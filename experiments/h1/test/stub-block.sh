#!/bin/bash
# Host-only stand-in for a workload block implementing the H1 hook (README "Hook contract H1-HOOK v1"); used by
# test/selftest.sh through plugins/pins-stub.sh. Writes synthetic run dirs (loadgen/summary.json, steps.jsonl,
# manifest.txt, steps.csv with recv/lib_bg CPU columns) — no VM, no SSH, no shared memory. Marker: H1-HOOK v1
# env: H1MODE slo|fix, H1_N, H1_MIXES / H1_LEVELS, H1_SEED, H1_PARENT_LOCK, LOCK (test lock), STUB_WORKLOAD,
#   STUB_FAIL (optional): "note:<sys>:<mix>" = that SLO run ends with a note; "rc" = the block fails.
set -uo pipefail
D=${1:?}
: "${H1MODE:?}" "${H1_N:?}" "${H1_PARENT_LOCK:?}" "${STUB_WORKLOAD:?}"
grep -q "^owner=$H1_PARENT_LOCK " "${LOCK:?}" || { echo "SEQUENCE STOP: parent lock $H1_PARENT_LOCK not held"; exit 2; }
[ "${STUB_FAIL:-}" = rc ] && { echo "SEQUENCE STOP: injected failure"; exit 1; }
python3 -I -B - "$D" <<'EOF'
import json, os, sys
d = sys.argv[1]
mode, n, w = os.environ["H1MODE"], os.environ["H1_N"], os.environ["STUB_WORKLOAD"]
fail = os.environ.get("STUB_FAIL", "")
base = {"hw": 100.0, "pop": 40.0, "mg": 80.0}
stream = {"vdb": "search", "recsys": "query"}.get(w, "mixed")
slo = {"vdb": (99, 100), "recsys": (95, 100)}.get(w, (99, 1))
def step(i, phase, off, x, ok, ms):
    return {"step": i, "phase": phase, "offered_x": off, "measure_s": 15, "x": x, "pass": ok, "aborted": False,
            "lag_flag": False, "reason": "" if ok else "p99 > SLO",
            "streams": {stream: {"offered": off, "achieved": x, "sent": int(x * 15), "done": int(x * 15), "errors": 0,
                                 "timeouts": 0, "p50_ms": ms / 3, "p90_ms": ms / 2, "p99_ms": ms, "p999_ms": ms * 1.2,
                                 "pslo_ms": ms, "max_ms": ms * 2, "lag_p99_us": 1, "lag_max_us": 2}}}
def write(name, sysk, mix, steps, summary):
    rd = os.path.join(d, name)
    os.makedirs(os.path.join(rd, "loadgen"))
    with open(os.path.join(rd, "loadgen", "steps.jsonl"), "w") as f:
        f.write("".join(json.dumps(s) + "\n" for s in steps))
    json.dump(summary, open(os.path.join(rd, "loadgen", "summary.json"), "w"))
    open(os.path.join(rd, "loadgen", "manifest.txt"), "w").write(f"slo={stream}:{slo[0]}:{slo[1]}\n")
    open(os.path.join(rd, "manifest.txt"), "w").write(
        f"name={name}\nsystem={sysk}\nnode0=192.168.122.100 6.14.0-famfs-de-stijl+-ds-popcorn-new-12 x\ncxl_swmc_commit=stub\n")
    with open(os.path.join(rd, "steps.csv"), "w") as f:
        f.write("label,step,stream,n0_window_s,n0_recv_cpu_s,n0_lib_bg_cpu_s,n1_window_s,n1_recv_cpu_s,n1_lib_bg_cpu_s\n")
        for s in steps:
            r = 3.0 if sysk == "pop" else 0.0
            b = 2.0 if sysk in ("mg", "mgoff") else 0.0
            f.write(f"x,{s['step']},{stream},15,{r},{b},15,{r},{b}\n")
    open(os.path.join(rd, "h1-runcheck.txt"), "w").write("stub per-run checks\nRUNCHECK PASS stub\n")
    if w == "vdb":
        open(os.path.join(rd, "opsplit-steps.csv"), "w").write("step,op\n")
    if w in ("kv", "lmdb"):  # workload split: Megalon background CPU over both nodes (opsplit.csv lib_bg_cpu_s)
        with open(os.path.join(rd, "opsplit.csv"), "w") as f:
            f.write("step,op,lib_bg_cpu_s[measured]\n")
            for s in steps:
                f.write(f"{s['step']},get,{4.0 if sysk in ('mg', 'mgoff') else 0.0}\n")
    if w == "recsys":  # breakdown.csv bg_cpu_ms_node<k>
        with open(os.path.join(rd, "breakdown.csv"), "w") as f:
            f.write("step,bg_cpu_ms_node0[measured],bg_cpu_ms_node1[measured]\n")
            for s in steps:
                f.write(f"{s['step']},{2000.0 if sysk in ('mg', 'mgoff') else 0.0},{2000.0 if sysk in ('mg', 'mgoff') else 0.0}\n")
    return name
runs = []
if mode == "slo":
    for spec in os.environ["H1_MIXES"].split():
        mix = spec.split("=", 1)[0]
        for sysk in ("hw", "pop", "mg"):
            m = base[sysk]
            st = [step(0, "warmup", 10, 10, True, 0.1)]
            i = 1
            for off in (10, m * 0.5, m * 0.9, m, m * 1.1):
                st.append(step(i, "ramp" if off < m else "bisect", off, min(off, m), off <= m, 0.5 if off <= m else 2)); i += 1
            for _ in range(3):
                st.append(step(i, "confirm", m, m, True, 0.9)); i += 1
            for f_ in (0.7, 0.8, 0.9):
                st.append(step(i, "fill", m * f_, m * f_, True, 0.6)); i += 1
            for f_ in (1.05, 1.1, 1.2):
                st.append(step(i, "overload", m * 1.1 * f_, m * 1.05, False, 3)); i += 1
            note = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" if fail == f"note:{sysk}:{mix}" else ""
            summ = {"mode": "slo", "note": note, "steps": i, "slo": {"stream": stream, "pct": slo[0], "ms": slo[1]},
                    "max_offered_x_pass": m, "min_offered_x_fail": m * 1.1,
                    "confirm": {"reps": 3, "fails": 0, "x_mean": m, "x_sd": 0.5, "pslo_mean_ms": 0.9, "pslo_sd_ms": 0.01},
                    "workload_finish": "ok"}
            runs.append((write(f"{sysk}-{mix}-slo-r{n}", sysk, mix, st, summ), sysk, mix))
else:
    lines = open(os.environ["H1_LEVELS"]).read().split("\n")[1:]
    for line in filter(None, lines):
        f = line.split("\t")
        mix, l1, l2 = f[0], float(f[8]), float(f[9])  # L1_rate, L2_rate: a fixed step's offered_x is the rate argument
        for sysk in ("hw", "pop", "mg", "mgoff"):
            st = [step(0, "warmup", l2, l2, True, 0.1), step(1, "fixed", l2, l2, True, 0.4), step(2, "fixed", l1, l1, True, 0.8)]
            summ = {"mode": "fixed", "note": "", "steps": 3, "slo": {"stream": stream, "pct": slo[0], "ms": slo[1]},
                    "workload_finish": "ok"}
            runs.append((write(f"{sysk}-{mix}-fix-r{n}", sysk, mix, st, summ), sysk, mix))
with open(os.path.join(d, "h1-runs.tsv"), "w") as f:
    f.write("# name system mix phase round run_dir\n")
    for name, sysk, mix in runs:
        f.write(f"{name}\t{sysk}\t{mix}\t{mode}\t{n}\t{name}\n")
print(f"stub {mode} {n}: {len(runs)} runs")
EOF
[ $? = 0 ] || { echo "SEQUENCE STOP: stub writer"; exit 1; }
echo "$(date -Is) SEQUENCE DONE stub-$STUB_WORKLOAD-$H1MODE-$H1_N"

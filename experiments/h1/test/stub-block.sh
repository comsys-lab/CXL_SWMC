#!/bin/bash
# Host-only stand-in for a workload block implementing the H1 hook (README "Hook contract H1-HOOK v2"); used by
# test/selftest.sh through plugins/pins-stub.sh. Writes synthetic lifetime dirs <dir>/<lifetime>/<part>/ with
# loadgen/summary.json + steps.jsonl, manifest.txt, steps.csv (recv/lib_bg CPU columns), the workload split file and
# h1-runcheck.txt — no VM, no SSH, no shared memory. Marker: H1-HOOK v2
# r1:   per mix hw, pop SLO-only lifetimes; mg lifetime SLO -> $H1_LEVELS_CMD <mix> -> settle -> L2 -> L1; mgoff lifetime
#       (settle -> L2 -> L1) right after mg; hw, pop separate fixed lifetimes
# cont: per mix hw, pop, mg each SLO -> settle -> L2 -> L1 at H1_LEVELS; mgoff lifetime right after mg
# H1_SYSTEMS (hook.sh, h1sys.py; v0.6.7): "hw pop mg" as above; "hw pop" (recsys): r1 per mix hw, pop SLO-only
#   lifetimes -> $H1_LEVELS_CMD <mix> -> hw, pop separate fixed lifetimes; cont hw, pop each SLO -> fix; no mg / mgoff.
# env: H1MODE r1|cont, H1_N, H1_MIXES, H1_SYSTEMS, H1_LEVELS (cont) / H1_LEVELS_CMD (r1), H1_SETTLE_S, H1_SEED, H1_PARENT_LOCK,
#   LOCK (test lock), STUB_WORKLOAD, STUB_FAIL (optional): "note:<sys>:<mix>" = that SLO run ends with the confirm-
#   failed note (decision E: a result); "badnote:<sys>:<mix>" = it ends with "streams exhausted during ramp" (an error);
#   "rc" = the block fails at once; "mgextra" = with H1_SYSTEMS "hw pop", an mg SLO entry is written anyway.
set -uo pipefail
D=${1:?}
: "${H1MODE:?}" "${H1_N:?}" "${H1_PARENT_LOCK:?}" "${STUB_WORKLOAD:?}" "${H1_SETTLE_S:?}"
grep -q "^owner=$H1_PARENT_LOCK " "${LOCK:?}" || { echo "SEQUENCE STOP: parent lock $H1_PARENT_LOCK not held"; exit 2; }
[ "${STUB_FAIL:-}" = rc ] && { echo "SEQUENCE STOP: injected failure"; exit 1; }
python3 -I -B - "$D" <<'EOF'
import json, os, subprocess, sys
d = sys.argv[1]
mode, n, w = os.environ["H1MODE"], os.environ["H1_N"], os.environ["STUB_WORKLOAD"]
settle = int(os.environ["H1_SETTLE_S"])
systems = os.environ["H1_SYSTEMS"].split()
assert systems in (["hw", "pop", "mg"], ["hw", "pop"]), systems
mgon = "mg" in systems
fail = os.environ.get("STUB_FAIL", "")
base = {"hw": 100.0, "pop": 40.0, "mg": 80.0}
stream = {"vdb": "search", "recsys": "query"}.get(w, "mixed")
slo = {"vdb": (99, 100), "recsys": (95, 100)}.get(w, (99, 1))
split = {"vdb": "opsplit-steps.csv", "kv": "opsplit.csv", "lmdb": "opsplit.csv", "recsys": "breakdown.csv"}[w]
idx = open(os.path.join(d, "h1-runs.tsv"), "w")
idx.write("# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n")
idx.flush()


def step(i, phase, off, x, ok, ms, meas=15):
    return {"step": i, "phase": phase, "offered_x": off, "measure_s": meas, "x": x, "pass": ok, "aborted": False,
            "lag_flag": False, "reason": "" if ok else "p99 > SLO",
            "streams": {stream: {"offered": off, "achieved": x, "sent": int(x * 15), "done": int(x * 15), "errors": 0,
                                 "timeouts": 0, "p50_ms": ms / 3, "p90_ms": ms / 2, "p99_ms": ms, "p999_ms": ms * 1.2,
                                 "pslo_ms": ms, "max_ms": ms * 2, "lag_p99_us": 1, "lag_max_us": 2}}}


def part(life, pname, sysk, steps, summary):
    ld = os.path.join(d, life)
    rd = os.path.join(ld, pname)
    os.makedirs(os.path.join(rd, "loadgen"))
    if not os.path.exists(os.path.join(ld, "manifest.txt")):
        open(os.path.join(ld, "manifest.txt"), "w").write(
            f"name={life}\nsystem={sysk}\nnode0=192.168.122.100 6.14.0-famfs-de-stijl+-ds-popcorn-new-12 x\ncxl_swmc_commit=stub\n")
        open(os.path.join(ld, "h1-runcheck.txt"), "w").write("stub per-run checks\nRUNCHECK PASS stub\n")
    with open(os.path.join(rd, "loadgen", "steps.jsonl"), "w") as f:
        f.write("".join(json.dumps(s) + "\n" for s in steps))
    json.dump(summary, open(os.path.join(rd, "loadgen", "summary.json"), "w"))
    open(os.path.join(rd, "loadgen", "manifest.txt"), "w").write(f"slo={stream}:{slo[0]}:{slo[1]}\n")
    r = 3.0 if sysk == "pop" else 0.0
    b = 2.0 if sysk in ("mg", "mgoff") else 0.0
    with open(os.path.join(rd, "steps.csv"), "w") as f:
        f.write("label,step,stream,n0_window_s,n0_recv_cpu_s,n0_lib_bg_cpu_s,n1_window_s,n1_recv_cpu_s,n1_lib_bg_cpu_s\n")
        for s in steps:
            f.write(f"x,{s['step']},{stream},15,{r},{b},15,{r},{b}\n")
    with open(os.path.join(rd, split), "w") as f:
        if w in ("kv", "lmdb"):
            f.write("step,op,lib_bg_cpu_s[measured]\n" + "".join(f"{s['step']},get,{2 * b}\n" for s in steps))
        elif w == "recsys":
            f.write("step,bg_cpu_ms_node0[measured],bg_cpu_ms_node1[measured]\n"
                    + "".join(f"{s['step']},{1000 * b},{1000 * b}\n" for s in steps))
        else:
            f.write("step,op\n")
    return os.path.relpath(rd, d)


def entry(name, sysk, mix, phase, rd, steps, life):
    idx.write(f"{name}\t{sysk}\t{mix}\t{phase}\t{n}\t{rd}\t{steps}\t{life}\n")
    idx.flush()


def slo_part(life, sysk, mix):
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
    note = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" if fail == f"note:{sysk}:{mix}" else \
        "streams exhausted during ramp" if fail == f"badnote:{sysk}:{mix}" else ""
    summ = {"mode": "slo", "note": note, "steps": i, "slo": {"stream": stream, "pct": slo[0], "ms": slo[1]},
            "max_offered_x_pass": m, "min_offered_x_fail": m * 1.1,
            "confirm": {"reps": 3, "fails": 0, "x_mean": m, "x_sd": 0.5, "pslo_mean_ms": 0.9, "pslo_sd_ms": 0.01},
            "workload_finish": "ok"}
    return part(life, "slo", sysk, st, summ)


def fix_part(life, sysk, l2, l1):
    # settle = loadgen warm-up at the L2 rate (discarded), then the L2 and L1 windows (steps 1, 2)
    st = [step(0, "warmup", l2, l2, True, 0.1, meas=0), step(1, "fixed", l2, l2, True, 0.4), step(2, "fixed", l1, l1, True, 0.8)]
    summ = {"mode": "fixed", "note": "", "steps": 3, "settle_s": settle,
            "slo": {"stream": stream, "pct": slo[0], "ms": slo[1]}, "workload_finish": "ok"}
    return part(life, "fix", sysk, st, summ)


def rates_cont(mix):
    for line in open(os.environ["H1_LEVELS"]).read().split("\n")[1:]:
        f = line.split("\t")
        if f[0] == mix:
            return float(f[9]), float(f[8])
    raise SystemExit(f"SEQUENCE STOP: no levels for {mix}")


for spec in os.environ["H1_MIXES"].split():
    mix = spec.split("=", 1)[0]
    if mode == "r1":
        for sysk in ("hw", "pop"):  # Latin order between hw and pop is the hook's; the stub keeps hw, pop
            life = f"{sysk}-{mix}-slo-r{n}"
            entry(life, sysk, mix, "slo", slo_part(life, sysk, mix), "-", "sep")
        life = f"mg-{mix}-r{n}"
        if mgon or fail == "mgextra":  # mgextra: a Megalon run where the workload has none (hook must refuse)
            entry(life + "-slo", "mg", mix, "slo", slo_part(life, "mg", mix), "-", "cont")
        p = subprocess.run([os.environ["H1_LEVELS_CMD"], mix], capture_output=True, text=True)
        if p.returncode != 0:
            print(f"SEQUENCE STOP: levels callback {mix}: {p.stderr.strip()}")
            sys.exit(1)
        l2, l1 = map(float, p.stdout.split())
        if mgon:
            entry(life + "-fix", "mg", mix, "fix", fix_part(life, "mg", l2, l1), "1,2", "cont")
            lo = f"mgoff-{mix}-fix-r{n}"
            entry(lo, "mgoff", mix, "fix", fix_part(lo, "mgoff", l2, l1), "1,2", "sep")
        for sysk in ("hw", "pop"):
            lf = f"{sysk}-{mix}-fix-r{n}"
            entry(lf, sysk, mix, "fix", fix_part(lf, sysk, l2, l1), "1,2", "sep")
    else:
        l2, l1 = rates_cont(mix)
        for sysk in systems:
            life = f"{sysk}-{mix}-r{n}"
            entry(life + "-slo", sysk, mix, "slo", slo_part(life, sysk, mix), "-", "cont")
            entry(life + "-fix", sysk, mix, "fix", fix_part(life, sysk, l2, l1), "1,2", "cont")
            if sysk == "mg":
                lo = f"mgoff-{mix}-fix-r{n}"
                entry(lo, "mgoff", mix, "fix", fix_part(lo, "mgoff", l2, l1), "1,2", "sep")
print(f"stub {mode} r{n} done")
EOF
[ $? = 0 ] || { echo "SEQUENCE STOP: stub writer"; exit 1; }
echo "$(date -Is) SEQUENCE DONE stub-$STUB_WORKLOAD-$H1MODE-$H1_N"

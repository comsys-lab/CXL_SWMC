#!/usr/bin/env python3
"""Per-rung results of the vector DB update-rate sweep (urate-block.sh; DESIGN.md §17;
reports/experiments/vectorDB-update-rate.md). Host only, offline.

  urate_report.py row <slo part dir> <name> <system> <rate> <writers> "<URATECHECK line>"
      one TSV line for <E>/urate-results.tsv: name system rate_ups writers result_search_s confirm_x_mean confirmed
      low_rate_violations uratecheck valid ramp_end knee_search_s note result_offered_raw
  urate_report.py table <evidence dir>
      stdout: urate-summary CSV, one row per lifetime <sys>-u<R> (sorted by rate, system): rate, % of corpus per hour,
      writers, max under SLO (result, confirm mean, confirmed, validity), low-rate violations, and at the result (mean
      over the confirm repeats at the result rate): achieved search/s, search p95/p99 (ms), achieved updates/s (server,
      both nodes), backlog at the window end (max), write lag mean/max (ms), writer busy fraction, Popcorn faults per
      search (read = I->S, write = S->M + write-protect) and per update, coherence time C per search / per update (ms),
      search T (ms), cxl_recv kernel-thread CPU (s per s); then (appended, verifier corrections 2026-10-20):
        result_offered_raw  loadgen max_offered_x_pass as written (when confirmed is not true this is loadgen's lo_fail,
                            a FAILED rate: never a result)
        confirm_x_sd        summary.json confirm.x_sd; confirm_x_min / confirm_x_max = min / max achieved search/s of the
                            confirm steps at the result rate (at_result=1); confirm_reps = their number
        n_judged, n_invalid_judged, n_invalid_all, n_steps
                            from urate_check.py's verdict line (urate-check.txt): steps judged for validity (ramp/bisect
                            passes at or below the result and the confirm repeats at it), invalid among them, invalid
                            among all measured steps, all measured steps. "valid" stays urate_check.py's PASS (no
                            judged step invalid); the doc's "rung not sustained" can be read from these counts.
      also <E>/urate-steps.csv (every measured step of every lifetime, the same columns per step plus phase / pass /
      valid, then the coherence columns COH_COLS below) for plots (x from 0) and CSV export.
  urate_report.py level <slo part dir>
      stdout: the lifetime's L1 candidate (summary.json confirm.x_mean) if confirmed is true and loadgen wrote no note;
      else exit 1 with the reason (urate-block.sh: fixed-load levels, user 2026-10-20)
  table also writes <E>/urate-fixed.csv: one row per measured window of the fixed-load lifetimes <sys>-u<R>-fix (part
      fix): rate_ups, system, writers, level (L2 | L1, from fix/h1-steps.txt), step, offered_search_s, valid
      (urate_check.py per window), update_offered, the metric columns COLS and the coherence columns COH_COLS (source of
      the H2-style common-load figures).
MED-1: result_search_s, confirm_x_mean, confirm_x_* and every at_result column are left empty unless summary.json
confirmed is true (an unconfirmed or truncated rung has no SLO result; result_offered_raw keeps loadgen's value).
cxl_recv CPU (s per s): opsplit's window (bg_cpu_frac x bg_kthr_run_s / (bg_lib_run_s + bg_kthr_run_s), i.e.
bg_kthr_run_s over opsplit's max-target stats window), so numerator and denominator come from the same snapshots; if the
opsplit columns are missing, the stats window of COH_COLS (same definition, from loadgen/stats), then urate-check's
window as before.
Inputs per lifetime: <life>/slo/loadgen/{summary.json,steps.jsonl,stats/step*-{begin,end}-t{0,1}.txt},
<life>/slo/urate-check.{csv,txt} (urate_check.py), <life>/slo/opsplit-steps.csv (opsplit.py, written by m4-run.sh)
and, if urate-recall.sh ran, <life>/slo/recall.recall.txt (recall@10 of 500 sampled measured searches of that lifetime,
plain and tie-aware; columns recall10, recall10_tie).
Coherence columns per step (urate-steps.csv; H2 / H3 figure sets of the experiment document): see COH_DOC. Keys the
stats files of a Popcorn lifetime lack give empty cells and one warning per key and lifetime on stderr (never an error);
all-HWcc lifetimes have no swmc keys and get empty Popcorn cells without warnings.
"""
import csv
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loadgen"))
import stats_delta  # noqa: E402

NLIVE = 26990000  # live records of the 28M dataset (pool A); an update deletes one and inserts one


def f(v):
    return "" if v is None else str(v)


def fl(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 4) if xs else ""


def warn(msg):
    print("urate_report.py WARNING: " + msg, file=sys.stderr)


def row(a):
    run, name, system, rate, writers, uc = a
    s = json.load(open(os.path.join(run, "loadgen", "summary.json")))
    c = s.get("confirm", {})
    rp = s.get("ramp_policy", {})
    ok = s.get("confirmed") is True
    print("\t".join([name, system, rate, writers, f(s.get("max_offered_x_pass")) if ok else "",
                     f(c.get("x_mean")) if ok else "", f(s.get("confirmed")),
                     str(len(s.get("low_rate_violations", []))), uc.split(" ")[1],
                     "1" if uc.startswith("URATECHECK PASS") else "0", f(rp.get("ramp_end", "")),
                     f(rp.get("knee_offered")), s.get("note", ""), f(s.get("max_offered_x_pass"))]))
    return 0


# --- coherence columns from the per-step stats snapshots (loadgen --stats-op) and opsplit-steps.csv ---------------
# node-wide Popcorn counters (/sys/kernel/swmc; keys as experiments/rocksdb/h3-faults.py, H3 csv), nodes summed
SYS_KEYS = {
    "read_faults": "sys.swmc.page_coherence.fault_read_count",
    "write_faults": "sys.swmc.page_coherence.fault_write_count",
    "is_faults": "sys.swmc.instr.fault_full_is.count",
    "inv_commits": "sys.swmc.instr.tx_invalidate.ack",
    "fetch_commits": "sys.swmc.instr.tx_fetch.ack",
    "unmaps": "sys.swmc.instr.serve.unmap_count",
    "coh_ipis": "sys.swmc.instr.ipi.coh_count",
    "coh_ipi_ns": "sys.swmc.instr.ipi.coh_ns",
}
PER_VM = ("read_faults", "write_faults")  # also reported per target (t0, t1)
# sums over every matching key (per-thread swmc accounting of all server threads; cxl_recv kernel threads)
PREFIX_SUMS = {
    "cxl_recv_run_ns": ("kthr.cxl_recv", ".run_ns"),
    "thr_is_faults": ("thr.", ".swmc.is_faults"),
    "thr_is_fault_ns": ("thr.", ".swmc.is_fault_ns"),
    "thr_sm_faults": ("thr.", ".swmc.sm_faults"),
    "thr_sm_fault_ns": ("thr.", ".swmc.sm_fault_ns"),
    "thr_wpu_faults": ("thr.", ".swmc.wpu_faults"),
    "thr_wpu_fault_ns": ("thr.", ".swmc.wpu_fault_ns"),
    "thr_nontrans_faults": ("thr.", ".swmc.nontrans_faults"),
    "thr_nontrans_fault_ns": ("thr.", ".swmc.nontrans_fault_ns"),
}
# owner reply wait of the search threads (qcoh.py: read + write msg wait of thr.vdb-search), per server search
SEARCH_WAIT = ("thr.vdb-search.swmc.read_msg_wait_ns", "thr.vdb-search.swmc.write_msg_wait_ns")
SEARCH_N = "searches"
# per-operation Popcorn fault counts / times by kind, as opsplit-steps.csv exports them (per operation of that type)
OPS_KINDS = ["pop_is_cnt", "pop_is_ms", "pop_sm_cnt", "pop_sm_ms", "pop_wp_cnt", "pop_wp_ms", "pop_ipi_cnt",
             "pop_ipi_ms", "pop_nontrans_cnt", "pop_nontrans_ms", "C_ms", "T_ms", "wait_ms", "n_ops"]
COH_COLS = (["coh_window_s", "coh_targets", "instr_enabled_all"]
            + [f"{op}_{k}" for op in ("search", "update") for k in OPS_KINDS]
            + ["search_owner_wait_ms", "search_read_owner_wait_ms", "server_searches"]
            + [x for n in SYS_KEYS for x in (n, n + "_per_s", n + "_per_s_per_vm")]
            + [f"{n}_per_s_t{t}" for n in PER_VM for t in (0, 1)]
            + [x for n in PREFIX_SUMS for x in (n, n + "_per_s")]
            + ["cxl_recv_cpu_s_per_s_stats"])
COH_DOC = """\
  coh_window_s / coh_targets  max loadgen window over the targets with both snapshots (as opsplit.py) / their number
  instr_enabled_all           1 if every target reports sys.swmc.instr.enabled = 1 (empty: key absent)
  <op>_pop_{is,sm,wp,ipi,nontrans}_{cnt,ms}, <op>_{C,T,wait}_ms, <op>_n_ops
                              opsplit-steps.csv per operation of type op (search | update): I->S, S->M, write-protect,
                              IPI, no-transition fault count and time; C, T; wait_ms = E1 wait (NOT the owner reply)
  search_owner_wait_ms        (thr.vdb-search.swmc.read_msg_wait_ns + write_msg_wait_ns) / server searches, ms per search
                              (as qcoh.py); search_read_owner_wait_ms = the read part only; server_searches = sum of the
                              stats key "searches" over the targets
  read_faults ... coh_ipi_ns  node-wide swmc counters (keys SYS_KEYS, as h3-faults.py), nodes summed; _per_s over
                              coh_window_s; _per_s_per_vm = / targets; read/write_faults_per_s_t<k> per VM over its own
                              window
  thr_* / cxl_recv_run_ns     sums over thr.*.swmc.<kind>_fault{s,_ns} (all server threads) / kthr.cxl_recv*.run_ns
  cxl_recv_cpu_s_per_s_stats  cxl_recv_run_ns / 1e9 / coh_window_s"""


def coh_steps(run, system):
    """{step: {COH_COLS...}} for the slo part dir run; missing keys -> None (+ one warning per key if system pop)."""
    out, missing = {}, set()
    lg = os.path.join(run, "loadgen")
    try:
        per = {}
        for fixed, d in stats_delta.deltas(lg):
            per.setdefault(fixed["step"], []).append((fixed, d))
    except Exception as e:  # noqa: BLE001 (analysis only: never stop the table)
        warn(f"{run}: stats snapshots unreadable ({e!r}); coherence columns empty")
        per = {}
    if not per and system == "pop":
        warn(f"{run}: no stats snapshot pairs in {lg}/stats; coherence columns empty")
    op = {}
    p = os.path.join(run, "opsplit-steps.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            op[(int(r["step"]), r["op"])] = r
    steps = set(per) | {s for s, _ in op}
    for n in steps:
        rs = per.get(n, [])
        o = {c: None for c in COH_COLS}
        wins = [float(fx["window_s"]) for fx, _ in rs if fx.get("window_s") not in ("", None)]
        win = max(wins) if wins else None
        o["coh_window_s"], o["coh_targets"] = (round(win, 6) if win else None), (len(rs) or None)
        en = [d.get("sys.swmc.instr.enabled") for _, d in rs]
        if rs and all(e is not None for e in en):
            o["instr_enabled_all"] = int(all(e == 1 for e in en))
        elif rs:
            missing.add("sys.swmc.instr.enabled")
        for opn in ("search", "update"):
            r = op.get((n, opn))
            for k in OPS_KINDS:
                v = fl(r.get(k)) if r else None
                if r is not None and k not in r:
                    missing.add("opsplit:" + k)
                o[f"{opn}_{k}"] = v
        if rs:
            def tsum(key):
                vals = [d.get(key) for _, d in rs]
                if any(v is None for v in vals):
                    missing.add(key)
                    return None
                return sum(vals)
            srch = tsum(SEARCH_N)
            rw, ww = tsum(SEARCH_WAIT[0]), tsum(SEARCH_WAIT[1])
            o["server_searches"] = srch
            if srch:
                if rw is not None:
                    o["search_read_owner_wait_ms"] = rw / srch / 1e6
                    if ww is not None:
                        o["search_owner_wait_ms"] = (rw + ww) / srch / 1e6
            for name, key in SYS_KEYS.items():
                tot = tsum(key)
                o[name] = tot
                o[name + "_per_s"] = tot / win if tot is not None and win else None
                o[name + "_per_s_per_vm"] = tot / win / len(rs) if tot is not None and win else None
            for name in PER_VM:
                for fx, d in rs:
                    v, w = d.get(SYS_KEYS[name]), fl(fx.get("window_s"))
                    if f"{name}_per_s_t{fx['target']}" in o:
                        o[f"{name}_per_s_t{fx['target']}"] = v / w if v is not None and w else None
            for name, (pre, suf) in PREFIX_SUMS.items():
                subs = [[v for k, v in d.items() if k.startswith(pre) and k.endswith(suf)] for _, d in rs]
                tot = sum(sum(s) for s in subs) if all(subs) else None  # every target must report the key
                if tot is None:
                    missing.add(pre + "*" + suf)
                o[name] = tot
                o[name + "_per_s"] = tot / win if tot is not None and win else None
            cr = o["cxl_recv_run_ns"]
            o["cxl_recv_cpu_s_per_s_stats"] = round(cr / 1e9 / win, 4) if cr is not None and win else None
        out[n] = o
    if system == "pop":
        for k in sorted(missing):
            warn(f"{run}: key {k} missing in some step (cells empty)")
    return out


def steps_of(run, system=""):
    st = {d["step"]: d for d in map(json.loads, open(os.path.join(run, "loadgen", "steps.jsonl"))) if d.get("measure_s", 0) > 0}
    uc = {}
    p = os.path.join(run, "urate-check.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            uc[int(r["step"])] = r
    op = {}
    p = os.path.join(run, "opsplit-steps.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            op[(int(r["step"]), r["op"])] = r
    coh = coh_steps(run, system)
    out = []
    for n, d in sorted(st.items()):
        srch = d["streams"].get("search", {})
        u = uc.get(n, {})
        os_, ou = op.get((n, "search"), {}), op.get((n, "update"), {})
        busy = [fl(x) for x in u.get("writer_busy", "").split()]
        r = {"step": n, "phase": d["phase"], "offered_x": d["offered_x"], "pass": d["pass"], "valid": u.get("valid", ""),
             "search_per_s": srch.get("achieved"), "search_p95_ms": srch.get("p95_ms"), "search_p99_ms": srch.get("p99_ms"),
             "updates_per_s": fl(u.get("done_per_s")), "update_offered": fl(u.get("update_offered")),
             "backlog_end": fl(u.get("backlog_end")), "lag_ms_mean": fl(u.get("lag_ms_mean")),
             "lag_ms_max": fl(u.get("lag_ms_max")), "writer_busy": mean(busy) if busy else None}
        for tag, o in (("search", os_), ("update", ou)):
            is_c, sm_c, wp_c = fl(o.get("pop_is_cnt")), fl(o.get("pop_sm_cnt")), fl(o.get("pop_wp_cnt"))
            r[f"pop_read_faults_per_{tag}"] = is_c
            r[f"pop_write_faults_per_{tag}"] = None if sm_c is None else sm_c + (wp_c or 0)
            r[f"C_ms_per_{tag}"] = fl(o.get("C_ms"))
            r[f"T_ms_per_{tag}"] = fl(o.get("T_ms"))
        c = coh.get(n, {c: None for c in COH_COLS})
        r.update(c)
        # cxl_recv CPU: opsplit's own window (bg_cpu_frac = (bg_lib + bg_kthr) / window_s), else the stats window of
        # the coherence columns (same snapshots), else urate-check's window (older behaviour)
        kthr, lib, frac = fl(os_.get("bg_kthr_run_s")), fl(os_.get("bg_lib_run_s")), fl(os_.get("bg_cpu_frac"))
        win = fl(u.get("window_s"))
        if kthr is not None and frac is not None:
            r["cxl_recv_cpu_s_per_s"] = round(frac * kthr / (kthr + (lib or 0)), 4) if kthr + (lib or 0) > 0 else 0.0
        elif c.get("cxl_recv_cpu_s_per_s_stats") is not None:
            r["cxl_recv_cpu_s_per_s"] = c["cxl_recv_cpu_s_per_s_stats"]
        else:
            r["cxl_recv_cpu_s_per_s"] = round(kthr / win, 4) if kthr is not None and win else None
        out.append(r)
    return out


COLS = ["search_per_s", "search_p95_ms", "search_p99_ms", "updates_per_s", "backlog_end", "lag_ms_mean", "lag_ms_max",
        "writer_busy", "pop_read_faults_per_search", "pop_write_faults_per_search", "pop_read_faults_per_update",
        "pop_write_faults_per_update", "C_ms_per_search", "C_ms_per_update", "T_ms_per_search", "T_ms_per_update",
        "cxl_recv_cpu_s_per_s"]


def check_counts(txt):
    """(n_judged, n_invalid_judged, n_invalid_all, n_steps) from urate_check.py's verdict line; None where absent."""
    m = re.search(r"judged_steps=(\d+) invalid=\[([^\]]*)\].*?all_steps_invalid=(\d+)/(\d+)", txt)
    if m:
        inv = [x for x in m.group(2).replace(",", " ").split() if x]
        return int(m.group(1)), len(inv), int(m.group(3)), int(m.group(4))
    m = re.search(r"no SLO result .*?invalid steps (\d+)/(\d+)", txt)  # no judged steps without an SLO result
    if m:
        return None, None, int(m.group(1)), int(m.group(2))
    return None, None, None, None


def table(a):
    E = a[0]
    lives = []
    for d in glob.glob(os.path.join(E, "*-u*", "slo")):
        m = re.fullmatch(r"(hw|pop)-u(\d+)", os.path.basename(os.path.dirname(d)))
        if m:
            lives.append((int(m.group(2)), m.group(1), d))
    lives.sort()
    w = csv.writer(sys.stdout)
    w.writerow(["rate_ups", "pct_corpus_per_h", "system", "writers", "result_search_s", "confirm_x_mean", "confirmed",
                "valid", "low_rate_violations", "ramp_end", "note", "recall10", "recall10_tie"]
               + ["at_result_" + c for c in COLS]
               + ["result_offered_raw", "confirm_x_sd", "confirm_x_min", "confirm_x_max", "confirm_reps", "n_judged",
                  "n_invalid_judged", "n_invalid_all", "n_steps"])
    allrows = []
    for rate, system, d in lives:
        s = json.load(open(os.path.join(d, "loadgen", "summary.json")))
        uc = open(os.path.join(d, "urate-check.txt")).read() if os.path.exists(os.path.join(d, "urate-check.txt")) else ""
        raw = s.get("max_offered_x_pass")
        ok = s.get("confirmed") is True
        best = raw if ok else None  # MED-1: an unconfirmed max_offered_x_pass is loadgen's lo_fail, not a result
        st = steps_of(d, system)
        wr = ""
        for line in open(os.path.join(os.path.dirname(d), "manifest.txt")):
            m = re.search(r"--writer-threads (\d+)", line)
            if m:
                wr = m.group(1)
                break
        rc = {}
        p = os.path.join(d, "recall.recall.txt")
        if os.path.exists(p):
            rc = dict(l.strip().split("=", 1) for l in open(p) if "=" in l and l.startswith("recall_"))
        at = [r for r in st if best is not None and r["phase"] == "confirm" and abs(r["offered_x"] - best) <= 1e-9 * max(1, best)]
        for r in st:
            allrows.append(dict(rate_ups=rate, system=system, writers=wr, result=best, result_offered_raw=raw,
                                at_result=int(r in at), **r))
        cx = [fl(r["search_per_s"]) for r in at if fl(r["search_per_s"]) is not None]
        conf = s.get("confirm", {}) if ok else {}
        w.writerow([rate, round(rate * 3600 / NLIVE * 100, 3), system, wr, f(best), f(conf.get("x_mean")),
                    f(s.get("confirmed")), int("URATECHECK PASS" in uc), len(s.get("low_rate_violations", [])),
                    s.get("ramp_policy", {}).get("ramp_end", ""), s.get("note", ""), rc.get("recall_measured_ok", ""),
                    rc.get("recall_tie_aware_measured_ok", "")]
                   + [mean([fl(r[c]) for r in at]) if at else "" for c in COLS]
                   + [f(raw), f(conf.get("x_sd")), f(min(cx)) if cx else "", f(max(cx)) if cx else "", len(at) if ok else ""]
                   + [f(x) for x in check_counts(uc)])
    keys = ["rate_ups", "system", "writers", "result", "at_result", "step", "phase", "offered_x", "pass", "valid",
            "update_offered"] + COLS + ["result_offered_raw"] + COH_COLS
    with open(os.path.join(E, "urate-steps.csv"), "w", newline="") as fo:
        dw = csv.DictWriter(fo, fieldnames=keys)
        dw.writeheader()
        for r in allrows:
            dw.writerow({k: f(r.get(k)) for k in keys})
    fixed_csv(E)
    return 0


def writers_of(life):
    for line in open(os.path.join(life, "manifest.txt")):
        m = re.search(r"--writer-threads (\d+)", line)
        if m:
            return m.group(1)
    return ""


def fixed_csv(E):
    """<E>/urate-fixed.csv: the measured windows of the fixed-load lifetimes <sys>-u<R>-fix (part fix: L2 then L1)."""
    rows = []
    for d in sorted(glob.glob(os.path.join(E, "*-u*-fix", "fix"))):
        m = re.fullmatch(r"(hw|pop)-u(\d+)-fix", os.path.basename(os.path.dirname(d)))
        if not m:
            continue
        try:
            st = [r for r in steps_of(d, m.group(1)) if r["phase"] == "fixed"]
        except Exception as e:  # noqa: BLE001 (analysis only)
            warn(f"{d}: fixed part unreadable ({e!r})")
            continue
        lv = {}
        p = os.path.join(d, "h1-steps.txt")
        if os.path.exists(p):
            a, _, b = open(p).read().strip().partition(",")
            lv = {int(a): "L2", int(b): "L1"}
        elif len(st) == 2:
            lv = {st[0]["step"]: "L2", st[1]["step"]: "L1"}
        for r in st:
            rows.append(dict(rate_ups=int(m.group(2)), system=m.group(1), writers=writers_of(os.path.dirname(d)),
                             level=lv.get(r["step"], ""), offered_search_s=r["offered_x"], **r))
    rows.sort(key=lambda r: (r["rate_ups"], r["system"], r["step"]))
    keys = ["rate_ups", "system", "writers", "level", "step", "offered_search_s", "valid", "update_offered"] + COLS + COH_COLS
    with open(os.path.join(E, "urate-fixed.csv"), "w", newline="") as fo:
        dw = csv.DictWriter(fo, fieldnames=keys)
        dw.writeheader()
        for r in rows:
            dw.writerow({k: f(r.get(k)) for k in keys})


def level(a):
    """L1 candidate of one SLO lifetime: confirm mean, only if confirmed is true and loadgen wrote no note."""
    s = json.load(open(os.path.join(a[0], "loadgen", "summary.json")))
    x = fl(s.get("confirm", {}).get("x_mean"))
    if s.get("confirmed") is not True:
        sys.exit("not confirmed")
    if s.get("note"):
        sys.exit("note: " + s["note"])
    if not x or x <= 0:
        sys.exit("no confirm mean")
    print(x)
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "row" and len(sys.argv) == 8:
        sys.exit(row(sys.argv[2:]))
    if len(sys.argv) == 3 and sys.argv[1] == "level":
        sys.exit(level(sys.argv[2:]))
    if len(sys.argv) == 3 and sys.argv[1] == "table":
        sys.exit(table(sys.argv[2:]))
    sys.exit(__doc__ + "\n" + COH_DOC)

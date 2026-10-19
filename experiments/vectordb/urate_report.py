#!/usr/bin/env python3
"""Per-rung results of the vector DB update-rate sweep (urate-block.sh; DESIGN.md §17). Host only, offline.

  urate_report.py row <slo part dir> <name> <system> <rate> <writers> "<URATECHECK line>"
      one TSV line for <E>/urate-results.tsv: name system rate_ups writers result_search_s confirm_x_mean confirmed
      low_rate_violations uratecheck valid ramp_end knee_search_s note
  urate_report.py table <evidence dir>
      stdout: urate-summary CSV, one row per lifetime <sys>-u<R> (sorted by rate, system): rate, % of corpus per hour,
      writers, max under SLO (result, confirm mean, confirmed, validity), low-rate violations, and at the result (mean
      over the confirm repeats at the result rate): achieved search/s, search p95/p99 (ms), achieved updates/s (server,
      both nodes), backlog at the window end (max), write lag mean/max (ms), writer busy fraction, Popcorn faults per
      search (read = I->S, write = S->M + write-protect) and per update, coherence time C per search / per update (ms),
      search T (ms), cxl_recv kernel-thread CPU (s per s); also <E>/urate-steps.csv (every measured step of every
      lifetime, the same columns per step plus phase / pass / valid) for plots (x from 0) and CSV export.
Inputs per lifetime: <life>/slo/loadgen/{summary.json,steps.jsonl}, <life>/slo/urate-check.csv (urate_check.py),
<life>/slo/opsplit-steps.csv (opsplit.py, written by m4-run.sh) and, if urate-recall.sh ran, <life>/slo/recall.recall.txt
(recall@10 of 500 sampled measured searches of that lifetime, plain and tie-aware; columns recall10, recall10_tie).
"""
import csv
import glob
import json
import os
import re
import sys

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


def row(a):
    run, name, system, rate, writers, uc = a
    s = json.load(open(os.path.join(run, "loadgen", "summary.json")))
    c = s.get("confirm", {})
    rp = s.get("ramp_policy", {})
    print("\t".join([name, system, rate, writers, f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")),
                     str(len(s.get("low_rate_violations", []))), uc.split(" ")[1],
                     "1" if uc.startswith("URATECHECK PASS") else "0", f(rp.get("ramp_end", "")),
                     f(rp.get("knee_offered")), s.get("note", "")]))
    return 0


def steps_of(run):
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
        win = fl(u.get("window_s"))
        bg = fl(os_.get("bg_kthr_run_s"))
        r["cxl_recv_cpu_s_per_s"] = round(bg / win, 4) if bg is not None and win else None
        out.append(r)
    return out


COLS = ["search_per_s", "search_p95_ms", "search_p99_ms", "updates_per_s", "backlog_end", "lag_ms_mean", "lag_ms_max",
        "writer_busy", "pop_read_faults_per_search", "pop_write_faults_per_search", "pop_read_faults_per_update",
        "pop_write_faults_per_update", "C_ms_per_search", "C_ms_per_update", "T_ms_per_search", "T_ms_per_update",
        "cxl_recv_cpu_s_per_s"]


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
                "valid", "low_rate_violations", "ramp_end", "note", "recall10", "recall10_tie"] + ["at_result_" + c for c in COLS])
    allrows = []
    for rate, system, d in lives:
        s = json.load(open(os.path.join(d, "loadgen", "summary.json")))
        uc = open(os.path.join(d, "urate-check.txt")).read() if os.path.exists(os.path.join(d, "urate-check.txt")) else ""
        best = s.get("max_offered_x_pass")
        st = steps_of(d)
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
            allrows.append(dict(rate_ups=rate, system=system, writers=wr, result=best,
                                at_result=int(r in at), **r))
        w.writerow([rate, round(rate * 3600 / NLIVE * 100, 3), system, wr, f(best), f(s.get("confirm", {}).get("x_mean")),
                    f(s.get("confirmed")), int("URATECHECK PASS" in uc), len(s.get("low_rate_violations", [])),
                    s.get("ramp_policy", {}).get("ramp_end", ""), s.get("note", ""), rc.get("recall_measured_ok", ""),
                    rc.get("recall_tie_aware_measured_ok", "")]
                   + [mean([fl(r[c]) for r in at]) if at else "" for c in COLS])
    keys = ["rate_ups", "system", "writers", "result", "at_result", "step", "phase", "offered_x", "pass", "valid",
            "update_offered"] + COLS
    with open(os.path.join(E, "urate-steps.csv"), "w", newline="") as fo:
        dw = csv.DictWriter(fo, fieldnames=keys)
        dw.writeheader()
        for r in allrows:
            dw.writerow({k: f(r.get(k)) for k in keys})
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "row" and len(sys.argv) == 8:
        sys.exit(row(sys.argv[2:]))
    if len(sys.argv) == 3 and sys.argv[1] == "table":
        sys.exit(table(sys.argv[2:]))
    sys.exit(__doc__)

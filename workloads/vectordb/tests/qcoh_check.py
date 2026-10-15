#!/usr/bin/env python3
"""Checks of the per-query coherence block (DESIGN.md §14) on a host_smoke.sh scratch dir (Host only).

usage: qcoh_check.py <scratch dir> fake|megalon|none
  every mode: one coh record per OK search response (search-coh.bin vs searches.bin, joined by seq),
              sections = segments + 1 (start + one per segment task) on every record, coh_ns = pf + mg parts,
              the server totals at stop (qcoh.searches, qcoh.coh_ns_total, summed over nodes) equal the records' sums
              (every response arrived: smoke runs drain), qcoh.read_errors = open_errors = 0, qcoh.py runs.
  fake (VDB_QCOH_FAKE=1, plain backend): the fake source adds a segment task's distance computations as fault ns,
              so per query pf_fault_ns = dists of searches.bin exactly, pf_faults = pf_transactions = segments,
              pf_msg_wait_ns = sum over segments of dists/4 (<= dists/4).
  megalon:    per-query sums of the sampled read counters over all records = the search role's totals at stop
              (megt.search.rd_sampled, rd_start_ns, ...; search threads only run queries); role blocks sum to megt.*;
              mg_check_est_ns follows the calibration rule; no write sections on search threads.
  none:       plain backend on a kernel without /proc/thread-self/swmc: source 0, coh_ns = 0.
"""
import os, re, subprocess, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, "experiments", "vectordb"))
import qcoh  # noqa: E402

S, mode = sys.argv[1], sys.argv[2]
fails = []


def check(c, msg):
    if not c:
        fails.append(msg)


def final_stats(path):
    t = open(path).read()
    t = t[t.index("vdb-server: stopping"):]
    d = {}
    for line in t.splitlines():
        k, s, v = line.partition("=")
        if s:
            try:
                d[k] = int(v)
            except ValueError:
                d[k] = v
    return d


lg = os.path.join(S, "loadgen")
logs = np.fromfile(os.path.join(lg, "search-coh.bin"), dtype=qcoh.LOG)
sr = np.fromfile(os.path.join(lg, "searches.bin"), dtype=qcoh.search_dtype(10))
ok = sr[sr["status"] == 0]
st = [final_stats(os.path.join(S, f"node{k}.log")) for k in (0, 1)]
c = logs["c"]
print(f"coh records {len(logs)}, OK search responses {len(ok)}")
check(len(logs) == len(ok), "one coh record per OK search response")
check(np.array_equal(np.sort(logs["seq"]), np.sort(ok["seq"])), "coh seqs = OK search seqs")
check((c["version"] == 1).all(), "version 1")
seg = ok["segs"][0] if len(ok) else 0
check((c["sections"] == seg + 1).all(), f"sections = segments + 1 = {seg + 1}")
check((c["coh_ns"] == c["pf_fault_ns"] + c["mg_check_est_ns"] + c["mg_reexec_est_ns"]).all(), "coh_ns = parts")
check(sum(s["qcoh.searches"] for s in st) == len(logs), "server qcoh.searches = records")
check(sum(s["qcoh.coh_ns_total"] for s in st) == int(c["coh_ns"].sum()), "server qcoh.coh_ns_total = records' sum")
check(all(s["qcoh.read_errors"] == 0 and s["qcoh.open_errors"] == 0 for s in st), "no counter read/open errors")
check((c["busy_ns"] > 0).all(), "busy_ns > 0")
by = {int(q): i for i, q in enumerate(ok["seq"])}
oi = np.array([by[int(q)] for q in logs["seq"]])
if mode == "fake":
    check(all(s["qcoh.source"] == "fake" for s in st), "source fake")
    check((c["source"] == 2).all(), "record source 2")
    check(np.array_equal(c["pf_fault_ns"], ok["dists"][oi].astype(np.uint64)), "per query pf_fault_ns = dists")
    check((c["pf_faults"] == seg).all() and (c["pf_transactions"] == seg).all(), "faults = transactions = segments")
    check((c["pf_msg_wait_ns"] <= c["pf_fault_ns"] // 4).all() and (c["pf_msg_wait_ns"] > 0).all(), "msg wait = sum dists/4")
    check((c["mg_rd_sampled"] == 0).all() and (c["mg_sample"] == 0).all(), "no Megalon fields")
elif mode == "megalon":
    check((c["mg_sample"] == 64).all(), "mg_sample 64")
    for f in ("rd_sampled", "rd_start_ns", "rd_body_ns", "rd_end_ns", "rd_retries", "rd_failed_timed", "rd_failed_ns"):
        tot = sum(s[f"megt.search.{f}"] for s in st)
        check(int(c["mg_" + f].sum()) == tot, f"sum per-query mg_{f} = megt.search.{f} ({int(c['mg_' + f].sum())} vs {tot})")
    for f in ("rd_sampled", "rd_start_ns", "wr_sections", "wr_end_ns", "rd_retries"):
        for s in st:
            parts = sum(s[f"megt.{r}.{f}"] for r in ("main", "writer", "search", "other"))
            check(parts == s[f"megt.{f}"], f"role blocks sum to megt.{f}")
    check(all(s["megt.search.wr_sections"] == 0 for s in st), "no write sections on search threads")
    check(all(s["megt.writer.wr_sections"] > 0 for s in st), "writer write sections counted in the writer role")
    cl = c["clock_ns"].astype(np.float64)
    exp = np.maximum(0, c["mg_rd_start_ns"].astype(np.float64) + c["mg_rd_end_ns"] - 2 * cl * c["mg_rd_sampled"]) * 64
    check(np.array_equal(c["mg_check_est_ns"], exp.astype(np.uint64)), "mg_check_est_ns = calibration rule")
    check((c["mg_rd_sampled"] > 0).mean() > 0.9, "most queries have sampled sections")
    check(c["coh_ns"].sum() < c["busy_ns"].sum(), "sum coh < sum busy (coherence is part of the sections' time)")
    check(all(s["megt.clock_ns"] == s["qcoh.clock_ns"] and 0 < s["megt.clock_ns"] < 2000 for s in st), "clock_ns recorded")
    ratio = c["mg_check_est_ns"].sum() / max(1, (c["mg_rd_start_ns"].sum() + c["mg_rd_end_ns"].sum()) * 64)
    print(f"megalon: per-query check estimate / uncalibrated = {ratio:.3f}, clock_ns {st[0]['megt.clock_ns']}, "
          f"mean check {c['mg_check_est_ns'].mean() / 1e3:.1f} us/query, retries {int(c['mg_rd_retries'].sum())}")
elif mode == "none":
    check(all(s["qcoh.source"] == "none" for s in st), "source none")
    check((c["coh_ns"] == 0).all(), "coh_ns 0")
r = subprocess.run([sys.executable, os.path.join(ROOT, "experiments", "vectordb", "qcoh.py"), S,
                    "--queries", os.path.join(S, "qcoh-queries.csv")], capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip())
check(r.returncode == 0, "qcoh.py runs")
m = re.search(r"matched (\d+), ambiguous (\d+), unmatched measured (\d+)", r.stdout)
if m:
    meas = int((logs["measured"] == 1).sum())
    check(int(m.group(3)) == 0, f"every measured record matched a raw record ({m.group(3)} unmatched of {meas})")
print("QCOH_CHECK " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
sys.exit(1 if fails else 0)

#!/usr/bin/env python3
"""faultlat parse: summarize step JSON files into one CSV table.

Usage: parse.py <outdir> [more dirs...]  > summary.csv
One row per (dir, step, pass): count, minflt, p50/p90/p99/p999/mean/stdev (ns),
and the kernel transaction/nack deltas recorded by the step.
faultlat-4/5 (Popcorn build 9/10): instr/enabled at the step and the measuring thread's
build-9 counter deltas (per step, repeated on every pass row; "_ns" = duration).
"""
import csv
import json
import pathlib
import sys

cols = ["dir", "step", "cmd", "op", "pass", "count", "minflt", "min_ns", "p50_ns",
        "p90_ns", "p99_ns", "p999_ns", "max_ns", "mean_ns", "stdev_ns",
        "transaction_count_delta", "nack_retry_count_delta", "local_wait_count_delta",
        "remote_request_count_delta", "protocol",
        "instr_enabled", "acct_registered", "is_faults", "is_fault_ns", "sm_faults", "sm_fault_ns",
        "wpu_faults", "wpu_fault_ns", "nontrans_faults", "nontrans_fault_ns", "instr_clock_reads",
        "acct_syncs"]
w = csv.DictWriter(sys.stdout, fieldnames=cols)
w.writeheader()
for d in sys.argv[1:]:
    for f in sorted(pathlib.Path(d).glob("*.json")):
        j = json.loads(f.read_text())
        if "passes" not in j:  # contend results: stress_summary.py
            continue
        k = j.get("kernel", {})
        ins = j.get("instr", {})
        td = ins.get("thread_delta", {})
        for name, s in j["passes"].items():
            if not isinstance(s, dict):
                continue
            mf = j["passes"].get(name + "_minflt", j["passes"].get("minflt", ""))
            row = {"dir": d, "step": f.stem, "cmd": j["cmd"], "op": j["params"]["op"],
                   "pass": name, "minflt": mf, "protocol": k.get("protocol", ""),
                   "instr_enabled": ins.get("enabled_before", ""),
                   "acct_registered": ins.get("acct_registered", "")}
            for c in cols:
                if c in s:
                    row[c] = s[c]
                elif c in k:
                    row[c] = k[c]
                elif c in td:
                    row[c] = td[c]
            w.writerow(row)

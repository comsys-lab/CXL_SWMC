#!/usr/bin/env python3
"""faultlat parse: summarize step JSON files into one CSV table.

Usage: parse.py <outdir> [more dirs...]  > summary.csv
One row per (dir, step, pass): count, minflt, p50/p90/p99/p999/mean/stdev (ns),
and the kernel transaction/nack deltas recorded by the step.
"""
import csv
import json
import pathlib
import sys

cols = ["dir", "step", "cmd", "op", "pass", "count", "minflt", "min_ns", "p50_ns",
        "p90_ns", "p99_ns", "p999_ns", "max_ns", "mean_ns", "stdev_ns",
        "transaction_count_delta", "nack_retry_count_delta", "local_wait_count_delta",
        "remote_request_count_delta", "protocol"]
w = csv.DictWriter(sys.stdout, fieldnames=cols)
w.writeheader()
for d in sys.argv[1:]:
    for f in sorted(pathlib.Path(d).glob("*.json")):
        j = json.loads(f.read_text())
        if "passes" not in j:  # contend results: stress_summary.py
            continue
        k = j.get("kernel", {})
        for name, s in j["passes"].items():
            if not isinstance(s, dict):
                continue
            mf = j["passes"].get(name + "_minflt", j["passes"].get("minflt", ""))
            row = {"dir": d, "step": f.stem, "cmd": j["cmd"], "op": j["params"]["op"],
                   "pass": name, "minflt": mf, "protocol": k.get("protocol", "")}
            for c in cols:
                if c in s:
                    row[c] = s[c]
                elif c in k:
                    row[c] = k[c]
            w.writerow(row)

#!/usr/bin/env python3
"""Checks tools/classify_sharing.py on the trace files of tests/megalon_trace_test.cc (scenario in its header).
usage: classify_sharing_test.py <scratch dir with node0/node1.vdbtrace.bin>"""
import csv, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
S = sys.argv[1]
r = subprocess.run([sys.executable, os.path.join(HERE, "..", "tools", "classify_sharing.py"), S, "--searches", "4",
                    "--a6-dir", os.path.join(S, "a6")], capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip())
rows = {x["role"]: x for x in csv.DictReader(open(os.path.join(S, "sharing.csv")))}
a = rows["all"]
want = dict(events_A="3", events_B="1", true_A="1", false_A="1", true_B="1", false_B="0", no_prior_copy="1",
            unexplained="0", ev_ns_true="150", ev_ns_false="100", ev_ns_excluded="100")
bad = [f"{k}={a[k]} (want {v})" for k, v in want.items() if a[k] != v]
if abs(float(a["false_time_share"]) - 0.4) > 1e-9:
    bad.append(f"false_time_share {a['false_time_share']}")
log1 = open(os.path.join(S, "a6", "node1.log.csv")).read().splitlines()
ev = [l for l in log1 if l.startswith("E,")]
if len(ev) != 3 or not ev[0].startswith("E,0,A,1,2"):
    bad.append(f"a6 events {ev}")
print("CLASSIFY_SHARING_TEST " + ("PASS" if not bad and r.returncode == 0 else "FAIL: " + "; ".join(bad)))
sys.exit(1 if bad or r.returncode else 0)

#!/usr/bin/env python3
"""Megalon probe decision of run set rs-h1 (runset-rs-h1.sh, evaluation-pipeline rev 3 §6.2, Q2).

usage: mg_decide.py <probe block dir> "<rates>" <slo_ms>
For every rate: the probe block's single Megalon fixed window (stream-fix.tsv row of system mg at that rate) decides
  slo  if its query p95 (loadgen steps.jsonl, streams.query.p95_ms of the window's step) <= slo_ms and the window is
       valid (stream-fix.tsv valid = 1, stream_check.py rule)
  fix  otherwise, or when the rate has no or several probe windows
Prints one TSV line per rate: rate decision probe_p95_ms probe_valid source. Blank lines in steps.jsonl are skipped.
"""
import csv
import json
import os
import sys


def decide(B, rates, slo):
    with open(os.path.join(B, "stream-fix.tsv")) as f:
        fx = [r for r in csv.reader(f, delimiter="\t") if r and not r[0].startswith("#")]
    out = []
    for rate in rates:
        w = [r for r in fx if r[1] == "mg" and r[2] == rate]
        if len(w) != 1:
            out.append([rate, "fix", "", "", f"no single probe window ({len(w)})"])
            continue
        name, step = w[0][0], int(w[0][5])
        with open(os.path.join(B, name, "fix", "loadgen", "steps.jsonl")) as f:
            st = {d["step"]: d for d in (json.loads(l) for l in f if l.strip())}
        p95 = float(st[step]["streams"]["query"]["p95_ms"])   # loadgen writes "inf" when no query completed
        ok = p95 <= slo and w[0][6] == "1"
        out.append([rate, "slo" if ok else "fix", str(p95), w[0][6],
                    f"probe {name} step {step} (rule: p95 <= {slo:g} ms and valid)"])
    return out


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    for r in decide(sys.argv[1], sys.argv[2].split(), float(sys.argv[3])):
        print("\t".join(r))

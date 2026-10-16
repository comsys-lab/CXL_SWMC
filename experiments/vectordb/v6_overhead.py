#!/usr/bin/env python3
"""Megalon coherence-timer overhead from two run dirs at the same offered rates (reports/VDB-V1-packet.md step 2).

usage: v6_overhead.py ON_RUN OFF_RUN      (ON = timers on, default; OFF = MEGALON_COH_TIMERS=0)
Both runs must have the same loadgen arguments (rates, mix, seed); the dirs' opsplit-steps.csv (opsplit.py) and
loadgen/steps.jsonl are read. Per measured step (same step number = same offered rate) and operation type it prints
achieved/s, latency p50/p99 (loadgen, ms) and T_ms (server per-operation thread time) for ON and OFF and the ratio
ON / OFF [derived]. One pair of runs: differences below the run-to-run noise (not measured here) are not significant.
Exit 1 if the runs' loadgen arguments differ or a step is missing.
"""
import csv, json, os, sys


def args_of(run):
    for line in open(os.path.join(run, "manifest.txt")):
        if line.startswith("loadgen_args="):
            return line.split("=", 1)[1].strip()
    return None


def rows(run):
    out = {}
    for r in csv.DictReader(open(os.path.join(run, "opsplit-steps.csv"))):
        out[(int(r["step"]), r["op"])] = r
    return out


def lat(run):
    out = {}
    for line in open(os.path.join(run, "loadgen", "steps.jsonl")):
        s = json.loads(line)
        for name, st in s.get("streams", {}).items():
            out[(s["step"], name)] = st
    return out


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    on, off = sys.argv[1], sys.argv[2]
    a_on, a_off = args_of(on), args_of(off)
    if a_on != a_off:
        print(f"loadgen arguments differ:\n  on:  {a_on}\n  off: {a_off}")
        return 1
    r_on, r_off, l_on, l_off = rows(on), rows(off), lat(on), lat(off)
    if set(r_on) != set(r_off):
        print(f"steps differ: on {sorted(r_on)} off {sorted(r_off)}")
        return 1
    print("step,op,offered,achieved_on,achieved_off,p50_on_ms,p50_off_ms,p99_on_ms,p99_off_ms,T_on_ms,T_off_ms,"
          "T_ratio,C_on_ms,C_off_ms")
    for k in sorted(r_on):
        a, b = r_on[k], r_off[k]
        la, lb = l_on.get(k, {}), l_off.get(k, {})
        ta, tb = f(a["T_ms"]), f(b["T_ms"])
        print(",".join(str(x) for x in (
            k[0], k[1], la.get("offered"), a["achieved_per_s"], b["achieved_per_s"], la.get("p50_ms"), lb.get("p50_ms"),
            la.get("p99_ms"), lb.get("p99_ms"), a["T_ms"], b["T_ms"], round(ta / tb, 4) if ta and tb else "",
            a["C_ms"], b["C_ms"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())

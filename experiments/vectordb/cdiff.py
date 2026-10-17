#!/usr/bin/env python3
"""Megalon C by difference (user decision 2026-10-17, state/TASKS.md "(a) 차분 방식"): per measured step and operation
type, C_diff = T(Megalon, timers off) - T(all-HWcc), both from opsplit-steps.csv of two runs with the same workload,
rates and seed (e.g. VDB-V1 mg-u5-t0 vs hw-u5-v6). The sampled Megalon C (C_ms of the timers-on run) is printed next
to it for reference only (biased upward by the probe cost, M2 §19). Offline, Host only; reads only.
Interim helper for the vector DB until experiments/analysis provides the same rule (it does not as of 2026-10-17).

usage: cdiff.py MEGALON_TIMERS_OFF_RUN ALLHWCC_RUN [MEGALON_TIMERS_ON_RUN]   -> CSV on stdout
columns: step, op, offered_t0, offered_hw, n_t0, n_hw, T_t0_ms, T_hw_ms, C_diff_ms, C_diff_frac (C_diff / T_t0),
         p50_t0_ms, p50_hw_ms, p99_t0_ms, p99_hw_ms, C_sampled_on_ms (optional third run)
A step whose achieved rates differ by more than 5 % between the runs is still printed with WARN in a trailing note
column (the difference then mixes load with coherence work).
"""
import csv, os, sys


def rows(run):
    return {(r["step"], r["op"]): r for r in csv.DictReader(open(os.path.join(run, "opsplit-steps.csv")))}


def f(x):
    return float(x) if x not in ("", None) else None


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    t0, hw = rows(sys.argv[1]), rows(sys.argv[2])
    on = rows(sys.argv[3]) if len(sys.argv) == 4 else {}
    w = csv.writer(sys.stdout)
    w.writerow(["step", "op", "achieved_t0", "achieved_hw", "n_t0", "n_hw", "T_t0_ms", "T_hw_ms", "C_diff_ms",
                "C_diff_frac", "p50_t0_ms", "p50_hw_ms", "p99_t0_ms", "p99_hw_ms", "C_sampled_on_ms", "note"])
    missing = sorted(set(t0) ^ set(hw))
    for k in sorted(set(t0) & set(hw), key=lambda k: (int(k[0]), k[1])):
        a, b = t0[k], hw[k]
        Ta, Tb = f(a["T_ms"]), f(b["T_ms"])
        cd = Ta - Tb if Ta is not None and Tb is not None else None
        ra, rb = f(a["achieved_per_s"]), f(b["achieved_per_s"])
        note = "WARN achieved rates differ > 5%" if ra and rb and abs(ra - rb) > 0.05 * max(ra, rb) else ""
        w.writerow([k[0], k[1], a["achieved_per_s"], b["achieved_per_s"], a["n_ops"], b["n_ops"], Ta, Tb, cd,
                    cd / Ta if cd is not None and Ta else None, a["lat_p50_ms"], b["lat_p50_ms"], a["lat_p99_ms"],
                    b["lat_p99_ms"], on.get(k, {}).get("C_ms", ""), note])
    if missing:
        print(f"cdiff: WARN steps/ops present in only one run: {missing}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

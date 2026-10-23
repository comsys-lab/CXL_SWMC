#!/usr/bin/env python3
"""Knee-sweep rate plan (reports/experiments/knee-sweep.md §2; user 2026-10-24). Generalised from
workspaces/knee-sweep-design/make_sweep.py with the approved factor sets:
  All-HWcc  0.90 1.00 1.03 1.06 1.09 1.12 1.15 1.20 (every cell)
  Popcorn   0.90 0.92 0.94 0.96 0.98 1.00 1.02 1.05 (every cell)
  Megalon   knee cells MK 0.90 1.00 1.15 1.30 1.45 1.60 1.80 2.00 2.30; floor cells MF 1 1.5 2.25 3.4 5.1 x the start
            rate (cells whose runs did not all confirm or whose lowest-rate p99 > 0.5 x SLO: DESIGN.md rule)
  base = mean over runs 1-3 of the confirmed max under SLO (base_search of cross_runs.csv; MF: the start rate),
  offered rate = base_search / search fraction of the mix x factor (loadgen --rates = total ops/s)
  step 15 s warmup + 45 s measure + 5 s drain; MF 15 + 120 + 5 s.
usage: knee_sweep_plan.py <cross_runs.csv> <out plan csv>
Prints, per (hypothesis, N), the H2N_FIXED token string (tokens <sys>@<mix>/sweep/-/-/<rates>/<wu>/<me>/<dr>) and the
time estimate (loadgen time + per-lifetime overhead of make_sweep.py: H1 hw/mg 3.5, pop 5 min; H2 hw/mg 2, pop 4 min).
"""
import csv
import statistics as S
import sys

SETS = {
    "HW": ([0.90, 1.00, 1.03, 1.06, 1.09, 1.12, 1.15, 1.20], 15, 45, 5),
    "POP": ([0.90, 0.92, 0.94, 0.96, 0.98, 1.00, 1.02, 1.05], 15, 45, 5),
    "MK": ([0.90, 1.00, 1.15, 1.30, 1.45, 1.60, 1.80, 2.00, 2.30], 15, 45, 5),
    "MF": ([1.00, 1.50, 2.25, 3.40, 5.10], 15, 120, 5),
    "POPX": ([0.90, 0.92, 0.94, 0.96, 0.98, 1.00, 1.02, 1.05, 1.10, 1.15], 15, 45, 5),
}
# user decisions 2026-10-24 (after the verifier review): H2 N=2 u50 Megalon takes the knee set (confirmed in every
# run; the floor rule above put it in MF); Popcorn cells with capacity > 1.05 x base (mean over runs 1-3 of
# cross_runs.csv xmax_over_base) get the extra factors 1.10 and 1.15 (set POPX)
MK_OVERRIDE = {("H2", 2, "u50")}
POP_EXTRA_CAP = 1.05
OVH = {("H1", "pop"): 5.0, ("H1", "hw"): 3.5, ("H1", "mg"): 3.5, ("H2", "pop"): 4.0, ("H2", "hw"): 2.0, ("H2", "mg"): 2.0}
SHORT = {"All-HWcc": "hw", "Popcorn": "pop", "Megalon": "mg"}
FRAC = {"u10": 0.9, "u50": 0.5, "u90": 0.1}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    cells = {}
    for r in csv.DictReader(open(src)):
        cells.setdefault((r["hyp"], int(r["n"]), r["mix"], r["system"]), []).append(r)
    plan = []
    for (hyp, n, mix, sysn), rs in sorted(cells.items()):
        s = SHORT[sysn]
        if s == "mg":
            conf = all(r["confirmed"] == "1" for r in rs)
            low = S.median(float(r["lowest_rate_p99_over_slo"]) for r in rs)
            fs = "MF" if (not conf or low > 0.5) else "MK"
            if (hyp, n, mix) in MK_OVERRIDE:
                fs = "MK"
        else:
            fs = "HW" if s == "hw" else "POP"
        cap = S.mean(float(r["xmax_over_base"]) for r in rs)
        if fs == "POP" and cap > POP_EXTRA_CAP:
            fs = "POPX"
        base_search = S.mean(float(r["base_search"]) for r in rs)
        base_x = base_search / FRAC[mix]
        f, wu, me, dr = SETS[fs]
        rates = [round(base_x * k, 2) for k in f]
        plan.append(dict(hyp=hyp, n=n, mix=mix, system=sysn, sys=s, factor_set=fs, runs=len(rs),
                         base_search=round(base_search, 2), base_offered_x=round(base_x, 2),
                         factors=" ".join(f"{k:g}" for k in f), rates_offered_x=",".join(f"{x:g}" for x in rates),
                         step_warmup_s=wu, step_measure_s=me, drain_s=dr, n_points=len(f),
                         est_min=round((len(f) * (wu + me + dr)) / 60 + OVH[(hyp, s)], 1)))
    with open(dst, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(plan[0]))
        w.writeheader()
        w.writerows(plan)
    tot = 0
    for hyp in ("H1", "H2"):
        for n in sorted({p["n"] for p in plan if p["hyp"] == hyp}):
            pp = [p for p in plan if p["hyp"] == hyp and p["n"] == n]
            m = sum(p["est_min"] for p in pp)
            tot += m
            print(f"# {hyp} N={n}: {len(pp)} lifetimes, est {m:.0f} min")
            print(" ".join(f"{p['sys']}@{p['mix']}/sweep/-/-/{p['rates_offered_x']}/{p['step_warmup_s']}/{p['step_measure_s']}/{p['drain_s']}"
                           for p in pp))
    print(f"# total lifetimes est {tot:.0f} min")


if __name__ == "__main__":
    main()

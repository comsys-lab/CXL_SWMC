#!/usr/bin/env python3
"""Worst-case update consumption of one KIND=urate lifetime (urate-block.sh budget rule; DESIGN.md §17; verifier
MEDIUM-1: computed from the loadgen parameters, not from an estimate).

The update stream runs whenever loadgen sends (run warm-up, every step warm-up and window; not during drains), so a
lifetime consumes R x (sending seconds). Sending seconds are bounded from the parameters of m4-run.sh's KIND=urate
parts (parsed from the file, so the bound follows any change there):
  warm part: --warmup-s + --step-warmup-s + --step-measure-s
  slo part:  --warmup-s
           + ramp: steps at x_i = start * g^i (g = --g-min, the smallest ramp growth below 0.8 x SLO: x 1.2; growth after
             a failed step is x factor), until x_i >= --x-knee, then K (--ramp-knee) failing steps; at most --max-steps
           + bisect: the KneeRamp bisect budget (12 steps) at x = --x-floor
           + confirm: (1 + --max-confirm-probes) x --confirm-reps steps of max(--confirm-s, minq / x_floor)
           + fill 3 steps at 0.7 x_floor, overload 3 steps at x_floor
  every step = --step-warmup-s + max(window, --min-step-queries / x).
Scenario assumptions (recorded with the result): --x-floor = the lowest SLO result the bound covers (search/s; a lower
result makes bisect/confirm longer), --x-knee = the highest knee it covers. Outside them the bound does not hold; the
block then relies on the loadgen exhaustion NOTE (m4-run.sh) for the explicitly allowed rates.

usage: urate_budget.py <m4-run.sh> [--start 1] [--x-floor 10] [--x-knee 400] [--g-min 1.2] [--rate R ...]
  prints "seconds=<bound>" and, per --rate, "rate=<R> updates=<R x bound>"; --start is the ramp start of the rates
  given (urate-block.sh calls it once per rate with that rate's start, URATE_START_MAP).
urate_budget.py <m4-run.sh> --fixed [--rate R ...]
  fixed-load lifetime (URATE_PARTS="warm fix"): warm part + fix part (--warmup-s settle + 2 x (--step-warmup-s +
  --step-measure-s), L2 and L1); prints "fixed_seconds=<bound>" and, per --rate, "fixed_rate=<R> updates=<R x bound>".
"""
import argparse
import re
import sys

BISECT_STEPS = 12  # experiments/loadgen slo_search.h KneeRamp bisect budget (knee_bisect_steps)
FILL = (0.7, 0.8, 0.9)
OVERLOAD = 3


def part_args(text, part):
    m = re.search(r'export PART_ARGS_%s="([^"]*)"' % part, text[text.index("  urate) "):])
    if not m:
        sys.exit(f"PART_ARGS_{part} not found in the urate case")
    toks = m.group(1).split()
    d = {}
    for i, t in enumerate(toks):
        if t.startswith("--") and i + 1 < len(toks) and not toks[i + 1].startswith("--"):
            d[t[2:]] = toks[i + 1]
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("m4run")
    ap.add_argument("--start", type=float, default=1.0)
    ap.add_argument("--x-floor", type=float, default=10.0)
    ap.add_argument("--x-knee", type=float, default=400.0)
    ap.add_argument("--g-min", type=float, default=1.2)
    ap.add_argument("--rate", type=int, action="append", default=[])
    ap.add_argument("--fixed", action="store_true")
    a = ap.parse_args()
    text = open(a.m4run).read()
    w, s = part_args(text, "warm"), part_args(text, "slo")
    f = lambda d, k: float(d[k])  # noqa: E731
    t_warm = f(w, "warmup-s") + f(w, "step-warmup-s") + f(w, "step-measure-s")
    if a.fixed:
        x = part_args(text, "fix")
        t_fix = f(x, "warmup-s") + 2 * (f(x, "step-warmup-s") + f(x, "step-measure-s"))
        print(f"fixed_seconds={t_warm + t_fix:.0f} warm={t_warm:.0f} fix={t_fix:.0f} (settle {f(x, 'warmup-s'):g} s + 2 windows)")
        for r in a.rate:
            print(f"fixed_rate={r} updates={int(r * (t_warm + t_fix) + 0.5)}")
        return 0
    sw, win, minq = f(s, "step-warmup-s"), f(s, "step-measure-s"), float(s.get("min-step-queries", 0))
    step = lambda x, window=win: sw + max(window, minq / x)  # noqa: E731
    ramp, x, n = 0.0, a.start, 0
    knee_k, max_steps = int(s.get("ramp-knee", 0)), int(s["max-steps"])
    while n < max_steps and x < a.x_knee:
        ramp += step(x)
        x *= a.g_min
        n += 1
    for _ in range(min(knee_k, max_steps - n)):
        ramp += step(x)
        x *= float(s["factor"])
    bisect = BISECT_STEPS * step(a.x_floor)
    confirm = (1 + int(s["max-confirm-probes"])) * int(s["confirm-reps"]) * step(a.x_floor, f(s, "confirm-s"))
    fill = sum(step(r * a.x_floor) for r in FILL)
    over = OVERLOAD * step(a.x_floor)
    total = t_warm + f(s, "warmup-s") + ramp + bisect + confirm + fill + over
    print(f"seconds={total:.0f} warm={t_warm:.0f} slo_warmup={f(s, 'warmup-s'):.0f} ramp={ramp:.0f} ({n}+{knee_k} steps) "
          f"bisect={bisect:.0f} confirm={confirm:.0f} fill={fill:.0f} overload={over:.0f} "
          f"(start={a.start:g} g_min={a.g_min:g} x_knee={a.x_knee:g} x_floor={a.x_floor:g} min_step_queries={minq:g})")
    for r in a.rate:
        print(f"rate={r} updates={int(r * total + 0.5)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

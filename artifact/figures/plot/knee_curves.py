"""Fig 1 / Fig 4 curve source with the knee sweep (reports/experiments/knee-sweep.md §2), plus the shared axis helpers.

curve(run1_slo_dir, sweep_rows, base_offered_x, slo_ms) -> (drawn, all_points)
  points = run 1's pooled SLO-search points (pool.py, 3 %, aborted steps left out) at offered < 0.9 x base, plus the
  knee-sweep fixed-rate points (one step per rate, offered >= 0.9 x base; aborted = 1 rows are not fully measured and
  are left out). Drawing rule (user 2026-10-24): in offered order draw every fully measured point while achieved
  search/s still rises; stop at the first point more than 2 % below the max so far (that point is not drawn).
  Each point: offered, x (search/s), xr (requests/s = search + update), p (p99 ms; inf -> 1e6), src, drawn.
Sweep CSV columns: experiments/eval/knee_pilot_export.py (knee-pilot.csv; lifetime = sys-mix-nN).
Paths are arguments (artifact/figures: no fixed locations).
"""
import csv
import math
import os

import pool

TOL = 0.03       # pool.py pooling; run 1 points at >= (1 - TOL) x the first sweep rate are dropped (user option a)
FALLBACK = 0.05  # a sweep point ends the curve if its search/s is > 5 % below the max so far (user option a)
INF_MS = 1e6
SYSKEY = {"All-HWcc": "hw", "Popcorn": "pop", "Megalon": "mg"}

# knee-sweep export layout under a knee root (default <control>/workspaces/knee-sweep/derived; artifact/figures/common.sh)
MAIN_GROUPS = ("knee-sweep-h1", "knee-sweep-h2-n2", "knee-sweep-h2-n4", "knee-sweep-h2-n8")
ADDENDUM_GROUPS = ("knee-sweep-h2-n4-v2", "knee-sweep-h2-n8-v2")


def sweep_paths(root, groups=MAIN_GROUPS):
    """knee-pilot.csv of each export group under root (the main sweep; ADDENDUM_GROUPS for the addendum)."""
    return [os.path.join(root, g, "knee-pilot.csv") for g in groups]


def load_plan(path):
    """{(hyp, n, mix, sys): base_offered_x} from experiments/eval/knee-sweep-plan.csv (knee_sweep_plan.py)."""
    return {(r["hyp"], int(r["n"]), r["mix"], r.get("sys") or SYSKEY[r["system"]]): float(r["base_offered_x"])
            for r in csv.DictReader(open(path))}


def load_sweep_by(paths):
    """{(hyp, n, mix, sys): [rows]} from the knee-sweep exports (H1 file = hyp H1; lifetime = sys-mix-nN)."""
    out = {}
    for p in paths:
        hyp = "H1" if "-h1" in os.path.basename(os.path.dirname(os.path.abspath(p))) else "H2"
        for r in csv.DictReader(open(p)):
            s, mix, nn = r["lifetime"].split("-")
            out.setdefault((hyp, int(nn[1:]), mix, s), []).append(r)
    return out


def load_sweep(paths):
    """{lifetime: [rows]} from one or more sweep CSVs."""
    out = {}
    for p in paths:
        for r in csv.DictReader(open(p)):
            out.setdefault(r["lifetime"], []).append(r)
    return out


def _f(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else INF_MS
    except (TypeError, ValueError):
        return INF_MS


def _req_x(d, p, steps):
    xw = w = 0.0
    for st in p["steps"]:
        s = steps[st]
        so = s["streams"]["search"]
        win = so["sent"] / so["offered"] if so["offered"] else s["measure_s"]
        xw += sum(v.get("achieved", 0) or 0 for v in s["streams"].values()) * win
        w += win
    return xw / w if w else 0.0



def curve(run1_slo_dir, sweep_rows, base_offered_x, split=None, extra_rows=None):
    d = f"{run1_slo_dir}/loadgen"
    steps = {s["step"]: s for s in pool.steps(d)}
    cut = 0.9 * base_offered_x * (1 - 1e-6)
    pts = []
    floor = split is None  # run 1 found no rate meeting the SLO: only its lowest step is kept (Megalon floor panels)
    if any(not s.get("aborted") for s in steps.values()):
        below = [p for p in pool.pooled(d, "search", 99, tol=TOL, split_at=split) if p["offered"] < cut]
        if floor:
            allp = pool.pooled(d, "search", 99, tol=TOL)
            below = allp[:1]
        # run 1 part: the pool.py shape filter (longest chain with rising throughput) as in the run-1 figures, so a
        # noisy bisect point below 0.9x does not end the curve before the sweep; points off the chain are not drawn
        keep = pool.shape_filter(below) if below else []
        for p, kp in zip(below, keep):
            pts.append({"offered": p["offered"], "x": p["x"], "xr": _req_x(d, p, steps), "p": min(p["p"], INF_MS),
                        "src": "run1 slo-search", "full": kp})
    for r in sweep_rows or []:
        ok = r["aborted"] in ("0", "", "False") and r.get("lifetime_ok", "1") in ("1", "True") \
            and r.get("after_abort", "0") in ("0", "", "False")
        pts.append({"offered": float(r["offered_x"]), "x": _f(r["achieved_search_s"]),
                    "xr": _f(r["achieved_search_s"]) + _f(r["achieved_update_s"]), "p": _f(r["p99_ms"]),
                    "src": f"knee sweep step {r['step']}", "full": ok, "reason": r.get("reason", ""),
                    "floor": floor})
    pts.sort(key=lambda p: (p["offered"], 0 if p["src"].startswith("run1") else 1))
    sw = [p["offered"] for p in pts if not p["src"].startswith("run1")]
    if sw and not floor:  # run 1 points within 3 % below the first sweep rate duplicate it: the sweep point is used
        for p in pts:
            if p["src"].startswith("run1") and p["offered"] >= min(sw) * (1 - TOL):
                p["full"], p["dup"] = False, True
    best, stop = 0.0, False
    for p in pts:
        p["drawn"] = False
        if p["src"].startswith("run1"):
            p["drawn"] = p["full"]  # run 1 part: shape-filtered chain (fall-back rule applies to the sweep part)
            continue
        if stop or not p["full"]:
            continue
        if best and p["x"] < (1 - FALLBACK) * best:
            stop = True
            continue
        p["drawn"] = True
        best = max(best, p["x"])
    drawn = [p for p in pts if p["drawn"]]
    # collapse step (user 2026-10-24, option ii): the first measured sweep step after the last drawn point that ended
    # the curve (aborted, after an abort, or fell back) and has a p99 (> 0, completions present); if the main sweep
    # has none, the first such step of an addendum lifetime (extra_rows) -- its rate may be below the last drawn one
    collapse = None
    if drawn:
        last = drawn[-1]
        cand = [p for p in pts if not p["src"].startswith("run1") and not p["drawn"] and p["offered"] > last["offered"]
                and p["p"] > 0]
        if cand:
            collapse = {"p": cand[0]["p"], "offered": cand[0]["offered"], "src": "main sweep " + cand[0]["src"]}
        else:
            for r in extra_rows or []:
                pv = _f(r["p99_ms"])
                if r["aborted"] not in ("0", "", "False") and pv > 0:
                    collapse = {"p": pv, "offered": float(r["offered_x"]), "src": f"addendum step {r['step']}"}
                    break
    curve.last_collapse = collapse
    return drawn, pts


def tight_ticks(vmax, pad=1.05, min_iv=3, max_iv=6):
    """(top, step): integer step in {1, 2, 2.5, 5} x 10^k, top = multiple of step >= vmax x pad, 3-6 intervals."""
    need = vmax * pad
    best = None
    for k in range(0, 7):
        for m in (1, 2, 2.5, 5):
            stp = m * 10 ** k
            if stp != int(stp):
                continue
            top = math.ceil(need / stp - 1e-9) * stp
            n = round(top / stp)
            if min_iv <= n <= max_iv and (best is None or top < best[0] or (top == best[0] and stp > best[1])):
                best = (top, int(stp))
    return best


def y_top_visible(slo, firsts, slo_axis):
    """SLO at 80-90 % (slo_axis), raised so that every system's first point (values in firsts > top) is inside."""
    top, st = slo_axis(slo)
    need = max([0] + [y for y in firsts if y > top])
    if not need:
        return top, st, None
    for stp in (1, 2, 4, 5, 10, 20, 25, 50, 100, 200, 250, 500):
        t = math.ceil(need * 1.08 / stp) * stp
        if 3 <= t / stp <= 6:
            return t, stp, need
    return math.ceil(need * 1.08), max(1, math.ceil(need * 1.08 / 5)), need

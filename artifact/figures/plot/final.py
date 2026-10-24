"""de-stijl-motivation-isca27 FINAL figure set over runs k in RUNS (mean over runs, min-max in the CSVs).

Usage: python3 -I -B final.py --out DIR --runs 1 2 3 --figs fig1,fig5 --eval2 DIR [--knee DIR --plan CSV]
                              [--evidence-map OLD=NEW ...]
  --eval2  derived root of the eval2 runs: per run k  <eval2>/h1/vdb/vdb/run<k>-chain (vectordb/export.py: slo_summary.csv,
           fixed.csv) and <eval2>/h2/vdb/h2n/run<k> (eval/export_h2n.py --combine: summary.csv, steps.csv, fig8.csv)
  --knee   knee-sweep export root (<knee>/knee-sweep-h1/, -h2-n2/4/8/, addendum -h2-n4-v2/, -h2-n8-v2/ knee-pilot.csv)
  --plan   knee-sweep plan (experiments/eval/knee-sweep-plan.csv); --knee and --plan are needed by fig1 and fig4 only
  --evidence-map OLD=NEW  rewrite the evidence prefix of every source_dir found in the exports (evidence moved/copied)
  --figs   comma list of fig1 .. fig8 or "all" (fig1 = Fig 1 + its requests/s and band variants and max-under-SLO CSV;
           fig4 = Fig 4 + requests/s + band; fig6 = 6a + 6b; fig8 = Fig 8 + its two secondary load variants)
Read-only on the exports and the evidence; writes only into --out.
Raw latencies and counters are read through each export's source_dir (the evidence dirs).
Aggregation (agg()): always the mean over runs with min-max (user 2026-10-23).
Latency curves (Figs 1, 4): knee_curves.py (run CURVE_RUN = first run given below 0.9 x base, knee sweep above).
Code origin: workspaces/figs-isca27/final.py (2026-10-24 final set); only path handling and figure selection changed.
"""
import argparse
import csv
import json
import math
import os
import re
import statistics as stt  # noqa: F401
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lstyle as L  # noqa: E402
import style as S  # noqa: E402
import pool  # noqa: E402
import cause_agg  # noqa: E402
import knee_curves as K  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

FIGS_ALL = ("fig1", "fig2", "fig3", "fig4", "fig5", "fig6", "fig7", "fig8")
ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--out", required=True)
ap.add_argument("--runs", required=True, type=int, nargs="+")
ap.add_argument("--figs", default="all")
ap.add_argument("--eval2", required=True)
ap.add_argument("--knee")
ap.add_argument("--plan")
ap.add_argument("--evidence-map", action="append", default=[])
A = ap.parse_args()
FIGS = FIGS_ALL if A.figs == "all" else tuple(f.strip() for f in A.figs.split(",") if f.strip())
for f in FIGS:
    if f not in FIGS_ALL:
        raise SystemExit(f"unknown figure {f} (fig1 .. fig8, all)")


def want(*figs):
    return any(f in FIGS for f in figs)


if want("fig1", "fig4") and not (A.knee and A.plan):
    raise SystemExit("fig1 / fig4 need --knee and --plan (knee-sweep exports and plan)")
EMAP = []
for m in A.evidence_map:
    old, _, new = m.partition("=")
    if not old or not new:
        raise SystemExit(f"bad --evidence-map {m} (OLD=NEW)")
    EMAP.append((old.rstrip("/"), new.rstrip("/")))


def ev(path):
    """evidence path of an export's source_dir after --evidence-map (unchanged without a map)."""
    for old, new in EMAP:
        if path == old or path.startswith(old + "/"):
            return new + path[len(old):]
    return path


OUT = L.ensure(A.out)
RUNS = A.runs
CURVE_RUN = RUNS[0]
EX = os.path.abspath(A.eval2)
TOL, SLO_MS = 0.03, 100.0
MIX = [("u10", "Search-heavy (90:10)"), ("u50", "Balanced (50:50)"), ("u90", "Update-heavy (10:90)")]
NS = (2, 4, 8)
NUM = {"runs": RUNS, "curve_run": CURVE_RUN, "figs_selected": list(FIGS), "figs": {}, "flags": [], "sources": {}}


def rows(path):
    return list(csv.DictReader(l for l in open(path) if not l.startswith("#")))


def fnum(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def agg(vals, label=None):
    """{'v', 'lo', 'hi', 'stat', 'runs': [...]}: mean with min-max over runs."""
    v = [x for x in vals if x is not None]
    if not v:
        return {"v": None, "lo": None, "hi": None, "stat": "none", "runs": vals}
    # user 2026-10-23: always the mean with min-max (no median / outlier rule)
    return {"v": sum(v) / len(v), "lo": min(v), "hi": max(v), "stat": "mean", "runs": vals}


def fmt(a, d=2):
    if a["v"] is None:
        return "n/a"
    return f"{a['v']:.{d}f} [{a['lo']:.{d}f}-{a['hi']:.{d}f}]" + ("m" if a["stat"] == "median" else "")


SHOW_WHISKERS = False  # user 2026-10-23: no min-max whiskers in the figures (min-max stays in the CSVs)


def whisker(ax, x, a, color, log=False):
    if not SHOW_WHISKERS or a["v"] is None or a["hi"] - a["lo"] <= 0:
        return
    ec = "white" if color.upper() in ("#000000", "BLACK") else "black"
    # the part inside the bar in the bar's contrast colour, the part above in black
    ax.errorbar([x], [a["v"]], yerr=[[a["v"] - a["lo"]], [a["hi"] - a["v"]]], fmt="none", ecolor=ec, elinewidth=1.0,
                capsize=2, capthick=1.0, zorder=6)
    if ec == "white" and a["hi"] > a["v"]:
        ax.plot([x, x], [a["v"], a["hi"]], color="black", lw=1.0, zorder=7)
        ax.plot([x - 0.05, x + 0.05], [a["hi"]] * 2, color="black", lw=1.0, zorder=7)


def bracket_lo(slo_dir):
    p = f"{slo_dir}/slo-points.txt"
    if os.path.exists(p):
        m = re.search(r"knee bracket offered \[([0-9.]+),", open(p).read())
        if m:
            return float(m.group(1))
    return None


def points(d, split):
    allst = pool.steps(d)
    pts = pool.pooled(d, "search", 99, tol=TOL, split_at=split) if any(not s.get("aborted") for s in allst) else []
    for p in pts:
        p["aborted"] = 0
    for s in allst:
        if s.get("aborted") and (split is None or s["offered_x"] > split * (1 + 1e-9)):
            so = s["streams"]["search"]
            pv = so["pslo_ms"]
            pts.append({"offered": s["offered_x"], "x": s["x"], "p": float(pv) if pv not in (0, "", None) else math.inf,
                        "n": so["sent"], "steps": [s["step"]], "phases": [s["phase"]], "step_p": [pv], "aborted": 1,
                        "saturated": "saturated" in s.get("reason", "")})
    pts.sort(key=lambda p: p["offered"])
    keep = [True] * len(pts) if split is None else pool.shape_filter(pts, slo=SLO_MS, split_at=split)
    return pts, keep


# ---------------------------------------------------------------- load per-run exports (only what the figures need)
H1, H2 = {}, {}
NEED_H1, NEED_H2 = want("fig1", "fig2", "fig3"), want("fig4", "fig5", "fig6", "fig7", "fig8")
for k in RUNS:
    d1 = f"{EX}/h1/vdb/vdb/run{k}-chain"
    d2 = f"{EX}/h2/vdb/h2n/run{k}"
    src = {}
    if NEED_H1:
        H1[k] = {"summ": {(r["system"], r["point"]): dict(r, source_dir=ev(r["source_dir"]))
                          for r in rows(f"{d1}/slo_summary.csv")},
                 "fx": {(r["system"], r["point"], r["level"]): r for r in rows(f"{d1}/fixed.csv")
                        if "fixh2" not in r["source_dir"]}}
        evd = sorted({r["source_dir"].split("/vdb/r1/")[0] for r in H1[k]["summ"].values()})
        src.update(h1_export=d1, h1_evidence=evd)
        for e in evd:  # Rule E sources
            p = f"{e}/vdb/levels.tsv"
            if os.path.exists(p):
                for r in csv.DictReader(open(p), delimiter="\t"):
                    for s in ("hw", "pop", "mg"):
                        if r.get(f"x_{s}_src", "confirm") != "confirm":
                            NUM["flags"].append(f"Rule E fallback run {k} {r['mix']} {s}: {r[f'x_{s}_src']}")
    if NEED_H2:
        H2[k] = {"summ": {(int(r["nodes"]), r["mix"], r["system"]): dict(r, source_dir=ev(r["source_dir"]))
                          for r in rows(f"{d2}/summary.csv")},
                 "fig8": [r for r in rows(f"{d2}/fig8.csv")]}
        src.update(h2_export=d2, h2_evidence=sorted({r["source_dir"].split("/block/")[0] for r in H2[k]["summ"].values()}))
    NUM["sources"][k] = src

if want("fig1", "fig4"):
    KPLAN = K.load_plan(A.plan)  # knee-sweep bases
    SWEEP = K.load_sweep_by(K.sweep_paths(A.knee))
    ADDEND = K.load_sweep_by(K.sweep_paths(A.knee, K.ADDENDUM_GROUPS))  # addendum lifetimes: collapse evidence only
    NUM["sources"]["knee_sweep"] = {"plan": A.plan, "exports": K.sweep_paths(A.knee)}
PT_HDR = ("figure", "panel", "system", "offered_total_ops_s", "x_search_per_s", "p99_ms", "n_search", "steps",
          "phases", "aborted_step", "drawn", "p99_norm", "base_ms", "clipped_at_top")


_JS = {}


def add_req(d, pts):
    """x_req per point = achieved requests/s (search + update streams of the loadgen, aggregate over VMs), averaged
    over the point's steps with the same window weights as pool.py uses for x (sent / offered of the search stream)."""
    if d not in _JS:
        _JS[d] = {s["step"]: s for s in pool.steps(d)}
    for p in pts:
        xw = w = 0.0
        for st in p["steps"]:
            s = _JS[d][st]
            so = s["streams"]["search"]
            win = so["sent"] / so["offered"] if so["offered"] else s["measure_s"]
            xw += sum(v.get("achieved", 0) or 0 for v in s["streams"].values()) * win
            w += win
        p["xr"] = xw / w if w else 0.0


def tight_ticks(vmax, pad=1.05, min_iv=3, max_iv=6):
    """(top, step) with integer step in {1, 2, 5} x 10^k (also 25, 250, ...): top = multiple of step >= vmax x pad,
    3-6 intervals, smallest such top (user 2026-10-23: the axis ends exactly at its last, labeled tick)."""
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


def y_top_visible(slo, firsts):
    """y axis: SLO at 80-90 % (lstyle.slo_axis), raised when a system's lowest-rate point lies above it so that point
    is inside (user rule 1); then (top, step, raised_for)."""
    top, st = L.slo_axis(slo)
    need = max([0] + [y for y in firsts if y > top])
    if not need:
        return top, st, None
    for stp in (1, 2, 4, 5, 10, 20, 25, 50, 100):
        t = math.ceil(need * 1.08 / stp) * stp
        if 3 <= t / stp <= 6:
            return t, stp, need
    return math.ceil(need * 1.08), max(1, math.ceil(need * 1.08 / 5)), need


def latency_fig(path, panels, nrows, figsize, xlabel, sub, legend_y, adjust, xkey="x", row_x=False):
    """panels: [(key, title, {sys: slo_dir of CURVE_RUN}, {sys: agg})]. Run CURVE_RUN's points joined by lines; no
    marker above the y top (line clipped at the top edge); xkey 'xr' = achieved requests/s. Axis rules (user
    2026-10-23): a system whose points are all above the SLO-based top raises the top until its first point is inside;
    row_x: all panels of a row share the x range (Fig 4); every axis ends at its last labeled tick; plain numbers."""
    from matplotlib.ticker import FixedLocator, FuncFormatter
    fig, axs = plt.subplots(nrows, 3, figsize=figsize)
    fig.subplots_adjust(**adjust)
    flat = list(axs.flat) if nrows > 1 else list(axs)
    rowsout = [("figure", "panel", "system", "offered_total_ops_s", "x_search_per_s", "x_requests_per_s", "p99_ms",
                "p99_norm", "base_ms", "source", "fully_measured", "drawn", "above_y_top", "reason")]
    info, data = {}, []
    for key, title, dirs, meta in panels:
        hyp, nn, mix = meta
        series, xmax, pre, firsts = [], 0, [], []
        curves, colls = {}, {}
        for k, nm, g in S.H1_SYS:
            # knee-sweep curve source (knee_curves.py): run 1 below 0.9 x base (shape filter), sweep points from 0.9 x
            # base (lifetime_ok, not aborted, not after an abort) while achieved search/s still rises (stop at the
            # first fall-back > 5 %); floor panels (no confirmed max in run 1): run 1's lowest step + the sweep points;
            # collapse step (main sweep, else addendum lifetime) for the vertical segment
            curves[k] = K.curve(dirs[k], SWEEP.get((hyp, nn, mix, k)), KPLAN[(hyp, nn, mix, k)],
                                split=bracket_lo(dirs[k]), extra_rows=ADDEND.get((hyp, nn, mix, k)))
            colls[nm] = K.curve.last_collapse
        base = min((p for p in curves["hw"][1] if p["src"].startswith("run1")), key=lambda p: p["offered"])["p"]
        for k, nm, g in S.H1_SYS:
            dr, allp = curves[k]
            pre.append((nm, allp))
            series.append((nm, g, [(p[xkey], min(p["p"], 1e6) / base) for p in dr]))
            xmax = max(xmax, max(p[xkey] for p in dr))
            firsts.append(dr[0]["p"] / base if all(p["p"] / base > L.slo_axis(SLO_MS / base)[0] for p in dr) else 0)
        # x range from the largest DRAWN point (a marker inside the y range), not from points above the top
        top0 = y_top_visible(SLO_MS / base, firsts)[0]
        vis = [t[0] for _, _, pts in series for t in pts if len(t) == 2 and t[1] <= top0]
        xmax = max(vis) if vis else xmax
        data.append((key, title, base, series, xmax, pre, firsts, colls))
    xr_of = {}
    for i, d in enumerate(data):
        grp = [x[4] for j, x in enumerate(data) if (j // 3 == i // 3 if row_x else j == i)]
        xr_of[i] = tight_ticks(max(grp))
    for i, (ax, (key, title, base, series, xmax, pre, firsts, colls)) in enumerate(zip(flat, data)):
        slo = SLO_MS / base
        top, st, raised = y_top_visible(slo, firsts)
        xtop, xst = xr_of[i]
        S.grid(ax)
        vert = {}
        for nm, g, pts in series:
            xs = [p[0] for p in pts]
            ys = [min(p[1], top * 60) for p in pts]
            ax.plot(xs, ys, "-", color=g, lw=S.LW, clip_on=True, zorder=3)
            c = colls.get(nm)
            # the curve ended at a collapsed step whose p99 is above the y top: vertical unmarked segment from the
            # last drawn point to the top edge (only when the line does not already leave the top)
            if c and c["p"] / base > top and ys and ys[-1] <= top:
                ax.plot([xs[-1], xs[-1]], [ys[-1], top * 60], "-", color=g, lw=S.LW, clip_on=True, zorder=3)
                vert[nm] = c
            ins = [(x, y) for x, y, t in zip(xs, ys, pts) if y <= top and len(t) == 2]
            ax.plot([x for x, _ in ins], [y for _, y in ins], "o", ms=S.MS, mfc=g, mec=g, lw=0, zorder=3)
        ax.axhline(slo, color="black", lw=1.6, ls=(0, (4, 2)), zorder=2)
        ax.set_xlim(0, xtop)
        ax.xaxis.set_major_locator(FixedLocator(list(range(0, int(xtop) + 1, xst))))
        ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(round(v))}"))
        ax.set_ylim(0, top)
        ax.yaxis.set_major_locator(FixedLocator([round(j * st, 6) for j in range(int(round(top / st)) + 1)]))
        dec = 0 if float(st).is_integer() else 1
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _, dec=dec: "0" if abs(v) < 1e-12 else f"{v:.{dec}f}"))
        lx, ly, va = L.slo_label_pos(series, slo, top, 0, xtop, 1)
        ax.text(lx, ly, "SLO", ha="right", va=va, fontsize=S.FS)
        ax.set_xlabel(xlabel, labelpad=1)
        if i % 3 == 0:
            ax.set_ylabel("Normalized 99$^{th}$\npercentile latency", labelpad=2)
        S.subcaption(ax, title, y=sub)
        ends = {}
        for nm, allp in pre:
            for p in allp:
                y = p["p"] / base
                rowsout.append((path.split("/")[-1], key, nm, f"{p['offered']:.3f}", f"{p['x']:.4f}", f"{p['xr']:.4f}",
                                f"{p['p']:.3f}", f"{y:.4f}", f"{base:.4f}", p["src"], int(p["full"]), int(p["drawn"]),
                                int(p["drawn"] and y > top), p.get("reason", "")))
            dr = [p for p in allp if p["drawn"]]
            last = dr[-1]["p"] / base
            nxt = next((p for p in allp if p["offered"] > dr[-1]["offered"]), None)
            ends[nm] = ("leaves top" if last > top else ("past SLO, inside" if last > slo else "ends below SLO")) + \
                ("" if nxt is None else f" (next: {'fall-back' if nxt['full'] else 'not fully measured'})")
        info[key] = {"base_ms": base, "slo_frac": slo / top, "y_top": top, "raised": raised is not None,
                     "x_top": xtop, "ends": ends,
                     "collapse": vert,
                     "zigzag": {nm: [round(t[0], 1) for a, t in zip(pts, pts[1:]) if t[0] < a[0]]
                                for nm, _, pts in series if any(t[0] < a[0] for a, t in zip(pts, pts[1:]))}}
    S.series_legend(fig, [(n, g) for _, n, g in S.H1_SYS], y=legend_y)
    S.save(fig, path)
    csv.writer(open(path + ".csv", "w")).writerows(rowsout)
    return info


# ---------------------------------------------------------------- band version helpers (Figs 1 / 4, all runs)
INF_MS = 1e6  # never-completed requests (p99 = inf) are held at 1e6 ms before the log interpolation


def run_curve(slo_dir):
    """One run's drawn curve (pool.py + shape filter + aborted steps, as in the point figures), in offered order;
    points at an equal offered rate (an aborted step at a pooled rate) merged: mean x, max p99."""
    split = bracket_lo(slo_dir)
    pts, keep = points(f"{slo_dir}/loadgen", split)
    by = {}
    for p, kp in zip(pts, keep):
        if kp:
            by.setdefault(round(p["offered"], 3), []).append(p)
    below, above = [], []
    stopped = False
    for o in sorted(by):
        g = by[o]
        rec = (o, sum(p["x"] for p in g) / len(g), min(max(p["p"] for p in g), INF_MS))
        # interpolated curve: in offered order while achieved search/s still rises (also past the knee); it stops at
        # the first step whose throughput falls back (> 2 % below the highest so far) or that the load generator
        # aborted at its queue cap ("saturated"); steps stopped early because the SLO percentile was already exceeded
        # are measured past-SLO points and stay on the curve. Later points are drawn as measured points only.
        if not stopped and (any(p.get("saturated") for p in g)
                            or (below and rec[1] < 0.98 * max(b[1] for b in below))):
            stopped = True
        (above if stopped else below).append(rec)
    return below, above


def interp(curve, o):
    """(x, p99) at offered o by linear interpolation in offered (p99 in log space); None outside the run's range."""
    if not curve or o < curve[0][0] - 1e-9 or o > curve[-1][0] + 1e-9:
        return None
    for (o0, x0, p0), (o1, x1, p1) in zip(curve, curve[1:] + [curve[-1]]):
        if o0 - 1e-9 <= o <= o1 + 1e-9:
            t = 0.0 if o1 == o0 else (o - o0) / (o1 - o0)
            return x0 + t * (x1 - x0), math.exp(math.log(p0) + t * (math.log(p1) - math.log(p0)))
    return None


def band_fig(path, panels, nrows, figsize, xlabel, sub, legend_y, adjust):
    """panels: [(key, title, {sys: [slo_dir per run]})]. Writes <path>.{pdf,png,csv}; returns per-panel info."""
    fig, axs = plt.subplots(nrows, 3, figsize=figsize)
    fig.subplots_adjust(**adjust)
    flat = list(axs.flat) if nrows > 1 else list(axs)
    out = [("figure", "panel", "system", "offered_total_ops_s", "n_runs", "x_mean_search_s", "x_min", "x_max",
            "p99_norm_mean", "p99_norm_min", "p99_norm_max", "base_ms_mean", "drawn_as")
           + tuple(f"run{r}_p99_norm" for r in RUNS)]
    info = {}
    for i, (ax, (key, title, dirs)) in enumerate(zip(flat, panels)):
        rc = {k: [run_curve(d) for d in dirs[k]] for k in ("hw", "pop", "mg")}
        curves = {k: [b for b, _ in v] for k, v in rc.items()}
        aboves = {k: [a for _, a in v] for k, v in rc.items()}
        bases = [c[0][2] for c in curves["hw"]]
        base = sum(bases) / len(bases)
        top, st = L.slo_axis(SLO_MS / base)
        series, xmax, inf = [], 0, {"base_ms_runs": bases, "single_run_points": {}, "clipped": {}}
        for k, nm, g in S.H1_SYS:
            grid_o = sorted({o for c in curves[k] for o, _, _ in c})
            main, single = [], []
            for o in grid_o:
                v = [interp(c, o) for c in curves[k]]
                cov = [x for x in v if x is not None]
                xs = [x for x, _ in cov]
                ps = [p / base for _, p in cov]
                rec = (o, len(cov), sum(xs) / len(xs), min(xs), max(xs), sum(ps) / len(ps), min(ps), max(ps))
                (main if len(cov) >= 2 or len(RUNS) == 1 else single).append(rec)
                out.append((path.split("/")[-1], key, nm, f"{o:.3f}", len(cov), f"{rec[2]:.4f}", f"{rec[3]:.4f}",
                            f"{rec[4]:.4f}", f"{rec[5]:.4f}", f"{rec[6]:.4f}", f"{rec[7]:.4f}", f"{base:.4f}",
                            "band" if len(cov) >= 2 or len(RUNS) == 1 else "single-run dashed")
                           + tuple("" if x is None else f"{x[1] / base:.4f}" for x in v))
            if main:
                xs = [m[2] for m in main]
                ax.fill(xs + xs[::-1], [min(m[6], top * 60) for m in main] + [min(m[7], top * 60) for m in main][::-1],
                        color=g, alpha=0.25, lw=0, zorder=2, clip_on=True)
                ax.plot(xs, [min(m[5], top * 60) for m in main], "-", color=g, lw=S.LW, zorder=3)
            # grid points covered by one run only are omitted (counted in the caption / CSV drawn_as)
            # past the knee: no interpolation; every run's measured points (offered > its confirmed max), points above
            # the top marked on the top edge
            ab = [(x, p / base, r) for r, a in zip(RUNS, aboves[k]) for o, x, p in a]
            for x, y, r in ab:
                out.append((path.split("/")[-1], key, nm, "", 1, f"{x:.4f}", "", "", f"{y:.4f}", "", "", f"{base:.4f}",
                            f"measured past the knee, run {r}") + tuple("" for _ in RUNS))
            if ab:
                ax.plot([x for x, _, _ in ab], [min(y, top) for _, y, _ in ab], "o", ms=S.MS - 0.6, mfc=g, mec=g,
                        lw=0, clip_on=False, zorder=4)
            inf.setdefault("line_end_below_slo", {})[k] = bool(main) and main[-1][5] < SLO_MS / base
            series.append((nm, g, [(m[2], m[5]) for m in main] + [(x, y) for x, y, _ in ab]))
            xmax = max([xmax] + [m[4] for m in main] + [x for x, _, _ in ab])
            inf["past_knee_points"] = inf.get("past_knee_points", {})
            inf["past_knee_points"][k] = len(ab)
            inf["clipped_past_knee"] = inf.get("clipped_past_knee", {})
            inf["clipped_past_knee"][nm] = sum(1 for _, y, _ in ab if y > top)
            inf["single_run_points"][k] = len(single)
            inf["clipped"][nm] = sum(1 for m in main if m[5] > top)
        fac, pre = S.scale_for(xmax * 1.03)
        if fac != 1:
            raise SystemExit("band_fig: x scale factor not supported")
        ax.axhline(SLO_MS / base, color="black", lw=1.6, ls=(0, (4, 2)), zorder=2)
        S.grid(ax)
        S.int_ticks(ax, "x", xmax * 1.03)
        ax.set_ylim(0, top)
        ticks = [round(j * st, 6) for j in range(int(round(top / st)) + 1)]
        dec = 0 if float(st).is_integer() else 1
        ax.yaxis.set_major_locator(S.FixedLocator(ticks))
        ax.yaxis.set_major_formatter(S.FuncFormatter(lambda v, _: "0" if abs(v) < 1e-12 else f"{v:.{dec}f}"))
        xl, xr = ax.get_xlim()
        lx, ly, va = L.slo_label_pos(series, SLO_MS / base, top, xl, xr, 1)
        ax.text(lx, ly, "SLO", ha="right", va=va, fontsize=S.FS)
        ax.set_xlabel(xlabel, labelpad=1)
        if i % 3 == 0:
            ax.set_ylabel("Normalized 99$^{th}$\npercentile latency", labelpad=2)
        S.subcaption(ax, title, y=sub)
        inf.update(base_ms=base, y_axis=(top, st), slo_frac=SLO_MS / base / top)
        info[key] = inf
    from matplotlib.lines import Line2D
    from matplotlib.patches import Rectangle
    hs = [(Rectangle((0, 0), 1, 1, fc=g, alpha=0.25, lw=0), Line2D([0], [0], color=g, lw=S.LW)) for _, _, g in S.H1_SYS]
    fig.legend(hs, [n for _, n, _ in S.H1_SYS], loc="lower center", bbox_to_anchor=(0.5, legend_y), ncol=3,
               handlelength=1.8, columnspacing=1.6, handletextpad=0.4, borderaxespad=0.0)
    S.save(fig, path)
    csv.writer(open(path + ".csv", "w")).writerows(out)
    return info


NGRAY = [(2, "N = 2", S.LIGHT), (4, "N = 4", S.MID), (8, "N = 8", S.BLACK)]


def mix_by_n(vals, hatched, ylabel, path, legend_extra=False):
    fig, ax = plt.subplots(figsize=(3.4, 1.6))
    S.grid(ax)
    w = 0.26
    for gi, (mix, _) in enumerate(MIX):
        for si, (n, _, g) in enumerate(NGRAY):
            a = vals[(mix, n)]
            L.bar(ax, gi + (si - 1) * w, a["v"], w, g, hatched=hatched.get((mix, n), False))
            whisker(ax, gi + (si - 1) * w, a, g)
    lo = min(a["lo"] for a in vals.values())
    hi = max(a["hi"] for a in vals.values())
    S.log_ticks(ax, math.floor(math.log10(lo)), math.ceil(math.log10(hi)))
    ax.set_xticks(range(3))
    ax.set_xticklabels([t.replace(" (", "\n(") for _, t in MIX], fontsize=S.FS)
    ax.tick_params(axis="x", length=0)
    ax.set_xlim(-0.55, 2.55)
    ax.set_ylabel(ylabel, fontsize=S.FS_LABEL, labelpad=2)
    hs = [Patch(fc=g, ec="black", lw=S.BAR_EDGE) for _, _, g in NGRAY]
    lb = [t for _, t, _ in NGRAY]
    if legend_extra:
        hs.append(L.hatched_patch(S.WHITE))
        lb.append("Lowest ramp step")
    ax.legend(hs, lb, loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=len(hs), handlelength=0.9,
              handleheight=0.9, handletextpad=0.4, columnspacing=1.0, borderaxespad=0.1)
    S.save(fig, path)


# ================================================================ Fig 1
if want("fig1"):
    mx1 = {(m, k): agg([fnum(H1[r]["summ"][(k, m)]["confirm_x_mean"]) for r in RUNS], f"Fig 1 {m} {k}")
           for m, _ in MIX for k in ("hw", "pop", "mg")}
    panels = [(m, t, {k: H1[CURVE_RUN]["summ"][(k, m)]["source_dir"] for k in ("hw", "pop", "mg")}, ("H1", 2, m))
              for m, t in MIX]
    i1 = latency_fig(f"{OUT}/fig1-h1-latency", panels, 1, (7.0, 1.45), "Searches per second", -0.40, 0.98,
                     dict(wspace=0.28))
    latency_fig(f"{OUT}/fig1-h1-latency-req", panels, 1, (7.0, 1.45), "Requests per second", -0.40, 0.98,
                dict(wspace=0.28), xkey="xr")
    ratio1 = {}
    for m, _ in MIX:
        for k in ("pop", "mg"):
            ratio1[(m, k)] = agg([fnum(H1[r]["summ"][(k, m)]["confirm_x_mean"])
                                  / fnum(H1[r]["summ"][("hw", m)]["confirm_x_mean"]) for r in RUNS], f"H1 {k}/hw {m}")
    with open(f"{OUT}/fig1-h1-max-under-slo.csv", "w") as f:
        w = csv.writer(f)
        w.writerow(["mix", "system", "stat", "max_under_slo_search_s", "min", "max"] + [f"run{r}" for r in RUNS]
                   + ["ratio_to_hw", "ratio_min", "ratio_max"])
        for (m, k), a in mx1.items():
            rr = ratio1.get((m, k))
            w.writerow([m, k, a["stat"], a["v"], a["lo"], a["hi"]] + a["runs"]
                       + ([rr["v"], rr["lo"], rr["hi"]] if rr else [1, 1, 1]))
    NUM["figs"]["fig1"] = {"panels": i1, "max": {f"{m}-{k}": a for (m, k), a in mx1.items()},
                           "ratio": {f"{m}-{k}": a for (m, k), a in ratio1.items()}}
    # band version (secondary)
    panels = [(m, t, {k: [H1[r]["summ"][(k, m)]["source_dir"] for r in RUNS] for k in ("hw", "pop", "mg")})
              for m, t in MIX]
    NUM["figs"]["fig1_band"] = band_fig(f"{OUT}/fig1-h1-latency-band", panels, 1, (7.0, 1.45), "Searches per second",
                                        -0.40, 0.98, dict(wspace=0.28))

# ================================================================ Fig 2
SYS3 = S.H1_SYS
if want("fig2"):
    f2 = [("load", "mix", "system", "stat", "norm_T", "norm_T_min", "norm_T_max", "norm_C", "norm_rest")
          + tuple(f"norm_T_run{r}" for r in RUNS) + tuple(f"offered_search_s_run{r}" for r in RUNS)]
    n2 = {}
    for load in ("L1", "L2"):
        fig, axs = plt.subplots(1, 3, figsize=(7.0, 1.45))
        fig.subplots_adjust(wspace=0.30, right=0.89)
        groups, whisk = [], []
        for mix, title in MIX:
            bars = []
            for si, (k, n, g) in enumerate(SYS3):
                Ts, Cs, offs = [], [], []
                for r in RUNS:
                    fx = H1[r]["fx"]
                    base = float(fx[("hw", mix, load)]["T_ms_rop"])
                    if k == "hw":
                        T, C = base, 0.0
                    elif k == "mg":
                        T = float(fx[("mgoff", mix, load)]["T_ms_rop"])
                        C = T - base
                    else:
                        T, C = float(fx[("pop", mix, load)]["T_ms_rop"]), float(fx[("pop", mix, load)]["C_ms_rop"])
                    Ts.append(T / base)
                    Cs.append(C / base)
                    offs.append(float(fx[("hw", mix, load)]["offered_x"]))
                aT = agg(Ts, f"Fig 2 {load} {mix} {k}")
                aC = agg(Cs)
                bars.append((n, g, aT["v"], aC["v"]))
                whisk.append((mix, si, aT))
                n2.setdefault(load, {}).setdefault(mix, {})[k] = {"T": aT, "C": aC, "offered": offs}
                f2.append((load, mix, n, aT["stat"], f"{aT['v']:.4f}", f"{aT['lo']:.4f}", f"{aT['hi']:.4f}",
                           f"{aC['v']:.4f}", f"{aT['v'] - aC['v']:.4f}") + tuple(f"{x:.4f}" for x in Ts)
                          + tuple(f"{x:.3f}" for x in offs))
            groups.append((title, bars))
        S.breakdown_row(axs, groups, "Normalized\nsearch latency", fig)
        for mix, si, aT in whisk:
            ax = axs[[m for m, _ in MIX].index(mix)]
            whisker(ax, si, aT, "#FFFFFF")
        S.save(fig, f"{OUT}/fig2-h1-search-breakdown-{load}")
    csv.writer(open(f"{OUT}/fig2-h1-search-breakdown.csv", "w")).writerows(f2)
    NUM["figs"]["fig2"] = n2

# ================================================================ Fig 3
if want("fig3"):
    f3 = [("load", "mix", "system", "stat", "lines_per_search", "min", "max") + tuple(f"run{r}" for r in RUNS)]
    n3 = {}
    for mix, _ in MIX:
        for load in ("L1", "L2"):
            for k in ("mg", "pop"):
                a = agg([fnum(H1[r]["fx"][(k, mix, load)].get("fig3_lines_per_rop")) for r in RUNS],
                        f"Fig 3 {load} {mix} {k}")
                n3[(load, mix, k)] = a
                f3.append((load, mix, k, a["stat"], a["v"], a["lo"], a["hi"]) + tuple(a["runs"]))
    csv.writer(open(f"{OUT}/fig3-h1-flushed-lines-per-search.csv", "w")).writerows(f3)
    for load in ("L1", "L2"):
        fig, ax = plt.subplots(figsize=(3.3, 1.6))
        S.grid(ax)
        w = 0.32
        for si, (n, c, key) in enumerate([("Megalon", S.MID, "mg"), ("Popcorn", S.BLACK, "pop")]):
            for gi, (m, _) in enumerate(MIX):
                x = gi + (si - 0.5) * (w + 0.02)
                a = n3[(load, m, key)]
                ax.bar(x, a["v"], w, color=c, edgecolor="black", lw=S.BAR_EDGE, zorder=3)
                whisker(ax, x, a, c)
        S.log_ticks(ax, 0, 7)
        ax.set_xticks(range(3))
        ax.set_xticklabels([t.replace(" (", "\n(") for _, t in MIX], fontsize=S.FS)
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.55, 2.55)
        ax.set_ylabel("Average flushed cache\nlines per search query", fontsize=S.FS_LABEL, labelpad=2)
        S.bar_legend(ax, [("Megalon", S.MID), ("Popcorn", S.BLACK)], loc="lower center", bbox_to_anchor=(0.5, 1.0),
                     ncol=2, columnspacing=1.6, borderaxespad=0.1)
        S.save(fig, f"{OUT}/fig3-h1-flushed-lines-per-search-{load}")
    NUM["figs"]["fig3"] = {f"{l}-{m}-{k}": a for (l, m, k), a in n3.items()}

# ================================================================ Fig 4
if want("fig4"):
    mx4 = {}
    for m, _ in MIX:
        for n in NS:
            for k in ("hw", "pop", "mg"):
                mx4[(m, n, k)] = agg([fnum(H2[r]["summ"][(n, m, k)]["max_under_slo_search_s"]) for r in RUNS])
    panels = [(f"{m}-n{n}", f"{t}, N = {n}",
               {k: H2[CURVE_RUN]["summ"][(n, m, k)]["source_dir"] for k in ("hw", "pop", "mg")}, ("H2", n, m))
              for m, t in MIX for n in NS]
    i4 = latency_fig(f"{OUT}/fig4-h2-latency", panels, 3, (7.0, 5.2), "Aggregate searches per second", -0.42, 0.945,
                     dict(wspace=0.30, hspace=0.95, top=0.93), row_x=True)
    latency_fig(f"{OUT}/fig4-h2-latency-req", panels, 3, (7.0, 5.2), "Aggregate requests per second", -0.42, 0.945,
                dict(wspace=0.30, hspace=0.95, top=0.93), xkey="xr", row_x=True)
    NUM["figs"]["fig4"] = i4
    NUM["figs"]["fig4_max"] = {f"{m}-n{n}-{k}": a for (m, n, k), a in mx4.items()}
    # band version (secondary)
    panels = [(f"{m}-n{n}", f"{t}, N = {n}", {k: [H2[r]["summ"][(n, m, k)]["source_dir"] for r in RUNS]
                                              for k in ("hw", "pop", "mg")}) for m, t in MIX for n in NS]
    NUM["figs"]["fig4_band"] = band_fig(f"{OUT}/fig4-h2-latency-band", panels, 3, (7.0, 5.2),
                                        "Aggregate searches per second", -0.42, 0.945,
                                        dict(wspace=0.30, hspace=0.95, top=0.93))

# ================================================================ Fig 5
if want("fig5"):
    f5 = [("mix", "N", "system", "stat", "search_s", "min", "max", "hatched_runs", "lowest_step_p99_min_ms",
           "lowest_step_p99_max_ms") + tuple(f"run{r}" for r in RUNS)]
    n5 = {}
    for mix, _ in MIX:
        for n in NS:
            for k in ("hw", "mg", "pop"):
                vals, hat, p99 = [], 0, []
                for r in RUNS:
                    x = H2[r]["summ"][(n, mix, k)]
                    v = fnum(x["max_under_slo_search_s"])
                    if v is None:
                        v = fnum(x["lowest_ramp_search_s"])
                        hat += 1
                        p99.append(fnum(x["lowest_ramp_p99_ms"]))
                    vals.append(v)
                a = agg(vals, f"Fig 5 {mix} N={n} {k}")
                a.update(hatched=hat, p99=(min(p99), max(p99)) if p99 else None)
                if 0 < hat < len(RUNS):
                    NUM["flags"].append(f"Fig 5/7 {mix} N={n} {k}: lowest step in {hat} of {len(RUNS)} runs (mixed)")
                n5[(mix, n, k)] = a
                f5.append((mix, n, k, a["stat"], a["v"], a["lo"], a["hi"], hat, *(a["p99"] or ("", ""))) + tuple(vals))
    csv.writer(open(f"{OUT}/fig5-h2-max-search-under-slo.csv", "w")).writerows(f5)
    fig, axs = plt.subplots(1, 3, figsize=(7.0, 1.6))
    fig.subplots_adjust(wspace=0.30)
    w = 0.26
    for pi, (mix, title) in enumerate(MIX):
        ax = axs[pi]
        S.grid(ax)
        top = S.int_ticks(ax, "y", max(n5[(mix, n, k)]["hi"] for n in NS for k in ("hw", "mg", "pop")) * 1.08)
        for gi, n in enumerate(NS):
            for si, (k, nm, g) in enumerate(S.H1_SYS):
                a = n5[(mix, n, k)]
                x = gi + (si - 1) * w
                L.bar(ax, x, a["v"], w, g, hatched=a["hatched"] > 0)
                whisker(ax, x, a, g)
                if a["p99"]:
                    lo, hi = a["p99"]
                    ax.text(x, a["hi"] + 0.02 * top,
                            f"{lo:.0f}-{hi:.0f} ms" if round(hi) != round(lo) else f"{lo:.0f} ms",
                            rotation=90, ha="center", va="bottom", fontsize=S.FS_TICK_CAT - 0.5)
        ax.set_xticks(range(3))
        ax.set_xticklabels([f"N = {n}" for n in NS], fontsize=S.FS)
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.55, 2.55)
        if pi == 0:
            ax.set_ylabel("Max searches per\nsecond under SLO", fontsize=S.FS_LABEL, labelpad=2)
        S.subcaption(ax, title, y=-0.22)
    hs = [Patch(fc=g, ec="black", lw=S.BAR_EDGE) for _, _, g in S.H1_SYS] + [L.hatched_patch(S.MID)]
    fig.legend(hs, [nm for _, nm, _ in S.H1_SYS] + ["Megalon, lowest ramp step (no rate met the SLO; p99 range above)"],
               loc="lower center", bbox_to_anchor=(0.5, 0.98), ncol=4, handlelength=0.9, handleheight=0.9,
               handletextpad=0.4, columnspacing=1.2, borderaxespad=0.0)
    S.save(fig, f"{OUT}/fig5-h2-max-search-under-slo")
    ratio5 = {(m, n): agg([fnum(H2[r]["summ"][(n, m, "pop")]["max_under_slo_search_s"])
                           / fnum(H2[r]["summ"][(n, m, "hw")]["max_under_slo_search_s"]) for r in RUNS],
                          f"H2 pop/hw {m} N={n}")
              for m, _ in MIX for n in NS}
    NUM["figs"]["fig5"] = {"values": {f"{m}-n{n}-{k}": a for (m, n, k), a in n5.items()},
                           "pop_hw": {f"{m}-n{n}": a for (m, n), a in ratio5.items()}}

# ================================================================ Fig 6a / 6b
if want("fig6"):
    f6 = [("mix", "N", "measure", "stat", "value", "min", "max") + tuple(f"run{r}" for r in RUNS)]
    n6 = {}
    for mix, _ in MIX:
        for n in NS:
            rd, wr, rps = [], [], []
            for r in RUNS:
                x = H2[r]["summ"][(n, mix, "pop")]
                rd.append(fnum(x["faults_read"]))
                wr.append(fnum(x["faults_write"]))
                rps.append(fnum(x["faults_read"]) / fnum(x["max_under_slo_search_s"]))
            for meas, vals in (("read_per_s", rd), ("write_per_s", wr), ("read_per_search", rps)):
                a = agg(vals, f"Fig 6 {mix} N={n} {meas}")
                n6[(mix, n, meas)] = a
                f6.append((mix, n, meas, a["stat"], a["v"], a["lo"], a["hi"]) + tuple(vals))
    csv.writer(open(f"{OUT}/fig6-h2-popcorn-faults.csv", "w")).writerows(f6)
    fig, axs = plt.subplots(1, 3, figsize=(7.0, 1.5))
    fig.subplots_adjust(wspace=0.30)
    w = 0.36
    allv = [a["lo"] for (m, n, me), a in n6.items() if me != "read_per_search"] + \
           [a["hi"] for (m, n, me), a in n6.items() if me != "read_per_search"]
    for pi, (mix, title) in enumerate(MIX):
        ax = axs[pi]
        S.grid(ax)
        for gi, n in enumerate(NS):
            for dx, me, c in ((-w / 2 - 0.01, "read_per_s", S.BLACK), (w / 2 + 0.01, "write_per_s", S.WHITE)):
                a = n6[(mix, n, me)]
                L.bar(ax, gi + dx, a["v"], w, c)
                whisker(ax, gi + dx, a, c)
        S.log_ticks(ax, math.floor(math.log10(min(allv))), math.ceil(math.log10(max(allv))))
        ax.set_xticks(range(3))
        ax.set_xticklabels([f"N = {n}" for n in NS], fontsize=S.FS)
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.55, 2.55)
        if pi == 0:
            ax.set_ylabel("Popcorn page\nfaults per second", fontsize=S.FS_LABEL, labelpad=2)
        S.subcaption(ax, title, y=-0.22)
    S.bar_legend(fig, [("Read faults", S.BLACK), ("Write faults", S.WHITE)], loc="lower center",
                 bbox_to_anchor=(0.5, 0.98), ncol=2, columnspacing=1.6, borderaxespad=0.0)
    S.save(fig, f"{OUT}/fig6a-h2-popcorn-faults-per-s")
    mix_by_n({(m, n): n6[(m, n, "read_per_search")] for m, _ in MIX for n in NS}, {},
             "Popcorn read faults\nper search query", f"{OUT}/fig6b-h2-popcorn-read-faults-per-search")
    NUM["figs"]["fig6"] = {f"{m}-n{n}-{me}": a for (m, n, me), a in n6.items()}

# ================================================================ Fig 7
if want("fig7"):
    f7 = [("mix", "N", "stat", "mg_fetch_per_op", "min", "max", "hatched_runs") + tuple(f"run{r}" for r in RUNS)]
    n7, h7 = {}, {}
    for mix, _ in MIX:
        for n in NS:
            vals, hat = [], 0
            for r in RUNS:
                x = H2[r]["summ"][(n, mix, "mg")]
                if fnum(x["max_under_slo_search_s"]) is not None:
                    vals.append(fnum(x["mg_fetch_per_op"]))
                else:
                    vals.append(fnum(x["lowest_ramp_mg_fetch_per_op"]))
                    hat += 1
            n7[(mix, n)] = agg(vals, f"Fig 7 {mix} N={n}")
            h7[(mix, n)] = hat > 0
            f7.append((mix, n, n7[(mix, n)]["stat"], n7[(mix, n)]["v"], n7[(mix, n)]["lo"], n7[(mix, n)]["hi"], hat)
                      + tuple(vals))
    csv.writer(open(f"{OUT}/fig7-h2-megalon-fetches-per-op.csv", "w")).writerows(f7)
    mix_by_n(n7, h7, "Megalon stale-object\nfetches per operation", f"{OUT}/fig7-h2-megalon-fetches-per-op",
             legend_extra=True)
    NUM["figs"]["fig7"] = {f"{m}-n{n}": dict(a, hatched=h7[(m, n)]) for (m, n), a in n7.items()}

# ================================================================ Fig 8 (fig8b share)
COMP = [("query", "Query processing", "#000000"), ("rq", "Run-queue delay", "#404040"),
        ("e1", "E1 wait (write order)", "#808080"), ("lock", "Segment write-lock wait", "#BFBFBF"),
        ("faults", "Search page faults", "#FFFFFF")]
# Ramp steps per run: {(n, mix, sys): {offered: (step, pass)}}; "both pass" = the fig8.csv per_n rule (checked: it
# reproduces fig8.csv per_n offered_x/steps of runs 1-2 exactly).
RAMP = {}
CONF = {}  # Popcorn confirm window(s) at its max under SLO: steps.csv at_result rows
if want("fig8"):
    for r in RUNS:
        for x in rows(f"{EX}/h2/vdb/h2n/run{r}/steps.csv"):
            if x["phase"] == "ramp" and x["system"] in ("hw", "pop"):
                RAMP.setdefault(r, {}).setdefault((int(x["nodes"]), x["mix"], x["system"]), {})[
                    round(float(x["offered_x"]), 3)] = (x["step"], x["pass"] == "True" and x.get("aborted") != "True")
            if x["system"] == "pop" and x["at_result"] == "True":
                CONF.setdefault((r, int(x["nodes"]), x["mix"]), []).append((x["step"], float(x["offered_x"]),
                                                                             x["phase"]))


def both_pass(r, n, mix):
    hw, pop = RAMP[r][(n, mix, "hw")], RAMP[r][(n, mix, "pop")]
    return {o for o, (_, p) in hw.items() if p and o in pop and pop[o][1]}


def shares_at(r, n, mix, offered, step=None):
    """Five components (ms, share %) of Popcorn search time at one step (default: the ramp step at `offered`)."""
    step = step or RAMP[r][(n, mix, "pop")][offered][0]
    d = H2[r]["summ"][(n, mix, "pop")]["source_dir"]
    t = cause_agg.terms(d, step)
    c = {"faults": t["C_ms"] + t["NT_ms"], "lock": t["lock_ms"], "e1": t["e1_ms"], "rq": t["srch_rq_ms"]}
    c["query"] = t["W_ms"] - sum(c.values())
    if t["missing"]:
        NUM["flags"].append(f"Fig 8 run {r} {mix} N={n} step {step}: missing counters {t['missing']} (counted as 0)")
    if c["query"] < 0:
        NUM["flags"].append(f"Fig 8 run {r} {mix} N={n} step {step}: negative query processing")
    return {k: (100 * v / t["W_ms"], v) for k, v in c.items()}, step, t["W_ms"], d


def fig8_variant(choose, suffix, label):
    """choose(n, mix) -> {run: offered}; writes fig8-h2-popcorn-search-time-share<suffix>.{pdf,png,csv} + loads CSV."""
    f8 = [("mix", "N", "component", "stat", "share_pct", "min", "max") + tuple(f"run{r}_share_pct" for r in RUNS)
          + tuple(f"run{r}_ms" for r in RUNS)]
    f8loads = [("run", "mix", "N", "offered_total_ops_s", "pop_step", "W_ms", "rule", "slo_dir")]
    sh, loads, rules = {}, {}, {}
    for mix, _ in MIX:
        for n in NS:
            pick, rule = choose(n, mix)
            rules[(mix, n)] = rule
            for r in RUNS:
                sel = pick[r] if isinstance(pick[r], list) else [(None, pick[r])]
                per = []
                for step0, off in sel:
                    s_, step, W, d = shares_at(r, n, mix, off, step0)
                    per.append(s_)
                    f8loads.append((r, mix, n, off, step, f"{W:.4f}", rule, d))
                # several windows (e.g. repeated confirms): mean of their shares
                sh[(r, mix, n)] = {k: (sum(p[k][0] for p in per) / len(per), sum(p[k][1] for p in per) / len(per))
                                   for k in per[0]}
                loads.setdefault((mix, n), []).append(sum(o for _, o in sel) / len(sel))
    n8 = {}
    for mix, _ in MIX:
        for n in NS:
            for k, _, _ in COMP:
                a = agg([sh[(r, mix, n)][k][0] for r in RUNS], f"Fig 8{suffix} {mix} N={n} {k}")
                n8[(mix, n, k)] = a
                f8.append((mix, n, k, a["stat"], f"{a['v']:.4f}", f"{a['lo']:.4f}", f"{a['hi']:.4f}")
                          + tuple(f"{sh[(r, mix, n)][k][0]:.4f}" for r in RUNS)
                          + tuple(f"{sh[(r, mix, n)][k][1]:.4f}" for r in RUNS))
    base = f"{OUT}/fig8-h2-popcorn-search-time-share{suffix}"
    csv.writer(open(base + ".csv", "w")).writerows(f8)
    csv.writer(open(f"{OUT}/fig8-h2-loads{suffix}.csv", "w")).writerows(f8loads)
    fig, axs = plt.subplots(1, 3, figsize=(7.0, 1.5))
    fig.subplots_adjust(wspace=0.30, right=0.85)
    for pi, (mix, title) in enumerate(MIX):
        ax = axs[pi]
        S.grid(ax)
        for gi, n in enumerate(NS):
            tot = sum(n8[(mix, n, k)]["v"] for k, _, _ in COMP)  # renormalize the mean shares to 100
            b = 0.0
            for k, _, c in COMP:
                h = 100 * n8[(mix, n, k)]["v"] / tot
                L.bar(ax, gi, h, 0.55, c, bottom=b)
                b += h
        ax.set_xticks(range(3))
        ax.set_xticklabels([f"N = {n}" for n in NS], fontsize=S.FS)
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.6, 2.6)
        S.int_ticks(ax, "y", 100, step=20)
        if pi == 0:
            ax.set_ylabel("Share of search\ntime (%)", fontsize=S.FS_LABEL, labelpad=2)
        S.subcaption(ax, title, y=-0.22)
    S.bar_legend(fig, [(n, c) for _, n, c in COMP[::-1]], loc="center left", bbox_to_anchor=(0.865, 0.55), ncol=1,
                 labelspacing=0.5, borderaxespad=0.0)
    S.save(fig, base)
    return {"label": label, "shares": {f"{m}-n{n}-{k}": a for (m, n, k), a in n8.items()},
            "loads": {f"{m}-n{n}": v for (m, n), v in loads.items()},
            "rules": {f"{m}-n{n}": v for (m, n), v in rules.items()}}


def choose_shared(n, mix):
    common = set.intersection(*[both_pass(r, n, mix) for r in RUNS])
    if common:
        o = max(common)
        return {r: o for r in RUNS}, "shared"
    NUM["flags"].append(f"Fig 8 {mix} N={n}: no ramp rate passed by both systems in every run; per-run per_n rule used")
    return {r: max(both_pass(r, n, mix)) for r in RUNS}, "per-run fallback"


def choose_perrun(n, mix):
    return {r: max(both_pass(r, n, mix)) for r in RUNS}, "per-run"


def choose_confirm(n, mix):
    out = {}
    for r in RUNS:
        c = CONF.get((r, n, mix))
        if not c:
            NUM["flags"].append(f"Fig 8 run {r} {mix} N={n}: no Popcorn confirm step (at_result) in steps.csv")
            out[r] = [(None, max(both_pass(r, n, mix)))]
        else:
            out[r] = [(s, o) for s, o, _ in c]
    return out, "confirm"


if want("fig8"):
    NUM["figs"]["fig8"] = fig8_variant(choose_confirm, "", "Popcorn's own max-under-SLO confirm window")
    NUM["figs"]["fig8_common"] = fig8_variant(choose_shared, "-common-load", "same load across runs")
    NUM["figs"]["fig8_perrun"] = fig8_variant(choose_perrun, "-perrun-load", "per-run per_n load")

tag = "" if set(FIGS) == set(FIGS_ALL) else "-" + "-".join(FIGS)
json.dump(NUM, open(f"{OUT}/numbers{tag}.json", "w"), indent=1, default=str)
for x in NUM["flags"]:
    print("FLAG", x)
if want("fig1"):
    print("H1 ratio", {f"{m}-{k}": fmt(a, 3) for (m, k), a in ratio1.items()})
if want("fig5"):
    print("H2 pop/hw", {f"{m}-n{n}": fmt(a, 3) for (m, n), a in ratio5.items()})

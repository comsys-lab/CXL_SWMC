"""Local wrapper over workspaces/figs-h1h2/style.py for the de-stijl-motivation-isca27 figures.

Only the rules the design doc (reports/experiments/de-stijl-motivation-isca27.md §1.2, §3) changes are here:
- latency-throughput panels: LINEAR y with the SLO line at 80-90 % of the axis height (style.py: 75-85 %);
- every point past the SLO is drawn: the curve leaves through the top of the axis, and every point above the top
  is marked ON the top edge (filled circle, same gray) so it stays visible; the caller counts them for the caption;
- hatched bars (Megalon at the lowest ramp step) whose fill is black get a white hatch, so the hatch stays visible.
Everything else (fonts, grays, grid, ticks, legends, save) comes from style.py unchanged.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # style.py sits next to this file
import style as S  # noqa: E402
from matplotlib.ticker import FixedLocator, FuncFormatter  # noqa: E402

SLO_LO, SLO_HI, SLO_TARGET = 0.80, 0.90, 0.85


def slo_axis(slo):
    """(top, step): SLO at 80-90 % of the height (closest to 85 %), 3-6 intervals; integer top/step, or 0.5 units
    when the normalized SLO is < 5; widened to 78-92 % / 7 intervals if nothing fits."""
    def cands(f_lo, f_hi, unit, max_iv):
        lo, hi = math.ceil(slo / f_hi / unit - 1e-9), math.floor(slo / f_lo / unit + 1e-9)
        tops = sorted((k * unit for k in range(max(lo, 1), hi + 1)), key=lambda t: abs(slo / t - SLO_TARGET))
        steps = (1, 2, 5, 10, 20, 25, 50, 3, 4, 6, 8) if unit == 1 else (0.5, 1)
        for t in tops:
            for st in steps:
                n = t / st
                if abs(n - round(n)) < 1e-9 and 3 <= round(n) <= max_iv:
                    return t, st
        return None
    for f_lo, f_hi, max_iv in ((SLO_LO, SLO_HI, 6), (0.78, 0.92, 7)):
        r = cands(f_lo, f_hi, 1, max_iv) or (cands(f_lo, f_hi, 0.5, 8) if slo < 5 else None)
        if r:
            return r
    t = math.ceil(slo / SLO_TARGET)
    return t, max(1, S.nice_step(t, 6))


def slo_label_pos(series, slo, top, xl, xr, fac, wfrac=0.26, hfrac=0.11):
    """'SLO' label position: the first spot (above the line: right, centre, left, ...; then below the line, same
    order) whose box no curve segment or marker meets (curves with clipped points held at the top edge, plus the
    vertical line segments leaving the axis). Returns (x_right, y, va)."""
    segs = []
    for _, _, pts in series:
        xs = [p[0] / fac for p in pts]
        ys = [min(p[1], top * 60) for p in pts]
        for a in range(len(xs)):
            segs.append((xs[a], min(ys[a], top), xs[a], min(ys[a], top)))
            if a:
                segs.append((xs[a - 1], ys[a - 1], xs[a], ys[a]))
    span = xr - xl
    w, h = wfrac * span, hfrac * top
    px, py = 0.03 * span, 0.03 * top
    rights = (xr - 0.03 * span, xl + 0.5 * span + w / 2, xl + 0.05 * span + w, xl + 0.3 * span + w / 2,
              xl + 0.75 * span + w / 2)
    for below in (False, True):
        for r in rights:
            y0, y1 = (slo - h - py, slo) if below else (slo, slo + h + py)
            if not any(S._seg_hits(a, b, c, e, r - w - px, r + px, y0, y1) for a, b, c, e in segs):
                return (r, slo - 0.02 * top, "top") if below else (r, slo + 0.015 * top, "bottom")
    return xr - 0.03 * span, slo - 0.02 * top, "top"


def latency_panel(ax, series, slo, xmax, xlabel, ylabel=None, axis=None, xlabel_fs=None, xtarget=5, mark_top=True):
    """series: [(name, gray, [(x, y_norm), ...] in offered-rate order)]. Returns ({name: clipped count}, (top, step)).
    mark_top=False (user 2026-10-23, final figures): no marker for a point above the top; its line segment is still
    drawn and clipped at the top edge."""
    top, st = axis or slo_axis(slo)
    fac, pre = S.scale_for(xmax)
    S.grid(ax)
    clipped = {}
    for name, g, pts in series:
        xs = [p[0] / fac for p in pts]
        ys = [min(p[1], top * 60) for p in pts]  # inf (never completed) -> far above the top; the line leaves upward
        if mark_top:
            ax.plot(xs, ys, "-", color=g, lw=S.LW, marker="o", ms=S.MS, mfc=g, mec=g, clip_on=True, zorder=3)
        else:
            ax.plot(xs, ys, "-", color=g, lw=S.LW, clip_on=True, zorder=3)
            inside = [(x, y) for x, y in zip(xs, ys) if y <= top]
            ax.plot([x for x, _ in inside], [y for _, y in inside], "o", ms=S.MS, mfc=g, mec=g, lw=0, zorder=3)
        cx = [x for x, y in zip(xs, ys) if y > top]
        if cx and mark_top:  # points past the top: marked on the top edge
            ax.plot(cx, [top] * len(cx), "o", ms=S.MS, mfc=g, mec=g, clip_on=False, zorder=4)
        clipped[name] = len(cx)
    ax.axhline(slo, color="black", lw=1.6, ls=(0, (4, 2)), zorder=2)
    S.int_ticks(ax, "x", xmax / fac, target=xtarget)
    ax.set_ylim(0, top)
    ticks = [round(k * st, 6) for k in range(int(round(top / st)) + 1)]
    dec = 0 if float(st).is_integer() else 1
    ax.yaxis.set_major_locator(FixedLocator(ticks))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "0" if abs(v) < 1e-12 else f"{v:.{dec}f}"))
    xl, xr = ax.get_xlim()
    lx, ly, va = slo_label_pos(series, slo, top, xl, xr, fac)
    ax.text(lx, ly, "SLO", ha="right", va=va, fontsize=S.FS)
    ax.set_xlabel(f"{xlabel} ({pre.strip()})" if pre else xlabel, labelpad=1, fontsize=xlabel_fs)
    if ylabel:
        ax.set_ylabel(ylabel, labelpad=2)
    return clipped, (top, st)


def bar(ax, x, h, w, color, hatched=False, bottom=0.0):
    """Vertical bar, 1.1 pt black edge; hatched: '////' in black (white on a black fill)."""
    if not hatched:
        return ax.bar(x, h, w, bottom=bottom, color=color, edgecolor="black", lw=S.BAR_EDGE, zorder=3)
    hc = "white" if color.upper() in ("#000000", "BLACK") else "black"
    ax.bar(x, h, w, bottom=bottom, color=color, edgecolor=hc, lw=0, hatch="////", zorder=3)
    return ax.bar(x, h, w, bottom=bottom, fill=False, edgecolor="black", lw=S.BAR_EDGE, zorder=4)


def hatched_patch(color):
    from matplotlib.patches import Patch
    return Patch(fc=color, ec="black", hatch="////", lw=S.BAR_EDGE)


def ensure(d):
    os.makedirs(d, exist_ok=True)
    return d

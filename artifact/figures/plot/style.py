"""Lab paper figure style (reference: hpca2027-paper249.pdf Fig. 8, 10, 11; rules in STYLE.md).

Figures are drawn at print size (double column 7.0 in, single column 3.4 in), so font sizes are real points.
"""
import math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator

FS = 8          # pt: tick labels, axis labels, legend (paper figures: one bold sans size)
FS_CAP = 9      # pt: sub-captions "(a) ..." in serif, as the LaTeX subcaptions of the paper
plt.rcParams.update({
    "font.family": "Liberation Sans", "font.weight": "bold", "font.size": FS,
    "axes.labelweight": "bold", "axes.labelsize": 9, "axes.titleweight": "bold",
    "xtick.labelsize": FS, "ytick.labelsize": FS, "legend.fontsize": FS,
    "axes.linewidth": 1.3, "xtick.major.width": 1.3, "ytick.major.width": 1.3,
    "xtick.major.size": 0, "xtick.minor.size": 0, "ytick.major.size": 0, "ytick.minor.size": 0, "xtick.major.pad": 3, "ytick.major.pad": 3,
    "axes.edgecolor": "black", "legend.frameon": False, "savefig.dpi": 300,
    "pdf.fonttype": 42, "ps.fonttype": 42, "mathtext.fontset": "custom",
    "mathtext.rm": "Liberation Sans:bold", "mathtext.bf": "Liberation Sans:bold", "mathtext.cal": "Liberation Sans:bold",
    "mathtext.it": "Liberation Sans:bold", "mathtext.sf": "Liberation Sans:bold", "mathtext.tt": "Liberation Sans:bold", "mathtext.default": "bf",
    "axes.unicode_minus": False,
})
GRID = "#d9d9d9"

# series grays, left to right: lightest -> black (coordinator/user rule 2026-10-18)
LIGHT, MID, BLACK, WHITE = "#BBBBBB", "#777777", "#000000", "#FFFFFF"
H1_SYS = [("hw", "All-HWcc", LIGHT), ("mg", "Megalon", MID), ("pop", "Popcorn", BLACK)]
H2_SYS = [("hw", "All-HWcc", LIGHT), ("pop", "Popcorn", BLACK)]
LW, MS = 1.8, 3.3   # line width, filled-circle marker size (Fig. 8)
BAR_EDGE = 1.1      # black bar edge width
SLO_FRAC = 0.80     # SLO line at 80 % of the y-axis height


def grid(ax):
    ax.yaxis.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def nice_step(span, target=5):
    """Integer step (1, 2, 5 x 10^k; 25, 250, ...) giving at most `target` intervals."""
    for k in range(0, 10):
        for m in (1, 2, 2.5, 5):
            s = m * 10 ** k
            if s == int(s) and span / s <= target:
                return int(s)
    return int(10 ** 10)


def int_ticks(ax, which, top, step=None, bottom=0, target=5):
    step = step or nice_step(top - bottom, target)
    top = math.ceil(top / step - 1e-9) * step
    ticks = list(range(int(bottom), int(top) + 1, int(step)))
    fmt = FuncFormatter(lambda v, _: f"{int(round(v))}")
    a = ax.xaxis if which == "x" else ax.yaxis
    (ax.set_xlim if which == "x" else ax.set_ylim)(bottom, top)
    a.set_major_locator(FixedLocator(ticks)); a.set_major_formatter(fmt); a.set_minor_locator(NullLocator())
    return top


def log_ticks(ax, lo_exp, hi_exp):
    ax.set_yscale("log"); ax.set_ylim(10 ** lo_exp, 10 ** hi_exp)
    ax.yaxis.set_major_locator(FixedLocator([10 ** e for e in range(lo_exp, hi_exp + 1)]))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"$\\mathbf{{10^{{{int(round(math.log10(v)))}}}}}$"))


def scale_for(vmax):
    """(factor, prefix) so that vmax / factor < 1000 (integer ticks); prefix goes into the axis label."""
    if vmax < 1000:
        return 1, ""
    if vmax < 1e6:
        return 1e3, "×10³ "
    return 1e6, "×10⁶ "


def series_legend(fig, items, y=1.0, ncol=None):
    """Legend above the panels, no frame: line + filled circle per series (Fig. 8)."""
    hs = [Line2D([0], [0], color=g, lw=LW, marker="o", ms=MS + 1, mfc=g, mec=g) for _, g in items]
    fig.legend(hs, [n for n, _ in items], loc="lower center", bbox_to_anchor=(0.5, y), ncol=ncol or len(items),
               handlelength=1.6, columnspacing=1.6, handletextpad=0.4, borderaxespad=0.0)


def bar_legend(fig_or_ax, items, **kw):
    hs = [Patch(fc=c, ec="black", lw=BAR_EDGE) for _, c in items]
    return fig_or_ax.legend(hs, [n for n, _ in items], handlelength=0.9, handleheight=0.9, handletextpad=0.4, **kw)


def slo_axis(slo):
    """y-axis top and tick step for a latency panel: SLO line at 75-85 % of the height (closest to 80 %), integer
    top whose ticks divide it into 3-6 intervals; for small normalized SLOs (< 5) a top in 0.5 steps; if nothing
    fits, the band widens to 73-87 % (3-7 intervals). Returns (top, step)."""
    def cands(f_lo, f_hi, unit, max_iv):
        lo, hi = math.ceil(slo / f_hi / unit - 1e-9), math.floor(slo / f_lo / unit + 1e-9)
        tops = sorted((k * unit for k in range(max(lo, 1), hi + 1)), key=lambda t: abs(slo / t - 0.80))
        steps = (1, 2, 5, 10, 20, 25, 50, 3, 4, 6, 8) if unit == 1 else (0.5, 1)
        for t in tops:
            for st in steps:
                n = t / st
                if abs(n - round(n)) < 1e-9 and 3 <= round(n) <= max_iv:
                    return t, st
        return None
    for f_lo, f_hi, max_iv in ((0.75, 0.85, 6), (0.73, 0.87, 7)):
        r = cands(f_lo, f_hi, 1, max_iv) or (cands(f_lo, f_hi, 0.5, 8) if slo < 5 else None)
        if r:
            return r
    t = math.ceil(slo / 0.8)
    return t, max(1, nice_step(t, 6))


def _seg_hits(ax_, ay, bx, by, x0, x1, y0, y1):
    """Liang-Barsky: does the segment (ax_, ay)-(bx, by) meet the box [x0, x1] x [y0, y1]?"""
    t0, t1 = 0.0, 1.0
    dx, dy = bx - ax_, by - ay
    for p, q in ((-dx, ax_ - x0), (dx, x1 - ax_), (-dy, ay - y0), (dy, y1 - ay)):
        if p == 0:
            if q < 0:
                return False
        else:
            t = q / p
            if p < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
            if t0 > t1:
                return False
    return True


def _slo_label_x(series, slo, top, xl, xr, fac, wfrac=0.24, hfrac=0.16):
    """x of the right edge of the 'SLO' label: the first of right / left / centre positions whose box
    [x-w, x] x [slo, slo + h] no curve passes through (curves sampled densely); right end if none is free."""
    import numpy as np
    w, h = wfrac * (xr - xl), hfrac * top
    segs = []
    for _, _, pts in series:
        xs = [p[0] / fac for p in pts]; ys = [p[1] for p in pts]
        for a in range(len(xs)):
            segs.append((xs[a], ys[a], xs[a], ys[a]))
            if a:
                segs.append((xs[a - 1], ys[a - 1], xs[a], ys[a]))
    span = xr - xl
    pad_x, pad_y = 0.04 * span, 0.04 * top  # line width + marker radius
    for right in (xr - 0.04 * span, xl + 0.5 * span + w / 2, xl + 0.06 * span + w, xl + 0.3 * span + w / 2,
                  xl + 0.75 * span + w / 2):
        x0, x1, y0, y1 = right - w - pad_x, right + pad_x, slo, slo + h + pad_y
        hit = any(_seg_hits(a, b, c, e, x0, x1, y0, y1) for a, b, c, e in segs)
        if not hit:
            return right
    return xr - 0.04 * (xr - xl)


def latency_panel(ax, series, slo, xmax, xlabel_base, xunit, ylabel=None, axis=None):
    """series: [(name, gray, [(x, y), ...] in offered-rate order)], y normalized (or in ms) like slo. SLO dashed
    line + 'SLO' label (Fig. 8); integer y top from slo_axis. Returns {name: number of points above the top}."""
    top, st = axis or slo_axis(slo)
    fac, pre = scale_for(xmax)
    grid(ax)
    clipped = {}
    for name, g, pts in series:
        xs = [p[0] / fac for p in pts]; ys = [p[1] for p in pts]
        ax.plot(xs, ys, "-", color=g, lw=LW, marker="o", ms=MS, mfc=g, mec=g, clip_on=True, zorder=3)
        clipped[name] = sum(1 for y in ys if y > top)
    ax.axhline(slo, color="black", lw=1.6, ls=(0, (4, 2)), zorder=2)
    int_ticks(ax, "x", xmax / fac)
    ax.set_ylim(0, top)
    ticks = [round(k * st, 6) for k in range(int(round(top / st)) + 1)]
    dec = 0 if float(st).is_integer() else 1
    ax.yaxis.set_major_locator(FixedLocator(ticks))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "0" if abs(v) < 1e-12 else f"{v:.{dec}f}"))
    xl, xr = ax.get_xlim()
    ax.text(_slo_label_x(series, slo, top, xl, xr, fac), slo + 0.02 * top, "SLO", ha="right", va="bottom", fontsize=FS)
    ax.set_xlabel(f"{xlabel_base} ({pre}{xunit})" if pre else f"{xlabel_base}", labelpad=1)
    if ylabel:
        ax.set_ylabel(ylabel, labelpad=2)
    return clipped


def subcaption(ax, text, y=-0.40):
    """Scenario name under a panel, same bold sans font as the axes, no "(a)" (user 2026-10-18)."""
    ax.text(0.5, y, text, transform=ax.transAxes, ha="center", va="top", fontsize=9, weight="bold")


def save(fig, path_noext):
    fig.savefig(path_noext + ".pdf", bbox_inches="tight", pad_inches=0.02)
    fig.savefig(path_noext + ".png", bbox_inches="tight", pad_inches=0.02)
    plt.close(fig)


# ---- stacked breakdown panels (user 2026-10-18 on h1-fig2) ----
FS_LABEL = 9          # axis names (x and y), larger than the tick labels
FS_TICK_CAT = 7       # categorical tick labels (system names)
REST_LABEL = "Query processing"  # bottom segment (user 2026-10-18); "Update processing" for update panels


TICK_STEPS = [(1.2, 0.2), (2.5, 0.5), (3.0, 0.5), (4, 1), (5, 1), (6, 1), (8, 2), (10, 2), (12, 2), (15, 5),
              (20, 5), (25, 5), (30, 5), (40, 10), (50, 10), (60, 10), (80, 20), (100, 20)]


def norm_ticks(ax, vmax):
    """Bar y axis from the tallest bar: the smallest (top, step) in TICK_STEPS with top >= tallest bar (e.g. <= 1.2 ->
    0..1.2 by 0.2; <= 2.5 -> by 0.5; then 1, 2, 5, 10, 20 steps), 4-7 intervals, a gray grid line at every tick."""
    for top, step in TICK_STEPS:
        if vmax <= top + 1e-9:
            break
    else:
        step = nice_step(vmax); top = math.ceil(vmax / step) * step
    n = int(round(top / step))
    ticks = [round(k * step, 6) for k in range(n + 1)]
    dec = 0 if step >= 1 else 1
    ax.set_ylim(0, top)
    ax.yaxis.set_major_locator(FixedLocator(ticks)); ax.yaxis.set_minor_locator(NullLocator())
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "0" if abs(v) < 1e-12 else f"{v:.{dec}f}"))


def breakdown_row(axs, groups, ylabel, legend_fig, rest_label=REST_LABEL):
    """groups: [(xlabel, [(system, gray-unused, T_norm, C_norm)])]; Others black (bottom), Coherence white (top)."""
    for ax, (xl, bars) in zip(axs, groups):
        grid(ax)
        vmax = 0
        for si, (n, _, T, C) in enumerate(bars):
            ax.bar(si, T - C, 0.55, color=BLACK, edgecolor="black", lw=BAR_EDGE, zorder=3)
            ax.bar(si, C, 0.55, bottom=T - C, color=WHITE, edgecolor="black", lw=BAR_EDGE, zorder=3)
            vmax = max(vmax, T)
        ax.set_xticks(range(len(bars))); ax.set_xticklabels([b[0] for b in bars], fontsize=FS_TICK_CAT)
        ax.tick_params(axis="x", length=0); ax.set_xlim(-0.6, len(bars) - 0.4)
        norm_ticks(ax, vmax * 1.02)
        ax.set_xlabel(xl, fontsize=FS_LABEL, labelpad=3)
    axs[0].set_ylabel(ylabel, fontsize=FS_LABEL, labelpad=2)
    segs = [("Coherence\nmanagement", WHITE), (rest_label.replace(" ", "\n"), BLACK)]  # top -> bottom
    bar_legend(legend_fig, segs, loc="center left", bbox_to_anchor=(0.905, 0.55), ncol=1, labelspacing=0.8,
               borderaxespad=0.0)

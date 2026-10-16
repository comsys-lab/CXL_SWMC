"""Paper figure style (user reference, 2026-10-16): bold Arial-metric font, grayscale series, thick black frame,
light horizontal grid, legend above the plot without a frame; latency curves normalized to all-HWcc's p99 at the
lowest request rate; breakdown bars normalized to the tallest bar."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

FONT = "Liberation Sans"  # metric-compatible with Arial
plt.rcParams.update({"font.family": FONT, "font.weight": "bold", "font.size": 22, "axes.labelweight": "bold",
                     "axes.titleweight": "bold", "axes.linewidth": 2.0, "xtick.major.width": 2.0,
                     "ytick.major.width": 2.0, "xtick.major.size": 5, "ytick.major.size": 5,
                     "axes.edgecolor": "black", "figure.facecolor": "white", "axes.facecolor": "white",
                     "savefig.facecolor": "white", "legend.frameon": False})
# series order and gray levels as in the reference (worst = lightest, best = black)
SERIES = {"Popcorn": "#bfbfbf", "Megalon": "#7f7f7f", "All HWcc": "#000000"}
STACK = ["white", "#d9d9d9", "#a6a6a6", "#595959", "black"]  # top -> bottom in the legend (5 gray levels)


def curve(path, series, slo, xlabel, ylabel, ylim, xticks, yticks):
    """series: [(name, xs, ys)] in legend order; ys already normalized; slo normalized (dashed line)."""
    fig, ax = plt.subplots(figsize=(10.2, 4.0))
    ax.yaxis.grid(True, color="#d9d9d9", linewidth=1.0)
    ax.set_axisbelow(True)
    for name, xs, ys in series:
        xs, ys = clean_curve(xs, ys, ylim[1])
        ax.plot(xs, ys, color=SERIES[name], linewidth=2.5, marker="o", markersize=6, label=name, clip_on=True)
    ax.axhline(slo, color="black", linestyle=(0, (4, 2)), linewidth=2.5)
    above = slo + (ylim[1] - ylim[0]) * 0.16 < ylim[1]  # label above the line if it fits, else below
    ax.text(xticks[-1] - (xticks[-1] - xticks[0]) * 0.03, slo + (ylim[1] - ylim[0]) * (0.04 if above else -0.04),
            "SLO", ha="right", va="bottom" if above else "top", fontsize=18)
    ax.set_xlim(xticks[0], xticks[-1])
    ax.set_ylim(*ylim)
    ax.set_xticks(xticks)
    ax.set_yticks(yticks)
    ax.set_xlabel(xlabel, fontsize=26)
    ax.set_ylabel(ylabel, fontsize=24, linespacing=0.95)
    for s in ax.spines.values():
        s.set_visible(True)
    ax.legend(ncol=len(series), loc="lower center", bbox_to_anchor=(0.5, 0.98), fontsize=24, handlelength=1.2,
              columnspacing=2.0, handletextpad=0.3, borderaxespad=0.1)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def breakdown(path, bars, components, ylabel="Normalized\nserving latency", hatched=()):
    """bars: [(name, [values per component])] normalized to all-HWcc = 1; components: legend names, top -> bottom
    (the last one is drawn at the bottom). y axis up to the next 0.5 above the tallest bar."""
    import math
    n = len(components)
    cols = STACK[-n:]
    top = max(sum(v) for _, v in bars)
    ymax = max(1.0, math.ceil(top * 2 + 1e-9) / 2)
    step = 0.5 if ymax <= 3 else 1.0
    aw = 1.45 * len(bars)
    fig = plt.figure(figsize=(1.3 + aw + 4.6, 5.0))
    ax = fig.add_axes([1.3 / (5.9 + aw), 0.13, aw / (5.9 + aw), 0.82])
    ax.yaxis.grid(True, color="#d9d9d9", linewidth=1.0)
    ax.set_axisbelow(True)
    for i, (name, vals) in enumerate(bars):
        b = 0
        for j in range(n - 1, -1, -1):  # bottom component first
            v = vals[j]
            if v > 1e-9:
                ax.bar(i, v, 0.55, bottom=b, color=cols[j], edgecolor="black", linewidth=2.5,
                       hatch="//" if (name, j) in hatched else None)
            b += v
    ax.set_xticks(range(len(bars)))
    ax.set_xticklabels([b[0] for b in bars], fontsize=19)
    ax.set_xlim(-0.6, len(bars) - 0.4)
    ax.set_ylim(0, ymax)
    ticks = [round(k * step, 2) for k in range(int(round(ymax / step)) + 1)]
    ax.set_yticks(ticks)
    ax.set_yticklabels(["%g" % t for t in ticks])
    ax.tick_params(axis="y", labelsize=18)
    ax.set_ylabel(ylabel, fontsize=20, linespacing=0.95)
    ax.legend([Patch(facecolor=c, edgecolor="black", linewidth=2) for c in cols], components, loc="center left",
              bbox_to_anchor=(1.02, 0.5), fontsize=18, handlelength=0.9, handleheight=0.9, labelspacing=0.6)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)


# Serving-latency breakdown (user 2026-10-16): each bar partitions that system's own serving time per request at
# the same offered rate; same legend in every figure (top -> bottom); normalized to all-HWcc = 1.
#   Version check (Megalon): read/write section start/end checks + re-execution (sampled section timers)
#   Remote reply wait (Popcorn): coherence-fault time spent waiting for the peer's FETCH/INVALIDATE reply
#   Fault handling (Popcorn): the rest of the coherence-fault handler (dev_dax_swmc_insert)
#   Request processing: everything else in the request (serving time minus the parts above)
COMPONENTS = ["Version check (Megalon)", "Remote reply wait (Popcorn)", "Fault handling (Popcorn)", "Request processing"]


def partition(raw, hw="HWcc"):
    """raw: {system: {"total", "check", "msg", "local"}} -> {system: [check, msg, local, rest]} / all-HWcc total."""
    base = raw[hw]["total"]
    out = {}
    for k, r in raw.items():
        c, m, l = r.get("check", 0.0), r.get("msg", 0.0), r.get("local", 0.0)
        out[k] = [c / base, m / base, l / base, (r["total"] - c - m - l) / base]
    return out


def nice_ylim(slo):
    """y max: the smallest 'nice' value >= 1.4 x the normalized SLO (SLO line visible with headroom); 4-5 ticks."""
    for top, step in ((2, 0.5), (4, 1), (5, 1), (8, 2), (10, 2), (15, 5), (20, 5), (40, 10), (80, 20)):
        if top >= 1.4 * slo:
            return (0, top), [round(k * step, 2) for k in range(int(top / step) + 1)]
    return (0, slo * 1.5), None


def clean_curve(xs, ys, top):
    """Display cleanup (user 2026-10-16: drop jagged points). Sorted by x: (1) points within 3% in x of each other
    (repeated nearby rates: bisect/fill/overload) are merged into their mean; (2) an interior point that is a dip
    (< 0.75 x both neighbours) or a spike (> 1.33 x both neighbours) is dropped; (3) after the first point above the
    y range nothing more is drawn. Returns (xs, ys); the CSV keeps every measured step."""
    pts = sorted(zip(xs, ys))
    groups = []
    for x, y in pts:
        if groups and x <= groups[-1][0][0] * 1.03:
            groups[-1].append((x, y))
        else:
            groups.append([(x, y)])
    pts = [(sum(p[0] for p in g) / len(g), sum(p[1] for p in g) / len(g)) for g in groups]
    changed = True
    while changed and len(pts) > 2:
        changed = False
        for i in range(1, len(pts) - 1):
            a, b, c = pts[i - 1][1], pts[i][1], pts[i + 1][1]
            if b < 0.75 * min(a, c) or b > 1.33 * max(a, c):
                del pts[i]
                changed = True
                break
    out = []
    for x, y in pts:
        out.append((x, y))
        if y > top:
            break
    return [p[0] for p in out], [p[1] for p in out]

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
SERIES = {"Popcorn": "#bfbfbf", "Megalon": "#7f7f7f", "HWcc": "#000000"}
STACK = ["white", "#bfbfbf", "#7f7f7f", "black"]  # top -> bottom in the legend, as in the reference


def curve(path, series, slo, xlabel, ylabel, ylim, xticks, yticks):
    """series: [(name, xs, ys)] in legend order; ys already normalized; slo normalized (dashed line)."""
    fig, ax = plt.subplots(figsize=(10.2, 4.0))
    ax.yaxis.grid(True, color="#d9d9d9", linewidth=1.0)
    ax.set_axisbelow(True)
    for name, xs, ys in series:
        ax.plot(xs, ys, color=SERIES[name], linewidth=2.5, marker="o", markersize=6, label=name, clip_on=True)
    ax.axhline(slo, color="black", linestyle=(0, (4, 2)), linewidth=2.5)
    ax.text(xticks[-1] - (xticks[-1] - xticks[0]) * 0.03, slo + (ylim[1] - ylim[0]) * 0.04, "SLO", ha="right",
            va="bottom", fontsize=18)
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


def breakdown(path, title, bars, components, ymax=1.0):
    """bars: [(name, [values per component])] already normalized; components: legend names, top -> bottom."""
    n = len(components)
    aw = 1.45 * len(bars)  # axes width (in) per bar, legend to the right
    fig = plt.figure(figsize=(1.1 + aw + 4.4, 5.6))
    ax = fig.add_axes([1.1 / (5.5 + aw), 0.12, aw / (5.5 + aw), 0.76])
    ax.yaxis.grid(True, color="#d9d9d9", linewidth=1.0)
    ax.set_axisbelow(True)
    cols = STACK[-n:] if n <= len(STACK) else STACK
    for i, (name, vals) in enumerate(bars):
        b = 0
        for j in range(n - 1, -1, -1):  # draw bottom component first
            v = vals[j]
            if v > 0:
                ax.bar(i, v, 0.55, bottom=b, color=cols[j], edgecolor="black", linewidth=2.5)
            b += v
    ax.set_xticks(range(len(bars)))
    ax.set_xticklabels([b[0] for b in bars], fontsize=19)
    ax.set_xlim(-0.6, len(bars) - 0.4)
    ax.set_ylim(0, ymax)
    ticks = [round(x * 0.2, 1) for x in range(int(ymax / 0.2) + 1)]
    ax.set_yticks(ticks)
    ax.set_yticklabels(["%g" % t for t in ticks])
    ax.tick_params(axis="y", labelsize=18)
    ax.set_title(title, fontsize=22, pad=14)
    ax.legend([Patch(facecolor=c, edgecolor="black", linewidth=2) for c in cols], components, loc="center left",
              bbox_to_anchor=(1.02, 0.5), fontsize=19, handlelength=0.9, handleheight=0.9, labelspacing=0.6)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)

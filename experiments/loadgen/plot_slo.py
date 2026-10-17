#!/usr/bin/env python3
"""Throughput (x) vs tail latency (y) from one or more loadgen runs; one series per run (e.g. per system).

usage: plot_slo.py --out fig.pdf RUN_DIR[=label] ... [--stream search] [--metric pslo_ms|p99_ms] [--logy]
Passing steps are filled markers, failing/aborted steps hollow (an aborted step's tail value is a lower bound);
the SLO is a dashed line, and each run's confirmed max throughput under the SLO a vertical dotted line with its knee
bracket (export_csv.knee_bracket: confirmed max offered rate .. lowest failed offered rate above it; 2026-10-18 "A+C")
as a shaded band on the offered-rate scale. Warmup steps are skipped. Also prints a table of the points and a
"# <label>: knee bracket" line per run.
"""
import argparse, json, math, os, sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from export_csv import knee_bracket  # noqa: E402


def load(run):
    steps = [json.loads(l) for l in open(os.path.join(run, "steps.jsonl"))]
    summ = json.load(open(os.path.join(run, "summary.json")))
    return steps, summ


def num(v):
    return math.inf if v == "inf" else float(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stream", help="stream for y (default: the run's SLO stream)")
    ap.add_argument("--metric", default="pslo_ms")
    ap.add_argument("--logy", action="store_true")
    a = ap.parse_args()
    fig, ax = plt.subplots(figsize=(5, 3.6))
    slo_ms = None
    for i, spec in enumerate(a.runs):
        run, _, label = spec.partition("=")
        steps, summ = load(run)
        label = label or os.path.basename(run.rstrip("/"))
        stream = a.stream or summ.get("slo", {}).get("stream") or next(iter(steps[-1]["streams"]))
        slo_ms = summ.get("slo", {}).get("ms", slo_ms)
        pts = sorted((s["x"], num(s["streams"][stream][a.metric]), s["pass"], s["phase"])
                     for s in steps if s["phase"] != "warmup" and s["measure_s"] > 0)
        c = f"C{i}"
        curve = [(x, min(y, 1e6)) for x, y, _, ph in pts if ph != "confirm"]  # confirm repeats: markers only
        ax.plot([x for x, _ in curve], [y for _, y in curve], "-", color=c, alpha=0.4)
        ax.scatter([x for x, _, p, _ in pts if p], [min(y, 1e6) for _, y, p, _ in pts if p], color=c, label=label)
        ax.scatter([x for x, _, p, _ in pts if not p], [min(y, 1e6) for _, y, p, _ in pts if not p],
                   facecolors="none", edgecolors=c)
        best = summ.get("confirm", {}).get("x_mean")
        if best:
            ax.axvline(best, color=c, ls=":")
        print(f"# {label} ({run}): stream {stream}, {a.metric}; max under SLO (confirm mean) = {best}")
        kb = knee_bracket(summ, steps)
        if kb:
            print(f"# {label}: knee bracket offered [{kb['lo']}, {kb['hi']}] (hi phase {kb['hi_phase'] or '-'}, "
                  f"confirmed {kb['confirmed']}, source {kb['source']})")
            if kb["lo"] and kb["hi"]:
                ax.axvspan(kb["lo"], kb["hi"], color=c, alpha=0.12, lw=0)
        for x, y, p, ph in pts:
            print(f"{label}\t{ph}\t{x:.1f}\t{y:.3f}\t{'pass' if p else 'fail'}")
    if slo_ms:
        ax.axhline(slo_ms, color="k", ls="--", lw=1, label=f"SLO {slo_ms} ms")
    ax.set_xlabel("throughput (req/s)")
    pct = summ.get("slo", {}).get("pct")
    name = f"p{pct:g}" if a.metric == "pslo_ms" and pct else a.metric.replace("_ms", "")
    ax.set_ylabel(f"{name} latency (ms)")
    if a.logy:
        ax.set_yscale("log")
    else:
        top = (slo_ms or 1) * 3
        ax.set_ylim(0, top)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(a.out)
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

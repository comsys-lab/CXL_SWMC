#!/usr/bin/env python3
"""MOT1 v6 Fig 1 (H1): latency vs throughput, one workload x mix per call (reports/MOT1-v6-redesign-draft.md §2).

  x    = achieved rate of step s = completions in the measurement window / window length (loadgen steps.jsonl "x":
         the run's --x-stream, or --x total = sum of all streams' achieved) [requests/s]
  y    = P(step s) / P(all-HWcc lowest-rate step), P = the run's SLO percentile of the SLO stream (pslo_ms: p99, DLRM
         p95), latency = response received - request scheduled on the loadgen clock
  SLO  = SLO ms / the same base
Lowest-rate step = all-HWcc's measured non-warmup step with the smallest offered rate. Curve steps: every measured
step except confirm repeats (ramp, bisect, fill, overload, fixed); paper_style.curve draws them (display cleanup only;
the CSV keeps every step). All runs must share SLO stream and percentile.

usage: v6_fig1_curves.py --out DIR --tag kv-ycsb-b [--xlabel ..] [--xscale 1e-3] [--x x|total]
                         [--xticks 0,20,..] [--ylim 0,4 --yticks 0,1,2,3,4] hw=DIR pop=DIR mg=DIR
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

CURVE_PHASES = ("ramp", "bisect", "fill", "overload", "fixed")


def points(run, xmode):
    out = []
    for s in run.measured():
        if s["phase"] not in CURVE_PHASES:
            continue
        st = s["streams"][run.slo_stream]
        x = s["x"] if xmode == "x" else sum(v["achieved"] for v in s["streams"].values())
        y = st["pslo_ms"]
        y = float("inf") if y == "inf" else y
        out.append({"step": s["step"], "phase": s["phase"], "offered": s["offered_x"], "x": x, "p_ms": y,
                    "pass": s["pass"]})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="SYS=DIR (SYS hw|pop|mg)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--xlabel", default="Requests per second (K)")
    ap.add_argument("--xscale", type=float, default=1e-3)
    ap.add_argument("--x", choices=("x", "total"), default="x")
    ap.add_argument("--xticks")
    ap.add_argument("--ylim")
    ap.add_argument("--yticks")
    a = ap.parse_args()
    runs = {}
    for spec in a.runs:
        k, d, _ = v6.parse_spec(spec)
        runs[k] = v6.Run(d, k)
    if "hw" not in runs:
        sys.exit("Fig 1 needs the all-HWcc run (hw=DIR): it is the normalization base")
    slo = {(r.slo_stream, r.slo_pct, r.slo_ms) for r in runs.values()}
    if len(slo) != 1:
        sys.exit(f"runs disagree on --slo (stream, pct, ms): {sorted(slo)}")
    stream, pct, slo_ms = slo.pop()
    P = {k: points(r, a.x) for k, r in runs.items()}
    base_pt = min(P["hw"], key=lambda p: p["offered"])
    base = base_pt["p_ms"]
    pname = f"p{pct:g}"
    series, rows = [], []
    for k in v6.ORDER:
        if k not in P:
            continue
        pts = sorted(P[k], key=lambda p: p["x"])
        ys = [p["p_ms"] / base for p in pts]
        series.append((v6.SYSTEMS[k], [p["x"] * a.xscale for p in pts], ys, [p["pass"] for p in pts]))
        rows += [[v6.SYSTEMS[k], p["step"], p["phase"], p["offered"], v6.r(p["x"]), p["p_ms"], v6.r(y), p["pass"],
                  runs[k].path] for p, y in zip(pts, ys)]
    slo_n = slo_ms / base
    xmax = max(x for _, xs, _, _ in series for x in xs)
    xticks = [float(t) for t in a.xticks.split(",")] if a.xticks else v6.nice_ticks(xmax * 1.05, 6)
    if a.ylim:
        ylim = tuple(float(t) for t in a.ylim.split(","))
        yticks = [float(t) for t in a.yticks.split(",")] if a.yticks else v6.nice_ticks(ylim[1], 4)
    else:
        ylim, yticks = v6.ps.nice_ylim(slo_n)
        yticks = yticks or v6.nice_ticks(ylim[1], 4)
    os.makedirs(a.out, exist_ok=True)
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig1.{e}") for e in ("png", "csv"))
    v6.ps.curve(png, series, slo_n, a.xlabel, f"Normalized\n{pname} latency", ylim, xticks, yticks)
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 1 latency vs throughput ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", f"x = completions in the step window / window ({'run x-stream' if a.x == 'x' else 'all streams'}) "
                    f"[req/s]; y = {pname}(step) / {pname}(all-HWcc lowest offered rate step) ; SLO line = SLO / same base"),
        ("base", f"all-HWcc step {base_pt['step']} offered {base_pt['offered']}: {pname} = {base} ms; "
                 f"SLO {slo_ms} ms -> {slo_n:.4f}"),
        ("sources", f"loadgen steps.jsonl: x {'x' if a.x == 'x' else 'streams.*.achieved'}, "
                    f"streams.{stream}.pslo_ms ({pname}, --slo {stream}:{pct:g}:{slo_ms:g}), pass, phase, offered_x"),
        ("tags", "achieved_per_s measured; pslo_ms measured; y_norm derived"),
        ("inputs", v6.inputs_line([(v6.SYSTEMS[k], r) for k, r in runs.items()])),
    ], ["system", "step", "phase", "offered", "achieved_per_s", f"{pname}_ms", "y_norm", "pass", "run"], rows)
    print(f"-> {png}\n-> {csvp}  (base {pname} {base} ms, SLO norm {slo_n:.3f})")


if __name__ == "__main__":
    main()

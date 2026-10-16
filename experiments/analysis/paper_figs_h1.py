#!/usr/bin/env python3
"""H1 main-run paper figures (VectorDB 28M, DLRM recommendation system): throughput vs p99 normalized to all-HWcc's
p99 at its lowest request rate, and a serving-time breakdown normalized to the tallest bar at the highest offered
rate that all systems ran and passed (identical ramp rates; user 2026-10-16: no fixed-load windows).
usage: paper_figs_h1.py --root <project root> --out <dir>"""
import argparse, csv, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paper_style as ps

NAMES = {"hw": "HWcc", "pop": "Popcorn", "mg": "Megalon"}
PS_KEY = {"HWcc": "HWcc", "Popcorn": "Popcorn", "Megalon": "Megalon"}
COMPS = ["Coherence processing", "Coherence wait", "Application"]  # legend top -> bottom


def steps(path, stream):
    return [r for r in csv.DictReader(open(path)) if r["stream"] == stream and float(r["achieved"] or 0) > 0
            and r["phase"] in ("ramp", "bisect", "fill", "overload")]  # confirm repeats left out of the curve


def common_step(S):
    """highest offered rate passed by every system with an identical offered rate (same ramp ladder)."""
    sets = [{r["offered"] for r in v if r["pass"] == "True"} for v in S.values()]
    o = max(set.intersection(*sets), key=float)
    return o, {k: next(r for r in v if r["offered"] == o and r["pass"] == "True") for k, v in S.items()}


def write(path, header, rows, note):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["# " + note])
        w.writerow(header)
        w.writerows(rows)


def figure(out, tag, S, xscale, xlabel, slo_ms, xticks, ylim, yticks, comps_of, unit):
    hw0 = min(S["hw"], key=lambda r: float(r["offered"]))
    base = float(hw0["p99_ms"])
    series, rows = [], []
    for s in ("pop", "mg", "hw"):
        if s not in S:
            continue
        v = sorted(S[s], key=lambda r: float(r["offered"]))
        xs, ys = [float(r["achieved"]) * xscale for r in v], [float(r["p99_ms"]) / base for r in v]
        series.append((PS_KEY[NAMES[s]], xs, ys))
        rows += [[NAMES[s], r["step"], r["phase"], r["offered"], r["achieved"], r["p99_ms"], round(y, 3), r["pass"]]
                 for r, y in zip(v, ys)]
    ps.curve(os.path.join(out, f"{tag}-curve.png"), series, slo_ms / base, xlabel, "Normalized\np99 latency", ylim,
             xticks, yticks)
    write(os.path.join(out, f"{tag}-curve.csv"), ["system", "step", "phase", "offered", "achieved", "p99_ms",
          "p99_norm", "pass"], rows,
          f"p99 normalized to all-HWcc p99 at its lowest offered rate ({hw0['offered']}): {base} ms; SLO {slo_ms} ms -> {slo_ms / base:.3f}")
    o, m = common_step(S)
    vals = {s: comps_of(s, m[s]) for s in S}
    top = max(sum(v) for v in vals.values())
    order = [s for s in ("hw", "mg", "pop") if s in S]
    ps.breakdown(os.path.join(out, f"{tag}-breakdown.png"), "Serving time breakdown",
                 [(NAMES[s], [x / top for x in vals[s]]) for s in order], COMPS)
    write(os.path.join(out, f"{tag}-breakdown.csv"), ["system", "step", "offered", "achieved"] + [c + unit for c in COMPS]
          + ["total" + unit, "normalized_total"],
          [[NAMES[s], m[s]["step"], o, m[s]["achieved"]] + [round(x, 4) for x in vals[s]] + [round(sum(vals[s]), 4),
           round(sum(vals[s]) / top, 4)] for s in order],
          f"identical offered rate {o} passed by all systems; normalized to the tallest bar ({top:.4f}{unit})")
    return o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    R = os.path.join(a.root, "recovery")
    os.makedirs(a.out, exist_ok=True)

    # VectorDB 28M (recovery/M4-vdb-h1-v2.1 round 1), search p99 <= 100 ms; per-search server time (wall) split by
    # the coherence share of search-thread busy time (time-share; thread sums x server_ms / busy_ms)
    V = os.path.join(R, "M4-vdb-h1-v2.1", "main")
    S = {s: steps(os.path.join(V, f"{s}-u5-slo-r1", "steps.csv"), "search") for s in ("hw", "pop", "mg")}
    Q = {s: {r["step"]: r for r in csv.DictReader(open(os.path.join(V, f"{s}-u5-slo-r1", "qcoh-steps.csv")))} for s in S}

    def vdb_comps(s, st):
        q = Q[s][st["step"]]
        f = lambda k: float(q[k] or 0)
        scale = f("server_ms_mean") / f("busy_mean_ms") if f("busy_mean_ms") else 0
        wait = f("pf_msg_wait_mean_ms") * scale
        proc = (f("coh_mean_ms") - f("pf_msg_wait_mean_ms")) * scale
        return [proc, wait, f("server_ms_mean") - proc - wait]
    o = figure(a.out, "vdb", S, 1.0, "Searches per second", 100.0, list(range(0, 211, 30)), (0, 40),
               [0, 10, 20, 30, 40], vdb_comps, "_ms")
    print("vdb common offered", o)

    # DLRM recommendation system (recovery/RECSYS-main-h1-v5 hw/pop, -v6 mg), query p99 <= 200 ms (user)
    D = {"hw": os.path.join(R, "RECSYS-main-h1-v5", "hw", "slo-r1"), "pop": os.path.join(R, "RECSYS-main-h1-v5", "pop", "slo-r1"),
         "mg": os.path.join(R, "RECSYS-main-h1-v6", "mg", "slo-r1")}
    D = {s: d for s, d in D.items() if os.path.exists(os.path.join(d, "steps.csv"))}
    S = {s: steps(os.path.join(d, "steps.csv"), "query") for s, d in D.items()}
    B = {s: {r["step"]: r for r in csv.DictReader(open(os.path.join(d, "breakdown.csv")))} for s, d in D.items()}

    def rs_comps(s, st):  # serving task time per query (sum over a query's parallel tasks)
        b = B[s][st["step"]]
        f = lambda k: float(b.get(k) or 0)
        wait = f("serve_fetch_wait_ms_per_query")
        coh = f("serve_coherence_ms_per_query")
        return [coh - wait, wait, f("serve_app_ms_per_query")]
    o = figure(a.out, "dlrm", S, 1.0, "Queries per second", 200.0, list(range(0, 31, 5)), (0, 10),
               [0, 2, 4, 6, 8, 10], rs_comps, "_ms")
    print("dlrm common offered", o, "systems", sorted(S))


if __name__ == "__main__":
    main()

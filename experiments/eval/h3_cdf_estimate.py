#!/usr/bin/env python3
"""Pre-CDF estimate (verifier M2, 2026-10-20; behaviour unchanged, information for the user's decision).

Upper bound of the distinct pages per VM that the CDF hist must hold: the Popcorn SLO lifetime's I->S read faults per
second of that VM at the result (mean over the at_result confirm steps; sys.swmc.instr.fault_full_is.count, else
fault_read_count) x the CDF part's length (window, s) / pfn_mod. Distinct pages <= faults, so the bound is safe; the
hist map holds 2^17 entries per VM (h3-cdf.sh). suggest_pfn_mod = the smallest power of two that brings the largest
bound to <= half the map.
usage: h3_cdf_estimate.py <Popcorn SLO part dir> --nodes N --window-s S [--pfn-mod M] [--map 131072]
Last line: "CDF ESTIMATE fits|MAY OVERFLOW max_bound=<pages> map=<entries> pfn_mod=<M> suggest_pfn_mod=<M'>".
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import canon  # noqa: E402
import export_h3  # noqa: E402


def estimate(part, nodes, window_s, pfn_mod=1, size=131072):
    names = canon.stream_names(part)
    wl = "vdb" if "search" in names else "recsys"
    rows, _ = export_h3.part_rows(part, wl, nodes)
    out = []
    for k in range(nodes):
        rs = [r for r in rows if r["vm"] == str(k) and r["at_result"]]
        v = [r.get("is_faults_per_s") if r.get("is_faults_per_s") is not None else r.get("read_faults_per_s") for r in rs]
        v = [x for x in v if x is not None]
        rate = sum(v) / len(v) if v else None
        out.append((k, len(rs), rate, rate * window_s / pfn_mod if rate is not None else None))
    bounds = [b for _, _, _, b in out if b is not None]
    mx = max(bounds) if bounds else None
    sug = 1
    while mx is not None and mx * pfn_mod / sug > size / 2:
        sug *= 2
    return out, mx, sug


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("part")
    ap.add_argument("--nodes", type=int, required=True)
    ap.add_argument("--window-s", type=float, required=True)
    ap.add_argument("--pfn-mod", type=int, default=1)
    ap.add_argument("--map", type=int, default=131072)
    a = ap.parse_args()
    out, mx, sug = estimate(a.part, a.nodes, a.window_s, a.pfn_mod, a.map)
    for k, n, rate, b in out:
        print(f"vm{k} at_result_steps={n} is_faults_per_s={rate} bound_pages={b}")
    if mx is None:
        print("CDF ESTIMATE unknown (no at_result fault counters)")
        sys.exit(1)
    verdict = "fits" if mx <= a.map else "MAY OVERFLOW"
    print(f"CDF ESTIMATE {verdict} max_bound={mx:.0f} map={a.map} pfn_mod={a.pfn_mod} suggest_pfn_mod={sug} window_s={a.window_s}")


if __name__ == "__main__":
    main()

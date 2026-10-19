#!/usr/bin/env python3
"""Completeness check of one RecSys eval stream block (main-block.sh BLOCK=stream, EVAL_RUN; Host only).

usage: rs_check.py <block dir> --rates "50 100" --slo-systems "hw pop" --fix-systems "hw pop" [--fix-levels "L1 L2"]
FAIL (exit 1): a planned SLO lifetime has no stream-results.tsv row or its loadgen summary is missing; a planned fixed
  lifetime (fix-systems x rates) has no stream-fix.tsv row, unless stream-levels.tsv records that the rate has no
  fixed-load window; no "SEQUENCE DONE" in sequence.log.
WARN: an SLO row with valid=0 (update rate not sustained at or below the result), an unconfirmed SLO search, a fixed
  window with valid != 1. Last line "RSCHECK PASS|FAIL (<n> warnings)"; output also written to <block>/rs-check.txt.
"""
import argparse
import csv
import os
import sys


def tsv(p):
    if not os.path.isfile(p):
        return []
    return [r for r in csv.reader(open(p), delimiter="\t") if r and not r[0].startswith("#")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("block")
    ap.add_argument("--rates", required=True)
    ap.add_argument("--slo-systems", default="")
    ap.add_argument("--fix-systems", default="")
    a = ap.parse_args()
    B, out, nf, nw = a.block, [], 0, 0

    def res(kind, ok, msg):
        nonlocal nf, nw
        if ok:
            out.append(f"OK   {msg}")
        elif kind == "F":
            nf += 1
            out.append(f"FAIL {msg}")
        else:
            nw += 1
            out.append(f"WARN {msg}")

    seq = os.path.join(B, "sequence.log")
    res("F", os.path.isfile(seq) and "SEQUENCE DONE" in open(seq).read(), "sequence.log ends with SEQUENCE DONE")
    sr = {(r[1], r[2]): r for r in tsv(os.path.join(B, "stream-results.tsv"))}
    fx = {}
    for r in tsv(os.path.join(B, "stream-fix.tsv")):
        fx.setdefault((r[1], r[2]), []).append(r)
    lv = {r[0]: r for r in tsv(os.path.join(B, "stream-levels.tsv"))}
    for rate in a.rates.split():
        for s in a.slo_systems.split():
            r = sr.get((s, rate))
            res("F", r is not None and os.path.isfile(os.path.join(B, f"{s}-u{rate}", "slo", "loadgen", "summary.json")),
                f"SLO {s} u{rate} present")
            if r:
                res("W", r[8] == "1", f"SLO {s} u{rate} valid (streamcheck {r[7]})")
                res("W", r[5] == "True", f"SLO {s} u{rate} confirmed (result {r[3] or '-'})")
        for s in a.fix_systems.split():
            w = fx.get((s, rate), [])
            nowin = rate in lv and lv[rate][1] == "-" and not w
            res("F", bool(w) or nowin, f"FIX {s} u{rate}: {len(w)} windows" + (" (no levels at this rate)" if nowin else ""))
            for x in w:
                res("W", x[6] == "1", f"FIX {s} u{rate} {x[3]} at {x[4]} q/s valid={x[6] or '?'}")
    out.append(f"RSCHECK {'FAIL' if nf else 'PASS'} ({nf} failures, {nw} warnings)")
    open(os.path.join(B, "rs-check.txt"), "w").write("\n".join(out) + "\n")
    print("\n".join(out))
    return 1 if nf else 0


if __name__ == "__main__":
    sys.exit(main())

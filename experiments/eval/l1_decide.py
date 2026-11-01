#!/usr/bin/env python3
"""L1 of an eval3 h2n lifetime (h2n-block.sh H2N_L1; experiment de-stijl-evaluation-run1, schedule doc §2).

usage: l1_decide.py --mix u<U> --nodes N --start R <h2n-results.tsv> ...
L1 (offered ops/s) = Megalon's max search/s under the SLO of that mix (column confirm_x_mean of row mg-u<U>-n<N>,
column confirmed True) x 100 / (100 - U), rounded to 2 decimals (the 2026-10-30 fixed-window rule: 97.71 search/s at
u10 -> 108.57 ops/s). The files are read in the given order and a later row wins (callers pass older evidence first
and this block's own h2n-results.tsv last). A row without a confirmed max (start fail, confirm failed, empty x_mean)
gives L1 = R (the ramp start) and append 0: the SLO search's first ramp step is already that point.
Prints one TSV line: L1 append source, where source = <file>:<row name> (<reason>). Exit 1 and prints
"none<TAB>0<TAB>no mg-u<U>-n<N> row" when no file has the row (missing files are skipped).
"""
import argparse
import csv
import os
import sys


def decide(mix, nodes, start, files):
    u = int(mix[1:])
    if not 0 <= u < 100:
        raise ValueError("mix must be u0..u99")
    want = f"mg-{mix}-n{nodes}"
    hit = None
    for f in files:
        if not os.path.isfile(f):
            continue
        with open(f) as fh:
            for r in csv.reader(fh, delimiter="\t"):
                if r and not r[0].startswith("#") and r[0] == want:
                    hit = (f, r)
    if hit is None:
        return None
    f, r = hit
    xm = r[7] if len(r) > 7 else ""
    conf = r[8] if len(r) > 8 else ""
    note = r[9] if len(r) > 9 else ""
    try:
        x = float(xm)
    except ValueError:
        x = 0.0
    if conf == "True" and x > 0:
        return (f"{x * 100.0 / (100 - u):.2f}", 1, f"{f}:{want} (confirm x_mean {xm} search/s, U={u})")
    why = note or (f"confirmed={conf or '-'} x_mean={xm or '-'}")
    return (f"{float(start):g}", 0, f"{f}:{want} (no confirmed max: {why}; L1 = ramp start, no step)")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--mix", required=True)
    ap.add_argument("--nodes", required=True, type=int)
    ap.add_argument("--start", required=True, type=float)
    ap.add_argument("files", nargs="*")
    a = ap.parse_args(argv)
    d = decide(a.mix, a.nodes, a.start, a.files)
    if d is None:
        print(f"none\t0\tno mg-{a.mix}-n{a.nodes} row")
        return 1
    print("\t".join(str(v) for v in d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""L1 of an eval3 h2n lifetime (h2n-block.sh H2N_L1; experiment de-stijl-evaluation-run1, schedule doc §2, outline
"Motivation": L1 = the LOWEST max under SLO of the three baseline systems at that mix).

usage: l1_decide.py --mix u<U> --nodes N --start R [--systems "mg pop hw"] <h2n-results.tsv> ...
For each system S of --systems (default "mg pop hw") the row S-u<U>-n<N> is looked up in the files, read in the given
order (a later row of the same name wins: callers pass older evidence first and this block's own h2n-results.tsv last).
A row's max = column confirm_x_mean when column confirmed is True (search/s). Then:
  - any found row that is a start fail (no confirmed max and no max_offered_x_pass: the ramp start already violates the
    SLO), or an mg row without a confirmed max (B1 rule, unchanged), gives L1 = R (the ramp start) and append 0: the SLO
    search's first ramp step is already that point;
  - otherwise L1 (offered ops/s) = min over the confirmed rows of max x 100 / (100 - U), rounded to 2 decimals (the
    2026-10-30 fixed-window rule: 97.71 search/s at u10 -> 108.57 ops/s), append 1. A pop / hw row with a pass but a
    failed confirm is skipped (named in the source column).
With --systems mg this is exactly the block-B1 rule (Megalon's confirmed max only).
Prints one TSV line: L1 append source, where source = <file>:<row name> (<reason>)[; ...]. Exit 1 and prints
"none<TAB>0<TAB>no <S>-u<U>-n<N> row" when no file has a row of any listed system (missing files are skipped).
"""
import argparse
import csv
import os
import sys

SYSTEMS = ("mg", "pop", "hw")


def _rows(files, wants):
    hit = {}
    for f in files:
        if not os.path.isfile(f):
            continue
        with open(f) as fh:
            for r in csv.reader(fh, delimiter="\t"):
                if r and not r[0].startswith("#") and r[0] in wants:
                    hit[r[0]] = (f, r)
    return hit


def decide(mix, nodes, start, files, systems=SYSTEMS):
    u = int(mix[1:])
    if not 0 <= u < 100:
        raise ValueError("mix must be u0..u99")
    systems = tuple(systems)
    for s in systems:
        if s not in SYSTEMS:
            raise ValueError(f"system {s} not in {SYSTEMS}")
    wants = {f"{s}-{mix}-n{nodes}": s for s in systems}
    hit = _rows(files, wants)
    if not hit:
        return None
    best = None   # (x, file, name, xm)
    skipped = []
    for name in (f"{s}-{mix}-n{nodes}" for s in systems):
        if name not in hit:
            continue
        f, r = hit[name]
        s = wants[name]
        xpass = r[6] if len(r) > 6 else ""
        xm = r[7] if len(r) > 7 else ""
        conf = r[8] if len(r) > 8 else ""
        note = r[9] if len(r) > 9 else ""
        try:
            x = float(xm)
        except ValueError:
            x = 0.0
        if conf == "True" and x > 0:
            if best is None or x < best[0]:
                best = (x, f, name, xm)
            continue
        why = note or (f"confirmed={conf or '-'} x_mean={xm or '-'}")
        if s == "mg" or not xpass.strip():
            return (f"{float(start):g}", 0, f"{f}:{name} (no confirmed max: {why}; L1 = ramp start, no step)")
        skipped.append(f"{f}:{name} skipped (pass {xpass} but no confirmed max: {why})")
    if best is None:
        return (f"{float(start):g}", 0, "; ".join(skipped + ["no confirmed max of any system; L1 = ramp start, no step"]))
    x, f, name, xm = best
    src = f"{f}:{name} (min confirm x_mean {xm} search/s over {','.join(systems)}, U={u})"
    return (f"{x * 100.0 / (100 - u):.2f}", 1, "; ".join([src] + skipped))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--mix", required=True)
    ap.add_argument("--nodes", required=True, type=int)
    ap.add_argument("--start", required=True, type=float)
    ap.add_argument("--systems", default=" ".join(SYSTEMS),
                    help='baseline systems whose minimum max is L1 (default "mg pop hw"; "mg" = block B1 rule)')
    ap.add_argument("files", nargs="*")
    a = ap.parse_args(argv)
    systems = a.systems.split()
    d = decide(a.mix, a.nodes, a.start, a.files, systems)
    if d is None:
        print(f"none\t0\tno {'/'.join(systems)}-{a.mix}-n{a.nodes} row")
        return 1
    print("\t".join(str(v) for v in d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

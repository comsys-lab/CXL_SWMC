#!/usr/bin/env python3
"""Compare object-test ANCHOR-PER-SECTION lines (Megalon build >= 75) of two builds, e.g. the megalon and the hwcc
flavor of one source commit: median per case and field over every node log found, ratio b/a, and PASS if every
ratio lies within [1/F, F] (F = --factor, default 2). Uncontended sections only (object-test phases 7/8).

usage: anchor-compare.py <label_a>=<dir[,dir...] with node*.log files (searched recursively)> <label_b>=<dir[,dir...]>
       [--factor F] [--csv out.csv]   (pass only runs with identical configs and arguments for both labels)
"""
import argparse, csv, glob, os, re, statistics, sys

LINE = re.compile(r"ANCHOR-PER-SECTION (?P<case>[a-zA-Z ]+): sampled (?P<s>\d+) read lookup (?P<rl>[\d.]+) nr (?P<rn>[\d.]+) "
                  r"rseq (?P<rq>[\d.]+) \| writes (?P<w>\d+) lookup (?P<wl>[\d.]+) nr (?P<wn>[\d.]+) wseq (?P<wq>[\d.]+) "
                  r"wseq_end (?P<we>[\d.]+) ns")
READ = [("read_lookup", "rl"), ("read_nr", "rn"), ("rseq", "rq")]
WRITE = [("write_lookup", "wl"), ("write_nr", "wn"), ("wseq", "wq"), ("wseq_end", "we")]


def load(dirs):
    out = {}
    files = [f for d in dirs.split(",") for f in glob.glob(os.path.join(d, "**", "node*.log"), recursive=True)]
    for f in files:
        for line in open(f, errors="replace"):
            m = LINE.search(line)
            if not m:
                continue
            case = m["case"].strip()
            fields = READ if int(m["s"]) > 0 else WRITE if int(m["w"]) > 0 else []
            for name, g in fields:
                out.setdefault((case, name), []).append(float(m[g]))
    return out


ap = argparse.ArgumentParser()
ap.add_argument("a")
ap.add_argument("b")
ap.add_argument("--factor", type=float, default=2.0)
ap.add_argument("--csv")
args = ap.parse_args()
(la, da), (lb, db) = (x.split("=", 1) for x in (args.a, args.b))
A, B = load(da), load(db)
rows, ok = [], True
for key in sorted(set(A) | set(B)):
    a, b = A.get(key, []), B.get(key, [])
    if not a or not b:
        rows.append([*key, len(a), len(b), "", "", "", "MISSING"])
        ok = False
        continue
    ma, mb = statistics.median(a), statistics.median(b)
    r = mb / ma if ma > 0 else float("inf")
    good = 1 / args.factor <= r <= args.factor
    ok &= good
    rows.append([*key, len(a), len(b), f"{ma:.1f}", f"{mb:.1f}", f"{r:.2f}", "ok" if good else "OUT"])
hdr = ["case", "field", f"n_{la}", f"n_{lb}", f"median_{la}_ns", f"median_{lb}_ns", f"ratio_{lb}/{la}", "status"]
if args.csv:
    with open(args.csv, "w", newline="") as f:
        csv.writer(f).writerows([hdr] + rows)
w = [max(len(str(x)) for x in col) for col in zip(hdr, *rows)]
for r in [hdr] + rows:
    print("  ".join(str(x).ljust(n) for x, n in zip(r, w)))
print(f"ANCHOR-COMPARE {'PASS' if ok else 'FAIL'} (factor {args.factor})")
sys.exit(0 if ok else 1)

"""Evidence dirs behind an existing export (for artifact/figures --reexport). Read only.

usage: evidence_dirs.py h1 <h1 export dir>            -> the evidence dirs of slo_summary.csv source_dir (one per line)
       evidence_dirs.py h2 <h2 combined export dir> N -> the evidence dirs of N (summary.csv source_dir, nodes = N)
       evidence_dirs.py knee <knee-pilot.csv>         -> the evidence dir names (column evidence)
       evidence_dirs.py sha <evidence dir>            -> config_sha256 of <evidence dir>/eval-manifest.txt
Prefixes are rewritten with --map OLD=NEW (repeatable, before the positional arguments), as final.py --evidence-map.
"""
import csv
import re
import sys

args = sys.argv[1:]
MAP = []
while args and args[0] == "--map":
    old, _, new = args[1].partition("=")
    MAP.append((old.rstrip("/"), new.rstrip("/")))
    args = args[2:]


def ev(p):
    for old, new in MAP:
        if p == old or p.startswith(old + "/"):
            return new + p[len(old):]
    return p


def rows(path):
    return list(csv.DictReader(l for l in open(path) if not l.startswith("#")))


kind = args[0] if args else ""
if kind == "h1":
    # in the order of first appearance: export.py keeps the order of its evidence arguments (a split run, e.g. eval2
    # run 1 = v2 (u10) then v1 (u50, u90), is re-exported with the same argument order and so the same row order)
    seen = []
    for r in rows(f"{args[1]}/slo_summary.csv"):
        e = ev(r["source_dir"].split("/vdb/r1/")[0])
        if e not in seen:
            seen.append(e)
    print("\n".join(seen))
    raise SystemExit(0)
elif kind == "h2":
    out = {ev(r["source_dir"].split("/block/")[0]) for r in rows(f"{args[1]}/summary.csv") if r["nodes"] == args[2]}
elif kind == "knee":
    out = {r["evidence"] for r in rows(args[1])}
elif kind == "sha":
    m = re.search(r"config_sha256=([0-9a-f]{64})", open(f"{args[1]}/eval-manifest.txt").read())
    if not m:
        raise SystemExit(f"no config_sha256 in {args[1]}/eval-manifest.txt")
    out = {m.group(1)}
else:
    raise SystemExit(__doc__)


def vkey(p):
    m = re.search(r"-v(\d+)$", p)
    return (re.sub(r"-v\d+$", "", p), int(m.group(1)) if m else 0)


for p in sorted(out, key=vkey):
    print(p)

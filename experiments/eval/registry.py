#!/usr/bin/env python3
"""Accepted-run registry of the evaluation run sets (experiments/eval/runs.tsv; evaluation-pipeline rev 3 §4.1).

runs.tsv is append-only, one line per event, tab separated:
  workload runset k evidence_dir config_sha256 status date note
status: started (driver, before the lock) | measured (block and checks done) | stopped (block stopped) |
        accepted (main session, after reviewing the checks) | invalid (main session: never used).
The state of (runset, k, evidence_dir) is its last line. The run k of a run set used by exports and figures is the
evidence dir whose last status is "accepted" (exactly one per runset and k; a second accept needs an invalid first).

usage: registry.py add <workload> <runset> <k> <evidence_dir> <config_sha256> <status> [note]
       registry.py accept <runset> <k> <evidence_dir> [note]     (needs last status measured)
       registry.py invalid <runset> <k> <evidence_dir> <note>
       registry.py get <runset> <k> [--status accepted|measured]  print evidence_dir and config_sha256 (exit 1 if none)
       registry.py list
env EVAL_REGISTRY = the runs.tsv to use (default /home/comsys/sungsu/destijl-control/workspaces/eval-derived/runs.tsv,
outside the code tree, created from the tracked template runs.tsv next to this script on first use: a run never
dirties the tree the drivers require clean; verifier M1). Tests point it elsewhere.
"""
import datetime
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REG = os.environ.get("EVAL_REGISTRY") or "/home/comsys/sungsu/destijl-control/workspaces/eval-derived/runs.tsv"
if not os.path.exists(REG):
    os.makedirs(os.path.dirname(REG), exist_ok=True)
    shutil.copyfile(os.path.join(HERE, "runs.tsv"), REG)
COLS = ["workload", "runset", "k", "evidence_dir", "config_sha256", "status", "date", "note"]
STATUS = ("started", "measured", "stopped", "accepted", "invalid")
WORKLOADS = {"vdb": ("vdb",), "recsys": ("rs-main", "rs-h1")}
# H3 run set per N (RUN-H3.md); new H2 vector DB VM-count scaling per N (h2n-n<N>, RUN-H2N.md)
H3_RUNSET = {"vdb": re.compile(r"h3-vdb-n[2-8]|h2n-n[2-8]"), "recsys": re.compile(r"h3-rs-n[2-8]")}


def valid_runset(w, rs):
    return rs in WORKLOADS.get(w, ()) or bool(w in H3_RUNSET and H3_RUNSET[w].fullmatch(rs))


def rows():
    out = []
    for line in open(REG):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) != len(COLS):
            raise ValueError(f"{REG}: bad line {line!r}")
        out.append(dict(zip(COLS, f)))
    return out


def state():
    st = {}
    for r in rows():
        st[(r["runset"], r["k"], r["evidence_dir"])] = r
    return st


def append(r):
    for c in COLS:
        if "\t" in r[c] or "\n" in r[c]:
            raise ValueError(f"{c} has a tab or newline")
    with open(REG, "a") as f:
        f.write("\t".join(r[c] for c in COLS) + "\n")


def get(runset, k, status="accepted"):
    hits = [r for (rs, kk, _), r in state().items() if rs == runset and kk == str(k) and r["status"] == status]
    if status == "accepted" and len(hits) > 1:
        raise ValueError(f"{runset} run {k}: {len(hits)} accepted evidence dirs")
    return hits[-1] if hits else None


def main(a):
    if len(a) < 2:
        sys.exit(__doc__)
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    if a[1] == "add" and len(a) in (8, 9):
        w, rs, k, d, sha, status = a[2:8]
        if not valid_runset(w, rs) or status not in STATUS or not k.isdigit():
            sys.exit(f"registry.py: bad add {a[2:]}")
        append(dict(workload=w, runset=rs, k=k, evidence_dir=d, config_sha256=sha, status=status, date=now,
                    note=a[8] if len(a) == 9 else ""))
    elif a[1] in ("accept", "invalid") and len(a) in (5, 6):
        rs, k, d = a[2:5]
        cur = state().get((rs, k, d))
        if not cur:
            sys.exit(f"registry.py: {rs} run {k} {d} not registered")
        if a[1] == "accept":
            if cur["status"] != "measured":
                sys.exit(f"registry.py: last status of {d} is {cur['status']}, not measured")
            if get(rs, k):
                sys.exit(f"registry.py: {rs} run {k} already has an accepted dir (mark it invalid first)")
        elif len(a) != 6:
            sys.exit("registry.py: invalid needs a note")
        append(dict(cur, status="accepted" if a[1] == "accept" else "invalid", date=now, note=a[5] if len(a) == 6 else ""))
    elif a[1] == "get" and len(a) in (4, 6):
        r = get(a[2], a[3], a[5] if len(a) == 6 else "accepted")
        if not r:
            sys.exit(1)
        print(r["evidence_dir"], r["config_sha256"])
    elif a[1] == "list":
        for r in state().values():
            print("\t".join(r[c] for c in COLS))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

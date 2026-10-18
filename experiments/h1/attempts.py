#!/usr/bin/env python3
"""H1 main: stage attempts of one workload x round (reports/H1-main-packet.v0.6.8.md §3; user decision 2026-10-18
"응 그렇게 진행해": re-run the stopped r1-recsys in a fresh attempt, the stopped dir stays as evidence).

Layout below the evidence root E (stage dirs are immutable, so a re-run never reuses or renames a dir):
  <E>/<W>/r<n>          attempt 1 (every stage as before)
  <E>/<W>/r<n>-a<k>     attempt k >= 2, written by `h1-main.sh r1-<W> <E> --retry "<reason>"`; it holds
                        attempt.txt (attempt=k, predecessor=r<n> or r<n>-a<k-1>, the predecessor's state, the reason)
                        and, for round 1, its own levels.tsv (+ levels-<mix>.log)
The CURRENT attempt of (W, n) is the highest k; attempts must be contiguous (a2, a3, ...) and each attempt.txt must name
its direct predecessor, otherwise this module refuses (exit 2 / ValueError) instead of guessing. Every consumer reads
the current attempt only: h1-main.sh (stage dir, acceptance precondition, levels for r2/r3, collect), check.py (round
dir, r1 runs and Fig 2 CSVs for n > 1, levels.tsv), collect.py (collect-all skips superseded attempt dirs) and
h1-accept.sh. Without any r<n>-a<k> dir everything resolves to the old paths, byte for byte.
Levels: <E>/<W>/levels.tsv for attempt 1 of r1; <current r1 attempt dir>/levels.tsv when the current r1 attempt is a
retry (a stopped attempt may have written levels.tsv rows of some mixes; they are never reused).

usage: attempts.py dir <E> <W> <n>      print the current attempt dir of round n (<E>/<W>/...; exit 1 if none)
       attempts.py levels <E> <W>       print the levels.tsv path of the workload (current r1 attempt)
       attempts.py next <E> <W> <n>     print the dir name a retry would create (r<n>-a<k+1>; exit 1 if no attempt)
"""
import os
import re
import sys

ATT = re.compile(r"^r(\d+)(?:-a(\d+))?$")


def _attempts(wdir, n):
    """[(k, name)] of round n below wdir, sorted by k (k = 1 for r<n>); ValueError on gaps or bad attempt.txt"""
    out = []
    if os.path.isdir(wdir):
        for e in os.listdir(wdir):
            m = ATT.match(e)
            if m and int(m.group(1)) == n and os.path.isdir(os.path.join(wdir, e)):
                out.append((int(m.group(2)) if m.group(2) else 1, e))
    out.sort()
    for i, (k, e) in enumerate(out):
        if k != i + 1:
            raise ValueError(f"{wdir}: round {n} attempts not contiguous ({[x[1] for x in out]})")
        if k >= 2:
            a = read_attempt(os.path.join(wdir, e))
            if a.get("attempt") != str(k) or a.get("predecessor") != out[i - 1][1] or a.get("round") != str(n):
                raise ValueError(f"{wdir}/{e}/attempt.txt: attempt/round/predecessor do not match the layout ({a})")
    return out


def read_attempt(d):
    p = os.path.join(d, "attempt.txt")
    if not os.path.isfile(p):
        raise ValueError(f"{d}: retry attempt without attempt.txt")
    a = {}
    for line in open(p):
        if "=" in line and not line.startswith("#"):
            k, v = line.rstrip("\n").split("=", 1)
            a.setdefault(k, v)
    return a


def round_dir(E, W, n):
    """current attempt dir of round n of W (the old <E>/<W>/r<n> when no retry exists); None if no attempt"""
    a = _attempts(os.path.join(E, W), int(n))
    return os.path.join(E, W, a[-1][1]) if a else None


def next_name(E, W, n):
    a = _attempts(os.path.join(E, W), int(n))
    return f"r{n}-a{a[-1][0] + 1}" if a else None


def levels_path(E, W):
    d = round_dir(E, W, 1)
    if d and os.path.basename(d) != "r1":
        return os.path.join(d, "levels.tsv")
    return os.path.join(E, W, "levels.tsv")


def superseded(wdir):
    """names of the attempt dirs directly below a workload dir that are NOT the current attempt of their round"""
    rounds = set()
    if os.path.isdir(wdir):
        for e in os.listdir(wdir):
            m = ATT.match(e)
            if m and os.path.isdir(os.path.join(wdir, e)):
                rounds.add(int(m.group(1)))
    out = set()
    for n in rounds:
        out.update(e for _, e in _attempts(wdir, n)[:-1])
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if len(a) == 4 and a[0] == "dir":
            d = round_dir(a[1], a[2], a[3])
            if not d:
                sys.exit(1)
            print(d)
        elif len(a) == 3 and a[0] == "levels":
            print(levels_path(a[1], a[2]))
        elif len(a) == 4 and a[0] == "next":
            x = next_name(a[1], a[2], a[3])
            if not x:
                sys.exit(1)
            print(x)
        else:
            sys.exit(__doc__)
    except ValueError as ex:
        print(f"ATTEMPTS ERROR: {ex}", file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env python3
"""Rate of the run-2 fault-breakdown step "pmax" (h2n-block.sh H2N_PMAX; user 2026-11-03 Q9: Popcorn and De Stijl at
the SAME load = Popcorn's max under the SLO of the cell, state/PROJECT.md "Evaluation run 2").

usage: pmax_decide.py --mix u<U> --nodes N [--suffix=-r<j>] [--summary <pop slo summary.json>] [--from <h2n-results.tsv>]...
                      [--log FILE] [--emit tsv|rate] [part]
Source of Popcorn's max, first hit wins:
  --summary  the pop lifetime's own slo part (loadgen summary.json; run.sh calls this right after the slo part, so the
             step runs inside the same server lifetime)
  --from     h2n-results.tsv files (ds lifetimes: the pop block of the same run), read in the given order, a later row
             of the same name wins; row name pop-<mix>-n<N><suffix>, then pop-<mix>-n<N> (suffix = the ds lifetime's
             repeat -r<j>, so run j of ds uses run j of pop when one evidence dir holds several repeats)
Rule (as l1_decide.py, --systems pop): a confirmed max (confirmed True, confirm x_mean > 0, search/s) gives the offered
total rate x * 100 / (100 - U) rounded to 2 decimals, append 1; anything else (no row, start fail, confirm failed)
gives append 0 = no step (the reason is the source text).
--emit tsv (default): prints "rate<TAB>append<TAB>source" (rate "none" when append 0); --emit rate (run.sh
PART_RATE_CMD): prints the rate or "skip" and appends the tsv line to --log. The trailing positional (run.sh passes the
part name) is recorded in the log line only. Exit 0 in every decided case, 2 on bad arguments / unreadable summary.
"""
import argparse
import csv
import json
import os
import sys


def from_summary(path):
    with open(path) as f:
        s = json.load(f)
    c = s.get("confirm") or {}
    return {"xm": c.get("x_mean"), "conf": s.get("confirmed"), "xpass": s.get("max_offered_x_pass"), "note": s.get("note", "")}


def from_rows(files, names):
    hit = {}
    for f in files:
        if not os.path.isfile(f):
            continue
        with open(f) as fh:
            for r in csv.reader(fh, delimiter="\t"):
                if r and not r[0].startswith("#") and r[0] in names:
                    hit[r[0]] = (f, r)
    for n in names:
        if n in hit:
            f, r = hit[n]
            g = lambda i: r[i] if len(r) > i else ""
            return f"{f}:{n}", {"xm": g(7), "conf": g(8) == "True", "xpass": g(6), "note": g(9)}
    return None, None


def decide(mix, row, src):
    u = int(mix[1:])
    if not 0 <= u < 100:
        raise ValueError("mix must be u0..u99")
    try:
        x = float(row["xm"])
    except (TypeError, ValueError):
        x = 0.0
    if row["conf"] is True and x > 0:
        return f"{x * 100.0 / (100 - u):.2f}", 1, f"{src} (pop confirm x_mean {row['xm']} search/s, U={u})"
    why = row.get("note") or f"confirmed={row['conf']} x_mean={row['xm'] or '-'} pass={row['xpass'] or '-'}"
    return "none", 0, f"{src} (no confirmed Popcorn max: {why}; no pmax step)"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--mix", required=True)
    ap.add_argument("--nodes", required=True, type=int)
    ap.add_argument("--suffix", default="")
    ap.add_argument("--summary")
    ap.add_argument("--from", dest="files", action="append", default=[])
    ap.add_argument("--log")
    ap.add_argument("--emit", choices=("tsv", "rate"), default="tsv")
    ap.add_argument("part", nargs="?", default="")
    a = ap.parse_args(argv)
    if a.suffix and not a.suffix.startswith("-r"):
        ap.error("--suffix is -r<j>")
    if a.summary:
        if not os.path.isfile(a.summary):
            d = ("none", 0, f"{a.summary} missing (slo part without output; no pmax step)")
        else:
            try:
                d = decide(a.mix, from_summary(a.summary), a.summary)
            except (ValueError, json.JSONDecodeError) as e:
                print(f"pmax_decide: {a.summary}: {e}", file=sys.stderr)
                return 2
    else:
        base = f"pop-{a.mix}-n{a.nodes}"
        src, row = from_rows(a.files, ([base + a.suffix] if a.suffix else []) + [base])
        d = decide(a.mix, row, src) if row else ("none", 0, f"no {base}{a.suffix or ''} row in [{' '.join(a.files)}]; no pmax step")
    line = "\t".join(str(v) for v in d)
    if a.log:
        with open(a.log, "a") as f:
            f.write(line + (f"\tpart={a.part}" if a.part else "") + "\n")
    if a.emit == "rate":
        print(d[0] if d[1] == 1 else "skip")
    else:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

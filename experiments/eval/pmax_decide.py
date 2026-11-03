#!/usr/bin/env python3
"""Rate of the run-2 fault-breakdown step "pmax" (user 2026-11-03 Q9: Popcorn and De Stijl at the SAME load =
Popcorn's max under the SLO of the cell, state/PROJECT.md "Evaluation run 2"). Callers: vector DB h2n-block.sh
H2N_PMAX, RecSys experiments/recsys/main-block.sh STREAM_PMAX, RocksDB experiments/rocksdb/pilot-run.sh PMAX.

usage: pmax_decide.py [--workload vectordb|recsys|rocksdb] --mix u<U> [--nodes N] [--suffix=-r<j>]
                      [--summary <pop slo summary.json>] [--from <results.tsv>]... [--log FILE] [--emit tsv|rate] [part]
Source of Popcorn's max, first hit wins:
  --summary  the pop lifetime's own slo part (loadgen summary.json; the caller runs this right after the slo part, so
             the step runs inside the same server lifetime). vectordb and rocksdb only.
  --from     results files, read in the given order, a later row of the same name wins:
               vectordb  h2n-results.tsv (ds lifetimes: the pop block of the same run); row pop-<mix>-n<N><suffix>, then
                         pop-<mix>-n<N> (suffix = the ds lifetime's repeat -r<j>)
               rocksdb   rocks-results.tsv (runset-rocks.sh, slo_result.py; same columns 0..9 as h2n-results.tsv); row
                         pop-<mix>-n<N>
               recsys    stream-results.tsv (main-block.sh: name system rate_sps result_q_s confirm_x_mean confirmed
                         low_rate_violations streamcheck valid ...); row pop-<mix> (mix u<R> = the update rate in
                         samples/s); --nodes unused. A pop lifetime reads its own block's tsv (its slo row was written
                         right before), a ds lifetime the rs-main block of the same run.
Rule (as l1_decide.py, --systems pop): a confirmed max (confirmed True, confirm x_mean > 0; RecSys also valid = 1,
the update stream sustained, as main-block.sh eval_levels_compute) gives the step's offered rate, append 1:
  vectordb  total ops/s = x * 100 / (100 - U) (x = search/s, U = update percent of the mix)
  rocksdb   x (the mixed request stream is the whole load; loadgen --mode fixed --rates = total requests/s)
  recsys    x (query/s of the x-stream query; the update stream stays at its fixed rate)
rounded to 2 decimals. Anything else (no row, start fail, confirm failed, invalid stream) gives append 0 = no step
(the reason is the source text).
--emit tsv (default): prints "rate<TAB>append<TAB>source" (rate "none" when append 0); --emit rate (PART_RATE_CMD
style): prints the rate or "skip" and appends the tsv line to --log. The trailing positional (the part name) is
recorded in the log line only. Exit 0 in every decided case, 2 on bad arguments / unreadable summary.
"""
import argparse
import csv
import json
import os
import re
import sys


def from_summary(path):
    with open(path) as f:
        s = json.load(f)
    c = s.get("confirm") or {}
    return {"xm": c.get("x_mean"), "conf": s.get("confirmed"), "xpass": s.get("max_offered_x_pass"), "note": s.get("note", ""),
            "valid": None}


# column indices per results format: x_mean, confirmed, max pass, note, valid (None = no column)
COLS = {"vectordb": (7, 8, 6, 9, None), "rocksdb": (7, 8, 6, 9, None), "recsys": (4, 5, 3, 11, 8)}


def from_rows(files, names, wl):
    hit = {}
    for f in files:
        if not os.path.isfile(f):
            continue
        with open(f) as fh:
            for r in csv.reader(fh, delimiter="\t"):
                if r and not r[0].startswith("#") and r[0] in names:
                    hit[r[0]] = (f, r)
    ixm, icf, ixp, ino, iva = COLS[wl]
    for n in names:
        if n in hit:
            f, r = hit[n]
            g = lambda i: r[i] if i is not None and len(r) > i else ""
            return f"{f}:{n}", {"xm": g(ixm), "conf": g(icf) == "True", "xpass": g(ixp), "note": g(ino),
                                "valid": None if iva is None else g(iva)}
    return None, None


def decide(wl, mix, row, src):
    u = int(mix[1:])
    if wl == "vectordb" and not 0 <= u < 100:
        raise ValueError("mix must be u0..u99")
    try:
        x = float(row["xm"])
    except (TypeError, ValueError):
        x = 0.0
    valid = row.get("valid")
    if row["conf"] is True and x > 0 and valid in (None, "1"):
        if wl == "vectordb":
            return f"{x * 100.0 / (100 - u):.2f}", 1, f"{src} (pop confirm x_mean {row['xm']} search/s, U={u})"
        unit = "query/s" if wl == "recsys" else "requests/s"
        return f"{x:.2f}", 1, f"{src} (pop confirm x_mean {row['xm']} {unit})"
    if row["conf"] is True and x > 0:
        why = f"valid={valid} (update stream not sustained)"
    else:
        why = row.get("note") or f"confirmed={row['conf']} x_mean={row['xm'] or '-'} pass={row['xpass'] or '-'}"
    return "none", 0, f"{src} (no confirmed Popcorn max: {why}; no pmax step)"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--workload", choices=("vectordb", "recsys", "rocksdb"), default="vectordb")
    ap.add_argument("--mix", required=True)
    ap.add_argument("--nodes", type=int)
    ap.add_argument("--suffix", default="")
    ap.add_argument("--summary")
    ap.add_argument("--from", dest="files", action="append", default=[])
    ap.add_argument("--log")
    ap.add_argument("--emit", choices=("tsv", "rate"), default="tsv")
    ap.add_argument("part", nargs="?", default="")
    a = ap.parse_args(argv)
    wl = a.workload
    if not re.fullmatch(r"u\d+", a.mix):
        ap.error("--mix is u<n>")
    if a.suffix and not a.suffix.startswith("-r"):
        ap.error("--suffix is -r<j>")
    if wl != "recsys" and a.nodes is None:
        ap.error(f"--nodes is required for --workload {wl}")
    if wl == "recsys" and a.summary:
        ap.error("--workload recsys reads stream-results.tsv rows (--from), not --summary (validity is in the row)")
    if a.summary:
        if not os.path.isfile(a.summary):
            d = ("none", 0, f"{a.summary} missing (slo part without output; no pmax step)")
        else:
            try:
                d = decide(wl, a.mix, from_summary(a.summary), a.summary)
            except (ValueError, json.JSONDecodeError) as e:
                print(f"pmax_decide: {a.summary}: {e}", file=sys.stderr)
                return 2
    else:
        base = f"pop-{a.mix}" if wl == "recsys" else f"pop-{a.mix}-n{a.nodes}"
        src, row = from_rows(a.files, ([base + a.suffix] if a.suffix else []) + [base], wl)
        try:
            d = decide(wl, a.mix, row, src) if row else ("none", 0, f"no {base}{a.suffix or ''} row in [{' '.join(a.files)}]; no pmax step")
        except ValueError as e:
            print(f"pmax_decide: {e}", file=sys.stderr)
            return 2
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

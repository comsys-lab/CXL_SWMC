#!/usr/bin/env python3
"""faultlat ksharer summary: one CSV row per (k, mode) cell of ksharer.sh output.

Usage: ksharer_summary.py --dir <writer step dir> --system S --build B --knobs K --n N --mode M --k K
                          [--status-dir D --status-pre TAG --status-post TAG --nodes N]
                          [--counters inv_wait_spins,inv_self_remove_retries] [--evidence E] --csv <out.csv>

Reads the node-0 writer raw files <dir>/k<k>_<mode>_r<r>_write.csv (faultlat access --thread-stat; pass column 0 =
the write step) of every round r, pools all samples of the cell and appends one row to --csv (header written when the
file is new or empty; an existing file must carry the same header):
  write_p50_us / write_p99_us        per-write latency (faultlat timed interval, ns column)
  inv_wait_p50_us / inv_wait_p99_us  per-write delta of write_msg_wait_ns (Popcorn: request round send -> last
                                     response; De Stijl: INV produce + directory poll until every holder acknowledged,
                                     + waits inside the directory acquire)
  <counter>_delta                    sum over the N nodes of the De Stijl counter ds.<counter> between the status
                                     snapshots TAG pre and post (p-*-shm.sh status: <status-dir>/status-<TAG>-vm<j>.txt);
                                     empty when the counter is absent (Popcorn, De Stijl build 10)
  bad_samples                        samples whose write_faults delta is not 1 (no fault or two faults in one access)
  tx_per_write_mean                  mean write_transactions delta (1 = one round per write; > 1 = NACK retries)
  errors                             sum of the error counter deltas (swmc transaction_error_count, send_drop_count,
                                     late_response_count, ds protocol_error, tx_timeout) + new dmesg BUG/Oops/WARNING
Percentiles: the faultlat rule (sorted v, index min(n - 1, floor(p * n))).
"""
import argparse
import csv
import math
import os
import re
import sys

HEADER = ["system", "build", "knobs", "k", "n", "write_p50_us", "write_p99_us", "inv_wait_p50_us", "inv_wait_p99_us",
          "inv_wait_spins_delta", "inv_self_remove_retries_delta", "mode", "samples", "rounds", "bad_samples",
          "tx_per_write_mean", "inv_wait_mean_us", "write_mean_us", "errors", "evidence"]
ERRS = ["swmc.transaction_error_count", "swmc.send_drop_count", "swmc.late_response_count", "ds.protocol_error",
        "ds.tx_timeout"]


def pct(v, p):
    return v[min(len(v) - 1, int(math.floor(p * len(v))))]


def read_raw(path):
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        need = {"pass", "index", "ns", "write_msg_wait_ns", "write_faults", "write_transactions"}
        miss = need - set(r.fieldnames or [])
        if miss:
            raise SystemExit(f"{path}: columns {sorted(miss)} missing (faultlat access --thread-stat keys)")
        return [row for row in r if row["pass"] == "0"]


def kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            if "=" in line and not line.startswith("dmesg: "):
                k, v = line.rstrip("\n").split("=", 1)
                d[k] = v
    return d


def delta(b, a, key):
    try:
        return int(a[key]) - int(b[key])
    except (KeyError, ValueError):
        return None


def main(argv=None):
    ap = argparse.ArgumentParser()
    for o in ("--dir", "--system", "--build", "--knobs", "--mode", "--csv"):
        ap.add_argument(o, required=True)
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--k", type=int, required=True)
    ap.add_argument("--status-dir")
    ap.add_argument("--status-pre")
    ap.add_argument("--status-post")
    ap.add_argument("--nodes", type=int)
    ap.add_argument("--counters", default="inv_wait_spins,inv_self_remove_retries")
    ap.add_argument("--evidence", default="")
    a = ap.parse_args(argv)
    pat = re.compile(r"^k%d_%s_r(\d+)_write\.csv$" % (a.k, re.escape(a.mode)))
    files = sorted((int(m.group(1)), f) for f in os.listdir(a.dir) for m in [pat.match(f)] if m)
    if not files:
        raise SystemExit(f"no k{a.k}_{a.mode}_r*_write.csv in {a.dir}")
    rounds = [r for r, _ in files]
    if rounds != list(range(len(rounds))):
        raise SystemExit(f"rounds {rounds} are not 0..{len(rounds) - 1}")
    lat, wait, bad, tx = [], [], 0, []
    for _, f in files:
        for row in read_raw(os.path.join(a.dir, f)):
            lat.append(int(row["ns"]))
            wait.append(int(row["write_msg_wait_ns"]))
            tx.append(int(row["write_transactions"]))
            if int(row["write_faults"]) != 1:
                bad += 1
    lat.sort()
    wait.sort()
    us = lambda x: "%.2f" % (x / 1000.0)
    cnt = {c: "" for c in a.counters.split(",") if c}
    errors = 0
    if a.status_dir:
        n = a.nodes or a.n
        sums = {c: None for c in cnt}
        for j in range(n):
            pb = os.path.join(a.status_dir, f"status-{a.status_pre}-vm{j}.txt")
            pa = os.path.join(a.status_dir, f"status-{a.status_post}-vm{j}.txt")
            if not (os.path.exists(pb) and os.path.exists(pa)):
                raise SystemExit(f"status snapshots missing for vm{j}: {pb} / {pa}")
            b, af = kv(pb), kv(pa)
            for c in cnt:
                d = delta(b, af, "ds." + c)
                if d is not None:
                    sums[c] = (sums[c] or 0) + d
            for e in ERRS:
                d = delta(b, af, e)
                errors += d or 0
            d = delta(b, af, "dmesg_bad")
            errors += max(d or 0, 0)
        cnt = {c: ("" if v is None else str(v)) for c, v in sums.items()}
    row = {"system": a.system, "build": a.build, "knobs": a.knobs, "k": a.k, "n": a.n,
           "write_p50_us": us(pct(lat, 0.50)), "write_p99_us": us(pct(lat, 0.99)),
           "inv_wait_p50_us": us(pct(wait, 0.50)), "inv_wait_p99_us": us(pct(wait, 0.99)),
           "inv_wait_spins_delta": cnt.get("inv_wait_spins", ""),
           "inv_self_remove_retries_delta": cnt.get("inv_self_remove_retries", ""),
           "mode": a.mode, "samples": len(lat), "rounds": len(files), "bad_samples": bad,
           "tx_per_write_mean": "%.3f" % (sum(tx) / len(tx)), "inv_wait_mean_us": us(sum(wait) / len(wait)),
           "write_mean_us": us(sum(lat) / len(lat)), "errors": errors, "evidence": a.evidence}
    new = not os.path.exists(a.csv) or os.path.getsize(a.csv) == 0
    if not new:
        with open(a.csv, newline="") as f:
            h = next(csv.reader(f), [])
        if h != HEADER:
            raise SystemExit(f"{a.csv}: header differs from {HEADER}")
    with open(a.csv, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=HEADER)
        if new:
            w.writeheader()
        w.writerow(row)
    print(",".join(str(row[h]) for h in HEADER))
    return 0


if __name__ == "__main__":
    sys.exit(main())

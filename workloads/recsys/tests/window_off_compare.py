#!/usr/bin/env python3
"""Default-off check of the windowed publisher (--publish-window-s unset): compare two tests/v7_host_test.sh work dirs
run with --train-batch 1 (BATCH=1: every batch is one sample, so the rows written per sample do not depend on timing),
one with the build before the change (A) and one with the new build (B).

usage: window_off_compare.py <work dir A> <work dir B>
Checks per node (stop stats in s/node<k>.log): the same key set; the same update counts (samples, train_samples,
train_batches, train_grad_rows, rows_written, update_sections, update_misses, published_seq, stale.writes_logged),
rows_written = train_grad_rows. Last line: OFF COMPARE PASS | OFF COMPARE FAIL (<reasons>).
"""
import sys

COUNTS = ["samples", "train_samples", "train_batches", "train_grad_rows", "rows_written", "update_sections",
          "update_misses", "published_seq", "stale.writes_logged", "torn_rows"]


def stop_stats(path):
    kv, on = {}, False
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("recsys-server: stopping"):
            on, kv = True, {}
            continue
        if on and "=" in line and not line.startswith("recsys-server:"):
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def main():
    a, b = sys.argv[1], sys.argv[2]
    fails = []
    for n in (0, 1):
        A, B = stop_stats(f"{a}/s/node{n}.log"), stop_stats(f"{b}/s/node{n}.log")
        if not A or not B:
            fails.append(f"node {n}: no stop stats")
            continue
        ka, kb = set(A), set(B)
        if ka != kb:
            fails.append(f"node {n}: key sets differ (only A: {sorted(ka - kb)[:5]}, only B: {sorted(kb - ka)[:5]})")
        row = []
        for k in COUNTS:
            row.append(f"{k}={A.get(k)}/{B.get(k)}")
            if A.get(k) != B.get(k):
                fails.append(f"node {n}: {k} {A.get(k)} != {B.get(k)}")
        for X, t in ((A, "A"), (B, "B")):
            if X.get("rows_written") != X.get("train_grad_rows"):
                fails.append(f"node {n} {t}: rows_written {X.get('rows_written')} != train_grad_rows {X.get('train_grad_rows')}")
        print(f"node {n}: {len(ka)} keys (A) {len(kb)} keys (B); A/B " + " ".join(row))
    print("OFF COMPARE PASS" if not fails else "OFF COMPARE FAIL (" + "; ".join(fails[:8]) + ")")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Exact top-k ground truth for STATIC searches over pool A (Host check of tools/search_index.cc; no writes, no
snapshots: the run-time recall path stays tools/compute_gt.py). Inner product in float32 over pool A rows [0, rows)
(record id = row, as tools/build_index.cc), queries rows [0, nq) of queries.fbin. Exact: every row is scored.
Optional subset GT in the same pass (--subset-mod S --subset-lt L --out-subset F): only rows with row % S < L, i.e.
the records of segments 0..L-1 (search_index.cc nseg = L).
Output: int32 nq, int32 k, uint64 ids[nq][k] (best first); <out>.manifest.txt.
usage: static_gt.py --pool-a pool_a.fbin --queries queries.fbin --nq 1000 [--rows 0=all] [--k 10] [--block 131072]
       --out gt.bin [--subset-mod 32 --subset-lt 8 --out-subset gt-s8.bin]
"""
import argparse
import sys
import time

import numpy as np


def fbin(path):
    n, d = np.fromfile(path, dtype=np.int32, count=2)
    return np.memmap(path, dtype=np.float32, mode="r", offset=8, shape=(int(n), int(d)))


class TopK:
    def __init__(self, nq, k):
        self.k = k
        self.s = np.full((nq, k), -np.inf, dtype=np.float32)
        self.i = np.zeros((nq, k), dtype=np.uint64)

    def add(self, S, base):
        kk = min(self.k, S.shape[1])
        idx = np.argpartition(-S, kk - 1, axis=1)[:, :kk]
        cs = np.concatenate([self.s, np.take_along_axis(S, idx, 1)], axis=1)
        ci = np.concatenate([self.i, (idx + base).astype(np.uint64)], axis=1)
        o = np.argsort(-cs, axis=1, kind="stable")[:, :self.k]
        self.s, self.i = np.take_along_axis(cs, o, 1), np.take_along_axis(ci, o, 1)

    def write(self, path, desc):
        with open(path, "wb") as f:
            np.array(self.i.shape, dtype=np.int32).tofile(f)
            self.i.tofile(f)
        with open(path + ".manifest.txt", "w") as f:
            f.write(f"# static_gt.py exact top-{self.k} inner product\n{desc}\n"
                    f"kth_score_mean={float(self.s[:, -1].mean()):.6f}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool-a", required=True)
    ap.add_argument("--queries", required=True)
    ap.add_argument("--nq", type=int, default=1000)
    ap.add_argument("--rows", type=int, default=0)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--block", type=int, default=131072)
    ap.add_argument("--out", required=True)
    ap.add_argument("--subset-mod", type=int, default=0)
    ap.add_argument("--subset-lt", type=int, default=0)
    ap.add_argument("--out-subset")
    a = ap.parse_args()
    A, Qa = fbin(a.pool_a), fbin(a.queries)
    rows = a.rows or A.shape[0]
    Q = np.ascontiguousarray(Qa[:a.nq])
    nq = Q.shape[0]
    full, sub = TopK(nq, a.k), (TopK(nq, a.k) if a.out_subset else None)
    t0 = time.time()
    for b in range(0, rows, a.block):
        e = min(rows, b + a.block)
        S = Q @ np.asarray(A[b:e]).T                      # [nq, block]
        full.add(S, b)
        if sub:
            keep = (np.arange(b, e) % a.subset_mod) < a.subset_lt
            S[:, ~keep] = -np.inf
            sub.add(S, b)
        if (b // a.block) % 20 == 0:
            print(f"rows {e}/{rows} {time.time() - t0:.0f} s", file=sys.stderr, flush=True)
    desc = f"pool_a={a.pool_a} rows={rows}\nqueries={a.queries} nq={nq}\nwall_s={time.time() - t0:.0f}"
    full.write(a.out, desc)
    if sub:
        sub.write(a.out_subset, desc + f"\nsubset=row % {a.subset_mod} < {a.subset_lt}")
    print(f"gt written: {a.out}{' ' + a.out_subset if sub else ''} ({nq} x {a.k}, {time.time() - t0:.0f} s)")


if __name__ == "__main__":
    main()

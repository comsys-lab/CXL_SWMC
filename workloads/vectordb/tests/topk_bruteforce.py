#!/usr/bin/env python3
"""Exact top-K' inner product over pool A + pool B for every query row of a SMALL dataset (Host tests only), in the
.npz format of workspaces/eval3/recall/recall_gt.py static (qrows, ids [Q, K'] in score order, scores, na,
pool_b_rows; ids >= na = na + pool B row). Input of experiments/vectordb/staleness_recall.py and compute_gt.py --topk.
usage: topk_bruteforce.py <data dir: pool_a.fbin pool_b.fbin queries.fbin> <out.npz> [--kprime 1000]
"""
import argparse
import os

import numpy as np


def fbin(path):
    n, d = np.fromfile(path, dtype=np.int32, count=2)
    return np.fromfile(path, dtype=np.float32, offset=8).reshape(int(n), int(d))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("out")
    ap.add_argument("--kprime", type=int, default=1000)
    a = ap.parse_args()
    A, B, Q = (fbin(os.path.join(a.data, f)) for f in ("pool_a.fbin", "pool_b.fbin", "queries.fbin"))
    X = np.concatenate([A, B])
    kk = min(a.kprime, len(X))
    ids = np.zeros((len(Q), kk), dtype=np.int64)
    sc = np.zeros((len(Q), kk), dtype=np.float32)
    for lo in range(0, len(Q), 256):
        s = Q[lo:lo + 256] @ X.T
        loc = np.argpartition(-s, kk - 1, axis=1)[:, :kk]
        v = np.take_along_axis(s, loc, axis=1)
        o = np.argsort(-v, axis=1, kind="stable")
        ids[lo:lo + 256] = np.take_along_axis(loc, o, axis=1)
        sc[lo:lo + 256] = np.take_along_axis(v, o, axis=1)
    np.savez(a.out, qrows=np.arange(len(Q), dtype=np.int64), ids=ids, scores=sc, na=np.int64(len(A)),
             pool_b_rows=np.int64(len(B)))
    print(f"top-{kk} of {len(Q)} queries over {len(A)} + {len(B)} rows -> {a.out}")


if __name__ == "__main__":
    main()

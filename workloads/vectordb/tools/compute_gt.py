#!/usr/bin/env python3
"""Offline exact top-k ground truth for a vectordb trace (DESIGN.md §8). Never run during a measurement.

For each query row used by the trace: exact top-K' by inner product (vectors are unit-norm, so this is cosine)
over all of pool A and pool B. For each SEARCH with snapshot s = ref_w, keep the candidates visible at s
(ins_seq <= s < del_seq) in score order and take the first k; if fewer than k remain, recompute that search by
brute force over every visible record.

Output: <out>.npy, uint64 array [num_searches, k] of record ids (row i = i-th SEARCH in trace order), its
op_seq in <out>.op_seq.npy, and <out>.manifest.txt.

usage: compute_gt.py --data DIR (pool_a.fbin, pool_b.fbin, queries.fbin) --trace trace.npy --out gt [--k 10 --kprime 200]
"""
import argparse, os, sys, time

import numpy as np

INSERT, DELETE, SEARCH = 1, 2, 3
INF = np.iinfo(np.uint32).max


def read_fbin(path):
    with open(path, "rb") as f:
        n, d = np.fromfile(f, dtype=np.int32, count=2)
    return np.memmap(path, dtype=np.float32, mode="r", offset=8, shape=(int(n), int(d)))


def topk_rows(scores, k):
    idx = np.argpartition(-scores, k - 1, axis=1)[:, :k]
    s = np.take_along_axis(scores, idx, axis=1)
    order = np.argsort(-s, axis=1, kind="stable")
    return np.take_along_axis(idx, order, axis=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--kprime", type=int, default=200)
    ap.add_argument("--block", type=int, default=262144, help="database rows per matmul block")
    a = ap.parse_args()
    t0 = time.time()
    A = read_fbin(os.path.join(a.data, "pool_a.fbin"))
    B = read_fbin(os.path.join(a.data, "pool_b.fbin"))
    Q = read_fbin(os.path.join(a.data, "queries.fbin"))
    NA, NB = A.shape[0], B.shape[0]
    tr = np.load(a.trace)

    # ins_seq / del_seq per record id (A: ins 0; B: ins at its INSERT's w_seq or never)
    ins = np.full(NA + NB, INF, dtype=np.uint32)
    ins[:NA] = 0
    dele = np.full(NA + NB, INF, dtype=np.uint32)
    w = tr[tr["op"] != SEARCH]
    wi = w[w["op"] == INSERT]
    ins[wi["id"].astype(np.int64)] = wi["w_seq"]
    wd = w[w["op"] == DELETE]
    dele[wd["id"].astype(np.int64)] = wd["w_seq"]

    srch = tr[tr["op"] == SEARCH]
    qrows = np.unique(srch["vec_ref"])
    Qu = np.ascontiguousarray(Q[qrows])

    # exact top-K' per used query over A ∪ B (ids: A rows 0..NA-1, B rows NA..)
    best_s = np.full((len(qrows), a.kprime), -np.inf, dtype=np.float32)
    best_i = np.zeros((len(qrows), a.kprime), dtype=np.int64)
    for base, X in ((0, A), (NA, B)):
        for lo in range(0, X.shape[0], a.block):
            blk = np.asarray(X[lo:lo + a.block])
            sc = Qu @ blk.T
            kk = min(a.kprime, sc.shape[1])
            loc = np.argpartition(-sc, kk - 1, axis=1)[:, :kk]
            cs = np.concatenate([best_s, np.take_along_axis(sc, loc, axis=1)], axis=1)
            ci = np.concatenate([best_i, loc + base + lo], axis=1)
            sel = np.argpartition(-cs, a.kprime - 1, axis=1)[:, :a.kprime]
            best_s = np.take_along_axis(cs, sel, axis=1)
            best_i = np.take_along_axis(ci, sel, axis=1)
        print(f"scanned pool {'A' if base == 0 else 'B'} ({time.time() - t0:.0f}s)", flush=True)
    order = np.argsort(-best_s, axis=1, kind="stable")
    best_i = np.take_along_axis(best_i, order, axis=1)
    row_of = {int(q): r for r, q in enumerate(qrows)}

    gt = np.zeros((len(srch), a.k), dtype=np.uint64)
    fallback = 0
    allX = None
    for n, (q, s) in enumerate(zip(srch["vec_ref"], srch["ref_w"])):
        cand = best_i[row_of[int(q)]]
        vis = cand[(ins[cand] <= s) & (s < dele[cand])]
        if len(vis) >= a.k:
            gt[n] = vis[:a.k]
            continue
        fallback += 1
        if allX is None:
            allX = (A, B)
        ids = np.nonzero((ins <= s) & (s < dele))[0]
        sc = np.concatenate([np.asarray(A[ids[ids < NA]]) @ Q[q], np.asarray(B[ids[ids >= NA] - NA]) @ Q[q]])
        gt[n] = ids[np.argsort(-sc, kind="stable")[:a.k]]
    np.save(a.out + ".npy", gt)
    np.save(a.out + ".op_seq.npy", srch["op_seq"])
    with open(a.out + ".manifest.txt", "w") as m:
        m.write("# vectordb ground truth (CXL_SWMC/workloads/vectordb/tools/compute_gt.py)\n")
        for k, v in sorted(vars(a).items()):
            m.write(f"{k}={v}\n")
        m.write(f"searches={len(srch)} distinct_queries={len(qrows)} brute_force_fallbacks={fallback}\n")
        m.write(f"seconds={time.time() - t0:.1f}\n")
    print(f"searches={len(srch)} fallbacks={fallback} -> {a.out}.npy ({time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()

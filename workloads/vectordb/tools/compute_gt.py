#!/usr/bin/env python3
"""Offline exact top-k ground truth and recall for a vectordb run (DESIGN.md §8). Never run during a measurement.

Inputs: the dataset (pool_a/pool_b/queries .fbin), the writes file of the run (gen_writes.py) and the loadgen
plugin's searches.bin (one record per search response: query row, E1 snapshot ref_w, returned ids).
For each distinct query row: exact top-K' by inner product (unit-norm vectors: cosine) over pools A and B. For each
search with snapshot s: keep the candidates visible at s (ins_seq <= s < del_seq) in score order and take the
first k; if fewer than k remain, recompute that search by brute force over every visible record.

Output: <out>.recall.txt (recall@k over measured OK responses and over all OK responses), <out>.gt.npy
(uint64 [searches, k], rows in searches.bin order), <out>.manifest.txt.

usage: compute_gt.py --data DIR --writes writes.bin --searches RUN/searches.bin --out PREFIX [--k 10 --kprime 200]
"""
import argparse, os, sys, time

import numpy as np

INSERT, DELETE = 1, 2
INF = np.iinfo(np.uint32).max
WDT = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"),
                ("vec_ref", "<u4"), ("pad1", "<u4")])


def search_dtype(k):  # vectordb_plugin.cc SearchLog (packed) + ids[k] + scores[k]
    return np.dtype([("seq", "<u8"), ("qrow", "<u4"), ("ref_w", "<u4"), ("s_used", "<u4"), ("measured", "u1"),
                     ("pad", "u1"), ("status", "<u2"), ("n", "<u2"), ("k", "<u2"), ("wait_us", "<u4"),
                     ("replay_us", "<u4"), ("search_us", "<u4"), ("lock_us", "<u4"), ("dists", "<u4"),
                     ("segs", "<u2"), ("pad2", "<u2"), ("ids", "<u8", (k,)), ("scores", "<f4", (k,))])


def read_fbin(path):
    with open(path, "rb") as f:
        n, d = np.fromfile(f, dtype=np.int32, count=2)
    return np.memmap(path, dtype=np.float32, mode="r", offset=8, shape=(int(n), int(d)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--writes", required=True)
    ap.add_argument("--searches", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--kprime", type=int, default=200)
    ap.add_argument("--block-mb", type=int, default=256, help="score-matrix budget per matmul block (MiB)")
    a = ap.parse_args()
    t0 = time.time()
    A = read_fbin(os.path.join(a.data, "pool_a.fbin"))
    B = read_fbin(os.path.join(a.data, "pool_b.fbin"))
    Q = read_fbin(os.path.join(a.data, "queries.fbin"))
    NA, NB = A.shape[0], B.shape[0]
    w = np.fromfile(a.writes, dtype=WDT)
    sr = np.fromfile(a.searches, dtype=search_dtype(a.k))
    if len(sr) and int(sr["k"][0]) != a.k:
        sys.exit(f"searches.bin has k={sr['k'][0]}, not {a.k}")

    # ins_seq / del_seq per record id (A: ins 0; B: ins at its INSERT's w_seq or never)
    ins = np.full(NA + NB, INF, dtype=np.uint32)
    ins[:NA] = 0
    dele = np.full(NA + NB, INF, dtype=np.uint32)
    wi = w[w["op"] == INSERT]
    ins[wi["id"].astype(np.int64)] = wi["w_seq"]
    wd = w[w["op"] == DELETE]
    dele[wd["id"].astype(np.int64)] = wd["w_seq"]

    ok = sr[sr["status"] == 0]
    qrows = np.unique(ok["qrow"])
    Qu = np.ascontiguousarray(Q[qrows])
    best_s = np.full((len(qrows), a.kprime), -np.inf, dtype=np.float32)
    best_i = np.zeros((len(qrows), a.kprime), dtype=np.int64)
    for base, X in ((0, A), (NA, B)):
        block = max(1024, (a.block_mb << 20) // (4 * max(1, len(qrows))))  # rows per block: bounded score matrix
        for lo in range(0, X.shape[0], block):
            blk = np.asarray(X[lo:lo + block])
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

    gt = np.zeros((len(sr), a.k), dtype=np.uint64)
    hits = np.zeros(len(sr), dtype=np.float64)
    fallback = invisible = dup = 0
    for n, rec in enumerate(sr):
        if rec["status"] != 0:
            continue
        q, s = int(rec["qrow"]), int(rec["ref_w"])
        cand = best_i[row_of[q]]
        vis = cand[(ins[cand] <= s) & (s < dele[cand])]
        if len(vis) >= a.k:
            gt[n] = vis[:a.k]
        else:
            fallback += 1
            ids = np.nonzero((ins <= s) & (s < dele))[0]
            sc = np.concatenate([np.asarray(A[ids[ids < NA]]) @ Q[q], np.asarray(B[ids[ids >= NA] - NA]) @ Q[q]])
            gt[n] = ids[np.argsort(-sc, kind="stable")[:a.k]]
        got = rec["ids"][:rec["n"]].astype(np.int64)
        hits[n] = len(np.intersect1d(got, gt[n])) / a.k
        bad = (got >= NA + NB)
        g = got[~bad]
        invisible += int(bad.sum()) + int(((ins[g] > s) | (dele[g] <= s)).sum())  # E1 violation
        dup += len(got) - len(np.unique(got))
    np.save(a.out + ".gt.npy", gt)
    okm = (sr["status"] == 0) & (sr["measured"] == 1)
    oka = sr["status"] == 0
    with open(a.out + ".recall.txt", "w") as f:
        f.write(f"k={a.k}\nresponses={len(sr)} ok={int(oka.sum())} measured_ok={int(okm.sum())} "
                f"not_ok={int((~oka).sum())}\n")
        f.write(f"recall_measured_ok={hits[okm].mean() if okm.any() else float('nan'):.5f}\n")
        f.write(f"recall_all_ok={hits[oka].mean() if oka.any() else float('nan'):.5f}\n")
        f.write(f"invisible_returned={invisible}\nduplicate_ids={dup}\n")
        f.write("(searches never answered are not in searches.bin: take timeouts from the loadgen steps.jsonl)\n")
    with open(a.out + ".manifest.txt", "w") as m:
        m.write("# vectordb ground truth (CXL_SWMC/workloads/vectordb/tools/compute_gt.py)\n")
        for key, v in sorted(vars(a).items()):
            m.write(f"{key}={v}\n")
        m.write(f"searches={len(sr)} distinct_queries={len(qrows)} brute_force_fallbacks={fallback}\n")
        m.write(f"seconds={time.time() - t0:.1f}\n")
    print(open(a.out + ".recall.txt").read(), end="")


if __name__ == "__main__":
    main()

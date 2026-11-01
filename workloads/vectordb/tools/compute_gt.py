#!/usr/bin/env python3
"""Offline exact top-k ground truth and recall for a vectordb run (DESIGN.md §8). Never run during a measurement.

Inputs: the dataset (pool_a/pool_b/queries .fbin), the writes file of the run (gen_writes.py) and the loadgen
plugin's searches.bin (one record per search response: query row, E1 snapshot ref_w, returned ids).
For each distinct query row: exact top-K' by inner product (unit-norm vectors: cosine) over pools A and B. For each
search with snapshot s: keep the candidates visible at s (ins_seq <= s < del_seq) in score order and take the
first k; if fewer than k remain, recompute that search by brute force over every visible record.

Inserted ids: id NA + j uses pool B row vec_ref of its INSERT record (gen_writes.py; row j unless --pool-b-rows reused
rows under new ids, DESIGN.md §17). With reused rows two live ids can hold the same vector (equal scores): the
recall file adds recall_tie_aware_* (a returned visible id whose score is >= the k-th exact score counts as a hit;
at most k per search).

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
    ap.add_argument("--topk", help="precomputed exact top-K' over pools A+B per query row (.npz: qrows, ids, scores, na;"
                    " ids >= na = na + pool-B row; workspaces/eval3/recall/recall_gt.py static --pool-b): skips the scan;"
                    " searches with < k visible candidates are brute-forced in ONE batched pass at the end")
    ap.add_argument("--no-tie", action="store_true", help="skip the tie-aware recall (random pool reads per search)")
    a = ap.parse_args()
    t0 = time.time()
    A = read_fbin(os.path.join(a.data, "pool_a.fbin"))
    B = read_fbin(os.path.join(a.data, "pool_b.fbin"))
    Q = read_fbin(os.path.join(a.data, "queries.fbin"))
    NA = A.shape[0]
    w = np.fromfile(a.writes, dtype=WDT)
    wi0 = w[w["op"] == INSERT]
    NB = int(wi0["id"].max()) - NA + 1 if len(wi0) else 0  # inserted id space NA .. NA + NB - 1
    rowmap = np.arange(NB, dtype=np.int64)  # inserted id - NA -> pool B row
    rowmap[wi0["id"].astype(np.int64) - NA] = wi0["vec_ref"]
    if NB and rowmap.max() >= B.shape[0]:
        sys.exit("writes file references pool B rows beyond pool_b.fbin")
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
    if a.topk:  # precomputed A+B top-K': pool-B row -> inserted id of this writes file; rows never inserted -> sentinel
        tk = np.load(a.topk)
        if int(tk["na"]) != NA or int(tk["pool_b_rows"]) != B.shape[0]:
            sys.exit("--topk file is for another pool A / pool B size")
        tpos = np.full(int(tk["qrows"].max()) + 1, -1, dtype=np.int64)
        tpos[tk["qrows"]] = np.arange(len(tk["qrows"]))
        if qrows.max() >= len(tpos) or (tpos[qrows] < 0).any():
            sys.exit("--topk file lacks query rows of this searches file")
        SENT = NA + NB  # extra id, never visible
        ins, dele = np.append(ins, INF), np.append(dele, INF)
        id_of_row = np.full(B.shape[0], SENT, dtype=np.int64)
        id_of_row[rowmap] = np.arange(NB) + NA
        best_i = tk["ids"][tpos[qrows]].astype(np.int64)
        best_s = tk["scores"][tpos[qrows]]
        mb = best_i >= NA
        best_i[mb] = id_of_row[best_i[mb] - NA]
        a.kprime = best_i.shape[1]
        print(f"loaded --topk {a.topk}: K'={a.kprime} ({time.time() - t0:.0f}s)", flush=True)
    for base, X, n_rows in (() if a.topk else ((0, A, NA), (NA, B, NB))):
        block = max(1024, (a.block_mb << 20) // (4 * max(1, len(qrows))))  # rows per block: bounded score matrix
        for lo in range(0, n_rows, block):
            blk = np.asarray(X[lo:lo + block]) if base == 0 else np.asarray(B[rowmap[lo:lo + block]])  # id order
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

    def vecs_b(j):  # inserted ids (minus NA) -> their pool B vectors
        return np.asarray(B[rowmap[j]])

    def score(ids, q):
        ids = np.asarray(ids, dtype=np.int64)
        out = np.empty(len(ids), dtype=np.float32)
        ma = ids < NA
        if ma.any():
            out[ma] = np.asarray(A[ids[ma]]) @ Q[q]
        if (~ma).any():
            out[~ma] = vecs_b(ids[~ma] - NA) @ Q[q]
        return out

    gt = np.zeros((len(sr), a.k), dtype=np.uint64)
    hits = np.zeros(len(sr), dtype=np.float64)
    hits_tie = np.zeros(len(sr), dtype=np.float64)
    fallback = invisible = dup = 0
    deferred = []
    for n, rec in enumerate(sr):
        if rec["status"] != 0:
            continue
        q, s = int(rec["qrow"]), int(rec["ref_w"])
        cand = best_i[row_of[q]]
        vis = cand[(ins[cand] <= s) & (s < dele[cand])]
        if len(vis) >= a.k:
            gt[n] = vis[:a.k]
        elif a.topk:
            deferred.append(n)
        else:
            fallback += 1
            ids = np.nonzero((ins <= s) & (s < dele))[0]
            sc = np.concatenate([np.asarray(A[ids[ids < NA]]) @ Q[q], vecs_b(ids[ids >= NA] - NA) @ Q[q]])
            gt[n] = ids[np.argsort(-sc, kind="stable")[:a.k]]
    if deferred:  # --topk: exact brute force for all short searches in ONE pass over A and the inserted B rows
        fallback = len(deferred)
        print(f"brute-force fallback for {fallback} searches (one pass over pools A+B)", flush=True)
        dn = np.array(deferred)
        Qd = np.ascontiguousarray(Q[sr["qrow"][dn].astype(np.int64)])
        sd = sr["ref_w"][dn].astype(np.int64)[:, None]
        fs = np.full((len(dn), a.k), -np.inf, dtype=np.float32)
        fi = np.zeros((len(dn), a.k), dtype=np.int64)
        block = max(1024, (a.block_mb << 20) // (4 * len(dn)))
        for base, n_rows in ((0, NA), (NA, NB)):
            for lo in range(0, n_rows, block):
                blk = np.asarray(A[lo:lo + block]) if base == 0 else np.asarray(B[rowmap[lo:lo + block]])
                idb = np.arange(base + lo, base + lo + blk.shape[0])
                sc = Qd @ blk.T
                sc[(ins[idb][None, :] > sd) | (dele[idb][None, :] <= sd)] = -np.inf
                cs = np.concatenate([fs, sc], axis=1)
                ci = np.concatenate([fi, np.broadcast_to(idb, sc.shape)], axis=1)
                sel = np.argpartition(-cs, a.k - 1, axis=1)[:, :a.k]
                fs, fi = np.take_along_axis(cs, sel, axis=1), np.take_along_axis(ci, sel, axis=1)
        o = np.argsort(-fs, axis=1, kind="stable")
        gt[dn] = np.take_along_axis(fi, o, axis=1)
    for n, rec in enumerate(sr):
        if rec["status"] != 0:
            continue
        q, s = int(rec["qrow"]), int(rec["ref_w"])
        got = rec["ids"][:rec["n"]].astype(np.int64)
        hits[n] = len(np.intersect1d(got, gt[n])) / a.k
        bad = (got >= NA + NB)
        g = got[~bad]
        gvis = g[(ins[g] <= s) & (s < dele[g])]
        if len(gvis) and len(gt[n]) and not a.no_tie:
            kth = float(score(gt[n][-1:].astype(np.int64), q)[0])
            hits_tie[n] = min(a.k, len(np.intersect1d(gvis, gt[n])) + int((score(np.setdiff1d(gvis, gt[n].astype(np.int64)), q) >= kth - 1e-6).sum())) / a.k
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
        if okm.any():  # s.e. of the mean: binomial over the 10 * n result slots, and empirical over searches
            p, nm = hits[okm].mean(), int(okm.sum())
            f.write(f"recall_measured_ok_se_binom={np.sqrt(p * (1 - p) / (a.k * nm)):.6f}\n")
            f.write(f"recall_measured_ok_se_emp={hits[okm].std(ddof=1) / np.sqrt(nm) if nm > 1 else float('nan'):.6f}\n")
        f.write(f"recall_tie_aware_measured_ok={hits_tie[okm].mean() if okm.any() else float('nan'):.5f}\n")
        f.write(f"recall_tie_aware_all_ok={hits_tie[oka].mean() if oka.any() else float('nan'):.5f}\n")
        f.write(f"inserted_ids={NB} vector_rows_used={len(np.unique(rowmap)) if NB else 0}\n")
        f.write(f"invisible_returned={invisible}\nduplicate_ids={dup}\n")
        f.write(f"brute_force_fallbacks={fallback} candidates={'topk:' + a.topk if a.topk else 'scan'} "
                f"kprime={a.kprime} tie_aware={'skipped' if a.no_tie else 'on'}\n")
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

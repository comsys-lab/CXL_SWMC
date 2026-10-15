#!/usr/bin/env python3
"""Fast E1 check of a vectordb run (every search response, no ground truth) and a sampled searches file for the
recall GT (reports/M4-vdb-packet.md §5). Host only, offline; cost ~ the size of searches.bin and the writes file.

E1 (DESIGN.md §4): a search with snapshot s = ref_w may return only ids with ins_seq <= s < del_seq; pool A ids
(< NA) have ins_seq 0, pool B ids get the w_seq of their INSERT, deleted ids the w_seq of their DELETE (writes file).
Counts: invisible (id not visible at s, or id out of range), duplicate ids within one response, responses with
fewer than k results, non-OK statuses.

usage: e1_check.py --writes writes.bin --na NA --nb NB --searches RUN/loadgen/searches.bin --out PREFIX
                   [--sample N --seed S]  -> PREFIX.e1.txt, and with --sample PREFIX.sample.bin: N measured OK
                   responses drawn with the seed (same record format; input for tools/compute_gt.py --searches)
Exit status 1 when invisible > 0 or duplicates > 0.
"""
import argparse, os, sys

import numpy as np

INSERT, DELETE = 1, 2
INF = np.iinfo(np.uint32).max
WDT = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"),
                ("vec_ref", "<u4"), ("pad1", "<u4")])


def search_dtype(k):  # loadgen/vectordb_plugin.cc SearchLog (packed) + ids[k] + scores[k]
    return np.dtype([("seq", "<u8"), ("qrow", "<u4"), ("ref_w", "<u4"), ("s_used", "<u4"), ("measured", "u1"),
                     ("pad", "u1"), ("status", "<u2"), ("n", "<u2"), ("k", "<u2"), ("wait_us", "<u4"),
                     ("replay_us", "<u4"), ("search_us", "<u4"), ("lock_us", "<u4"), ("dists", "<u4"),
                     ("segs", "<u2"), ("pad2", "<u2"), ("ids", "<u8", (k,)), ("scores", "<f4", (k,))])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--writes", required=True)
    ap.add_argument("--na", type=int, required=True)
    ap.add_argument("--nb", type=int, required=True)
    ap.add_argument("--searches", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--seed", type=int, default=20261016)
    a = ap.parse_args()
    N = a.na + a.nb
    w = np.fromfile(a.writes, dtype=WDT)
    ins = np.full(N, INF, dtype=np.uint32)
    ins[:a.na] = 0
    dele = np.full(N, INF, dtype=np.uint32)
    wi, wd = w[w["op"] == INSERT], w[w["op"] == DELETE]
    ins[wi["id"].astype(np.int64)] = wi["w_seq"]
    dele[wd["id"].astype(np.int64)] = wd["w_seq"]
    sr = np.fromfile(a.searches, dtype=search_dtype(a.k))
    ok = sr["status"] == 0
    s = sr["ref_w"].astype(np.int64)[:, None]
    ids = sr["ids"].astype(np.int64)
    valid = np.arange(a.k)[None, :] < sr["n"][:, None]
    oob = valid & (ids >= N)
    idc = np.where(valid & ~oob, ids, 0)
    vis = (ins[idc] <= s) & (s < dele[idc])
    invisible = int((valid & ~oob & ~vis)[ok].sum() + oob[ok].sum())
    srt = np.sort(np.where(valid, ids, -1 - np.arange(a.k)[None, :]), axis=1)  # invalid slots never collide
    dup = int(((srt[:, 1:] == srt[:, :-1]) & (srt[:, 1:] >= 0))[ok].sum())
    short = int((sr["n"][ok] < a.k).sum())
    meas = ok & (sr["measured"] == 1)
    with open(a.out + ".e1.txt", "w") as f:
        f.write(f"# e1_check.py searches={a.searches} writes={a.writes} na={a.na} nb={a.nb} k={a.k}\n")
        f.write(f"responses={len(sr)} ok={int(ok.sum())} measured_ok={int(meas.sum())} not_ok={int((~ok).sum())}\n")
        f.write(f"invisible_returned={invisible}\nduplicate_ids={dup}\nshort_responses={short}\n")
        f.write(f"max_ref_w={int(sr['ref_w'].max()) if len(sr) else 0} writes={len(w)}\n")
        if a.sample:
            idx = np.flatnonzero(meas)
            pick = np.sort(np.random.default_rng(a.seed).choice(idx, size=min(a.sample, len(idx)), replace=False))
            sr[pick].tofile(a.out + ".sample.bin")
            f.write(f"sample={len(pick)} seed={a.seed} distinct_qrows={len(np.unique(sr['qrow'][pick]))} "
                    f"-> {os.path.basename(a.out)}.sample.bin\n")
    print(open(a.out + ".e1.txt").read(), end="")
    return 1 if invisible or dup else 0


if __name__ == "__main__":
    sys.exit(main())

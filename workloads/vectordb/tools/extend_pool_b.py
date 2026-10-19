#!/usr/bin/env python3
"""Extend the vectordb pool B with fresh PubMed_bge rows (update-rate sweep, DESIGN.md §17; user decision 2026-10-20).

The 28M dataset (prepare_data.py) used every row of raw28m = binbin10/PubMed_bge@29f9db47 rows with chunk_id
0 .. 27,999,999 (checked here: contiguous). Fresh rows come from upstream shards of the same revision (downloaded
separately, untrusted data: read only as arrow tables). Selection, deterministic:
  upstream shards in the given order, rows in shard order; keep a row iff chunk_id >= --min-id (28,000,000), its
  chunk_id was not kept before, its document text and its embedding are not exact duplicates of any of the 28M rows or
  of a row kept before (64-bit blake2b of the UTF-8 document; 64-bit blake2b of the float32 embedding bytes); stop at
  --need rows. Vectors are copied as float32 exactly like prepare_data.py (no normalisation there either; norms are
  checked and recorded).
Output dir: pool_a.{fbin,ids} and queries.{fbin,ids} = symlinks to --base (sha256 recorded, checked against the base
manifest with --verify-base), pool_b.{fbin,ids} = the base pool B rows followed by the fresh rows, manifest.txt
(selection counts, skip reasons, shard sha256s, norm statistics, distribution check), dist-check.txt.
Distribution check: for --dist-queries queries (seed), top-1 / top-10 mean inner product against a random same-size
subset (size = min(1M, fresh)) of the fresh rows vs of the old pool B.

usage: extend_pool_b.py --base DIR --raw28m DIR --out DIR (must not exist) --need N [--min-id 28000000]
                        [--procs 6] [--dist-queries 1000] [--seed 20261020] [--verify-base] UPSTREAM_SHARD...
Run with python3 -E (pyarrow from the user site), from a trusted cwd; never from the data dirs.
"""
import argparse
import glob
import hashlib
import os
import sys
import time
from multiprocessing import Pool

import numpy as np
import pyarrow as pa


def read_table(p):
    with open(p, "rb") as f:
        try:
            return pa.ipc.open_stream(f).read_all()
        except pa.ArrowInvalid:
            f.seek(0)
            return pa.ipc.open_file(f).read_all()


def vectors(t):
    emb = t.column("embedding").combine_chunks()
    n = len(emb)
    offs = emb.offsets.to_numpy()
    d = int(offs[1] - offs[0]) if n else 0
    if n and not np.all(np.diff(offs) == d):
        raise SystemExit("ragged embeddings")
    return emb.flatten().to_numpy(zero_copy_only=False).astype(np.float32, copy=False).reshape(n, d)


def h8(b):
    return int.from_bytes(hashlib.blake2b(b, digest_size=8).digest(), "little")


def hash_shard(p):
    t = read_table(p)
    ids = t.column("chunk_id").to_numpy().astype(np.int64)
    v = np.ascontiguousarray(vectors(t))
    docs = t.column("document").to_pylist()
    dh = np.fromiter((h8((x or "").encode()) for x in docs), dtype=np.uint64, count=len(docs))
    vh = np.fromiter((h8(v[i].tobytes()) for i in range(len(v))), dtype=np.uint64, count=len(v))
    return ids, dh, vh


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 24), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--raw28m", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--need", type=int, required=True)
    ap.add_argument("--min-id", type=int, default=28_000_000)
    ap.add_argument("--procs", type=int, default=6)
    ap.add_argument("--dist-queries", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20261020)
    ap.add_argument("--verify-base", action="store_true")
    ap.add_argument("shards", nargs="+")
    a = ap.parse_args()
    if os.path.exists(a.out):
        sys.exit(f"refusing: {a.out} exists")
    t0 = time.time()
    raw = sorted(glob.glob(os.path.join(a.raw28m, "data-*.arrow")))
    with Pool(a.procs) as pool:
        res = pool.map(hash_shard, raw, chunksize=1)
    ids28 = np.concatenate([r[0] for r in res])
    if not np.array_equal(ids28, np.arange(len(ids28))) or len(ids28) != a.min_id:
        sys.exit(f"raw28m chunk_ids are not 0..{a.min_id - 1} in order (n={len(ids28)})")
    doc28 = np.unique(np.concatenate([r[1] for r in res]))
    vec28 = np.unique(np.concatenate([r[2] for r in res]))
    del res
    print(f"raw28m: {len(ids28)} rows, ids contiguous 0..{len(ids28) - 1}, distinct doc hashes {len(doc28)}, "
          f"distinct vector hashes {len(vec28)} ({time.time() - t0:.0f} s)", flush=True)

    os.makedirs(a.out)
    base_b = os.path.join(a.base, "pool_b.fbin")
    nb0, d = (int(x) for x in np.fromfile(base_b, dtype=np.int32, count=2))
    fv = open(os.path.join(a.out, "pool_b.fbin"), "wb")
    fi = open(os.path.join(a.out, "pool_b.ids"), "wb")
    np.array([nb0 + a.need, d], dtype=np.int32).tofile(fv)
    with open(base_b, "rb") as f:
        f.seek(8)
        for b in iter(lambda: f.read(1 << 26), b""):
            fv.write(b)
    with open(os.path.join(a.base, "pool_b.ids"), "rb") as f:
        fi.write(f.read())
    seen_id, seen_doc, seen_vec = set(), set(), set()
    skip = dict(old_id=0, dup_id=0, doc_in_28m=0, vec_in_28m=0, doc_dup_new=0, vec_dup_new=0)
    kept, norms, used = 0, [], []
    for p in a.shards:
        if kept >= a.need:
            break
        ids, dh, vh = hash_shard(p)
        v = vectors(read_table(p))
        take = []
        in28d, in28v = np.isin(dh, doc28), np.isin(vh, vec28)
        for i in range(len(ids)):
            if kept + len(take) >= a.need:
                break
            c, x, y = int(ids[i]), int(dh[i]), int(vh[i])
            if c < a.min_id:
                skip["old_id"] += 1
            elif c in seen_id:
                skip["dup_id"] += 1
            elif in28d[i]:
                skip["doc_in_28m"] += 1
            elif in28v[i]:
                skip["vec_in_28m"] += 1
            elif x in seen_doc:
                skip["doc_dup_new"] += 1
            elif y in seen_vec:
                skip["vec_dup_new"] += 1
            else:
                take.append(i)
                seen_id.add(c), seen_doc.add(x), seen_vec.add(y)
        if take:
            rows = np.asarray(take)
            np.ascontiguousarray(v[rows], dtype=np.float32).tofile(fv)
            ids[rows].astype(np.uint64).tofile(fi)
            norms.append(np.linalg.norm(v[rows], axis=1))
            kept += len(take)
        used.append((os.path.basename(p), len(take), sha256(p)))
        print(f"{os.path.basename(p)}: kept {len(take)} (total {kept}) skips {skip} ({time.time() - t0:.0f} s)", flush=True)
    fv.close()
    fi.close()
    if kept != a.need:
        sys.exit(f"only {kept} fresh rows in the given shards (need {a.need})")
    nr = np.concatenate(norms)

    for n in ("pool_a.fbin", "pool_a.ids", "queries.fbin", "queries.ids"):
        os.symlink(os.path.abspath(os.path.join(a.base, n)), os.path.join(a.out, n))
    base_sha = {}
    for line in open(os.path.join(a.base, "manifest.txt")):
        if line.startswith("out "):
            nm, h = line.split()[1], line.split("sha256=")[1].strip()
            base_sha[nm] = h
    linked = {}
    for n in ("pool_a.fbin", "pool_a.ids", "queries.fbin", "queries.ids"):
        linked[n] = sha256(os.path.join(a.out, n)) if a.verify_base else base_sha.get(n, "?")
        if a.verify_base and linked[n] != base_sha.get(n):
            sys.exit(f"{n}: sha256 differs from the base manifest")

    # distribution check: queries' top-1 / top-10 similarity on fresh vs old pool B, same-size random subsets
    rng = np.random.default_rng(a.seed)
    B = np.memmap(os.path.join(a.out, "pool_b.fbin"), dtype=np.float32, mode="r", offset=8, shape=(nb0 + a.need, d))
    Qall = np.memmap(os.path.join(a.base, "queries.fbin"), dtype=np.float32, mode="r", offset=8,
                     shape=(int(np.fromfile(os.path.join(a.base, "queries.fbin"), dtype=np.int32, count=1)[0]), d))
    Q = np.asarray(Qall[np.sort(rng.choice(len(Qall), size=min(a.dist_queries, len(Qall)), replace=False))])
    m = min(nb0, a.need)
    dist = {}
    for name, lo, n in (("old_pool_b", 0, nb0), ("fresh", nb0, a.need)):
        sel = np.sort(rng.choice(n, size=m, replace=False)) + lo
        top = np.full((len(Q), 10), -np.inf, dtype=np.float32)
        for s in range(0, m, 200_000):
            sc = Q @ np.asarray(B[sel[s:s + 200_000]]).T
            top = -np.sort(-np.concatenate([top, -np.partition(-sc, 9, axis=1)[:, :10]], axis=1), axis=1)[:, :10]
        dist[name] = (float(top[:, 0].mean()), float(top.mean()), float(np.median(top[:, 0])))
    with open(os.path.join(a.out, "dist-check.txt"), "w") as f:
        f.write(f"# queries {len(Q)} (seed {a.seed}), subset size {m} per side; inner product (unit vectors)\n")
        for k, (t1, t10, med) in dist.items():
            f.write(f"{k}: top1_mean={t1:.5f} top10_mean={t10:.5f} top1_median={med:.5f}\n")
    with open(os.path.join(a.out, "manifest.txt"), "w") as f:
        f.write("# vectordb dataset, pool B extended with fresh rows (CXL_SWMC/workloads/vectordb/tools/extend_pool_b.py)\n")
        f.write(f"base={os.path.abspath(a.base)}\nraw28m={os.path.abspath(a.raw28m)} rows={len(ids28)} chunk_ids=0..{len(ids28) - 1}\n")
        f.write(f"pool_b={nb0 + a.need} (base rows 0..{nb0 - 1}, fresh rows {nb0}..{nb0 + a.need - 1})\n")
        f.write(f"fresh={a.need} min_id={a.min_id} skips={skip}\n")
        f.write(f"fresh_norm_min={nr.min():.6f} fresh_norm_max={nr.max():.6f} fresh_norm_mean={nr.mean():.6f}\n")
        for n, h in linked.items():
            f.write(f"link {n} -> base sha256={h}{' (verified)' if a.verify_base else ' (from base manifest)'}\n")
        for nm, k, h in used:
            f.write(f"upstream {nm} kept={k} sha256={h}\n")
        for n in ("pool_b.fbin", "pool_b.ids"):
            f.write(f"out {n} sha256={sha256(os.path.join(a.out, n))}\n")
        for k, (t1, t10, med) in dist.items():
            f.write(f"dist {k}: top1_mean={t1:.5f} top10_mean={t10:.5f} top1_median={med:.5f}\n")
        f.write(f"seconds={time.time() - t0:.0f}\n")
    print(open(os.path.join(a.out, "manifest.txt")).read(), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())

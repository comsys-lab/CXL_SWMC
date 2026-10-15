#!/usr/bin/env python3
"""Build the vectordb datasets from PubMed BGE arrow shards (DESIGN.md §2).

Samples rows uniformly (fixed seed) from the given shards into three disjoint sets:
  pool A (initial records), pool B (insert source), queries (held-out PubMed vectors; user decision
  2026-10-15, BioASQ deferred).
Outputs, in --out:
  <name>.fbin   int32 n, int32 d, then n*d float32 (row-major)
  <name>.ids    n uint64 chunk_id (source identity, for provenance only)
  manifest.txt  inputs (sha256), seed, counts, norm statistics

usage: prepare_data.py --out DIR --seed 20261015 --pool-a 1000000 --pool-b 1000000 --queries 10000 SHARD...
"""
import argparse, hashlib, os, sys

import numpy as np
import pyarrow as pa


def read_shard(path):
    with pa.memory_map(path) as f:
        try:
            t = pa.ipc.open_stream(f).read_all()
        except pa.ArrowInvalid:
            t = pa.ipc.open_file(f).read_all()
    emb = t.column("embedding").combine_chunks()
    d = len(emb[0])
    vals = emb.flatten().to_numpy(zero_copy_only=False).astype(np.float32, copy=False)
    if vals.size != len(emb) * d:
        sys.exit(f"{path}: ragged embeddings")
    return t.column("chunk_id").to_numpy(), vals.reshape(len(emb), d)


def write_set(out, name, ids, vecs):
    n, d = vecs.shape
    with open(os.path.join(out, name + ".fbin"), "wb") as f:
        np.array([n, d], dtype=np.int32).tofile(f)
        np.ascontiguousarray(vecs, dtype=np.float32).tofile(f)
    ids.astype(np.uint64).tofile(os.path.join(out, name + ".ids"))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--pool-a", type=int, required=True)
    ap.add_argument("--pool-b", type=int, required=True)
    ap.add_argument("--queries", type=int, required=True)
    ap.add_argument("shards", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    ids, vecs = [], []
    for s in sorted(a.shards):
        i, v = read_shard(s)
        ids.append(i)
        vecs.append(v)
        print(f"read {os.path.basename(s)}: {len(i)} rows", flush=True)
    ids = np.concatenate(ids)
    vecs = np.concatenate(vecs)
    if len(np.unique(ids)) != len(ids):
        sys.exit("duplicate chunk_id across shards")
    need = a.pool_a + a.pool_b + a.queries
    if need > len(ids):
        sys.exit(f"need {need} rows, have {len(ids)}")

    perm = np.random.default_rng(a.seed).permutation(len(ids))[:need]
    parts = {"pool_a": perm[:a.pool_a], "pool_b": perm[a.pool_a:a.pool_a + a.pool_b],
             "queries": perm[a.pool_a + a.pool_b:]}
    norms = np.linalg.norm(vecs[perm], axis=1)
    for name, sel in parts.items():
        sel = np.sort(sel)  # stable on-disk order; sampling already randomized membership
        write_set(a.out, name, ids[sel], vecs[sel])
        print(f"wrote {name}: {len(sel)}", flush=True)

    with open(os.path.join(a.out, "manifest.txt"), "w") as m:
        m.write("# vectordb dataset (CXL_SWMC/workloads/vectordb/tools/prepare_data.py)\n")
        m.write(f"seed={a.seed}\ndim={vecs.shape[1]}\nsource_rows={len(ids)}\n")
        for name, sel in parts.items():
            m.write(f"{name}={len(sel)}\n")
        m.write(f"norm_min={norms.min():.6f} norm_max={norms.max():.6f} norm_mean={norms.mean():.6f}\n")
        for s in sorted(a.shards):
            m.write(f"shard {os.path.basename(s)} sha256={sha256(s)}\n")
        for name in parts:
            for ext in (".fbin", ".ids"):
                p = os.path.join(a.out, name + ext)
                m.write(f"out {name}{ext} sha256={sha256(p)}\n")
    print("done")


if __name__ == "__main__":
    main()

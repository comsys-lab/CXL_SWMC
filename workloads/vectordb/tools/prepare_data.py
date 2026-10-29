#!/usr/bin/env python3
"""Build the vectordb datasets from PubMed BGE arrow shards (DESIGN.md §2).

Samples rows uniformly (fixed seed) from the given shards into three disjoint sets:
  pool A (initial records), pool B (insert source), queries (held-out PubMed vectors; user decision
  2026-10-15, BioASQ deferred).
Outputs, in --out:
  <name>.fbin   int32 n, int32 d, then n*d float32 (row-major)
  <name>.ids    n uint64 chunk_id (source identity, for provenance only)
  manifest.txt  inputs (sha256), seed, counts, norm statistics

Streaming (2026-10-16, for the 28M set): pass 1 reads only chunk_id, row counts and per-row norms; pass 2 appends each
set's rows shard by shard. Memory is O(rows * 13 B) plus one shard, never the whole vector matrix. Selection,
on-disk order (global row order) and norm statistics are identical to the earlier in-memory version.

Exact-duplicate filter (2026-10-30, for the 54M set; default off = the behaviour above, byte for byte): --dedupe doc,vec
drops every row whose document text (doc) or whose float32 embedding bytes (vec) exactly repeat a row kept before it
(first occurrence kept; order = shard order, sorted, then row order), the same 64-bit blake2b hashes and the same
sequential rule as extend_pool_b.py (a row is checked against the kept rows only, doc first, then vec). The split then
draws from the unique rows only (need <= unique rows). Memory stays O(rows): two uint64 hash arrays; the per-row loop and
the seen sets cover only rows whose hash repeats somewhere. chunk_id uniqueness is checked as before. The manifest gets
dedupe=<rule> rows_scanned=.. dropped_doc=.. dropped_vec=.. unique_kept=..

usage: prepare_data.py --out DIR --seed 20261015 --pool-a 1000000 --pool-b 1000000 --queries 10000 [--dedupe doc,vec] SHARD...
Run with python3 -E (pyarrow lives in the user site; -I hides it: --help works, a run stops with a message).
"""
import argparse, hashlib, os, sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
try:
    import pyarrow as pa
except ImportError:  # python3 -I: --help still works; main() stops before reading a shard
    pa = None


def read_table(f):
    try:
        return pa.ipc.open_stream(f).read_all()
    except pa.ArrowInvalid:
        f.seek(0)
        return pa.ipc.open_file(f).read_all()


def shard_vectors(path, t):
    emb = t.column("embedding").combine_chunks()
    n = len(emb)
    offs = emb.offsets.to_numpy()
    d = int(offs[1] - offs[0]) if n else 0
    if n and not np.all(np.diff(offs) == d):
        sys.exit(f"{path}: ragged embeddings")
    vals = emb.flatten().to_numpy(zero_copy_only=False).astype(np.float32, copy=False)
    if vals.size != n * d:
        sys.exit(f"{path}: ragged embeddings")
    return vals.reshape(n, d)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def h8(b):  # as extend_pool_b.py: 64-bit blake2b
    return int.from_bytes(hashlib.blake2b(b, digest_size=8).digest(), "little")


def doc_hashes(t):
    docs = t.column("document").to_pylist()
    return np.fromiter((h8((x or "").encode()) for x in docs), dtype=np.uint64, count=len(docs))


def vec_hashes(v):
    v = np.ascontiguousarray(v, dtype=np.float32)
    return np.fromiter((h8(v[i].tobytes()) for i in range(len(v))), dtype=np.uint64, count=len(v))


def repeated(h):
    """mask: the hash of this row occurs more than once over all rows (vectorised; the rest never need the loop)"""
    _, inv, cnt = np.unique(h, return_inverse=True, return_counts=True)
    return cnt[inv] > 1


def dedupe(rule, dh, vh, n):
    """keep mask over the n rows (global order) + drop counts; sequential rule of extend_pool_b.py :124-143 over the
    kept rows: drop if the doc hash was kept before, else if the vec hash was kept before, else keep."""
    cand = np.zeros(n, dtype=bool)
    if "doc" in rule:
        cand |= repeated(dh)
    if "vec" in rule:
        cand |= repeated(vh)
    keep = np.ones(n, dtype=bool)
    seen_doc, seen_vec = set(), set()
    dropped = {"doc": 0, "vec": 0}
    for i in np.flatnonzero(cand):
        x = int(dh[i]) if "doc" in rule else None
        y = int(vh[i]) if "vec" in rule else None
        if x is not None and x in seen_doc:
            keep[i] = False
            dropped["doc"] += 1
        elif y is not None and y in seen_vec:
            keep[i] = False
            dropped["vec"] += 1
        else:
            if x is not None:
                seen_doc.add(x)
            if y is not None:
                seen_vec.add(y)
    return keep, dropped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--pool-a", type=int, required=True)
    ap.add_argument("--pool-b", type=int, required=True)
    ap.add_argument("--queries", type=int, required=True)
    ap.add_argument("--hash-threads", type=int, default=8)
    ap.add_argument("--dedupe", default=None, metavar="RULE",
                    help="drop exact duplicates before the split: doc | vec | doc,vec (document text / embedding bytes "
                         "equal to a row kept earlier; default off = no filter)")
    ap.add_argument("shards", nargs="+")
    a = ap.parse_args()
    rule = ()
    if a.dedupe is not None:
        rule = tuple(sorted(set(a.dedupe.split(","))))
        if not rule or any(r not in ("doc", "vec") for r in rule):
            sys.exit(f"--dedupe {a.dedupe}: expected doc, vec or doc,vec")
    if pa is None:
        sys.exit("pyarrow is not importable (it lives in the user site: run with python3 -E, not -I)")
    shards = sorted(a.shards)
    os.makedirs(a.out, exist_ok=True)

    # pass 1: ids, row counts, per-row norms (float32, same per-row reduction as before); with --dedupe also the
    # 64-bit doc / vec hashes of every row
    ids, norms, d = [], [], None
    dh, vh = [], []
    for s in shards:
        with pa.memory_map(s) as f:
            t = read_table(f)
            v = shard_vectors(s, t)
            if d is None:
                d = v.shape[1]
            elif v.shape[1] != d:
                sys.exit(f"{s}: dim {v.shape[1]} != {d}")
            ids.append(t.column("chunk_id").to_numpy())
            norms.append(np.linalg.norm(v, axis=1))
            if "doc" in rule:
                dh.append(doc_hashes(t))
            if "vec" in rule:
                vh.append(vec_hashes(v))
            del v, t
        print(f"pass1 {os.path.basename(s)}: {len(ids[-1])} rows", flush=True)
    counts = [len(i) for i in ids]
    ids = np.concatenate(ids)
    norms_all = np.concatenate(norms)
    del norms
    if len(np.unique(ids)) != len(ids):
        sys.exit("duplicate chunk_id across shards")
    dropped = None
    if rule:
        dh = np.concatenate(dh) if dh else None
        vh = np.concatenate(vh) if vh else None
        keep, dropped = dedupe(rule, dh, vh, len(ids))
        del dh, vh
        uniq = np.flatnonzero(keep)
        print(f"dedupe {','.join(rule)}: rows_scanned={len(ids)} dropped_doc={dropped['doc']} dropped_vec={dropped['vec']} "
              f"unique_kept={len(uniq)}", flush=True)
    else:
        uniq = np.arange(len(ids))
    need = a.pool_a + a.pool_b + a.queries
    if need > len(uniq):
        sys.exit(f"need {need} rows, have {len(uniq)}" + (" unique" if rule else ""))

    # the permutation is over the unique rows (= all rows without --dedupe: identical to the earlier versions)
    perm = uniq[np.random.default_rng(a.seed).permutation(len(uniq))[:need]]
    del uniq
    parts = {"pool_a": perm[:a.pool_a], "pool_b": perm[a.pool_a:a.pool_a + a.pool_b],
             "queries": perm[a.pool_a + a.pool_b:]}
    norms = norms_all[perm]
    del norms_all
    label = np.full(len(ids), 255, dtype=np.uint8)
    names = list(parts)
    for k, name in enumerate(names):
        label[parts[name]] = k  # stable on-disk order = global row order; sampling already randomized membership

    # pass 2: append each set's rows in global row order
    fv = {n: open(os.path.join(a.out, n + ".fbin"), "wb") for n in names}
    fi = {n: open(os.path.join(a.out, n + ".ids"), "wb") for n in names}
    for n in names:
        np.array([len(parts[n]), d], dtype=np.int32).tofile(fv[n])
    written = dict.fromkeys(names, 0)
    base = 0
    for s, c in zip(shards, counts):
        lab = label[base:base + c]
        with pa.memory_map(s) as f:
            v = shard_vectors(s, read_table(f))
            for k, n in enumerate(names):
                rows = np.flatnonzero(lab == k)
                if len(rows):
                    np.ascontiguousarray(v[rows], dtype=np.float32).tofile(fv[n])
                    ids[base + rows].astype(np.uint64).tofile(fi[n])
                    written[n] += len(rows)
            del v
        base += c
        print(f"pass2 {os.path.basename(s)}: " + " ".join(f"{n}={written[n]}" for n in names), flush=True)
    for n in names:
        fv[n].close()
        fi[n].close()
        if written[n] != len(parts[n]):
            sys.exit(f"{n}: wrote {written[n]} != {len(parts[n])}")
        print(f"wrote {n}: {written[n]}", flush=True)

    outs = [os.path.join(a.out, n + ext) for n in names for ext in (".fbin", ".ids")]
    with ThreadPoolExecutor(a.hash_threads) as ex:
        sh = list(ex.map(sha256, shards))
        oh = list(ex.map(sha256, outs))
    with open(os.path.join(a.out, "manifest.txt"), "w") as m:
        m.write("# vectordb dataset (CXL_SWMC/workloads/vectordb/tools/prepare_data.py)\n")
        m.write(f"seed={a.seed}\ndim={d}\nsource_rows={len(ids)}\n")
        if rule:
            m.write(f"dedupe={','.join(rule)} rows_scanned={len(ids)} dropped_doc={dropped['doc']} "
                    f"dropped_vec={dropped['vec']} unique_kept={len(ids) - dropped['doc'] - dropped['vec']}\n")
        for name, sel in parts.items():
            m.write(f"{name}={len(sel)}\n")
        m.write(f"norm_min={norms.min():.6f} norm_max={norms.max():.6f} norm_mean={norms.mean():.6f}\n")
        for s, h in zip(shards, sh):
            m.write(f"shard {os.path.basename(s)} sha256={h}\n")
        for p, h in zip(outs, oh):
            m.write(f"out {os.path.basename(p)} sha256={h}\n")
    print("done")


if __name__ == "__main__":
    main()

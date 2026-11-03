#!/usr/bin/env python3
"""Convert the MLPerf DLRMv2 torchsnapshot checkpoint (DLRM_DCN, fp32) into recsys v7 inputs (DESIGN.md §10).

The torchsnapshot package is not needed: .snapshot_metadata is JSON; every embedding table is a ShardedTensor whose
shards are raw row-major fp32 files (serializer buffer_protocol, byte_range null; the small tables sit inside
"batched" files at their byte_range); the dense weights are Tensors inside the batched files at their byte_range.

Outputs (in --out, created; must not exist):
  emb-<dtype>.img  table image: 4096 B header (server/layout.h ImageHeader) + one record per row, tables contiguous in
                   table order (row r of table k = record row_base[k] + r). Record (whole cache lines):
                   key u64 | seq u64 (0) | csum u32 | acc f32 (row-wise Adagrad state, --acc-init) | pad 40 | emb[128]
                   fp16 -> 320 B (default), fp32 -> 576 B. csum = layout.h row_csum over the emb words.
  dense.bin        "RSYSDNS1" header + named fp32 tensors in torch layout (Linear weight [out][in]).
  convert.json     per-table rows, max |w|, fp16 conversion error, source paths and sha256 of the metadata.

Streaming: each shard is read once in --chunk-row blocks and the output written sequentially; page cache of both is
dropped behind (posix_fadvise DONTNEED), so the footprint stays at a few chunks (coordinator rule 2026-11-03).

usage: ckpt_convert.py --ckpt DIR --out DIR [--emb-dtype fp16|fp32] [--acc-init 0] [--tables 0-25] [--max-rows N]
"""
import argparse
import hashlib
import json
import os
import struct
import sys
import time

import numpy as np

ROWS = [40000000, 39060, 17295, 7424, 20265, 3, 7122, 1543, 63, 40000000, 3067956, 405282, 10, 2209, 11938, 155, 4,
        976, 14, 40000000, 40000000, 40000000, 590152, 12973, 108, 36]
DIM = 128
IMG_MAGIC = 0x31474D4953595352  # "RSYSIMG1"
IMG_VERSION = 1
HDR_BYTES = 4096
DNS_MAGIC = b"RSYSDNS1"
DENSE_KEYS = (
    [f"model.dense_arch.model._mlp.{i}._linear.{w}" for i in range(3) for w in ("weight", "bias")]
    + [f"model.inter_arch.crossnet.{n}.{i}" for i in range(3) for n in ("V_kernels", "W_kernels", "bias")]
    + [f"model.over_arch.model.0._mlp.{i}._linear.{w}" for i in range(4) for w in ("weight", "bias")]
    + ["model.over_arch.model.1.weight", "model.over_arch.model.1.bias"])


def rec_dtype(emb):
    e = "<f2" if emb == "fp16" else "<f4"
    d = np.dtype([("key", "<u8"), ("seq", "<u8"), ("csum", "<u4"), ("acc", "<f4"), ("pad", "u1", (40,)),
                  ("emb", e, (DIM,))])
    assert d.itemsize % 64 == 0, d.itemsize
    return d


def row_csum(key, seq, words):
    """layout.h row_csum: FNV-1a style over (key, seq, emb as u32 words), | 1. key/seq uint64 arrays, words [n][w] u32."""
    with np.errstate(over="ignore"):
        h = (np.uint32(0x811C9DC5) ^ (key & 0xFFFFFFFF).astype(np.uint32) ^ (key >> 32).astype(np.uint32)
             ^ (seq.astype(np.uint32) * np.uint32(0x9E3779B1)))
        for j in range(words.shape[1]):
            h = (h ^ words[:, j]) * np.uint32(0x01000193)
    return h | np.uint32(1)


def drop(fd, off=0, length=0):
    try:
        os.posix_fadvise(fd, off, length, os.POSIX_FADV_DONTNEED)
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--emb-dtype", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument("--acc-init", type=float, default=0.0, help="initial row-wise Adagrad accumulator (FBGEMM: 0)")
    ap.add_argument("--chunk-rows", type=int, default=1 << 19)
    ap.add_argument("--dense-only", action="store_true")
    a = ap.parse_args()
    meta_path = os.path.join(a.ckpt, ".snapshot_metadata")
    meta_raw = open(meta_path, "rb").read()
    meta = json.loads(meta_raw)
    man = meta["manifest"]
    os.makedirs(a.out)
    info = {"ckpt": os.path.abspath(a.ckpt), "metadata_sha256": hashlib.sha256(meta_raw).hexdigest(),
            "world_size": meta["world_size"], "emb_dtype": a.emb_dtype, "acc_init": a.acc_init, "tables": []}

    # ---- dense weights (replicated Tensors, rank 0 entries)
    dense = {}
    for k, v in man.items():
        if v["type"] != "Tensor":
            continue
        name = k.split("/", 2)[2]
        if v["dtype"] != "torch.float32" or v["serializer"] != "buffer_protocol":
            sys.exit(f"{k}: unexpected {v['dtype']} {v['serializer']}")
        b0, b1 = v["byte_range"]
        with open(os.path.join(a.ckpt, v["location"]), "rb") as f:
            f.seek(b0)
            buf = f.read(b1 - b0)
        arr = np.frombuffer(buf, dtype="<f4").reshape(v["shape"])
        if name in dense and not np.array_equal(dense[name], arr):
            sys.exit(f"{name}: replicas differ")
        dense[name] = arr
    if sorted(dense) != sorted(DENSE_KEYS):
        sys.exit(f"dense keys differ: {sorted(set(dense) ^ set(DENSE_KEYS))}")
    with open(os.path.join(a.out, "dense.bin"), "xb") as f:
        f.write(DNS_MAGIC + struct.pack("<II", 1, len(DENSE_KEYS)))
        for name in DENSE_KEYS:
            t = np.ascontiguousarray(dense[name], dtype="<f4")
            shp = list(t.shape) + [1] * (2 - t.ndim)
            f.write(struct.pack("<96sIII", name.encode(), t.ndim, shp[0], shp[1]))
            f.write(t.tobytes())
    info["dense"] = {n: list(dense[n].shape) for n in DENSE_KEYS}
    if a.dense_only:
        json.dump(info, open(os.path.join(a.out, "convert.json"), "w"), indent=1)
        return

    # ---- embedding shards per table (union over ranks; each shard listed once per owner)
    shards = {k: {} for k in range(26)}
    for key, v in man.items():
        if v["type"] != "ShardedTensor":
            continue
        name = key.split("/", 2)[2]
        t = int(name.split("t_cat_")[1].split(".")[0])
        for s in v["shards"]:
            tt = s["tensor"]
            if tt["dtype"] != "torch.float32" or s["offsets"][1] != 0 or s["sizes"][1] != DIM:
                sys.exit(f"{name}: unexpected shard {s}")
            br = tt["byte_range"]  # small tables live inside "batched" files at byte_range
            if br is not None and br[1] - br[0] != s["sizes"][0] * DIM * 4:
                sys.exit(f"{name}: byte_range {br} != {s['sizes']}")
            shards[t][s["offsets"][0]] = (s["sizes"][0], tt["location"], None if br is None else br[0])
    rd = rec_dtype(a.emb_dtype)
    total = sum(ROWS)
    row_base = np.cumsum([0] + ROWS)[:-1]
    img = os.path.join(a.out, f"emb-{a.emb_dtype}.img")
    fo = os.open(img, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    hdr = struct.pack("<QIIQIIQ", IMG_MAGIC, IMG_VERSION, rd.itemsize, total, DIM, 2 if a.emb_dtype == "fp16" else 4,
                      HDR_BYTES)
    hdr += struct.pack("<26Q", *ROWS) + struct.pack("<26Q", *[int(x) for x in row_base])
    hdr += bytes.fromhex(info["metadata_sha256"])
    hdr = hdr.ljust(HDR_BYTES, b"\0")
    os.write(fo, hdr)
    wpos = HDR_BYTES
    t0 = time.time()
    for k in range(26):
        offs = sorted(shards[k])
        pos = 0
        mx, err = 0.0, 0.0
        for o in offs:
            if o != pos:
                sys.exit(f"table {k}: gap at row {pos} (next shard {o})")
            n, loc, base = shards[k][o]
            path = os.path.join(a.ckpt, loc)
            if base is None and os.path.getsize(path) != n * DIM * 4:
                sys.exit(f"{path}: size {os.path.getsize(path)} != {n}x{DIM}x4")
            base = base or 0
            fi = os.open(path, os.O_RDONLY)
            for r0 in range(0, n, a.chunk_rows):
                r1 = min(n, r0 + a.chunk_rows)
                raw = os.pread(fi, (r1 - r0) * DIM * 4, base + r0 * DIM * 4)
                if len(raw) != (r1 - r0) * DIM * 4:
                    sys.exit(f"{path}: short read at row {r0}")
                w = np.frombuffer(raw, dtype="<f4").reshape(r1 - r0, DIM)
                if not np.isfinite(w).all():
                    sys.exit(f"table {k} rows {o + r0}..: non-finite weight")
                rec = np.zeros(r1 - r0, dtype=rd)
                rows = np.arange(o + r0, o + r1, dtype=np.uint64)
                rec["key"] = (np.uint64(k + 1) << np.uint64(56)) | rows
                rec["acc"] = a.acc_init
                rec["emb"] = w
                mx = max(mx, float(np.abs(w).max()))
                if a.emb_dtype == "fp16":
                    err = max(err, float(np.abs(rec["emb"].astype("<f4") - w).max()))
                words = np.ascontiguousarray(rec["emb"]).view("<u4").reshape(r1 - r0, -1)
                rec["csum"] = row_csum(rec["key"], rec["seq"], words)
                b = rec.tobytes()
                done = 0
                while done < len(b):
                    done += os.pwrite(fo, b[done:], wpos + done)
                drop(fi, base + r0 * DIM * 4, (r1 - r0) * DIM * 4)
                drop(fo, wpos, len(b))
                wpos += len(b)
            os.close(fi)
            pos += n
        if pos != ROWS[k]:
            sys.exit(f"table {k}: {pos} rows, expected {ROWS[k]}")
        if a.emb_dtype == "fp16" and mx > 65000:
            sys.exit(f"table {k}: max |w| {mx} overflows fp16")
        info["tables"].append({"table": k, "rows": pos, "shards": len(offs), "max_abs": mx, "fp16_max_err": err})
        print(f"table {k}: {pos} rows, {len(offs)} shards, max|w| {mx:.4g}, fp16 err {err:.3g}, "
              f"{time.time() - t0:.0f} s", flush=True)
    os.fsync(fo)
    os.close(fo)
    if wpos != HDR_BYTES + total * rd.itemsize:
        sys.exit("image size mismatch")
    info["image"] = {"path": img, "bytes": wpos, "record_bytes": rd.itemsize, "rows": total}
    json.dump(info, open(os.path.join(a.out, "convert.json"), "w"), indent=1)
    print(f"wrote {img}: {total} rows x {rd.itemsize} B = {wpos} B in {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()

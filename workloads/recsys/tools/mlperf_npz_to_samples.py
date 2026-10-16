#!/usr/bin/env python3
"""Convert the MLCommons DLRMv2 preprocessed day 23 (multi-hot, as is) into a recsys v2 samples file (samples.h).

Input (https://inference.mlcommons-storage.org, dlrm_preprocessed/; reports/RECSYS-design.md §1.2):
  day_23_dense.npy               float32 [N, 13]   (MLPerf/torchrec preprocessing; observed log(x + 3))
  day_23_sparse_multi_hot.npz    members 0.npy .. 25.npy, int32 [N, h_k] with h_k = 3,2,1,2,6,...,1 (MLPerf sizes)
The npz members are stored uncompressed, so each is memory-mapped at its offset inside the zip (no 152 GB load).
Output records: 13 dense fp32 + the 214 multi-hot ids in table order (uncapped; the server applies id mod rows).
Records [start, start + count) are copied in file order. File order = time order is NOT verified for day 23 (the
MLPerf pipeline shuffles the training days; day 23 is the evaluation day, inf) -- recorded in the output source.

usage: mlperf_npz_to_samples.py --dir DAY23_DIR --out FILE --start S --count N [--label TEXT]
"""
import argparse
import struct
import sys
import zipfile

import numpy as np

MAGIC = 0x31504D5353595352  # "RSYSSMP1"
VERSION = 2
HOT = [3, 2, 1, 2, 6, 1, 1, 1, 1, 7, 3, 8, 1, 6, 9, 5, 1, 1, 1, 12, 100, 27, 10, 3, 1, 1]
assert sum(HOT) == 214
REC = np.dtype([("dense", "<f4", (13,)), ("ids", "<u4", (214,))])
assert REC.itemsize == 908


def npz_member(path, zf, name):
    info = zf.getinfo(name)
    if info.compress_type != zipfile.ZIP_STORED:
        sys.exit(f"{name}: compressed member (expected stored)")
    with open(path, "rb") as f:
        f.seek(info.header_offset)
        lh = f.read(30)
        if lh[:4] != b"PK\x03\x04":
            sys.exit(f"{name}: bad local header")
        nlen, xlen = struct.unpack("<HH", lh[26:30])
        data = info.header_offset + 30 + nlen + xlen
        f.seek(data)
        version = np.lib.format.read_magic(f)
        shape, fortran, dtype = np.lib.format._read_array_header(f, version)
        off = f.tell()
    if fortran:
        sys.exit(f"{name}: fortran order")
    return np.memmap(path, dtype=dtype, mode="r", offset=off, shape=shape)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--label", default="mlperf dlrmv2 day_23 multi-hot")
    ap.add_argument("--chunk", type=int, default=1 << 18)
    a = ap.parse_args()
    dense = np.load(f"{a.dir}/day_23_dense.npy", mmap_mode="r")
    npz = f"{a.dir}/day_23_sparse_multi_hot.npz"
    zf = zipfile.ZipFile(npz)
    sp = [npz_member(npz, zf, f"{k}.npy") for k in range(26)]
    n_all = dense.shape[0]
    if dense.ndim != 2 or dense.shape[1] != 13:
        sys.exit(f"dense shape {dense.shape}")
    for k, m in enumerate(sp):
        if m.ndim != 2 or m.shape != (n_all, HOT[k]) or m.dtype.kind not in "iu":
            sys.exit(f"member {k}.npy: shape {m.shape} dtype {m.dtype}, expected ({n_all}, {HOT[k]}) int")
    if a.start < 0 or a.count <= 0 or a.start + a.count > n_all:
        sys.exit(f"bad --start/--count for {n_all} samples")
    src = f"{a.label} [{a.start},{a.start + a.count}) of {n_all}; file order (time order unverified)".encode()[:95]
    offs = np.cumsum([0] + HOT)
    with open(a.out, "xb") as f:
        f.write(struct.pack("<QIIQQ96s", MAGIC, VERSION, REC.itemsize, a.count, 0, src))
        for s in range(a.start, a.start + a.count, a.chunk):
            e = min(s + a.chunk, a.start + a.count)
            r = np.empty(e - s, dtype=REC)
            r["dense"] = np.asarray(dense[s:e], dtype="<f4")
            for k in range(26):
                x = np.asarray(sp[k][s:e])
                if (x < 0).any():
                    sys.exit(f"negative id in table {k} rows [{s},{e})")
                r["ids"][:, offs[k]:offs[k + 1]] = x.astype("<u4")
            r.tofile(f)
    print(f"wrote {a.count} samples [{a.start}, {a.start + a.count}) of {n_all} to {a.out}")


if __name__ == "__main__":
    main()

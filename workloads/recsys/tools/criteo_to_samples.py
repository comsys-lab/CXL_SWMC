#!/usr/bin/env python3
"""Convert MLPerf/torchrec preprocessed Criteo 1TB click logs (one-hot) into a recsys samples file (samples.h).

Input: the output of torchrec_dlrm scripts/process_Criteo_1TB_Click_Logs_dataset.sh for one day:
  day_<d>_dense.npy   float32 [N, 13]  (already log(1 + x) transformed)
  day_<d>_sparse.npy  int32   [N, 26]  (one-hot categorical ids; the server applies its row cap and multi-hot expansion)
Rows of a day are in time order (Criteo logs are chronological), so [start, start + count) is a time-ordered trace.
Not run on real data yet (no Criteo copy on the Host, GPU server or guests, 2026-10-16); tested with tiny fake arrays.

usage: criteo_to_samples.py --dense day_23_dense.npy --sparse day_23_sparse.npy --out FILE [--start 0] [--count N]
                            [--label "criteo-1tb day_23"]
"""
import argparse
import struct
import sys

import numpy as np

MAGIC = 0x31504D5353595352  # "RSYSSMP1"
REC = np.dtype([("dense", "<f4", (13,)), ("sparse", "<u4", (26,))])
assert REC.itemsize == 156


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dense", required=True)
    ap.add_argument("--sparse", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--count", type=int, default=0)
    ap.add_argument("--label", default="criteo-1tb (mlperf preprocessed)")
    ap.add_argument("--chunk", type=int, default=1 << 20)
    a = ap.parse_args()
    dense = np.load(a.dense, mmap_mode="r")
    sparse = np.load(a.sparse, mmap_mode="r")
    if dense.ndim != 2 or dense.shape[1] != 13 or sparse.ndim != 2 or sparse.shape[1] != 26 or len(dense) != len(sparse):
        sys.exit(f"shape mismatch: dense {dense.shape} sparse {sparse.shape}")
    n = len(dense) - a.start if a.count == 0 else a.count
    if a.start < 0 or n <= 0 or a.start + n > len(dense):
        sys.exit("bad --start/--count")
    if (np.asarray(sparse[a.start:a.start + min(n, 4096)]) < 0).any():
        sys.exit("negative sparse ids")
    src = a.label.encode()[:95]
    with open(a.out, "wb") as f:
        f.write(struct.pack("<QIIQQ96s", MAGIC, 1, 156, n, 0, src))
        for s in range(a.start, a.start + n, a.chunk):
            e = min(s + a.chunk, a.start + n)
            r = np.empty(e - s, dtype=REC)
            r["dense"] = np.asarray(dense[s:e], dtype="<f4")
            r["sparse"] = np.asarray(sparse[s:e]).astype("<u4")
            r.tofile(f)
    print(f"wrote {n} samples [{a.start}, {a.start + n}) to {a.out}")


if __name__ == "__main__":
    main()

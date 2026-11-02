#!/usr/bin/env python3
"""Scaled v7 table image for Host tests (server --image with the same --row-cap / --row-div).
Rows per table = max(1, min(MLPerf rows, cap) // div) (layout.h Params::derive). With --src (the converted full
image) row r of table k is copied from the full image's row r (trained values of the low ids); else values are
N(0, 0.01) from --seed. Records: emb_v7.h layout, seq 0, acc --acc-init, csum as ckpt_convert.py.
usage: make_test_image.py --out F --row-cap C --row-div D [--src FULL.img] [--seed N] [--acc-init X]"""
import argparse
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
from ckpt_convert import row_csum  # noqa: E402

ROWS = [40000000, 39060, 17295, 7424, 20265, 3, 7122, 1543, 63, 40000000, 3067956, 405282, 10, 2209, 11938, 155, 4,
        976, 14, 40000000, 40000000, 40000000, 590152, 12973, 108, 36]
HDR = 4096


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--row-cap", type=int, required=True)
    ap.add_argument("--row-div", type=int, default=1)
    ap.add_argument("--src")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--acc-init", type=float, default=0.0)
    a = ap.parse_args()
    dim, elt = 128, 2
    rb = (64 + dim * elt + 63) // 64 * 64
    rows = [max(1, min(r, a.row_cap) // a.row_div) for r in ROWS]
    base = np.cumsum([0] + rows[:-1]).tolist()
    total = sum(rows)
    dt = np.dtype([("key", "<u8"), ("seq", "<u8"), ("csum", "<u4"), ("acc", "<f4"), ("pad", "u1", (40,)),
                   ("emb", "<f2", (dim,))])
    assert dt.itemsize == rb
    src = None
    if a.src:
        with open(a.src, "rb") as f:
            h = f.read(HDR)
        sb = struct.unpack_from("<26Q", h, 40 + 26 * 8)
        src = (np.memmap(a.src, dtype=dt, mode="r", offset=HDR), sb)
    rng = np.random.default_rng(a.seed)
    hdr = bytearray(HDR)
    struct.pack_into("<QIIQIIQ", hdr, 0, 0x31474d4953595352, 1, rb, total, dim, elt, HDR)
    struct.pack_into("<26Q", hdr, 40, *rows)
    struct.pack_into("<26Q", hdr, 40 + 26 * 8, *base)
    with open(a.out, "xb") as f:
        f.write(bytes(hdr))
        for k in range(26):
            r = np.arange(rows[k], dtype=np.uint64)
            rec = np.zeros(rows[k], dt)
            rec["key"] = (np.uint64(k + 1) << np.uint64(56)) | r
            rec["acc"] = a.acc_init
            if src:
                rec["emb"] = src[0][src[1][k]: src[1][k] + rows[k]]["emb"]
            else:
                rec["emb"] = rng.normal(0, 0.01, (rows[k], dim)).astype(np.float16)
            words = np.ascontiguousarray(rec["emb"]).view(np.uint32).reshape(rows[k], dim * elt // 4)
            rec["csum"] = row_csum(rec["key"], rec["seq"], words)
            rec.tofile(f)
    print(f"image {a.out}: {total} rows x {rb} B, row_cap {a.row_cap} row_div {a.row_div}")


if __name__ == "__main__":
    main()

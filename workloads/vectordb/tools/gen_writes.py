#!/usr/bin/env python3
"""Generate the deterministic write order for a vectordb run (DESIGN.md §2-§3, loadgen model).

Searches are made at run time by the loadgen plugin (query row and target drawn with its seed; E1 snapshot
ref_w = last write made before it), and arrival times come from the loadgen rate, so this file holds only the
writes: w_seq 1..W in order, independent INSERT and DELETE requests, each with its target VM.

Record ids: pool A row i -> id i (initial records, ins_seq 0); pool B row j -> id NA + j (inserted in pool B order).
Deletes pick uniformly among ids live at their w_seq (pool A and already inserted pool B ids).

Output: <out> = binary records (little-endian, 24 B each):
  u8 op (1 INSERT, 2 DELETE), u8 target_vm, u16 pad, u32 w_seq, u64 id, u32 vec_ref (pool B row; 0 for deletes),
  u32 pad
plus <out>.manifest.txt.

usage: gen_writes.py --out writes.bin --pool-a 1000000 --pool-b 1000000 --writes 2000000 [--insert-frac 0.5]
                     [--vms 2] [--seed S]
"""
import argparse, sys

import numpy as np

INSERT, DELETE = 1, 2
DTYPE = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"),
                  ("vec_ref", "<u4"), ("pad1", "<u4")])
assert DTYPE.itemsize == 24


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pool-a", type=int, required=True)
    ap.add_argument("--pool-b", type=int, required=True)
    ap.add_argument("--writes", type=int, required=True, help="W (must stay below the server's --max-writes)")
    ap.add_argument("--insert-frac", type=float, default=0.5)
    ap.add_argument("--vms", type=int, default=2)
    ap.add_argument("--seed", type=int, default=20261015)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    W = a.writes
    is_ins = rng.random(W) < a.insert_frac
    if is_ins.sum() > a.pool_b:
        sys.exit(f"{is_ins.sum()} inserts exceed pool B ({a.pool_b})")

    live = np.empty(a.pool_a + int(is_ins.sum()), dtype=np.uint64)  # O(1) swap-remove live set
    live[:a.pool_a] = np.arange(a.pool_a, dtype=np.uint64)
    nlive, next_b = a.pool_a, 0
    w = np.zeros(W, dtype=DTYPE)
    picks = rng.random(W)
    for k in range(W):
        if is_ins[k]:
            w["id"][k] = a.pool_a + next_b
            w["vec_ref"][k] = next_b
            live[nlive] = w["id"][k]
            nlive += 1
            next_b += 1
        else:
            if nlive == 0:
                sys.exit("live set empty")
            j = int(picks[k] * nlive)
            w["id"][k] = live[j]
            live[j] = live[nlive - 1]
            nlive -= 1
    w["op"] = np.where(is_ins, INSERT, DELETE)
    w["w_seq"] = np.arange(1, W + 1, dtype=np.uint32)
    w["target"] = rng.integers(0, a.vms, size=W, dtype=np.uint8)
    w.tofile(a.out)
    with open(a.out + ".manifest.txt", "w") as m:
        m.write("# vectordb writes (CXL_SWMC/workloads/vectordb/tools/gen_writes.py)\n")
        for k, v in sorted(vars(a).items()):
            m.write(f"{k}={v}\n")
        m.write(f"inserts={int(is_ins.sum())} deletes={int(W - is_ins.sum())} live_at_end={nlive}\n")
    print(f"writes={W} (ins {int(is_ins.sum())}, del {int(W - is_ins.sum())}) -> {a.out}")


if __name__ == "__main__":
    main()

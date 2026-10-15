#!/usr/bin/env python3
"""Generate one deterministic vectordb trace (DESIGN.md §2-§4).

Open-loop arrivals over a fixed duration: writes (independent INSERT and DELETE requests, a replacement = one of
each) at --write-rate per second, searches at --search-rate per second, each a Poisson process. Every write gets
w_seq 1..W in scheduled order (the generator-assigned global write order); every search gets
ref_w = last w_seq scheduled at or before it. target_vm is uniform over --vms (fixed seed).

Record ids: pool A row i -> id i (initial records, ins_seq 0); pool B row j -> id NA + j (inserted in pool B order).
Deletes pick uniformly among ids live at their w_seq (pool A and already inserted pool B ids).

Output (numpy .npy structured array, one row per request, sorted by sched_t):
  op_seq u64, op u8 (1 INSERT, 2 DELETE, 3 SEARCH), id u64 (writes), vec_ref u32 (pool B row / query row),
  sched_t u64 ns, target_vm u8, w_seq u32 (writes; 0 for searches), ref_w u32 (searches; 0 for writes)
plus <out>.manifest.txt.

usage: gen_trace.py --out trace.npy --pool-a 1000000 --pool-b 1000000 --queries 10000
                    --duration-s 60 --write-rate 2000 --search-rate 5000 [--insert-frac 0.5] [--vms 2] [--seed S]
"""
import argparse, sys

import numpy as np

INSERT, DELETE, SEARCH = 1, 2, 3
DTYPE = np.dtype([("op_seq", "<u8"), ("op", "u1"), ("id", "<u8"), ("vec_ref", "<u4"), ("sched_t", "<u8"),
                  ("target_vm", "u1"), ("w_seq", "<u4"), ("ref_w", "<u4")])


def poisson_times(rng, rate, duration_ns):
    if rate <= 0:
        return np.zeros(0, dtype=np.uint64)
    n = rng.poisson(rate * duration_ns / 1e9)
    return np.sort(rng.integers(0, duration_ns, size=n, dtype=np.uint64))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pool-a", type=int, required=True)
    ap.add_argument("--pool-b", type=int, required=True)
    ap.add_argument("--queries", type=int, required=True)
    ap.add_argument("--duration-s", type=float, required=True)
    ap.add_argument("--write-rate", type=float, required=True)
    ap.add_argument("--search-rate", type=float, required=True)
    ap.add_argument("--insert-frac", type=float, default=0.5)
    ap.add_argument("--vms", type=int, default=2)
    ap.add_argument("--max-writes", type=int, default=16 << 20, help="applied-bitmap budget (W)")
    ap.add_argument("--seed", type=int, default=20261015)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    dur = int(a.duration_s * 1e9)

    wt = poisson_times(rng, a.write_rate, dur)
    st = poisson_times(rng, a.search_rate, dur)
    W = len(wt)
    if W > a.max_writes:
        sys.exit(f"W={W} exceeds the applied-bitmap budget {a.max_writes}")
    is_ins = rng.random(W) < a.insert_frac
    if is_ins.sum() > a.pool_b:
        sys.exit(f"{is_ins.sum()} inserts exceed pool B ({a.pool_b})")

    # live set as an array with O(1) swap-remove; ids < pool_a are live at start
    live = np.empty(a.pool_a + int(is_ins.sum()), dtype=np.uint64)
    live[:a.pool_a] = np.arange(a.pool_a, dtype=np.uint64)
    nlive, next_b = a.pool_a, 0
    w_id = np.empty(W, dtype=np.uint64)
    w_ref = np.zeros(W, dtype=np.uint32)
    for k in range(W):
        if is_ins[k]:
            w_id[k] = a.pool_a + next_b
            w_ref[k] = next_b
            live[nlive] = w_id[k]
            nlive += 1
            next_b += 1
        else:
            if nlive == 0:
                sys.exit("live set empty")
            j = int(rng.integers(0, nlive))
            w_id[k] = live[j]
            live[j] = live[nlive - 1]
            nlive -= 1

    tr = np.zeros(W + len(st), dtype=DTYPE)
    tr["sched_t"][:W] = wt
    tr["op"][:W] = np.where(is_ins, INSERT, DELETE)
    tr["id"][:W] = w_id
    tr["vec_ref"][:W] = w_ref
    tr["w_seq"][:W] = np.arange(1, W + 1, dtype=np.uint32)
    tr["sched_t"][W:] = st
    tr["op"][W:] = SEARCH
    tr["vec_ref"][W:] = rng.integers(0, a.queries, size=len(st), dtype=np.uint32)
    # ref_w = number of writes scheduled at or before the search (w_seq is 1-based and in time order)
    tr["ref_w"][W:] = np.searchsorted(wt, st, side="right").astype(np.uint32)
    tr["target_vm"] = rng.integers(0, a.vms, size=len(tr), dtype=np.uint8)
    # stable sort by time; writes before searches at equal times (ref_w uses side="right")
    order = np.lexsort((tr["op"], tr["sched_t"]))
    tr = tr[order]
    tr["op_seq"] = np.arange(len(tr), dtype=np.uint64)
    np.save(a.out, tr)

    with open(a.out + ".manifest.txt", "w") as m:
        m.write("# vectordb trace (CXL_SWMC/workloads/vectordb/tools/gen_trace.py)\n")
        for k, v in sorted(vars(a).items()):
            m.write(f"{k}={v}\n")
        m.write(f"writes={W} inserts={int(is_ins.sum())} deletes={int(W - is_ins.sum())} searches={len(st)}\n")
        m.write(f"live_at_end={nlive}\n")
    print(f"writes={W} (ins {int(is_ins.sum())}, del {int(W - is_ins.sum())}) searches={len(st)} -> {a.out}")


if __name__ == "__main__":
    main()

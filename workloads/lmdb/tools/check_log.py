#!/usr/bin/env python3
"""Exact MVCC check of an lmdb loadgen run with --opt log=1 (workloads/lmdb/DESIGN.md §6).

For every successful get (key k, snapshot txnid S, version v read): v must be the version of the last acknowledged
update of k with commit txnid <= S, or 0 (initial image) if there is none. Updates whose response never arrived are not
in the log; a get that read such a version is counted as `unlogged`, not as a violation (reported separately).
Also checks that update txnids are unique (one update = one write txn) and gets' snapshot >= min_txnid.
usage: check_log.py <loadgen out dir>          exit 0 = no violation
"""
import bisect
import collections
import struct
import sys

REC = struct.Struct("<QQQQIHBBQ")  # seq, key, txnid, version, writer, status, measured, target, min_txnid


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % REC.size:
        sys.exit(f"{path}: size not a multiple of {REC.size}")
    return [REC.unpack_from(data, i) for i in range(0, len(data), REC.size)]


def main():
    d = sys.argv[1]
    gets, ups = load(d + "/gets.bin"), load(d + "/updates.bin")
    per_key = collections.defaultdict(list)  # key -> sorted [(txnid, version)]
    txnids = collections.Counter()
    for _, key, txnid, version, _, status, _, _, _ in ups:
        if status == 0:
            per_key[key].append((txnid, version))
            txnids[txnid] += 1
    for v in per_key.values():
        v.sort()
    versions = {(k, ver) for k, v in per_key.items() for _, ver in v}
    dup = sum(1 for c in txnids.values() if c > 1)
    ok = viol = unlogged = stale = 0
    examples = []
    for _, key, snap, version, _, status, _, _, min_txnid in gets:
        if status != 0:
            continue
        if snap < min_txnid:
            stale += 1
        lst = per_key.get(key, [])
        i = bisect.bisect_right(lst, (snap, float("inf")))
        want = lst[i - 1][1] if i else 0
        if version == want:
            ok += 1
        elif version != 0 and (key, version) not in versions:
            unlogged += 1
        else:
            viol += 1
            if len(examples) < 5:
                examples.append((key, snap, version, want))
    print(f"gets_checked={ok + viol + unlogged} ok={ok} violations={viol} unlogged={unlogged} stale={stale} "
          f"updates_ok={sum(len(v) for v in per_key.values())} duplicate_txnids={dup}")
    for e in examples:
        print("violation key=%d snapshot=%d read_version=%d expected=%d" % e)
    sys.exit(1 if viol or stale or dup else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Offline check of a rocksdb loadgen run with --opt log=1 (verifier LOW, 2026-10-18).

Reads <dir>/gets.bin and <dir>/updates.bin (LogRec, workloads/rocksdb/loadgen/rocksdb_plugin.cc) and checks:
  - every acknowledged update has a unique stamp;
  - every successful get returned either the initial image (stamp 0, version 0, writer 0xffff) or exactly the
    (key, version, writer) of the acknowledged update with that stamp (a value is never mixed up); a get that
    returned the value of an update never acknowledged in this log counts as foreign (conservative: FAIL);
  - per-key freshness: the stamp read >= the highest stamp of that key acknowledged before the get was made
    (min_stamp, recorded by the plugin);
  - a get never returns a stamp that no update of this run produced (unless --allow-foreign, for multi-run tests
    whose servers kept state from an earlier loadgen run).
usage: check_log.py <loadgen out dir> [--allow-foreign]
"""
import struct
import sys

REC = struct.Struct("<QQQQIHBBQ")  # seq, key, stamp, version, writer, status, measured, target, min_stamp
OK = 0


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % REC.size:
        sys.exit(f"{path}: size {len(data)} not a multiple of {REC.size}")
    return [REC.unpack_from(data, i) for i in range(0, len(data), REC.size)]


def main():
    d = sys.argv[1]
    foreign_ok = "--allow-foreign" in sys.argv[2:]
    ups = load(f"{d}/updates.bin")
    gets = load(f"{d}/gets.bin")
    by_stamp = {}
    dup = 0
    for seq, key, stamp, version, writer, status, *_ in ups:
        if status != OK:
            continue
        if stamp in by_stamp:
            dup += 1
        by_stamp[stamp] = (key, version, writer)
    bad = stale = foreign = initial = ok = 0
    for seq, key, stamp, version, writer, status, measured, target, min_stamp in gets:
        if status != OK:
            continue
        if stamp < min_stamp:
            stale += 1
        if stamp == 0:
            initial += 1
            if version != 0 or writer != 0xFFFF:
                bad += 1
            continue
        w = by_stamp.get(stamp)
        if w is None:
            foreign += 1
        elif w != (key, version, writer):
            bad += 1
        else:
            ok += 1
    print(f"check_log: updates={len(ups)} gets={len(gets)} matched={ok} initial={initial} foreign={foreign} "
          f"dup_stamps={dup} mismatched={bad} stale={stale}")
    fail = dup or bad or stale or (foreign and not foreign_ok)
    print("check_log:", "FAIL" if fail else "OK")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()

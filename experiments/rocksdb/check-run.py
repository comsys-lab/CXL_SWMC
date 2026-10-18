#!/usr/bin/env python3
"""Server-side pass criteria of one rocksdb run (experiments/rocksdb/run.sh; workloads/rocksdb/DESIGN.md §9).

usage: check-run.py RUN_DIR --nodes N [--stop-extents-free E] [--stop-blocks-free B]
Checks, for every node k:
  - node<k>.log has the clean-stop stats ("rocksdb-server: stopping") and in them
    remote_errors = get_errors = update_errors = get_retry_limit = 0 and remoteV.errors = remoteV.catchup_errors = 0
    for every remote view V (MED-4, MED-A: a get that found a value elsewhere still answers, so these counters, not
    the loadgen, show remote failures);
  - pools.extents_free >= E and pools.blocks_free >= B in the final stats and in every loadgen --stats-op snapshot of
    that node (loadgen/stats/step*-{begin,end}-t<k>.txt) (MED-5 stop rule).
Prints one line per node and "check: PASS|FAIL"; exit 1 on FAIL.
"""
import argparse
import glob
import os
import re
import sys


def kv(text):
    d = {}
    for line in text.splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def num(d, k):
    try:
        return int(d.get(k, "0"))
    except ValueError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--nodes", type=int, required=True)
    ap.add_argument("--keys", type=int, default=0)
    ap.add_argument("--stop-extents-free", type=int, default=2048)
    ap.add_argument("--stop-blocks-free", type=int, default=16)
    a = ap.parse_args()
    bad = []
    for k in range(a.nodes):
        log = os.path.join(a.run, f"node{k}.log")
        if not os.path.exists(log):
            bad.append(f"node{k}: no log")
            continue
        text = open(log, errors="replace").read()
        if "rocksdb-server: stopping" not in text:
            bad.append(f"node{k}: no clean-stop stats")
            continue
        s = kv(text.split("rocksdb-server: stopping", 1)[1])
        views = sorted({m.group(1) for m in (re.match(r"^(remote\d+)\.gets$", x) for x in s) if m})
        if len(views) != a.nodes - 1:
            bad.append(f"node{k}: {len(views)} remote views, expected {a.nodes - 1}")
        keys = ["remote_errors", "get_errors", "update_errors", "get_retry_limit"] + \
               [v + x for v in views for x in (".errors", ".catchup_errors")]
        for x in keys:
            if num(s, x):
                bad.append(f"node{k}: {x}={num(s, x)}")
        # pool floors: final stats and every snapshot of this node
        snaps = [("final", s)] + [(os.path.basename(f), kv(open(f, errors="replace").read()))
                                  for f in sorted(glob.glob(os.path.join(a.run, "loadgen", "stats", f"step*-t{k}.txt")))]
        ext_min = blk_min = None
        for name, d in snaps:
            if "pools.extents_free" not in d:
                continue
            e, b = num(d, "pools.extents_free"), num(d, "pools.blocks_free")
            ext_min = e if ext_min is None else min(ext_min, e)
            blk_min = b if blk_min is None else min(blk_min, b)
            if e < a.stop_extents_free:
                bad.append(f"node{k}: {name}: pools.extents_free {e} < {a.stop_extents_free}")
            if b < a.stop_blocks_free:
                bad.append(f"node{k}: {name}: pools.blocks_free {b} < {a.stop_blocks_free}")
        print(f"node{k}: gets={s.get('gets')} updates={s.get('updates')} get_retries={s.get('get_retries')} "
              f"gc.dropped={s.get('gc.dropped')} views={','.join(views)} "
              f"catchups={','.join(s.get(v + '.catchups', '?') for v in views)} "
              f"sync_catchups={','.join(s.get(v + '.sync_catchups', '?') for v in views)} "
              f"extents_free_min={ext_min} blocks_free_min={blk_min} snapshots={len(snaps)} "
              f"sst_bytes={s.get('rocksdb.total-sst-files-size')}")
    if a.keys:  # completeness (verifier LOW): each node's image = its key share; every key in at least one DB
        man = open(os.path.join(a.run, "manifest.txt"), errors="replace").read()
        for k in range(a.nodes):
            want = (a.keys - k + a.nodes - 1) // a.nodes
            m = re.search(rf"^node{k} rocksdb-server: IMAGE (\d+) keys", man, re.M)
            if not m or int(m.group(1)) != want:
                bad.append(f"node{k}: image keys {m.group(1) if m else 'missing'} != {want}")
        tot = 0
        for k in range(a.nodes):
            p = os.path.join(a.run, f"verify-node{k}.txt")
            if os.path.exists(p):
                tot += num(kv(open(p).read()), "verify.entries")
        if tot and tot < a.keys:
            bad.append(f"verify entries over all nodes {tot} < keys {a.keys}")
        print(f"completeness: verify_entries_total={tot} keys={a.keys}")
    for b in bad:
        print("FAIL", b)
    print("check:", "FAIL" if bad else "PASS")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

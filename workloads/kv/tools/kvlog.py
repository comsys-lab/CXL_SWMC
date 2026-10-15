#!/usr/bin/env python3
"""kv-server trace logs (workloads/kv/proto.h TraceRec, 48 B: t_real_ns t_mono_ns key stamp slot page tid dur_ns).

  kvlog.py check <run dir> [--nodes 2]      consistency of node<k>.kv-{puts,gets}.bin (+ .kv-trace.txt): record
                                            count, key range, page = slot / 4, put writer = node, one slot per key
                                            across all logs; prints a summary, exit 1 on a violation
  kvlog.py csv <file.bin> [--out f.csv]     one CSV row per record
  kvlog.py classify <run dir> <faults.csv> [--out f.csv]
        MOT1 H2 Figure 2c (KV / page MSI): every read fault of a get, joined with both nodes' put and get logs.
        faults.csv columns: node,tid,t_real_ns,page,type   (type 'r' = read fault; others ignored)
        A fault is attributed to the get of the same node and thread whose [t_end - dur, t_end] contains it
        (gets must be logged in full: kv-server --trace-get-sample 1). Then, with t_prev = this node's previous get
        of any key of that page:
          true sharing  (TS): the other node put the key being read in (t_prev, t_fault]
          page false sharing (FS): the other node put only other keys of the page in that interval
          unexplained: neither (e.g. no previous read of the page on this node, or no matching get)
        Output: counts per class (and a per-fault CSV with --out).
"""
import argparse
import bisect
import collections
import csv
import os
import struct
import sys

REC = struct.Struct("<QQQQIIII")
assert REC.size == 48


def read(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % REC.size:
        raise SystemExit(f"{path}: size {len(data)} is not a multiple of {REC.size}")
    return [REC.unpack_from(data, i) for i in range(0, len(data), REC.size)]


def meta(path):
    m = {}
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                m[k] = v
    return m


def cmd_check(a):
    bad = 0
    slot_of = {}
    for k in range(a.nodes):
        base = os.path.join(a.run, f"node{k}")
        m = meta(base + ".kv-trace.txt")
        if not m:
            print(f"node{k}: no .kv-trace.txt")
            bad += 1
            continue
        keys = int(m["keys"])
        for kind in ("puts", "gets"):
            recs = read(f"{base}.kv-{kind}.bin")
            n_bad = 0
            if len(recs) != int(m[kind]):
                print(f"node{k} {kind}: {len(recs)} records, trace.txt says {m[kind]}")
                n_bad += 1
            for t_real, t_mono, key, stamp, slot, page, tid, dur in recs:
                writer, ver = stamp >> 56, stamp & ((1 << 56) - 1)
                ok = key < keys and page == slot // 4 and t_real > 0 and t_mono > 0 and tid > 0
                if kind == "puts":
                    ok = ok and writer == k and ver > 0
                if slot_of.setdefault(key, slot) != slot:
                    ok = False
                if not ok:
                    n_bad += 1
            durs = sorted(r[7] for r in recs)
            p50 = durs[len(durs) // 2] if durs else 0
            print(f"node{k} {kind}: {len(recs)} records, {len({r[2] for r in recs})} keys, "
                  f"{len({r[5] for r in recs})} pages, dur p50 {p50} ns, violations {n_bad}")
            bad += n_bad
    print(f"keys with a slot: {len(slot_of)}; distinct slots: {len(set(slot_of.values()))}")
    if len(set(slot_of.values())) != len(slot_of):
        print("two keys share a slot")
        bad += 1
    print("KVLOG CHECK", "PASS" if bad == 0 else f"FAIL ({bad})")
    return 0 if bad == 0 else 1


def cmd_csv(a):
    out = open(a.out, "w", newline="") if a.out else sys.stdout
    w = csv.writer(out)
    w.writerow(["t_real_ns", "t_mono_ns", "key", "writer", "version", "slot", "page", "tid", "dur_ns"])
    for t_real, t_mono, key, stamp, slot, page, tid, dur in read(a.file):
        writer = stamp >> 56  # 0xff = initial load (version 0; the low bits are the run tag)
        w.writerow([t_real, t_mono, key, writer, 0 if writer == 0xff else stamp & ((1 << 56) - 1), slot, page, tid, dur])
    return 0


def cmd_classify(a):
    nodes = {}
    for k in range(a.nodes):
        base = os.path.join(a.run, f"node{k}")
        nodes[k] = {"puts": read(base + ".kv-puts.bin"), "gets": read(base + ".kv-gets.bin")}
    # puts per (node, page): sorted (t, key); gets per (node, tid): sorted end times; gets per (node, page): sorted t
    puts_by_page = collections.defaultdict(list)
    gets_by_tid = collections.defaultdict(list)
    gets_by_page = collections.defaultdict(list)
    for k, d in nodes.items():
        for r in d["puts"]:
            puts_by_page[(k, r[5])].append((r[0], r[2]))
        for r in d["gets"]:
            gets_by_tid[(k, r[6])].append((r[0], r[0] - r[7], r[2], r[5]))
            gets_by_page[(k, r[5])].append(r[0] - r[7])
    for v in list(puts_by_page.values()) + list(gets_by_tid.values()) + list(gets_by_page.values()):
        v.sort()
    counts = collections.Counter()
    rows = []
    with open(a.faults) as f:
        for row in csv.DictReader(f):
            if row["type"] != "r":
                continue
            node, tid, t, page = int(row["node"]), int(row["tid"]), int(row["t_real_ns"]), int(row["page"])
            g = gets_by_tid.get((node, tid), [])
            i = bisect.bisect_left(g, (t,))
            cls, key = "unexplained", None
            if i < len(g) and g[i][1] <= t and g[i][3] == page:
                key = g[i][2]
                prev = gets_by_page[(node, page)]
                j = bisect.bisect_left(prev, g[i][1]) - 1  # previous get of this page on this node
                if j >= 0:
                    t_prev = prev[j]
                    other = [kk for nn in nodes if nn != node for (tp, kk) in puts_by_page.get((nn, page), [])
                             if t_prev < tp <= t]
                    if key in other:
                        cls = "true_sharing"
                    elif other:
                        cls = "page_false_sharing"
            counts[cls] += 1
            rows.append([node, tid, t, page, key, cls])
    if a.out:
        with open(a.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["node", "tid", "t_real_ns", "page", "key", "class"])
            w.writerows(rows)
    total = sum(counts.values())
    for c in ("true_sharing", "page_false_sharing", "unexplained"):
        print(f"{c}={counts[c]} ({100.0 * counts[c] / total if total else 0:.1f}%)")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="cmd", required=True)
    c = s.add_parser("check")
    c.add_argument("run")
    c.add_argument("--nodes", type=int, default=2)
    c = s.add_parser("csv")
    c.add_argument("file")
    c.add_argument("--out")
    c = s.add_parser("classify")
    c.add_argument("run")
    c.add_argument("faults")
    c.add_argument("--nodes", type=int, default=2)
    c.add_argument("--out")
    a = p.parse_args()
    return {"check": cmd_check, "csv": cmd_csv, "classify": cmd_classify}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

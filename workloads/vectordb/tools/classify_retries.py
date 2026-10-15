#!/usr/bin/env python3
"""Classify Megalon re-reads as false / true sharing (MOT1 v4 §4.3 "False-sharing classification").

Two kinds of events (vdb-server --backend megalon --trace-dir DIR, written at stop; server/megalon_backend.h,
DESIGN.md §13), both 48 B records "u64 object id, u32 off, len (the read's range), u64 s0, s1, u64 t_ns, u64 node":
  node<K>.megalon-retry.bin    a failed ObjectReadEnd (the read is re-run): s0 = HWcc write-section counter before
                               read_start, s1 = after the failed read_end
  node<K>.megalon-refetch.bin  a read section that found the object's HWcc objseq past this node's cache: a write
                               section completed on the object since the node last saw it, so ObjectReadStart
                               flushes and re-reads the whole object (Megalon's internal "incoherent" retry):
                               s0 = the node's cached seq, s1 = the new objseq
  node<K>.megalon-wsec.bin     one record per write section, after write_end: u64 seq (counter after it, all nodes),
                               u64 object id, u32 off0, len0, off1, len1 (written ranges; len1 = 0: one), u64 t_ns,
                               u64 node
Rule (per event e): candidates = write sections with seq in (s0, s1 + slack] on the same object by a PEER node.
true sharing: a candidate range overlaps e's read range; false sharing: candidates, none overlaps; otherwise
unexplained, or for refetches local_only when only the node's own writes are in the interval (no Megalon flush is
expected then; not a sharing event). Same-object writes of the reader's own node are counted (n_local_same_obj) but
do not change a class. Slack (default 0): the counter is taken after write_end, so a peer section that ended just
before a failed read_end may carry a seq > s1; --slack N widens the interval by N.
For a refetch the read range is that of the first read of the object after the change (later reads of other
ranges find the cache current), and a write landing between the objseq load and read_start is attributed to the
next read of the object.

Window (optional): --stats LOADGEN_DIR --step N keeps only events (and counts writes) inside that step's
measurement window on each node's own clock (t_mono_ns of stats/stepNNN-{begin,end}-t<k>.txt; the "node" key names
the node) and compares, per node, the Megalon counter delta megalon.read_retry_incoherent (ObjectReadStart's
incoherent retries AND failed ObjectReadEnd with PAGE_INCOHERENT) with refetches that have a peer write +
incoherent failed read_ends (= megt.rd_retries - megalon.read_retry_notify, window deltas); a large difference
means the per-node cache does not track Megalon's own state (e.g. several threads flushing the same object
concurrently).

usage: classify_retries.py --trace DIR --out PREFIX [--slack 0] [--stats LOADGEN_DIR --step N]
Output: PREFIX.events.csv (one row per event), PREFIX.summary.csv (per node, kind, class), PREFIX.summary.txt
(retries, refetches, combined = both kinds without local_only).
"""
import argparse, bisect, csv, glob, os, sys

import numpy as np

WSEC = np.dtype([("seq", "<u8"), ("id", "<u8"), ("off0", "<u4"), ("len0", "<u4"), ("off1", "<u4"), ("len1", "<u4"),
                 ("t_ns", "<u8"), ("node", "<u8")])
RETRY = np.dtype([("id", "<u8"), ("off", "<u4"), ("len", "<u4"), ("s0", "<u8"), ("s1", "<u8"), ("t_ns", "<u8"),
                  ("node", "<u8")])
assert WSEC.itemsize == 48 and RETRY.itemsize == 48
CLASSES = ["false_sharing", "true_sharing", "unexplained", "local_only"]
KINDS = ["retry", "refetch"]


def load(trace, suffix, dt):
    parts = []
    for p in sorted(glob.glob(os.path.join(trace, f"node*.megalon-{suffix}.bin"))):
        if os.path.getsize(p) % dt.itemsize:
            sys.exit(f"{p}: size is not a multiple of {dt.itemsize}")
        parts.append(np.fromfile(p, dtype=dt))
    return np.concatenate(parts) if parts else np.zeros(0, dtype=dt)


def snapshot(path):
    d = {}
    for line in open(path):
        k, s, v = line.strip().partition("=")
        if s and not k.startswith("#"):
            d[k] = v
    return d


def windows(stats_dir, step):
    """node -> (t0, t1, {Megalon counter deltas}) from the step's begin/end snapshots."""
    w = {}
    for p in glob.glob(os.path.join(stats_dir, "stats", f"step{step:03d}-begin-t*.txt")):
        b, e = snapshot(p), snapshot(p.replace("-begin-", "-end-"))
        dd = {k: int(e[k]) - int(b[k]) for k in ("megalon.read_retry_incoherent", "megalon.read_retry_notify",
                                                   "megt.rd_retries") if k in b and k in e}
        w[int(b["node"])] = (int(b["t_mono_ns"]), int(e["t_mono_ns"]), dd)
    if not w:
        sys.exit(f"no snapshots for step {step} in {stats_dir}/stats")
    return w


def in_window(rec, win):
    if win is None:
        return np.ones(len(rec), dtype=bool)
    m = np.zeros(len(rec), dtype=bool)
    for node, (t0, t1, _) in win.items():
        m |= (rec["node"] == node) & (rec["t_ns"] >= t0) & (rec["t_ns"] <= t1)
    return m


def overlaps(a0, alen, b0, blen):
    return blen > 0 and alen > 0 and a0 < b0 + blen and b0 < a0 + alen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--slack", type=int, default=0)
    ap.add_argument("--stats")
    ap.add_argument("--step", type=int)
    a = ap.parse_args()
    if (a.stats is None) != (a.step is None):
        sys.exit("--stats and --step go together")
    ws = load(a.trace, "wsec", WSEC)
    win = windows(a.stats, a.step) if a.stats else None
    events = {k: load(a.trace, k, RETRY) for k in KINDS}
    events = {k: v[in_window(v, win)] for k, v in events.items()}
    # writes are selected by counter value (s0, s1], not by time
    ws = ws[np.lexsort((ws["seq"], ws["id"]))]
    by_id = {}
    if len(ws):
        ids = ws["id"]
        cuts = np.flatnonzero(np.diff(ids)) + 1
        for lo, hi in zip(np.r_[0, cuts], np.r_[cuts, len(ws)]):
            by_id[int(ids[lo])] = (ws["seq"][lo:hi].tolist(), ws[lo:hi])
    rows, counts = [], {}
    for kind in KINDS:
        for r in events[kind]:
            rid, node, off, ln = int(r["id"]), int(r["node"]), int(r["off"]), int(r["len"])
            s0, s1 = int(r["s0"]), int(r["s1"]) + a.slack
            n_peer = n_peer_ov = n_local = 0
            if rid in by_id:
                seqs, recs = by_id[rid]
                for w in recs[bisect.bisect_right(seqs, s0):bisect.bisect_right(seqs, s1)]:
                    if int(w["node"]) == node:
                        n_local += 1
                        continue
                    n_peer += 1
                    if overlaps(off, ln, int(w["off0"]), int(w["len0"])) or overlaps(off, ln, int(w["off1"]), int(w["len1"])):
                        n_peer_ov += 1
            cls = ("true_sharing" if n_peer_ov else "false_sharing" if n_peer else
                   "local_only" if kind == "refetch" and n_local else "unexplained")
            counts.setdefault((node, kind), dict.fromkeys(CLASSES, 0))[cls] += 1
            rows.append([kind, node, int(r["t_ns"]), hex(rid), off, ln, int(r["s0"]), int(r["s1"]), cls, n_peer,
                         n_peer_ov, n_local])
    with open(a.out + ".events.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["kind", "node", "t_ns", "id", "off", "len", "s0", "s1", "class", "n_peer_same_obj",
                    "n_peer_overlap", "n_local_same_obj"])
        w.writerows(rows)
    nw = in_window(ws, win)
    nodes = sorted({n for n, _ in counts} | {int(x) for x in ws["node"]} | (set(win) if win else set()))
    zero = dict.fromkeys(CLASSES, 0)
    with open(a.out + ".summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["node", "kind", "events"] + CLASSES + ["write_sections_in_window", "megalon_read_retry_incoherent"])
        for node in nodes:
            for kind in KINDS + ["combined"]:
                if kind == "combined":
                    c = {k: sum(counts.get((node, kk), zero)[k] for kk in KINDS) for k in CLASSES}
                    c["local_only"] = 0
                else:
                    c = counts.get((node, kind), zero)
                inc = win[node][2].get("megalon.read_retry_incoherent", "") if win and node in win else ""
                w.writerow([node, kind, sum(c.values())] + [c[k] for k in CLASSES] +
                           [int((nw & (ws["node"] == node)).sum()), inc])
    with open(a.out + ".summary.txt", "w") as f:
        f.write(f"# classify_retries.py trace={a.trace} slack={a.slack} window="
                f"{'step %d of %s' % (a.step, a.stats) if win else 'whole trace'}\n")
        f.write(f"write_sections={len(ws)} write_sections_in_window={int(nw.sum())}\n")
        for kind in KINDS + ["combined"]:
            kk = KINDS if kind == "combined" else [kind]
            tot = {k: sum(c[k] for (n, kd), c in counts.items() if kd in kk) for k in CLASSES}
            if kind == "combined":
                tot["local_only"] = 0
            n = sum(tot[k] for k in CLASSES[:3])
            f.write(f"{kind}: events={n}" + "".join(
                f" {k}={tot[k]} ({100 * tot[k] / n:.1f}%)" if n else f" {k}={tot[k]}" for k in CLASSES[:3]) +
                (f" (local_only={tot['local_only']}, excluded)" if kind == "refetch" else "") + "\n")
        for node in nodes:
            line = f"node{node}"
            for kind in KINDS:
                c = counts.get((node, kind), zero)
                line += f" {kind}:" + ",".join(f"{k}={c[k]}" for k in CLASSES if kind == "refetch" or k != "local_only")
            dd = win[node][2] if win and node in win else {}
            if "megalon.read_retry_incoherent" in dd:
                c = counts.get((node, "refetch"), zero)
                peer = c["false_sharing"] + c["true_sharing"]
                # failed read_ends = notify (META_OUTDATE) + incoherent (PAGE_INCOHERENT; also counted by Megalon)
                inc_end = dd.get("megt.rd_retries", 0) - dd.get("megalon.read_retry_notify", 0)
                line += (f" | megalon.read_retry_incoherent={dd['megalon.read_retry_incoherent']} vs refetch_with_peer"
                         f"_write={peer} + incoherent_failed_read_end={inc_end} (= megt.rd_retries - read_retry_notify)"
                         f" = {peer + inc_end}")
            f.write(line + "\n")
    print(open(a.out + ".summary.txt").read(), end="")


if __name__ == "__main__":
    main()

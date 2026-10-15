#!/usr/bin/env python3
"""Classify Megalon read-section retries as false / true sharing (MOT1 §4.3 "False-sharing classification").

Inputs (vdb-server --backend megalon --trace-dir DIR, written at stop; server/megalon_backend.h):
  node<K>.megalon-wsec.bin   one 48 B record per write section, after write_end:
                             u64 seq (HWcc write-section counter after this section, all nodes), u64 object id,
                             u32 off0, len0, off1, len1 (written ranges; len1 = 0: one range), u64 t_ns, u64 node
  node<K>.megalon-retry.bin  one 48 B record per failed read_end: u64 object id, u32 off, len (read range),
                             u64 s0 (counter before read_start), u64 s1 (counter after the failed read_end),
                             u64 t_ns, u64 node
Rule (per retry r): the write sections W with seq in (s0, s1 + slack] on the same object by a PEER node (node !=
r.node) are the candidates. true sharing: some candidate range overlaps r's read range; false sharing: candidates
exist and none overlaps; unexplained: no candidate. Default slack 0 (the counter is incremented after write_end, so
a peer section that ended just before the failed read_end but incremented the counter after s1 was read is
"unexplained"; --slack N widens the interval by N counter values to bound that effect). Same-object writes of the
reader's own node in the interval are reported (n_local_same_obj) but do not change the class.

Window (optional): --stats LOADGEN_DIR --step N limits each node's retries and writes to that step's measurement
window [t_mono_ns of stats/stepNNN-begin-t<k>.txt, t_mono_ns of ...-end-t<k>.txt] on that node's own clock (the
"node" key of the snapshot names the node); without it the whole trace is used.

usage: classify_retries.py --trace DIR --out PREFIX [--slack 0] [--stats LOADGEN_DIR --step N]
Output: PREFIX.retries.csv (one row per retry), PREFIX.summary.txt (counts per node and class), PREFIX.summary.csv.
"""
import argparse, bisect, csv, glob, os, sys

import numpy as np

WSEC = np.dtype([("seq", "<u8"), ("id", "<u8"), ("off0", "<u4"), ("len0", "<u4"), ("off1", "<u4"), ("len1", "<u4"),
                 ("t_ns", "<u8"), ("node", "<u8")])
RETRY = np.dtype([("id", "<u8"), ("off", "<u4"), ("len", "<u4"), ("s0", "<u8"), ("s1", "<u8"), ("t_ns", "<u8"),
                  ("node", "<u8")])
assert WSEC.itemsize == 48 and RETRY.itemsize == 48
CLASSES = ["false_sharing", "true_sharing", "unexplained"]


def load(trace, suffix, dt):
    parts = []
    for p in sorted(glob.glob(os.path.join(trace, f"node*.megalon-{suffix}.bin"))):
        if os.path.getsize(p) % dt.itemsize:
            sys.exit(f"{p}: size is not a multiple of {dt.itemsize}")
        parts.append(np.fromfile(p, dtype=dt))
    return np.concatenate(parts) if parts else np.zeros(0, dtype=dt)


def windows(stats_dir, step):
    """node -> (t0, t1) on that node's monotonic clock, from the step's begin/end snapshots."""
    w = {}
    for p in glob.glob(os.path.join(stats_dir, "stats", f"step{step:03d}-begin-t*.txt")):
        q = p.replace("-begin-", "-end-")
        kv = []
        for f in (p, q):
            d = {}
            for line in open(f):
                k, s, v = line.strip().partition("=")
                if s and not k.startswith("#"):
                    d[k] = v
            kv.append(d)
        w[int(kv[0]["node"])] = (int(kv[0]["t_mono_ns"]), int(kv[1]["t_mono_ns"]))
    if not w:
        sys.exit(f"no snapshots for step {step} in {stats_dir}/stats")
    return w


def in_window(rec, win):
    if win is None:
        return np.ones(len(rec), dtype=bool)
    m = np.zeros(len(rec), dtype=bool)
    for node, (t0, t1) in win.items():
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
    ws, rs = load(a.trace, "wsec", WSEC), load(a.trace, "retry", RETRY)
    win = windows(a.stats, a.step) if a.stats else None
    rs = rs[in_window(rs, win)]
    # writes are not window-filtered by time: a retry's interval (s0, s1] selects them by counter value
    order = np.lexsort((ws["seq"], ws["id"]))
    ws = ws[order]
    by_id = {}
    if len(ws):
        ids = ws["id"]
        cuts = np.flatnonzero(np.diff(ids)) + 1
        for lo, hi in zip(np.r_[0, cuts], np.r_[cuts, len(ws)]):
            by_id[int(ids[lo])] = (ws["seq"][lo:hi].tolist(), ws[lo:hi])
    rows, counts = [], {}
    for r in rs:
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
        cls = "true_sharing" if n_peer_ov else "false_sharing" if n_peer else "unexplained"
        counts.setdefault(node, dict.fromkeys(CLASSES, 0))[cls] += 1
        rows.append([node, int(r["t_ns"]), hex(rid), off, ln, int(r["s0"]), int(r["s1"]), cls, n_peer, n_peer_ov, n_local])
    with open(a.out + ".retries.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["node", "t_ns", "id", "off", "len", "s0", "s1", "class", "n_peer_same_obj", "n_peer_overlap",
                    "n_local_same_obj"])
        w.writerows(rows)
    nw = in_window(ws, win)
    with open(a.out + ".summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["node", "retries"] + CLASSES + ["write_sections_in_window"])
        for node in sorted(set(counts) | set(int(x) for x in ws["node"])):
            c = counts.get(node, dict.fromkeys(CLASSES, 0))
            w.writerow([node, sum(c.values())] + [c[k] for k in CLASSES] + [int((nw & (ws["node"] == node)).sum())])
    tot = {k: sum(c[k] for c in counts.values()) for k in CLASSES}
    n = sum(tot.values())
    with open(a.out + ".summary.txt", "w") as f:
        f.write(f"# classify_retries.py trace={a.trace} slack={a.slack} window="
                f"{'step %d of %s' % (a.step, a.stats) if win else 'whole trace'}\n")
        f.write(f"write_sections={len(ws)} write_sections_in_window={int(nw.sum())} retries={n}\n")
        for k in CLASSES:
            f.write(f"{k}={tot[k]} ({100 * tot[k] / n:.1f}%)\n" if n else f"{k}=0\n")
        for node in sorted(counts):
            f.write(f"node{node} " + " ".join(f"{k}={counts[node][k]}" for k in CLASSES) + "\n")
    print(open(a.out + ".summary.txt").read(), end="")


if __name__ == "__main__":
    main()

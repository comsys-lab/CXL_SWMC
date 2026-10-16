#!/usr/bin/env python3
"""False vs true sharing of Megalon coherence events from a vdb-server sharing trace (MOT1 v6 Fig 3c;
reports/MOT1-v6-redesign-draft.md §4.3; DESIGN.md §16). Offline, Host only. Replaces classify_retries.py (v4 range-
overlap rule, v4/v5 trace files) for vdb builds >= 10.

usage: classify_sharing.py TRACE_DIR [--out PREFIX] [--searches N] [--a6-dir DIR]
TRACE_DIR holds node<K>.vdbtrace.bin of every node of one run (run.sh TRACE=1 run dir, host_smoke.sh scratch dir).

Trace (megalon_backend.h TraceRec, 32 B, per thread in the node's file): read sections (object, element, units, seq =
global write-section counter loaded after the accepted attempt's ObjectReadStart, flags = (A) count | (B) count << 4,
ev_ns = CohSnap stale_ns + concur_ns of the section, tsc) and write sections (object, element, units, seq = the write
section's global sequence number from the HWcc counter). Elements: vector chunk slot, delete-log entry, link block
(slot, level); units = consecutive elements (link: levels of the slot); 0 = the whole object.

Definition (Dubois et al., draft §4.3): an event ((A) stale copy or (B) concurrent write; a read section with flags) of
node n on object O is TRUE sharing if, while that copy lives (from the event until n's next event on O, or the end of
the trace), n reads at least one element modified by the writes that caused the event; otherwise FALSE.
  causing writes = writes on O by other nodes with seq_prev < seq <= seq_seen, seq_seen = the event section's seq,
  seq_prev = seq of n's latest refresh point on O before the event (node-local tsc order): its previous event, its own
  write section on O (Megalon's write end flushes the whole object and sets the node's local version), or its first
  read of O (the copy it started with). An event with no earlier refresh point is "no_prior_copy"; one without a
  causing write is "unexplained"; both are counted and excluded from true/false.
  reads of the copy = n's read records on O (any thread) with tsc in [event, next event); the event's own record is
  the accepted re-read and counts.
Sequence numbers: a write takes its seq inside its section (before ObjectWriteEnd) and a reader loads wsec after its
accepted ObjectReadStart, so an accepted read has seen exactly the writes on its object with seq <= its value (a write
that took its seq before the load but ended after the read's start overlaps the read section, which then fails).
Reads by several threads of one node are ordered by tsc (one VM, invariant TSC).
Implementation: numpy (sort by object and tsc, running maxima for refresh points and copy owners, searchsorted counts of
peer writes per (object, element) in (seq_prev, seq_seen]). Measured (Host, 2026-10-16): 1.6M records in 1.0 s and
210 MB peak (~130 B per record), identical to the earlier per-record Python version. Two nodes at the server's default
cap (--trace-max-mb 4096 = 134M records each) would need ~35 GB: run it pinned to node 1 or use --trace-max-mb <= 2048.
The --a6-dir export is plain Python and only for small traces.

Output: PREFIX.csv (one row per role: search, writer, main, all) with columns
  events_A, events_B [measured counts], sections_with_events, true_A, false_A, true_B, false_B, no_prior_copy,
  unexplained [measured counts of events], ev_ns_true, ev_ns_false, ev_ns_excluded [measured ns],
  false_time_share = ev_ns_false / (ev_ns_true + ev_ns_false) [derived], searches [measured],
  events_per_search_true, events_per_search_false [derived = events / searches]
and PREFIX.txt (summary). --a6-dir writes the provisional input of experiments/analysis/v6_fig3_megalon.py c
(writes.csv object,element,wseq; node<K>.log.csv R/E rows; n_search.txt) with element = "<kind>:<unit>" (vec, link,
dlog) and "*" for a whole-object write.
"""
import argparse, csv, glob, os, re, struct, sys
from collections import defaultdict

import numpy as np

HDR = struct.Struct("<8s4I8Q2I")  # TraceFileHdr
THR = struct.Struct("<2I2Q")      # TraceThreadHdr
REC = np.dtype([("tsc", "<u8"), ("seq", "<u4"), ("obj", "<u4"), ("elem", "<u4"), ("n", "<u2"), ("type", "u1"),
                ("flags", "u1"), ("ev_ns", "<u4"), ("pad", "<u4")])
assert HDR.size == 96 and THR.size == 24 and REC.itemsize == 32
ROLES = {0: "main", 1: "writer", 2: "search", 3: "other"}
READ, WRITE = 1, 2
ALL = None  # whole object


def load(path):
    b = open(path, "rb").read()
    h = HDR.unpack_from(b, 0)
    if h[0].rstrip(b"\0") != b"VDBTRC1":
        sys.exit(f"{path}: not a vdb trace")
    hdr = dict(node=h[1], nr_nodes=h[2], segments=h[3], threads=h[4], groups=h[5], dlog_chunks=h[6], per_chunk=h[7],
               dlog_chunk=h[8], wsec=h[9], tsc_khz=h[10], dropped=h[11], records=h[12], has_coh=h[13])
    off, parts = HDR.size, []
    for _ in range(hdr["threads"]):
        idx, role, cnt, dropped = THR.unpack_from(b, off)
        off += THR.size
        r = np.frombuffer(b, dtype=REC, count=cnt, offset=off)
        off += cnt * REC.itemsize
        parts.append((role, r))
    return hdr, parts


def kind_of(hdr, obj):
    vl = hdr["segments"] * hdr["groups"] * 2
    return "dlog" if obj >= vl else ("vec" if obj % 2 == 0 else "link")


def units(kind, elem, n):
    if n == 0:
        return ALL
    step = 1 << 24 if kind == "link" else 1
    return {int(elem) + k * step for k in range(int(n))}


def arrays(nodes):
    """per node: records of all threads concatenated (+ role), sorted by (object, tsc)"""
    out = {}
    for node, (hdr, parts) in nodes.items():
        r = np.concatenate([p for _, p in parts]) if parts else np.zeros(0, REC)
        role = np.concatenate([np.full(len(p), ro, np.uint8) for ro, p in parts]) if parts else np.zeros(0, np.uint8)
        o = np.lexsort((r["tsc"], r["obj"]))
        out[node] = (r[o], role[o])
    return out


def link_mask(hdr, obj):
    return (obj < hdr["segments"] * hdr["groups"] * 2) & (obj % 2 == 1)


def expand(hdr, r):
    """(record index, unit) for records with n > 0 (link: levels of the slot, others: consecutive elements)"""
    n = r["n"].astype(np.int64)
    rep = np.repeat(np.arange(len(r)), n)
    k = np.arange(len(rep)) - np.repeat(np.cumsum(n) - n, n)
    step = np.where(link_mask(hdr, r["obj"].astype(np.int64)), 1 << 24, 1)[rep]
    return rep, r["elem"].astype(np.int64)[rep] + k * step


def count_between(keys_sorted, base, lo, hi):
    """number of keys base<<32 | s with lo < s <= hi (keys_sorted: sorted uint64)"""
    b = base.astype(np.uint64) << np.uint64(32)
    return (np.searchsorted(keys_sorted, b | hi.astype(np.uint64), side="right")
            - np.searchsorted(keys_sorted, b | lo.astype(np.uint64), side="right"))


def classify(nodes):
    """nodes: {node: (hdr, parts)} -> per-role counters (vectorized; definition in the module doc)"""
    hdr0 = next(iter(nodes.values()))[0]
    A = arrays(nodes)
    # writes of all nodes: per (object, unit) and per object (whole-object writes and any write)
    w_pair, w_seq, w_node, o_key_all, o_key_whole = [], [], [], [], []
    for node, (r, _) in A.items():
        wr = r[r["type"] == WRITE]
        ri, u = expand(hdr0, wr)
        w_pair.append((wr["obj"][ri].astype(np.uint64) << np.uint64(32)) | u.astype(np.uint64))
        w_seq.append(wr["seq"][ri].astype(np.uint64))
        w_node.append(np.full(len(ri), node, np.int64))
        o_key_all.append((wr["obj"].astype(np.uint64) << np.uint64(32)) | wr["seq"].astype(np.uint64))
        wh = wr[wr["n"] == 0]
        o_key_whole.append(((wh["obj"].astype(np.uint64) << np.uint64(32)) | wh["seq"].astype(np.uint64),
                            np.full(len(wh), node, np.int64)))
    w_pair, w_seq, w_node = np.concatenate(w_pair), np.concatenate(w_seq), np.concatenate(w_node)
    pairs = np.unique(w_pair)
    dense = np.searchsorted(pairs, w_pair).astype(np.uint64)
    key = (dense << np.uint64(32)) | w_seq
    key_all = np.sort(key)
    key_node = {n: np.sort(key[w_node == n]) for n in A}
    oall = np.sort(np.concatenate(o_key_all))
    oown = {n: np.sort(k) for n, k in zip(A, o_key_all)}
    wh_all = np.sort(np.concatenate([k for k, _ in o_key_whole]))
    wh_own = {n: np.sort(k) for n, (k, _) in zip(A, o_key_whole)}
    keys = ["events_A", "events_B", "sections_with_events", "true_A", "false_A", "true_B", "false_B", "no_prior_copy",
            "unexplained", "ev_ns_true", "ev_ns_false", "ev_ns_excluded"]
    cnt = {r: dict.fromkeys(keys, 0) for r in ("search", "writer", "main", "other", "all")}
    for node, (r, role) in A.items():
        N = len(r)
        if not N:
            continue
        idx = np.arange(N)
        obj = r["obj"].astype(np.int64)
        gstart = np.ones(N, bool)
        gstart[1:] = obj[1:] != obj[:-1]
        g0 = np.maximum.accumulate(np.where(gstart, idx, 0))
        is_read, is_write = r["type"] == READ, r["type"] == WRITE
        is_ev = is_read & (r["flags"] != 0)
        ev = np.flatnonzero(is_ev)
        if not len(ev):
            continue
        refresh = is_write | is_ev | gstart  # own write, event, first record of the object (first read)
        last_ref = np.maximum.accumulate(np.where(refresh, idx, -1))
        prev = np.where(ev > 0, last_ref[np.maximum(ev - 1, 0)], -1)
        has_prev = (prev >= g0[ev]) & (ev > 0)
        seq = r["seq"].astype(np.int64)
        lo, hi = np.where(has_prev, seq[np.maximum(prev, 0)], 0), seq[ev]
        o_ev = obj[ev].astype(np.uint64)
        any_peer = count_between(oall, o_ev, lo, hi) - count_between(oown[node], o_ev, lo, hi)
        whole_peer = count_between(wh_all, o_ev, lo, hi) - count_between(wh_own[node], o_ev, lo, hi)
        # reads of each event's copy: owner = latest event at or before the read in the same object
        last_ev = np.maximum.accumulate(np.where(is_ev, idx, -1))
        rd = np.flatnonzero(is_read & (last_ev >= g0))
        owner = np.searchsorted(ev, last_ev[rd])  # position in ev
        ok = has_prev[owner]
        rd, owner = rd[ok], owner[ok]
        hit = whole_peer > 0
        whole_rd = r["n"][rd] == 0  # a whole-object read meets any peer write
        hit[np.unique(owner[whole_rd][any_peer[owner[whole_rd]] > 0])] = True
        sub = r[rd[~whole_rd]]
        so = owner[~whole_rd]
        ri, u = expand(hdr0, sub)
        q = (sub["obj"][ri].astype(np.uint64) << np.uint64(32)) | u.astype(np.uint64)
        pos = np.clip(np.searchsorted(pairs, q), 0, max(len(pairs) - 1, 0))
        found = (pairs[pos] == q) if len(pairs) else np.zeros(len(q), bool)
        qo = so[ri][found]
        d = pos[found].astype(np.uint64)
        c = count_between(key_all, d, lo[qo], hi[qo]) - count_between(key_node[node], d, lo[qo], hi[qo])
        hit[np.unique(qo[c > 0])] = True
        cls = np.where(~has_prev, 0, np.where(any_peer == 0, 1, np.where(hit, 2, 3)))  # no_prior, unexpl, true, false
        fl = r["flags"][ev].astype(np.int64)
        nA, nB, ens, rl = fl & 15, fl >> 4, r["ev_ns"][ev].astype(np.int64), role[ev]
        for rr in list(ROLES) + [None]:
            m = np.ones(len(ev), bool) if rr is None else rl == rr
            c_ = cnt["all" if rr is None else ROLES[rr]]
            c_["events_A"] += int(nA[m].sum())
            c_["events_B"] += int(nB[m].sum())
            c_["sections_with_events"] += int(m.sum())
            for k, nm in ((2, "true"), (3, "false")):
                mm = m & (cls == k)
                c_[f"{nm}_A"] += int(nA[mm].sum())
                c_[f"{nm}_B"] += int(nB[mm].sum())
                c_[f"ev_ns_{nm}"] += int(ens[mm].sum())
            for k, nm in ((0, "no_prior_copy"), (1, "unexplained")):
                mm = m & (cls == k)
                c_[nm] += int((nA[mm] + nB[mm]).sum())
                c_["ev_ns_excluded"] += int(ens[mm].sum())
    return cnt


def per_lists(nodes):
    """record lists for the A6 export (Python; slow on large traces)"""
    writes = defaultdict(list)
    per = defaultdict(lambda: defaultdict(list))
    for node, (hdr, parts) in nodes.items():
        for role, r in parts:
            for x in r:
                obj = int(x["obj"])
                u = units(kind_of(hdr, obj), x["elem"], x["n"])
                if x["type"] == WRITE:
                    writes[obj].append((int(x["seq"]), node, u))
                per[node][obj].append((int(x["tsc"]), int(x["type"]), int(x["seq"]), u, int(x["flags"]),
                                       int(x["ev_ns"]), role))
    for w in writes.values():
        w.sort(key=lambda t: t[0])
    for objs in per.values():
        for recs in objs.values():
            recs.sort(key=lambda t: t[0])
    return per, writes


def searches_from_logs(d):
    n = 0
    for p in glob.glob(os.path.join(d, "node*.log")):
        t = open(p, errors="replace").read()
        i = t.rfind("vdb-server: stopping")
        m = re.search(r"^searches=(\d+)$", t[i:], re.M) if i >= 0 else None
        n += int(m.group(1)) if m else 0
    return n or None


def write_a6(d, nodes, per, writes, nsearch):
    os.makedirs(d, exist_ok=True)
    any_hdr = next(iter(nodes.values()))[0]

    def el(obj, u):
        k = kind_of(any_hdr, obj)
        return ["*"] if u is ALL else [f"{k}:{x}" for x in sorted(u)]
    with open(os.path.join(d, "writes.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["object", "element", "wseq"])
        for obj, ws in sorted(writes.items()):
            for seq, node, u in ws:
                for e in el(obj, u):
                    w.writerow([obj, e, seq])
    for node, objs in per.items():
        rows = []
        for obj, recs in objs.items():
            refresh = None
            for tsc, typ, seq, u, flags, ev_ns, role in recs:
                if typ == WRITE:
                    refresh = seq
                    continue
                if flags:
                    if refresh is not None:
                        rows.append((tsc, ["E", obj, "A" if flags & 15 else "B", refresh, seq, ev_ns]))
                    refresh = seq
                elif refresh is None:
                    refresh = seq
                for e in el(obj, u):
                    rows.append((tsc, ["R", obj, e, "", ""]))
        rows.sort(key=lambda t: t[0])
        with open(os.path.join(d, f"node{node}.log.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["kind", "object", "a", "b", "c"])
            for _, r in rows:
                w.writerow(r)
    open(os.path.join(d, "n_search.txt"), "w").write(f"{nsearch or 0}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace_dir")
    ap.add_argument("--out")
    ap.add_argument("--searches", type=int)
    ap.add_argument("--a6-dir")
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.trace_dir, "node*.vdbtrace.bin")))
    if not files:
        sys.exit(f"no node*.vdbtrace.bin in {a.trace_dir}")
    nodes = {}
    for p in files:
        hdr, parts = load(p)
        nodes[hdr["node"]] = (hdr, parts)
    cnt = classify(nodes)
    ns = a.searches or searches_from_logs(a.trace_dir)
    out = a.out or os.path.join(a.trace_dir, "sharing")
    cols = ["role"] + list(cnt["all"]) + ["false_time_share", "searches", "events_per_search_true",
                                           "events_per_search_false"]
    with open(out + ".csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for role in ("search", "writer", "main", "all"):
            c = cnt[role]
            tf = c["ev_ns_true"] + c["ev_ns_false"]
            w.writerow([role] + list(c.values()) + [
                c["ev_ns_false"] / tf if tf else "", ns or "",
                (c["true_A"] + c["true_B"]) / ns if ns else "", (c["false_A"] + c["false_B"]) / ns if ns else ""])
    recs = sum(h["records"] for h, _ in nodes.values())
    drop = sum(h["dropped"] for h, _ in nodes.values())
    c = cnt["all"]
    txt = (f"nodes {sorted(nodes)}, records {recs}, dropped {drop}, thread_coh {[h['has_coh'] for h, _ in nodes.values()]}, "
           f"writes {sum(int((p['type'] == WRITE).sum()) for h, ps in nodes.values() for _, p in ps)}, events A {c['events_A']} B {c['events_B']}: "
           f"true {c['true_A'] + c['true_B']} false {c['false_A'] + c['false_B']} no_prior_copy {c['no_prior_copy']} "
           f"unexplained {c['unexplained']}, searches {ns}")
    open(out + ".txt", "w").write(txt + "\n")
    if a.a6_dir:
        per, writes = per_lists(nodes)
        write_a6(a.a6_dir, nodes, per, writes, ns)
    print(f"-> {out}.csv: {txt}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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
Known limits: seq is loaded after read_start, so a write whose ObjectWriteEnd finished before the read but whose
fetch-add came after the load gets a seq > seq_seen and is attributed to the next event; reads by several threads of
one node are ordered by tsc (one VM, invariant TSC).

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


def classify(nodes):
    """nodes: {node: (hdr, parts)} -> per-role counters, list of A6 rows"""
    writes = defaultdict(list)  # obj -> [(seq, node, units)]
    per = defaultdict(lambda: defaultdict(list))  # node -> obj -> [(tsc, kind, seq, units, flags, ev_ns, role)]
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
    keys = ["events_A", "events_B", "sections_with_events", "true_A", "false_A", "true_B", "false_B", "no_prior_copy",
            "unexplained", "ev_ns_true", "ev_ns_false", "ev_ns_excluded"]
    cnt = {r: dict.fromkeys(keys, 0) for r in ("search", "writer", "main", "other", "all")}
    for node, objs in per.items():
        for obj, recs in objs.items():
            recs.sort(key=lambda t: t[0])
            ev_idx = [i for i, t in enumerate(recs) if t[1] == READ and t[4]]
            if not ev_idx:
                continue
            wo = writes.get(obj, [])
            wseqs = [w[0] for w in wo]
            refresh_seq = None  # seq of the latest refresh point so far
            nxt = 0
            for k, i in enumerate(ev_idx):
                while nxt < i:  # refresh points before the event: own writes, first read
                    t = recs[nxt]
                    if t[1] == WRITE or (t[1] == READ and refresh_seq is None):
                        refresh_seq = t[2]
                    nxt += 1
                tsc, _, seq, _, flags, ev_ns, role = recs[i]
                nA, nB = flags & 15, flags >> 4
                rn = ROLES.get(role, "other")
                for r in (rn, "all"):
                    cnt[r]["events_A"] += nA
                    cnt[r]["events_B"] += nB
                    cnt[r]["sections_with_events"] += 1
                prev = refresh_seq
                refresh_seq = seq  # the event refreshes the copy
                nxt = i + 1
                if prev is None:
                    cls = "no_prior_copy"
                else:
                    lo = np.searchsorted(wseqs, prev, side="right")
                    hi = np.searchsorted(wseqs, seq, side="right")
                    cause = [w for w in wo[lo:hi] if w[1] != node]
                    if not cause:
                        cls = "unexplained"
                    else:
                        mod = set()
                        whole = False
                        for w in cause:
                            if w[2] is ALL:
                                whole = True
                                break
                            mod |= w[2]
                        end = ev_idx[k + 1] if k + 1 < len(ev_idx) else len(recs)
                        hit = False
                        for t in recs[i:end]:
                            if t[1] == READ and (whole or t[3] is ALL or (t[3] & mod)):
                                hit = True
                                break
                        cls = "true" if hit else "false"
                for r in (rn, "all"):
                    c = cnt[r]
                    if cls in ("true", "false"):
                        c[f"{cls}_A"] += nA
                        c[f"{cls}_B"] += nB
                        c[f"ev_ns_{cls}"] += ev_ns
                    else:
                        c[cls] += nA + nB
                        c["ev_ns_excluded"] += ev_ns
    return cnt, per, writes


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
    cnt, per, writes = classify(nodes)
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
           f"writes {sum(len(v) for v in writes.values())}, events A {c['events_A']} B {c['events_B']}: "
           f"true {c['true_A'] + c['true_B']} false {c['false_A'] + c['false_B']} no_prior_copy {c['no_prior_copy']} "
           f"unexplained {c['unexplained']}, searches {ns}")
    open(out + ".txt", "w").write(txt + "\n")
    if a.a6_dir:
        write_a6(a.a6_dir, nodes, per, writes, ns)
    print(f"-> {out}.csv: {txt}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

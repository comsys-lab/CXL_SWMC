#!/usr/bin/env python3
"""Late responses of saturated loadgen steps (workloads/vectordb/tests/opcoh_check.py; Host only, read-only).

A loadgen step closes its statistics after a bounded drain (loadgen.cc: a request without a response by then is a
timeout, raw row done = 0). In an overload step that saturates ("outstanding > 1000", aborted) the server may still
answer such a request later. The vector DB plugin then records the response's op coherence block (op-coh.bin), and,
when the response arrives before finish() writes searches.bin, also the search record; a response that arrives
between finish() writing searches.bin and op-coh.bin is in op-coh.bin only (first seen: eval2 run 1 H1
pop-u10-slo-r1, steps 23 and 24). Such records are correct server work, but the loadgen counted them as timeouts:
they are not matched to an OK raw row (opsplit "unmatched") and may have no searches.bin record.

late(lg, recs) classifies op records (opsplit.OPLOG) by the loadgen raw row of the same frame req_id (rawid-step<N>.bin
sidecars, loadgen >= dd934dbd9):
  ok       raw row with a response (done > 0) and status OK
  late     raw row counted as a timeout (done = 0, or status kStatusTimeout = 4) in a step that was aborted or is an
           overload step (steps.jsonl): allowed, reported as NOTE by the checker
  bad      anything else (raw row of another status, a timeout outside an aborted/overload step, no raw row although
           every raw file has its sidecar)
  unknown  no sidecars (old runs): step membership not derivable
"""
import glob
import json
import os
import re

import numpy as np

TIMEOUT = 4  # experiments/loadgen/frame.h kStatusTimeout


def raw_rows(lg):
    """sorted req_ids and their (step, done, status) arrays over every raw-step<N>.bin; None when a raw file has no
    rawid sidecar of the same length"""
    ids, step, done, status = [], [], [], []
    for p in sorted(glob.glob(os.path.join(lg, "raw-step*.bin"))):
        n = int(re.search(r"raw-step(\d+)\.bin$", p).group(1))
        r = np.fromfile(p, dtype=np.uint64).reshape(-1, 4)
        q = p.replace("raw-step", "rawid-step")
        if not os.path.exists(q):
            return None
        i = np.fromfile(q, dtype=np.uint64)
        if len(i) != len(r):
            return None
        ids.append(i)
        step.append(np.full(len(r), n, np.int64))
        done.append(r[:, 2])
        status.append((r[:, 3] & np.uint64(0xffff)).astype(np.int64))
    if not ids:
        return None
    ids, step, done, status = (np.concatenate(x) for x in (ids, step, done, status))
    o = np.argsort(ids, kind="stable")
    return ids[o], step[o], done[o], status[o]


def step_info(lg):
    """step -> (phase, aborted, {stream: timeouts}) from steps.jsonl"""
    out = {}
    p = os.path.join(lg, "steps.jsonl")
    if os.path.isfile(p):
        for line in open(p):
            if line.strip():
                d = json.loads(line)
                out[d["step"]] = (d.get("phase"), bool(d.get("aborted")),
                                  {k: int(v.get("timeouts") or 0) for k, v in d.get("streams", {}).items()})
    return out


def saturated(info, step):
    ph, ab, _ = info.get(step, (None, False, {}))
    return ab or ph == "overload"


def saturated_timeouts(lg, stream):
    """loadgen timeouts (measured requests without a response at step close) of one stream, summed over the aborted /
    overload steps"""
    info = step_info(lg)
    return sum(t.get(stream, 0) for s, (_, _, t) in info.items() if saturated(info, s))


def late(lg, recs):
    """per record of recs (opsplit.OPLOG array): (class, step) with class ok | late | bad | unknown, step -1 when
    there is no raw row"""
    rr = raw_rows(lg)
    if rr is None:
        return [("unknown", -1)] * len(recs)
    ids, step, done, status = rr
    info = step_info(lg)
    out = []
    for q in recs["c"]["req_id"].astype(np.uint64):
        k = int(np.searchsorted(ids, q))
        if k >= len(ids) or ids[k] != q:
            out.append(("bad", -1))
            continue
        s, d, st = int(step[k]), int(done[k]), int(status[k])
        if d > 0 and st == 0:
            out.append(("ok", s))
        elif (d == 0 or st == TIMEOUT) and saturated(info, s):
            out.append(("late", s))
        else:
            out.append(("bad", s))
    return out


def search_timeouts(lg):
    """loadgen search timeouts summed over every step (steps.jsonl)"""
    return sum(t.get("search", 0) for _, _, t in step_info(lg).values())


def lost(lg, recs, stream):
    """requests of a stream the server answered but the loadgen never recorded (response after the op-coh.bin write
    or never delivered): saturated-step timeouts minus the measured late records of recs (that stream's op records);
    the closure of opcoh_check.py adds this many operations to the records. None without rawid sidecars."""
    cl = late(lg, recs[recs["measured"] == 1])
    if any(c == "unknown" for c, _ in cl):
        return None
    return saturated_timeouts(lg, stream) - sum(1 for c, _ in cl if c == "late")

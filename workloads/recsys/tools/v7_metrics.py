#!/usr/bin/env python3
"""RecSys v7 per-step and per-run model-quality metrics (DESIGN.md §10.6; reports/experiments/de-stijl-evaluation-isca27.md §R).

Host only, offline; reads one loadgen output dir (PART/loadgen or PART itself) and the two servers' stale-read logs.

Inputs
  scores.bin  RSYSSCR1: {u64 trace position, f32 score, u8 label, u8 measured, u8[2]} per scored sample (loadgen
              prequential=1); scoreq.bin RSYSSCQ1: {u64 query seq, u64 make CLOCK_MONOTONIC ns, u64 first, u32 pairs,
              u16 status, u8 measured, u8} per query response.
  stats/stepNNN-{begin,end}-t<k>.txt  loadgen stats snapshots (header mono_ns = loadgen clock, wall_ns =
              CLOCK_REALTIME of the loadgen host; body = server stats: updater_cpu_ns, ...).
  --stale0 F  node-0 (updater) RSYSSTL1 log: {u64 global row, u64 seq, u64 CLOCK_REALTIME ns} per write of a sampled
              row (after it is visible); --stale1 F the serving node's log, one record per lookup of a sampled row
              (seq read). Rows are sampled by a hash of the global row on both nodes (same set).
  --frozen F  recsys-score --mode frozen scores over a contiguous sample range covering the trace ([0, 2M) of day 23).

Formulas (per measured step n; window = [begin, end] snapshot of the serving target, loadgen clock)
  samples_scored   = scored samples of queries made in the window with measured = 1 (a sample scored twice counts twice)
  auc              = ROC AUC of those (score, label) pairs, ties at half credit (tools/auc.py roc_auc; = sklearn
                     roc_auc_score)
  logloss          = mean BCE, scores clipped to [1e-7, 1 - 1e-7]
  stale_read_frac  = sampled serving lookups in the window (wall_ns window) whose seq < the last seq node 0 had written
                     to that row at the read time / sampled serving lookups in the window
  stale_age_*_ms   = over the stale lookups: read time - visibility time of the first write newer than the seq read
                     (p50, p95 nearest-rank, max); empty when the step has no stale lookup
  updater_cpu_s_per_s = d(updater_cpu_ns of node 0) / 1e9 / window seconds (trainer + row-owner thread CPU)
Per run (auc_run.csv): samples_scored, auc, logloss over every measured step's samples; auc_frozen = checkpoint
  without updates over the same multiset of samples; auc_fresh = --fresh (the hw run at the same update rate; for the
  hw run itself = its own auc); gain_retained = (auc - auc_frozen) / (auc_fresh - auc_frozen).
Clock note: read/write times are CLOCK_REALTIME of two guests; the age resolution is bounded by their offset
  (recorded as is; no correction).

usage: v7_metrics.py PART [--stale0 F] [--stale1 F] [--frozen F] [--trace-n N] [--serve-target 1] [--update-target 0]
                     [--steps-out CSV] [--merge-steps CSV] [--auc-run CSV --system S --update-rate R --T T --run K
                     [--fresh AUC]]
"""
import argparse
import csv
import glob
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from auc import logloss, roc_auc  # noqa: E402

SCR = np.dtype([("sample", "<u8"), ("score", "<f4"), ("label", "u1"), ("measured", "u1"), ("pad", "u1", (2,))])
SCQ = np.dtype([("qseq", "<u8"), ("t_make", "<u8"), ("first", "<u8"), ("pairs", "<u4"), ("status", "<u2"),
                ("measured", "u1"), ("pad", "u1")])
STL = np.dtype([("row", "<u8"), ("seq", "<u8"), ("t", "<u8")])
STEP_COLS = ["samples_scored", "auc", "logloss", "stale_read_frac", "stale_age_p50_ms", "stale_age_p95_ms",
             "stale_age_max_ms", "updater_cpu_s_per_s"]
RUN_COLS = ["system", "update_rate", "T", "run", "samples_scored", "auc", "logloss", "auc_frozen", "auc_fresh",
            "gain_retained"]


def binfile(path, magic, dt, hdr=64):
    with open(path, "rb") as f:
        h = f.read(hdr)
        if h[:8] != magic:
            sys.exit(f"{path}: not a {magic.decode()} file")
        r = np.fromfile(f, dtype=dt)
    if magic in (b"RSYSSCR1", b"RSYSSCQ1"):
        n = int(np.frombuffer(h[8:16], "<u8")[0])
        if n != len(r):
            sys.exit(f"{path}: {len(r)} records, header says {n}")
    return r


def snap(path):
    head = open(path).readline()
    hd = dict(re.findall(r"(\w+)=(\S+)", head))
    body = {}
    for line in open(path).read().splitlines()[1:]:
        k, _, v = line.partition("=")
        body[k] = v
    return int(hd["mono_ns"]), int(hd["wall_ns"]), body


def windows(lg, target):
    """step -> (mono0, mono1, wall0, wall1, body0, body1) from stepNNN-begin/end-t<target>.txt"""
    out = {}
    for b in sorted(glob.glob(os.path.join(lg, "stats", f"step*-begin-t{target}.txt"))):
        n = int(re.search(r"step(\d+)-begin", b).group(1))
        e = b.replace("-begin-", "-end-")
        if os.path.isfile(e):
            m0, w0, b0 = snap(b)
            m1, w1, b1 = snap(e)
            out[n] = (m0, m1, w0, w1, b0, b1)
    return out


def stale_join(wr, rd):
    """per read: (stale bool, age ns or -1). Writes per row are in seq order (owners apply batches in order)."""
    if len(rd) == 0:
        return np.zeros(0, bool), np.zeros(0, np.int64)
    if len(wr) == 0:
        return np.zeros(len(rd), bool), np.full(len(rd), -1, np.int64)
    t0 = int(min(wr["t"].min(), rd["t"].min()))
    wt = ((wr["t"] - t0) // 1000).astype(np.uint64)  # us since t0 (< 2^36 for 19 h)
    rt = ((rd["t"] - t0) // 1000).astype(np.uint64)
    o = np.lexsort((wt, wr["row"]))
    wrow, wseq, wtu, wtn = wr["row"][o], wr["seq"][o], wt[o], wr["t"][o].astype(np.int64)
    kt = (wrow << np.uint64(36)) | wtu
    ks = (wrow << np.uint64(36)) | wseq
    if np.any(ks[1:] < ks[:-1]):
        print("v7_metrics: WARNING write seqs not monotone in time per row", file=sys.stderr)
    p = np.searchsorted(kt, (rd["row"] << np.uint64(36)) | rt, side="right") - 1
    okp = (p >= 0) & (wrow[np.maximum(p, 0)] == rd["row"])
    last = np.where(okp, wseq[np.maximum(p, 0)], 0)
    stale = rd["seq"] < last
    q = np.searchsorted(ks, (rd["row"] << np.uint64(36)) | rd["seq"], side="right")
    qc = np.minimum(q, len(ks) - 1)
    age = np.where(stale, rd["t"].astype(np.int64) - wtn[qc], -1)
    return stale, age


def pct(x, p):  # nearest rank
    x = np.sort(x)
    return float(x[max(0, int(np.ceil(p / 100 * len(x))) - 1)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("part")
    ap.add_argument("--stale0")
    ap.add_argument("--stale1")
    ap.add_argument("--frozen")
    ap.add_argument("--trace-n", type=int)
    ap.add_argument("--serve-target", type=int, default=1)
    ap.add_argument("--update-target", type=int, default=0)
    ap.add_argument("--steps-out")
    ap.add_argument("--merge-steps", help="add the step columns to this steps.csv (rows matched by step)")
    ap.add_argument("--auc-run")
    ap.add_argument("--system")
    ap.add_argument("--update-rate")
    ap.add_argument("--T", default="")
    ap.add_argument("--run", default="1")
    ap.add_argument("--fresh", type=float)
    a = ap.parse_args()
    lg = os.path.join(a.part, "loadgen") if os.path.isdir(os.path.join(a.part, "loadgen")) else a.part
    sc = binfile(os.path.join(lg, "scores.bin"), b"RSYSSCR1", SCR)
    sq = binfile(os.path.join(lg, "scoreq.bin"), b"RSYSSCQ1", SCQ)
    ws, wu = windows(lg, a.serve_target), windows(lg, a.update_target)
    wr = binfile(a.stale0, b"RSYSSTL1", STL) if a.stale0 else np.zeros(0, STL)
    rd = binfile(a.stale1, b"RSYSSTL1", STL) if a.stale1 else np.zeros(0, STL)
    stale, age = stale_join(wr, rd)
    rows, run_idx = [], []
    for n, (m0, m1, w0, w1, _, _) in sorted(ws.items()):
        qm = (sq["measured"] == 1) & (sq["t_make"] >= m0) & (sq["t_make"] <= m1) & (sq["pairs"] > 0)
        idx = np.concatenate([np.arange(f, f + p, dtype=np.int64) for f, p in zip(sq["first"][qm], sq["pairs"][qm])]) \
            if qm.any() else np.zeros(0, np.int64)
        run_idx.append(idx)
        r = {"step": n, "samples_scored": len(idx)}
        if len(idx):
            r["auc"], r["logloss"] = roc_auc(sc["label"][idx], sc["score"][idx]), logloss(sc["label"][idx], sc["score"][idx])
        if a.stale1:
            m = (rd["t"] >= w0) & (rd["t"] <= w1)
            if m.any():
                r["stale_read_frac"] = float(stale[m].mean())
                ag = age[m & stale] / 1e6
                if len(ag):
                    r["stale_age_p50_ms"], r["stale_age_p95_ms"], r["stale_age_max_ms"] = pct(ag, 50), pct(ag, 95), float(ag.max())
        if n in wu:
            um0, um1, _, _, b0, b1 = wu[n]
            if "updater_cpu_ns" in b0 and um1 > um0:
                r["updater_cpu_s_per_s"] = (int(b1["updater_cpu_ns"]) - int(b0["updater_cpu_ns"])) / 1e9 / ((um1 - um0) / 1e9)
        rows.append(r)

    def fmt(v):
        return "" if v is None else f"{v:.6g}" if isinstance(v, float) else str(v)
    if a.steps_out:
        with open(a.steps_out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["step"] + STEP_COLS)
            for r in rows:
                w.writerow([r["step"]] + [fmt(r.get(c)) for c in STEP_COLS])
    if a.merge_steps:
        by = {r["step"]: r for r in rows}
        src = list(csv.DictReader(open(a.merge_steps)))
        cols = list(src[0].keys()) if src else []
        cols += [c for c in STEP_COLS if c not in cols]
        tmp = a.merge_steps + ".v7tmp"
        with open(tmp, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            for s in src:
                r = by.get(int(s["step"]), {})
                w.writerow({**s, **{c: fmt(r.get(c)) for c in STEP_COLS}})
        os.replace(tmp, a.merge_steps)
    if a.auc_run:
        idx = np.concatenate(run_idx) if run_idx else np.zeros(0, np.int64)
        out = dict(system=a.system, update_rate=a.update_rate, T=a.T, run=a.run, samples_scored=len(idx))
        if len(idx):
            lab, s = sc["label"][idx], sc["score"][idx]
            out["auc"], out["logloss"] = roc_auc(lab, s), logloss(lab, s)
            if a.frozen:
                fz = binfile(a.frozen, b"RSYSSCR1", SCR)
                base = int(fz["sample"][0])
                pos = sc["sample"][idx].astype(np.int64)
                if a.trace_n:
                    pos = pos % a.trace_n
                fi = pos - base
                if fi.min() < 0 or fi.max() >= len(fz):
                    sys.exit("scored samples outside the frozen range")
                if not np.array_equal(fz["label"][fi], lab):
                    sys.exit("labels differ between the run and the frozen scores")
                out["auc_frozen"] = roc_auc(fz["label"][fi], fz["score"][fi])
                fresh = a.fresh if a.fresh is not None else (out["auc"] if a.system == "hw" else None)
                if fresh is not None:
                    out["auc_fresh"] = fresh
                    d = fresh - out["auc_frozen"]
                    out["gain_retained"] = (out["auc"] - out["auc_frozen"]) / d if d else float("nan")
        new = not os.path.isfile(a.auc_run)
        with open(a.auc_run, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(RUN_COLS)
            w.writerow([fmt(out.get(c)) for c in RUN_COLS])
    for r in rows:
        print(" ".join(f"{k}={fmt(r.get(k))}" for k in ["step"] + STEP_COLS))


if __name__ == "__main__":
    main()

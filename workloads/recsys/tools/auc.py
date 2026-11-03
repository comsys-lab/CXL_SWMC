#!/usr/bin/env python3
"""ROC AUC and logloss of recsys v7 score logs (DESIGN.md §10.5).

Input: one or more score files (64 B header "RSYSSCR1" + count; records {u64 sample, f32 score, u8 label, u8[3]}),
written by recsys-score (Host) or by the loadgen from the serving node's (score, label) replies. Every record counts
(a sample scored twice counts twice).

AUC = ROC AUC with ties at half credit (Mann-Whitney U with average ranks), numerically identical to
sklearn.metrics.roc_auc_score, which MLPerf's accuracy script for DLRM uses [citation to be verified via WebFetch,
DESIGN.md §10.5]; sklearn is not installed on the Host, so the rank formula is implemented here directly.
logloss = mean binary cross-entropy with predictions clipped to [1e-7, 1 - 1e-7] (fp32 scores).

--frozen F: also the AUC of the checkpoint without updates over the SAME multiset of sample indices (F = recsys-score
--mode frozen over a range covering them); --fresh A: update gain retained G = (AUC - AUC_frozen) / (A - AUC_frozen).
usage: auc.py SCORES... [--frozen F] [--fresh AUC] [--csv]
"""
import argparse
import sys

import numpy as np

REC = np.dtype([("sample", "<u8"), ("score", "<f4"), ("label", "u1"), ("pad", "u1", (3,))])


def load(path):
    with open(path, "rb") as f:
        h = f.read(64)
        if h[:8] != b"RSYSSCR1":
            sys.exit(f"{path}: not a RSYSSCR1 file")
        n = int(np.frombuffer(h[8:16], "<u8")[0])
        r = np.fromfile(f, dtype=REC)
    if len(r) != n:
        sys.exit(f"{path}: {len(r)} records, header says {n}")
    return r


def roc_auc(label, score):
    label = np.asarray(label, dtype=np.int64)
    score = np.asarray(score, dtype=np.float64)
    npos = int(label.sum())
    nneg = len(label) - npos
    if npos == 0 or nneg == 0:
        return float("nan")
    order = np.argsort(score, kind="mergesort")
    s = score[order]
    # average ranks for ties (1-based)
    ranks = np.empty(len(s), dtype=np.float64)
    starts = np.flatnonzero(np.r_[True, s[1:] != s[:-1]])
    ends = np.r_[starts[1:], len(s)]
    avg = (starts + 1 + ends) / 2.0  # mean of ranks starts+1 .. ends
    ranks_sorted = np.repeat(avg, ends - starts)
    ranks[order] = ranks_sorted
    u = ranks[label == 1].sum() - npos * (npos + 1) / 2.0
    return float(u / (npos * nneg))


def logloss(label, score):
    p = np.clip(np.asarray(score, dtype=np.float64), 1e-7, 1 - 1e-7)
    y = np.asarray(label, dtype=np.float64)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scores", nargs="+")
    ap.add_argument("--frozen")
    ap.add_argument("--fresh", type=float)
    ap.add_argument("--csv", action="store_true")
    a = ap.parse_args()
    r = np.concatenate([load(p) for p in a.scores])
    out = {"samples_scored": len(r), "positives": int(r["label"].sum()), "auc": roc_auc(r["label"], r["score"]),
           "logloss": logloss(r["label"], r["score"])}
    if a.frozen:
        fz = load(a.frozen)
        base = int(fz["sample"][0])
        if not np.array_equal(fz["sample"], np.arange(base, base + len(fz), dtype=np.uint64)):
            sys.exit(f"{a.frozen}: frozen scores must be one contiguous sample range")
        idx = r["sample"].astype(np.int64) - base
        if idx.min() < 0 or idx.max() >= len(fz):
            sys.exit(f"scored samples [{r['sample'].min()}, {r['sample'].max()}] outside the frozen range")
        if not np.array_equal(fz["label"][idx], r["label"]):
            sys.exit("labels differ between the run and the frozen scores")
        out["auc_frozen"] = roc_auc(fz["label"][idx], fz["score"][idx])
        out["logloss_frozen"] = logloss(fz["label"][idx], fz["score"][idx])
        if a.fresh is not None:
            d = a.fresh - out["auc_frozen"]
            out["auc_fresh"] = a.fresh
            out["gain_retained"] = (out["auc"] - out["auc_frozen"]) / d if d != 0 else float("nan")
    if a.csv:
        print(",".join(out))
        print(",".join(f"{v:.6f}" if isinstance(v, float) else str(v) for v in out.values()))
    else:
        print(" ".join(f"{k}={v:.6f}" if isinstance(v, float) else f"{k}={v}" for k, v in out.items()))


if __name__ == "__main__":
    main()

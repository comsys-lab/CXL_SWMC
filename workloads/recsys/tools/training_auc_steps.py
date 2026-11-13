#!/usr/bin/env python3
"""Per-step online-training AUC of one RecSys lifetime (experiment recsys-training-auc, reports/experiments/
recsys-training-auc.md). Host only, offline; evidence is only read.

Input: the lifetime's measured part dirs IN TIME ORDER (main-block.sh STREAM_AUC_STEPS: parts auc-1 .. auc-N, one
measured step each; the Host test: one part with several steps). Per part dir: loadgen/{scores.bin, scoreq.bin,
stats/stepNNN-{begin,end}-t<k>.txt} (as tools/v7_metrics.py), optional stale-n0.stl / stale-n1.stl (main-block.sh
v7_post copies) and ss-residence.csv (experiments/recsys/ss_hist.py delta; De Stijl lifetimes only).

Per measured step (global step number 1.., in part order then step order; window = serving target's begin / end
snapshot, loadgen clock; queries made in the window with measured = 1, as v7_metrics.py):
  samples_scored  scored samples of those queries (a sample scored twice counts twice)
  auc, logloss    tools/auc.py roc_auc / logloss over (score, label)
  auc_frozen      roc_auc of the frozen checkpoint scores (--frozen, recsys-score --mode frozen) of the SAME multiset
                  of trace positions (position mod --trace-n); empty without --frozen
  gain            auc - auc_frozen
  pred_ctr        mean served score;  true_ctr = mean label (calibration drift check)
  t_start_s       step begin (CLOCK_REALTIME of the loadgen host) - first step begin, seconds
  ss_p50_us, ss_p95_us, ss_max_us   SS-residence of the part (cumulative-histogram delta summed over the nodes):
                  log2 bucket lower bounds (us) of the 50th / 95th percentile and of the largest non-empty bucket;
                  empty without ss-residence.csv. A part with several steps repeats its part values.
  stale_frac      sampled serving lookups in the step's wall window whose seq < the last seq node 0 had written to
                  the row at the read time / sampled lookups (v7_metrics.py stale_join); empty without stale logs
--stale-summary CSV appends one row per lifetime: system, store, acc_init, stale_reads, stale_frac, stale_age_p50_ms,
  stale_age_p95_ms, stale_age_max_ms over all measured steps (the last part's stale logs = the whole lifetime).
usage: training_auc_steps.py --out CSV --system S --store rn|sr --acc-init X [--frozen F] [--trace-n N]
                             [--stale-summary CSV] PART...        training_auc_steps.py --selftest
--out is appended to (header written when the file is new); rows of a lifetime are written together.
"""
import argparse
import csv
import os
import struct
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from auc import logloss, roc_auc  # noqa: E402
from v7_metrics import SCQ, SCR, STL, binfile, pct, stale_join, windows  # noqa: E402

COLS = ["system", "store", "acc_init", "step", "t_start_s", "samples_scored", "auc", "auc_frozen", "gain", "logloss",
        "pred_ctr", "true_ctr", "ss_p50_us", "ss_p95_us", "ss_max_us", "stale_frac"]
SCOLS = ["system", "store", "acc_init", "stale_reads", "stale_frac", "stale_age_p50_ms", "stale_age_p95_ms",
         "stale_age_max_ms"]


def ss_summary(part):
    """-> (p50, p95, max) bucket lower bounds (us) of the summed cumulative delta, or Nones"""
    f = os.path.join(part, "ss-residence.csv")
    if not os.path.isfile(f):
        return None, None, None
    tot = {}
    for r in csv.DictReader(open(f)):
        if r["hist"] == "ss_residence_hist" and r["delta"] != "":
            tot[int(r["lo_us"])] = tot.get(int(r["lo_us"]), 0) + int(r["delta"])
    d = sorted(tot.items())
    n = sum(max(c, 0) for _, c in d)
    if n == 0:
        return None, None, None

    def at(p):
        k, acc = int(np.ceil(p / 100 * n)), 0
        for lo, c in d:
            acc += max(c, 0)
            if acc >= k:
                return lo
        return d[-1][0]
    return at(50), at(95), max(lo for lo, c in d if c > 0)


def part_rows(part, a, fz):
    lg = os.path.join(part, "loadgen") if os.path.isdir(os.path.join(part, "loadgen")) else part
    sc = binfile(os.path.join(lg, "scores.bin"), b"RSYSSCR1", SCR)
    sq = binfile(os.path.join(lg, "scoreq.bin"), b"RSYSSCQ1", SCQ)
    ws = windows(lg, a.serve_target)
    s0, s1 = (os.path.join(part, f"stale-n{k}.stl") for k in (0, 1))
    have_st = os.path.isfile(s0) and os.path.isfile(s1)
    if have_st:
        rd = binfile(s1, b"RSYSSTL1", STL)
        stale, age = stale_join(binfile(s0, b"RSYSSTL1", STL), rd)
    ss = ss_summary(part)
    out = []
    for n, (m0, m1, w0, w1, _, _) in sorted(ws.items()):
        qm = (sq["measured"] == 1) & (sq["t_make"] >= m0) & (sq["t_make"] <= m1) & (sq["pairs"] > 0)
        idx = np.concatenate([np.arange(f, f + p, dtype=np.int64) for f, p in zip(sq["first"][qm], sq["pairs"][qm])]) \
            if qm.any() else np.zeros(0, np.int64)
        r = {"wall0": w0, "samples_scored": len(idx), "ss_p50_us": ss[0], "ss_p95_us": ss[1], "ss_max_us": ss[2]}
        if len(idx):
            lab, s = sc["label"][idx], sc["score"][idx]
            r["auc"], r["logloss"] = roc_auc(lab, s), logloss(lab, s)
            r["pred_ctr"], r["true_ctr"] = float(np.mean(s, dtype=np.float64)), float(np.mean(lab, dtype=np.float64))
            if fz is not None:
                pos = sc["sample"][idx].astype(np.int64)
                if a.trace_n:
                    pos = pos % a.trace_n
                fi = pos - int(fz["sample"][0])
                if fi.min() < 0 or fi.max() >= len(fz):
                    sys.exit(f"{part} step {n}: scored samples outside the frozen range")
                if not np.array_equal(fz["label"][fi], lab):
                    sys.exit(f"{part} step {n}: labels differ between the run and the frozen scores")
                r["auc_frozen"] = roc_auc(fz["label"][fi], fz["score"][fi])
                r["gain"] = r["auc"] - r["auc_frozen"]
        if have_st:
            m = (rd["t"] >= w0) & (rd["t"] <= w1)
            if m.any():
                r["stale_frac"] = float(stale[m].mean())
        out.append(r)
    summ = None
    if have_st:
        ag = age[stale] / 1e6
        summ = {"stale_reads": int(len(rd)), "stale_frac": float(stale.mean()) if len(rd) else None,
                "stale_age_p50_ms": pct(ag, 50) if len(ag) else None, "stale_age_p95_ms": pct(ag, 95) if len(ag) else None,
                "stale_age_max_ms": float(ag.max()) if len(ag) else None}
    return out, summ


def fmt(v):
    return "" if v is None else f"{v:.6g}" if isinstance(v, float) else str(v)


def append(path, cols, rows):
    new = not os.path.isfile(path) or os.path.getsize(path) == 0
    with open(path, "a", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(cols)
        for r in rows:
            w.writerow([fmt(r.get(c)) for c in cols])


def run(a):
    fz = binfile(a.frozen, b"RSYSSCR1", SCR) if a.frozen else None
    rows, summ = [], None
    for p in a.parts:
        pr, s = part_rows(p, a, fz)
        rows += pr
        summ = s if s is not None else summ
    if not rows:
        sys.exit("no measured step in " + " ".join(a.parts))
    t0 = rows[0]["wall0"]
    for i, r in enumerate(rows):
        r.update(system=a.system, store=a.store, acc_init=a.acc_init, step=i + 1, t_start_s=(r["wall0"] - t0) / 1e9)
    append(a.out, COLS, rows)
    if a.stale_summary and summ is not None:
        append(a.stale_summary, SCOLS, [{**summ, "system": a.system, "store": a.store, "acc_init": a.acc_init}])
    for r in rows:
        print(" ".join(f"{c}={fmt(r.get(c))}" for c in COLS))
    return 0


def selftest():
    rng = np.random.default_rng(7)
    with tempfile.TemporaryDirectory() as d:
        frozen = os.path.join(d, "frozen.scr")
        N = 4000
        fzr = np.zeros(N, SCR)
        fzr["sample"] = np.arange(1000, 1000 + N)
        fzr["label"] = rng.random(N) < 0.1
        fzr["score"] = np.clip(0.1 + 0.2 * (fzr["label"] - 0.1) + 0.05 * rng.standard_normal(N), 0.001, 0.999)
        open(frozen, "wb").write(b"RSYSSCR1" + struct.pack("<Q", N) + b"\0" * 48 + fzr.tobytes())
        parts = []
        for k in range(2):  # two parts, one step each; the second with an SS histogram
            p = os.path.join(d, f"auc-{k + 1}")
            os.makedirs(os.path.join(p, "loadgen", "stats"))
            n = 1000
            sc = np.zeros(n, SCR)
            sc["sample"] = 1000 + k * n + np.arange(n)
            sc["label"] = fzr["label"][k * n:(k + 1) * n]
            sc["score"] = np.where(sc["label"] == 1, 0.3, 0.05).astype(np.float32)  # perfect ranking -> auc 1
            sc["measured"] = 1
            open(os.path.join(p, "loadgen", "scores.bin"), "wb").write(b"RSYSSCR1" + struct.pack("<Q", n) + b"\0" * 48 + sc.tobytes())
            q = np.zeros(10, SCQ)
            q["qseq"], q["t_make"], q["first"], q["pairs"], q["measured"] = np.arange(10), 100 + np.arange(10), np.arange(10) * 100, 100, 1
            open(os.path.join(p, "loadgen", "scoreq.bin"), "wb").write(b"RSYSSCQ1" + struct.pack("<Q", 10) + b"\0" * 48 + q.tobytes())
            for w, mono in (("begin", 50), ("end", 500)):
                open(os.path.join(p, "loadgen", "stats", f"step001-{w}-t1.txt"), "w").write(
                    f"# stats mono_ns={mono} wall_ns={(k * 300 + (0 if w == 'begin' else 1)) * 10**9}\nx=1\n")
            if k == 1:
                with open(os.path.join(p, "ss-residence.csv"), "w") as f:
                    f.write("node,hist,lo_us,pre,post,delta\n")
                    for node, lo, dl in ((0, 64, 10), (0, 1024, 8), (1, 64, 2), (1, 65536, 1)):
                        f.write(f"{node},ss_residence_hist,{lo},0,{dl},{dl}\n")
            parts.append(p)
        out = os.path.join(d, "steps.csv")
        a = argparse.Namespace(out=out, system="hw", store="sr", acc_init="0.01", frozen=frozen, trace_n=0,
                               stale_summary=None, serve_target=1, parts=parts)
        run(a)
        r = list(csv.DictReader(open(out)))
        assert [x["step"] for x in r] == ["1", "2"] and r[1]["t_start_s"] == "300", r
        assert float(r[0]["auc"]) == 1.0 and r[0]["auc_frozen"] and abs(float(r[0]["gain"]) - (1 - float(r[0]["auc_frozen"]))) < 1e-6
        assert abs(float(r[0]["true_ctr"]) - fzr["label"][:1000].mean()) < 1e-9
        assert r[0]["ss_p50_us"] == "" and (r[1]["ss_p50_us"], r[1]["ss_p95_us"], r[1]["ss_max_us"]) == ("64", "1024", "65536"), r[1]
        assert list(r[0].keys()) == COLS
    print("TRAINING AUC STEPS SELFTEST PASS")
    return 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--system", required=True)
    ap.add_argument("--store", required=True, choices=["rn", "sr"])
    ap.add_argument("--acc-init", required=True)
    ap.add_argument("--frozen")
    ap.add_argument("--trace-n", type=int, default=0)
    ap.add_argument("--stale-summary")
    ap.add_argument("--serve-target", type=int, default=1)
    ap.add_argument("parts", nargs="+")
    return run(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())

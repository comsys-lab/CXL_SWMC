#!/usr/bin/env python3
"""recall@k of stale-snapshot searches against the exact top-k of the FRESH snapshot (experiment
vector-db-staleness-recall; workloads/vectordb/DESIGN.md §20). Host only, offline (never during a measurement).

Inputs: searches.bin and stale.bin of one loadgen invocation with --opt stale_ms (every search group = one query row
sent len(LIST) times at one scheduled time t, copy i with snapshot s_i = ref_w(t - T_i)), the writes file of the run,
and the exact top-K' file over pools A + B (.npz: qrows, ids [Q, K'] in score order, na, pool_b_rows; ids >= na =
na + pool B row; workspaces/eval3/recall/out/topk-ab54m-k200-q10k.npz).
Visibility (DESIGN.md §4): a record is visible at s iff ins_seq <= s < del_seq (pool A: ins 0; inserted ids: the w_seq
of their INSERT; deleted ids: the w_seq of their DELETE). GT of a group = the first k records of the query's top-K'
list visible at the group's fresh snapshot (ref_w of T = 0); the exact stale top-k at s_i likewise.

Per T (measured groups only; a group counts as measured when a copy's response says so, a group without any response
when its scheduled time lies inside the measured groups' range):
  recall_ann      mean over groups of |ANN ids of copy T  &  GT| / k (no OK response = 0 hits)
  loss_pp         100 x mean over groups of (recall of copy T=0 - recall of copy T) (paired, same group)
  *_ci_lo/_hi     95 % percentile bootstrap over groups (--boot resamples, --seed)
  exact_loss_pp   100 x mean of (1 - |exact top-k(s_T) & GT| / k): staleness alone, no ANN error
  frac_queries_any_miss  fraction of groups whose exact top-k(s_T) misses at least one GT record
  p50_ms p99_ms   nearest-rank percentiles of copy T's latency from the scheduled time (no response = +inf)
  extra columns   groups (= searches), groups_excluded_short (top-K' list has < k visible records at the fresh or a
                  stale snapshot; excluded from every T), copies_not_ok, recall_ann_ok_only (copies with an OK response),
                  frac_ann_lower (ANN hits of copy T < copy T=0), mean_age_writes (mean fresh - sent, writes),
                  pred_pp (= 100 x 2 R T / N, N = pool A size = live records; the Host-only prediction line),
                  window_s (--window-s: the measured window of the run, as given by the caller)
--check: structural checks (every group has all T; sent non-increasing in T; sent(T=0) = fresh; searches.bin ref_w =
  sent and s_used = sent for OK responses; returned ids visible at the sent snapshot (E1); one fresh per group) ->
  "STALECHECK PASS|FAIL ..." and exit 1 on a failure. --monotone-tol X (with --check): recall_ann non-increasing in T
  within X (absolute) and loss_pp at the largest T > 0.

usage: staleness_recall.py --searches S --stale S --writes W --topk NPZ --out steps.csv [--run NAME] [--rate R]
                           [--k 10] [--boot 2000] [--seed 20261113] [--check] [--monotone-tol X]
"""
import argparse
import csv
import sys

import numpy as np

INSERT, DELETE = 1, 2
INF = np.iinfo(np.uint32).max
WDT = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"),
                ("vec_ref", "<u4"), ("pad1", "<u4")])
STALE = np.dtype([("seq", "<u8"), ("sched_ns", "<u8"), ("group", "<u4"), ("t_ms", "<u4"), ("fresh", "<u4"),
                  ("sent", "<u4"), ("lat_us", "<u4"), ("status", "<u2"), ("flags", "u1"), ("t_idx", "u1")])
assert STALE.itemsize == 40
COLS = ["run", "T_ms", "R_updates_s", "searches", "recall_ann", "recall_ann_ci_lo", "recall_ann_ci_hi", "loss_pp",
        "loss_ci_lo", "loss_ci_hi", "exact_loss_pp", "frac_queries_any_miss", "p50_ms", "p99_ms",
        "groups_excluded_short", "copies_not_ok", "recall_ann_ok_only", "frac_ann_lower", "mean_age_writes", "pred_pp",
        "window_s"]


def search_dtype(k):  # loadgen/vectordb_plugin.cc SearchLog (packed) + ids[k] + scores[k]
    return np.dtype([("seq", "<u8"), ("qrow", "<u4"), ("ref_w", "<u4"), ("s_used", "<u4"), ("measured", "u1"),
                     ("pad", "u1"), ("status", "<u2"), ("n", "<u2"), ("k", "<u2"), ("wait_us", "<u4"),
                     ("replay_us", "<u4"), ("search_us", "<u4"), ("lock_us", "<u4"), ("dists", "<u4"),
                     ("segs", "<u2"), ("pad2", "<u2"), ("ids", "<u8", (k,)), ("scores", "<f4", (k,))])


def first_k(vis, k):
    """vis bool [..., K'] in score order -> (mask of the first k visible, rows with >= k visible)."""
    c = np.cumsum(vis, axis=-1)
    return vis & (c <= k), c[..., -1] >= k


def pct(v, p):  # nearest rank, +inf allowed
    if len(v) == 0:
        return float("nan")
    v = np.sort(v)
    r = int(np.ceil(p / 100 * len(v)))
    return float(v[min(len(v) - 1, max(r, 1) - 1)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--searches", required=True)
    ap.add_argument("--stale", required=True)
    ap.add_argument("--writes", required=True)
    ap.add_argument("--topk", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run", default="run")
    ap.add_argument("--rate", type=float, default=float("nan"), help="update rate R of the run (updates/s; pred_pp)")
    ap.add_argument("--window-s", default="", help="measured window of the run (s), copied into steps.csv window_s")
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--boot", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=20261113)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--monotone-tol", type=float, default=None)
    a = ap.parse_args()
    k = a.k
    bad = []

    st = np.fromfile(a.stale, dtype=STALE)
    sr = np.fromfile(a.searches, dtype=search_dtype(k))
    if len(st) == 0:
        sys.exit("stale.bin is empty")
    if len(sr) and int(sr["k"][0]) != k:
        sys.exit(f"searches.bin has k={sr['k'][0]}, not {k}")
    if not (st["seq"] == np.arange(len(st))).all():
        sys.exit("stale.bin is not in seq order 0..n-1")
    nT = int(st["t_idx"].max()) + 1
    T_of = np.zeros(nT, dtype=np.int64)
    T_of[st["t_idx"]] = st["t_ms"]
    G = int(st["group"].max()) + 1
    if len(st) != G * nT:
        bad.append(f"records {len(st)} != groups {G} x copies {nT}")
    # [G, nT] views (records are made group by group, copies in LIST order)
    cnt = np.bincount(st["group"].astype(np.int64) * nT + st["t_idx"], minlength=G * nT)
    if (cnt != 1).any():
        bad.append(f"groups without exactly one copy per T: {int((cnt.reshape(G, nT) != 1).any(axis=1).sum())}")
        sys.exit("STALECHECK FAIL " + "; ".join(bad))
    order = np.lexsort((st["t_idx"], st["group"]))
    S = st[order].reshape(G, nT)
    # join searches.bin by seq (one record per response; at most one per seq)
    resp = np.full(len(st), -1, dtype=np.int64)
    if len(sr):
        if np.unique(sr["seq"]).size != len(sr) or sr["seq"].max() >= len(st):
            sys.exit("searches.bin seq values are not unique / beyond stale.bin")
        resp[sr["seq"].astype(np.int64)] = np.arange(len(sr))
    R = resp[S["seq"].astype(np.int64)]                                   # [G, nT] row in sr or -1
    has = R >= 0
    if ((S["flags"] & 1).astype(bool) != has).any():
        bad.append("stale.bin responded flags differ from the searches.bin records")
    okc = has & (np.where(has, sr["status"][np.maximum(R, 0)], 1) == 0)  # OK responses
    # measured groups
    mflag = ((S["flags"] & 2) > 0).any(axis=1)
    resp_any = has.any(axis=1)
    sched = S["sched_ns"][:, 0]
    if mflag.any():
        lo, hi = sched[mflag].min(), sched[mflag].max()
        measured = mflag | (~resp_any & (sched >= lo) & (sched <= hi))
    else:
        measured = mflag
    # structural checks
    tsort = np.argsort(T_of, kind="stable")
    if T_of[tsort[0]] != 0:
        bad.append("no T = 0 copy")
    sent = S["sent"].astype(np.int64)
    fresh = S["fresh"].astype(np.int64)
    if (fresh != fresh[:, :1]).any():
        bad.append("fresh differs within a group")
    fresh = fresh[:, 0]
    i0 = int(tsort[0])
    n_t0 = int((sent[:, i0] != fresh).sum())
    if n_t0:
        bad.append(f"sent(T=0) != fresh in {n_t0} groups")
    n_mono = int((np.diff(sent[:, tsort], axis=1) > 0).any(axis=1).sum())
    if n_mono:
        bad.append(f"sent snapshot increases with T in {n_mono} groups")
    if (S["sched_ns"] != sched[:, None]).any():
        bad.append("copies of a group with different scheduled times")
    Rr = np.maximum(R, 0)
    if (has & (sr["ref_w"][Rr].astype(np.int64) != sent)).any():
        bad.append("searches.bin ref_w != stale.bin sent")
    if (okc & (sr["s_used"][Rr].astype(np.int64) != sent)).any():
        bad.append("server s_used != sent snapshot")
    if (has & (sr["qrow"][Rr] != sr["qrow"][Rr[:, :1]])).any():
        bad.append("query row differs within a group")

    # visibility arrays (pool A size from the top-K' file)
    z = np.load(a.topk)
    na = int(z["na"])
    w = np.fromfile(a.writes, dtype=WDT)
    wi, wd = w[w["op"] == INSERT], w[w["op"] == DELETE]
    nrec = max(na, int(w["id"].max()) + 1 if len(w) else na)
    ins = np.full(nrec + 1, INF, dtype=np.uint32)  # + sentinel (never visible)
    ins[:na] = 0
    dele = np.full(nrec + 1, INF, dtype=np.uint32)
    ins[wi["id"].astype(np.int64)] = wi["w_seq"]
    dele[wd["id"].astype(np.int64)] = wd["w_seq"]
    SENT = nrec
    nb_rows = int(z["pool_b_rows"])
    id_of_row = np.full(nb_rows, SENT, dtype=np.int64)
    if len(wi):
        if int(wi["vec_ref"].max()) >= nb_rows:
            sys.exit("writes file references pool B rows beyond the top-K' file")
        id_of_row[wi["vec_ref"].astype(np.int64)] = wi["id"].astype(np.int64)
    # E1 over every returned id (all copies with a response)
    if len(sr):
        ids_all = sr["ids"].astype(np.int64)
        valid_all = np.arange(k)[None, :] < sr["n"][:, None]
        oob = valid_all & (ids_all >= nrec)
        idc = np.where(valid_all & ~oob, ids_all, SENT)
        s_all = sr["ref_w"].astype(np.int64)[:, None]
        vis_all = (ins[idc] <= s_all) & (s_all < dele[idc])
        okr = sr["status"] == 0
        e1_viol = int((valid_all & ~oob & ~vis_all)[okr].sum() + oob[okr].sum())
    else:
        e1_viol = 0
    if e1_viol:
        bad.append(f"E1 violations (returned ids invisible at the sent snapshot): {e1_viol}")

    # groups used: measured, with a known query row (some copy responded)
    qrow = np.where(has, sr["qrow"][Rr].astype(np.int64), -1).max(axis=1)
    use = measured & (qrow >= 0)
    n_noq = int((measured & (qrow < 0)).sum())  # measured groups without any response: all copies are misses
    tq = z["qrows"].astype(np.int64)
    tpos = np.full(max(int(tq.max()), int(qrow.max()) if len(qrow) else 0) + 1, -1, dtype=np.int64)
    tpos[tq] = np.arange(len(tq))
    if (tpos[qrow[use]] < 0).any():
        sys.exit("the top-K' file lacks query rows of this run")
    gi = np.nonzero(use)[0]
    cand = z["ids"][tpos[qrow[gi]]].astype(np.int64)                  # [g, K']
    mb = cand >= na
    cand[mb] = id_of_row[np.minimum(cand[mb] - na, nb_rows - 1)]
    cand[mb & (z["ids"][tpos[qrow[gi]]] - na >= nb_rows)] = SENT
    ci, cd = ins[cand], dele[cand]                                     # [g, K']
    fz = fresh[gi][:, None]
    gt_mask, ok_f = first_k((ci <= fz) & (fz < cd), k)
    sg = sent[gi][:, :, None]                                          # [g, nT, 1]
    ex_mask, ok_s = first_k((ci[:, None, :] <= sg) & (sg < cd[:, None, :]), k)  # [g, nT, K']
    keep = ok_f & ok_s.all(axis=1)
    n_short = int((~keep).sum())
    gi, cand, gt_mask, ex_mask = gi[keep], cand[keep], gt_mask[keep], ex_mask[keep]
    g = len(gi)
    exact_hits = (ex_mask & gt_mask[:, None, :]).sum(axis=2) / k      # [g, nT]
    gt = np.where(gt_mask, cand, -1)
    gt_sorted = -np.sort(-gt, axis=1)[:, :k]                           # the k GT ids (order irrelevant)
    Rg = R[gi]
    ids = np.where(Rg[:, :, None] >= 0, sr["ids"][np.maximum(Rg, 0)].astype(np.int64), -2)  # [g, nT, k]
    nval = np.where(Rg >= 0, sr["n"][np.maximum(Rg, 0)], 0)
    valid = np.arange(k)[None, None, :] < nval[:, :, None]
    okg = okc[gi]
    hit = (valid & (ids[:, :, :, None] == gt_sorted[:, None, None, :]).any(axis=3)).sum(axis=2) / k
    hit = np.where(okg, hit, 0.0)                                      # no OK response = 0 hits
    lat = np.where(S["flags"][gi] & 1, S["lat_us"][gi] / 1000.0, np.inf)

    rng = np.random.default_rng(a.seed)
    loss = hit[:, [i0]] - hit                                          # [g, nT]
    bm_r = np.zeros((a.boot, nT))
    bm_l = np.zeros((a.boot, nT))
    if g:
        for b0 in range(0, a.boot, 100):
            nb = min(100, a.boot - b0)
            ix = rng.integers(0, g, size=(nb, g))
            bm_r[b0:b0 + nb] = hit[ix].mean(axis=1)
            bm_l[b0:b0 + nb] = loss[ix].mean(axis=1)
    rows = []
    for t in tsort:
        T = int(T_of[t])
        r_ok = hit[:, t][okg[:, t]]
        rows.append({
            "run": a.run, "T_ms": T, "R_updates_s": "" if np.isnan(a.rate) else f"{a.rate:g}", "searches": g,
            "recall_ann": f"{hit[:, t].mean():.6f}" if g else "",
            "recall_ann_ci_lo": f"{np.percentile(bm_r[:, t], 2.5):.6f}" if g else "",
            "recall_ann_ci_hi": f"{np.percentile(bm_r[:, t], 97.5):.6f}" if g else "",
            "loss_pp": f"{100 * loss[:, t].mean():.5f}" if g else "",
            "loss_ci_lo": f"{100 * np.percentile(bm_l[:, t], 2.5):.5f}" if g else "",
            "loss_ci_hi": f"{100 * np.percentile(bm_l[:, t], 97.5):.5f}" if g else "",
            "exact_loss_pp": f"{100 * (1 - exact_hits[:, t]).mean():.5f}" if g else "",
            "frac_queries_any_miss": f"{(exact_hits[:, t] < 1).mean():.6f}" if g else "",
            "p50_ms": f"{pct(lat[:, t], 50):.3f}", "p99_ms": f"{pct(lat[:, t], 99):.3f}",
            "groups_excluded_short": n_short, "copies_not_ok": int((~okg[:, t]).sum()),
            "recall_ann_ok_only": f"{r_ok.mean():.6f}" if len(r_ok) else "",
            "frac_ann_lower": f"{(hit[:, t] < hit[:, i0]).mean():.6f}" if g else "",
            "mean_age_writes": f"{(fresh[gi] - sent[gi][:, t]).mean():.2f}" if g else "",
            "pred_pp": "" if np.isnan(a.rate) else f"{100 * 2 * a.rate * T / 1000 / na:.6f}",
            "window_s": a.window_s,
        })
    with open(a.out, "w", newline="") as f:
        cw = csv.DictWriter(f, fieldnames=COLS)
        cw.writeheader()
        for r in rows:
            cw.writerow(r)
    print(f"groups {G} (measured {int(measured.sum())}, used {g}, excluded short {n_short}, measured without any "
          f"response {n_noq}), copies per group {nT} T_ms {[int(T_of[t]) for t in tsort]}, e1_violations {e1_viol}")
    for r in rows:
        print(f"T={r['T_ms']:>6} ms recall {r['recall_ann']} [{r['recall_ann_ci_lo']}, {r['recall_ann_ci_hi']}] "
              f"loss {r['loss_pp']} pp [{r['loss_ci_lo']}, {r['loss_ci_hi']}] exact_loss {r['exact_loss_pp']} pp "
              f"any_miss {r['frac_queries_any_miss']} age {r['mean_age_writes']} p50 {r['p50_ms']} p99 {r['p99_ms']} ms")
    if a.check:
        if n_noq:  # verifier L3: a few groups lost at drain are a NOTE (no effect on the paired loss); many = FAIL
            if n_noq > max(5, 0.001 * int(measured.sum())):
                bad.append(f"{n_noq} measured groups without any response")
            else:
                print(f"NOTE: {n_noq} measured groups without any response (excluded; paired loss unaffected)")
        if a.monotone_tol is not None and g:
            rec = [float(r["recall_ann"]) for r in rows]
            up = [(rows[i]["T_ms"], rows[i + 1]["T_ms"]) for i in range(len(rec) - 1) if rec[i + 1] > rec[i] + a.monotone_tol]
            if up:
                bad.append(f"recall rises with T beyond {a.monotone_tol}: {up}")
            if not float(rows[-1]["loss_pp"]) > 0:
                bad.append(f"no loss at the largest T ({rows[-1]['T_ms']} ms)")
        print(("STALECHECK FAIL " + "; ".join(bad)) if bad else
              f"STALECHECK PASS groups={G} measured={int(measured.sum())} used={g} copies={nT} e1_violations={e1_viol}")
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

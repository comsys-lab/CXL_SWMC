#!/usr/bin/env python3
"""Coherence time per search of one vectordb run (DESIGN.md §14; MOT1 v5 Figure 1b; user 2026-10-16: per-query
attribution, search-serving threads only, writer reported separately, window time-share kept). Offline, Host only.

usage: qcoh.py RUN_DIR [--out RUN_DIR/qcoh-steps.csv] [--queries RUN_DIR/qcoh-queries.csv] [--tol-us 20]
RUN_DIR = a run.sh result dir (loadgen/ with search-coh.bin, searches.bin, raw-step*.bin, steps.jsonl, stats/).

Megalon per-query values come from 1-in-64 sampled read sections: per-query means (and step means) are robust;
per-query p50/p99 of a Megalon run (coh_p50_ms, coh_p99_ms) are distributions of sampled estimates (sampling noise
included), labelled as such in fig1b-query.csv (coh_pct_note).
Per query (loadgen/search-coh.bin, vectordb_plugin.cc CohLog = seq, recv_ns, measured, target, status + proto.h
SearchCoh): coherence time = pf_fault_ns (page MSI: managed-fault handler time of the query's sections) +
mg_check_est_ns (Megalon: sampled read-section checks minus 2 clock reads each, x kSample) + re-executed failed
attempts recomputed here from the raw sums (mg_estimate: 3 clock reads per timed failed attempt; the server's
mg_reexec_est_ns and coh_ns subtract only 1 and are not used). Each record
is matched to the loadgen raw record of the same request: the search-stream record of a raw-step file whose done time
is the latest one <= recv_ns within --tol-us (the engine takes done just before it calls the plugin on the same
thread); its step is the raw file's step, its latency done - sched. Records with more than one candidate in the
tolerance window are matched to the latest one and counted as ambiguous (as are raw records claimed twice).

Per step (qcoh-steps.csv; one row per measured step, nodes summed):
  step, phase, achieved (search/s), searches_window (server count, stats deltas), queries (coh records matched),
  ambiguous, unmatched_measured (run-level, same on every row), latency_mean_ms / p99 (matched queries),
  per query (matched): coh_mean_ms, coh_p50_ms, coh_p99_ms, coh_share_mean (coh / latency), pf_fault_mean_ms,
  pf_msg_wait_mean_ms, pf_local_wait_mean_ms, pf_other_mean_ms (= fault - msg wait - local wait), pf_faults_mean,
  pf_transactions_mean, mg_check_mean_ms, mg_reexec_mean_ms, mg_retries_mean, server_ms_mean (wait + replay +
  search of searches.bin), busy_mean_ms (thread time of the query's sections), coh_frac_of_busy (sum coh / sum
  busy; coh and busy are sums over parallel segment tasks and can exceed the latency; the proportional
  "wall-equivalent" column was removed for MOT1 v6),
  window time-share (search threads only, stats deltas / searches in the window): ts_search_coh_ms (page MSI:
  thr.vdb-search.swmc read+write fault ns; Megalon: megt.search.* calibrated like the per-query estimate),
  ts_search_msg_wait_ms, ts_vs_query (ts_search_coh_ms / coh_mean_ms),
  writer (separate; per update in the window): writer_coh_ms_per_update (page MSI thr.vdb-writer.swmc fault ns;
  Megalon megt.writer.*: read checks x sample + write_start + write_end (flush) + re-executed reads, calibrated),
  writer_wr_flush_ms_per_update (Megalon write_end), updates_window,
  clock_ns (timer overhead subtracted, end snapshot of node 0), qc_unattributed_fault_ns (window).
"""
import argparse, csv, glob, json, os, re, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loadgen"))
import stats_delta  # noqa: E402

COH = np.dtype([("version", "<u2"), ("source", "<u2"), ("sections", "<u4"), ("coh_ns", "<u8"),
                ("pf_fault_ns", "<u8"), ("pf_msg_wait_ns", "<u8"), ("pf_local_wait_ns", "<u8"),
                ("pf_faults", "<u4"), ("pf_transactions", "<u4"),
                ("mg_rd_sampled", "<u8"), ("mg_rd_start_ns", "<u8"), ("mg_rd_body_ns", "<u8"), ("mg_rd_end_ns", "<u8"),
                ("mg_rd_retries", "<u8"), ("mg_rd_failed_timed", "<u8"), ("mg_rd_failed_ns", "<u8"),
                ("clock_ns", "<u4"), ("mg_sample", "<u4"), ("mg_check_est_ns", "<u8"), ("mg_reexec_est_ns", "<u8"),
                ("busy_ns", "<u8")])
LOG = np.dtype([("seq", "<u8"), ("recv_ns", "<u8"), ("measured", "u1"), ("target", "u1"), ("status", "<u2"),
                ("pad", "<u4"), ("c", COH)])
assert COH.itemsize == 136 and LOG.itemsize == 160


def search_dtype(k):  # vectordb_plugin.cc SearchLog (same as e1_check.py)
    return np.dtype([("seq", "<u8"), ("qrow", "<u4"), ("ref_w", "<u4"), ("s_used", "<u4"), ("measured", "u1"),
                     ("pad", "u1"), ("status", "<u2"), ("n", "<u2"), ("k", "<u2"), ("wait_us", "<u4"),
                     ("replay_us", "<u4"), ("search_us", "<u4"), ("lock_us", "<u4"), ("dists", "<u4"),
                     ("segs", "<u2"), ("pad2", "<u2"), ("ids", "<u8", (k,)), ("scores", "<f4", (k,))])


def mg_estimate(start, body, end, sampled, retries, failed_timed, failed_ns, c, sample):
    """Megalon read-section coherence time (ns) from sampled sums, timer overhead c ns per clock read: checks
    (read_start + read_end - 2c per sampled section) x sample + retries x mean failed attempt. A timed failed
    attempt (megalon_backend.h read/account_read: t3 - t0) contains three clock reads (t1, t2 inside, t3 closing),
    so 3c per failed attempt. server/qcoh.h mg_estimate subtracts only 1c there: the server's mg_reexec_est_ns and
    coh_ns overstate by ~2c per retry and are NOT used; this function recomputes from the raw sums."""
    chk = max(0.0, start + end - 2 * c * sampled) * sample
    if retries and failed_timed:
        reexec = retries * max(0.0, failed_ns - 3 * c * failed_timed) / failed_timed
    elif retries and sampled:
        reexec = retries * max(0.0, start + body + end - 3 * c * sampled) / sampled
    else:
        reexec = 0.0
    return chk, reexec


def window_megalon(d, role, c, sample):
    g = lambda k: d.get(f"megt.{role}.{k}", 0)  # noqa: E731
    if f"megt.{role}.rd_sampled" not in d:
        return None
    chk, reexec = mg_estimate(g("rd_start_ns"), g("rd_body_ns"), g("rd_end_ns"), g("rd_sampled"), g("rd_retries"),
                              g("rd_failed_timed"), g("rd_failed_ns"), c, sample)
    n = g("wr_sections")
    wr_start = max(0.0, g("wr_start_ns") - c * n)
    flush = max(0.0, g("wr_end_ns") - c * n)
    return dict(rd_check=chk, reexec=reexec, wr_check=wr_start, flush=flush, total=chk + reexec + wr_start + flush)


def match(logs, raws, tol_ns):
    """index into the concatenated raw search records per coh record (-1 = none), ambiguous count"""
    done = raws["done"]
    order = np.argsort(done, kind="stable")
    ds = done[order]
    recv = logs["recv_ns"].astype(np.int64)
    hi = np.searchsorted(ds, recv, side="right") - 1  # latest done <= recv
    lo = np.searchsorted(ds, recv - tol_ns, side="left")
    ok = (hi >= 0) & (hi >= lo)
    idx = np.where(ok, order[np.clip(hi, 0, max(len(ds) - 1, 0))] if len(ds) else -1, -1)
    ambiguous = int((ok & (hi - lo >= 1)).sum())
    m = idx[idx >= 0]
    ambiguous += int(len(m) - len(np.unique(m)))  # two coh records on one raw record
    return idx, ambiguous


def load_raws(lg, search_idx):
    recs = []
    for p in sorted(glob.glob(os.path.join(lg, "raw-step*.bin"))):
        step = int(re.search(r"raw-step(\d+)\.bin$", p).group(1))
        r = np.fromfile(p, dtype=np.uint64).reshape(-1, 4)
        meas = ((r[:, 3] >> 40) & 1) == 1
        strm = (r[:, 3] >> 32) & 0xff
        ok = meas & (strm == search_idx) & (r[:, 2] > 0) & ((r[:, 3] & 0xffff) == 0)
        recs.append(np.rec.fromarrays([r[ok, 0].astype(np.int64), r[ok, 2].astype(np.int64),
                                       np.full(int(ok.sum()), step, dtype=np.int64)], names="sched,done,step"))
    if not recs:
        return np.rec.fromarrays([np.zeros(0, np.int64)] * 3, names="sched,done,step")
    return np.concatenate(recs).view(np.recarray)


def pct(v, q):
    return float(np.percentile(v, q)) if len(v) else None


COLS = ["step", "phase", "achieved", "searches_window", "queries", "ambiguous", "unmatched_measured", "latency_mean_ms",
        "latency_p99_ms", "coh_mean_ms", "coh_p50_ms", "coh_p99_ms", "coh_share_mean", "pf_fault_mean_ms",
        "pf_msg_wait_mean_ms", "pf_local_wait_mean_ms", "pf_other_mean_ms", "pf_faults_mean", "pf_transactions_mean",
        "mg_check_mean_ms", "mg_reexec_mean_ms", "mg_retries_mean", "server_ms_mean", "busy_mean_ms", "coh_frac_of_busy",
        "ts_search_coh_ms", "ts_search_msg_wait_ms", "ts_vs_query", "writer_coh_ms_per_update",
        "writer_wr_flush_ms_per_update", "updates_window", "clock_ns", "qc_unattributed_fault_ns"]
QCOLS = ["step", "seq", "target", "latency_ms", "coh_ms", "pf_fault_ms", "pf_msg_wait_ms", "pf_faults", "mg_check_ms",
         "mg_reexec_ms", "mg_retries", "sections", "server_ms", "busy_ms"]


def analyze(run, tol_us=20.0, want_queries=False):
    """(step rows, query rows, summary text) of one run dir (see the module doc)"""
    a = argparse.Namespace(run=run, tol_us=tol_us, queries=want_queries)
    lg = os.path.join(a.run, "loadgen")
    steps = [json.loads(x) for x in open(os.path.join(lg, "steps.jsonl"))]
    names = list(steps[0]["streams"]) if steps else ["update", "search"]
    sidx = names.index("search")
    path = os.path.join(lg, "search-coh.bin")
    logs = np.fromfile(path, dtype=LOG) if os.path.exists(path) else np.zeros(0, LOG)
    raws = load_raws(lg, sidx)
    idx, ambiguous = match(logs, raws, int(a.tol_us * 1000))
    meas = logs["measured"] == 1
    unmatched = int((meas & (idx < 0)).sum())
    k = 10
    kvt = os.path.join(lg, "vectordb.txt")
    if os.path.exists(kvt):
        for line in open(kvt):
            if line.startswith("k="):
                k = int(line.split("=")[1])
    sp = os.path.join(lg, "searches.bin")
    srv_ms = {}
    if os.path.exists(sp):
        sr = np.fromfile(sp, dtype=search_dtype(k))
        okr = sr["status"] == 0
        srv = (sr["wait_us"].astype(np.float64) + sr["replay_us"] + sr["search_us"]) / 1e3
        srv_ms = dict(zip(sr["seq"][okr].tolist(), srv[okr].tolist()))
    # per-step window deltas (nodes summed) + clock from the end snapshots
    snaps = stats_delta.load(lg)
    win = {}
    for fixed, d in stats_delta.deltas(lg):
        end = snaps[(fixed["step"], fixed["target"])]["end"][1]
        c = end.get("megt.clock_ns", end.get("qcoh.clock_ns", 0))
        sample = end.get("megt.sample", 64)
        w = win.setdefault(fixed["step"], dict(searches=0, updates=0, ts_pf=0.0, ts_pf_msg=0.0, wr_pf=0.0,
                                               ts_mg=None, wr_mg=None, wr_flush=None, clock=None, unattr=0, pf=False))
        w["searches"] += d.get("searches", 0)
        w["updates"] += d.get("updates", 0)
        if "thr.vdb-search.swmc.read_fault_ns" in d:
            w["pf"] = True
            w["ts_pf"] += d.get("thr.vdb-search.swmc.read_fault_ns", 0) + d.get("thr.vdb-search.swmc.write_fault_ns", 0)
            w["ts_pf_msg"] += d.get("thr.vdb-search.swmc.read_msg_wait_ns", 0) + d.get("thr.vdb-search.swmc.write_msg_wait_ns", 0)
            w["wr_pf"] += d.get("thr.vdb-writer.swmc.read_fault_ns", 0) + d.get("thr.vdb-writer.swmc.write_fault_ns", 0)
        ms, mw = window_megalon(d, "search", c, sample), window_megalon(d, "writer", c, sample)
        if ms:
            w["ts_mg"] = (w["ts_mg"] or 0) + ms["total"]
        if mw:
            w["wr_mg"] = (w["wr_mg"] or 0) + mw["total"]
            w["wr_flush"] = (w["wr_flush"] or 0) + mw["flush"]
        w["unattr"] += d.get("qcoh.unattributed_fault_ns", 0)
        if fixed["target"] == 0:
            w["clock"] = c
    rows, qrows = [], []
    lat_all = np.where(idx >= 0, (raws["done"][np.clip(idx, 0, None)] - raws["sched"][np.clip(idx, 0, None)]) / 1e6
                       if len(raws) else 0, np.nan)
    step_of = np.where(idx >= 0, raws["step"][np.clip(idx, 0, None)] if len(raws) else -1, -1)
    c = logs["c"]
    # Megalon re-executed work recomputed from the raw sums (3 clock reads per timed failed attempt, mg_estimate);
    # the server's mg_reexec_est_ns / coh_ns are not used. coh = page MSI fault time + Megalon checks + re-exec.
    rx = np.array([mg_estimate(float(x["mg_rd_start_ns"]), float(x["mg_rd_body_ns"]), float(x["mg_rd_end_ns"]),
                               float(x["mg_rd_sampled"]), float(x["mg_rd_retries"]), float(x["mg_rd_failed_timed"]),
                               float(x["mg_rd_failed_ns"]), float(x["clock_ns"]), float(x["mg_sample"]))[1]
                   if x["mg_rd_retries"] else 0.0 for x in c], dtype=np.float64)
    cohv = c["pf_fault_ns"].astype(np.float64) + c["mg_check_est_ns"] + rx
    for s in steps:
        if s["phase"] == "warmup" or s.get("measure_s", 0) <= 0:
            continue
        sel = step_of == s["step"]
        lat = lat_all[sel]
        coh = cohv[sel] / 1e6
        f = lambda col: float((c[col][sel] / 1e6).mean()) if sel.any() else None  # noqa: E731
        w = win.get(s["step"], {})
        nsr = w.get("searches", 0)
        ts = None
        if w.get("ts_mg") is not None:
            ts = w["ts_mg"] / nsr / 1e6 if nsr else None
        elif w.get("pf"):
            ts = w["ts_pf"] / nsr / 1e6 if nsr else None
        coh_mean = float(coh.mean()) if sel.any() else None
        upd = w.get("updates", 0)
        wr = w.get("wr_mg") if w.get("wr_mg") is not None else (w.get("wr_pf") if w.get("pf") else None)
        srvm = [srv_ms[q] for q in logs["seq"][sel].tolist() if q in srv_ms]
        busy = c["busy_ns"][sel].astype(np.float64)
        rows.append(dict(step=s["step"], phase=s["phase"], achieved=s["streams"]["search"]["achieved"],
                         searches_window=nsr, queries=int(sel.sum()), ambiguous=ambiguous, unmatched_measured=unmatched,
                         latency_mean_ms=float(lat.mean()) if sel.any() else None, latency_p99_ms=pct(lat, 99),
                         coh_mean_ms=coh_mean, coh_p50_ms=pct(coh, 50), coh_p99_ms=pct(coh, 99),
                         coh_share_mean=float((coh / lat).mean()) if sel.any() else None,
                         pf_fault_mean_ms=f("pf_fault_ns"), pf_msg_wait_mean_ms=f("pf_msg_wait_ns"),
                         pf_local_wait_mean_ms=f("pf_local_wait_ns"),
                         pf_other_mean_ms=float(((c["pf_fault_ns"][sel].astype(np.float64) - c["pf_msg_wait_ns"][sel]
                                                  - c["pf_local_wait_ns"][sel]) / 1e6).mean()) if sel.any() else None,
                         pf_faults_mean=float(c["pf_faults"][sel].mean()) if sel.any() else None,
                         pf_transactions_mean=float(c["pf_transactions"][sel].mean()) if sel.any() else None,
                         mg_check_mean_ms=f("mg_check_est_ns"), mg_reexec_mean_ms=float((rx[sel] / 1e6).mean()) if sel.any() else None,
                         mg_retries_mean=float(c["mg_rd_retries"][sel].mean()) if sel.any() else None,
                         server_ms_mean=float(np.mean(srvm)) if srvm else None,
                         busy_mean_ms=float(busy.mean() / 1e6) if sel.any() else None,
                         coh_frac_of_busy=float(cohv[sel].sum() / busy.sum()) if sel.any() and busy.sum() else None,
                         ts_search_coh_ms=ts,
                         ts_search_msg_wait_ms=w["ts_pf_msg"] / nsr / 1e6 if w.get("pf") and nsr else None,
                         ts_vs_query=ts / coh_mean if ts is not None and coh_mean else None,
                         writer_coh_ms_per_update=wr / upd / 1e6 if wr is not None and upd else None,
                         writer_wr_flush_ms_per_update=w["wr_flush"] / upd / 1e6 if w.get("wr_flush") is not None and upd else None,
                         updates_window=upd, clock_ns=w.get("clock"), qc_unattributed_fault_ns=w.get("unattr")))
        if a.queries:
            for i in np.flatnonzero(sel):
                qrows.append(dict(step=s["step"], seq=int(logs["seq"][i]), target=int(logs["target"][i]),
                                  latency_ms=float(lat_all[i]), coh_ms=float(cohv[i] / 1e6),
                                  pf_fault_ms=float(c["pf_fault_ns"][i] / 1e6), pf_msg_wait_ms=float(c["pf_msg_wait_ns"][i] / 1e6),
                                  pf_faults=int(c["pf_faults"][i]), mg_check_ms=float(c["mg_check_est_ns"][i] / 1e6),
                                  mg_reexec_ms=float(rx[i] / 1e6), mg_retries=int(c["mg_rd_retries"][i]),
                                  sections=int(c["sections"][i]), server_ms=srv_ms.get(int(logs["seq"][i])),
                                  busy_ms=float(c["busy_ns"][i] / 1e6)))
    gap = (logs["recv_ns"].astype(np.int64) - raws["done"][np.clip(idx, 0, None)])[idx >= 0] / 1e3 if len(raws) else np.zeros(0)
    summary = (f"{len(rows)} steps, {len(logs)} coh records, matched {int((idx >= 0).sum())}, ambiguous {ambiguous}, "
               f"unmatched measured {unmatched}, recv-done gap p50 {pct(gap, 50)} p99 {pct(gap, 99)} us")
    return rows, qrows, summary


def write(path, cols, rows):
    with open(path, "w", newline="") as fh:
        wtr = csv.writer(fh)
        wtr.writerow(cols)
        for r in rows:
            wtr.writerow(["" if r.get(x) is None else r[x] for x in cols])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--out")
    ap.add_argument("--queries")
    ap.add_argument("--tol-us", type=float, default=20)
    a = ap.parse_args()
    rows, qrows, summary = analyze(a.run, a.tol_us, bool(a.queries))
    out = a.out or os.path.join(a.run, "qcoh-steps.csv")
    write(out, COLS, rows)
    if a.queries:
        write(a.queries, QCOLS, qrows)
    print(f"-> {out}: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

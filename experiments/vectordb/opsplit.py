#!/usr/bin/env python3
"""Per-operation time split of one vectordb run (MOT1 v6 Fig 2 and Fig 3b; reports/MOT1-v6-redesign-draft.md §3,
§4.2; workloads/vectordb/DESIGN.md §15). Offline, Host only. Replaces qcoh.py for vdb builds >= 10 (qcoh.py stays for
the v1 search-coh.bin of earlier runs).

usage: opsplit.py RUN_DIR [--out RUN_DIR/opsplit-steps.csv] [--tol-us 20]
RUN_DIR = a run.sh result dir (loadgen/ with op-coh.bin, raw-step*.bin, steps.jsonl, optional stats/), or a
host_smoke.sh scratch dir (same layout).

Input per operation (loadgen/op-coh.bin = vectordb_plugin.cc OpLog: seq, recv_ns, measured, target, status, op + the
server's proto.h OpCoh v2 block): T = sum over the operation's sections of (end - start) rdtsc on the thread that ran
the section (search: start section + one per segment task; update: one section on the writer), C = change of the
thread's coherence counters across the same sections (Popcorn swmc_acct / build-8 file; Megalon CohSnap). Each record
is matched to the loadgen raw record of the same request (same stream; the latest done time <= recv_ns within
--tol-us); its step is the raw file's step and its latency done - sched.

Output: one row per (measured step, operation type) in --out and a column table <out without .csv>.columns.csv
(column, tag, unit, meaning). Tags: measured = sum of timed intervals / counted events / bytes; sampled×N = sum over
sampled intervals × N (N = the CohSnap check_sample in the records, e.g. sampled×64); derived = computed from other
columns (formula in the table). Means are per operation of that type: (1/N_o) sum_ops sum_threads. No proportional
"wall-equivalent" columns (thread-time sums are reported as they are). Per-operation C percentiles and the window C
are not exported (the per-operation Megalon check ratio estimate is biased; C means use the step's sums). A run whose
records carry more than one coherence source (mixed nodes or builds) is refused.
"""
import argparse, csv, glob, json, os, re, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loadgen"))
import stats_delta  # noqa: E402

OPCOH = np.dtype([("version", "<u2"), ("src", "<u2"), ("op", "<u2"), ("sections", "<u2"), ("tsc_khz", "<u4"),
                  ("mg_check_sample", "<u4"), ("t_ns", "<u8"), ("c_ns", "<u8"), ("pf_ns", "<u8", (3,)),
                  ("pf_cnt", "<u4", (3,)), ("ipi_cnt", "<u4"), ("ipi_ns", "<u8"), ("mg_check_ns_sampled", "<u8"),
                  ("mg_check_sampled", "<u4"), ("mg_read_sections", "<u4"), ("mg_write_sections", "<u4"),
                  ("mg_stale_cnt", "<u4"), ("mg_concur_cnt", "<u4"), ("mg_meta_cnt", "<u4"), ("mg_spin_cnt", "<u4"),
                  ("mg_switch_rw_cnt", "<u4"), ("mg_reclaim_cnt", "<u4"), ("mg_wflush_cnt", "<u4"),
                  ("mg_stale_ns", "<u8"), ("mg_concur_ns", "<u8"), ("mg_meta_ns", "<u8"), ("mg_spin_ns", "<u8"),
                  ("mg_wstart_ns", "<u8"), ("mg_switch_rw_ns", "<u8"), ("mg_reclaim_ns", "<u8"),
                  ("mg_wflush_ns", "<u8"), ("mg_wflush_bytes", "<u8"), ("mod_bytes", "<u8"), ("wait_ns", "<u8"),
                  ("nontrans_ns", "<u8"), ("nontrans_cnt", "<u4"), ("pad2", "<u4")])
OPLOG = np.dtype([("seq", "<u8"), ("recv_ns", "<u8"), ("measured", "u1"), ("target", "u1"), ("status", "<u2"),
                  ("op", "<u2"), ("pad", "<u2"), ("c", OPCOH)])
assert OPCOH.itemsize == 232 and OPLOG.itemsize == 256
OP_SEARCH, OP_UPDATE = 3, 4
OPS = {OP_SEARCH: "search", OP_UPDATE: "update"}
POP_SRC = {0: "none", 1: "swmc_acct", 2: "swmc_file", 3: "fake"}
PAGE = 4096

# (column, tag, unit, meaning); tag "sampled" is written as sampled×N with the run's N
COLUMNS = [
    ("step", "", "", "loadgen step (steps.jsonl)"),
    ("phase", "", "", "loadgen phase (ramp/bisect/confirm/fill/overload/fixed)"),
    ("op", "", "", "operation type (search | update)"),
    ("achieved_per_s", "measured", "1/s", "loadgen: completions of this stream in the window / window"),
    ("n_ops", "measured", "count", "operations of this type matched to the step (N_o)"),
    ("lat_p50_ms", "measured", "ms", "loadgen latency (done - scheduled) p50 of the matched operations"),
    ("lat_p99_ms", "measured", "ms", "loadgen latency p99 of the matched operations"),
    ("T_ms", "measured", "ms", "T_o = (1/N_o) sum_ops sum_threads (end - start), rdtsc per section; server processing "
     "from the worker's dequeue to the response being ready (search incl. the final merge); excludes queueing and the "
     "reply send"),
    ("wait_ms", "measured", "ms", "search: E1 wait (polling P >= ref_w) inside the start section, part of T_ms"),
    ("C_ms", "derived", "ms", "C_o = Popcorn (pop_is + pop_sm + pop_wp + pop_ipi) + Megalon (mg_check + mg_stale + "
     "mg_concur + mg_meta + mg_spin + mg_wstart + mg_wflush), step means"),
    ("rest_ms", "derived", "ms", "T_ms - C_ms"),
    ("C_frac", "derived", "", "C_ms / T_ms"),
    ("T_p50_ms", "measured", "ms", "per-operation T p50"),
    ("T_p99_ms", "measured", "ms", "per-operation T p99"),
    ("sections", "measured", "count", "sections per operation (search: 1 + segments)"),
    ("pop_is_ms", "measured", "ms", "Popcorn I->S coherence-fault time per operation (swmc_acct fault_ns[0]; "
     "build-8 file source: read faults)"),
    ("pop_sm_ms", "measured", "ms", "Popcorn S->M fault time (fault_ns[1]; file source: write faults)"),
    ("pop_wp_ms", "measured", "ms", "Popcorn write-protect upgrade fault time (fault_ns[2])"),
    ("pop_ipi_ms", "measured", "ms", "Popcorn TLB-shootdown IPI handling time on the thread's CPU (ipi_ns)"),
    ("pop_nontrans_ms", "measured", "ms", "Popcorn coherence faults without an MSI transition (NACKed rounds, wait "
     "behind a local holder; swmc_acct reserved[0], build 10): own component, NOT part of C_ms"),
    ("pop_nontrans_cnt", "measured", "count", "no-transition coherence faults per operation (reserved[1])"),
    ("pop_is_cnt", "measured", "count", "I->S faults per operation"),
    ("pop_sm_cnt", "measured", "count", "S->M faults per operation"),
    ("pop_wp_cnt", "measured", "count", "write-protect upgrades per operation"),
    ("pop_ipi_cnt", "measured", "count", "IPIs handled per operation"),
    ("mg_check_ms", "sampled", "ms", "Megalon section checks per operation, ratio estimator over the step: "
     "sum check_ns_sampled x sum mg_read_sections / sum check_sampled / N_o (read sections only)"),
    ("mg_stale_ms", "measured", "ms", "Megalon (A) stale copy: flush + restart"),
    ("mg_concur_ms", "measured", "ms", "Megalon (B) concurrent write: flush + discarded section body"),
    ("mg_meta_ms", "measured", "ms", "Megalon (C) metadata change: discarded section"),
    ("mg_spin_ms", "measured", "ms", "Megalon (D) spin: writer lock, NR combiner / replica read-lock waits (contended only)"),
    ("mg_wstart_ms", "measured", "ms", "Megalon write start (incl. switch_rw and reclaim)"),
    ("mg_switch_rw_ms", "measured", "ms", "Megalon switch_rw (part of mg_wstart_ms; not added to C)"),
    ("mg_reclaim_ms", "measured", "ms", "Megalon reclaim (part of mg_wstart_ms; not added to C)"),
    ("mg_wflush_ms", "measured", "ms", "Megalon write-end whole-object flush"),
    ("mg_read_sections", "measured", "count", "Megalon read sections per operation"),
    ("mg_write_sections", "measured", "count", "Megalon write sections per operation"),
    ("mg_check_sampled", "measured", "count", "Megalon sampled sections per operation (timed checks)"),
    ("mg_stale_cnt", "measured", "count", "(A) events per operation"),
    ("mg_concur_cnt", "measured", "count", "(B) events per operation"),
    ("mg_meta_cnt", "measured", "count", "(C) events per operation"),
    ("mg_spin_cnt", "measured", "count", "(D) contended spins per operation"),
    ("mg_switch_rw_cnt", "measured", "count", "switch_rw per operation"),
    ("mg_reclaim_cnt", "measured", "count", "reclaims per operation"),
    ("mg_wflush_cnt", "measured", "count", "write-end flushes per operation"),
    ("wb_bytes_mg", "measured", "B", "Fig 3b: bytes written back per operation, Megalon (CohSnap wflush_bytes)"),
    ("wb_bytes_pop", "derived", "B", "Fig 3b (update rows): Popcorn bytes written back per update = window delta of "
     "sys.swmc.page_coherence.remote_writeback_count (pages written back for a peer, nodes summed) x 4096 / "
     "opt.update.ops of the window"),
    ("m_acq_bytes_pop", "derived", "B", "Popcorn M acquisitions x 4 KiB per operation = (pop_sm_cnt + pop_wp_cnt) x 4096 "
     "(pages taken to M, not bytes written back)"),
    ("mod_bytes", "measured", "B", "Fig 3b: bytes the application stored per operation (whole lines of the vector "
     "record, zeroed and committed link blocks, delete-log entry)"),
    ("win_n", "measured", "count", "server window counter opt.<op>.ops (stats deltas, nodes summed; server completion time)"),
    ("win_T_ms", "measured", "ms", "server window opt.<op>.t_ns / opt.<op>.ops"),
    ("bg_lib_run_s", "measured", "s", "Megalon background threads (thr.megalon-lib: WriteMetadataManager etc. + "
     "thr.nr-log-sync: NR replay) run time in the window, nodes summed (schedstat; NOT in CohSnap/C)"),
    ("bg_kthr_run_s", "measured", "s", "Popcorn message receive kernel threads (kthr.cxl_recv*) run time in the window, "
     "nodes summed (not in C)"),
    ("bg_cpu_frac", "derived", "", "(bg_lib_run_s + bg_kthr_run_s) / window_s (CPUs busy with background coherence)"),
    ("pop_source", "", "", "Popcorn counter source of the step's records (none | swmc_acct | swmc_file | fake); one "
     "source per run is enforced"),
    ("mg_cohsnap", "", "", "1 = Megalon CohSnap present in the step's records (shim v2 with thread_coh)"),
    ("unmatched", "measured", "count", "run-level: measured op records without a raw record (same on every row)"),
]
COLS = [c[0] for c in COLUMNS]


def match(recv, raw_done, tol_ns):
    """index of the raw record per op record (-1 = none) and the ambiguous count"""
    order = np.argsort(raw_done, kind="stable")
    ds = raw_done[order]
    r = recv.astype(np.int64)
    hi = np.searchsorted(ds, r, side="right") - 1
    lo = np.searchsorted(ds, r - tol_ns, side="left")
    ok = (hi >= 0) & (hi >= lo)
    idx = np.where(ok, order[np.clip(hi, 0, max(len(ds) - 1, 0))] if len(ds) else -1, -1)
    m = idx[idx >= 0]
    return idx, int((ok & (hi - lo >= 1)).sum()) + int(len(m) - len(np.unique(m)))


def load_raws(lg, stream_idx):
    recs = []
    for p in sorted(glob.glob(os.path.join(lg, "raw-step*.bin"))):
        step = int(re.search(r"raw-step(\d+)\.bin$", p).group(1))
        r = np.fromfile(p, dtype=np.uint64).reshape(-1, 4)
        meas = ((r[:, 3] >> 40) & 1) == 1
        strm = (r[:, 3] >> 32) & 0xff
        ok = meas & (strm == stream_idx) & (r[:, 2] > 0) & ((r[:, 3] & 0xffff) == 0)
        recs.append(np.rec.fromarrays([r[ok, 0].astype(np.int64), r[ok, 2].astype(np.int64),
                                       np.full(int(ok.sum()), step, dtype=np.int64)], names="sched,done,step"))
    if not recs:
        return np.rec.fromarrays([np.zeros(0, np.int64)] * 3, names="sched,done,step")
    return np.concatenate(recs).view(np.recarray)


def pct(v, q):
    return float(np.percentile(v, q)) if len(v) else None


def mean(v):
    return float(np.mean(v)) if len(v) else None


def analyze(run, tol_us=20.0):
    """(rows, column table, summary) of one run dir"""
    lg = os.path.join(run, "loadgen")
    steps = [json.loads(x) for x in open(os.path.join(lg, "steps.jsonl"))]
    names = list(steps[0]["streams"]) if steps else ["update", "search"]
    path = os.path.join(lg, "op-coh.bin")
    logs = np.fromfile(path, dtype=OPLOG) if os.path.exists(path) else np.zeros(0, OPLOG)
    c = logs["c"]
    bad = int((c["version"] != 2).sum()) if len(logs) else 0
    srcs = sorted(set(int(x) for x in c["src"])) if len(logs) else []
    if len(srcs) > 1:  # one coherence source per run (every record of every node)
        raise SystemExit(f"opsplit: mixed coherence sources in {path}: " +
                         ", ".join(f"{POP_SRC.get(x & 3)}/cohsnap={x >> 2 & 1}" for x in srcs))
    win = {}
    if os.path.isdir(os.path.join(lg, "stats")):
        for fixed, d in stats_delta.deltas(lg):
            w = win.setdefault(fixed["step"], {})
            for k, v in d.items():
                if not isinstance(v, (int, float)):
                    continue
                if k.startswith("opt."):
                    w[k] = w.get(k, 0) + v
                elif k.endswith(".run_ns") and (k.startswith("thr.megalon-lib.") or k.startswith("thr.nr-log-sync.")):
                    w["bg_lib"] = w.get("bg_lib", 0) + v
                elif k == "sys.swmc.page_coherence.remote_writeback_count":
                    w["remote_wb"] = w.get("remote_wb", 0) + v
                elif k.endswith(".run_ns") and k.startswith("kthr.cxl_recv"):
                    w["bg_kthr"] = w.get("bg_kthr", 0) + v
            if fixed.get("window_s") not in ("", None):
                w["window_s"] = max(w.get("window_s", 0), float(fixed["window_s"]))
    sample = int(c["mg_check_sample"].max()) if len(logs) else 0
    rows, unmatched, ambiguous, matched = [], 0, 0, 0
    per_op = {}
    for op, name in OPS.items():
        if name not in names:
            continue
        sel_op = logs["op"] == op
        L = logs[sel_op]
        raws = load_raws(lg, names.index(name))
        idx, amb = match(L["recv_ns"], raws["done"], int(tol_us * 1000))
        ambiguous += amb
        matched += int((idx >= 0).sum())
        unmatched += int(((L["measured"] == 1) & (idx < 0)).sum())
        step_of = np.where(idx >= 0, raws["step"][np.clip(idx, 0, None)] if len(raws) else -1, -1)
        lat = np.where(idx >= 0, (raws["done"][np.clip(idx, 0, None)] - raws["sched"][np.clip(idx, 0, None)]) / 1e6
                       if len(raws) else 0, np.nan)
        per_op[op] = (L, step_of, lat)
    src = int(c["src"][0]) if len(logs) else 0
    for s in steps:
        if s["phase"] == "warmup" or s.get("measure_s", 0) <= 0:
            continue
        for op, (L, step_of, lat) in per_op.items():
            name = OPS[op]
            sel = step_of == s["step"]
            x = L["c"][sel]
            n = int(sel.sum())
            ms = lambda v: mean(np.asarray(v, dtype=np.float64) / 1e6)  # noqa: E731
            cnt = lambda v: mean(np.asarray(v, dtype=np.float64))  # noqa: E731
            T, C = x["t_ns"].astype(np.float64), x["c_ns"].astype(np.float64)
            # step-level ratio estimator for the Megalon checks (contract CXL_SWMC 2015a31f3)
            ns_s, rs, cs_ = (float(x[k].astype(np.float64).sum()) for k in ("mg_check_ns_sampled", "mg_read_sections",
                                                                            "mg_check_sampled"))
            chk_total = ns_s * rs / cs_ if cs_ else 0.0
            other = (x["pf_ns"].sum(axis=1).astype(np.float64) + x["ipi_ns"] + x["mg_stale_ns"] + x["mg_concur_ns"]
                     + x["mg_meta_ns"] + x["mg_spin_ns"] + x["mg_wstart_ns"] + x["mg_wflush_ns"])
            C_step = (float(other.sum()) + chk_total) / n if n else None
            w = win.get(s["step"], {})
            wn = w.get(f"opt.{name}.ops", 0)
            row = dict(step=s["step"], phase=s["phase"], op=name,
                       achieved_per_s=s["streams"].get(name, {}).get("achieved"), n_ops=n,
                       lat_p50_ms=pct(lat[sel], 50), lat_p99_ms=pct(lat[sel], 99),
                       T_ms=ms(T), C_ms=C_step / 1e6 if n else None,
                       rest_ms=(float(T.mean()) - C_step) / 1e6 if n else None,
                       C_frac=C_step * n / float(T.sum()) if n and T.sum() else None,
                       T_p50_ms=pct(T / 1e6, 50), T_p99_ms=pct(T / 1e6, 99), wait_ms=ms(x["wait_ns"]),
                       sections=cnt(x["sections"]),
                       pop_is_ms=ms(x["pf_ns"][:, 0]), pop_sm_ms=ms(x["pf_ns"][:, 1]), pop_wp_ms=ms(x["pf_ns"][:, 2]),
                       pop_ipi_ms=ms(x["ipi_ns"]), pop_nontrans_ms=ms(x["nontrans_ns"]),
                       pop_nontrans_cnt=cnt(x["nontrans_cnt"]), pop_is_cnt=cnt(x["pf_cnt"][:, 0]), pop_sm_cnt=cnt(x["pf_cnt"][:, 1]),
                       pop_wp_cnt=cnt(x["pf_cnt"][:, 2]), pop_ipi_cnt=cnt(x["ipi_cnt"]),
                       mg_check_ms=chk_total / n / 1e6 if n else None,
                       wb_bytes_mg=cnt(x["mg_wflush_bytes"]),
                       m_acq_bytes_pop=cnt((x["pf_cnt"][:, 1].astype(np.float64) + x["pf_cnt"][:, 2]) * PAGE),
                       wb_bytes_pop=(w["remote_wb"] * PAGE / w["opt.update.ops"]
                                     if name == "update" and "remote_wb" in w and w.get("opt.update.ops") else None),
                       mod_bytes=cnt(x["mod_bytes"]),
                       win_n=wn if w else None, win_T_ms=w[f"opt.{name}.t_ns"] / wn / 1e6 if wn else None,
                       bg_lib_run_s=w.get("bg_lib", 0) / 1e9 if w else None,
                       bg_kthr_run_s=w.get("bg_kthr", 0) / 1e9 if w else None,
                       bg_cpu_frac=(w.get("bg_lib", 0) + w.get("bg_kthr", 0)) / 1e9 / w["window_s"]
                       if w.get("window_s") else None,
                       pop_source=POP_SRC.get(int(x["src"][0]) & 3, "?") if n else None,
                       mg_cohsnap=(int(x["src"][0]) >> 2) & 1 if n else None, unmatched=None)
            for k in ("stale", "concur", "meta", "spin", "wstart", "switch_rw", "reclaim", "wflush"):
                row[f"mg_{k}_ms"] = ms(x[f"mg_{k}_ns"])
            for k in ("read_sections", "write_sections", "check_sampled", "stale_cnt", "concur_cnt", "meta_cnt",
                      "spin_cnt", "switch_rw_cnt", "reclaim_cnt", "wflush_cnt"):
                row[f"mg_{k}"] = cnt(x[f"mg_{k}"])
            rows.append(row)
    for r in rows:
        r["unmatched"] = unmatched
    tag = lambda t: f"sampled×{sample or 64}" if t == "sampled" else t  # noqa: E731
    table = [(col, tag(t), u, m) for col, t, u, m in COLUMNS]
    summary = (f"{len(rows)} rows, {len(logs)} op records ({int((logs['op'] == OP_SEARCH).sum())} search, "
               f"{int((logs['op'] == OP_UPDATE).sum())} update), matched {matched}, ambiguous {ambiguous}, "
               f"unmatched measured {unmatched}, bad version {bad}, popcorn source {POP_SRC.get(src & 3)}, "
               f"megalon cohsnap {(src >> 2) & 1}")
    return rows, table, summary


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
    ap.add_argument("--tol-us", type=float, default=20)
    a = ap.parse_args()
    rows, table, summary = analyze(a.run, a.tol_us)
    out = a.out or os.path.join(a.run, "opsplit-steps.csv")
    write(out, COLS, rows)
    tpath = (out[:-4] if out.endswith(".csv") else out) + ".columns.csv"
    with open(tpath, "w", newline="") as fh:
        wtr = csv.writer(fh)
        wtr.writerow(["column", "tag", "unit", "meaning"])
        wtr.writerows(table)
    print(f"-> {out}, {tpath}: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

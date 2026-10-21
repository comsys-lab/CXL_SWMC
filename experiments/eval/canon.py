#!/usr/bin/env python3
"""Canonical CSV schemas of the evaluation (evaluation-pipeline rev 3 §4.2) and helpers shared by the per-workload
export scripts (experiments/vectordb/export.py, experiments/recsys/export.py). Host only, offline, read-only on the
evidence.

Generic names: rop = read op (vector DB search, RecSys query), wop = write op (vector DB update = delete + insert,
RecSys row update / update sample); point = the workload's x value (vector DB mix u5/u50/u90 with upd_share 0.05 /
0.5 / 0.9; RecSys samples/s); x = offered read ops/s. Every row starts with workload, run, config_sha256.
Validity (verifier M3): valid = the update stream was sustained in that step (server counters: vector DB
urate_check.py write jobs done / accepted >= 0.98 with bounded backlog; RecSys stream_check.py written / accepted >=
0.98 with bounded lag); empty when the evidence has no such counters (vector DB builds < 17, e.g. H1 r1). wop_done_ratio
= that server ratio; wop_offered_per_s = the offered update stream. The loadgen ratio achieved / offered is NOT used:
with Poisson arrivals it differs from 1 by sampling (e.g. 0.937 for every system at the same seed, H1 r1 u90 L2).
fixed.csv slo_pass = the window met the SLO (loadgen pass), a separate fact from validity.
fixed.csv level_set (user decision 2026-10-20, M4 = b): which figure set a window belongs to: "h1" = the 3-system H1
levels (vector DB: weakest of hw, pop, mg; RecSys: the 1 q/s Megalon comparison windows and every Megalon window),
"h2" = the hw/pop levels (vector DB H2 set; RecSys L1/L2 and the 1 q/s fallback), "h1 h2" = a window that serves both
(vector DB hw/pop H1 windows of a mix whose H2 set equals its H1 set). H1 figures read rows containing h1, H2 figures
rows containing h2.
"""
import csv
import json
import math
import os

import numpy as np

KEY = ["workload", "run", "config_sha256"]
# per-step coherence columns of the vector DB export (experiments/vectordb/export.py coh_steps, 2026-10-22: Megalon
# columns as experiments/eval/export_h2n.py + what de-stijl-motivation-isca27 Fig 3 needs); appended to slo_steps.csv
# and fixed.csv (empty for RecSys rows)
VDB_COH = ["srv_searches", "srv_updates", "mg_fetch_per_s", "mg_flush_writeend_per_s", "mg_flushes_per_s",
           "mg_flush_bytes_per_s", "mg_wflush_bytes_per_s", "mg_wflushes_per_s", "mg_rflush_bytes_per_rop",
           "mg_rflushes_per_rop", "mg_rflush_bytes_per_flush", "mg_search_events_per_rop", "pop_search_is_per_rop",
           "fig3_lines_per_rop", "mg_fetch_per_op"]
# lowest measured ramp step of an SLO search (verifier L3): hatched bars for searches without a confirmed max
LOWEST = ["lowest_ramp_step", "lowest_ramp_offered_x", "lowest_ramp_achieved_x", "lowest_ramp_p99_ms",
          "lowest_ramp_mg_fetch_per_op"]
POINT = ["system", "point", "upd_share", "rate_unit", "vcpus_per_vm", "threads", "writers"]
SCHEMA = {
    "slo_summary.csv": KEY + POINT + [
        "slo_pct", "slo_ms", "result_x", "confirm_x_mean", "confirm_x_sd", "confirm_x_min", "confirm_x_max",
        "confirmed", "valid", "n_judged", "n_invalid_judged", "low_rate_violations", "ramp_end", "knee_x", "note",
        "recall10", "recall10_tie", "at_result_achieved_x", "at_result_p95_ms", "at_result_p99_ms",
        "at_result_wop_per_s", "at_result_T_ms_rop", "at_result_C_ms_rop", "at_result_pop_read_faults_per_rop",
        "at_result_cxl_recv_cpu_s_per_s", "lifetime", "source_dir"] + LOWEST,
    "slo_steps.csv": KEY + POINT + [
        "step", "phase", "offered_x", "achieved_x", "n_rop", "p50_ms", "p95_ms", "p99_ms", "pass", "valid",
        "at_result", "aborted", "wop_per_s", "wop_offered_per_s", "wop_done_ratio", "T_ms_rop", "C_ms_rop", "T_ms_wop", "C_ms_wop",
        "pop_read_faults_per_rop", "pop_write_faults_per_rop", "pop_read_faults_per_wop", "pop_write_faults_per_wop",
        "owner_wait_ms_rop", "cxl_recv_cpu_s_per_s", "slo_pct", "slo_ms", "lifetime"] + VDB_COH,
    "latency_hist.csv": KEY + ["system", "point", "step", "phase", "offered_x", "bin_hi_us", "count"],
    "fixed.csv": KEY + POINT + [
        "level", "level_set", "step", "offered_x", "achieved_x", "valid", "slo_pass", "n_rop", "p95_ms", "p99_ms", "wop_per_s",
        "wop_offered_per_s", "wop_done_ratio",
        "T_ms_rop", "C_ms_rop", "T_ms_wop", "C_ms_wop",
        "pop_read_faults_per_rop", "pop_write_faults_per_rop", "pop_read_faults_per_wop", "pop_write_faults_per_wop",
        "seg_is_ms_rop", "seg_sm_ms_rop", "seg_wp_ms_rop", "seg_ipi_ms_rop", "seg_nontrans_ms_rop",
        "seg_owner_wait_ms_rop", "seg_inval_ipis_per_rop", "seg_processing_ms_rop",
        "mg_flush_bytes_per_rop", "mg_wflush_bytes_per_wop", "flushed_lines_per_rop", "cxl_recv_cpu_s_per_s",
        "mgoff_T_ms_rop", "mgoff_T_ms_wop", "lifetime", "source_dir"] + VDB_COH,
    "mg_probe.csv": KEY + ["point", "offered_x", "T_ms_rop", "p95_ms", "achieved_wop_per_s", "backlog_end",
                           "lag_ms_max", "valid", "decision", "source_dir"],
}
BIN_RATIO = 1.01  # latency_hist: log bins, 1 % wide; bin i covers (1.01^i, 1.01^(i+1)] us


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, float):
        if math.isnan(v) or math.isinf(v):
            return ""
        return repr(round(v, 6))
    return str(v)


def fl(v):
    try:
        x = float(v)
        return None if math.isnan(x) else x
    except (TypeError, ValueError):
        return None


class Out:
    """collects rows per canonical CSV; write() emits every schema (header only when no rows)"""

    def __init__(self, workload, run, sha):
        self.base = {"workload": workload, "run": run, "config_sha256": sha}
        self.rows = {k: [] for k in SCHEMA}

    def add(self, csvname, **kw):
        bad = set(kw) - set(SCHEMA[csvname])
        if bad:
            raise KeyError(f"{csvname}: unknown columns {sorted(bad)}")
        self.rows[csvname].append(dict(self.base, **kw))

    def write(self, outdir, only=None):
        os.makedirs(outdir, exist_ok=True)
        for name, cols in SCHEMA.items():
            if only and name not in only:
                continue
            with open(os.path.join(outdir, name), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(cols)
                for r in self.rows[name]:
                    w.writerow([fmt(r.get(c)) for c in cols])
        return {k: len(v) for k, v in self.rows.items()}


def jsonl(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def measured_steps(part):
    return [d for d in jsonl(os.path.join(part, "loadgen", "steps.jsonl")) if d.get("measure_s", 0) > 0]


def summary(part):
    return json.load(open(os.path.join(part, "loadgen", "summary.json")))


def confirm_stats(part, xs):
    """(best, at_result step numbers, min, max achieved x over the confirm repeats at the result rate)"""
    s = summary(part)
    if s.get("confirmed") is not True:
        return None, set(), None, None
    best = fl(s.get("max_offered_x_pass"))
    st = [d for d in measured_steps(part) if d["phase"] == "confirm" and best is not None and
          abs(d["offered_x"] - best) <= 1e-6 * max(1.0, best)]
    ach = [d["streams"][xs]["achieved"] for d in st]
    return best, {d["step"] for d in st}, (min(ach) if ach else None), (max(ach) if ach else None)


def stream_names(part):
    st = jsonl(os.path.join(part, "loadgen", "steps.jsonl"))
    return list(st[0]["streams"]) if st else []


def latency_hist(part, stream):
    """{step: [(bin_hi_us, count)]} of the measured, OK requests of `stream` (loadgen --raw rows: sched, send, done,
    stream << 32 | status | measured << 40; latency = done - sched, as loadgen's percentiles)."""
    names = stream_names(part)
    if stream not in names:
        return {}
    idx = names.index(stream)
    out = {}
    lg = os.path.join(part, "loadgen")
    for fn in os.listdir(lg):
        if not (fn.startswith("raw-step") and fn.endswith(".bin")):
            continue
        step = int(fn[len("raw-step"):-4])
        r = np.fromfile(os.path.join(lg, fn), dtype=np.uint64).reshape(-1, 4)
        meas = ((r[:, 3] >> np.uint64(40)) & np.uint64(1)) == 1
        strm = (r[:, 3] >> np.uint64(32)) & np.uint64(0xff)
        ok = meas & (strm == idx) & (r[:, 2] > 0) & ((r[:, 3] & np.uint64(0xffff)) == 0)
        lat_us = (r[ok, 2].astype(np.float64) - r[ok, 0].astype(np.float64)) / 1e3
        lat_us = np.maximum(lat_us, 1.0)
        b = np.ceil(np.log(lat_us) / math.log(BIN_RATIO) - 1e-9).astype(np.int64)
        u, c = np.unique(b, return_counts=True)
        out[step] = [(round(BIN_RATIO ** int(i), 3), int(n)) for i, n in zip(u, c)]
    return out

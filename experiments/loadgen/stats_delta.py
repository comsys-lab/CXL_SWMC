#!/usr/bin/env python3
"""Per-step server counter deltas from loadgen --stats-op snapshots (experiments/loadgen/README.md).

usage: stats_delta.py RUN_DIR [--out RUN_DIR/stats-steps.csv]
RUN_DIR is a loadgen --out dir with stats/step<NNN>-{begin,end}-t<k>.txt (one header line "# when=.. phase=..
step=.. offered_x=.. target=.. addr=.. status=.. wall_ns=.. mono_ns=.. rtt_us=..", then the server's key=value text).

Output: one row per (step, target) that has both snapshots. Fixed columns: step, phase, offered_x, target, addr,
begin_wall_ns, end_wall_ns, window_s (loadgen clock: end mono_ns - begin mono_ns), srv_window_s (server clock:
t_mono_ns delta, if the server emits it), then one column per numeric key (sorted): end - begin, except gauges
(identity values, flag words, current sizes and maxima: see GAUGE below), which keep the end value; per-operation counts
op.<op>.n / opt.<op>.n are counters despite the ".n" gauge suffix. Non-numeric keys are ignored.
A key missing in one snapshot of a pair is left empty for that row. Coherence lifetimes (any sys.cxl_shm.* key) always
carry the STABLE columns below (empty where the kernel lacks the counter: pop and ds files have the same column set).
"""
import argparse, csv, os, re, sys

FNAME = re.compile(r"^step(\d+)-(begin|end)-t(\d+)\.txt$")
# keys reported as their end value (not differenced)
GAUGE_EXACT = {"node", "write_queue", "search_queue", "megt.sample",
               # run 2 vector DB (builds/vdb/23+): bytes / time of the unused-slot zeroing at preload (one-time values)
               "zeroed_unused_bytes", "zeroed_unused_ms",
               # recsys Megalon (shim v5, builds/recsys-megalon/17+): current record-pool values (cluster-wide);
               # megalon.pool.reclaim_count / allocate_count stay counters (per-step deltas)
               "megalon.pool.records_in_use", "megalon.pool.record_slots", "megalon.pool.dyn_wmeta",
               # recsys windowed publication (--publish-window-s > 0, builds/recsys/17+, recsys-megalon/18+): current
               # values; publish_lag_ns_max = max since the previous stats read (reset by the read). published_rows,
               # publish_sections, publish_carryover_rows, publish_lag_ns_sum / _count, dram_updates, train_dram_hits
               # stay counters
               "publish_window_s", "publish_started", "publish_window", "publish_backlog", "publish_queued",
               "window_distinct", "publish_lag_ns_max", "dram_rows", "dram_capacity", "dram_index_bytes", "dram_bytes"}
GAUGE_SUFFIX = (".n", "max_ns", ".in_flight_transaction_count", ".enabled",
                # identity values of the MOT1 v6 per-operation stats (sampling factor, TSC rate, thread counts)
                "check_sample", "tsc_hz", ".threads", "_threads", ".version", ".meg_coh",
                # Megalon >= 76 flag words (CohSnap.reserved[1]: lean sampling, events_always) and >= 77 probe cost:
                # vector DB opt.<op>.meg.flags, opt.<op>.meg.anchor.probe_ps_{min,max}; recsys op.<op>.mg.flags;
                # KV/LMDB opt.meg_flags, opt.meg_lean, opt.meg_events_always, opt.meg_probe_ps_{min,max}
                ".meg.flags", ".mg.flags", "meg_flags", "meg_lean", "meg_events_always", "probe_ps_min", "probe_ps_max",
                # De Stijl v2 (systems/common/proc_stats.h sys.swmc.destijl.*): current pending count, completion rate,
                # residence p95 and max, replica pool size ("lambda": the pre-kernel spec name, kept for old snapshots)
                "swmc.destijl.pending_now", "swmc.destijl.lambda", "swmc.destijl.lambda_per_s", "swmc.destijl.p95_us",
                "swmc.destijl.ss_residence_max_us", "swmc.destijl.replica_pages",
                # cxl_shm adaptive receiver state (/sys/kernel/cxl_shm/recv_adaptive "name value" lines): current values
                ".recv_adaptive.gap_ewma_us", ".recv_adaptive.timed_sleep_us", ".recv_adaptive.q_warm",
                ".recv_adaptive.ipoll_live")

# Columns every coherence run (a snapshot with any sys.cxl_shm.* key: Popcorn and De Stijl lifetimes) carries, empty
# where the kernel lacks the counter, so that pop and ds stats-steps.csv files have the same column set for the per-step
# write-path breakdown (RocksDB N=4 write-wait RCA, 2026-11-05): De Stijl INV round / inline self write-back / INV
# serve (last INV, pickup bound) / FETCH serve; cxl_shm per-kind receive counts, receiver wake outcomes and the
# sleep-found log2 histogram (us; buckets b0..b23). Popcorn's analogues (owner handler, transport, message wait) are
# the per-thread thr.<comm>.swmc.* counters both kernels export.
STABLE_DS = ["wr_rounds", "wr_round_ns", "wr_inv_produce_ns", "wr_evict_m_self", "wr_evict_m_self_ns", "wr_evict_m_remote",
             "wr_evict_m_remote_ns", "wr_poll_once", "wr_poll_once_ns", "wr_acq_hpd_n", "wr_acq_hpd_ns",
             "srv_inv_count", "srv_inv_h_ns", "srv_inv_revoke_ns", "srv_inv_wb_ns", "srv_inv_last_count",
             "srv_inv_last_h_ns", "srv_inv_by_poll", "srv_inv_pickup_n", "srv_inv_pickup_bound_ns", "srv_inv_cas_retry",
             "srv_fetch_sync_count", "srv_fetch_sync_h_ns", "srv_fetch_async_count", "srv_fetch_async_h_ns",
             "srv_fetch_evict_count", "srv_fetch_evict_h_ns", "inv_sent", "fetch_sent", "ack_sent", "rx_inv", "rx_fetch",
             "rx_ack", "evict_self_fetch"]
STABLE_SHM = ["rx_inv_count", "rx_fetch_count", "rx_ack_count", "rx_by_poll_once", "rx_by_fault_poll", "fault_poll_msgs",
              "r_found_after_timeout", "r_wake_timeout_timed", "r_wake_timeout_cold", "r_wake_timeout_covered",
              "r_wake_by_writer", "r_wake_by_ipoll", "r_sleep_aborted", "poll_until_stop", "poll_until_wake_r",
              "req_by_kthread", "rsp_by_kthread", "rsp_by_requester"]
SLEEP_HIST_BUCKETS = 24
STABLE = (["sys.swmc.destijl." + k for k in STABLE_DS] + ["sys.cxl_shm." + k for k in STABLE_SHM] +
          [f"sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b{i}" for i in range(SLEEP_HIST_BUCKETS)])


def stable_keys(rows):
    """STABLE when any row has a sys.cxl_shm.* key (a coherence lifetime), else nothing (all-HWcc, Megalon)"""
    return STABLE if any(k.startswith("sys.cxl_shm.") for _, dv in rows for k in dv) else []
# MOT1 v6 per-operation namespaces op.<op>.* / opt.<op>.*: the operation count "<prefix>.<op>.n" is a counter
OP_COUNT = re.compile(r"^opt?\.[^.]+\.n$")


def is_gauge(k):
    if OP_COUNT.match(k):
        return False
    return k in GAUGE_EXACT or k.endswith(GAUGE_SUFFIX)


def num(v):
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return None


def parse(path):
    hdr, kv = {}, {}
    with open(path) as f:
        first = f.readline()
        if first.startswith("#"):
            for tok in first[1:].split():
                k, _, v = tok.partition("=")
                hdr[k] = v
        for line in f:
            k, sep, v = line.rstrip("\n").partition("=")
            if not sep or not k:
                continue
            x = num(v.strip())
            if x is not None:
                kv[k] = x
    return hdr, kv


def load(run):
    d = os.path.join(run, "stats")
    snaps = {}
    if not os.path.isdir(d):
        return snaps
    for name in os.listdir(d):
        m = FNAME.match(name)
        if m:
            snaps.setdefault((int(m.group(1)), int(m.group(3))), {})[m.group(2)] = parse(os.path.join(d, name))
    return snaps


def deltas(run):
    """[(fixed dict, delta dict)] per (step, target) with both snapshots, in step/target order."""
    rows = []
    for (step, t), pair in sorted(load(run).items()):
        if "begin" not in pair or "end" not in pair:
            continue
        (hb, b), (he, e) = pair["begin"], pair["end"]
        fixed = {"step": step, "phase": he.get("phase", ""), "offered_x": he.get("offered_x", ""), "target": t,
                 "addr": he.get("addr", ""), "begin_wall_ns": hb.get("wall_ns", ""), "end_wall_ns": he.get("wall_ns", ""),
                 "window_s": (int(he["mono_ns"]) - int(hb["mono_ns"])) / 1e9 if "mono_ns" in he and "mono_ns" in hb else "",
                 "srv_window_s": (e["t_mono_ns"] - b["t_mono_ns"]) / 1e9 if "t_mono_ns" in e and "t_mono_ns" in b else ""}
        dv = {}
        for k in set(b) | set(e):
            if k in b and k in e:
                dv[k] = e[k] if is_gauge(k) else e[k] - b[k]
        rows.append((fixed, dv))
    return rows


FIXED = ["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s", "srv_window_s"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--out")
    a = ap.parse_args()
    rows = deltas(a.run)
    if not rows:
        sys.exit(f"stats_delta: no begin/end snapshot pairs in {a.run}/stats")
    keys = sorted({k for _, dv in rows for k in dv} | set(stable_keys(rows)))
    out = a.out or os.path.join(a.run, "stats-steps.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(FIXED + keys)
        for fixed, dv in rows:
            w.writerow([fixed[c] for c in FIXED] + [dv.get(k, "") for k in keys])
    print(f"-> {out} ({len(rows)} step/target rows, {len(keys)} keys)")


if __name__ == "__main__":
    main()

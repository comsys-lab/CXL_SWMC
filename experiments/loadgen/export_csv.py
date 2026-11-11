#!/usr/bin/env python3
"""Export loadgen runs to CSV for spreadsheets: one row per (run, step, stream).

usage: export_csv.py --out steps.csv RUN_DIR[=label] ...
RUN_DIR is a loadgen --out dir (steps.jsonl, summary.json, optional stats/ from --stats-op).

Columns (stable; new columns are only ever appended):
  label, step, phase, measure_s, pass, aborted, reason, stream, offered, achieved, sent, done, errors, timeouts,
  p50/p90/p99/p999/pslo/max (ms), lag_p99_us, max_under_slo (the run's confirm mean, same on every row of the run)
  ... (appended last, 2026-10-18 "A+C") bracket_lo_offered, bracket_hi_offered: the run's knee bracket (knee_bracket():
  confirmed max offered rate under the SLO, lowest failed offered rate above it; same on every row of the run)
  ... (appended last, 2026-10-21) confirm_rule, result_majority_offered, result_majority_complete,
  result_pooled_offered, result_pooled_complete (loadgen --confirm-rule; empty for older runs; see RULES)
  ... (appended last, 2026-11-12) drain_wait_s, outstanding_after_drain, outstanding_at_start, contaminated, judged,
  rerun_of (loadgen --drain-full-s; empty for runs without it; see DRAIN), drain_fail (--drain-fail-s)
Step-level (same value on every stream row of a step):
  search_per_s, update_per_s     achieved rate of stream "search" / "update" (empty if the run has no such stream)
  total_ops_per_s                sum of the achieved rates of all streams (an update counts as one operation)
  search_p50_ms, search_p99_ms, update_p50_ms, update_p99_ms
  traffic_bytes, traffic_per_update   coherence traffic over all nodes (n<k>_traffic_bytes summed) and per update
                                      completed by the servers in the window (sum of n<k>_updates)
Per node k (target index of --target; from the stats snapshot deltas, experiments/loadgen/stats_delta.py; empty
when the run has no snapshots or the counter is absent). Times in seconds of the window, summed over threads:
  n<k>_window_s            loadgen-clock window between the begin and end snapshots
  n<k>_searches, n<k>_updates, n<k>_p_advance   server counters (searches done, updates done, watermark P advance)
  n<k>_search_busy_frac    search_busy_ns / (window x search threads): worker busy fraction
  n<k>_writer_busy_frac    writer_busy_ns / window
  n<k>_search_cpu_s, n<k>_search_rq_wait_s, n<k>_writer_cpu_s   schedstat CPU / run-queue wait (thread groups
                           vdb-search, vdb-writer)
  n<k>_cpu_busy_frac       node CPU busy fraction (/proc/stat: 1 - (idle + iowait) / total)
  Popcorn (per-thread /proc/<pid>/task/<tid>/swmc, Popcorn build >= 8; node-wide sysfs):
  n<k>_pop_search_fault_s  vdb-search threads: swmc.read_fault_ns + swmc.write_fault_ns (wp is a subset of write)
  n<k>_pop_search_msg_wait_s   vdb-search: swmc.read_msg_wait_ns + swmc.write_msg_wait_ns (part of the fault time)
  n<k>_pop_search_local_wait_s vdb-search: swmc.read_local_wait_ns + swmc.write_local_wait_ns (part of the fault time)
  n<k>_pop_writer_fault_s  vdb-writer: swmc.read_fault_ns + swmc.write_fault_ns
  n<k>_pop_node_fault_s    sys.swmc.page_coherence.total_page_fault_handling_time (ns, all tasks of the node)
  Megalon (workload wrapper timers megt.*, all threads; read sections sampled 1/megt.sample):
  n<k>_meg_rd_check_s      (megt.rd_start_ns + megt.rd_end_ns) x megt.sample   (successful read sections, estimate)
  n<k>_meg_wr_check_s      megt.wr_start_ns
  n<k>_meg_flush_s         megt.wr_end_ns (write_end includes the flush)
  n<k>_meg_reexec_s        megt.rd_retries x mean failed-attempt time; source in n<k>_meg_reexec_src:
                           timed      mean of the timed (sampled) failed attempts (megt.rd_failed_ns / rd_failed_timed)
                           est_section  no failed attempt was timed: mean sampled accepted section
                                      ((rd_start_ns + rd_body_ns + rd_end_ns) / rd_sampled), an underestimate when the
                                      failed read_end flushes the object
                           none       no retries (0)
  n<k>_meg_stall_s         sum of the four above
  n<k>_coh_stall_s         coherence time over all request-serving threads (search + writer), by the run's system
                           (manifest system=, not by counter presence): page MSI pop_search_fault_s +
                           pop_writer_fault_s; Megalon meg_stall_s; all-HWcc empty. pop_* columns only for page MSI
                           runs, meg_* only for Megalon runs
  n<k>_recv_cpu_s          kernel threads cxl_recv* (schedstat run_ns; cpu_ticks / 100 if absent)
  n<k>_lib_bg_cpu_s        this process's thread groups not named vdb-* (e.g. megalon-lib: Megalon's own threads)
  n<k>_coh_bg_cpu_s        recv_cpu_s + lib_bg_cpu_s
  n<k>_ipoll_cpu_s         run 2 adaptive receiver: kernel threads cxl_ipoll/<cpu> (idle pollers, schedstat run_ns);
                           empty when the server build does not list the prefix or the receiver is not adaptive;
                           not included in coh_bg_cpu_s
  n<k>_tlb_ipi, n<k>_cal_ipi   /proc/interrupts TLB shootdowns / function-call IPIs (whole node)
  n<k>_traffic_bytes, n<k>_traffic_src   coherence traffic estimate and its source:
                           megalon       megalon.flush_bytes + megalon.replay_flush_bytes
                           popcorn       (n<k>_pop_remote_wb + n<k>_pop_acquire_flush) x 4096 (MOT1 v4 Figure 2b;
                                         only with sys.swmc.instr.enabled = 1 at the window end)
                           popcorn-wb    n<k>_pop_remote_wb x 4096 (no instr/ counters or instr disabled:
                                         acquire flushes not counted)
  n<k>_pop_remote_wb       sys.swmc.page_coherence.remote_writeback_count: pages this node wrote back for a peer =
                           Figure 2b terms "remote write-back" (FETCH on M: M -> S) + "remote invalidate with
                           write-back" (INVALIDATE on M: M -> I); one increment per pc_downgrade_m(), both cases.
                           Not used: instr serve wb_flush_count (the flush of the same downgrades: double count),
                           remote_invalidate_count (S -> I, nothing written back), mkclean/unmap counts (only pages
                           mapped on the node).
  n<k>_pop_acquire_flush   sys.swmc.instr.serve.acquire_flush_count: Figure 2b "requester acquire-flush" (stale lines
                           dropped on I -> S/M or the first map of an init-S page)
  n<k>_meg_reexec_src      see n<k>_meg_reexec_s
Run SLO (appended after the per-node columns; from manifest.txt slo=stream:pct:ms, present in every run):
  slo_stream, slo_pct, slo_ms   --slo of the run (pct 99 for KV/LMDB/vector DB, 95 for DLRM; MOT1 v6 §1);
                                pslo_ms is the slo_pct percentile of this row's stream
  p95_ms                        nearest-rank p95 of this row's stream (loadgen >= 2026-10-16; empty for older runs)
"""
import argparse, csv, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stats_delta  # noqa: E402

BASE = ["label", "step", "phase", "measure_s", "pass", "aborted", "reason", "stream", "offered", "achieved", "sent",
        "done", "errors", "timeouts", "p50_ms", "p90_ms", "p99_ms", "p999_ms", "pslo_ms", "max_ms", "lag_p99_us",
        "max_under_slo"]
STEP = ["search_per_s", "update_per_s", "total_ops_per_s", "search_p50_ms", "search_p99_ms", "update_p50_ms",
        "update_p99_ms", "traffic_bytes", "traffic_per_update"]
RUNSLO = ["slo_stream", "slo_pct", "slo_ms", "p95_ms"]
BRACKET = ["bracket_lo_offered", "bracket_hi_offered"]
# appended last (2026-10-21, loadgen --confirm-rule): both confirm rules' results (summary.json result_<rule>; empty for
# older runs). *_offered = confirmed max offered rate (empty if none); *_complete = false when the rule the search did
# not follow would have needed a probe that was never run (its offered value is then its state at that point)
RULES = ["confirm_rule", "result_majority_offered", "result_majority_complete", "result_pooled_offered",
         "result_pooled_complete"]
# appended last (2026-11-12, loadgen --drain-full-s; empty when the run did not use it): drain_wait_s (send end -> drain
# end), outstanding_after_drain, outstanding_at_start, contaminated (requests outstanding at step start), judged (false =
# contaminated first attempt, phase "contaminated", not a search decision), rerun_of (a re-run: step of that attempt)
# drain_fail (loadgen --drain-fail-s; empty without it): the drain took longer than D s (non-latency failure)
DRAIN = ["drain_wait_s", "outstanding_after_drain", "outstanding_at_start", "contaminated", "judged", "rerun_of",
         "drain_fail"]
SEARCH_PHASES = ("ramp", "bisect", "confirm")


def knee_bracket(summ, steps):
    """Knee bracket of an SLO run (decision 2026-10-18 "A+C"): {"lo", "hi", "hi_phase", "source", "confirmed"};
    lo = the confirmed max offered rate under the SLO (None if no rate was confirmed), hi = the lowest failed offered
    rate above it (None if none). summary.json "bracket" (loadgen since 2026-10-18, source "summary"); older runs
    (source "steps"): lo = max_offered_x_pass when the search ended without a note, hi = the lowest offered_x of a
    failed ramp / bisect / confirm step above max_offered_x_pass (a failed confirm repeat counts: the r1 step-down
    runs confirmed-failed there). {} for a run without an SLO result."""
    b = summ.get("bracket")
    if isinstance(b, dict):
        return {"lo": b.get("lo_offered"), "hi": b.get("hi_offered"), "hi_phase": b.get("hi_phase") or "",
                "source": "summary", "confirmed": bool(summ.get("confirmed"))}
    best = summ.get("max_offered_x_pass")
    if not best:
        return {}
    best = float(best)
    fails = sorted((float(s["offered_x"]), s["phase"]) for s in steps
                   if s.get("phase") in SEARCH_PHASES and not s.get("pass") and s.get("measure_s", 0) > 0
                   and float(s["offered_x"]) > best * (1 + 1e-9))
    confirmed = not summ.get("note")
    return {"lo": best if confirmed else None, "hi": fails[0][0] if fails else None,
            "hi_phase": fails[0][1] if fails else "", "source": "steps", "confirmed": confirmed}
NODE = ["window_s", "searches", "updates", "p_advance", "search_busy_frac", "writer_busy_frac", "search_cpu_s",
        "search_rq_wait_s", "writer_cpu_s", "cpu_busy_frac", "pop_search_fault_s", "pop_search_msg_wait_s",
        "pop_search_local_wait_s", "pop_writer_fault_s", "pop_node_fault_s", "meg_rd_check_s", "meg_wr_check_s",
        "meg_flush_s", "meg_reexec_s", "meg_stall_s", "coh_stall_s", "recv_cpu_s", "lib_bg_cpu_s", "coh_bg_cpu_s",
        "tlb_ipi", "cal_ipi", "traffic_bytes", "traffic_src", "pop_remote_wb", "pop_acquire_flush", "meg_reexec_src",
        "ipoll_cpu_s"]
PAGE = 4096


def _sum(d, keys):
    v = [d[k] for k in keys if k in d]
    return sum(v) if v else None


def system_kind(system):
    """'popcorn' | 'megalon' | 'hwcc' from a run manifest's system= value (run.sh SYSTEM), None if unknown."""
    if not system:
        return None
    s = system.lower()
    if s.startswith("popcorn") or s.startswith("page msi") or s.startswith("page-msi"):
        return "popcorn"
    if s.startswith("megalon"):
        return "megalon"
    if s.startswith("all-hwcc"):
        return "hwcc"
    return None


def run_system(loadgen_dir):
    """system= of the run.sh manifest next to a loadgen dir (<run>/manifest.txt), or None."""
    p = os.path.join(os.path.dirname(os.path.abspath(loadgen_dir.rstrip("/"))), "manifest.txt")
    if os.path.exists(p):
        for line in open(p):
            if line.startswith("system="):
                return line.strip().split("=", 1)[1]
    return None


POP_COLS = ("pop_search_fault_s", "pop_search_msg_wait_s", "pop_search_local_wait_s", "pop_writer_fault_s",
            "pop_node_fault_s", "pop_remote_wb", "pop_acquire_flush")
MEG_COLS = ("meg_rd_check_s", "meg_wr_check_s", "meg_flush_s", "meg_reexec_s", "meg_stall_s", "meg_reexec_src")


def node_metrics(fixed, d, system=None):
    """Derived per-node values of one step (dict of NODE -> value or None). The coherence formula follows the run's
    system (system_kind; a page MSI kernel creates /proc/<tid>/swmc for every thread even without cxl_shm, so key
    presence does not identify the system): page MSI columns only for page MSI runs, Megalon columns only for
    Megalon runs, neither for all-HWcc. Unknown system (no manifest): page MSI if its fault counters are non-zero,
    else Megalon if megt.* exist. Missing counters stay None."""
    kind = system_kind(system)
    m = dict.fromkeys(NODE)
    win = fixed["window_s"] if fixed["window_s"] != "" else None
    m["window_s"] = win
    m["searches"], m["updates"], m["p_advance"] = d.get("searches"), d.get("updates"), d.get("P")
    nsearch = d.get("thr.vdb-search.n")
    if win and "search_busy_ns" in d and nsearch:
        m["search_busy_frac"] = d["search_busy_ns"] / (win * 1e9 * nsearch)
    if win and "writer_busy_ns" in d:
        m["writer_busy_frac"] = d["writer_busy_ns"] / (win * 1e9)
    s = lambda k: d[k] / 1e9 if k in d else None  # noqa: E731
    m["search_cpu_s"], m["search_rq_wait_s"] = s("thr.vdb-search.run_ns"), s("thr.vdb-search.wait_ns")
    m["writer_cpu_s"] = s("thr.vdb-writer.run_ns")
    cpu = [d[k] for k in d if k.startswith("cpu.")]
    if cpu and sum(cpu) > 0:
        m["cpu_busy_frac"] = 1 - (d.get("cpu.idle", 0) + d.get("cpu.iowait", 0)) / sum(cpu)
    ns = lambda keys: (lambda v: v / 1e9 if v is not None else None)(_sum(d, keys))  # noqa: E731
    sw = "thr.vdb-search.swmc."
    m["pop_search_fault_s"] = ns([sw + "read_fault_ns", sw + "write_fault_ns"])
    m["pop_search_msg_wait_s"] = ns([sw + "read_msg_wait_ns", sw + "write_msg_wait_ns"])
    m["pop_search_local_wait_s"] = ns([sw + "read_local_wait_ns", sw + "write_local_wait_ns"])
    m["pop_writer_fault_s"] = ns(["thr.vdb-writer.swmc.read_fault_ns", "thr.vdb-writer.swmc.write_fault_ns"])
    m["pop_node_fault_s"] = ns(["sys.swmc.page_coherence.total_page_fault_handling_time"])
    m["pop_remote_wb"] = d.get("sys.swmc.page_coherence.remote_writeback_count")
    m["pop_acquire_flush"] = d.get("sys.swmc.instr.serve.acquire_flush_count")
    if "megt.sample" in d:
        smp = d["megt.sample"]
        m["meg_rd_check_s"] = (d.get("megt.rd_start_ns", 0) + d.get("megt.rd_end_ns", 0)) * smp / 1e9
        m["meg_wr_check_s"] = d.get("megt.wr_start_ns", 0) / 1e9
        m["meg_flush_s"] = d.get("megt.wr_end_ns", 0) / 1e9
        retries = d.get("megt.rd_retries", 0)
        if retries == 0:
            m["meg_reexec_s"], m["meg_reexec_src"] = 0.0, "none"
        elif d.get("megt.rd_failed_timed"):
            m["meg_reexec_s"] = retries * d["megt.rd_failed_ns"] / d["megt.rd_failed_timed"] / 1e9
            m["meg_reexec_src"] = "timed"
        elif d.get("megt.rd_sampled"):
            sec = d.get("megt.rd_start_ns", 0) + d.get("megt.rd_body_ns", 0) + d.get("megt.rd_end_ns", 0)
            m["meg_reexec_s"] = retries * sec / d["megt.rd_sampled"] / 1e9
            m["meg_reexec_src"] = "est_section"
        m["meg_stall_s"] = sum(m[k] or 0 for k in ("meg_rd_check_s", "meg_wr_check_s", "meg_flush_s", "meg_reexec_s"))
    if kind is None:  # legacy inference
        if (m["pop_search_fault_s"] or 0) + (m["pop_writer_fault_s"] or 0) > 0:
            kind = "popcorn"
        elif m["meg_stall_s"] is not None:
            kind = "megalon"
    if kind != "popcorn":
        for c in POP_COLS:
            m[c] = None
    if kind != "megalon":
        for c in MEG_COLS:
            m[c] = None
    # coherence time over all request-serving threads (search + writer): page MSI managed-fault time of vdb-search
    # and vdb-writer threads; Megalon megt.* (per process: search, writer, main)
    if kind == "popcorn" and (m["pop_search_fault_s"] is not None or m["pop_writer_fault_s"] is not None):
        m["coh_stall_s"] = (m["pop_search_fault_s"] or 0) + (m["pop_writer_fault_s"] or 0)
    elif kind == "megalon" and m["meg_stall_s"] is not None:
        m["coh_stall_s"] = m["meg_stall_s"]
    recv = [k for k in d if k.startswith("kthr.cxl_recv") and k.endswith(".run_ns")]
    if recv:
        m["recv_cpu_s"] = sum(d[k] for k in recv) / 1e9
    else:
        ticks = [k for k in d if k.startswith("kthr.cxl_recv") and k.endswith(".cpu_ticks")]
        m["recv_cpu_s"] = sum(d[k] for k in ticks) / 100 if ticks else None
    # run 2: adaptive receiver idle pollers (kthreads cxl_ipoll/<cpu>, SCHED_IDLE) apart from cxl_recv; not part of
    # coh_bg_cpu_s (they spin only on otherwise idle vCPUs; reported next to it)
    ip = [k for k in d if k.startswith("kthr.cxl_ipoll") and k.endswith(".run_ns")]
    m["ipoll_cpu_s"] = sum(d[k] for k in ip) / 1e9 if ip else None
    bg = [k for k in d if k.startswith("thr.") and k.endswith(".run_ns") and not k.startswith("thr.vdb-")]
    m["lib_bg_cpu_s"] = sum(d[k] for k in bg) / 1e9 if bg else (0.0 if "thr.vdb-search.run_ns" in d else None)
    if m["recv_cpu_s"] is not None or m["lib_bg_cpu_s"] is not None:
        m["coh_bg_cpu_s"] = (m["recv_cpu_s"] or 0) + (m["lib_bg_cpu_s"] or 0)
    m["tlb_ipi"], m["cal_ipi"] = d.get("irq.TLB"), d.get("irq.CAL")
    if kind == "megalon" and "megalon.flush_bytes" in d:
        m["traffic_bytes"] = d["megalon.flush_bytes"] + d.get("megalon.replay_flush_bytes", 0)
        m["traffic_src"] = "megalon"
    elif kind == "popcorn" and m["pop_remote_wb"] is not None and m["pop_acquire_flush"] is not None and d.get("sys.swmc.instr.enabled") == 1:
        m["traffic_bytes"] = (m["pop_remote_wb"] + m["pop_acquire_flush"]) * PAGE
        m["traffic_src"] = "popcorn"
    elif kind == "popcorn" and m["pop_remote_wb"] is not None:
        m["traffic_bytes"] = m["pop_remote_wb"] * PAGE
        m["traffic_src"] = "popcorn-wb"
    return m


def run_slo(run):
    """(stream, pct, ms) of the run's --slo, from manifest.txt (summary.json slo as fallback); blanks if none."""
    mf = os.path.join(run, "manifest.txt")
    if os.path.exists(mf):
        for line in open(mf):
            if line.startswith("slo="):
                st, pct, ms = (line.strip()[4:].split(":") + ["", "", ""])[:3]
                if st:
                    return st, float(pct), float(ms)
    slo = json.load(open(os.path.join(run, "summary.json"))).get("slo", {})
    return slo.get("stream", ""), slo.get("pct", ""), slo.get("ms", "")


def blank(v):
    return "" if v is None else v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    runs = []
    for spec in a.runs:
        run, _, label = spec.partition("=")
        per_step = {}
        system = run_system(run)
        for fixed, d in stats_delta.deltas(run):
            per_step.setdefault(fixed["step"], {})[fixed["target"]] = node_metrics(fixed, d, system)
        ntgt = sum(1 for line in open(os.path.join(run, "manifest.txt")) if line.startswith("target=")) \
            if os.path.exists(os.path.join(run, "manifest.txt")) else 0
        runs.append((run, label or os.path.basename(run.rstrip("/")), per_step, ntgt))
    nodes = max([2] + [r[3] for r in runs] + [max(t) + 1 for r in runs for t in r[2].values()])
    cols = BASE + STEP + [f"n{k}_{c}" for k in range(nodes) for c in NODE] + RUNSLO + BRACKET + RULES + DRAIN
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for run, label, per_step, _ in runs:
            summ = json.load(open(os.path.join(run, "summary.json")))
            best = summ.get("confirm", {}).get("x_mean", "")
            slo = list(run_slo(run))
            kb = knee_bracket(summ, [json.loads(line) for line in open(os.path.join(run, "steps.jsonl")) if line.strip()])
            brk = [blank(kb.get("lo")), blank(kb.get("hi"))]
            rules = [summ.get("confirm_rule", {}).get("rule", "")]
            for r in ("result_majority", "result_pooled"):
                rr = summ.get(r)
                rules += ["", ""] if rr is None else [blank(rr.get("max_offered_x_pass")), rr.get("complete")]
            brk += rules
            for line in open(os.path.join(run, "steps.jsonl")):
                s = json.loads(line)
                if s["phase"] == "warmup":
                    continue
                st = s["streams"]
                g = lambda n, k: st[n][k] if n in st else ""  # noqa: E731
                nm = per_step.get(s["step"], {})
                tb = [m["traffic_bytes"] for m in nm.values() if m["traffic_bytes"] is not None]
                upd = [m["updates"] for m in nm.values() if m["updates"] is not None]
                traffic = sum(tb) if tb else None
                per_upd = traffic / sum(upd) if tb and upd and sum(upd) > 0 else None
                step_cols = [g("search", "achieved"), g("update", "achieved"),
                             sum(x["achieved"] for x in st.values()), g("search", "p50_ms"), g("search", "p99_ms"),
                             g("update", "p50_ms"), g("update", "p99_ms"), blank(traffic), blank(per_upd)]
                node_cols = []
                for k in range(nodes):
                    m = nm.get(k, {})
                    node_cols += [blank(m.get(c)) for c in NODE]
                drain = [blank(s.get(c)) for c in DRAIN]
                for name, x in st.items():
                    w.writerow([label, s["step"], s["phase"], s["measure_s"], s["pass"], s["aborted"], s["reason"], name,
                                x["offered"], x["achieved"], x["sent"], x["done"], x["errors"], x["timeouts"],
                                x["p50_ms"], x["p90_ms"], x["p99_ms"], x["p999_ms"], x["pslo_ms"], x["max_ms"],
                                x["lag_p99_us"], best] + step_cols + node_cols + slo + [x.get("p95_ms", "")] + brk
                               + drain)
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

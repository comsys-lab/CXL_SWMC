#!/usr/bin/env python3
"""Unit test (Host, no servers): stats_delta.py and the derived columns of export_csv.py on a synthetic run dir.
usage: python3 stats_delta_test.py <scratch dir>"""
import csv, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LG = os.path.dirname(HERE)
sys.path.insert(0, LG)
import stats_delta  # noqa: E402

fails = 0


def check(c, what):
    global fails
    if not c:
        fails += 1
        print("FAIL", what)


def snap(path, hdr, kv):
    with open(path, "w") as f:
        f.write("# " + " ".join(f"{k}={v}" for k, v in hdr.items()) + "\n")
        for k, v in kv.items():
            f.write(f"{k}={v}\n")


def main():
    run = os.path.join(sys.argv[1], "run")
    os.makedirs(os.path.join(run, "stats"))
    with open(os.path.join(run, "manifest.txt"), "w") as f:
        f.write("target=a:1\ntarget=b:1\n")
    b = {"node": 0, "P": 100, "updates": 10, "searches": 1000, "search_busy_ns": 0, "writer_busy_ns": 0,
         "backend": "plain segments=4", "t_mono_ns": 5_000_000_000, "thr.vdb-search.n": 4, "thr.vdb-search.run_ns": 0,
         "thr.megalon-lib.run_ns": 1_000_000_000, "kthr.cxl_recv_0.run_ns": 0, "irq.TLB": 50, "cpu.user": 100,
         "cpu.idle": 300, "megt.sample": 64, "megt.rd_start_ns": 0, "megt.rd_end_ns": 0, "megt.rd_retries": 0,
         "megt.rd_failed_timed": 0, "megt.rd_failed_ns": 0, "megt.wr_start_ns": 0, "megt.wr_end_ns": 0,
         "megalon.flush_bytes": 0, "megalon.replay_flush_bytes": 0, "sys.instr.fault_read.max_ns": 7, "only_begin": 1}
    e = dict(b, P=140, updates=30, searches=3000, search_busy_ns=4_000_000_000, writer_busy_ns=500_000_000,
             t_mono_ns=7_000_000_000, **{"thr.vdb-search.run_ns": 3_000_000_000, "thr.megalon-lib.run_ns": 1_500_000_000,
                                         "kthr.cxl_recv_0.run_ns": 200_000_000, "irq.TLB": 80, "cpu.user": 400,
                                         "cpu.idle": 400, "megt.rd_start_ns": 1000, "megt.rd_end_ns": 1000,
                                         "megt.rd_retries": 10, "megt.rd_failed_timed": 2, "megt.rd_failed_ns": 4000,
                                         "megt.wr_start_ns": 10_000, "megt.wr_end_ns": 20_000,
                                         "megalon.flush_bytes": 6400, "megalon.replay_flush_bytes": 3200,
                                         "sys.instr.fault_read.max_ns": 9})
    del e["only_begin"]
    hb = {"when": "begin", "phase": "ramp", "step": 1, "offered_x": 50, "target": 0, "addr": "a:1", "status": 0,
          "wall_ns": 1, "mono_ns": 1_000_000_000, "rtt_us": 10}
    he = dict(hb, when="end", wall_ns=2, mono_ns=3_000_000_000)
    snap(os.path.join(run, "stats", "step001-begin-t0.txt"), hb, b)
    snap(os.path.join(run, "stats", "step001-end-t0.txt"), he, e)
    snap(os.path.join(run, "stats", "step002-begin-t0.txt"), dict(hb, step=2), b)  # no end: skipped
    rows = stats_delta.deltas(run)
    check(len(rows) == 1, "one complete pair")
    fx, d = rows[0]
    check(fx["step"] == 1 and fx["phase"] == "ramp" and fx["window_s"] == 2.0 and fx["srv_window_s"] == 2.0, "fixed")
    check(d["P"] == 40 and d["updates"] == 20 and d["searches"] == 2000, "counter deltas")
    check(d["node"] == 0 and d["thr.vdb-search.n"] == 4 and d["megt.sample"] == 64, "gauges keep end value")
    check(d["sys.instr.fault_read.max_ns"] == 9, "max_ns is a gauge")
    # MOT1 v6 per-operation stats: op.<op>.n is a counter, sampling factors / TSC rate / thread counts are gauges
    check(not stats_delta.is_gauge("op.query.n") and not stats_delta.is_gauge("opt.get.ops"), "per-op counts")
    check(all(stats_delta.is_gauge(k) for k in ("op.query.mg.check_sample", "opt.meg_check_sample", "opt.tsc_hz",
                                                "opt.threads", "opt.pop_threads", "opt.version", "thr.x.n")),
          "per-op identity values")
    # Megalon >= 76 flag words and >= 77 probe cost are values (end value), the per-op sums beside them are counters
    check(all(stats_delta.is_gauge(k) for k in ("opt.search.meg.flags", "op.query.mg.flags", "opt.meg_flags",
                                                "opt.meg_lean", "opt.meg_events_always", "opt.meg_probe_ps_min",
                                                "opt.meg_probe_ps_max", "opt.search.meg.anchor.probe_ps_min",
                                                "opt.search.meg.anchor.probe_ps_max")), "Megalon flag / probe gauges")
    check(not any(stats_delta.is_gauge(k) for k in ("opt.get.meg.anchor.write_sampled", "op.query.mg.wstart_ns",
                                                    "opt.search.meg.anchor.timed_a", "opt.get.meg.check_sampled")),
          "Megalon per-op sums stay counters")
    check("backend" not in d and "only_begin" not in d, "non-numeric / one-sided keys dropped")
    subprocess.run([sys.executable, os.path.join(LG, "stats_delta.py"), run], check=True)
    hdr = next(csv.reader(open(os.path.join(run, "stats-steps.csv"))))
    check(hdr[:9] == stats_delta.FIXED and "P" in hdr, "stats-steps.csv header")
    # export_csv on a fake steps.jsonl
    st = {"offered": 0, "achieved": 0, "sent": 0, "done": 0, "errors": 0, "timeouts": 0, "p50_ms": 1, "p90_ms": 2,
          "p99_ms": 3, "p999_ms": 4, "pslo_ms": 3, "max_ms": 5, "lag_p99_us": 1, "lag_max_us": 1}
    step = {"step": 1, "phase": "ramp", "offered_x": 50, "measure_s": 2, "x": 50, "pass": True, "aborted": False,
            "lag_flag": False, "reason": "", "streams": {"update": dict(st, achieved=10.0, p99_ms=7),
                                                         "search": dict(st, achieved=1000.0)}}
    with open(os.path.join(run, "steps.jsonl"), "w") as f:
        f.write(json.dumps(dict(step, step=0, phase="warmup")) + "\n" + json.dumps(step) + "\n")
    with open(os.path.join(run, "summary.json"), "w") as f:
        json.dump({"confirm": {"x_mean": 900}}, f)
    out = os.path.join(sys.argv[1], "steps.csv")
    subprocess.run([sys.executable, os.path.join(LG, "export_csv.py"), "--out", out, run + "=t"], check=True)
    r = list(csv.DictReader(open(out)))
    check(len(r) == 2 and {x["stream"] for x in r} == {"update", "search"}, "rows per stream, warmup skipped")
    x = r[0]
    f = lambda k: float(x[k])  # noqa: E731
    check(f("search_per_s") == 1000 and f("update_per_s") == 10 and f("total_ops_per_s") == 1010, "rates")
    check(f("update_p99_ms") == 7 and f("search_p99_ms") == 3, "percentiles")
    check(f("n0_window_s") == 2 and f("n0_updates") == 20 and f("n0_p_advance") == 40, "node counters")
    check(abs(f("n0_search_busy_frac") - 0.5) < 1e-9, "busy frac = 4 s / (2 s x 4 threads)")
    check(abs(f("n0_writer_busy_frac") - 0.25) < 1e-9, "writer busy")
    check(abs(f("n0_cpu_busy_frac") - (1 - 100 / 400)) < 1e-9, "cpu busy (300 user + 100 idle)")
    check(abs(f("n0_meg_rd_check_s") - 2000 * 64 / 1e9) < 1e-15, "megalon read check scaled")
    check(abs(f("n0_meg_reexec_s") - 10 * 2000 / 1e9) < 1e-15, "re-exec = retries x mean timed failed attempt")
    check(abs(f("n0_meg_stall_s") - (128000 + 10000 + 20000 + 20000) / 1e9) < 1e-15, "megalon stall sum")
    check(f("n0_coh_stall_s") == f("n0_meg_stall_s"), "coh stall = megalon")
    check(abs(f("n0_recv_cpu_s") - 0.2) < 1e-9 and abs(f("n0_lib_bg_cpu_s") - 0.5) < 1e-9, "background CPU")
    check(abs(f("n0_coh_bg_cpu_s") - 0.7) < 1e-9 and f("n0_tlb_ipi") == 30, "bg sum, IPIs")
    check(f("n0_traffic_bytes") == 9600 and x["n0_traffic_src"] == "megalon", "traffic")
    check(f("traffic_bytes") == 9600 and f("traffic_per_update") == 480, "step traffic per update")
    check(x["n1_window_s"] == "" and x["n0_pop_search_fault_s"] == "", "absent node / counters are empty")
    # Popcorn traffic: (remote write-backs + acquire flushes) x 4 KiB; wb_flush_count is not added
    import export_csv  # noqa: E402
    pd = {"sys.swmc.page_coherence.remote_writeback_count": 10, "sys.swmc.instr.serve.acquire_flush_count": 5,
          "sys.swmc.instr.serve.wb_flush_count": 10, "sys.swmc.instr.enabled": 1}
    pm = export_csv.node_metrics({"window_s": 1.0}, pd, "Popcorn-poll")
    check(pm["traffic_bytes"] == 15 * 4096 and pm["traffic_src"] == "popcorn", "popcorn traffic")
    pm = export_csv.node_metrics({"window_s": 1.0}, {"sys.swmc.page_coherence.remote_writeback_count": 3}, "Popcorn-poll")
    check(pm["traffic_bytes"] == 3 * 4096 and pm["traffic_src"] == "popcorn-wb", "popcorn traffic without instr")
    pm = export_csv.node_metrics({"window_s": 1.0}, dict(pd, **{"sys.swmc.instr.enabled": 0}), "Popcorn-poll")
    check(pm["traffic_bytes"] == 10 * 4096 and pm["traffic_src"] == "popcorn-wb", "popcorn traffic, instr disabled")
    md = {"megt.sample": 64, "megt.rd_retries": 4, "megt.rd_failed_timed": 0, "megt.rd_sampled": 10,
          "megt.rd_start_ns": 100, "megt.rd_body_ns": 200, "megt.rd_end_ns": 700}
    mm = export_csv.node_metrics({"window_s": 1.0}, md, "Megalon")
    check(abs(mm["meg_reexec_s"] - 4 * 100 / 1e9) < 1e-18 and mm["meg_reexec_src"] == "est_section", "reexec estimate")
    check(x["n0_meg_reexec_src"] == "timed", "reexec timed")
    # system decides the formula, not key presence (page MSI kernels expose zero swmc counters for every process)
    z = dict(md, **{"thr.vdb-search.swmc.read_fault_ns": 0, "thr.vdb-search.swmc.write_fault_ns": 0,
                    "thr.vdb-writer.swmc.read_fault_ns": 0, "thr.vdb-writer.swmc.write_fault_ns": 0,
                    "megalon.flush_bytes": 640})
    mz = export_csv.node_metrics({"window_s": 1.0}, z, "Megalon")
    check(mz["coh_stall_s"] == mz["meg_stall_s"] and mz["meg_stall_s"] > 0 and mz["pop_search_fault_s"] is None,
          "Megalon on a page MSI kernel uses megt.*")
    check(mz["traffic_src"] == "megalon", "Megalon traffic")
    mp = export_csv.node_metrics({"window_s": 1.0}, dict(z, **{"thr.vdb-search.swmc.read_fault_ns": 2000,
                                                                 "thr.vdb-writer.swmc.write_fault_ns": 1000}), "Popcorn-poll")
    check(abs(mp["coh_stall_s"] - 3e-6) < 1e-15 and mp["meg_stall_s"] is None, "page MSI: search + writer fault time")
    mh = export_csv.node_metrics({"window_s": 1.0}, z, "all-HWcc")
    check(mh["coh_stall_s"] is None and mh["meg_stall_s"] is None and mh["pop_search_fault_s"] is None
          and mh["traffic_bytes"] is None, "all-HWcc: no coherence columns")
    mu = export_csv.node_metrics({"window_s": 1.0}, z)  # unknown system, zero swmc: legacy inference -> Megalon
    check(mu["coh_stall_s"] == mu["meg_stall_s"], "legacy inference ignores zero swmc counters")
    print("PASSED" if not fails else f"FAILED ({fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

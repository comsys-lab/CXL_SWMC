#!/usr/bin/env python3
"""New H2 (vector DB VM-count scaling) canonical CSVs. Host only, offline, read only on the evidence.

One aggregate SLO search per (N, mix, system) (h2n-block.sh); the figures read the latency-throughput steps of each
(N, mix, system), the max under the SLO (bar chart, scaling plot) and the coherence counters at that point.

usage: export_h2n.py --run K --nodes N --config-sha256 S --out DIR [--source h2n|2vm] [--cxlbw DIR] [--hostcpu DIR]
                     EVIDENCE [EVIDENCE..]
       export_h2n.py --combine --out DIR EXPORT_DIR [EXPORT_DIR..]   (concatenate per-N exports: summary.csv, steps.csv)
  --source h2n  EVIDENCE = h2n block dirs (<E>/block of runset-h2n.sh: h2n-results.tsv, <sys>-<mix>-n<N>/slo, cxlbw/,
                hostcpu/). Several dirs of one N (a resumed N: the stopped block's dir, then the resumed one): a later
                dir wins per (mix, system). The sampler dirs are <block>/cxlbw and <block>/hostcpu unless --cxlbw /
                --hostcpu is given.
  --source 2vm  EVIDENCE = a 2-VM vdb run set dir (<E>/vdb/r<n>/run/{hw,pop}-<mix>-slo-r<n>/slo, mg-<mix>-r<n>/slo; e.g.
                recovery/two-workload-eval-run1-vdb-v1): self tests and the 16-vCPU comparison only (it is NOT the
                N = 2 point of new H2, which is measured at 4 vCPU / 24 GB).
Outputs (in --out):
  steps.csv                    one row per (nodes, mix, system, measured SLO step), aggregate over the N VMs:
                               latency of the search stream (loadgen measures the aggregate), counters summed over VMs
  steps-n<N>-<mix>-<sys>.csv   the same rows of one lifetime (latency-throughput curve for the spreadsheet)
  steps-vm.csv                 one row per (nodes, mix, system, step, vm): that VM's counters (per s)
  summary.csv                  one row per (nodes, mix, system): result + counters at the result (mean of the
                               at_result steps = the confirm repeats at the result rate, canon.confirm_stats)
Units: counters are events per second of the step window (summed over the N VMs), *_per_op per achieved op (search +
update), *_ns_per_op in ns per achieved op, CPU columns in cores (CPU-seconds per second), busy columns 0..1.
summary.csv columns (first eleven = the figure contract): nodes, mix, system, max_under_slo_search_s (loadgen confirm
  x_mean = ACHIEVED searches/s, mean over the confirm repeats at the result rate, aggregate over the N VMs; empty if not
  confirmed), faults_read, faults_write (Popcorn managed page faults per s, sys.swmc.page_coherence.fault_{read,write}_
  count summed over the N VMs; supersets: they include managed faults without a state transition), coherence_events
  (Popcorn MSI state transitions per s = is_faults (sys.swmc.instr.fault_full_is.count, exact I->S) + inv_commits
  (sys.swmc.instr.tx_invalidate.ack, committed invalidation rounds = I->M and S->M incl. write-protect upgrades)),
  mg_fetch (Megalon read-side stale-copy flush + refetch per s: megalon.read_retry_incoherent; each one is exactly one
  object flush, lib/object_store.cc ReadStart/ReadEnd), mg_flush_writeend (Megalon write-end object flushes per s =
  megalon.flushes - megalon.read_retry_incoherent), cxl_rd_MBs, cxl_wr_MBs (Host CXL.mem MB/s, cxl-bw-sampler.sh,
  Intel PCM rule; perf intervals fully inside the step's guest wall window); then *_per_op variants, Popcorn request
  wait (tx_wait_ns_per_op: sys.swmc.instr.tx_{fetch,invalidate}.wait_sum_ns summed over VMs per op, filled only when
  the instr detail histograms count (wait_count > 0; empty with instr detail=0); msg_wait_ns_per_op /
  msg_wait_ns_per_round: per-thread thr.*.swmc.{read,write}_msg_wait_ns, always on, request round send -> last
  response incl. ring-full send retries), Host CPU of the QEMU emulator / vhost threads and of the loadgen
  (host-cpu-sampler.py), raw Megalon counters per s, confirm stats, validity.
  A coherence column of a system without that mechanism is 0 when its counter is absent (hw: all, pop: mg_*,
  mg: faults_* / coherence_events); counter_source names what was read.
Fig 8 columns (appended to steps.csv and summary.csv; de-stijl-motivation-isca27 §2.1, 2026-10-22): per server search
  (srv_searches = server counter "searches" summed over the VMs) of the vector DB server's search threads (comm
  vdb-search): srch_wall_ns_per_search W (search_busy_ns), srch_{is,sm,wpu,nontrans}_fault_ns_per_search,
  srch_coh_ipi_ns_per_search, srch_ipi_coh_infault_ns_per_search, srch_{read,write}_msg_wait_ns_per_search, srch_F
  (is + sm + wpu), srch_C (F + coh IPI outside faults), srch_sections_t_ns_per_search (opt.search.t_ns, cross-check of
  W), and the stack fig8_inval_ipi (C - F), fig8_owner_wait (MW = read + write msg wait), fig8_other_fault (F + NT -
  MW), fig8_query (W - C - NT), which add up to W. Popcorn columns are 0 (kernel keys present, no coherence) or empty
  for hw / mg; W is filled for every system (the All-HWcc base of the normalization). C agrees with the server's
  per-op accounting opt.search.c_ns within a few % (sections vs stats window). steps.csv also gets "aborted" (loadgen queue-cap abort; such steps are
  kept: drawn clipped). fig8.csv (per-N export and --combine): one row per (nodes, mix) at the Fig 8 load point
  (user 2026-10-22 Q1: the highest ramp step offered rate that both hw and pop pass), hw and pop W, the Popcorn
  stack, all normalized to hw's W (fig8_norm_*); variant common_n (verifier L1): one load per mix, the highest ramp
  rate passed by hw and pop at every N of the export (n_set), rows per N at that load.
summary.csv lowest_ramp_{step,offered_x,search_s,p99_ms,mg_fetch_per_op} (verifier L3): the lowest measured ramp step
  of every search (aggregate achieved searches/s, its p99, Megalon read_retry_incoherent per achieved op; 0 for hw,
  pop): the hatched value of Figs 5 and 7 when confirmed is not True.
"""
import argparse
import csv
import glob
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import canon  # noqa: E402
import export_h3 as X3  # noqa: E402  (Popcorn counter formulas: experiments/rocksdb/h3-faults.py KEYS)

_spec = importlib.util.spec_from_file_location("cxl_bw", os.path.join(HERE, "cxl_bw.py"))
CXB = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(CXB)

MG = {"mg_fetch": "megalon.read_retry_incoherent", "mg_flushes": "megalon.flushes",
      "mg_read_sections": "megalon.read_sections", "mg_write_sections": "megalon.write_sections",
      "mg_retry_notify": "megalon.read_retry_notify", "mg_replay_flushes": "megalon.replay_flushes",
      "mg_flush_bytes": "megalon.flush_bytes"}
POPC = {"faults_read": "read_faults", "faults_write": "write_faults", "is_faults": "is_faults",
        "inv_commits": "inv_commits", "fetch_commits": "fetch_commits", "coh_ipis": "coh_ipis"}
# Popcorn request wait (verifier review v1 M5): node-wide tx histograms (instr detail only) and per-thread accounting
TXW = {"tx_wait_ns": ("sys.swmc.instr.tx_fetch.wait_sum_ns", "sys.swmc.instr.tx_invalidate.wait_sum_ns"),
       "tx_wait_count": ("sys.swmc.instr.tx_fetch.wait_count", "sys.swmc.instr.tx_invalidate.wait_count")}
THR = {"msg_wait_ns": (".swmc.read_msg_wait_ns", ".swmc.write_msg_wait_ns"),
       "msg_rounds": (".swmc.read_transactions", ".swmc.write_transactions"),
       "nack_retries": (".swmc.nack_retries",)}
# Fig 8 (de-stijl-motivation-isca27 §2.1): Popcorn coherence time of the vector DB server's SEARCH threads (comm
# "vdb-search": every search segment task runs on them; the writer, connection and listener threads are not in it),
# per server search, summed over the N VMs; same definitions as the RecSys streaming breakdown (figs-h1h2 h2s.py):
SRCH = "thr.vdb-search.swmc."
FIG8_THR = {"srch_is_fault_ns": "is_fault_ns", "srch_sm_fault_ns": "sm_fault_ns", "srch_wpu_fault_ns": "wpu_fault_ns",
            "srch_nontrans_fault_ns": "nontrans_fault_ns", "srch_coh_ipi_ns": "ipi_coh_ns",
            "srch_ipi_coh_infault_ns": "ipi_coh_infault_ns", "srch_read_msg_wait_ns": "read_msg_wait_ns",
            "srch_write_msg_wait_ns": "write_msg_wait_ns"}
#   W  = srch_wall_ns: server counter search_busy_ns (wall time of every search task run by the search threads)
#   F  = is + sm + wpu fault ns (transition faults), NT = nontrans fault ns, MW = read + write msg wait ns,
#   C  = F + coherence IPI ns outside faults (ipi_coh_ns - ipi_coh_infault_ns) = swmc_acct C
#   fig8_inval_ipi = C - F, fig8_owner_wait = MW, fig8_other_fault = F + NT - MW, fig8_query = W - C - NT
#   (they add up to W). srch_sections_t_ns = opt.search.t_ns (sum of the search sections, a cross-check of W).
FIG8_SEG = ["fig8_inval_ipi_ns_per_search", "fig8_owner_wait_ns_per_search", "fig8_other_fault_ns_per_search",
            "fig8_query_ns_per_search"]
FIG8 = (["srv_searches", "srch_wall_ns_per_search"] + [k + "_per_search" for k in FIG8_THR]
        + ["srch_C_ns_per_search", "srch_F_ns_per_search", "srch_sections_t_ns_per_search"] + FIG8_SEG)
DERIVED = ["coherence_events", "mg_flush_writeend"]
RATE = ["faults_read", "faults_write", "coherence_events", "is_faults", "inv_commits", "fetch_commits", "coh_ipis",
        "mg_fetch", "mg_flush_writeend", "mg_flushes", "mg_read_sections", "mg_write_sections", "mg_retry_notify",
        "mg_replay_flushes", "mg_flush_bytes"]
WAIT = ["tx_wait_ns_per_op", "tx_wait_count_per_s", "msg_wait_ns_per_op", "msg_wait_ns_per_round", "nack_retries"]
HCPU = ["qemu_emu_cpu", "qemu_vhost_cpu", "qemu_vcpu_cpu", "emu_pcpu_busy_max", "loadgen_cpu", "lg_pcpu_busy_mean",
        "hostcpu_n_samples"]
CXL = ["cxl_rd_MBs", "cxl_wr_MBs", "cxl_n_intervals"]
SUMMARY_HEAD = ["nodes", "mix", "system", "max_under_slo_search_s", "faults_read", "faults_write", "coherence_events",
                "mg_fetch", "mg_flush_writeend", "cxl_rd_MBs", "cxl_wr_MBs"]
PER_OP = ["faults_read", "faults_write", "coherence_events", "mg_fetch", "mg_flush_writeend"]
SUMMARY = SUMMARY_HEAD + [k + "_per_op" for k in PER_OP] + [
    "cxl_rd_B_per_op", "cxl_wr_B_per_op"] + WAIT + HCPU + [
    "is_faults", "inv_commits", "fetch_commits", "coh_ipis", "mg_flushes", "mg_read_sections", "mg_write_sections",
    "mg_retry_notify", "mg_replay_flushes", "mg_flush_bytes", "result_offered_x", "result_offered_search_s",
    "confirm_x_sd", "confirmed", "note", "n_at_result", "valid_at_result", "at_result_search_s", "at_result_update_s",
    "at_result_p99_ms", "cxl_n_intervals", "counter_source", "vcpus_per_vm", "threads", "u", "run", "config_sha256",
    "lifetime", "source_dir"] + FIG8 + [   # Fig 8 columns appended (mean over the at_result steps)
    "lowest_ramp_step", "lowest_ramp_offered_x", "lowest_ramp_search_s", "lowest_ramp_p99_ms",
    "lowest_ramp_mg_fetch_per_op"]     # verifier L3: hatched bars of Figs 5 / 7 (searches without a confirmed max)
STEP = ["nodes", "mix", "system", "u", "step", "phase", "offered_x", "search_s", "update_s", "p50_ms", "p95_ms",
        "p99_ms", "pass", "at_result", "valid", "window_s"] + RATE + WAIT + CXL + HCPU + ["run", "config_sha256",
                                                                                         "lifetime"] + FIG8 + ["aborted"]
STEP_VM = ["nodes", "mix", "system", "step", "phase", "offered_x", "vm", "window_s"] + RATE + ["run", "lifetime"]
SYS = {"hw", "pop", "mg", "mgoff"}


def fl(v):
    return canon.fl(v)


def lifetimes_h2n(dirs, nodes):
    """{(mix, sys): (name, part dir, block dir)}; later dirs win"""
    out = {}
    for E in dirs:
        p = os.path.join(E, "h2n-results.tsv")
        for ln in open(p):
            f = ln.rstrip("\n").split("\t")
            if ln.startswith("#") or len(f) < 11:
                continue
            if int(f[4]) != nodes:
                raise SystemExit(f"{p}: row nodes {f[4]} != --nodes {nodes}")
            out[(f[2], f[1])] = (f[0], os.path.join(E, f[10]), E)
    return out


def lifetimes_2vm(dirs, nodes):
    if nodes != 2:
        raise SystemExit("--source 2vm needs --nodes 2")
    out = {}
    for E in dirs:
        for d in sorted(glob.glob(os.path.join(E, "vdb", "r*", "run", "*"))):
            m = re.fullmatch(r"(hw|pop)-(u\d+)-slo-r\d+|(mg)-(u\d+)-r\d+", os.path.basename(d))
            if m and os.path.isdir(os.path.join(d, "slo")):
                s, mix = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
                out[(mix, s)] = (os.path.basename(d), os.path.join(d, "slo"), E)
    return out


def sum_key(rows, key):
    v = [float(r[key]) for r in rows if r.get(key) not in (None, "")]
    return sum(v) if v else None


def sum_keys(rows, keys):
    v = [sum_key(rows, k) for k in keys]
    v = [x for x in v if x is not None]
    return sum(v) if v else None


def sum_thr(rows, suffixes):
    """sum over every per-thread key thr.<comm><suffix> of every target row (None when no such key)"""
    tot = None
    for r in rows:
        for k, v in r.items():
            if k.startswith("thr.") and k.endswith(suffixes) and v not in (None, ""):
                tot = (tot or 0) + float(v)
    return tot


def cxl_steps(sampler, part):
    """{step: (read MB/s, write MB/s, n intervals, seconds)} from the sampler dir over the part's step windows"""
    if not sampler or not os.path.isfile(os.path.join(sampler, "perf.csv")):
        return {}
    iv = CXB.intervals(sampler)
    out, seen = {}, set()
    for r in csv.DictReader(open(os.path.join(part, "stats-steps.csv"))):
        n = int(r["step"])
        if n in seen or not r.get("begin_wall_ns") or not r.get("end_wall_ns"):
            continue
        seen.add(n)
        b, e = int(r["begin_wall_ns"]) / 1e9, int(r["end_wall_ns"]) / 1e9
        sel = [x for x in iv if x[0] >= b and x[1] <= e]
        dt = sum(x[1] - x[0] for x in sel)
        out[n] = (sum(x[2] for x in sel) / dt / 1e6 if dt else None, sum(x[3] for x in sel) / dt / 1e6 if dt else None,
                  len(sel), dt)
    return out


def hostcpu_load(hdir):
    """(samples, clk_tck, domains, emulator CPUs, loadgen CPUs) of a host-cpu-sampler.py dir, or None"""
    if not hdir or not os.path.isfile(os.path.join(hdir, "samples.csv")):
        return None
    clk, doms, emu, lg = 100, [], set(), set()
    for ln in open(os.path.join(hdir, "manifest.txt")):
        f = dict(x.split("=", 1) for x in ln.split() if "=" in x)
        if ln.startswith("clk_tck="):
            clk = int(f["clk_tck"])
            if f.get("extra_cpus"):
                lg = cpus_of(f["extra_cpus"])
        elif ln.startswith("domain="):
            doms.append(f["domain"])
        elif ln.startswith("thread ") and f.get("class") in ("emu", "vhost") and f.get("affinity"):
            comm = ln.split(" comm=", 1)[1].strip() if " comm=" in ln else ""
            if f["class"] == "vhost" or comm.startswith("qemu-system"):
                emu |= cpus_of(f["affinity"])
    with open(os.path.join(hdir, "samples.csv")) as fh:
        smp = list(csv.DictReader(fh))
    return smp, clk, doms, emu - lg, lg


def cpus_of(s):
    out = set()
    for part in s.split(","):
        if part:
            a, _, b = part.partition("-")
            out.update(range(int(a), int(b or a) + 1))
    return out


def hostcpu_steps(hc, part):
    """{step: {HCPU column: value}}: counter deltas between the first and the last sample inside the step window"""
    if not hc:
        return {}
    smp, clk, doms, emu, lg = hc
    ts = [int(s["epoch_ns"]) for s in smp]
    out, seen = {}, set()
    for r in csv.DictReader(open(os.path.join(part, "stats-steps.csv"))):
        n = int(r["step"])
        if n in seen or not r.get("begin_wall_ns") or not r.get("end_wall_ns"):
            continue
        seen.add(n)
        b, e = int(r["begin_wall_ns"]), int(r["end_wall_ns"])
        idx = [i for i, t in enumerate(ts) if b <= t <= e]
        o = {"hostcpu_n_samples": len(idx)}
        if len(idx) >= 2:
            s0, s1 = smp[idx[0]], smp[idx[-1]]
            dt = (ts[idx[-1]] - ts[idx[0]]) / 1e9

            def d(col):
                a, z = fl(s0.get(col)), fl(s1.get(col))
                return z - a if a is not None and z is not None else None

            for cls, col in (("emu", "qemu_emu_cpu"), ("vhost", "qemu_vhost_cpu"), ("vcpu", "qemu_vcpu_cpu")):
                v = [d(f"{dm}.{cls}") for dm in doms]
                o[col] = sum(v) / clk / dt if v and all(x is not None for x in v) else None

            def busy(c):
                tb, tt = d(f"cpu{c}.busy"), d(f"cpu{c}.total")
                return tb / tt if tb is not None and tt else None

            eb = [x for x in (busy(c) for c in sorted(emu)) if x is not None]
            o["emu_pcpu_busy_max"] = max(eb) if eb else None
            lb = [x for x in (busy(c) for c in sorted(lg)) if x is not None]
            o["lg_pcpu_busy_mean"] = sum(lb) / len(lb) if lb else None
            same = s0.get("loadgen_pids") and s0.get("loadgen_pids") == s1.get("loadgen_pids")
            lt = d("loadgen")
            o["loadgen_cpu"] = lt / clk / dt if same and lt is not None else None
        out[n] = o
    return out


def derive(o, rs, win):
    """coherence_events, mg_flush_writeend (per s) of one row from its rates and the target rows"""
    i, v = fl(o.get("is_faults")), fl(o.get("inv_commits"))
    o["coherence_events"] = i + v if i is not None and v is not None else None
    fx, ff = sum_key(rs, MG["mg_flushes"]), sum_key(rs, MG["mg_fetch"])
    o["mg_flush_writeend"] = (fx - ff) / win if fx is not None and ff is not None and win else None


def fig8_cols(rs):
    """Fig 8 columns of one step from the target rows (stats deltas): per server search, summed over the VMs; the
    Popcorn columns stay empty for a system without the search threads' swmc keys (hw, mg)"""
    ns = sum_key(rs, "searches")
    o = {k: None for k in FIG8}
    o["srv_searches"] = ns
    if not ns:
        return o
    per = lambda v: v / ns if v is not None else None  # noqa: E731
    o["srch_wall_ns_per_search"] = per(sum_key(rs, "search_busy_ns"))
    o["srch_sections_t_ns_per_search"] = per(sum_key(rs, "opt.search.t_ns"))
    for col, key in FIG8_THR.items():
        o[col + "_per_search"] = per(sum_key(rs, SRCH + key))
    g = {k: o[k + "_per_search"] for k in FIG8_THR}
    if g["srch_is_fault_ns"] is None:
        return o
    z = lambda k: g[k] or 0.0  # noqa: E731  (a key absent on one build: 0)
    F = z("srch_is_fault_ns") + z("srch_sm_fault_ns") + z("srch_wpu_fault_ns")
    C = F + z("srch_coh_ipi_ns") - z("srch_ipi_coh_infault_ns")
    NT, MW, W = z("srch_nontrans_fault_ns"), z("srch_read_msg_wait_ns") + z("srch_write_msg_wait_ns"), \
        o["srch_wall_ns_per_search"]
    o.update(srch_F_ns_per_search=F, srch_C_ns_per_search=C, fig8_inval_ipi_ns_per_search=C - F,
             fig8_owner_wait_ns_per_search=MW, fig8_other_fault_ns_per_search=F + NT - MW,
             fig8_query_ns_per_search=W - C - NT if W is not None else None)
    return o


def lifetime_rows(part, nodes, sampler, hc=None):
    rows3, sm = X3.part_rows(part, "vdb", nodes)
    cs = X3.step_counters(part)
    cx = cxl_steps(sampler, part)
    hx = hostcpu_steps(hc, part)
    ab = {d["step"]: d.get("aborted") for d in canon.measured_steps(part)}  # queue-cap aborted steps stay (clipped)
    agg, per_vm = [], []
    for r in rows3:
        n = r["step"]
        rs = cs.get(n, [])
        win = fl(r.get("window_s"))
        if r["vm"] == "all":
            o = dict(step=n, phase=r["phase"], offered_x=r["offered_x"], search_s=fl(r.get("achieved_x")),
                     update_s=fl(r.get("wop_per_s")), p50_ms=r.get("p50_ms"), p95_ms=r.get("p95_ms"),
                     p99_ms=r.get("p99_ms"), at_result=r["at_result"], valid=r.get("valid"), window_s=win)
            o["pass"], o["aborted"] = r.get("pass"), ab.get(n)
            for k, src in POPC.items():
                o[k] = r.get(src + "_per_s")
            for k, key in MG.items():
                t = sum_key(rs, key)
                o[k] = t / win if t is not None and win else None
            derive(o, rs, win)
            ops = ((o["search_s"] or 0) + (o["update_s"] or 0)) * (win or 0)
            tw, tc = sum_keys(rs, TXW["tx_wait_ns"]), sum_keys(rs, TXW["tx_wait_count"])
            o["tx_wait_count_per_s"] = tc / win if tc is not None and win else None
            o["tx_wait_ns_per_op"] = tw / ops if tw is not None and tc and ops else None
            mw, mr = sum_thr(rs, THR["msg_wait_ns"]), sum_thr(rs, THR["msg_rounds"])
            o["msg_wait_ns_per_op"] = mw / ops if mw is not None and ops else None
            o["msg_wait_ns_per_round"] = mw / mr if mw is not None and mr else None
            nr = sum_thr(rs, THR["nack_retries"])
            o["nack_retries"] = nr / win if nr is not None and win else None
            c = cx.get(n)
            o.update(cxl_rd_MBs=c[0] if c else None, cxl_wr_MBs=c[1] if c else None, cxl_n_intervals=c[2] if c else None)
            o.update(hx.get(n, {}))
            o.update(fig8_cols(rs))
            o["_has"] = {k: (any(rr.get(key) not in (None, "") for rr in rs)) for k, key in MG.items()}
            o["_has_pop"] = any(rr.get("sys.swmc.page_coherence.fault_read_count") not in (None, "") for rr in rs)
            agg.append(o)
        else:
            k = int(r["vm"])
            rr = rs[k] if k < len(rs) else {}
            o = dict(step=n, phase=r["phase"], offered_x=r["offered_x"], vm=r["vm"], window_s=win)
            for kk, src in POPC.items():
                o[kk] = r.get(src + "_per_s")
            for kk, key in MG.items():
                t = fl(rr.get(key))
                o[kk] = t / win if t is not None and win else None
            derive(o, [rr] if rr else [], win)
            per_vm.append(o)
    return agg, per_vm, sm


def mean(rows, k):
    v = [fl(r.get(k)) for r in rows if fl(r.get(k)) is not None]
    return sum(v) / len(v) if v else None


def summary_row(system, agg, sm, u):
    at = [r for r in agg if r["at_result"]]
    c = sm.get("confirm") or {}
    conf = sm.get("confirmed") is True
    o = dict(max_under_slo_search_s=fl(c.get("x_mean")) if conf else None, confirmed=sm.get("confirmed"),
             confirm_x_sd=fl(c.get("x_sd")), note=sm.get("note", ""), n_at_result=len(at),
             result_offered_x=fl(sm.get("max_offered_x_pass")) if conf else None)
    o["result_offered_search_s"] = o["result_offered_x"] * (100 - u) / 100 if o["result_offered_x"] is not None else None
    vs = [r.get("valid") for r in at]
    o["valid_at_result"] = all(vs) if vs and all(x is not None for x in vs) else None
    o["at_result_search_s"], o["at_result_update_s"] = mean(at, "search_s"), mean(at, "update_s")
    o["at_result_p99_ms"] = mean(at, "p99_ms")
    for k in RATE + WAIT + CXL + HCPU + FIG8:
        o[k] = mean(at, k)
    has_mg = any(any(r["_has"].values()) for r in at)
    has_pop = any(r["_has_pop"] for r in at)
    src = []
    if has_pop:
        src.append("swmc")
    if has_mg:
        src.append("megalon")
    o["counter_source"] = "+".join(src) or "none"
    popz = list(POPC) + ["coherence_events"]
    mgz = list(MG) + ["mg_flush_writeend"]
    zero = {"hw": popz + mgz, "pop": mgz, "mg": popz, "mgoff": popz}[system]
    for k in zero:
        if o.get(k) is None and at:
            o[k] = 0.0
    # lowest measured ramp step (verifier L3): the hatched bars of Figs 5 and 7 for a search without a confirmed max
    ramp = [r for r in agg if r["phase"] == "ramp" and fl(r.get("offered_x")) is not None]
    lo = min(ramp, key=lambda r: (fl(r["offered_x"]), r["step"])) if ramp else {}
    lops = (lo.get("search_s") or 0) + (lo.get("update_s") or 0)
    mf = 0.0 if system in ("hw", "pop") and lo else lo.get("mg_fetch")
    o.update(lowest_ramp_step=lo.get("step"), lowest_ramp_offered_x=fl(lo.get("offered_x")),
             lowest_ramp_search_s=lo.get("search_s"), lowest_ramp_p99_ms=fl(lo.get("p99_ms")),
             lowest_ramp_mg_fetch_per_op=mf / lops if mf is not None and lops else None)
    ops = (o["at_result_search_s"] or 0) + (o["at_result_update_s"] or 0)
    for k in PER_OP:
        o[k + "_per_op"] = o[k] / ops if o.get(k) is not None and ops else None
    for k, b in (("cxl_rd_B_per_op", "cxl_rd_MBs"), ("cxl_wr_B_per_op", "cxl_wr_MBs")):
        o[k] = o[b] * 1e6 / ops if o.get(b) is not None and ops else None
    return o


FIG8_CSV = ["variant", "nodes", "mix", "u", "offered_x", "n_set", "hw_step", "pop_step", "hw_search_s", "pop_search_s", "hw_p99_ms",
            "pop_p99_ms", "hw_W_ns", "pop_W_ns", "pop_inval_ipi_ns", "pop_owner_wait_ns", "pop_other_fault_ns",
            "pop_query_ns", "fig8_norm_hw", "fig8_norm_pop", "fig8_norm_inval_ipi", "fig8_norm_owner_wait",
            "fig8_norm_other_fault", "fig8_norm_query", "pop_W_minus_sections_rel", "n_common_pass_steps", "run",
            "config_sha256"]


def fig8_rows(steps):
    """Fig 8 load points; two variants (verifier L1, 2026-10-22):
      per_n     per (nodes, mix): the highest ramp offered rate that both hw and pop pass at that N (user Q1)
      common_n  per mix: the highest ramp offered rate that both hw and pop pass at EVERY N present (one load for the
                whole N group of the mix: the adaptive ramp step makes per-N rates differ); n_set = the N group
    values of those two steps, normalized to hw's W (fig8_norm_*); offered_x = the load of the row's group"""
    yes = lambda v: str(v) == "True"  # noqa: E731  (bool in an export, text after --combine)
    key = lambda r: round(fl(r["offered_x"]), 6)  # noqa: E731
    ps = {}
    for r in steps:
        if r["system"] in ("hw", "pop") and r["phase"] == "ramp" and yes(r["pass"]) and str(r.get("valid")) != "False" \
                and fl(r.get("srch_wall_ns_per_search")) is not None:
            ps.setdefault((int(r["nodes"]), r["mix"], r["system"]), {}).setdefault(key(r), r)
    keys = sorted({(int(r["nodes"]), r["mix"]) for r in steps}, key=lambda k: (k[0], int(k[1][1:])))
    common = {k: set(ps.get(k + ("hw",), {})) & set(ps.get(k + ("pop",), {})) for k in keys}
    out = []
    for nodes, mix in keys:
        if common[(nodes, mix)]:
            x = max(common[(nodes, mix)])
            out.append(_fig8_row("per_n", str(nodes), nodes, mix, ps[(nodes, mix, "hw")][x], ps[(nodes, mix, "pop")][x],
                                 len(common[(nodes, mix)])))
    for mix in sorted({m for _, m in keys}, key=lambda m: int(m[1:])):
        ns = sorted(n for n, m in keys if m == mix)
        allc = set.intersection(*(common[(n, mix)] for n in ns))
        if not allc:
            continue
        x = max(allc)
        for n in ns:
            out.append(_fig8_row("common_n", "/".join(map(str, ns)), n, mix, ps[(n, mix, "hw")][x],
                                 ps[(n, mix, "pop")][x], len(allc)))
    return out


def _fig8_row(variant, nset, nodes, mix, h, p, ncommon):
    """one fig8.csv row from the hw step h and the pop step p at the same offered rate"""
    hw_w, pw = fl(h["srch_wall_ns_per_search"]), fl(p["srch_wall_ns_per_search"])
    seg = {k: fl(p.get(f"fig8_{k}_ns_per_search")) for k in ("inval_ipi", "owner_wait", "other_fault", "query")}
    o = dict(variant=variant, n_set=nset, nodes=nodes, mix=mix, u=int(mix[1:]), offered_x=fl(h["offered_x"]),
             hw_step=h["step"], pop_step=p["step"], hw_search_s=h.get("search_s"), pop_search_s=p.get("search_s"),
             hw_p99_ms=h.get("p99_ms"), pop_p99_ms=p.get("p99_ms"), hw_W_ns=hw_w, pop_W_ns=pw,
             n_common_pass_steps=ncommon, run=h.get("run"), config_sha256=h.get("config_sha256"),
             fig8_norm_hw=1.0 if hw_w else None, fig8_norm_pop=pw / hw_w if pw is not None and hw_w else None)
    for k, v in seg.items():
        o[f"pop_{k}_ns"] = v
        o[f"fig8_norm_{k}"] = v / hw_w if v is not None and hw_w else None
    t = fl(p.get("srch_sections_t_ns_per_search"))
    o["pop_W_minus_sections_rel"] = (pw - t) / pw if pw and t is not None else None
    return o


def write(path, cols, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([canon.fmt(r.get(c)) for c in cols])


def combine(out, dirs):
    os.makedirs(out, exist_ok=True)
    n = {}
    for name in ("summary.csv", "steps.csv"):
        rows, cols = [], None
        for d in dirs:
            p = os.path.join(d, name)
            with open(p) as f:
                r = csv.DictReader(f)
                if cols is None:
                    cols = r.fieldnames
                elif r.fieldnames != cols:
                    raise SystemExit(f"{p}: columns differ from {dirs[0]}")
                rows += list(r)
        rows.sort(key=lambda r: (int(r["nodes"]), int(r["u"]) if r.get("u") else 0, r["system"]))
        with open(os.path.join(out, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
        n[name] = len(rows)
        if name == "steps.csv" and "srch_wall_ns_per_search" in cols:
            f8 = fig8_rows(rows)
            write(os.path.join(out, "fig8.csv"), FIG8_CSV, f8)
            n["fig8.csv"] = len(f8)
    print("COMBINE H2N: " + " ".join(f"{k}={v}" for k, v in n.items()) + f" -> {out}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int)
    ap.add_argument("--nodes", type=int)
    ap.add_argument("--config-sha256", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", choices=["h2n", "2vm"], default="h2n")
    ap.add_argument("--cxlbw", help="sampler dir (default <block>/cxlbw of each lifetime's block dir)")
    ap.add_argument("--hostcpu", help="host-cpu-sampler.py dir (default <block>/hostcpu of each lifetime's block dir)")
    ap.add_argument("--combine", action="store_true")
    ap.add_argument("evidence", nargs="+")
    a = ap.parse_args(argv)
    if a.combine:
        return combine(a.out, a.evidence)
    if a.run is None or a.nodes is None:
        sys.exit("--run and --nodes are required")
    lts = (lifetimes_h2n if a.source == "h2n" else lifetimes_2vm)(a.evidence, a.nodes)
    if not lts:
        sys.exit(f"no SLO lifetimes in {a.evidence}")
    os.makedirs(a.out, exist_ok=True)
    vcpu = 16 if a.source == "2vm" else 4
    key = dict(nodes=a.nodes, run=a.run, config_sha256=a.config_sha256)
    steps, steps_vm, summ, warn = [], [], [], []
    hcache = {}
    for (mix, s), (life, part, E) in sorted(lts.items(), key=lambda x: (int(x[0][0][1:]), x[0][1])):
        if s not in SYS:
            raise SystemExit(f"unknown system {s} ({life})")
        u = int(mix[1:])
        sampler = a.cxlbw or (os.path.join(E, "cxlbw") if a.source == "h2n" else None)
        if a.source == "h2n" and not os.path.isfile(os.path.join(sampler, "perf.csv")):
            warn.append(f"{life}: no CXL.mem sampler data ({sampler}/perf.csv): cxl columns empty")
        hdir = a.hostcpu or (os.path.join(E, "hostcpu") if a.source == "h2n" else None)
        if hdir not in hcache:
            hcache[hdir] = hostcpu_load(hdir)
        if a.source == "h2n" and hcache[hdir] is None:
            warn.append(f"{life}: no Host CPU sampler data ({hdir}/samples.csv): host CPU columns empty")
        agg, per_vm, sm = lifetime_rows(part, a.nodes, sampler, hcache[hdir])
        idd = dict(key, mix=mix, system=s, u=u, lifetime=life)
        rows = [dict(r, **idd) for r in agg]
        steps += rows
        write(os.path.join(a.out, f"steps-n{a.nodes}-{mix}-{s}.csv"), STEP, rows)
        steps_vm += [dict(r, **idd) for r in per_vm]
        sr = summary_row(s, agg, sm, u)
        summ.append(dict(sr, **idd, vcpus_per_vm=vcpu, threads=f"{vcpu - 1}+1", source_dir=part))
        if sm.get("confirmed") is not True:
            warn.append(f"{life}: no confirmed result (note: {sm.get('note', '')})")
        if s == "pop" and sr.get("tx_wait_ns_per_op") is None:
            warn.append(f"{life}: tx_*.wait histograms empty (instr detail=0): tx_wait_ns_per_op empty, "
                        "msg_wait_ns_per_round is the always-on request wait")
    write(os.path.join(a.out, "steps.csv"), STEP, steps)
    write(os.path.join(a.out, "steps-vm.csv"), STEP_VM, steps_vm)
    write(os.path.join(a.out, "summary.csv"), SUMMARY, summ)
    write(os.path.join(a.out, "fig8.csv"), FIG8_CSV, fig8_rows(steps))
    for x in warn:
        print("WARN " + x)
    print(f"EXPORT H2N N={a.nodes} run {a.run}: lifetimes={len(summ)} steps={len(steps)} steps_vm={len(steps_vm)} -> {a.out}")


if __name__ == "__main__":
    main()

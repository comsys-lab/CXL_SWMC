#!/usr/bin/env python3
"""New H2 (vector DB VM-count scaling) canonical CSVs. Host only, offline, read only on the evidence.

One aggregate SLO search per (N, mix, system) (h2n-block.sh); the figures read the latency-throughput steps of each
(N, mix, system), the max under the SLO (bar chart, scaling plot) and the coherence counters at that point.

usage: export_h2n.py --run K --nodes N --config-sha256 S --out DIR [--source h2n|2vm] [--cxlbw DIR] EVIDENCE [EVIDENCE..]
       export_h2n.py --combine --out DIR EXPORT_DIR [EXPORT_DIR..]   (concatenate per-N exports: summary.csv, steps.csv)
  --source h2n  EVIDENCE = h2n block dirs (<E>/block of runset-h2n.sh: h2n-results.tsv, <sys>-<mix>-n<N>/slo, cxlbw/).
                Several dirs of one N (a resumed N: the stopped block's dir, then the resumed one): a later dir wins per
                (mix, system). The CXL.mem sampler dir is <block>/cxlbw unless --cxlbw is given.
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
summary.csv columns (first ten = the figure contract): nodes, mix, system, max_under_slo_search_s (loadgen confirm
  x_mean = achieved searches/s over the confirm repeats, aggregate over the N VMs; empty if not confirmed),
  faults_read, faults_write (Popcorn coherence page faults per s, sys.swmc.page_coherence.fault_{read,write}_count
  summed over the N VMs), mg_fetch (Megalon object refetches per s: megalon.read_retry_incoherent = a reader found its
  copy stale, flushed it and re-read the object from CXL memory), mg_inval (Megalon object flushes per s:
  megalon.flushes = stale-copy invalidations by readers + write-end flushes by writers), cxl_rd_MBs, cxl_wr_MBs
  (Host CXL.mem MB/s, cxl-bw-sampler.sh, Intel PCM rule; perf intervals fully inside the step's guest wall window);
  then *_per_op variants (per achieved op = search + update), raw Megalon counters per s, confirm stats, validity.
  A coherence column of a system without that mechanism is 0 when its counter is absent (hw: all, pop: mg_*,
  mg: faults_*); counter_source names what was read.
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

MG = {"mg_fetch": "megalon.read_retry_incoherent", "mg_inval": "megalon.flushes",
      "mg_read_sections": "megalon.read_sections", "mg_write_sections": "megalon.write_sections",
      "mg_retry_notify": "megalon.read_retry_notify", "mg_replay_flushes": "megalon.replay_flushes",
      "mg_flush_bytes": "megalon.flush_bytes"}
POPC = {"faults_read": "read_faults", "faults_write": "write_faults", "is_faults": "is_faults",
        "inv_commits": "inv_commits", "fetch_commits": "fetch_commits", "coh_ipis": "coh_ipis"}
RATE = list(POPC) + list(MG)
SUMMARY_HEAD = ["nodes", "mix", "system", "max_under_slo_search_s", "faults_read", "faults_write", "mg_fetch",
                "mg_inval", "cxl_rd_MBs", "cxl_wr_MBs"]
SUMMARY = SUMMARY_HEAD + ["faults_read_per_op", "faults_write_per_op", "mg_fetch_per_op", "mg_inval_per_op",
                          "cxl_rd_B_per_op", "cxl_wr_B_per_op", "is_faults", "inv_commits", "fetch_commits",
                          "coh_ipis", "mg_read_sections", "mg_write_sections", "mg_retry_notify", "mg_replay_flushes",
                          "mg_flush_bytes", "result_offered_x", "result_offered_search_s", "confirm_x_sd",
                          "confirmed", "note", "n_at_result", "valid_at_result", "at_result_search_s",
                          "at_result_update_s", "at_result_p99_ms", "cxl_n_intervals", "counter_source",
                          "vcpus_per_vm", "threads", "u", "run", "config_sha256", "lifetime", "source_dir"]
STEP = ["nodes", "mix", "system", "u", "step", "phase", "offered_x", "search_s", "update_s", "p50_ms", "p95_ms",
        "p99_ms", "pass", "at_result", "valid", "window_s"] + RATE + ["cxl_rd_MBs", "cxl_wr_MBs", "cxl_n_intervals",
                                                                      "run", "config_sha256", "lifetime"]
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


def lifetime_rows(part, nodes, sampler):
    rows3, sm = X3.part_rows(part, "vdb", nodes)
    cs = X3.step_counters(part)
    cx = cxl_steps(sampler, part)
    steps = {d["step"]: d for d in canon.measured_steps(part)}
    agg, per_vm = [], []
    for r in rows3:
        n = r["step"]
        rs = cs.get(n, [])
        win = fl(r.get("window_s"))
        if r["vm"] == "all":
            d = steps[n]["streams"]
            o = dict(step=n, phase=r["phase"], offered_x=r["offered_x"], search_s=fl(r.get("achieved_x")),
                     update_s=fl(r.get("wop_per_s")), p50_ms=r.get("p50_ms"), p95_ms=r.get("p95_ms"),
                     p99_ms=r.get("p99_ms"), at_result=r["at_result"], valid=r.get("valid"), window_s=win)
            o["pass"] = r.get("pass")
            for k, src in POPC.items():
                o[k] = r.get(src + "_per_s")
            for k, key in MG.items():
                t = sum_key(rs, key)
                o[k] = t / win if t is not None and win else None
            c = cx.get(n)
            o.update(cxl_rd_MBs=c[0] if c else None, cxl_wr_MBs=c[1] if c else None, cxl_n_intervals=c[2] if c else None)
            o["_has"] = {k: (any(rr.get(key) not in (None, "") for rr in rs)) for k, key in MG.items()}
            o["_has_pop"] = any(rr.get("sys.swmc.page_coherence.fault_read_count") not in (None, "") for rr in rs)
            del d
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
    for k in RATE + ["cxl_rd_MBs", "cxl_wr_MBs", "cxl_n_intervals"]:
        o[k] = mean(at, k)
    has_mg = any(any(r["_has"].values()) for r in at)
    has_pop = any(r["_has_pop"] for r in at)
    src = []
    if has_pop:
        src.append("swmc")
    if has_mg:
        src.append("megalon")
    o["counter_source"] = "+".join(src) or "none"
    zero = {"hw": list(POPC) + list(MG), "pop": list(MG), "mg": list(POPC), "mgoff": list(POPC)}[system]
    for k in zero:
        if o.get(k) is None and at:
            o[k] = 0.0
    ops = (o["at_result_search_s"] or 0) + (o["at_result_update_s"] or 0)
    for k in ("faults_read", "faults_write", "mg_fetch", "mg_inval"):
        o[k + "_per_op"] = o[k] / ops if o.get(k) is not None and ops else None
    for k, b in (("cxl_rd_B_per_op", "cxl_rd_MBs"), ("cxl_wr_B_per_op", "cxl_wr_MBs")):
        o[k] = o[b] * 1e6 / ops if o.get(b) is not None and ops else None
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
    print(f"COMBINE H2N: " + " ".join(f"{k}={v}" for k, v in n.items()) + f" -> {out}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int)
    ap.add_argument("--nodes", type=int)
    ap.add_argument("--config-sha256", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", choices=["h2n", "2vm"], default="h2n")
    ap.add_argument("--cxlbw", help="sampler dir (default <block>/cxlbw of each lifetime's block dir)")
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
    for (mix, s), (life, part, E) in sorted(lts.items(), key=lambda x: (int(x[0][0][1:]), x[0][1])):
        if s not in SYS:
            raise SystemExit(f"unknown system {s} ({life})")
        u = int(mix[1:])
        sampler = a.cxlbw or (os.path.join(E, "cxlbw") if a.source == "h2n" else None)
        if a.source == "h2n" and not os.path.isfile(os.path.join(sampler, "perf.csv")):
            warn.append(f"{life}: no CXL.mem sampler data ({sampler}/perf.csv): cxl columns empty")
        agg, per_vm, sm = lifetime_rows(part, a.nodes, sampler)
        idd = dict(key, mix=mix, system=s, u=u, lifetime=life)
        rows = [dict(r, **idd) for r in agg]
        steps += rows
        write(os.path.join(a.out, f"steps-n{a.nodes}-{mix}-{s}.csv"), STEP, rows)
        steps_vm += [dict(r, **idd) for r in per_vm]
        sr = summary_row(s, agg, sm, u)
        summ.append(dict(sr, **idd, vcpus_per_vm=vcpu, threads=f"{vcpu - 1}+1", source_dir=part))
        if sm.get("confirmed") is not True:
            warn.append(f"{life}: no confirmed result (note: {sm.get('note', '')})")
    write(os.path.join(a.out, "steps.csv"), STEP, steps)
    write(os.path.join(a.out, "steps-vm.csv"), STEP_VM, steps_vm)
    write(os.path.join(a.out, "summary.csv"), SUMMARY, summ)
    for x in warn:
        print("WARN " + x)
    print(f"EXPORT H2N N={a.nodes} run {a.run}: lifetimes={len(summ)} steps={len(steps)} steps_vm={len(steps_vm)} -> {a.out}")


if __name__ == "__main__":
    main()

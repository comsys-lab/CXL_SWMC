#!/usr/bin/env python3
"""H3 canonical CSVs (user H3 design 2026-10-20, second revision; evaluation-pipeline rev 3 §2.3, §4.2). Host only,
offline, read-only on the evidence.

One aggregate SLO search per (workload, N, system); the figure reads the faults at the max-under-SLO point of each N
and the latency curve of each N. Sources:
  --source h3   an H3 block evidence dir (runset-h3-{vdb,rs}.sh, N = 4 / 8): <E>/<sys>-n<N>/slo, <E>/cdf/
  --source 2vm  the N = 2 point = the 2-VM run set of the same run k at the H3 operating point (--point):
                vector DB <E>/vdb/r<n>/run/<sys>-<point>-slo-r<n>/slo (run set vdb, round 1 or k), RecSys
                <E>/block/<sys>-u<point>/slo (run set rs-main); same sizing (16 vCPU / 96 GB), threads, SLO rules
Outputs (in --out):
  hslo.csv          one row per (system, nodes, measured SLO step, vm): vm = "all" (aggregate over the N VMs: latency
                    curve of the read stream + fault counters summed) or "0".."N-1" (that VM's counters; latency
                    columns empty: loadgen measures the aggregate stream). at_result = the step is a confirm repeat at
                    the result rate (canon.confirm_stats), so the fault figure reads at_result rows.
  hosts-at-max.csv  one row per (system, nodes, vm): mean of the at_result steps of every rate column (the faults at
                    the max under the SLO), + result_x and confirm stats
  cdf.csv           per-page I->S read-fault CDF of the CDF pass (h3-page-cdf.py rule; dropped > 0 = incomplete;
                    pfn_mod > 1 = pages sampled by pfn % pfn_mod == 0; offered_x = the CDF rate)
  Every row: valid / wop_done_ratio = the step's update-stream validity from the part's kept check file (vector DB
  urate-check.csv valid / done_ratio, RecSys stream-check.csv valid / written_ratio; empty when absent), check = its
  verdict (URATECHECK / STREAMCHECK PASS|NOTE|FAIL); hosts-at-max valid_at_result = every at_result step valid;
  source_config_sha256 = the config_sha256 in the measuring run set's eval-manifest.txt (N = 2 rows: the 2-VM run set's
  hash, which differs from config_sha256 = the H3 hash of this export).
Counter formulas: experiments/rocksdb/h3-faults.py KEYS / PREFIX_SUMS (loaded from that file: one source), summed
over the targets of a step (vm = all) or per target; *_per_s = delta / window_s (aggregate: max window of the
targets, as h3-faults.py); *_per_rop = delta / (achieved read ops/s x window_s) (aggregate only); cxl_recv_cpu_s_per_s
= cxl_recv run time (s) / window_s. Normalisations (to N = 2, to all-HWcc) are the plot's.
usage: export_h3.py --run K --runset h3-<vdb|rs>-n<N> --config-sha256 S --out DIR [--source h3|2vm] [--point P]
                    [--round n] EVIDENCE_DIR
"""
import argparse
import collections
import csv
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import canon  # noqa: E402

_spec = importlib.util.spec_from_file_location("h3faults", os.path.join(HERE, "..", "rocksdb", "h3-faults.py"))
H3F = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H3F)
COUNTERS = list(H3F.KEYS) + list(H3F.PREFIX_SUMS)
KEY = ["workload", "run", "config_sha256"]
ID = ["system", "nodes", "vcpus_per_vm", "threads", "point", "rate_unit", "slo_pct", "slo_ms"]
RATES = [c + "_per_s" for c in COUNTERS] + ["cxl_recv_cpu_s_per_s"]
PER_ROP = ["read_faults_per_rop", "write_faults_per_rop", "is_faults_per_rop", "thr_is_fault_ns_per_rop"]
SCHEMA = {
    "hslo.csv": KEY + ID + ["step", "phase", "vm", "offered_x", "achieved_x", "n_rop", "p50_ms", "p95_ms", "p99_ms",
                            "pslo_ms", "pass", "valid", "wop_done_ratio", "at_result", "result_x", "window_s",
                            "wop_per_s", "instr_enabled"]
    + RATES + PER_ROP + ["check", "lifetime", "source_config_sha256", "source_dir"],
    "hosts-at-max.csv": KEY + ID + ["vm", "result_x", "confirm_x_mean", "confirm_x_sd", "confirmed", "note",
                                    "n_at_result", "valid_at_result", "offered_x", "achieved_x", "p95_ms", "p99_ms"]
    + RATES + PER_ROP + ["check", "lifetime", "source_config_sha256", "source_dir"],
    "cdf.csv": KEY + ["system", "nodes", "faults_per_page", "pages", "cum_pages_frac", "cum_faults_frac",
                      "pages_total", "faults_total", "dropped", "complete", "pfn_mod", "offered_x",
                      "source_config_sha256", "source_dir"],
}
WL = {"vdb": dict(rop="search", wop="update", slo_pct=99, rate_unit="mix"),
      "recsys": dict(rop="query", wop="update", slo_pct=95, rate_unit="samples/s")}
SYSNAME = {"hw": "hw", "pop": "pop", "all-HWcc": "hw"}


def fl(v):
    return canon.fl(v)


def step_counters(part):
    """{step: [per-target dict]} from <part>/stats-steps.csv (stats_delta.py: one row per step and target)"""
    p = os.path.join(part, "stats-steps.csv")
    out = collections.defaultdict(list)
    if not os.path.isfile(p):
        return out
    for r in csv.DictReader(open(p)):
        out[int(r["step"])].append(r)
    for rs in out.values():
        rs.sort(key=lambda r: int(r.get("target") or 0))
    return out


def counters(rows):
    """sum of every counter over the given target rows (None when no row has it)"""
    o = {}
    for name, keys in H3F.KEYS.items():
        tot = None
        for r in rows:
            v = next((r[k] for k in keys if r.get(k) not in (None, "")), None)
            if v is not None:
                tot = (tot or 0) + float(v)
        o[name] = tot
    for name, (pre, suf) in H3F.PREFIX_SUMS.items():
        tot = None
        for r in rows:
            for k, v in r.items():
                if k.startswith(pre) and k.endswith(suf) and v not in (None, ""):
                    tot = (tot or 0) + float(v)
        o[name] = tot
    en = [r.get("sys.swmc.instr.enabled") for r in rows]
    o["instr_enabled"] = (all(e not in (None, "") and float(e) == 1 for e in en) if any(e not in (None, "") for e in en)
                          else None)
    return o


def rates(c, win, achieved):
    o = {}
    for k in COUNTERS:
        o[k + "_per_s"] = c[k] / win if c.get(k) is not None and win else None
    o["cxl_recv_cpu_s_per_s"] = (c["cxl_recv_run_ns"] / 1e9 / win if c.get("cxl_recv_run_ns") is not None and win
                                 else None)
    req = achieved * win if achieved and win else None
    for k in ("read_faults", "write_faults", "is_faults", "thr_is_fault_ns"):
        o[k + "_per_rop"] = c[k] / req if c.get(k) is not None and req else None
    return o


def validity(part):
    """verifier L3: per-step update-stream validity from the kept check files of the part (vector DB urate_check.py:
    urate-check.csv valid / done_ratio; RecSys stream_check.py: stream-check.csv valid / written_ratio) and the
    verdict line (URATECHECK / STREAMCHECK ...); ({step: (valid, ratio)}, verdict) or ({}, "") when absent"""
    for csvn, ratio, txt, tag in (("urate-check.csv", "done_ratio", "urate-check.txt", "URATECHECK"),
                                  ("stream-check.csv", "written_ratio", "stream-check.txt", "STREAMCHECK")):
        p = os.path.join(part, csvn)
        if not os.path.isfile(p):
            continue
        with open(p) as f:
            v = {int(r["step"]): (r.get("valid") == "True" if r.get("valid") in ("True", "False") else None, fl(r.get(ratio)))
                 for r in csv.DictReader(f)}
        verdict = ""
        if os.path.isfile(os.path.join(part, txt)):
            with open(os.path.join(part, txt)) as f:
                verdict = next((" ".join(ln.split()[:2]) for ln in f if ln.startswith(tag)), "")
        return v, verdict
    return {}, ""


def part_rows(part, wl, nodes, stream=None):
    """rows of hslo.csv (without KEY / ID) for one SLO part dir; stream = the read stream name"""
    stream = stream or WL[wl]["rop"]
    steps = canon.measured_steps(part)
    best, at, _, _ = canon.confirm_stats(part, stream) if os.path.isfile(os.path.join(part, "loadgen", "summary.json")) \
        else (None, set(), None, None)
    sm = canon.summary(part) if os.path.isfile(os.path.join(part, "loadgen", "summary.json")) else {}
    result_x = fl((sm.get("confirm") or {}).get("x_mean")) if sm.get("confirmed") is True else None
    cs = step_counters(part)
    val, verdict = validity(part)
    out = []
    for d in steps:
        n = d["step"]
        rs = cs.get(n, [])
        if rs and len(rs) != nodes:
            raise SystemExit(f"{part} step {n}: {len(rs)} targets in stats-steps.csv != nodes {nodes}")
        st = d["streams"].get(stream, {})
        ach = fl(st.get("achieved"))
        win = max((fl(r.get("window_s")) or 0) for r in rs) if rs else None
        wop = d["streams"].get(WL[wl]["wop"], {}) if wl in WL else {}
        vv = val.get(n, (None, None))
        base = dict(step=n, phase=d.get("phase"), offered_x=d.get("offered_x"), at_result=n in at, result_x=result_x,
                    valid=vv[0], wop_done_ratio=vv[1], check=verdict)
        c = counters(rs)
        out.append(dict(base, vm="all", achieved_x=ach, n_rop=st.get("done"), p50_ms=st.get("p50_ms"),
                        p95_ms=st.get("p95_ms"), p99_ms=st.get("p99_ms"), pslo_ms=st.get("pslo_ms"),
                        **{"pass": d.get("pass")}, window_s=win, wop_per_s=fl(wop.get("achieved")),
                        instr_enabled=c["instr_enabled"], **rates(c, win, ach)))
        for k, r in enumerate(rs):
            ck = counters([r])
            rk = rates(ck, fl(r.get("window_s")), None)
            out.append(dict(base, vm=str(k), window_s=fl(r.get("window_s")), instr_enabled=ck["instr_enabled"],
                            **{x: y for x, y in rk.items() if not x.endswith("_per_rop")}))
    return out, sm


def at_max(rows):
    """hosts-at-max rows: mean of every rate over the at_result rows, per vm"""
    out = []
    for vm in sorted({r["vm"] for r in rows}, key=lambda v: (v != "all", int(v) if v.isdigit() else -1)):
        rs = [r for r in rows if r["vm"] == vm and r["at_result"]]
        vs = [r.get("valid") for r in rs]
        o = dict(vm=vm, n_at_result=len(rs), check=rs[0].get("check") if rs else None,
                 valid_at_result=(all(vs) if vs and all(x is not None for x in vs) else None))
        for k in ["offered_x", "achieved_x", "p95_ms", "p99_ms"] + RATES + PER_ROP:
            v = [fl(r.get(k)) for r in rs if fl(r.get(k)) is not None]
            o[k] = sum(v) / len(v) if v else None
        out.append(o)
    return out


def cdf_rows(cdir):
    """h3-page-cdf.py rule over <cdir>/hist-vm*.txt -> (rows, totals)"""
    line = re.compile(r"\{\s*pfn:\s*(\d+)\s*\}\s*hitcount:\s*(\d+)")
    drop = re.compile(r"Dropped:\s*(\d+)")
    per_page, dropped = [], 0
    for fn in sorted(os.listdir(cdir)):
        if not re.fullmatch(r"hist-vm\d+\.txt", fn):
            continue
        for ln in open(os.path.join(cdir, fn), errors="replace"):
            m = line.search(ln)
            if m:
                per_page.append(int(m.group(2)))
            d = drop.search(ln)
            if d:
                dropped += int(d.group(1))
    if not per_page:
        return [], None
    h = collections.Counter(per_page)
    pages, faults = len(per_page), sum(per_page)
    rows, cp, cf = [], 0, 0
    for k in sorted(h):
        cp += h[k]
        cf += k * h[k]
        rows.append(dict(faults_per_page=k, pages=h[k], cum_pages_frac=cp / pages, cum_faults_frac=cf / faults))
    return rows, dict(pages_total=pages, faults_total=faults, dropped=dropped, complete=dropped == 0)


class W:
    def __init__(self, key):
        self.key, self.rows = key, {k: [] for k in SCHEMA}

    def add(self, name, **kw):
        bad = set(kw) - set(SCHEMA[name])
        if bad:
            raise KeyError(f"{name}: unknown columns {sorted(bad)}")
        self.rows[name].append(dict(self.key, **kw))

    def write(self, outdir):
        os.makedirs(outdir, exist_ok=True)
        for name, cols in SCHEMA.items():
            with open(os.path.join(outdir, name), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(cols)
                for r in self.rows[name]:
                    w.writerow([canon.fmt(r.get(c)) for c in cols])
        return {k: len(v) for k, v in self.rows.items()}


def lifetimes(E, source, wl, nodes, point, rnd):
    """[(system, lifetime name, part dir)]"""
    if source == "h3":
        out = []
        p = os.path.join(E, "h3-results.tsv")
        for ln in open(p):
            f = ln.rstrip("\n").split("\t")
            if ln.startswith("#") or len(f) < 9:
                continue
            if int(f[2]) != nodes:
                raise SystemExit(f"{p}: row nodes {f[2]} != runset N {nodes}")
            out.append((f[1], f[0], os.path.join(E, f[8])))
        return out
    if wl == "vdb":
        base = os.path.join(E, "vdb", f"r{rnd}", "run")
        return [(s, f"{s}-{point}-slo-r{rnd}", os.path.join(base, f"{s}-{point}-slo-r{rnd}", "slo")) for s in ("hw", "pop")
                if os.path.isdir(os.path.join(base, f"{s}-{point}-slo-r{rnd}", "slo"))]
    base = os.path.join(E, "block")
    return [(s, f"{s}-u{point}", os.path.join(base, f"{s}-u{point}", "slo")) for s in ("hw", "pop")
            if os.path.isdir(os.path.join(base, f"{s}-u{point}", "slo"))]


def source_sha(E):
    """config_sha256 recorded by the run-set driver (eval-manifest.txt in E or its parent: H3 E/block, 2-VM E)"""
    for d in (E, os.path.dirname(os.path.abspath(E))):
        p = os.path.join(d, "eval-manifest.txt")
        if os.path.isfile(p):
            with open(p) as f:
                mm = re.search(r"config_sha256=([0-9a-f]{64})", f.read())
            if mm:
                return mm.group(1)
    return ""


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--runset", required=True)
    ap.add_argument("--config-sha256", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source", choices=["h3", "2vm"], default="h3")
    ap.add_argument("--point", help="operating point (vdb mix u50 / recsys samples/s); default from h3-params or required for 2vm")
    ap.add_argument("--round", type=int, default=1, help="2vm vdb: round dir r<n> (r1 in run 1; cont runs: n = k)")
    ap.add_argument("--total-vcpu", type=int, default=32)
    ap.add_argument("evidence")
    a = ap.parse_args(argv)
    m = re.fullmatch(r"h3-(vdb|rs)-n([2-8])", a.runset)
    if not m:
        sys.exit("runset must be h3-vdb-n<N> or h3-rs-n<N>")
    wl = "vdb" if m.group(1) == "vdb" else "recsys"
    nodes = int(m.group(2))
    vcpu = a.total_vcpu // nodes
    point = a.point
    if a.source == "h3" and not point:
        pp = open(os.path.join(a.evidence, "h3-params.txt")).read()
        mm = re.search(r"U=(\d+)", pp) if wl == "vdb" else re.search(r"rate=(\d+) samples/s", pp)
        point = (f"u{mm.group(1)}" if wl == "vdb" else mm.group(1)) if mm else None
    if a.source == "2vm" and (not point or nodes != 2):
        sys.exit("--source 2vm needs --point and runset N = 2")
    threads = f"{vcpu - 1}+1" if wl == "vdb" else f"{vcpu}/{vcpu}"
    w = W({"workload": wl, "run": a.run, "config_sha256": a.config_sha256})
    idd = dict(nodes=nodes, vcpus_per_vm=vcpu, threads=threads, point=point, rate_unit=WL[wl]["rate_unit"],
               slo_pct=WL[wl]["slo_pct"], slo_ms=100)
    lts = lifetimes(a.evidence, a.source, wl, nodes, point, a.round)
    if not lts:
        sys.exit(f"no SLO lifetimes in {a.evidence}")
    warn = []
    src_sha = source_sha(a.evidence)  # verifier L4: config_sha256 of the run set that measured the rows
    if a.source == "2vm" and not src_sha:
        warn.append("no eval-manifest.txt config_sha256 for the 2-VM evidence (source_config_sha256 empty)")
    for sysname, life, part in lts:
        rows, sm = part_rows(part, wl, nodes)
        if sysname == "pop" and any(r["instr_enabled"] is False for r in rows):
            warn.append(f"{life}: sys.swmc.instr.enabled != 1 on some VM/step (Popcorn counters incomplete)")
        for r in rows:
            w.add("hslo.csv", system=SYSNAME.get(sysname, sysname), **idd, **r, lifetime=life,
                  source_config_sha256=src_sha, source_dir=part)
        c = sm.get("confirm") or {}
        for r in at_max(rows):
            w.add("hosts-at-max.csv", system=SYSNAME.get(sysname, sysname), **idd, **r,
                  result_x=fl(c.get("x_mean")) if sm.get("confirmed") is True else None,
                  confirm_x_mean=fl(c.get("x_mean")), confirm_x_sd=fl(c.get("x_sd")), confirmed=sm.get("confirmed"),
                  note=sm.get("note", ""), lifetime=life, source_config_sha256=src_sha, source_dir=part)
    cdir = os.path.join(a.evidence, "cdf")
    if a.source == "h3" and os.path.isdir(cdir):
        rows, tot = cdf_rows(cdir)
        rate = mod = None
        if os.path.isfile(os.path.join(cdir, "cdf-rate.txt")):
            with open(os.path.join(cdir, "cdf-rate.txt")) as f:
                mm = re.search(r"max_offered_x_pass ([0-9.]+)", f.read())
            rate = float(mm.group(1)) if mm else None
        if os.path.isfile(os.path.join(cdir, "cdf-setup.txt")):
            with open(os.path.join(cdir, "cdf-setup.txt")) as f:
                mm = re.search(r"pfn_mod=(\d+)", f.read())
            mod = int(mm.group(1)) if mm else None
        for r in rows:
            w.add("cdf.csv", system="pop", nodes=nodes, **r, **tot, pfn_mod=mod, offered_x=rate,
                  source_config_sha256=src_sha, source_dir=cdir)
        if tot and not tot["complete"]:
            warn.append(f"cdf: Dropped = {tot['dropped']} (hist map full; incomplete CDF)")
    n = w.write(a.out)
    for x in warn:
        print("WARN " + x)
    print(f"EXPORT H3 {wl} N={nodes} run {a.run}: " + " ".join(f"{k}={v}" for k, v in n.items()) + f" -> {a.out}")


if __name__ == "__main__":
    main()

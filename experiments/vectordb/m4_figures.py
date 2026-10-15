#!/usr/bin/env python3
"""M4/M5 VectorDB figure tables (reports/M4-vdb-packet.md §6, reports/M5-pilot-packet.md; MOT1 v5 "Values needed" of
Figures 1a, 1b, the collected background-CPU/traffic values, Figures 2a, 2b, 2c, Table 2). Offline, Host only; reads
run dirs written by m4-run.sh / run.sh. Pilot kinds (pslo, pfix) are treated as slo / fix.
A run whose SLO search ended with a note (e.g. "confirm failed at three rates") is flagged (valid=0 in runs.csv) and
excluded from fig1a/fig2a (excluded_runs counts them).

usage: m4_figures.py --out DIR EVIDENCE_DIR...    (run dirs named <sys>-u<U>-<kind>[-r<R>|-<recv_mode>])
Outputs in DIR:
  runs.csv     one row per run: block, run, system, u, kind, rep, trace, confirm mean/sd of search/s and of p99,
               confirm fails, SLO-search note, load times, E1 counts, sampled recall (if <run>/gt.recall.txt)
  steps-all.csv  every step of every run (experiments/loadgen/export_csv.py; label = <block>/<run>)
  fig1a.csv    U=5 SLO: per system mean and sd over repeats of the confirm mean, mean within-run sd, normalized
  fig2a.csv    same for every U (0/5/20/50)
  fig1b.csv    U=5 fixed load: mean search latency (raw per-request times), per-search stall split per node and
               system (page MSI search threads: message wait, local fault handling = fault - message wait; Megalon:
               section checks, flushes, re-executed work), busy fraction, all-HWcc latency at the same L, and
               coh_ms_per_search_all_threads = coherence time of all request-serving threads (search + writer;
               export_csv coh_stall_s, chosen by the run's system=) per search on that node
  table1.csv   fixed load at U = 5 (H1 point): coherence background CPU (vCPU-s per s) and traffic (bytes/s) per node
  fig2b.csv    fixed load U 20/50: traffic bytes per update (all nodes / updates done). Megalon: megalon.flush_bytes +
               replay_flush_bytes; flush_bytes counts every ObjectStore::Flush (write_end, the incoherent flush in
               ObjectReadStart and the one after a failed ObjectReadEnd: object_store.cc:191, 214, 264), so retry and
               refetch flushes are included. Page MSI: (remote write-back + acquire flush) x 4 KiB
  fig2c.csv    Megalon fixed load with trace: classify_retries counts (retry, refetch, combined) for the window
  table2.csv   Megalon fixed load: failed read sections and refetches per update on the other node, mean time of one
               re-executed attempt, switch_rw (reclaims are not exposed by the shim; switch_rw reported instead)
"""
import argparse, csv, glob, json, os, re, statistics as st, subprocess, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "experiments", "loadgen"))
import export_csv  # noqa: E402
import stats_delta  # noqa: E402

NAME = re.compile(r"^(hw|mg|pop)-u(\d+)-(slo|fix|func|pslo|pfix)(?:-(\w+))?$")
KIND = {"pslo": "slo", "pfix": "fix"}
SYSN = {"hw": "all-HWcc", "mg": "Megalon", "pop": "Popcorn"}


def runs(evid):
    for e in evid:
        for d in sorted(glob.glob(os.path.join(e, "*/"))):
            m = NAME.match(os.path.basename(d.rstrip("/")))
            if m and os.path.exists(os.path.join(d, "loadgen", "summary.json")):
                s, u, kind, tag = m.groups()
                yield dict(block=os.path.basename(e.rstrip("/")), run=os.path.basename(d.rstrip("/")), dir=d.rstrip("/"),
                           system=SYSN[s], u=int(u), kind=KIND.get(kind, kind), rep=tag or "", mode=kind)


def kv(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            k, s, v = line.strip().partition("=")
            if s:
                d[k] = v
    return d


def manifest_trace(d):
    return kv(os.path.join(d, "manifest.txt")).get("trace", "").split()[0] if os.path.exists(os.path.join(d, "manifest.txt")) else ""


def load_times(d):
    out = {}
    p = os.path.join(d, "load-times.txt")
    if not os.path.exists(p):
        return out
    t = open(p).read()
    m = re.search(r"run_wall_s=(\d+)", t)
    out["run_wall_s"] = m.group(1) if m else ""
    m = re.search(r"(?:loaded|published preloaded) \d+ initial records in \d+ segments \(([\d.]+) s\)", t)
    out["load_s"] = m.group(1) if m else ""
    w = re.findall(r"warm-up read \d+ MiB in ([\d.]+) s", t)
    out["warmup_s"] = "/".join(w)
    m = re.search(r"PRELOAD DONE .* in ([\d.]+) s", t)
    out["preload_s"] = m.group(1) if m else ""
    return out


def mean_latency_ms(d, step, stream_idx):
    p = os.path.join(d, "loadgen", f"raw-step{step}.bin")
    if not os.path.exists(p):
        return None
    r = np.fromfile(p, dtype=np.uint64).reshape(-1, 4)
    meas = ((r[:, 3] >> 40) & 1) == 1
    strm = (r[:, 3] >> 32) & 0xff
    ok = meas & (strm == stream_idx) & (r[:, 2] > 0) & ((r[:, 3] & 0xffff) == 0)
    return float(((r[ok, 2] - r[ok, 0]) / 1e6).mean()) if ok.any() else None


def fixed_step(d):
    for line in open(os.path.join(d, "loadgen", "steps.jsonl")):
        s = json.loads(line)
        if s["phase"] == "fixed":
            return s
    return None


def node_rows(d, step):
    """per target: (export_csv.node_metrics, deltas) of one step; the coherence formula follows the run's system="""
    out = {}
    lg = os.path.join(d, "loadgen")
    system = export_csv.run_system(lg)
    for fixed, dv in stats_delta.deltas(lg):
        if fixed["step"] == step:
            out[fixed["target"]] = (export_csv.node_metrics(fixed, dv, system), dv)
    return out


def write(path, cols, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([("" if r.get(c) is None else r.get(c, "")) for c in cols])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("evidence", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    R = list(runs(a.evidence))
    # runs.csv
    rows = []
    for r in R:
        sm = json.load(open(os.path.join(r["dir"], "loadgen", "summary.json")))
        c = sm.get("confirm", {})
        e1 = kv(os.path.join(r["dir"], "e1.e1.txt"))
        gt = kv(os.path.join(r["dir"], "gt.recall.txt"))
        rows.append(dict(r, trace=manifest_trace(r["dir"]), x_mean=c.get("x_mean"), x_sd=c.get("x_sd"),
                         p99_mean_ms=c.get("pslo_mean_ms"), p99_sd_ms=c.get("pslo_sd_ms"), confirm_fails=c.get("fails"),
                         max_offered_pass=sm.get("max_offered_x_pass"), note=sm.get("note"), valid=0 if sm.get("note") else 1,
                         invisible=e1.get("invisible_returned"), duplicates=e1.get("duplicate_ids"),
                         recall_sampled=gt.get("recall_measured_ok"), **load_times(r["dir"])))
    rcols = ["block", "run", "system", "u", "kind", "mode", "rep", "trace", "valid", "x_mean", "x_sd", "p99_mean_ms", "p99_sd_ms",
             "confirm_fails", "max_offered_pass", "note", "run_wall_s", "preload_s", "load_s", "warmup_s",
             "invisible", "duplicates", "recall_sampled"]
    write(os.path.join(a.out, "runs.csv"), rcols, rows)
    if R:
        subprocess.run([sys.executable, os.path.join(ROOT, "experiments", "loadgen", "export_csv.py"), "--out",
                        os.path.join(a.out, "steps-all.csv")] +
                       [f"{r['dir']}/loadgen={r['block']}/{r['run']}" for r in R], check=True, stdout=subprocess.DEVNULL)
    # fig1a / fig2a
    slo = [x for x in rows if x["kind"] == "slo" and x["x_mean"] and x["valid"]]
    excl = [x for x in rows if x["kind"] == "slo" and not x["valid"]]
    agg = []
    for u in sorted({x["u"] for x in slo}):
        base = [x["x_mean"] for x in slo if x["u"] == u and x["system"] == "all-HWcc"]
        bm = st.mean(base) if base else None
        for sys_ in ("all-HWcc", "Popcorn", "Megalon"):
            v = [x for x in slo if x["u"] == u and x["system"] == sys_]
            if not v:
                continue
            m = st.mean(x["x_mean"] for x in v)
            agg.append(dict(u=u, system=sys_, repeats=len(v), excluded_runs=sum(1 for x in excl if x["u"] == u and x["system"] == sys_),
                            search_per_s_mean=m,
                            sd_over_repeats=st.stdev([x["x_mean"] for x in v]) if len(v) > 1 else None,
                            within_run_sd_mean=st.mean(x["x_sd"] or 0 for x in v), normalized=m / bm if bm else None,
                            normalized_sd=(st.stdev([x["x_mean"] for x in v]) / bm if bm and len(v) > 1 else None)))
    acols = ["u", "system", "repeats", "excluded_runs", "search_per_s_mean", "sd_over_repeats", "within_run_sd_mean", "normalized",
             "normalized_sd"]
    write(os.path.join(a.out, "fig2a.csv"), acols, agg)
    write(os.path.join(a.out, "fig1a.csv"), acols, [x for x in agg if x["u"] == 5])
    # fixed-load tables
    f1b, t1, f2b, f2c, t2 = [], [], [], [], []
    hw_lat = {}
    for r in [x for x in R if x["kind"] == "fix"]:
        s = fixed_step(r["dir"])
        if not s:
            continue
        names = list(s["streams"])
        lat = mean_latency_ms(r["dir"], s["step"], names.index("search"))
        if r["system"] == "all-HWcc":
            hw_lat[r["u"]] = lat
        nodes = node_rows(r["dir"], s["step"])
        tot_traffic = tot_upd = 0
        for k, (m, dv) in sorted(nodes.items()):
            n_search = dv.get("searches") or 0
            win = m["window_s"] or 0
            per = lambda v: v / n_search * 1e3 if v is not None and n_search else None  # noqa: E731  ms per search
            msg = m["pop_search_msg_wait_s"]
            row = dict(block=r["block"], run=r["run"], system=r["system"], u=r["u"], node=k, rate=s["offered_x"],
                       search_per_s=s["streams"]["search"]["achieved"], mean_latency_ms=lat,
                       searches=n_search, search_busy_frac=m["search_busy_frac"],
                       pop_msg_wait_ms=per(msg),
                       pop_local_fault_ms=per(m["pop_search_fault_s"] - msg) if m["pop_search_fault_s"] is not None and msg is not None else None,
                       meg_section_checks_ms=per((m["meg_rd_check_s"] or 0) + (m["meg_wr_check_s"] or 0)) if m["meg_rd_check_s"] is not None else None,
                       meg_flush_ms=per(m["meg_flush_s"]), meg_reexec_ms=per(m["meg_reexec_s"]),
                       meg_reexec_src=m["meg_reexec_src"], tlb_ipi=m["tlb_ipi"],
                       coh_ms_per_search_all_threads=per(m["coh_stall_s"]))
            f1b.append(row)
            if r["u"] == 5:  # collected values at the H1 operating point
              t1.append(dict(block=r["block"], run=r["run"], system=r["system"], u=r["u"], node=k, window_s=win,
                           coh_bg_vcpu=m["coh_bg_cpu_s"] / win if m["coh_bg_cpu_s"] is not None and win else None,
                           recv_vcpu=m["recv_cpu_s"] / win if m["recv_cpu_s"] is not None and win else None,
                           lib_bg_vcpu=m["lib_bg_cpu_s"] / win if m["lib_bg_cpu_s"] is not None and win else None,
                           traffic_bytes_per_s=m["traffic_bytes"] / win if m["traffic_bytes"] is not None and win else None,
                           traffic_src=m["traffic_src"]))
            tot_traffic += m["traffic_bytes"] or 0
            tot_upd += dv.get("updates") or 0
            if r["system"] == "Megalon":
                other = [vv for kk, (mm, vv) in nodes.items() if kk != k]
                upd_other = sum(vv.get("updates", 0) for vv in other)
                t2.append(dict(block=r["block"], run=r["run"], u=r["u"], node=k, updates_other_node=upd_other,
                               failed_reads=dv.get("megt.rd_retries"),
                               failed_reads_per_update=dv.get("megt.rd_retries", 0) / upd_other if upd_other else None,
                               incoherent_per_update=dv.get("megalon.read_retry_incoherent", 0) / upd_other if upd_other else None,
                               mean_failed_attempt_us=(dv["megt.rd_failed_ns"] / dv["megt.rd_failed_timed"] / 1e3) if dv.get("megt.rd_failed_timed") else None,
                               switch_rw=dv.get("megalon.switch_rw")))
        if r["u"] in (20, 50):
            f2b.append(dict(block=r["block"], run=r["run"], system=r["system"], u=r["u"], traffic_bytes=tot_traffic,
                            updates=tot_upd, bytes_per_update=tot_traffic / tot_upd if tot_upd else None,
                            src=";".join(sorted({m["traffic_src"] or "" for m, _ in nodes.values()}))))
        if r["system"] == "Megalon" and glob.glob(os.path.join(r["dir"], "node*.megalon-wsec.bin")):
            pre = os.path.join(a.out, f"fs-{r['block']}-{r['run']}")
            subprocess.run([sys.executable, os.path.join(ROOT, "workloads", "vectordb", "tools", "classify_retries.py"),
                            "--trace", r["dir"], "--out", pre, "--stats", os.path.join(r["dir"], "loadgen"),
                            "--step", str(s["step"])], check=True, stdout=subprocess.DEVNULL)
            for x in csv.DictReader(open(pre + ".summary.csv")):
                f2c.append(dict(block=r["block"], run=r["run"], u=r["u"], **x))
    for x in f1b:
        x["hw_latency_same_L_ms"] = hw_lat.get(x["u"])
    write(os.path.join(a.out, "fig1b.csv"), ["block", "run", "system", "u", "node", "rate", "search_per_s",
          "mean_latency_ms", "hw_latency_same_L_ms", "searches", "search_busy_frac", "pop_msg_wait_ms",
          "pop_local_fault_ms", "meg_section_checks_ms", "meg_flush_ms", "meg_reexec_ms", "meg_reexec_src", "tlb_ipi",
          "coh_ms_per_search_all_threads"], f1b)
    write(os.path.join(a.out, "table1.csv"), ["block", "run", "system", "u", "node", "window_s", "coh_bg_vcpu",
          "recv_vcpu", "lib_bg_vcpu", "traffic_bytes_per_s", "traffic_src"], t1)
    write(os.path.join(a.out, "fig2b.csv"), ["block", "run", "system", "u", "traffic_bytes", "updates",
          "bytes_per_update", "src"], f2b)
    cc = ["block", "run", "u", "node", "kind", "events", "false_sharing", "true_sharing", "unexplained", "local_only",
          "write_sections_in_window", "megalon_read_retry_incoherent"]
    write(os.path.join(a.out, "fig2c.csv"), cc, f2c)
    write(os.path.join(a.out, "table2.csv"), ["block", "run", "u", "node", "updates_other_node", "failed_reads",
          "failed_reads_per_update", "incoherent_per_update", "mean_failed_attempt_us", "switch_rw"], t2)
    print(f"{len(R)} runs -> {a.out}")


if __name__ == "__main__":
    main()

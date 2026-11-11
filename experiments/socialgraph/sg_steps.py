#!/usr/bin/env python3
"""socialgraph-serving steps.csv (reports/experiments/socialgraph-serving.md §2 "CSV", exactly those columns, in that
order) and the pmax rate decision. Host only, offline, read only on the evidence.

usage: sg_steps.py steps --run-dir R --system S --nodes N --mix M --run K [--vcpus 4] [--t-ms T] [--vm K=IP ...]
                         [--cxlbw SAMPLER_DIR] --out R/steps.csv
       sg_steps.py pmax-rate (--summary SLO_SUMMARY_JSON | --name pop-<mix>-n<N> --from SG_RESULTS_TSV ...)
                         [--emit rate] [--log FILE]
       sg_steps.py selftest
R = an sg-run.sh run dir (parts slo/, pmax/; each <part>/loadgen/steps.jsonl and <part>/stats-steps.csv), stale/ and
clock-offset.tsv. One row per measured step (warmup steps dropped), parts in the order slo, pmax; phase = the loadgen
phase (ramp | bisect | confirm | overload), "pmax" for the pmax part's fixed step.
Columns (empty when the system does not provide the counter; per-VM counters summed over the N VMs, rates per second of
the step window = stats-steps.csv window_s of target 0; T_vcpu = window_s x N x vcpus):
  offered_rps          loadgen offered_x (all request streams, aggregate)
  feed_rps             feed stream achieved /s (the SLO stream); feed_p50/p99/p999_ms its latency
  getnode_p99_ms, countlink_p99_ms, write_rps, write_p99_ms   the other streams
  slo_pass             loadgen pass (feed p99 <= 10 ms, no abort)
  coherence_cpu_pct    100 x coherence ns / T_vcpu. pop / ds: thr.*.swmc.{is,sm,wpu,nontrans}_fault_ns + (ipi_coh_ns -
                       ipi_coh_infault_ns) of the server threads + kthr.cxl_recv* / kthr.cxl_ipoll* run_ns (receiver and
                       idle pollers); mg: megt.{rd_start,rd_end}_ns x rd_sections / rd_sampled (1 in megt.sample timed) +
                       megt.{wr_start,wr_end}_ns (every write section timed), all roles
  coh_msgs_per_s       run-2 definition, computed by experiments/analysis/eval3_extract.py rates() itself (coh_msgs_s, over
                       the max target window): pop = 2 x (sys.swmc.instr.serve_fetch + serve_invalidate reply_count);
                       ds = sys.swmc.destijl.{fetch_sent + inv_sent + ack_sent}; hw = 0; Megalon empty
  read_faults_per_s, write_faults_per_s   sys.swmc.page_coherence.fault_{read,write}_count
  rf_msg_us, rf_pte_tlb_us, rf_flush_us, rf_other_us   mean read fault split (us per fault) of class "read" from
                       eval3_extract.py breakdown() (run 2: pop = b13 CAT_KEYS method; ds = build-8 is_ds8 / ds8_classes /
                       ds8_owner, sync + async reads), mapped to the four Motivation Fig. 3 categories:
                         rf_msg_us     = cat1_comm      (inter-host messaging: wait - owner revoke / wb / meta)
                         rf_pte_tlb_us = cat2_unmap_tlb (PTE update and TLB flush: owner revoke)
                         rf_flush_us   = cat3_flush     (cache flush: owner write-back + local acquire flush)
                         rf_other_us   = cat4_metadata + cat5_others (others incl. metadata update: owner + local
                                         metadata, PTE install, local wait, residual)
                       rf_* sum to F / faults. Empty when the build has no five-category counters (b12 / ds7 modes).
  mg_lookup_us, mg_flush_us, mg_query_us   per server read op (op.{feed,getnode,countlink,getlink}.ops): query-thread
                       read-section start (lookup) / end time scaled by rd_sections / rd_sampled, and query = op server_ns
                       per read op - lookup - flush (Motivation Fig 2 split). mg_flush_us = VALIDATION + cache flush
                       (Megalon's read-end timer covers the version validation and the flush; not separable)
  stale_frac, stale_age_p99_ms, stale_age_max_ms   sg_stale_join.py over NODE-SLOT records (kind 1) read in the step window
                       (stats begin/end wall_ns = loadgen Host CLOCK_REALTIME), clock-corrected with clock-offset.tsv;
                       p99 over stale reads only (RecSys convention)
  cxl_read_gbps        Host CXL.mem read GB/s (cxl-bw-sampler.sh perf.csv, intervals fully inside the step; cxl_bw.py)
  stale_node_frac, stale_node_age_p99_ms, stale_node_age_max_ms   = stale_* (node-slot records), named explicitly
  stale_list_frac, stale_list_age_p99_ms, stale_list_age_max_ms   adjacency-list records (kind 2). CAVEAT: on a De Stijl
                       replica a list header and a straddled slot page can be of different ages (48 % of primary blocks
                       straddle a 4 KiB page), so the version read does not always date every byte of the list: reported,
                       not used for the pass (doc §2 "Observed staleness", verifier M3)
Max RPS under SLO (doc §2) is NOT a steps.csv column: it is the SLO search's confirm_x_mean of the feed stream (loadgen
--x-stream feed: completed feed queries / s summed over the VMs), column confirm_x_mean of <E>/sg-results.tsv (sg-block.sh);
max_offered_x_pass there is the total offered requests/s of the same step (all streams).
"""
import argparse, csv, glob, importlib.util, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(os.path.dirname(HERE))
COLS = ["system", "n_hosts", "mix", "run", "step", "phase", "offered_rps", "feed_rps", "feed_p50_ms", "feed_p99_ms",
        "feed_p999_ms", "getnode_p99_ms", "countlink_p99_ms", "write_rps", "write_p99_ms", "slo_pass", "coherence_cpu_pct",
        "coh_msgs_per_s", "read_faults_per_s", "write_faults_per_s", "rf_msg_us", "rf_pte_tlb_us", "rf_flush_us",
        "rf_other_us", "mg_lookup_us", "mg_flush_us", "mg_query_us", "stale_frac", "stale_age_p99_ms", "stale_age_max_ms",
        "cxl_read_gbps",
        # appended after the doc's original columns (verifier M3): node-slot (= stale_*) and adjacency-list staleness
        "stale_node_frac", "stale_node_age_p99_ms", "stale_node_age_max_ms",
        "stale_list_frac", "stale_list_age_p99_ms", "stale_list_age_max_ms"]
READ_OPS = ("feed", "getnode", "countlink", "getlink")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def fnum(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(x) else x


def div(a, b):
    return None if a is None or not b else a / b


class Step:
    """summed counter deltas of one step over the targets (VMs)"""

    def __init__(self, rows):
        self.rows = rows
        t0 = [r for r in rows if r.get("target") == "0"] or rows
        self.window_s = fnum(t0[0].get("window_s"))
        self.begin = min(int(r["begin_wall_ns"]) for r in rows if r.get("begin_wall_ns"))
        self.end = max(int(r["end_wall_ns"]) for r in rows if r.get("end_wall_ns"))

    def key(self, k):
        vals = [fnum(r.get(k)) for r in self.rows]
        vals = [v for v in vals if v is not None]
        return sum(vals) if vals else None

    def match(self, pre, suf):
        tot, hit = 0.0, False
        for r in self.rows:
            for k, v in r.items():
                if k.startswith(pre) and k.endswith(suf):
                    x = fnum(v)
                    if x is not None:
                        tot += x; hit = True
        return tot if hit else None


def coh_cpu_ns(st, system):
    if system in ("pop", "ds"):
        parts = [st.match("thr.", ".swmc." + k) for k in ("is_fault_ns", "sm_fault_ns", "wpu_fault_ns", "nontrans_fault_ns")]
        ipi, ipin = st.match("thr.", ".swmc.ipi_coh_ns"), st.match("thr.", ".swmc.ipi_coh_infault_ns")
        rx = [st.match("kthr.cxl_recv", ".run_ns"), st.match("kthr.cxl_ipoll", ".run_ns")]
        if all(p is None for p in parts + rx):
            return None
        return sum(p or 0 for p in parts) + ((ipi or 0) - (ipin or 0)) + sum(p or 0 for p in rx)
    if system in ("mgc", "mgr"):
        rs, rsm = st.key("megt.rd_sections"), st.key("megt.rd_sampled")
        rd = [st.key("megt.rd_start_ns"), st.key("megt.rd_end_ns")]
        wr = [st.key("megt.wr_start_ns"), st.key("megt.wr_end_ns")]
        if all(x is None for x in rd + wr):
            return None
        scale = div(rs, rsm) or 0.0
        return sum(x or 0 for x in rd) * scale + sum(x or 0 for x in wr)
    return None


E3_SYS = {"hw": "hw", "pop": "pop", "ds": "ds", "mgc": "mg", "mgr": "mg"}  # sg system -> eval3_extract cell system


class E3Cell:
    """the eval3_extract.Cell fields its breakdown() / rates() read (no lifetime status-delta: per-step srv_* only)"""

    def __init__(self, system, n):
        self.system, self.N = E3_SYS[system], n
        self.ds_status, self.ds_status_note = None, ""


def e3_msgs_per_s(E3, cell, t):
    """coh_msgs_per_s = eval3_extract.rates()["coh_msgs_s"] (run 2: pop 2 x serve reply counts; ds fetch + inv + ack)"""
    return E3.rates(cell, t)["coh_msgs_s"]


def e3_rf_split(E3, cell, t):
    """[msg, pte_tlb, flush, other] us per read fault from eval3_extract.breakdown() class "read" (see the module doc for
    the five-category -> Motivation Fig. 3 four-category mapping); [None] x 4 without five-category counters"""
    rows = [b for b in E3.breakdown(cell, t) if b.get("class") == "read"]
    if not rows or not rows[0].get("faults"):
        return [None] * 4
    b = rows[0]
    cats = [b.get(k) for k in ("cat1_comm_ns", "cat2_unmap_tlb_ns", "cat3_flush_ns", "cat4_metadata_ns", "cat5_others_ns")]
    if any(v is None for v in cats):
        return [None] * 4
    n = b["faults"]
    return [cats[0] / n / 1e3, cats[1] / n / 1e3, cats[2] / n / 1e3, (cats[3] + cats[4]) / n / 1e3]


def mg_split(st):
    """[lookup, validation + flush, query] us per server read op. megt.query.rd_end_ns times Megalon's read-section end,
    which validates the object version and flushes the read lines: mg_flush_us is validation + flush (L6)."""
    rops = sum(st.key(f"op.{o}.ops") or 0 for o in READ_OPS)
    if not rops or st.key("megt.query.rd_sections") is None:
        return [None] * 3
    scale = div(st.key("megt.query.rd_sections"), st.key("megt.query.rd_sampled")) or 0.0
    lk = (st.key("megt.query.rd_start_ns") or 0) * scale / rops
    fl = (st.key("megt.query.rd_end_ns") or 0) * scale / rops
    srv = sum(st.key(f"op.{o}.server_ns") or 0 for o in READ_OPS) / rops
    return [lk / 1e3, fl / 1e3, (srv - lk - fl) / 1e3]


def steps_rows(a):
    SJ = _load("sg_stale_join", os.path.join(TREE, "workloads", "socialgraph", "tools", "sg_stale_join.py"))
    E3 = _load("eval3_extract", os.path.join(TREE, "experiments", "analysis", "eval3_extract.py"))
    cell = E3Cell(a.system, a.nodes)
    stale = None
    sd = os.path.join(a.run_dir, "stale")
    if glob.glob(os.path.join(sd, "stale-*.bin")):
        clk = os.path.join(a.run_dir, "clock-offset.tsv")
        vms = {int(x.split("=", 1)[0]): x.split("=", 1)[1] for x in a.vm}
        stale = SJ.prepare(sd, [clk] if os.path.isfile(clk) and vms else None, vms)
    cxl = None
    if a.cxlbw and os.path.isfile(os.path.join(a.cxlbw, "perf.csv")):
        cxl = _load("cxl_bw", os.path.join(TREE, "experiments", "eval", "cxl_bw.py")).intervals(a.cxlbw)
    out = []
    for part in ("slo", "pmax"):
        pd = os.path.join(a.run_dir, part)
        sj = os.path.join(pd, "loadgen", "steps.jsonl")
        if not os.path.isfile(sj):
            continue
        by = {}
        ss = os.path.join(pd, "stats-steps.csv")
        if os.path.isfile(ss):
            for r in csv.DictReader(open(ss)):
                by.setdefault(int(r["step"]), []).append(r)
        e3 = E3.load_stats(pd) if os.path.isfile(ss) else {}  # eval3_extract per-step pools (rates / breakdown input)
        for line in open(sj):
            if not line.strip():
                continue
            d = json.loads(line)
            if d.get("phase") == "warmup" or not d.get("measure_s"):
                continue
            s = d.get("streams", {})
            f = lambda st, k: s.get(st, {}).get(k)  # noqa: E731
            o = dict(system=a.system, n_hosts=a.nodes, mix=a.mix, run=a.run, step=d["step"],
                     phase="pmax" if part == "pmax" else d.get("phase"), offered_rps=d.get("offered_x"),
                     feed_rps=f("feed", "achieved"), feed_p50_ms=f("feed", "p50_ms"), feed_p99_ms=f("feed", "p99_ms"),
                     feed_p999_ms=f("feed", "p999_ms"), getnode_p99_ms=f("getnode", "p99_ms"),
                     countlink_p99_ms=f("countlink", "p99_ms"), write_rps=f("write", "achieved"),
                     write_p99_ms=f("write", "p99_ms"), slo_pass=int(bool(d.get("pass"))))
            rows = by.get(int(d["step"]))
            if rows:
                st = Step(rows)
                w = st.window_s
                tv = w * a.nodes * a.vcpus * 1e9 if w else None
                c = coh_cpu_ns(st, a.system)
                o["coherence_cpu_pct"] = None if c is None or not tv else 100.0 * c / tv
                t3 = e3.get(int(d["step"]))
                if t3:
                    o["coh_msgs_per_s"] = e3_msgs_per_s(E3, cell, t3)
                if a.system in ("pop", "ds"):
                    o["read_faults_per_s"] = div(st.key("sys.swmc.page_coherence.fault_read_count"), w)
                    o["write_faults_per_s"] = div(st.key("sys.swmc.page_coherence.fault_write_count"), w)
                    if t3:
                        o["rf_msg_us"], o["rf_pte_tlb_us"], o["rf_flush_us"], o["rf_other_us"] = e3_rf_split(E3, cell, t3)
                if a.system in ("mgc", "mgr"):
                    o["mg_lookup_us"], o["mg_flush_us"], o["mg_query_us"] = mg_split(st)
                if stale is not None:
                    R, C, err, corr, _ = stale
                    j = SJ.join(R, C, [(st.begin, st.end)])
                    for kind, pre in ((SJ.KIND_NODE, "stale_node_"), (SJ.KIND_LIST, "stale_list_")):
                        sm = SJ.summarize(j, err, corr, a.t_ms, kind=kind)
                        o[pre + "frac"], o[pre + "age_p99_ms"], o[pre + "age_max_ms"] = (
                            sm["stale_frac"], sm["stale_age_p99_ms"], sm["stale_age_max_ms"])
                    # the doc's stale_* columns = node-slot records (verifier M3)
                    o["stale_frac"], o["stale_age_p99_ms"], o["stale_age_max_ms"] = (
                        o["stale_node_frac"], o["stale_node_age_p99_ms"], o["stale_node_age_max_ms"])
                if cxl is not None:
                    b, e = st.begin / 1e9, st.end / 1e9
                    sel = [x for x in cxl if x[0] >= b and x[1] <= e]
                    dt = sum(x[1] - x[0] for x in sel)
                    o["cxl_read_gbps"] = sum(x[2] for x in sel) / dt / 1e9 if dt else None
            out.append(o)
    return out


def write(path, rows):
    fmt = lambda v: "" if v is None else (f"{v:.6g}" if isinstance(v, float) else str(v))  # noqa: E731
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(COLS)
        for r in rows:
            w.writerow([fmt(r.get(c)) for c in COLS])


def pmax_rate(a):
    """offered rate of the pmax step = Popcorn's max under the SLO of the cell (confirmed max_offered_x_pass), or skip"""
    src, rate, why = None, None, ""
    if a.summary:
        src = a.summary
        try:
            s = json.load(open(a.summary))
            rate = s.get("max_offered_x_pass") if s.get("confirmed") else None
            why = "" if rate else f"not confirmed (confirmed={s.get('confirmed')}, note={s.get('note', '')!r})"
        except (OSError, ValueError) as e:
            why = f"unreadable ({e})"
    else:
        for p in a.from_ or []:
            for r in csv.reader(open(p), delimiter="\t"):
                if r and not r[0].startswith("#") and r[0] == a.name and len(r) > 7:
                    src = p
                    rate = fnum(r[5]) if r[7] == "True" else None
                    why = "" if rate else f"row {a.name} not confirmed ({r[7]})"
        if src is None:
            why = f"no {a.name} row in [{' '.join(a.from_ or [])}]"
    line = f"{rate if rate else '-'}\t{1 if rate else 0}\t{src or '-'}\t{why}"
    if a.log:
        with open(a.log, "a") as f:
            f.write(line + "\n")
    if a.emit == "rate":
        print(f"{float(rate):g}" if rate else "skip")
    else:
        print(line)
    return 0


def _selftest_cell(d, per_target):
    """synthetic sg-run.sh part slo/ under d: one warm-up + one measured step (window 10 s, 2 VMs); per_target = {column:
    value} of every target's stats-steps.csv row (same counters on both VMs); staleness logs: per VM a node-slot read
    (rid 1<<40|7, v1, Host 1000.5 s; commit v2 at 1000.2 s by VM 0 -> stale 300 ms), list reads (rid 2<<40|9: v1 at
    1000.6 s -> stale 100 ms vs commit v2 at 1000.5 s; v2 at 1000.7 s fresh) and an out-of-window read (2000 s)"""
    import struct  # noqa: F401  (SJ.HDR / ENT are struct.Struct)
    os.makedirs(os.path.join(d, "slo", "loadgen"))
    st = {"feed": {"achieved": 900.0, "p50_ms": 1.0, "p99_ms": 5.0, "p999_ms": 9.0},
          "getnode": {"p99_ms": 0.5}, "countlink": {"p99_ms": 0.4}, "write": {"achieved": 9.0, "p99_ms": 2.0}}
    with open(os.path.join(d, "slo", "loadgen", "steps.jsonl"), "w") as f:
        f.write(json.dumps({"step": 0, "phase": "warmup", "measure_s": 0, "offered_x": 1000, "streams": st}) + "\n")
        f.write(json.dumps({"step": 1, "phase": "ramp", "measure_s": 15, "offered_x": 1000, "pass": True, "streams": st}) + "\n")
    hdr = ["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s"] + list(per_target)
    with open(os.path.join(d, "slo", "stats-steps.csv"), "w", newline="") as f:
        w = csv.writer(f); w.writerow(hdr)
        for t in (0, 1):
            w.writerow([1, "ramp", 1000, t, f"vm{t}", 1_000_000_000_000, 1_010_000_000_000, 10.0] + list(per_target.values()))
    os.makedirs(os.path.join(d, "stale"))
    SJ = _load("sg_stale_join", os.path.join(TREE, "workloads", "socialgraph", "tools", "sg_stale_join.py"))
    nd, ls = (SJ.KIND_NODE << 40) | 7, (SJ.KIND_LIST << 40) | 9
    for k in (0, 1):
        with open(os.path.join(d, "stale", f"stale-reads-n{k}.bin"), "wb") as f:
            f.write(SJ.HDR.pack(b"SGSTLR01", k, 24, 1000, 0))
            for e in ((nd, 1, 1_000_500_000_000), (ls, 1, 1_000_600_000_000), (ls, 2, 1_000_700_000_000),
                      ((SJ.KIND_NODE << 40) | 8, 1, 2_000_000_000_000)):
                f.write(SJ.ENT.pack(*e))
        with open(os.path.join(d, "stale", f"stale-commits-n{k}.bin"), "wb") as f:
            f.write(SJ.HDR.pack(b"SGSTLC01", k, 24, 1, 0))
            if k == 0:
                f.write(SJ.ENT.pack(nd, 2, 1_000_200_000_000)); f.write(SJ.ENT.pack(ls, 2, 1_000_500_000_000))


def selftest():
    import tempfile
    fails = []

    def near(r, k, v, tol=1e-9):
        if r.get(k) is None or abs(r[k] - v) > tol:
            fails.append(f"{r.get('system')}: {k}={r.get(k)} want {v}")

    with tempfile.TemporaryDirectory() as d:
        # --- Popcorn b13 (eval3_extract CAT_KEYS method). Per VM: 100 read faults of 10 us (F 1 ms), msg wait 600 us,
        # last owner revoke 300 / wb 100 / meta 50 us, acquire flush 20 us, local meta 10 us; receiver 1 s CPU;
        # serve_fetch 100 + serve_invalidate 25 replies. Sums over 2 VMs / 200 faults:
        #   cat1 = (600-300-100-50) x 2 = 300 us -> 1.5 us/fault; cat2 = 600 -> 3.0; cat3 = (100+20) x 2 = 240 -> 1.2;
        #   cat4 = (50+10) x 2 = 120 -> 0.6; cat5 = 2000-300-600-240-120 = 740 -> 3.7; rf_other = 0.6 + 3.7 = 4.3
        #   coh msgs = 2 x (100 + 25) x 2 = 500 / 10 s = 50 /s (run 2: 2 x serve reply counts)
        pop = {"thr.sg-query.swmc.is_fault_ns": 1_000_000, "thr.sg-query.swmc.is_faults": 100,
               "thr.sg-query.swmc.breakdown_faults": 100, "thr.sg-query.swmc.read_msg_wait_ns": 600_000,
               "thr.sg-query.swmc.read_owner_h_ns": 500_000, "thr.sg-query.swmc.read_last_revoke_ns": 300_000,
               "thr.sg-query.swmc.read_last_wb_ns": 100_000, "thr.sg-query.swmc.read_last_meta_ns": 50_000,
               "thr.sg-query.swmc.read_acquire_flush_ns": 20_000, "thr.sg-query.swmc.read_local_meta_ns": 10_000,
               "thr.sg-query.swmc.read_pte_install_ns": 5_000, "thr.sg-query.swmc.read_local_wait_ns": 1_000,
               "sys.swmc.instr.serve_fetch.reply_count": 100, "sys.swmc.instr.serve_invalidate.reply_count": 25,
               "sys.swmc.page_coherence.requests_sent_count": 999,  # the pre-fix definition: must NOT be used
               "kthr.cxl_recv/0.run_ns": 1_000_000_000, "sys.swmc.page_coherence.fault_read_count": 1000,
               "sys.swmc.page_coherence.fault_write_count": 10}
        # --- De Stijl build 8 (is_ds8 / ds8_classes / ds8_owner, srv_* per node). Per VM: 100 sync read faults (F 1 ms,
        # read_async_* = 0), msg wait 600 us, acquire flush 50 us, local meta 20 us; fetch_sent 100 (no async, no
        # eviction), inv_sent 10, ack_sent 110; owner srv_fetch_sync per request revoke 2 / wb 1 / meta 0.5 us.
        # Owner totals (2 requesters x 100 rounds x the other VM's means): revoke 400, wb 200, meta 100 us. Sums / 200:
        #   cat1 = 1200-400-200-100 = 500 -> 2.5; cat2 = 400 -> 2.0; cat3 = 200+100 = 300 -> 1.5;
        #   cat4 = 100+40 = 140 -> 0.7; cat5 = 2000-500-400-300-140 = 660 -> 3.3; rf_other = 4.0
        #   coh msgs = (100 + 10 + 110) x 2 = 440 / 10 s = 44 /s
        ds = {"thr.sg-query.swmc.is_fault_ns": 1_000_000, "thr.sg-query.swmc.is_faults": 100,
              "thr.sg-query.swmc.read_async_is_fault_ns": 0, "thr.sg-query.swmc.read_async_faults": 0,
              "thr.sg-query.swmc.read_msg_wait_ns": 600_000, "thr.sg-query.swmc.read_acquire_flush_ns": 50_000,
              "thr.sg-query.swmc.read_local_meta_ns": 20_000, "thr.sg-query.swmc.read_pte_install_ns": 10_000,
              "thr.sg-query.swmc.read_local_wait_ns": 5_000,
              "sys.swmc.destijl.fetch_sent": 100, "sys.swmc.destijl.async_issued": 0, "sys.swmc.destijl.inv_sent": 10,
              "sys.swmc.destijl.ack_sent": 110, "sys.swmc.destijl.srv_fetch_sync_count": 100,
              "sys.swmc.destijl.srv_fetch_sync_revoke_ns": 200_000, "sys.swmc.destijl.srv_fetch_sync_wb_ns": 100_000,
              "sys.swmc.destijl.srv_fetch_sync_meta_ns": 50_000, "sys.swmc.destijl.srv_inv_count": 0,
              "sys.swmc.destijl.srv_fetch_evict_count": 0,
              "sys.swmc.page_coherence.fault_read_count": 1000, "sys.swmc.page_coherence.fault_write_count": 10}
        rows = {}
        for system, cols in (("pop", pop), ("ds", ds), ("hw", {"sys.swmc.page_coherence.fault_read_count": 0})):
            cd = os.path.join(d, system)
            _selftest_cell(cd, cols)
            a = argparse.Namespace(run_dir=cd, system=system, nodes=2, mix="rw100", run=1, vcpus=4, t_ms=1000.0, vm=[],
                                   cxlbw=None)
            rr = steps_rows(a)
            if len(rr) != 1:
                fails.append(f"{system}: rows {len(rr)} != 1 (warmup dropped)")
                continue
            rows[system] = rr[0]
        r = rows.get("pop", {})
        exp = {"feed_rps": 900.0, "feed_p99_ms": 5.0, "slo_pass": 1, "offered_rps": 1000, "phase": "ramp",
               "read_faults_per_s": 100.0 * 2, "write_faults_per_s": 2.0}
        for k, v in exp.items():
            if r.get(k) != v:
                fails.append(f"pop: {k}={r.get(k)} want {v}")
        near(r, "coh_msgs_per_s", 50.0)
        # coherence ns = 2 x (1 ms faults + 1 s receiver) = 2.002e9 over 10 s x 2 x 4 vCPU = 8e10 ns -> 2.5025 %
        near(r, "coherence_cpu_pct", 2.5025, 1e-6)
        for k, v in (("rf_msg_us", 1.5), ("rf_pte_tlb_us", 3.0), ("rf_flush_us", 1.2), ("rf_other_us", 4.3)):
            near(r, k, v)
        r = rows.get("ds", {})
        near(r, "coh_msgs_per_s", 44.0)
        for k, v in (("rf_msg_us", 2.5), ("rf_pte_tlb_us", 2.0), ("rf_flush_us", 1.5), ("rf_other_us", 4.0)):
            near(r, k, v)
        if rows.get("hw", {}).get("coh_msgs_per_s") != 0.0:
            fails.append(f"hw: coh_msgs_per_s={rows.get('hw', {}).get('coh_msgs_per_s')} want 0 (run 2)")
        # stale split (M3): node slots 2 reads in the window, both stale 300 ms; lists 4 reads, 2 stale 100 ms
        for system, r in rows.items():
            for k, v in (("stale_frac", 1.0), ("stale_age_max_ms", 300.0), ("stale_age_p99_ms", 300.0),
                         ("stale_node_frac", 1.0), ("stale_node_age_max_ms", 300.0), ("stale_list_frac", 0.5),
                         ("stale_list_age_p99_ms", 100.0), ("stale_list_age_max_ms", 100.0)):
                near(r, k, v, 1e-6)
        out = os.path.join(d, "steps.csv")
        write(out, list(rows.values()))
        hdr = next(csv.reader(open(out)))
        doc = COLS[:COLS.index("cxl_read_gbps") + 1]
        if hdr != COLS or hdr[:31] != doc or len(doc) != 31 or hdr[31:] != [
                "stale_node_frac", "stale_node_age_p99_ms", "stale_node_age_max_ms",
                "stale_list_frac", "stale_list_age_p99_ms", "stale_list_age_max_ms"]:
            fails.append("header != the doc's columns + the six appended staleness columns")
        json.dump({"confirmed": True, "max_offered_x_pass": 1100, "confirm": {"x_mean": 31.5}},
                  open(os.path.join(d, "sm.json"), "w"))
        if "max RPS under SLO = 31.5 feed completions/s" not in max_rps_line(os.path.join(d, "sm.json")):
            fails.append("max_rps_line")
        # pmax rate: confirmed summary -> rate; tsv row -> rate; unconfirmed -> skip
        sm = os.path.join(d, "s.json")
        json.dump({"max_offered_x_pass": 1234.5, "confirmed": True}, open(sm, "w"))
        tsv = os.path.join(d, "r.tsv")
        with open(tsv, "w") as f:
            f.write("# name\tsystem\tmix\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\n")
            f.write("pop-rw100-n2\tpop\trw100\t2\t4\t2000\t1500\tTrue\tnote\tx\t1\n")
            f.write("pop-rw470-n2\tpop\trw470\t2\t4\t3000\t2500\tFalse\tnote\tx\t1\n")
        import io, contextlib
        for ns, want in ((argparse.Namespace(summary=sm, from_=None, name=None, emit="rate", log=None), "1234.5"),
                         (argparse.Namespace(summary=None, from_=[tsv], name="pop-rw100-n2", emit="rate", log=None), "2000"),
                         (argparse.Namespace(summary=None, from_=[tsv], name="pop-rw470-n2", emit="rate", log=None), "skip"),
                         (argparse.Namespace(summary=None, from_=[tsv], name="pop-rw100-n4", emit="rate", log=None), "skip")):
            b = io.StringIO()
            with contextlib.redirect_stdout(b):
                pmax_rate(ns)
            if b.getvalue().strip() != want:
                fails.append(f"pmax-rate {ns.name or 'summary'}: {b.getvalue().strip()!r} want {want}")
    print("sg_steps selftest " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
    return 0 if not fails else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("steps")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--system", required=True, choices=["hw", "pop", "ds", "mgc", "mgr"])
    s.add_argument("--nodes", type=int, required=True)
    s.add_argument("--mix", required=True)
    s.add_argument("--run", type=int, required=True)
    s.add_argument("--vcpus", type=int, default=4)
    s.add_argument("--t-ms", type=float)
    s.add_argument("--vm", action="append", default=[])
    s.add_argument("--cxlbw")
    s.add_argument("--out", required=True)
    p = sub.add_parser("pmax-rate")
    p.add_argument("--summary")
    p.add_argument("--name")
    p.add_argument("--from", dest="from_", action="append")
    p.add_argument("--emit", choices=["rate", "line"], default="line")
    p.add_argument("--log")
    sub.add_parser("selftest")
    a = ap.parse_args()
    if a.cmd == "selftest":
        return selftest()
    if a.cmd == "pmax-rate":
        if not a.summary and not a.name:
            ap.error("pmax-rate needs --summary or --name with --from")
        return pmax_rate(a)
    rows = steps_rows(a)
    write(a.out, rows)
    print(f"sg_steps: {len(rows)} rows -> {a.out}")
    print(max_rps_line(os.path.join(a.run_dir, "slo", "loadgen", "summary.json")))
    return 0


def max_rps_line(summary):
    """L1: the doc's "max RPS under SLO" = summary confirm.x_mean with --x-stream feed (completed feed queries / s)"""
    try:
        s = json.load(open(summary))
    except (OSError, ValueError) as e:
        return f"sg_steps: max RPS under SLO: no SLO summary ({e})"
    c = s.get("confirm", {}) or {}
    return (f"sg_steps: max RPS under SLO = {c.get('x_mean')} feed completions/s (confirm_x_mean, --x-stream feed; "
            f"confirmed={s.get('confirmed')}); total offered at that step max_offered_x_pass={s.get('max_offered_x_pass')} req/s")


if __name__ == "__main__":
    sys.exit(main())

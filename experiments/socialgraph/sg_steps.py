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
  coh_msgs_per_s       pop: sum of sys.swmc.*.requests_sent_count; ds: sys.swmc.destijl.{fetch_sent,inv_sent}
  read_faults_per_s, write_faults_per_s   sys.swmc.page_coherence.fault_{read,write}_count
  rf_msg_us, rf_pte_tlb_us, rf_flush_us, rf_other_us   mean I->S read fault split (us per fault), formulas of
                       experiments/analysis/v6_fig4_popcorn.py phases_b9 (Motivation Fig 3): F = is_fault_ns / is_faults,
                       msg = transport + owner reply send, pte_tlb = owner revoke (mkclean + TLB shootdown), flush = owner
                       write-back flush, other = F - msg - pte_tlb - flush (local handling + rest of owner handling)
  mg_lookup_us, mg_flush_us, mg_query_us   per server read op (op.{feed,getnode,countlink,getlink}.ops): query-thread
                       read-section start (lookup) / end (validation + flush) time scaled by rd_sections / rd_sampled, and
                       query = op server_ns per read op - lookup - flush (Motivation Fig 2 split)
  stale_frac, stale_age_p99_ms, stale_age_max_ms   sg_stale_join.py over the reads whose Host time lies in the step window
                       (stats begin/end wall_ns = loadgen Host CLOCK_REALTIME), clock-corrected with clock-offset.tsv
  cxl_read_gbps        Host CXL.mem read GB/s (cxl-bw-sampler.sh perf.csv, intervals fully inside the step; cxl_bw.py)
"""
import argparse, csv, glob, importlib.util, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(os.path.dirname(HERE))
COLS = ["system", "n_hosts", "mix", "run", "step", "phase", "offered_rps", "feed_rps", "feed_p50_ms", "feed_p99_ms",
        "feed_p999_ms", "getnode_p99_ms", "countlink_p99_ms", "write_rps", "write_p99_ms", "slo_pass", "coherence_cpu_pct",
        "coh_msgs_per_s", "read_faults_per_s", "write_faults_per_s", "rf_msg_us", "rf_pte_tlb_us", "rf_flush_us",
        "rf_other_us", "mg_lookup_us", "mg_flush_us", "mg_query_us", "stale_frac", "stale_age_p99_ms", "stale_age_max_ms",
        "cxl_read_gbps"]
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


def msgs(st, system):
    if system == "pop":
        return st.match("sys.swmc.", ".requests_sent_count")
    if system == "ds":
        a, b = st.key("sys.swmc.destijl.fetch_sent"), st.key("sys.swmc.destijl.inv_sent")
        return None if a is None and b is None else (a or 0) + (b or 0)
    return None


def rf_split(st):
    g = lambda pre, suf: st.match(pre, suf)  # noqa: E731
    nF, F_ns = g("thr.", ".swmc.is_faults"), g("thr.", ".swmc.is_fault_ns")
    if not nF:
        return [None] * 4
    F = F_ns / nF
    rpf = div(g("thr.", ".swmc.read_transactions"), nF)
    hr = g("thr.", ".swmc.read_owner_h_rounds")
    served = (st.key("sys.swmc.instr.serve_fetch.ack") or 0) + (st.key("sys.swmc.instr.serve_fetch.nack") or 0)
    sc = lambda v: None if v is None or rpf is None else v * rpf  # noqa: E731  per round -> per fault
    trans = sc(div(g("thr.", ".swmc.read_xport_ns"), hr))
    rev = sc(div(st.key("sys.swmc.instr.serve_fetch.revoke_ns"), served))
    wb = sc(div(st.key("sys.swmc.instr.serve_fetch.wb_ns"), served))
    rep = sc(div(st.key("sys.swmc.instr.serve_fetch.reply_ns"), st.key("sys.swmc.instr.serve_fetch.reply_count")))
    if trans is None and rev is None:
        return [None] * 4
    msg = (trans or 0) + (rep or 0)
    other = F - msg - (rev or 0) - (wb or 0)
    us = lambda v: None if v is None else v / 1e3  # noqa: E731
    return [us(msg), us(rev), us(wb), us(other)]


def mg_split(st):
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
                o["coh_msgs_per_s"] = div(msgs(st, a.system), w)
                if a.system in ("pop", "ds"):
                    o["read_faults_per_s"] = div(st.key("sys.swmc.page_coherence.fault_read_count"), w)
                    o["write_faults_per_s"] = div(st.key("sys.swmc.page_coherence.fault_write_count"), w)
                    o["rf_msg_us"], o["rf_pte_tlb_us"], o["rf_flush_us"], o["rf_other_us"] = rf_split(st)
                if a.system in ("mgc", "mgr"):
                    o["mg_lookup_us"], o["mg_flush_us"], o["mg_query_us"] = mg_split(st)
                if stale is not None:
                    R, C, err, corr, _ = stale
                    sm = SJ.summarize(SJ.join(R, C, [(st.begin, st.end)]), err, corr, a.t_ms)
                    o["stale_frac"], o["stale_age_p99_ms"], o["stale_age_max_ms"] = (
                        sm["stale_frac"], sm["stale_age_p99_ms"], sm["stale_age_max_ms"])
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


def selftest():
    import tempfile
    fails = []
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "slo", "loadgen"))
        st = {"feed": {"achieved": 900.0, "p50_ms": 1.0, "p99_ms": 5.0, "p999_ms": 9.0},
              "getnode": {"p99_ms": 0.5}, "countlink": {"p99_ms": 0.4}, "write": {"achieved": 9.0, "p99_ms": 2.0}}
        with open(os.path.join(d, "slo", "loadgen", "steps.jsonl"), "w") as f:
            f.write(json.dumps({"step": 0, "phase": "warmup", "measure_s": 0, "offered_x": 1000, "streams": st}) + "\n")
            f.write(json.dumps({"step": 1, "phase": "ramp", "measure_s": 15, "offered_x": 1000, "pass": True, "streams": st}) + "\n")
        hdr = ["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s",
               "thr.sg-query.swmc.is_fault_ns", "thr.sg-query.swmc.is_faults", "thr.sg-query.swmc.read_transactions",
               "thr.sg-query.swmc.read_xport_ns", "thr.sg-query.swmc.read_owner_h_rounds",
               "sys.swmc.instr.serve_fetch.revoke_ns", "sys.swmc.instr.serve_fetch.wb_ns",
               "sys.swmc.instr.serve_fetch.reply_ns", "sys.swmc.instr.serve_fetch.reply_count",
               "sys.swmc.instr.serve_fetch.ack", "sys.swmc.instr.serve_fetch.nack", "kthr.cxl_recv/0.run_ns",
               "sys.swmc.page_coherence.requests_sent_count", "sys.swmc.page_coherence.fault_read_count",
               "sys.swmc.page_coherence.fault_write_count"]
        with open(os.path.join(d, "slo", "stats-steps.csv"), "w", newline="") as f:
            w = csv.writer(f); w.writerow(hdr)
            # 2 VMs, window 10 s; per VM: 100 I->S faults of 10 us each (1 round each), xport 2 us/round, owner revoke 3 us,
            # wb 1 us, reply 0.5 us per served request, receiver 1 s of CPU
            for t in (0, 1):
                w.writerow([1, "ramp", 1000, t, f"vm{t}", 1_000_000_000_000, 1_010_000_000_000, 10.0, 1_000_000, 100, 100,
                            200_000, 100, 300_000, 100_000, 50_000, 100, 100, 0, 1_000_000_000, 500, 1000, 10])
        os.makedirs(os.path.join(d, "stale"))
        SJ = _load("sg_stale_join", os.path.join(TREE, "workloads", "socialgraph", "tools", "sg_stale_join.py"))
        import struct
        for k in (0, 1):
            with open(os.path.join(d, "stale", f"stale-reads-n{k}.bin"), "wb") as f:
                f.write(SJ.HDR.pack(b"SGSTLR01", k, 24, 1000, 0))
                # reads at host t = 1000.5 s (in the window) of version 1 (stale vs a commit at 1000.2 s) and at 2000 s (out)
                f.write(SJ.ENT.pack(7, 1, 1_000_500_000_000)); f.write(SJ.ENT.pack(8, 1, 2_000_000_000_000))
            with open(os.path.join(d, "stale", f"stale-commits-n{k}.bin"), "wb") as f:
                f.write(SJ.HDR.pack(b"SGSTLC01", k, 24, 1, 0))
                if k == 0:
                    f.write(SJ.ENT.pack(7, 2, 1_000_200_000_000))
        del struct
        a = argparse.Namespace(run_dir=d, system="pop", nodes=2, mix="rw100", run=1, vcpus=4, t_ms=1000.0, vm=[],
                               cxlbw=None)
        rows = steps_rows(a)
        if len(rows) != 1:
            fails.append(f"rows {len(rows)} != 1 (warmup dropped)")
        else:
            r = rows[0]
            exp = {"feed_rps": 900.0, "feed_p99_ms": 5.0, "slo_pass": 1, "offered_rps": 1000, "phase": "ramp",
                   "coh_msgs_per_s": 100.0, "read_faults_per_s": 200.0, "write_faults_per_s": 2.0}
            for k, v in exp.items():
                if r.get(k) != v:
                    fails.append(f"{k}={r.get(k)} want {v}")
            # coherence ns = 2 x (1 ms faults + 1 s receiver) = 2.002e9 over 10 s x 2 x 4 vCPU = 8e10 ns -> 2.5025 %
            if abs((r.get("coherence_cpu_pct") or 0) - 2.5025) > 1e-6:
                fails.append(f"coherence_cpu_pct={r.get('coherence_cpu_pct')} want 2.5025")
            # F 10 us; msg = 2 + 0.5; pte_tlb 3; flush 1; other 3.5
            for k, v in (("rf_msg_us", 2.5), ("rf_pte_tlb_us", 3.0), ("rf_flush_us", 1.0), ("rf_other_us", 3.5)):
                if abs((r.get(k) or -1) - v) > 1e-9:
                    fails.append(f"{k}={r.get(k)} want {v}")
            # stale: 2 reads in the window (one per node, both rid 7 v1 at 1000.5 s, commit v2 at 1000.2 s) -> both stale 300 ms
            if r.get("stale_frac") != 1.0 or abs((r.get("stale_age_max_ms") or 0) - 300.0) > 1e-6:
                fails.append(f"stale {r.get('stale_frac')} {r.get('stale_age_max_ms')} want 1.0 300")
        out = os.path.join(d, "steps.csv")
        write(out, rows)
        if next(csv.reader(open(out))) != COLS:
            fails.append("header != the doc's columns")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())

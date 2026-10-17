#!/usr/bin/env python3
"""P-popcorn recv13 comparison: Host-side summary of one evidence dir (reports/P-popcorn-recv13-packet.md).

Usage: p-popcorn-recv-summary.py <E> [<out dir>]   (out dir default <E>; results.csv/summary.txt go there)
Reads <E>/r<rep>-<cfg>/{config.txt, s1, s2, s3} written by recovery/P-popcorn-recv13-v1/run.sh and writes
  <E>/results.csv   one row per (repeat, config, scenario): latency, owner H / W-H, coherence CPU, counters, hogs
  <E>/summary.txt   mean +- sd per (config, scenario) over the repeats (v1.1: 2 repeats; each repeat listed) and the decision rule of
                    reports/P-popcorn-recv-scaleout.md §5 (adopted by the user 2026-10-18) as computed checks
Exit 1 if an expected file is missing (no partial summary).
Decision (v1.2, user 2026-10-18): with 1 repeat each criterion is PASS/FAIL (rule below) and CLEAR or MARGINAL:
  S1 p50 NEW-OLD <= +2.5 us clear pass, >= +7.5 us clear fail; S2 p99 NEW <= 0.9 OLD / >= 1.1 OLD;
  S3 ops/s NEW >= 1.025 OLD / <= 0.925 OLD; coh_cpu_total NEW <= 0.9 OLD / >= 1.1 OLD; else MARGINAL.
  Final line: "DECISION KEEP (clear)" if any criterion is a clear fail, "DECISION ADOPT (clear)" if all are clear
  passes, else "DECISION MARGINAL: run R2".  With 2 repeats: the mean-based rule (PASS/FAIL per criterion).

Coherence CPU (seconds, per scenario window, delta of the post minus pre snapshots):
  recv_s     receive thread utime+stime (/proc/<pid>/stat, clock ticks): poll/sleep mode = consumer CPU,
             idle mode = the SCHED_IDLE watcher (reported apart as watcher_s, not counted as coherence CPU)
  busy_s     sum of instr consumer<i>_busy_ns (module 13 consumer work items, start -> return incl. spin)
  coh_s      = busy_s + (recv_s if recv_mode != idle else 0)
S1/S2 count the answering node vm1 only (vm0 only requests); S3 counts both nodes.  coh_s excludes hardirq time
(module 13: fallback timer and tick hook; both modules: IPIs), so fallback_expiries and the S2 hog iterations/s
(like-for-like CPU left to the workload) are printed next to it.
  irq_s, softirq_s, steal_s  /proc/stat aggregate deltas of the window (build 12: CONFIG_IRQ_TIME_ACCOUNTING=y,
             so hardirq/softirq time is measured, not folded into the interrupted task; USER_HZ resolution, 10 ms
             per CPU field: short S1 windows are coarse); steal = Host time while the vCPU was preempted (VM exits
             of timer interrupts land mostly here, reported apart)
  coh_cpu_total = coh_s + irq_s + softirq_s (user decision 2026-10-18: interrupt cost is part of the coherence
             cost; includes background interrupts, equal across configs); the decision rule uses coh_cpu_total.
"""
import csv
import json
import os
import re
import statistics
import sys

CFGS = ["OLD", "NEW", "NEWP"]
COUNTERS = ["consumer_kicks", "scaleout_kicks", "consumer_requeues", "consumer_rekicks", "fallback_arms",
            "fallback_kicks", "fallback_expiries", "fallback_parks", "stuck_kicks", "idle_kicks", "tick_kicks",
            "work_runs", "link_down"]
KDELTA = ["transaction_error_count", "send_drop_count", "late_response_count", "nack_retry_count",
          "remote_request_count", "transaction_count"]


def die(msg):
    sys.exit("summary: " + msg)


def need(p):
    if not os.path.exists(p):
        die("missing " + p)
    return p


def kv(path):
    d = {}
    for line in open(need(path)):
        if "=" in line and not line.startswith("dmesg: "):
            k, v = line.rstrip("\n").split("=", 1)
            d[k] = v
    return d


def instr(path):
    d = {}
    for line in open(need(path)):
        p = line.split()
        if len(p) == 2 and re.fullmatch(r"-?\d+", p[1]):
            d[p[0]] = int(p[1])
    return d


def recv_s(st):
    t = 0.0
    for k, v in st.items():
        if k.startswith("recv_thread."):
            m = re.match(r"(\d+) ticks \((\d+)/s\)", v)
            if m:
                t += int(m.group(1)) / int(m.group(2))
    return t


def busy_ns(ins):
    return sum(v for k, v in ins.items() if re.fullmatch(r"cxl_shm\.counters\.consumer\d+_busy_ns", k))


def num(d, k):
    try:
        return int(d.get(k, ""))
    except ValueError:
        return None


def cpu_delta(sd, k, mode):
    a, b = kv(os.path.join(sd, "status-pre-vm%d.txt" % k)), kv(os.path.join(sd, "status-post-vm%d.txt" % k))
    ia, ib = instr(os.path.join(sd, "instr-pre-vm%d.txt" % k)), instr(os.path.join(sd, "instr-post-vm%d.txt" % k))
    r = recv_s(b) - recv_s(a)
    bz = (busy_ns(ib) - busy_ns(ia)) / 1e9
    out = {"recv_s": r, "busy_s": bz, "coh_s": bz + (0 if mode == "idle" else r), "watcher_s": r if mode == "idle" else 0.0,
           "kthread_watch_ms": (ib.get("cxl_shm.counters.kthread_watch_ns", 0) - ia.get("cxl_shm.counters.kthread_watch_ns", 0)) / 1e6}
    for c in COUNTERS:
        x, y = num(a, "cxl_shm." + c), num(b, "cxl_shm." + c)
        out[c] = (y - x) if x is not None and y is not None else ""
    for c in KDELTA:
        x, y = num(a, "swmc." + c), num(b, "swmc." + c)
        out[c] = (y - x) if x is not None and y is not None else ""
    out["max_active"] = b.get("cxl_shm.max_active", "")
    pa, pb = pstat(os.path.join(sd, "procstat-pre-vm%d.txt" % k)), pstat(os.path.join(sd, "procstat-post-vm%d.txt" % k))
    for i, f in ((5, "irq_s"), (6, "softirq_s"), (7, "steal_s")):
        out[f] = (pb["cpu"][i] - pa["cpu"][i]) / pb["hz"]
    out["coh_cpu_total"] = out["coh_s"] + out["irq_s"] + out["softirq_s"]
    # per-consumer runs/msgs (module 13 /sys/kernel/cxl_shm/consumers; not reset by instr reset): deltas
    ca, cb = cons(os.path.join(sd, "consumers-pre-vm%d.txt" % k)), cons(os.path.join(sd, "consumers-post-vm%d.txt" % k))
    out["consumer_runs"] = sum(v for kk, v in cb.items() if kk.endswith("_runs")) - \
        sum(v for kk, v in ca.items() if kk.endswith("_runs"))
    out["consumer_msgs"] = sum(v for kk, v in cb.items() if kk.endswith("_msgs")) - \
        sum(v for kk, v in ca.items() if kk.endswith("_msgs"))
    return out


def pstat(path):
    """clk_tck line + /proc/stat; returns {"hz": N, "cpu": [user nice system idle iowait irq softirq steal ...]}"""
    d = {"hz": None, "cpu": None}
    for line in open(need(path)):
        p = line.split()
        if p and p[0] == "clk_tck":
            d["hz"] = int(p[1])
        elif p and p[0] == "cpu":
            d["cpu"] = [int(x) for x in p[1:]]
    if not d["hz"] or not d["cpu"]:
        die("bad " + path)
    return d


def cons(path):
    d = {}
    for line in open(need(path)):
        p = line.split()
        if len(p) == 2 and re.fullmatch(r"consumer\d+_(runs|msgs)", p[0]):
            d[p[0]] = int(p[1])
    return d


def fl(path, key):
    j = json.load(open(need(path)))
    p = j["passes"][key]
    td = j.get("instr", {}).get("thread_delta", {})
    op = "read" if key == "pass0_read" else "write"
    rounds = td.get(op + "_owner_h_rounds", 0)
    return {"p50_ns": p["p50_ns"], "p99_ns": p["p99_ns"], "mean_ns": p["mean_ns"], "max_ns": p["max_ns"],
            "H_ns": td.get(op + "_owner_h_ns", 0) / rounds if rounds else "",
            "WmH_ns": td.get(op + "_xport_ns", 0) / rounds if rounds else ""}


def main():
    E = sys.argv[1]
    OUT = sys.argv[2] if len(sys.argv) > 2 else E
    os.makedirs(OUT, exist_ok=True)
    rows = []
    sessions = sorted(d for d in os.listdir(E) if re.fullmatch(r"r[12]-(OLD|NEW|NEWP)", d))
    if not sessions:
        die("no session dirs in " + E)
    for s in sessions:
        rep, cfg = s.split("-", 1)
        sd = os.path.join(E, s)
        conf = kv(os.path.join(sd, "config.txt"))
        mode = conf["recv_mode"]
        for scen in conf["scenarios"].split():
            d = os.path.join(sd, scen.lower())
            row = {"repeat": rep, "config": cfg, "scenario": scen, "module": conf["module"], "recv_mode": mode,
                   "max_workers": conf.get("max_workers", "")}
            if scen in ("S1", "S2"):
                for kind, key in (("readM", "pass0_read"), ("writeI", "pass0_write")):
                    for m, v in fl(os.path.join(d, "vm0", "%s_%s.json" % (scen.lower(), kind)), key).items():
                        row["%s_%s" % (kind, m)] = v
                c = cpu_delta(d, 1, mode)
                for m, v in c.items():
                    row[m] = v
                if scen == "S2":
                    h = json.load(open(need(os.path.join(d, "vm1", "s2_hog.json"))))
                    hb = json.load(open(need(os.path.join(d, "vm1", "s2_hogbase.json"))))
                    row["hog_iter_s"] = h["iter_per_s"]
                    row["hog_base_iter_s"] = hb["iter_per_s"]
                    row["hog_s"] = h["elapsed_s"]
            else:
                sc = list(csv.DictReader(open(need(os.path.join(d, "summary.csv")))))
                if len(sc) != 1:
                    die("%s: %d S3 rows" % (d, len(sc)))
                for m in ("ops_s_total", "read_p50_ns", "read_p99_ns", "write_p50_ns", "write_p99_ns", "jain_all"):
                    row["s3_" + m] = sc[0][m]
                c0, c1 = cpu_delta(d, 0, mode), cpu_delta(d, 1, mode)
                for m in c0:
                    if m == "max_active":
                        row[m] = "%s/%s" % (c0[m], c1[m])
                    elif isinstance(c0[m], (int, float)) and isinstance(c1[m], (int, float)):
                        row[m] = c0[m] + c1[m]
                    else:
                        row[m] = ""
            rows.append(row)
    cols = []
    for r in rows:
        for k in r:
            if k not in cols:
                cols.append(k)
    with open(os.path.join(OUT, "results.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    def vals(cfg, scen, m):
        v = [r.get(m) for r in rows if r["config"] == cfg and r["scenario"] == scen]
        return [float(x) for x in v if x not in ("", None)]

    def ms(cfg, scen, m):
        v = vals(cfg, scen, m)
        if not v:
            return None, None, 0
        return statistics.mean(v), (statistics.stdev(v) if len(v) > 1 else 0.0), len(v)

    out = []
    metrics = {"S1": ["readM_p50_ns", "readM_p99_ns", "writeI_p50_ns", "writeI_p99_ns", "readM_H_ns", "readM_WmH_ns",
                      "coh_cpu_total", "coh_s", "irq_s", "softirq_s", "steal_s", "watcher_s", "fallback_expiries", "consumer_kicks", "consumer_msgs", "fallback_kicks"],
               "S2": ["readM_p50_ns", "readM_p99_ns", "writeI_p50_ns", "writeI_p99_ns", "readM_H_ns", "readM_WmH_ns",
                      "coh_cpu_total", "coh_s", "irq_s", "softirq_s", "steal_s", "watcher_s", "fallback_expiries", "hog_iter_s", "hog_base_iter_s", "fallback_arms",
                      "fallback_parks", "fallback_kicks", "stuck_kicks", "tick_kicks"],
               "S3": ["s3_ops_s_total", "s3_read_p99_ns", "s3_write_p99_ns", "coh_cpu_total", "coh_s", "irq_s", "softirq_s", "steal_s", "watcher_s", "fallback_expiries",
                      "scaleout_kicks", "stuck_kicks", "consumer_kicks", "consumer_msgs", "nack_retry_count"]}
    out.append("config scenario metric n mean sd values(r1 r2 ...)")
    for scen in ("S1", "S2", "S3"):
        for cfg in CFGS:
            for m in metrics[scen]:
                a, sd, n = ms(cfg, scen, m)
                if n:
                    out.append("%s %s %s %d %.6g %.3g %s" % (cfg, scen, m, n, a, sd,
                               " ".join("%.6g" % x for x in vals(cfg, scen, m))))
            ma = [r["max_active"] for r in rows if r["config"] == cfg and r["scenario"] == scen]
            if ma and scen == "S3":
                out.append("%s %s max_active(vm0/vm1, cumulative since load) %s" % (cfg, scen, " ".join(ma)))
    out.append("")
    out.append("decision rule (reports/P-popcorn-recv-scaleout.md §5, user-adopted 2026-10-18; NEW = module 13 defaults):")
    ok = True
    nrep = len(vals("OLD", "S1", "readM_p50_ns"))
    single = nrep == 1
    grades = []
    out.append("  repeats: %d (%s)" % (nrep, "CLEAR/MARGINAL thresholds" if single else "mean-based rule"))

    def chk(name, cond, detail, clear_pass=None, clear_fail=None):
        nonlocal ok
        ok = ok and bool(cond)
        g = ""
        if single:
            if cond and clear_pass:
                g = "CLEAR"
            elif not cond and clear_fail:
                g = "CLEAR"
            else:
                g = "MARGINAL"
            grades.append((bool(cond), g))
            g = " " + g
        out.append("  %s: %s%s (%s)" % (name, "PASS" if cond else "FAIL", g, detail))

    def det(m, scen, unit):
        o, n = vals("OLD", scen, m), vals("NEW", scen, m)
        mo = statistics.mean(o) if o else None
        mn = statistics.mean(n) if n else None
        txt = "OLD %s (mean %s), NEW %s (mean %s), NEW-OLD %s %s" % (
            " ".join("%.6g" % x for x in o), "%.6g" % mo if mo is not None else "-",
            " ".join("%.6g" % x for x in n), "%.6g" % mn if mn is not None else "-",
            "%+.6g" % (mn - mo) if mo is not None and mn is not None else "-", unit)
        return mo, mn, txt

    for kind in ("readM", "writeI"):
        o, n, t = det(kind + "_p50_ns", "S1", "ns")
        v = o is not None and n is not None
        chk("S1 %s p50 within +5 us of OLD" % kind, v and n <= o + 5000, t,
            v and n - o <= 2500, v and n - o >= 7500)
    for kind in ("readM", "writeI"):
        o, n, t = det(kind + "_p99_ns", "S2", "ns")
        v = o is not None and n is not None
        chk("S2 %s p99 not worse than OLD" % kind, v and n <= o, t, v and n <= 0.9 * o, v and n >= 1.1 * o)
    o, n, t = det("s3_ops_s_total", "S3", "ops/s")
    v = o is not None and n is not None
    chk("S3 throughput within 5 % of OLD or better", v and n >= 0.95 * o, t, v and n >= 1.025 * o, v and n <= 0.925 * o)
    oc = sum(ms("OLD", s_, "coh_cpu_total")[0] or 0 for s_ in ("S1", "S2", "S3"))
    nc = sum(ms("NEW", s_, "coh_cpu_total")[0] or 0 for s_ in ("S1", "S2", "S3"))
    ho, hn = ms("OLD", "S2", "hog_iter_s")[0], ms("NEW", "S2", "hog_iter_s")[0]
    chk("coherence CPU lower: coh_cpu_total = consumer/poll-thread CPU + irq + softirq (S1+S2+S3, mean per repeat; "
        "S1/S2 vm1 only, S3 both nodes)", nc < oc,
        "OLD %.4g s, NEW %.4g s, NEW-OLD %+.4g s; coh_s OLD %.4g NEW %.4g; fallback_expiries NEW %s" % (
            oc, nc, nc - oc, sum(ms("OLD", s_, "coh_s")[0] or 0 for s_ in ("S1", "S2", "S3")),
            sum(ms("NEW", s_, "coh_s")[0] or 0 for s_ in ("S1", "S2", "S3")),
            sum(ms("NEW", s_, "fallback_expiries")[0] or 0 for s_ in ("S1", "S2", "S3"))),
        nc <= 0.9 * oc, nc >= 1.1 * oc)
    out.append("  like-for-like: S2 hog iterations/s OLD %s, NEW %s" % (ho, hn))
    if ho and hn and ((nc < oc and hn < ho) or (nc >= oc and hn > ho)):
        out.append("  NOTE: coh_cpu_total and S2 hog iterations/s disagree (decide with the user)")
    out.append("  => all checks %s; the adoption itself is decided with the user" % ("PASS" if ok else "not all PASS"))
    if single:
        if any(g == "CLEAR" and not p for p, g in grades):
            out.append("DECISION KEEP (clear)")
        elif all(g == "CLEAR" and p for p, g in grades):
            out.append("DECISION ADOPT (clear)")
        else:
            out.append("DECISION MARGINAL: run R2")
    out.append("")
    out.append("sanity NEW-poll (module 13, recv_mode=poll max_workers=1 fallback_us=0 worker_spin_us=0) vs OLD, S1 "
               "(expected equal; information):")
    for kind in ("readM", "writeI"):
        o, n = ms("OLD", "S1", kind + "_p50_ns")[0], ms("NEWP", "S1", kind + "_p50_ns")[0]
        if o and n:
            out.append("  %s p50 OLD %.0f NEW-poll %.0f ns (%+.1f %%)%s" % (kind, o, n, 100 * (n - o) / o,
                       "  NOTE: > 5 %" if abs(n - o) > 0.05 * o else ""))
    open(os.path.join(OUT, "summary.txt"), "w").write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()

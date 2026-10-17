#!/usr/bin/env python3
"""P-popcorn recv13 comparison: Host-side summary of one evidence dir (reports/P-popcorn-recv13-packet.md).

Usage: p-popcorn-recv-summary.py <E>
Reads <E>/r<rep>-<cfg>/{config.txt, s1, s2, s3} written by recovery/P-popcorn-recv13-v1/run.sh and writes
  <E>/results.csv   one row per (repeat, config, scenario): latency, owner H / W-H, coherence CPU, counters, hogs
  <E>/summary.txt   mean +- sd per (config, scenario) over the repeats and the decision rule of
                    reports/P-popcorn-recv-scaleout.md §5 (adopted by the user 2026-10-18) as computed checks
Exit 1 if an expected file is missing (no partial summary).

Coherence CPU (seconds, per scenario window, delta of the post minus pre snapshots):
  recv_s     receive thread utime+stime (/proc/<pid>/stat, clock ticks): poll/sleep mode = consumer CPU,
             idle mode = the SCHED_IDLE watcher (reported apart as watcher_s, not counted as coherence CPU)
  busy_s     sum of instr consumer<i>_busy_ns (module 13 consumer work items, start -> return incl. spin)
  coh_s      = busy_s + (recv_s if recv_mode != idle else 0)
S1/S2 count the answering node vm1 (vm0 only requests); S3 counts both nodes.
"""
import csv
import json
import os
import re
import statistics
import sys

CFGS = ["OLD", "NEW", "NEWP", "NEW16"]
COUNTERS = ["consumer_kicks", "scaleout_kicks", "consumer_requeues", "consumer_rekicks", "fallback_arms",
            "fallback_kicks", "fallback_expiries", "idle_kicks", "tick_kicks", "work_runs", "link_down"]
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
    return out


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
    rows = []
    sessions = sorted(d for d in os.listdir(E) if re.fullmatch(r"r[123]-(OLD|NEW|NEWP|NEW16)", d))
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
    with open(os.path.join(E, "results.csv"), "w", newline="") as f:
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
                      "coh_s", "watcher_s", "consumer_kicks", "fallback_kicks"],
               "S2": ["readM_p50_ns", "readM_p99_ns", "writeI_p50_ns", "writeI_p99_ns", "readM_H_ns", "readM_WmH_ns",
                      "coh_s", "watcher_s", "hog_iter_s", "hog_base_iter_s", "fallback_arms", "fallback_kicks",
                      "tick_kicks"],
               "S3": ["s3_ops_s_total", "s3_read_p99_ns", "s3_write_p99_ns", "coh_s", "watcher_s", "scaleout_kicks",
                      "consumer_kicks", "nack_retry_count"]}
    out.append("config scenario metric n mean sd")
    for scen in ("S1", "S2", "S3"):
        for cfg in CFGS:
            for m in metrics[scen]:
                a, sd, n = ms(cfg, scen, m)
                if n:
                    out.append("%s %s %s %d %.6g %.3g" % (cfg, scen, m, n, a, sd))
            ma = [r["max_active"] for r in rows if r["config"] == cfg and r["scenario"] == scen]
            if ma and scen == "S3":
                out.append("%s %s max_active(vm0/vm1, cumulative since load) %s" % (cfg, scen, " ".join(ma)))
    out.append("")
    out.append("decision rule (reports/P-popcorn-recv-scaleout.md §5, user-adopted 2026-10-18; NEW = module 13 defaults):")
    ok = True

    def chk(name, cond, detail):
        nonlocal ok
        ok = ok and bool(cond)
        out.append("  %s: %s (%s)" % (name, "PASS" if cond else "FAIL", detail))

    for kind in ("readM", "writeI"):
        o, n = ms("OLD", "S1", kind + "_p50_ns")[0], ms("NEW", "S1", kind + "_p50_ns")[0]
        chk("S1 %s p50 within +5 us of OLD" % kind, o is not None and n is not None and n <= o + 5000,
            "OLD %s, NEW %s ns" % (o, n))
    for kind in ("readM", "writeI"):
        o, n = ms("OLD", "S2", kind + "_p99_ns")[0], ms("NEW", "S2", kind + "_p99_ns")[0]
        chk("S2 %s p99 not worse than OLD" % kind, o is not None and n is not None and n <= o, "OLD %s, NEW %s ns" % (o, n))
    o, n = ms("OLD", "S3", "s3_ops_s_total")[0], ms("NEW", "S3", "s3_ops_s_total")[0]
    chk("S3 throughput within 5 % of OLD or better", o is not None and n is not None and n >= 0.95 * o,
        "OLD %s, NEW %s ops/s" % (o, n))
    oc = sum(ms("OLD", s, "coh_s")[0] or 0 for s in ("S1", "S2", "S3"))
    nc = sum(ms("NEW", s, "coh_s")[0] or 0 for s in ("S1", "S2", "S3"))
    chk("coherence CPU lower (S1+S2+S3, mean per repeat)", nc < oc, "OLD %.3f s, NEW %.3f s" % (oc, nc))
    out.append("  => all checks %s; the adoption itself is decided with the user" % ("PASS" if ok else "not all PASS"))
    out.append("")
    out.append("sanity NEW-poll (module 13, recv_mode=poll max_workers=1) vs OLD, S1 (expected equal; information):")
    for kind in ("readM", "writeI"):
        o, n = ms("OLD", "S1", kind + "_p50_ns")[0], ms("NEWP", "S1", kind + "_p50_ns")[0]
        if o and n:
            out.append("  %s p50 OLD %.0f NEW-poll %.0f ns (%+.1f %%)%s" % (kind, o, n, 100 * (n - o) / o,
                       "  NOTE: > 5 %" if abs(n - o) > 0.05 * o else ""))
    out.append("S3 NEW (max_workers default) vs NEW16 (max_workers 16): ops/s %s vs %s" % (
        ms("NEW", "S3", "s3_ops_s_total")[0], ms("NEW16", "S3", "s3_ops_s_total")[0]))
    open(os.path.join(E, "summary.txt"), "w").write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()

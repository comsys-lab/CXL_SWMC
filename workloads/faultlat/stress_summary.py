#!/usr/bin/env python3
"""faultlat contend stress: Host-side summary of one evidence dir (p-popcorn-stress.sh layout).

Usage: stress_summary.py <R> [<R>...] > summary.csv
Reads <R>/<scenario>/{scenario.txt, rc.txt, status-pre-vm{0,1}.txt, status-post-vm{0,1}.txt,
dmesg-new-vm{0,1}.txt, vm{0,1}/<scenario>.json}; one row per scenario.  Missing files (e.g. no JSON after a
SIGBUS) give empty cells.  Latency quantiles merge both nodes' histograms (bucket upper bounds, <= 12.5 %).
"""
import csv
import json
import math
import pathlib
import re
import sys

KDELTA = ["transaction_count", "remote_request_count", "fault_count", "nack_retry_count", "request_busy_count",
          "send_retry_count", "local_wait_count", "remote_nack_count", "transaction_error_count", "send_drop_count",
          "late_response_count"]
SHM = ["stale_slots", "nack_on_drop"]


def kv(path):
    d = {}
    try:
        for line in open(path):
            if "=" in line and not line.startswith("dmesg: "):
                k, v = line.rstrip("\n").split("=", 1)
                d[k] = v
    except OSError:
        pass
    return d


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def recv_ticks(d):
    t = 0
    for k, v in d.items():
        if k.startswith("recv_thread."):
            t += int(v.split()[0])
    return t


def merged_quantiles(hists, ps):
    b = {}
    n = 0
    mx = 0
    for h in hists:
        if not h:
            continue
        n += h["count"]
        mx = max(mx, h["max_ns"])
        for up, c in h["hist"]:
            b[up] = b.get(up, 0) + c
    out = []
    for p in ps:
        if not n:
            out.append("")
            continue
        want = max(1, math.ceil(p * n))
        acc = 0
        for up in sorted(b):
            acc += b[up]
            if acc >= want:
                out.append(min(up, mx))
                break
    return out + [mx if n else ""]


def jain(xs):
    s1 = sum(xs)
    s2 = sum(x * x for x in xs)
    return round(s1 * s1 / (len(xs) * s2), 4) if s2 else ""


cols = ["scenario", "threads", "pages", "read_pct0", "read_pct1", "dist", "duration_s", "page_offset", "extra",
        "rc0", "rc1", "status0", "status1", "accept", "ops_s0", "ops_s1", "ops_s_total", "thread_ops_min",
        "thread_ops_max", "jain_all", "faults_per_op0", "faults_per_op1",
        "read_p50_ns", "read_p99_ns", "read_p999_ns", "read_max_ns",
        "write_p50_ns", "write_p99_ns", "write_p999_ns", "write_max_ns",
        "violations", "starvation_samples", "node_stall_samples", "global_stall_samples", "max_thread_zero_ms",
        "probe_checks", "churn_dontneed", "churn_remaps", "churn_errors"]
cols += ["%s_d%d" % (k, n) for k in KDELTA for n in (0, 1)]
cols += ["%s_d%d" % (k, n) for k in SHM for n in (0, 1)]
cols += ["recv_ticks_d0", "recv_ticks_d1", "dmesg_bad_new0", "dmesg_bad_new1", "host_build_procs"]

w = csv.DictWriter(sys.stdout, fieldnames=cols)
w.writeheader()
for root in sys.argv[1:]:
    for sd in sorted(p for p in pathlib.Path(root).iterdir() if (p / "scenario.txt").exists()):
        row = {}
        sc = kv(sd / "scenario.txt")
        for k in ("scenario", "threads", "pages", "read_pct0", "read_pct1", "dist", "duration_s", "page_offset",
                  "extra", "host_build_procs"):
            row[k] = sc.get(k, "")
        rc = kv(sd / "rc.txt")
        row["rc0"], row["rc1"], row["accept"] = rc.get("rc0", ""), rc.get("rc1", ""), rc.get("accept", "")
        js = []
        for n in (0, 1):
            f = sd / ("vm%d" % n) / (sc.get("scenario", "") + ".json")
            try:
                js.append(json.loads(f.read_text()))
            except (OSError, ValueError):
                js.append(None)
        tops = []
        for n, j in enumerate(js):
            if not j:
                continue
            r = j["result"]
            row["status%d" % n] = r["status"]
            row["ops_s%d" % n] = r["ops_per_s"]
            row["faults_per_op%d" % n] = r["faults_per_op"]
            tops += [t["reads"] + t["writes"] for t in j["threads"]]
        good = [j for j in js if j]
        if good:
            R = [j["result"] for j in good]
            row["ops_s_total"] = round(sum(r["ops_per_s"] for r in R), 1)
            row["thread_ops_min"] = min(tops) if tops else ""
            row["thread_ops_max"] = max(tops) if tops else ""
            row["jain_all"] = jain(tops) if tops else ""
            q = merged_quantiles([r["lat_read"] for r in R], (0.5, 0.99, 0.999))
            row.update(dict(zip(["read_p50_ns", "read_p99_ns", "read_p999_ns", "read_max_ns"], q)))
            q = merged_quantiles([r["lat_write"] for r in R], (0.5, 0.99, 0.999))
            row.update(dict(zip(["write_p50_ns", "write_p99_ns", "write_p999_ns", "write_max_ns"], q)))
            row["violations"] = sum(r["violations"]["total"] for r in R)
            for k in ("starvation_samples", "node_stall_samples", "global_stall_samples"):
                row[k] = sum(r[k] for r in R)
            row["max_thread_zero_ms"] = max(r["max_thread_zero_ms"] for r in R)
            row["probe_checks"] = sum(r["swmr_probe"]["checks"] for r in R)
            for k in ("dontneed", "remaps", "errors"):
                row["churn_" + k] = sum(r["churn"][k] for r in R)
        for n in (0, 1):
            a, b = kv(sd / ("status-pre-vm%d.txt" % n)), kv(sd / ("status-post-vm%d.txt" % n))
            for k in KDELTA:
                x, y = num(a.get("swmc." + k)), num(b.get("swmc." + k))
                row["%s_d%d" % (k, n)] = y - x if x is not None and y is not None else ""
            for k in SHM:
                x, y = num(a.get("cxl_shm." + k)), num(b.get("cxl_shm." + k))
                row["%s_d%d" % (k, n)] = y - x if x is not None and y is not None else ""
            if a and b:
                row["recv_ticks_d%d" % n] = recv_ticks(b) - recv_ticks(a)
            try:
                row["dmesg_bad_new%d" % n] = sum(1 for _ in open(sd / ("dmesg-bad-vm%d.txt" % n)))
            except OSError:
                row["dmesg_bad_new%d" % n] = ""
        w.writerow(row)

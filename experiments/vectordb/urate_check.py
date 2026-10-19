#!/usr/bin/env python3
"""Update-stream validity of one vector DB update-rate run (urate-block.sh; DESIGN.md §17). Adapted from
experiments/recsys/stream_check.py (RecSys methodology, user decisions 2026-10-19, state/PROJECT.md).

A measured step is VALID only if the writers kept up with the offered update stream (summed over both nodes):
  rate  write jobs finished in the window >= RATIO x write jobs accepted in it (d write_jobs_done / d
        write_jobs_accepted, server counters; default RATIO 0.98). Arrivals are Poisson, so the count sent in a window
        differs from R x dt by a few %; it is not compared with the nominal rate (done/s vs R is reported as
        nominal_ratio, information only). Accepted = received by the server's connection reader (open loop: = sent).
  lag   the backlog (write_backlog = accepted - done, both nodes) did not grow over the window: end - begin <=
        max(LAG_ABS, R x LAG_S) (defaults 50 updates, 1 s of updates), and the backlog at the window end is
        <= max(LAG_ABS, R x LAG_MAX_S) (default 5 s of updates).
Reported per step (stdout STEP lines, <run>/urate-check.csv): offered update rate, done/s, ratio, backlog begin/end,
write lag mean / window max (ms), writer busy fraction per node (writer_busy_ns / (window x writer_threads)), update
service time mean (update_ns / updates), segment write-lock wait per insert (insert_lock_ns_total / inserts), loadgen
update-stream achieved/s and search p95/p99 (ms).
Verdict (last line):
  URATECHECK PASS|NOTE|FAIL <run>: result=<max under SLO> ...
    PASS  every step at or below the SLO result (ramp/bisect passes <= result and the confirm repeats at the result)
          is valid
    NOTE  some of those steps are invalid: "update rate not sustained" (the result is reported, marked invalid), or
          no SLO result (fixed mode / note)
    FAIL  inputs missing (no steps, a judged step without both nodes' snapshots, a stats key missing, writer_threads
          differing between the nodes or from --writers)
usage: urate_check.py <run dir> [--ratio 0.98] [--lag-abs 50] [--lag-s 1] [--lag-max-s 5] [--writers N]
"""
import argparse
import csv
import glob
import json
import os
import re
import sys


def kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.rstrip("\n").split("=", 1)
            d[k] = v
    return d


def num(d, k):
    v = d.get(k)
    if v is None or not re.fullmatch(r"-?[0-9]+", v):
        raise KeyError(k)
    return int(v)


KEYS = ("t_mono_ns", "write_jobs_accepted", "write_jobs_done", "write_backlog", "write_lag_ns_sum", "write_lag_n",
        "write_lag_max_ns", "writer_threads", "writer_busy_ns", "updates", "update_ns", "inserts", "insert_lock_ns_total")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--ratio", type=float, default=0.98)
    ap.add_argument("--lag-abs", type=float, default=50)
    ap.add_argument("--lag-s", type=float, default=1.0)
    ap.add_argument("--lag-max-s", type=float, default=5.0)
    ap.add_argument("--writers", type=int, default=0, help="expected writer_threads on every node (0 = not checked)")
    a = ap.parse_args()
    lg = os.path.join(a.run, "loadgen")
    try:
        steps = [json.loads(l) for l in open(os.path.join(lg, "steps.jsonl")) if l.strip()]
    except OSError as e:
        print(f"URATECHECK FAIL {a.run}: {e}")
        return 1
    try:
        summ = json.load(open(os.path.join(lg, "summary.json")))
    except (OSError, ValueError):
        summ = {}
    targets = sorted({int(m.group(1)) for p in glob.glob(os.path.join(lg, "stats", "step*-end-t*.txt"))
                      for m in [re.search(r"-t(\d+)\.txt$", p)] if m})
    rows = []
    for st in steps:
        if not st.get("measure_s", 0) > 0:
            continue
        n = st["step"]
        upd = st["streams"].get("update", {})
        srch = st["streams"].get("search", {})
        R = float(upd.get("offered", 0))
        r = {"step": n, "phase": st["phase"], "offered_x": st["offered_x"], "pass": st["pass"], "update_offered": R,
             "lg_update_achieved": upd.get("achieved", ""), "search_p95_ms": srch.get("p95_ms", ""),
             "search_p99_ms": srch.get("p99_ms", ""), "reason": st.get("reason", "")}
        snaps = []
        for t in targets or [0, 1]:
            b = os.path.join(lg, "stats", f"step{n:03d}-begin-t{t}.txt")
            e = os.path.join(lg, "stats", f"step{n:03d}-end-t{t}.txt")
            if not (os.path.exists(b) and os.path.exists(e)):
                snaps = None
                break
            snaps.append((t, kv(b), kv(e)))
        if not snaps or len(snaps) < 2:
            r.update(valid=False, why="nostats")
            rows.append(r)
            continue
        acc = done = lag_b = lag_e = lns = ln = lmax = 0
        busy, svc, lock = [], [], []
        dts = []
        for t, B, E in snaps:
            try:
                vals = {k: (num(B, k), num(E, k)) for k in KEYS}
            except KeyError as k:
                print(f"URATECHECK FAIL {a.run}: step {n} target {t} stats key {k} missing (vdb build without §17 counters?)")
                return 1
            w = vals["writer_threads"][1]
            if vals["writer_threads"][0] != w or (a.writers and w != a.writers):
                print(f"URATECHECK FAIL {a.run}: step {n} target {t} writer_threads {vals['writer_threads']} (expected {a.writers or 'equal'})")
                return 1
            d = {k: v[1] - v[0] for k, v in vals.items()}
            dt = d["t_mono_ns"] / 1e9
            dts.append(dt)
            acc += d["write_jobs_accepted"]
            done += d["write_jobs_done"]
            lag_b += vals["write_backlog"][0]
            lag_e += vals["write_backlog"][1]
            lns += d["write_lag_ns_sum"]
            ln += d["write_lag_n"]
            lmax = max(lmax, vals["write_lag_max_ns"][1])  # window max (reset by every stats read)
            busy.append(round(d["writer_busy_ns"] / (dt * 1e9 * w), 4) if dt > 0 else 0)
            svc.append(round(d["update_ns"] / d["updates"] / 1e6, 3) if d["updates"] else 0)
            lock.append(round(d["insert_lock_ns_total"] / d["inserts"] / 1e6, 3) if d["inserts"] else 0)
            r["writer_threads"] = w
        dt = max(dts)
        ratio = done / acc if acc > 0 else 0
        rate = done / dt if dt > 0 else 0
        tol = max(a.lag_abs, R * a.lag_s)
        cap = max(a.lag_abs, R * a.lag_max_s)
        ok_rate = acc > 0 and ratio >= a.ratio
        ok_lag = lag_e - lag_b <= tol and lag_e <= cap
        why = [] if ok_rate else [f"done {done} < {a.ratio} x accepted {acc} write jobs"]
        if lag_e - lag_b > tol:
            why.append(f"backlog grew {lag_b} -> {lag_e} (> {tol:g})")
        if lag_e > cap:
            why.append(f"backlog {lag_e} > {cap:g}")
        r.update(valid=ok_rate and ok_lag, why="; ".join(why), window_s=round(dt, 3),
                 accepted_per_s=round(acc / dt, 3) if dt > 0 else 0, done_per_s=round(rate, 3),
                 done_ratio=round(ratio, 4), nominal_ratio=round(rate / R, 4) if R > 0 else 0,
                 backlog_begin=lag_b, backlog_end=lag_e, lag_ms_mean=round(lns / ln / 1e6, 3) if ln else 0,
                 lag_ms_max=round(lmax / 1e6, 3), writer_busy=" ".join(map(str, busy)),
                 update_service_ms=" ".join(map(str, svc)), insert_lock_wait_ms=" ".join(map(str, lock)))
        rows.append(r)
    if not rows:
        print(f"URATECHECK FAIL {a.run}: no measured steps")
        return 1
    cols = ["step", "phase", "offered_x", "pass", "reason", "valid", "why", "update_offered", "lg_update_achieved",
            "window_s", "accepted_per_s", "done_per_s", "done_ratio", "nominal_ratio", "backlog_begin", "backlog_end",
            "lag_ms_mean", "lag_ms_max", "writer_threads", "writer_busy", "update_service_ms", "insert_lock_wait_ms",
            "search_p95_ms", "search_p99_ms"]
    with open(os.path.join(a.run, "urate-check.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})
    for r in rows:
        print(f"STEP {r['step']} {r['phase']} x={r['offered_x']} pass={r['pass']} valid={r['valid']} "
              f"R={r['update_offered']} done={r.get('done_per_s', '-')}/s ratio={r.get('done_ratio', '-')} "
              f"backlog={r.get('backlog_begin', '-')}->{r.get('backlog_end', '-')} lag_ms={r.get('lag_ms_mean', '-')}"
              f"/{r.get('lag_ms_max', '-')} busy=[{r.get('writer_busy', '')}] svc_ms=[{r.get('update_service_ms', '')}] "
              f"lockwait_ms=[{r.get('insert_lock_wait_ms', '')}] p99={r['search_p99_ms']}"
              f"{' (' + r['why'] + ')' if r.get('why') else ''}")
    best = summ.get("max_offered_x_pass")
    if summ.get("mode") != "slo" or best is None:
        bad = [r for r in rows if not r["valid"]]
        print(f"URATECHECK NOTE {a.run}: no SLO result (mode {summ.get('mode')!r}, note {summ.get('note', '')!r}); "
              f"invalid steps {len(bad)}/{len(rows)}")
        return 0
    eps = 1e-9 * max(1.0, best)
    judged = [r for r in rows if (r["phase"] in ("ramp", "bisect") and r["pass"] and r["offered_x"] <= best + eps)
              or (r["phase"] == "confirm" and abs(r["offered_x"] - best) <= eps)]
    nost = [r["step"] for r in judged if r.get("why") == "nostats"]
    if nost:
        print(f"URATECHECK FAIL {a.run}: steps without stats snapshots at or below the result: {nost}")
        return 1
    bad = [r for r in judged if not r["valid"]]
    low = summ.get("low_rate_violations", [])
    tail = (f"result={best:g} judged_steps={len(judged)} invalid={[r['step'] for r in bad]} "
            f"low_rate_violations={len(low)} all_steps_invalid={sum(not r['valid'] for r in rows)}/{len(rows)}")
    if bad:
        print(f"URATECHECK NOTE {a.run}: update rate not sustained at or below the result: {tail}")
    else:
        print(f"URATECHECK PASS {a.run}: {tail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

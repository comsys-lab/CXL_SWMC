#!/usr/bin/env python3
"""Streaming-update validity of one RecSys measurement (recsys-server --update-mode stream; DESIGN.md §5.1).

RecSys methodology (user decisions 2026-10-19, state/PROJECT.md): a step is VALID only if the updater kept up with
the offered update stream:
  rate  samples fully written (by every worker) in the window >= RATIO x samples accepted in it: d published_seq /
        d update_accepted_seq (default RATIO 0.98). Arrivals are Poisson, so the count actually sent in a window
        differs from R x dt by a few % at 50 samples/s; it is not compared with the nominal rate (written/s vs R is
        reported as nominal_ratio, information only). Accepted = sent: the server acknowledges on acceptance.
  lag   the backlog (update_lag_samples = accepted seq - published_seq) did not grow over the window: end - begin <=
        max(LAG_ABS samples, R x LAG_S) (defaults 50 samples, 1 s of updates), and the backlog at the window end is
        <= max(LAG_ABS, R x LAG_MAX_S) (default 5 s of updates; a deficit below the growth tolerance accumulates
        over a lifetime)
Inputs: <run>/loadgen/steps.jsonl and the node-0 stats snapshots <run>/loadgen/stats/step<NNN>-{begin,end}-t0.txt
(loadgen --stats-op; target 0 = the updater node). Every measured step without both snapshots is "nostats" (invalid).
Outputs: <run>/stream-check.csv (one row per measured step) and lines on stdout:
  STEP ... per step, then
  STREAMCHECK PASS|NOTE|FAIL <run>: result=<max under SLO> ...
    PASS  every step at or below the SLO result (ramp/bisect passes <= result and the confirm repeats at the result)
          is valid
    NOTE  some of those steps are invalid: "update rate not sustained" (the result is reported, marked invalid)
    FAIL  inputs missing (no steps, a step without snapshots at or below the result, not stream mode)
usage: stream_check.py <run dir> [--ratio 0.98] [--lag-abs 50] [--lag-s 1] [--lag-max-s 5]
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--ratio", type=float, default=0.98)
    ap.add_argument("--lag-abs", type=float, default=50)
    ap.add_argument("--lag-s", type=float, default=1.0)
    ap.add_argument("--lag-max-s", type=float, default=5.0)
    a = ap.parse_args()
    lg = os.path.join(a.run, "loadgen")
    try:
        steps = [json.loads(l) for l in open(os.path.join(lg, "steps.jsonl")) if l.strip()]
    except OSError as e:
        print(f"STREAMCHECK FAIL {a.run}: {e}")
        return 1
    try:
        summ = json.load(open(os.path.join(lg, "summary.json")))
    except (OSError, ValueError):
        summ = {}
    rows, out = [], []
    for st in steps:
        if not st.get("measure_s", 0) > 0:
            continue
        n = st["step"]
        upd = st["streams"].get("update", {})
        R = float(upd.get("offered", 0))
        b = os.path.join(lg, "stats", f"step{n:03d}-begin-t0.txt")
        e = os.path.join(lg, "stats", f"step{n:03d}-end-t0.txt")
        r = {"step": n, "phase": st["phase"], "offered_x": st["offered_x"], "pass": st["pass"], "update_offered": R}
        if not (os.path.exists(b) and os.path.exists(e)):
            r.update(valid=False, why="nostats")
            rows.append(r)
            continue
        B, E = kv(b), kv(e)
        if E.get("update_mode") != "stream":
            print(f"STREAMCHECK FAIL {a.run}: step {n} server update_mode={E.get('update_mode')} (not stream)")
            return 1
        try:
            dt = (num(E, "stats_mono_ns") - num(B, "stats_mono_ns")) / 1e9
            pub = num(E, "published_seq") - num(B, "published_seq")
            acc = num(E, "update_accepted_seq") - num(B, "update_accepted_seq")
            rw = num(E, "rows_written") - num(B, "rows_written")
            lag_b, lag_e = num(B, "update_lag_samples"), num(E, "update_lag_samples")
            ln = num(E, "update_lag_n") - num(B, "update_lag_n")
            lns = num(E, "update_lag_ns_sum") - num(B, "update_lag_ns_sum")
            lmax = num(E, "update_lag_ns_max")  # max since the begin snapshot (reset by every stats read)
        except KeyError as k:
            print(f"STREAMCHECK FAIL {a.run}: step {n} stats key {k} missing")
            return 1
        qmax = max((int(v) for k, v in E.items() if k.startswith("update_queue.w")), default=0)
        written = pub / dt if dt > 0 else 0
        ratio = pub / acc if acc > 0 else 0
        tol = max(a.lag_abs, R * a.lag_s)
        ok_rate = acc > 0 and ratio >= a.ratio
        cap = max(a.lag_abs, R * a.lag_max_s)
        ok_lag = lag_e - lag_b <= tol and lag_e <= cap
        why = [] if ok_rate else [f"written {pub} < {a.ratio} x accepted {acc} samples"]
        if lag_e - lag_b > tol:
            why.append(f"backlog grew {lag_b} -> {lag_e} samples (> {tol:g})")
        if lag_e > cap:
            why.append(f"backlog {lag_e} samples > {cap:g}")
        r.update(valid=ok_rate and ok_lag, why="; ".join(why), window_s=round(dt, 3), accepted_per_s=round(acc / dt, 3) if dt > 0 else 0,
                 written_per_s=round(written, 3), written_ratio=round(ratio, 4), nominal_ratio=round(written / R, 4) if R > 0 else 0, rows_written_per_s=round(rw / dt, 1) if dt > 0 else 0,
                 lag_samples_begin=lag_b, lag_samples_end=lag_e, lag_ms_mean=round(lns / ln / 1e6, 3) if ln else 0,
                 lag_ms_max=round(lmax / 1e6, 3), queue_max_end=qmax)
        rows.append(r)
    if not rows:
        print(f"STREAMCHECK FAIL {a.run}: no measured steps")
        return 1
    cols = ["step", "phase", "offered_x", "pass", "valid", "why", "update_offered", "window_s", "accepted_per_s",
            "written_per_s", "written_ratio", "nominal_ratio", "rows_written_per_s", "lag_samples_begin", "lag_samples_end", "lag_ms_mean",
            "lag_ms_max", "queue_max_end"]
    with open(os.path.join(a.run, "stream-check.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in cols})
    for r in rows:
        print(f"STEP {r['step']} {r['phase']} x={r['offered_x']} pass={r['pass']} valid={r['valid']} "
              f"written={r.get('written_per_s', '-')}/s ratio={r.get('written_ratio', '-')} lag={r.get('lag_samples_begin', '-')}"
              f"->{r.get('lag_samples_end', '-')} lag_ms_mean={r.get('lag_ms_mean', '-')}{' (' + r['why'] + ')' if r.get('why') else ''}")
    best = summ.get("max_offered_x_pass")
    if best is None:
        bad = [r for r in rows if not r["valid"]]
        print(f"STREAMCHECK NOTE {a.run}: no SLO result (note {summ.get('note', '')!r}); invalid steps {len(bad)}/{len(rows)}")
        return 0
    eps = 1e-9 * max(1.0, best)
    judged = [r for r in rows if (r["phase"] in ("ramp", "bisect") and r["pass"] and r["offered_x"] <= best + eps)
              or (r["phase"] == "confirm" and abs(r["offered_x"] - best) <= eps)]
    nost = [r["step"] for r in judged if r.get("why") == "nostats"]
    if nost:
        print(f"STREAMCHECK FAIL {a.run}: steps without stats snapshots at or below the result: {nost}")
        return 1
    bad = [r for r in judged if not r["valid"]]
    low = summ.get("low_rate_violations", [])
    tail = (f"result={best:g} judged_steps={len(judged)} invalid={[r['step'] for r in bad]} "
            f"low_rate_violations={len(low)} all_steps_invalid={sum(not r['valid'] for r in rows)}/{len(rows)}")
    if bad:
        print(f"STREAMCHECK NOTE {a.run}: update rate not sustained at or below the result: {tail}")
    else:
        print(f"STREAMCHECK PASS {a.run}: {tail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

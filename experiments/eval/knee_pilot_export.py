#!/usr/bin/env python3
"""Knee-sweep pilot export (workspaces/knee-sweep-design/DESIGN.md §3 "Pilot"): one CSV row per fixed-rate step.

usage: knee_pilot_export.py <evidence dir | loadgen dir> ... [--out DIR]
  evidence dir: recovery/knee-sweep-pilot-v<V> (every <E>/block/<sys>-<mix>-n<N>/<part>/loadgen); a loadgen dir (has
  steps.jsonl) is read as is. --out default workspaces/popcorn-lock-split/derived/<evidence dir name>. Read only.
Output knee-pilot.csv, columns: lifetime, system, part, step, offered_x (loadgen --rates value: total ops/s),
  offered_search_s, achieved_search_s (= x), achieved_update_s, search_sent, search_done, timeouts, errors, p50_ms,
  p99_ms, p999_ms, max_ms (search, whole window, from steps.jsonl), p99_over_slo (p99 / 100 ms), p99_third1..3_ms (search
  p99 of the measured requests in consecutive thirds of the window by scheduled time, raw rows; not completed = inf),
  thirds_ratio (third 3 / third 1), stationary (thirds_ratio <= 1.5), p99_first30s_ms (first 30 s of the window: the
  30 s vs 45 s question), update_p99_ms, aborted, reason. Raw-row method = knee-sweep-design/raw_windows.py.
"""
import csv
import glob
import json
import math
import os
import struct
import sys

P = "/home/comsys/sungsu/destijl-control"
SLO_MS = 100.0


def p99(v):
    if not v:
        return None
    v = sorted(v)
    return v[max(0, math.ceil(0.99 * len(v)) - 1)]


def raw_split(path, sent):
    """thirds p99 and first-30 s p99 (ms) of the search stream's measured requests"""
    if not os.path.exists(path):
        return [None] * 3, None
    b = open(path, "rb").read()
    rows = [struct.unpack_from("<4Q", b, i) for i in range(0, len(b) - 31, 32)]
    meas = [(s, d, (m >> 32) & 0xff) for s, _, d, m in rows if (m >> 40) & 1]
    cnt = {}
    for r in meas:
        cnt[r[2]] = cnt.get(r[2], 0) + 1
    if not cnt:
        return [None] * 3, None
    si = min(cnt, key=lambda x: abs(cnt[x] - sent))  # search stream = the one with search.sent measured requests
    sr = sorted((s, (d - s) / 1e6 if d else math.inf) for s, d, k in meas if k == si)
    t0, t1 = sr[0][0], sr[-1][0]
    th = [p99([l for t, l in sr if t0 + j * (t1 - t0) / 3 <= t < t0 + (j + 1) * (t1 - t0) / 3 + (j == 2)]) for j in range(3)]
    return th, p99([l for t, l in sr if t < t0 + 30e9])


def r(x, d=3):
    if x is None:
        return ""
    if isinstance(x, float) and math.isinf(x):
        return "inf"
    return round(x, d)


def main():
    a = sys.argv[1:]
    out = None
    if "--out" in a:
        i = a.index("--out")
        out = a[i + 1]
        del a[i:i + 2]
    if not a:
        sys.exit(__doc__)
    lgs = []
    for x in a:
        if os.path.isfile(os.path.join(x, "steps.jsonl")):
            lgs.append(("-", os.path.basename(os.path.dirname(os.path.normpath(x))), x))
        for d in sorted(glob.glob(os.path.join(x, "block", "*-n[0-9]*", "*", "loadgen"))):
            life = os.path.basename(os.path.dirname(os.path.dirname(d)))
            lgs.append((life, os.path.basename(os.path.dirname(d)), d))
    if not lgs:
        sys.exit("no loadgen dirs found")
    out = out or os.path.join(P, "workspaces/popcorn-lock-split/derived", os.path.basename(os.path.normpath(a[0])))
    os.makedirs(out, exist_ok=True)
    cols = ["lifetime", "system", "part", "step", "offered_x", "offered_search_s", "achieved_search_s", "achieved_update_s",
            "search_sent", "search_done", "timeouts", "errors", "p50_ms", "p99_ms", "p999_ms", "max_ms", "p99_over_slo",
            "p99_third1_ms", "p99_third2_ms", "p99_third3_ms", "thirds_ratio", "stationary", "p99_first30s_ms",
            "update_p99_ms", "aborted", "reason"]
    rows = []
    for life, part, d in lgs:
        sysname = life.split("-")[0]
        for line in open(os.path.join(d, "steps.jsonl")):
            s = json.loads(line)
            if s.get("phase") != "fixed":
                continue
            q = s["streams"].get("search", {})
            u = s["streams"].get("update", {})
            th, f30 = raw_split(os.path.join(d, f"raw-step{s['step']}.bin"), q.get("sent", 0))
            ratio = th[2] / th[0] if th[0] and th[2] is not None and not math.isinf(th[0]) else None
            p = q.get("p99_ms")
            rows.append([life, sysname, part, s["step"], s["offered_x"], q.get("offered"), q.get("achieved"), u.get("achieved"),
                         q.get("sent"), q.get("done"), q.get("timeouts"), q.get("errors"), r(q.get("p50_ms")), r(p),
                         r(q.get("p999_ms")), r(q.get("max_ms")), r(p / SLO_MS if p is not None else None),
                         r(th[0]), r(th[1]), r(th[2]), r(ratio), "" if ratio is None else int(ratio <= 1.5) if not math.isinf(ratio) else 0,
                         r(f30), r(u.get("p99_ms")), int(bool(s.get("aborted"))), s.get("reason", "")])
    with open(os.path.join(out, "knee-pilot.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        w.writerows(rows)
    for x in rows:
        print(f"{x[0]:14s} {x[2]:6s} step {x[3]:2d} offered {x[4]:8.2f} x {x[6]} p99 {x[13]} ms thirds {x[17]}/{x[18]}/{x[19]} "
              f"stationary {x[21]} aborted {x[24]} {x[25]}")
    print(f"knee_pilot_export: {len(rows)} steps -> {out}/knee-pilot.csv")


if __name__ == "__main__":
    main()

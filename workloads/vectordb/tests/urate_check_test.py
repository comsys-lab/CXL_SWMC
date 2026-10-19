#!/usr/bin/env python3
"""Unit test of experiments/vectordb/urate_check.py on synthetic run dirs (Host, no servers).
usage: urate_check_test.py <scratch dir (must not exist)>   -> prints URATE CHECK TEST PASS|FAIL
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHK = os.path.join(HERE, "..", "..", "..", "experiments", "vectordb", "urate_check.py")


def snap(acc, done, backlog, t_s, writers=4, lagmax=5_000_000, drop=None):
    d = {"t_mono_ns": int(t_s * 1e9), "write_jobs_accepted": acc, "write_jobs_done": done, "write_backlog": backlog,
         "write_lag_ns_sum": done * 1_000_000, "write_lag_n": done, "write_lag_max_ns": lagmax, "writer_threads": writers,
         "writer_busy_ns": int(t_s * 1e9 * 0.4 * writers), "updates": done, "update_ns": done * 3_000_000,
         "inserts": done, "insert_lock_ns_total": done * 10_000}
    if drop:
        d.pop(drop)
    return "# when=x\n" + "".join(f"{k}={v}\n" for k, v in d.items())


def make(root, name, steps, summary, stats):
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "loadgen", "stats"))
    with open(os.path.join(d, "loadgen", "steps.jsonl"), "w") as f:
        for s in steps:
            f.write(json.dumps(s) + "\n")
    json.dump(summary, open(os.path.join(d, "loadgen", "summary.json"), "w"))
    for (n, t, w), txt in stats.items():
        open(os.path.join(d, "loadgen", "stats", f"step{n:03d}-{w}-t{t}.txt"), "w").write(txt)
    return d


def step(n, phase, x, ok, R=1000):
    return {"step": n, "phase": phase, "offered_x": x, "pass": ok, "measure_s": 15,
            "streams": {"update": {"offered": R, "achieved": R}, "search": {"achieved": x, "p95_ms": 10, "p99_ms": 20}}}


def run(d, *extra):
    p = subprocess.run([sys.executable, CHK, d, *extra], capture_output=True, text=True)
    return p.returncode, p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.stderr


def main():
    root = sys.argv[1]
    os.makedirs(root)
    bad = []
    summ = {"mode": "slo", "max_offered_x_pass": 20, "low_rate_violations": []}
    steps = [step(1, "ramp", 10, True), step(2, "ramp", 20, True), step(3, "ramp", 30, False), step(4, "confirm", 20, True)]

    def stats(per_node_done_frac=1.0, backlog_end=3, drop=None, writers=(4, 4), skip=None):
        st = {}
        for n in (1, 2, 3, 4):
            for t in (0, 1):
                if skip == (n, t):
                    continue
                acc0, t0 = 100000 * n, 100.0 * n
                acc1 = acc0 + 7500
                done1 = acc0 + int(7500 * per_node_done_frac)
                st[(n, t, "begin")] = snap(acc0, acc0, 2, t0, writers[t], drop=drop)
                st[(n, t, "end")] = snap(acc1, done1, backlog_end, t0 + 15, writers[t], drop=drop)
        return st

    cases = [
        ("pass", stats(), [], 0, "URATECHECK PASS"),
        ("ratio", stats(per_node_done_frac=0.95), [], 0, "URATECHECK NOTE"),
        ("backlog_growth", stats(backlog_end=1200), [], 0, "URATECHECK NOTE"),  # grew 4 -> 2400 > 1000 (R x 1 s)
        ("nostats_judged", stats(skip=(2, 1)), [], 1, "URATECHECK FAIL"),
        ("missing_key", stats(drop="write_backlog"), [], 1, "URATECHECK FAIL"),
        ("writers_expected", stats(), ["--writers", "8"], 1, "URATECHECK FAIL"),
        ("writers_ok", stats(), ["--writers", "4"], 0, "URATECHECK PASS"),
    ]
    for name, st, extra, rc_want, head in cases:
        d = make(root, name, steps, summ, st)
        rc, last = run(d, *extra)
        ok = rc == rc_want and last.startswith(head)
        print(f"{name}: rc={rc} {last[:160]} -> {'ok' if ok else 'WRONG'}")
        if not ok:
            bad.append(name)
    # failed step above the result with invalid stats is not judged; fixed mode -> NOTE
    d = make(root, "fixed", [step(1, "fixed", 20, True)], {"mode": "fixed"}, {k: v for k, v in stats().items() if k[0] == 1})
    rc, last = run(d)
    ok = rc == 0 and last.startswith("URATECHECK NOTE") and "no SLO result" in last
    print(f"fixed: rc={rc} {last[:120]} -> {'ok' if ok else 'WRONG'}")
    if not ok:
        bad.append("fixed")
    print("URATE CHECK TEST " + ("PASS" if not bad else "FAIL " + " ".join(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

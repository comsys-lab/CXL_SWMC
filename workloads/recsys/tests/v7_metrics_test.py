#!/usr/bin/env python3
"""Unit test of tools/v7_metrics.py on a synthetic loadgen dir (no server, no VM).
Two steps; step 1 has 4 queries x 3 samples, step 2 one query; stale logs with known stale reads and ages;
checks samples_scored, auc against tools/auc.py, stale_read_frac, ages, updater CPU, auc_run.csv and the frozen join.
usage: v7_metrics_test.py <new work dir>"""
import csv
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
T = os.path.join(os.path.dirname(HERE), "tools")
sys.path.insert(0, T)
import v7_metrics as vm  # noqa: E402
from auc import roc_auc  # noqa: E402

wd = sys.argv[1]
os.makedirs(os.path.join(wd, "loadgen", "stats"))
lg = os.path.join(wd, "loadgen")


def w(path, magic, arr):
    with open(path, "wb") as f:
        h = bytearray(64)
        h[:8] = magic
        h[8:16] = np.uint64(len(arr)).tobytes()
        f.write(bytes(h))
        arr.tofile(f)


S = 1_000_000_000
W0 = 1_800_000_000 * S  # wall clock base
for t in (0, 1):  # step n window: mono [n*100 s, n*100 + 50 s], wall = W0 + same
    for n in (1, 2):
        for when, off in (("begin", 0), ("end", 50)):
            m = n * 100 * S + off * S
            cpu = (n * 1000 + off * 2) * 10**9 // 100 * 100 if t == 0 else 0  # 2 s/s inside the window
            with open(os.path.join(lg, "stats", f"step{n:03d}-{when}-t{t}.txt"), "w") as f:
                f.write(f"# when={when} phase=ramp step={n} offered_x=1 target={t} addr=x status=0 wall_ns={W0 + m} "
                        f"mono_ns={m} rtt_us=1\nupdater_cpu_ns={cpu}\n")
rng = np.random.default_rng(1)
n_sc = 15
sc = np.zeros(n_sc, vm.SCR)
sc["sample"] = np.arange(n_sc) + 5
sc["score"] = rng.random(n_sc).astype(np.float32)
sc["label"] = np.array([1, 0] * 7 + [1], np.uint8)
sc["measured"] = 1
sq = np.zeros(6, vm.SCQ)
# step 1: queries 0-3 (made at 110..140 s), query 4 unmeasured inside step 1; step 2: query 5 at 120+100 s
for i, (tm, first, meas) in enumerate([(110, 0, 1), (120, 3, 1), (130, 6, 1), (140, 9, 1), (145, 12, 0), (220, 12, 1)]):
    sq[i] = (i, tm * S, first, 3, 0, meas, 0)
w(os.path.join(lg, "scores.bin"), b"RSYSSCR1", sc)
w(os.path.join(lg, "scoreq.bin"), b"RSYSSCQ1", sq)
# writes: row 7 seq 10 at 105 s, seq 20 at 120 s; row 9 seq 5 at 101 s. Reads in step 1: row 7 seq 10 at 125 s
# (stale, age 5 s), row 7 seq 20 at 126 s (fresh), row 9 seq 5 at 130 s (fresh), row 11 seq 0 (never written, fresh)
wr = np.array([(7, 10, W0 + 105 * S), (7, 20, W0 + 120 * S), (9, 5, W0 + 101 * S)], vm.STL)
rd = np.array([(7, 10, W0 + 125 * S), (7, 20, W0 + 126 * S), (9, 5, W0 + 130 * S), (11, 0, W0 + 131 * S),
               (7, 10, W0 + 230 * S)], vm.STL)  # step 2: one stale read, age 110 s
w(os.path.join(wd, "s0.stl"), b"RSYSSTL1", wr)
w(os.path.join(wd, "s1.stl"), b"RSYSSTL1", rd)
fz = np.zeros(100, vm.SCR)
fz["sample"] = np.arange(100)
fz["score"] = rng.random(100).astype(np.float32)
fz["label"] = 0
fz["label"][sc["sample"]] = sc["label"]
w(os.path.join(wd, "frozen.scr"), b"RSYSSCR1", fz)
steps = os.path.join(wd, "steps.csv")
with open(steps, "w") as f:
    f.write("label,step,stream\nx,1,query\nx,1,update\nx,2,query\n")
auc_run = os.path.join(wd, "auc_run.csv")
cmd = [sys.executable, "-I", "-B", os.path.join(T, "v7_metrics.py"), wd, "--stale0", os.path.join(wd, "s0.stl"),
       "--stale1", os.path.join(wd, "s1.stl"), "--frozen", os.path.join(wd, "frozen.scr"), "--trace-n", "100",
       "--merge-steps", steps, "--auc-run", auc_run, "--system", "pop", "--update-rate", "200", "--T", "0",
       "--fresh", "0.9"]
print(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout, end="")
fail = []
rows = list(csv.DictReader(open(steps)))
r1 = [r for r in rows if r["step"] == "1"]
if len(r1) != 2 or r1[0]["samples_scored"] != "12":
    fail.append(f"step 1 samples_scored {r1[0]['samples_scored'] if r1 else None}")
want = roc_auc(sc["label"][:12], sc["score"][:12])
if abs(float(r1[0]["auc"]) - want) > 1e-5:
    fail.append(f"auc {r1[0]['auc']} != {want}")
if abs(float(r1[0]["stale_read_frac"]) - 0.25) > 1e-9:
    fail.append(f"stale frac {r1[0]['stale_read_frac']}")
if abs(float(r1[0]["stale_age_p50_ms"]) - 5000) > 1e-6 or abs(float(r1[0]["stale_age_max_ms"]) - 5000) > 1e-6:
    fail.append(f"stale age {r1[0]['stale_age_p50_ms']} {r1[0]['stale_age_max_ms']}")
if abs(float(r1[0]["updater_cpu_s_per_s"]) - 2.0) > 1e-6:
    fail.append(f"updater cpu {r1[0]['updater_cpu_s_per_s']}")
r2 = [r for r in rows if r["step"] == "2"][0]
if r2["samples_scored"] != "3" or abs(float(r2["stale_read_frac"]) - 1) > 1e-9 or abs(float(r2["stale_age_max_ms"]) - 110000) > 1e-3:
    fail.append(f"step 2 {r2}")
ar = list(csv.DictReader(open(auc_run)))[0]
idx = np.r_[0:12, 12:15]
fa = roc_auc(fz["label"][sc["sample"][idx]], fz["score"][sc["sample"][idx]])
a = roc_auc(sc["label"][idx], sc["score"][idx])
if ar["samples_scored"] != "15" or abs(float(ar["auc_frozen"]) - fa) > 1e-5 or \
        abs(float(ar["gain_retained"]) - (a - fa) / (0.9 - fa)) > 1e-4:
    fail.append(f"auc_run {ar}")
print("V7 METRICS TEST " + ("PASS" if not fail else "FAIL: " + "; ".join(fail)))
sys.exit(1 if fail else 0)

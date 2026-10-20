#!/usr/bin/env python3
"""Receive-mode check of the Popcorn lifetimes of one evaluation block dir (Host only, read-only; recv-sleep experiment,
reports/experiments/recv-sleep.md).

usage: recv_check.py <dir> --mode poll|idle|sleep [--out FILE]
<dir> = a dir holding the per-lifetime files the blocks write side by side (vector DB: <E>/vdb/r1/run, RecSys:
<E>/block): recv-mode-<name>.txt (m4-run.sh / main-block.sh: "<ip> recv_mode=<m> ..." per VM after the sysfs write)
and shm-<name>/ (p-popcorn-shm.sh: status-pre/post-vm<k>.txt, teardown-vm<k>.txt).
FAIL (exit 1): no Popcorn lifetime; a recv-mode file without exactly two VM lines of --mode; a status-pre/post file whose
  param.recv_mode is not --mode; a lifetime without "unload OK" on both VMs (the unload is what returns the receiver
  to the module default poll for the next load); --mode sleep: a stats-steps.csv of the lifetime without the per-step
  receive counters (kthread_{work,idle,sleep}_ns of /sys/kernel/cxl_shm/instr/counters; sleep_wakeups, tick_kicks of
  /sys/kernel/cxl_shm) - the vector DB server always snapshots both dirs, RecSys needs RS_PROC_CXL_SHM=1.
Prints per lifetime and VM the post - pre deltas of sleep_wakeups, tick_kicks and the cxl_recv thread CPU ticks.
Last line "RECVCHECK PASS|FAIL <n> lifetimes"; also written to --out (default <dir>/recv-check.txt).
"""
import argparse
import csv
import glob
import os
import re
import sys

PER_STEP = ("instr.counters.kthread_work_ns", "instr.counters.kthread_idle_ns", "instr.counters.kthread_sleep_ns",
            "cxl_shm.sleep_wakeups", "cxl_shm.tick_kicks")


def kv(path):
    out = {}
    if os.path.isfile(path):
        for line in open(path, errors="replace"):
            if "=" in line and not line.startswith("dmesg:"):
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


def ticks(d):
    return sum(int(re.match(r"\d+", v).group()) for k, v in d.items() if k.startswith("recv_thread.") and re.match(r"\d+", v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--mode", required=True, choices=("poll", "idle", "sleep"))
    ap.add_argument("--out")
    a = ap.parse_args()
    D, out, bad = a.dir, [], 0

    def fail(msg):
        nonlocal bad
        bad += 1
        out.append("FAIL " + msg)

    names = sorted(os.path.basename(p)[len("recv-mode-"):-len(".txt")] for p in glob.glob(os.path.join(D, "recv-mode-*.txt")))
    if not names:
        fail(f"no recv-mode-*.txt in {D} (no Popcorn lifetime)")
    for n in names:
        lines = [x.split() for x in open(os.path.join(D, f"recv-mode-{n}.txt")) if x.strip()]
        modes = [next((t.split("=", 1)[1] for t in x if t.startswith("recv_mode=")), None) for x in lines]
        if len(lines) != 2 or len({x[0] for x in lines}) != 2 or any(m != a.mode for m in modes):
            fail(f"{n}: recv-mode lines {lines} (want two VMs with recv_mode={a.mode})")
        shm = os.path.join(D, f"shm-{n}")
        for k in (0, 1):
            pre, post = kv(os.path.join(shm, f"status-pre-vm{k}.txt")), kv(os.path.join(shm, f"status-post-vm{k}.txt"))
            for tag, st in (("pre", pre), ("post", post)):
                if st.get("param.recv_mode") != a.mode:
                    fail(f"{n} vm{k}: status-{tag} param.recv_mode={st.get('param.recv_mode')}")
            td = os.path.join(shm, f"teardown-vm{k}.txt")
            if not (os.path.isfile(td) and "unload OK" in open(td, errors="replace").read()):
                fail(f"{n} vm{k}: no 'unload OK' in {td} (receiver not returned to the module default)")
            d = {c: int(post.get(f"cxl_shm.{c}", 0) or 0) - int(pre.get(f"cxl_shm.{c}", 0) or 0)
                 for c in ("sleep_wakeups", "tick_kicks")}
            out.append(f"{n} vm{k}: sleep_wakeups {d['sleep_wakeups']} tick_kicks {d['tick_kicks']} "
                       f"recv_thread_ticks {ticks(post) - ticks(pre)} (status post - pre)")
        parts = sorted(glob.glob(os.path.join(D, n, "*", "stats-steps.csv")))
        for p in parts:
            cols = next(csv.reader(open(p)), [])
            miss = [c for c in PER_STEP if not any(x.endswith(c) for x in cols)]
            rel = os.path.relpath(p, D)
            if miss and a.mode == "sleep":
                fail(f"{rel}: no per-step column for {', '.join(miss)}")
            else:
                out.append(f"{rel}: per-step receive counters {'present' if not miss else 'missing ' + ','.join(miss)}")
        if not parts:
            out.append(f"{n}: no stats-steps.csv parts (lifetime dir {os.path.join(D, n)})")
    out.append(f"RECVCHECK {'PASS' if not bad else 'FAIL'} {len(names)} lifetimes (mode {a.mode}; {bad} failures)")
    text = "\n".join(out) + "\n"
    with open(a.out or os.path.join(D, "recv-check.txt"), "w") as f:
        f.write(text)
    sys.stdout.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

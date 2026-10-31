#!/usr/bin/env python3
"""Receive-mode check of the Popcorn and De Stijl lifetimes of one evaluation block dir (Host only, read-only;
recv-sleep experiment, reports/experiments/recv-sleep.md; De Stijl v2 lifetimes, systems/destijl/system.yaml).

usage: recv_check.py <dir> --mode poll|idle|sleep [--out FILE]
<dir> = a dir holding the per-lifetime files the blocks write side by side (vector DB: <E>/vdb/r1/run or an h2n / h3
block dir, RecSys: <E>/block): recv-mode-<name>.txt (m4-run.sh / main-block.sh / h2n-block.sh / h3-block.sh:
"<ip> recv_mode=<m> ..." per VM after the sysfs write) and the cxl_shm status dir of the lifetime: shm-<name>/
(Popcorn, p-popcorn-shm.sh) or dsshm-<name>/ (De Stijl, p-destijl-shm.sh): status-pre/post-vm<k>.txt,
teardown-vm<k>.txt. A lifetime with both dirs is a FAIL. The VMs of a lifetime are the status-pre-vm<k>.txt files of
its dir (2 for the 2-VM blocks, N for h2n / h3; none: vm0, vm1 expected).
FAIL (exit 1), every lifetime: no lifetime at all; a recv-mode file without exactly one line of --mode per VM (distinct
  VMs, at least two); a status-pre/post file whose param.recv_mode is not --mode; a VM without "unload OK" in its
  teardown file (the unload is what returns the receiver to the module default poll for the next load); --mode sleep:
  a stats-steps.csv of the lifetime without the per-step receive counters (kthread_{work,idle,sleep}_ns of
  /sys/kernel/cxl_shm/instr/counters; sleep_wakeups, tick_kicks of /sys/kernel/cxl_shm) - the vector DB server always
  snapshots both dirs, RecSys needs RS_PROC_CXL_SHM=1.
FAIL, De Stijl lifetimes (dsshm-<name>) additionally: a status-pre/post file whose cxl_shm.state is not the cxl_shm v13
  line "running registered 1", whose swmc.protocol is not destijl, or without the De Stijl counters ds.tx_timeout,
  ds.protocol_error, ds.async_issued, ds.async_fallback_mean, ds.async_fallback_p95 (/sys/kernel/swmc/destijl);
  no receive thread (recv_thread.*) in status-post (receiver not on a CPU); a tx_timeout or protocol_error delta
  (post - pre) != 0 on any VM; a stats-steps.csv of the lifetime without per-step sys.swmc.destijl.* columns.
Prints per lifetime and VM the post - pre deltas of sleep_wakeups, tick_kicks and the cxl_recv thread CPU ticks; per De
Stijl lifetime ds_async_share = async_issued / (async_issued + async_fallback_mean + async_fallback_p95) over the
status post - pre deltas of all VMs (experiments/eval/canon.py DS_COH; "n/a" when the denominator is 0).
Last line "RECVCHECK PASS|FAIL <n> lifetimes (...)"; also written to --out (default <dir>/recv-check.txt).
"""
import argparse
import csv
import glob
import os
import re
import sys

PER_STEP = ("instr.counters.kthread_work_ns", "instr.counters.kthread_idle_ns", "instr.counters.kthread_sleep_ns",
            "cxl_shm.sleep_wakeups", "cxl_shm.tick_kicks")
DS_COUNTERS = ("tx_timeout", "protocol_error", "async_issued", "async_fallback_mean", "async_fallback_p95")
DS_ZERO = ("tx_timeout", "protocol_error")
DS_STEP_PREFIX = "sys.swmc.destijl."


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


def integer(v):
    return int(v) if v is not None and re.fullmatch(r"\d+", v.strip()) else None


def vms_of(shm):
    ks = sorted(int(m.group(1)) for p in glob.glob(os.path.join(shm, "status-pre-vm*.txt"))
                if (m := re.search(r"status-pre-vm(\d+)\.txt$", p)))
    return ks or [0, 1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--mode", required=True, choices=("poll", "idle", "sleep"))
    ap.add_argument("--out")
    a = ap.parse_args()
    D, out, bad = a.dir, [], 0
    kinds = {"pop": 0, "ds": 0}

    def fail(msg):
        nonlocal bad
        bad += 1
        out.append("FAIL " + msg)

    names = sorted(os.path.basename(p)[len("recv-mode-"):-len(".txt")] for p in glob.glob(os.path.join(D, "recv-mode-*.txt")))
    if not names:
        fail(f"no recv-mode-*.txt in {D} (no Popcorn or De Stijl lifetime)")
    for n in names:
        pop_dir, ds_dir = os.path.join(D, f"shm-{n}"), os.path.join(D, f"dsshm-{n}")
        if os.path.isdir(pop_dir) and os.path.isdir(ds_dir):
            fail(f"{n}: both shm-{n} and dsshm-{n} exist (one cxl_shm cycle per lifetime)")
        ds = os.path.isdir(ds_dir)
        kinds["ds" if ds else "pop"] += 1
        shm = ds_dir if ds else pop_dir
        vms = vms_of(shm)
        lines = [x.split() for x in open(os.path.join(D, f"recv-mode-{n}.txt")) if x.strip()]
        modes = [next((t.split("=", 1)[1] for t in x if t.startswith("recv_mode=")), None) for x in lines]
        if len(lines) != len(vms) or len(lines) < 2 or len({x[0] for x in lines}) != len(lines) or any(m != a.mode for m in modes):
            fail(f"{n}: recv-mode lines {lines} (want {len(vms)} distinct VMs with recv_mode={a.mode})")
        dsum = {c: 0 for c in DS_COUNTERS}
        for k in vms:
            pre, post = kv(os.path.join(shm, f"status-pre-vm{k}.txt")), kv(os.path.join(shm, f"status-post-vm{k}.txt"))
            for tag, st in (("pre", pre), ("post", post)):
                if st.get("param.recv_mode") != a.mode:
                    fail(f"{n} vm{k}: status-{tag} param.recv_mode={st.get('param.recv_mode')}")
                if ds:
                    if (st.get("cxl_shm.state") or "").split() != ["running", "registered", "1"]:
                        fail(f"{n} vm{k}: status-{tag} cxl_shm.state={st.get('cxl_shm.state')!r} (want 'running registered 1')")
                    if st.get("swmc.protocol") != "destijl":
                        fail(f"{n} vm{k}: status-{tag} swmc.protocol={st.get('swmc.protocol')}")
                    miss = [c for c in DS_COUNTERS if integer(st.get(f"ds.{c}")) is None]
                    if miss:
                        fail(f"{n} vm{k}: status-{tag} without De Stijl counters {', '.join('ds.' + c for c in miss)}")
            td = os.path.join(shm, f"teardown-vm{k}.txt")
            if not (os.path.isfile(td) and "unload OK" in open(td, errors="replace").read()):
                fail(f"{n} vm{k}: no 'unload OK' in {td} (receiver not returned to the module default)")
            d = {c: int(post.get(f"cxl_shm.{c}", 0) or 0) - int(pre.get(f"cxl_shm.{c}", 0) or 0)
                 for c in ("sleep_wakeups", "tick_kicks")}
            out.append(f"{n} vm{k}: sleep_wakeups {d['sleep_wakeups']} tick_kicks {d['tick_kicks']} "
                       f"recv_thread_ticks {ticks(post) - ticks(pre)} (status post - pre)")
            if ds:
                if not any(x.startswith("recv_thread.") for x in post):
                    fail(f"{n} vm{k}: no receive thread (recv_thread.*) in status-post (receiver not on a CPU)")
                for c in DS_COUNTERS:
                    b, e = integer(pre.get(f"ds.{c}")), integer(post.get(f"ds.{c}"))
                    if b is None or e is None:
                        continue
                    dsum[c] += e - b
                    if c in DS_ZERO and e != b:
                        fail(f"{n} vm{k}: ds.{c} delta {e - b} (post {e} - pre {b}; must be 0)")
        if ds:
            den = dsum["async_issued"] + dsum["async_fallback_mean"] + dsum["async_fallback_p95"]
            share = f"{dsum['async_issued'] / den:.4f}" if den else "n/a"
            out.append(f"{n} ds: ds_async_share {share} (async_issued {dsum['async_issued']}, async_fallback_mean "
                       f"{dsum['async_fallback_mean']}, async_fallback_p95 {dsum['async_fallback_p95']}); tx_timeout "
                       f"{dsum['tx_timeout']} protocol_error {dsum['protocol_error']} (status post - pre, {len(vms)} VMs)")
        parts = sorted(glob.glob(os.path.join(D, n, "*", "stats-steps.csv")))
        for p in parts:
            cols = next(csv.reader(open(p)), [])
            miss = [c for c in PER_STEP if not any(x.endswith(c) for x in cols)]
            rel = os.path.relpath(p, D)
            if miss and a.mode == "sleep":
                fail(f"{rel}: no per-step column for {', '.join(miss)}")
            else:
                out.append(f"{rel}: per-step receive counters {'present' if not miss else 'missing ' + ','.join(miss)}")
            if ds and not any(DS_STEP_PREFIX in x for x in cols):
                fail(f"{rel}: no per-step De Stijl counter column ({DS_STEP_PREFIX}*)")
        if not parts:
            out.append(f"{n}: no stats-steps.csv parts (lifetime dir {os.path.join(D, n)})")
    out.append(f"RECVCHECK {'PASS' if not bad else 'FAIL'} {len(names)} lifetimes ({kinds['pop']} Popcorn, {kinds['ds']} De Stijl; "
               f"mode {a.mode}; {bad} failures)")
    text = "\n".join(out) + "\n"
    with open(a.out or os.path.join(D, "recv-check.txt"), "w") as f:
        f.write(text)
    sys.stdout.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

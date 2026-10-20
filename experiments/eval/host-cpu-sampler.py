#!/usr/bin/env python3
"""Host CPU sampler of one h2n block (verifier review v1 M4, L10). Host only, read only (/proc, /run/libvirt pid files).

usage: host-cpu-sampler.py <out dir (new)> --domains "cxl_vm0 cxl_vm1 .." [--loadgen PATH] [--cpus LIST]
                           [--interval-s 1] [--max-s 21600] [--until-unlock 1]
Every interval, one row of cumulative tick counters (utime + stime, /proc/.../stat fields 14 + 15, CLK_TCK units):
  <dom>.emu    the QEMU process's non-vCPU, non-vhost threads (main loop, IO thread, workers: the emulator threads)
  <dom>.vhost  the vhost-<pid> worker threads (virtio-net data path)
  <dom>.vcpu   the "CPU n/KVM" threads (guest time; for reference)
  cpu<N>.busy, cpu<N>.total   /proc/stat of every Host CPU an emulator / vhost thread may run on (their
               Cpus_allowed_list at start) and of --cpus (e.g. the loadgen CPUs 56-63)
  loadgen, loadgen_pids       summed ticks of the processes whose argv[0] resolves to --loadgen (own uid), and their pids
Output: <dir>/samples.csv (epoch_ns + the columns above), <dir>/manifest.txt (domains, qemu pids, thread list with class
and affinity, CLK_TCK), <dir>/stop-epoch.txt. Stops when workspaces/MEASUREMENT.lock is gone for two checks 5 s apart
(--until-unlock 1, as cxl-bw-sampler.sh) or after --max-s. export_h2n.py averages the counters over each step's wall
window (samples inside [begin_wall_ns, end_wall_ns]).
"""
import argparse
import os
import sys
import time

P = "/home/comsys/sungsu/destijl-control"
LOCK = os.path.join(P, "workspaces", "MEASUREMENT.lock")


def ticks(stat_path):
    """utime + stime of a /proc stat file (comm may hold spaces: parse after the last ')')"""
    with open(stat_path) as f:
        s = f.read()
    rest = s[s.rindex(")") + 2:].split()
    return int(rest[11]) + int(rest[12])  # fields 14, 15 (rest[0] = field 3)


def classify(comm):
    if comm.startswith("CPU ") and comm.endswith("/KVM"):
        return "vcpu"
    if comm.startswith("vhost-"):
        return "vhost"
    return "emu"


def cpulist(s):
    out = set()
    for part in s.strip().split(","):
        if not part:
            continue
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


def qemu_pid(dom):
    with open(f"/run/libvirt/qemu/{dom}.pid") as f:
        return int(f.read().strip())


def threads(pid):
    out = []
    for tid in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
        try:
            with open(f"/proc/{pid}/task/{tid}/comm") as f:
                comm = f.read().strip()
            aff = ""
            with open(f"/proc/{pid}/task/{tid}/status") as f:
                for ln in f:
                    if ln.startswith("Cpus_allowed_list:"):
                        aff = ln.split(":", 1)[1].strip()
            out.append((int(tid), comm, classify(comm), aff))
        except OSError:
            continue  # thread exited
    return out


def dom_ticks(pid):
    t = {"emu": 0, "vhost": 0, "vcpu": 0}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            with open(f"/proc/{pid}/task/{tid}/comm") as f:
                c = classify(f.read().strip())
            t[c] += ticks(f"/proc/{pid}/task/{tid}/stat")
        except OSError:
            continue
    return t


def proc_stat(cpus):
    out = {}
    with open("/proc/stat") as f:
        for ln in f:
            if ln.startswith("cpu") and ln[3].isdigit():
                v = ln.split()
                n = int(v[0][3:])
                if n in cpus:
                    x = [int(y) for y in v[1:9]]  # user nice system idle iowait irq softirq steal
                    busy = x[0] + x[1] + x[2] + x[5] + x[6] + x[7]
                    out[n] = (busy, busy + x[3] + x[4])
    return out


def loadgen_ticks(path):
    if not path:
        return 0, ""
    want, uid, tot, pids = os.path.realpath(path), os.getuid(), 0, []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            if os.stat(f"/proc/{d}").st_uid != uid:
                continue
            with open(f"/proc/{d}/cmdline", "rb") as f:
                a0 = f.read().split(b"\0", 1)[0].decode(errors="replace")
            if a0 and os.path.realpath(a0) == want:
                tot += ticks(f"/proc/{d}/stat")
                pids.append(d)
        except OSError:
            continue
    return tot, " ".join(sorted(pids, key=int))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--domains", required=True)
    ap.add_argument("--loadgen", default="")
    ap.add_argument("--cpus", default="")
    ap.add_argument("--interval-s", type=float, default=1.0)
    ap.add_argument("--max-s", type=float, default=21600)
    ap.add_argument("--until-unlock", type=int, default=1)
    a = ap.parse_args(argv)
    if os.path.exists(a.out):
        sys.exit(f"refuse: {a.out} exists")
    doms = a.domains.split()
    pids = {d: qemu_pid(d) for d in doms}
    os.makedirs(a.out)
    cpus = cpulist(a.cpus) if a.cpus else set()
    with open(os.path.join(a.out, "manifest.txt"), "w") as m:
        m.write(f"clk_tck={os.sysconf('SC_CLK_TCK')} interval_s={a.interval_s} max_s={a.max_s} "
                f"until_unlock={a.until_unlock} loadgen={a.loadgen} extra_cpus={a.cpus}\n")
        for d in doms:
            m.write(f"domain={d} qemu_pid={pids[d]}\n")
            for tid, comm, cls, aff in threads(pids[d]):
                m.write(f"thread {d} tid={tid} class={cls} affinity={aff} comm={comm}\n")
                if cls != "vcpu" and aff:
                    cpus |= cpulist(aff)
        m.write("cpus=" + ",".join(str(c) for c in sorted(cpus)) + "\n")
    cols = ["epoch_ns"] + [f"{d}.{c}" for d in doms for c in ("emu", "vhost", "vcpu")]
    cols += [f"cpu{n}.{k}" for n in sorted(cpus) for k in ("busy", "total")] + ["loadgen", "loadgen_pids"]
    t0, gone, last_chk = time.monotonic(), 0, 0.0
    with open(os.path.join(a.out, "samples.csv"), "w", buffering=1) as f:
        f.write(",".join(cols) + "\n")
        nxt = time.monotonic()
        while time.monotonic() - t0 < a.max_s:
            row = [str(time.time_ns())]
            for d in doms:
                try:
                    t = dom_ticks(pids[d])
                    row += [str(t["emu"]), str(t["vhost"]), str(t["vcpu"])]
                except OSError:
                    row += ["", "", ""]
            ps = proc_stat(cpus)
            for n in sorted(cpus):
                row += [str(ps[n][0]), str(ps[n][1])] if n in ps else ["", ""]
            lt, lp = loadgen_ticks(a.loadgen)
            row += [str(lt), lp]
            f.write(",".join(row) + "\n")
            now = time.monotonic()
            if a.until_unlock and now - last_chk >= 5:
                last_chk = now
                gone = gone + 1 if not os.path.exists(LOCK) else 0
                if gone >= 2:
                    break
            nxt += a.interval_s
            time.sleep(max(0.0, nxt - time.monotonic()))
    with open(os.path.join(a.out, "stop-epoch.txt"), "w") as f:
        f.write(f"{time.time():.6f}\n")
    print(f"HOST-CPU SAMPLER DONE {a.out}")


if __name__ == "__main__":
    main()

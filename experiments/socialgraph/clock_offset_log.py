#!/usr/bin/env python3
"""Host-side guest clock-offset logger for N VMs (socialgraph-serving §2 "host clock offsets logged as in the RecSys
T-sweep"). Generalised from workspaces/clock-offset-log-v1.py (2026-11-05; 2 VMs hard-coded): the VM list is an
argument, the loop ends by itself (until a file exists, until a pid is gone, or after --max-s), and one sample round is
taken right at the start and one at the end, so that every measured step lies between two ok rows per VM.

Every PERIOD s, for each VM: one ssh session (BatchMode, read only on the guest: `date +%s%N` in a read loop), 20
request/response pings of the guest's CLOCK_REALTIME, the first two discarded; offset = guest - host midpoint of the
minimum-RTT ping (error <= RTT/2). One TSV row per VM per round (same columns as v1, read by
workloads/socialgraph/tools/sg_stale_join.py --clock): host_ns, vm (IP), offset_ms, rtt_ms, status (ok | no-reply |
error <type>). A failed sample is an error row; the loop continues.
usage: python3 -I clock_offset_log.py --out OUT.tsv --vm IP [--vm IP ...] [--period 30] [--until-file F]
                                      [--until-pid PID] [--max-s 14400]
       python3 -I clock_offset_log.py --selftest      (offline: the offset arithmetic on a local stub, no ssh)
"""
import argparse, os, subprocess, sys, time

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]


def best_of(cmd, n=20):
    """min-RTT (rtt_ns, offset_ns) over n pings of a `while read x; do date +%s%N; done` process (first 2 dropped)"""
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                         bufsize=1)
    best = None
    try:
        for i in range(n):
            t1 = time.time_ns(); p.stdin.write("x\n"); p.stdin.flush(); line = p.stdout.readline(); t2 = time.time_ns()
            if not line:
                break
            if i < 2:
                continue
            rtt = t2 - t1; off = int(line) - (t1 + t2) // 2
            if best is None or rtt < best[0]:
                best = (rtt, off)
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    return best


def sample(ip):
    return best_of(SSH + [f"comsys@{ip}", "while read x; do date +%s%N; done"])


def row(ip, sampler=sample):
    now = time.time_ns()
    try:
        b = sampler(ip)
        return f"{now}\t{ip}\t{b[1] / 1e6:.4f}\t{b[0] / 1e6:.4f}\tok" if b else f"{now}\t{ip}\t\t\tno-reply"
    except Exception as e:  # noqa: BLE001 (recorded as an error row; the loop continues)
        return f"{now}\t{ip}\t\t\terror {type(e).__name__}"


def done(a, t0):
    if a.until_file and os.path.exists(a.until_file):
        return True
    if a.until_pid:
        try:
            os.kill(a.until_pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass
    return time.time() - t0 >= a.max_s


def selftest():
    # a local stub that answers with the Host clock + 5 ms: offset must be ~ +5 ms, rtt > 0
    cmd = [sys.executable, "-I", "-c",
           "import sys,time\nfor l in sys.stdin:\n print(time.time_ns()+5000000, flush=True)"]
    b = best_of(cmd)
    ok = b is not None and 4.0 < b[1] / 1e6 < 6.0 and b[0] > 0
    r = row("stub", lambda ip: b)
    f = r.split("\t")
    ok = ok and len(f) == 5 and f[4] == "ok" and abs(float(f[2]) - b[1] / 1e6) < 1e-3
    bad = row("stub", lambda ip: (_ for _ in ()).throw(OSError("x")))
    ok = ok and bad.split("\t")[4] == "error OSError"
    print(f"clock_offset_log selftest {'PASS' if ok else 'FAIL'}: offset {b[1] / 1e6 if b else None} ms rtt "
          f"{b[0] / 1e6 if b else None} ms")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out")
    ap.add_argument("--vm", action="append", default=[])
    ap.add_argument("--period", type=float, default=30.0)
    ap.add_argument("--until-file")
    ap.add_argument("--until-pid", type=int)
    ap.add_argument("--max-s", type=float, default=14400.0)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.out or not a.vm:
        ap.error("--out and at least one --vm are required")
    t0 = time.time()
    with open(a.out, "a") as f:
        if f.tell() == 0:
            f.write("host_ns\tvm\toffset_ms\trtt_ms\tstatus\n")
        while True:
            last = done(a, t0)
            for ip in a.vm:
                f.write(row(ip) + "\n"); f.flush()
            if last:
                return 0
            end = time.time() + a.period
            while time.time() < end and not done(a, t0):
                time.sleep(0.5)


if __name__ == "__main__":
    sys.exit(main())

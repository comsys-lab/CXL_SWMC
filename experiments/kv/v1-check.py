#!/usr/bin/env python3
"""KV-V1 closure checks of one run dir (reports/KV-V1-packet.md): per-operation split vs the server counters and the
expected coherence source of the system.

usage: v1-check.py RUN_DIR --system all-HWcc|Popcorn|Megalon [--timers on|off] [--workload kv|lmdb]
RUN_DIR = an experiments/kv/run.sh (or experiments/lmdb/run.sh, --workload lmdb: ops get/update, server counters
gets+get_not_found+get_errors / updates+update_not_found+update_errors, C formula lmdb) result dir (node<k>.log with the clean-stop stats, opsplit.csv).
Checks (each printed; exit 1 if any fails):
  stop      every node log has "kv-server: stopping" and opt.get.ops = gets, opt.put.ops = puts (every executed op
            counted once in the split)
  rows      opsplit.csv has get and put rows with ops > 0 and T > 0; every C within [0, T]
  source    all-HWcc: C = 0 on every row
            Megalon timers on: c_formula kv, c_supported 1, C > 0 on every row with ops > 0, tsc_backwards 0
            Megalon timers off (MEGALON_COH_TIMERS=0): C = 0 on every row (durations off, counts kept)
            Popcorn: c_supported 1 (swmc_acct registered on every node) and the run's total C > 0
Writes RUN_DIR/v1-check.txt (results + per step/op T and C).
"""
import argparse, csv, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("--system", required=True, choices=["all-HWcc", "Popcorn", "Megalon"])
ap.add_argument("--timers", choices=["on", "off"], default="on")
ap.add_argument("--workload", choices=["kv", "lmdb"], default="kv")
a = ap.parse_args()
out, fails = [], []


def check(ok, what):
    out.append(("PASS " if ok else "FAIL ") + what)
    if not ok:
        fails.append(what)


def stop_stats(path):
    kv, seen = {}, False
    for line in open(path, errors="replace"):
        if "-server: stopping" in line:
            seen, kv = True, {}
            continue
        if seen:
            k, sep, v = line.rstrip("\n").partition("=")
            if sep and re.match(r"^[a-z][\w.\-]*$", k):
                kv[k] = v
    return seen, kv


logs = sorted(f for f in os.listdir(a.run) if re.match(r"^node\d+\.log$", f))
check(len(logs) == 2, f"two node logs ({logs})")
for f in logs:
    seen, kv = stop_stats(os.path.join(a.run, f))
    check(seen, f"{f}: clean stop")
    pairs = (("get", ("gets",)), ("put", ("puts",))) if a.workload == "kv" else \
        (("get", ("gets", "get_not_found", "get_errors")), ("update", ("updates", "update_not_found", "update_errors")))
    for op, ctrs in pairs:
        x = kv.get(f"opt.{op}.ops")
        y = sum(int(kv[c]) for c in ctrs) if all(c in kv for c in ctrs) else None
        check(x is not None and y is not None and int(x) == y, f"{f}: opt.{op}.ops {x} = {'+'.join(ctrs)} {y}")
path = os.path.join(a.run, "opsplit.csv")
rows = list(csv.DictReader(open(path))) if os.path.exists(path) else []
check(bool(rows), "opsplit.csv has rows")
T = lambda r: float(r["T_us_per_op[measured]"])
C = lambda r: float(r["C_us_per_op[derived]"])
n = lambda r: int(r["ops[measured]"])
OPS = ("get", "put") if a.workload == "kv" else ("get", "update")
for op in OPS:
    rs = [r for r in rows if r["op"] == op and n(r) > 0]
    check(bool(rs) and all(T(r) > 0 for r in rs), f"{op}: rows with ops > 0 and T > 0")
check(all(0 <= C(r) <= T(r) * 1.0001 + 0.01 for r in rows if n(r)), "every C within [0, T]")
live = [r for r in rows if n(r) > 0]
if a.system == "all-HWcc":
    check(all(C(r) == 0 for r in live), "all-HWcc: C = 0")
elif a.system == "Megalon" and a.timers == "on":
    check(all(r["c_formula"] == a.workload for r in live), f"Megalon: c_formula {a.workload}")
    check(all(r["c_supported"] == "1" for r in live), "Megalon: c_supported 1")
    check(all(C(r) > 0 for r in live), "Megalon: C > 0 on every row")
    check(all(float(r["meg_tsc_backwards_per_op[measured]"]) == 0 for r in live), "Megalon: tsc_backwards 0")
elif a.system == "Megalon":
    check(all(C(r) == 0 for r in live), "Megalon timers off: C = 0")
else:
    check(all(r["c_supported"] == "1" for r in live), "Popcorn: c_supported 1 (swmc_acct registered)")
    check(sum(C(r) * n(r) for r in live) > 0, "Popcorn: total C > 0")
for r in rows:
    out.append(f"step {r['step']} {r['op']} offered={r['offered_x']} ops={r['ops[measured]']} T={r['T_us_per_op[measured]']} us "
               f"C={r['C_us_per_op[derived]']} us bg={r['coh_bg_us_per_op[derived]']} us/op sup={r['c_supported']}")
res = "V1 CHECK " + ("PASS" if not fails else "FAIL: " + "; ".join(fails))
out.append(res)
open(os.path.join(a.run, "v1-check.txt"), "w").write("\n".join(out) + "\n")
print(res)
sys.exit(1 if fails else 0)

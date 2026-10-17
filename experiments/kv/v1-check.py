#!/usr/bin/env python3
"""KV-V1 closure checks of one run dir (reports/KV-V1-packet.md): per-operation split vs the server counters and the
expected coherence source of the system.

usage: v1-check.py RUN_DIR --system all-HWcc|Popcorn|Megalon [--timers on|off] [--workload kv|lmdb] [--megalon-lean 1|0]
RUN_DIR = an experiments/kv/run.sh (or experiments/lmdb/run.sh, --workload lmdb: ops get/update, server counters
gets+get_not_found+get_errors / updates+update_not_found+update_errors, C formula lmdb) result dir (node<k>.log with the clean-stop stats, opsplit.csv).
Checks (each printed; exit 1 if any fails):
  stop      every node log has "kv-server: stopping" and opt.get.ops = gets, opt.put.ops = puts (every executed op
            counted once in the split)
  rows      opsplit.csv has get and put rows with ops > 0 and T > 0; every C within [0, T]
  gauge     every node's clean-stop stats carry opt.c_formula = the workload (kv / lmdb)
  source    all-HWcc: C = 0 and every raw pop_*/meg_* column 0 on every row
            Megalon timers on: c_formula kv, c_supported 1, C > 0 on every row with ops > 0, tsc_backwards 0;
                      --megalon-lean 1 (default; Megalon >= 76, e.g. build 77): meg_lean 1, meg_events_always 0 on every
                      row and timed write sections (write_sampled) > 0 summed over the write op's rows (put / update; a single
                      low-rate step may have none), so C used the lean
                      estimators (reports/M2-megalon-port-changes.md §18); --megalon-lean 0 for builds <= 75
            Megalon timers off (MEGALON_COH_TIMERS=0): c_supported 1 and C = 0 on every row (durations off, counts kept)
            Popcorn: c_supported 1 (swmc_acct registered on every node) and the run's total C > 0
Writes RUN_DIR/v1-check.txt (results + per step/op T and C).
"""
import argparse, csv, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("--system", required=True, choices=["all-HWcc", "Popcorn", "Megalon"])
ap.add_argument("--timers", choices=["on", "off"], default="on")
ap.add_argument("--workload", choices=["kv", "lmdb"], default="kv")
ap.add_argument("--megalon-lean", choices=["0", "1"], default="1")
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
    check(kv.get("opt.c_formula") == a.workload, f"{f}: opt.c_formula gauge present and = {a.workload} (got {kv.get('opt.c_formula')})")
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
    # the raw parts, not only the derived C: no Popcorn fault/IPI time and no Megalon interval in any operation
    raw = [k for k in (rows[0].keys() if rows else []) if (k.startswith("pop_") or k.startswith("meg_"))
           and k != "meg_check_sample[measured]"]
    nz = sorted({k for r in live for k in raw if r[k] not in ("", "0", "0.0") and float(r[k]) != 0})
    check(not nz, f"all-HWcc: every raw pop_*/meg_* column 0 (non-zero: {nz})")
elif a.system == "Megalon" and a.timers == "on":
    check(all(r["c_formula"] == a.workload for r in live), f"Megalon: c_formula {a.workload}")
    check(all(r["c_supported"] == "1" for r in live), "Megalon: c_supported 1")
    check(all(C(r) > 0 for r in live), "Megalon: C > 0 on every row")
    check(all(float(r["meg_tsc_backwards_per_op[measured]"]) == 0 for r in live), "Megalon: tsc_backwards 0")
    if a.megalon_lean == "1":
        wop = "put" if a.workload == "kv" else "update"
        check(all(r.get("meg_lean[measured]") == "1" and r.get("meg_events_always[measured]") == "0" for r in live),
              "Megalon: lean sampling (meg_lean 1, events_always 0) on every row")
        check(sum(float(r.get("meg_write_sampled_per_op[measured]") or 0) * n(r) for r in live if r["op"] == wop) > 0,
              f"Megalon: write_sampled > 0 over the run's {wop} rows")
elif a.system == "Megalon":
    check(all(r["c_supported"] == "1" for r in live), "Megalon timers off: c_supported 1 (thread_coh present)")
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

#!/usr/bin/env python3
"""Unit test of workloads/kv/tools/opsplit.py on synthetic stats snapshots (no servers). usage: opsplit_test.py <scratch dir>"""
import csv, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "tools", "opsplit.py")
d = sys.argv[1]
os.makedirs(os.path.join(d, "stats"), exist_ok=False)


def snap(t, when, mono, kv):
    with open(os.path.join(d, "stats", f"step001-{when}-t{t}.txt"), "w") as f:
        f.write(f"# when={when} phase=fixed step=1 offered_x=1000 target={t} addr=x status=0 wall_ns=0 mono_ns={mono} rtt_us=1\n")
        for k, v in kv.items():
            f.write(f"{k}={v}\n")


base = {"opt.tsc_hz": 2e9, "opt.pop_threads": 4, "opt.meg_coh": 1, "opt.meg_check_sample": 64, "opt.c_source": "x"}
for t in (0, 1):
    b = dict(base, **{"opt.get.ops": 100, "opt.get.t_ns": 1000, "opt.put.ops": 0, "opt.put.t_ns": 0})
    e = dict(base, **{"opt.get.ops": 1100, "opt.get.t_ns": 1000 + 1000 * 10000,   # 10 us per get
                      "opt.get.pop.is_ns": 1000 * 2000, "opt.get.pop.ipi_ns": 1000 * 500, "opt.get.pop.is_cnt": 500,
                      "opt.get.meg.check_ns_sampled": 1000 * 10, "opt.get.meg.stale_ns": 1000 * 1000,
                      "opt.get.meg.switch_rw_ns": 7777,
                      "opt.put.ops": 10, "opt.put.t_ns": 10 * 50000, "opt.put.mod_bytes": 10 * 1024,
                      "opt.put.meg.wstart_ns": 10 * 3000, "opt.put.meg.wflush_ns": 10 * 2000, "opt.get.t_max_ns": 99000})
    b = dict({k: 0 for k in e}, **b)  # a server emits every key in both snapshots
    snap(t, "begin", 0, b)
    snap(t, "end", 2_000_000_000, e)


def run(system):
    out = os.path.join(d, f"{system}.csv")
    subprocess.run([sys.executable, "-I", TOOL, d, "--system", system, "--out", out], check=True, stdout=subprocess.DEVNULL)
    return {r["op"]: r for r in csv.DictReader(open(out))}


fails = []
def eq(a, b, what):
    if abs(float(a) - b) > 1e-6:
        fails.append(f"{what}: {a} != {b}")

p = run("Popcorn-poll")
eq(p["get"]["ops[measured]"], 2000, "ops")
eq(p["get"]["ops_per_s[derived]"], 1000, "ops/s")
eq(p["get"]["T_us_per_op[measured]"], 10, "T")
eq(p["get"]["C_us_per_op[derived]"], 2.5, "pop C = is + ipi")
eq(p["get"]["rest_us_per_op[derived]"], 7.5, "rest")
eq(p["get"]["pop_is_per_op[measured]"], 0.5, "pop is count")
eq(p["get"]["T_max_us[measured]"], 99, "T max")
m = run("Megalon")
eq(m["get"]["C_us_per_op[derived]"], 0.64 + 1.0, "meg C = check x 64 + stale (switch_rw not added)")
eq(m["get"]["meg_check_us_per_op[sampled_xN]"], 0.64, "check est")
eq(m["put"]["C_us_per_op[derived]"], 5.0, "meg put C = wstart + wflush")
eq(m["put"]["mod_bytes_per_op[measured]"], 1024, "mod bytes")
h = run("all-HWcc")
eq(h["get"]["C_us_per_op[derived]"], 0, "all-HWcc C")
print("OPSPLIT TEST " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
sys.exit(1 if fails else 0)

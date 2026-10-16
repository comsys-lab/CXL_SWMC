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
                      "opt.get.pop.is_ns": 1000 * 2000, "opt.get.pop.ipi_ns": 1000 * 500, "opt.get.pop.is_cnt": 500, "opt.get.pop.nontrans_ns": 1000 * 9000,
                      "opt.get.meg.check_ns_sampled": 1000 * 10, "opt.get.meg.check_sampled": 15, "opt.get.meg.read_sections": 960, "opt.get.meg.stale_ns": 1000 * 1000,
                      "opt.get.meg.switch_rw_ns": 7777,
                      "opt.put.ops": 10, "opt.put.t_ns": 10 * 50000, "opt.put.mod_bytes": 10 * 1024,
                      "opt.put.meg.wstart_ns": 10 * 3000, "opt.put.meg.vcopy_ns_sampled": 1000, "opt.put.meg.vcopy_sampled": 2,
                      "opt.put.meg.vcopy_cnt": 40, "thr.nr-log-sync.run_ns": 505_000_000, "thr.kv-worker.run_ns": 9e9,
                      "kthr.cxl_recv0.run_ns": 1010_000_000, "opt.put.meg.wflush_ns": 10 * 2000, "opt.get.t_max_ns": 99000})
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
eq(p["get"]["pop_nontrans_us_per_op[measured]"], 9, "nontrans exported (not in C)")
eq(p["get"]["T_max_us[measured]"], 99, "T max")
m = run("Megalon")
eq(m["get"]["C_us_per_op[derived]"], 0.64 + 1.0, "meg C = check x 64 + stale (switch_rw not added)")
eq(m["get"]["meg_check_us_per_op[sampled_xN]"], 0.64, "check est")
eq(m["put"]["C_us_per_op[derived]"], 7.0, "meg put C = wstart + wflush + vcopy (1000 x 40 / 2 = 20 us / 10 ops)")
eq(m["put"]["meg_vcopy_us_per_op[sampled_xN]"], 2.0, "vcopy est")
eq(m["put"]["mod_bytes_per_op[measured]"], 1024, "mod bytes")
eq(m["get"]["lib_bg_cpu_s[measured]"], 1.01, "lib bg (2 targets x 0.505 s, kv-* excluded)")
eq(m["get"]["coh_bg_us_per_op[derived]"], 1.01e6 / 2020, "bg per op (all ops)")
eq(p["put"]["coh_bg_cpu_s[derived]"], 2.02, "popcorn bg = recv")
h = run("all-HWcc")
eq(h["get"]["C_us_per_op[derived]"], 0, "all-HWcc C")
# MOT1 v6 §3.1 formulas with AnchorSnap (one target, 100 ops, check_sampled 10 of read_sections 100 -> x10)
def scenario(name, formula):
    d2 = os.path.join(d, name)
    os.makedirs(os.path.join(d2, "stats"))
    e = {"opt.tsc_hz": 2e9, "opt.meg_coh": 1, "opt.meg_anchor": 1, "opt.meg_check_sample": 64, "opt.c_formula": formula,
         "opt.get.ops": 100, "opt.get.t_ns": 100 * 20000, "opt.get.meg.read_sections": 100, "opt.get.meg.check_sampled": 10,
         "opt.get.meg.check_ns_sampled": 10 * 1000, "opt.get.meg.anchor.rseq_ns_sampled": 10 * 200,
         "opt.get.meg.anchor.read_lookup_ns_sampled": 10 * 300, "opt.get.meg.anchor.read_nr_ns_sampled": 10 * 400,
         "opt.get.meg.stale_ns": 100 * 50, "opt.get.meg.wstart_ns": 100 * 3000, "opt.get.meg.anchor.wseq_ns": 100 * 1000,
         "opt.get.meg.wflush_ns": 100 * 2000, "opt.get.meg.anchor.wseq_end_ns": 100 * 500,
         "opt.get.meg.anchor.write_lookup_ns": 100 * 700, "opt.get.meg.anchor.write_nr_ns": 100 * 800,
         "opt.get.meg.vcopy_ns_sampled": 1000, "opt.get.meg.vcopy_sampled": 10, "opt.get.meg.vcopy_cnt": 100}
    b = {k: (v if not k.startswith("opt.get.") else 0) for k, v in e.items()}
    for when, kv, mono in (("begin", b, 0), ("end", e, 1_000_000_000)):
        with open(os.path.join(d2, "stats", f"step001-{when}-t0.txt"), "w") as f:
            f.write(f"# when={when} phase=fixed step=1 offered_x=1 target=0 addr=x status=0 wall_ns=0 mono_ns={mono} rtt_us=1\n")
            f.writelines(f"{k}={v}\n" for k, v in kv.items())
    out = os.path.join(d2, "o.csv")
    subprocess.run([sys.executable, "-I", TOOL, d2, "--system", "Megalon", "--out", out], check=True, stdout=subprocess.DEVNULL)
    return {r["op"]: r for r in csv.DictReader(open(out))}
k = scenario("kv", "kv")["get"]
# kv: (1000-200) x10 / per op... sums: check 10000, rseq 2000 -> (8000 x 10) = 80000 ns; + stale 5000 + (300000-100000)
#     + (200000-50000) = 435000 ns / 100 ops = 4.35 us
eq(k["C_us_per_op[derived]"], 4.35, "kv formula")
l = scenario("lmdb", "lmdb")["get"]
# lmdb: (10000+3000+4000) x10 = 170000 + 5000 + 300000 + 70000 + 80000 + 200000 + vcopy 1000x100/10 = 10000 -> 835000 / 100
eq(l["C_us_per_op[derived]"], 8.35, "lmdb formula")
eq(l["meg_anc_read_nr_us_per_op[sampled_xN]"], 0.4, "anchor read_nr est")
print("OPSPLIT TEST " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
sys.exit(1 if fails else 0)

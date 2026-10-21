#!/usr/bin/env python3
"""Tests of experiments/eval/export_h2n.py and h2n_layout.py (Host only; evidence read-only, outputs in EVAL_TEST_OUT).

usage: EVAL_TEST_OUT=<scratch dir (new or empty)> python3 -B test_export_h2n.py [-v]
  1. 2-VM vector DB run 1 (recovery/two-workload-eval-run1-vdb-v1) through export_h2n --source 2vm: nine lifetimes
     (hw, pop, mg x u5, u50, u90); max_under_slo_search_s = loadgen confirm x_mean of every lifetime; Popcorn read /
     write faults at the result = export_h3.py hosts-at-max (vm = all) of the same dirs; Megalon mg_fetch /
     mg_flushes / mg_flush_writeend at the result = the mean over the confirm steps of megalon.read_retry_incoherent /
     megalon.flushes / their difference summed over the targets / max window; coherence_events = is_faults +
     inv_commits; Popcorn request wait (tx histograms empty at detail=0, per-thread msg wait per round); hw coherence
     columns 0; per-lifetime step files and per-VM rows present (2 per step); summary/steps column contract.
     Host CPU path: a synthetic host-cpu-sampler dir gives the expected cores / busy fractions.
  2. CXL.mem path: a synthetic sampler (1 s intervals, 1e6 rxc + 1e6 txc mem_data inserts each) over the hw u50
     lifetime gives 64.0 MB/s read and 32.0 MB/s write at the result; the other lifetimes have no interval.
  3. --combine concatenates two exports (row counts add up, columns equal).
  4. h2n_layout.py: PASS for the configured per-N delete logs, FAIL for N = 8 with the 2-VM per-node value.
  5. Fig 8 (2026-10-22): per-search vdb-search thread columns match the raw keys, the stack adds up to W, C agrees
     with opt.search.c_ns (5 %), hw C = 0; fig8.csv load point = highest ramp rate both hw and pop pass (also after
     --combine); instr detail=0 evidence (confirm-rule-test-run1-n2-v1) has every counter filled.
"""
import csv
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.dirname(HERE)
P = "/home/comsys/sungsu/destijl-control"
E1 = f"{P}/recovery/two-workload-eval-run1-vdb-v1"
RUN = f"{E1}/vdb/r1/run"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")
LIVES = {("u5", "hw"): "hw-u5-slo-r1", ("u50", "hw"): "hw-u50-slo-r1", ("u90", "hw"): "hw-u90-slo-r1",
         ("u5", "pop"): "pop-u5-slo-r1", ("u50", "pop"): "pop-u50-slo-r1", ("u90", "pop"): "pop-u90-slo-r1",
         ("u5", "mg"): "mg-u5-r1", ("u50", "mg"): "mg-u50-r1", ("u90", "mg"): "mg-u90-r1"}


def run(*a):
    r = subprocess.run([sys.executable, "-I", "-B", *a], capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"{a}: rc {r.returncode}: {r.stdout[-500:]} {r.stderr[-1500:]}")
    return r.stdout


def rows(p):
    with open(p) as f:
        return list(csv.DictReader(f))


def close(a, b, rel=1e-6):
    return abs(float(a) - float(b)) <= rel * max(1.0, abs(float(a)), abs(float(b)))


class H2nExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.o = os.path.join(OUT, "export-2vm")
        run(f"{EV}/export_h2n.py", "--run", "1", "--nodes", "2", "--source", "2vm", "--out", cls.o, E1)
        cls.s = {(r["mix"], r["system"]): r for r in rows(os.path.join(cls.o, "summary.csv"))}

    def test_lifetimes_and_result(self):
        self.assertEqual(set(self.s), set(LIVES))
        for k, d in LIVES.items():
            sm = json.load(open(f"{RUN}/{d}/slo/loadgen/summary.json"))
            self.assertIs(sm["confirmed"], True, d)
            self.assertTrue(close(self.s[k]["max_under_slo_search_s"], sm["confirm"]["x_mean"]), k)
            self.assertEqual(self.s[k]["n_at_result"], "3", k)
            self.assertTrue(os.path.isfile(os.path.join(self.o, f"steps-n2-{k[0]}-{k[1]}.csv")))

    def test_popcorn_faults_equal_export_h3(self):
        for mix in ("u5", "u50", "u90"):
            o3 = os.path.join(OUT, f"export-h3-{mix}")
            run(f"{EV}/export_h3.py", "--run", "1", "--runset", "h3-vdb-n2", "--config-sha256", "t", "--source", "2vm",
                "--point", mix, "--out", o3, E1)
            h = {r["system"]: r for r in rows(os.path.join(o3, "hosts-at-max.csv")) if r["vm"] == "all"}
            for s in ("hw", "pop"):
                self.assertTrue(close(self.s[(mix, s)]["faults_read"], h[s]["read_faults_per_s"]), (mix, s))
                self.assertTrue(close(self.s[(mix, s)]["faults_write"], h[s]["write_faults_per_s"]), (mix, s))
            self.assertGreater(float(self.s[(mix, "pop")]["faults_read"]), 0)

    def test_megalon_counters(self):
        for mix in ("u5", "u50", "u90"):
            d = f"{RUN}/{LIVES[(mix, 'mg')]}/slo"
            sm = json.load(open(f"{d}/loadgen/summary.json"))
            best = float(sm["max_offered_x_pass"])
            steps = [json.loads(x) for x in open(f"{d}/loadgen/steps.jsonl")]
            at = {s["step"] for s in steps if s.get("measure_s", 0) > 0 and s["phase"] == "confirm"
                  and abs(s["offered_x"] - best) <= 1e-6 * max(1, best)}
            st = rows(f"{d}/stats-steps.csv")
            for col, key in (("mg_fetch", ("megalon.read_retry_incoherent",)), ("mg_flushes", ("megalon.flushes",)),
                             ("mg_flush_writeend", ("megalon.flushes", "-megalon.read_retry_incoherent"))):
                v = []
                for n in at:
                    rs = [r for r in st if int(r["step"]) == n]
                    t = sum((-1 if k[0] == "-" else 1) * float(r[k.lstrip("-")]) for r in rs for k in key)
                    v.append(t / max(float(r["window_s"]) for r in rs))
                self.assertTrue(close(self.s[(mix, "mg")][col], sum(v) / len(v)), (mix, col))
                self.assertGreater(float(self.s[(mix, "mg")][col]), 0)
            m = self.s[(mix, "mg")]
            self.assertTrue(close(float(m["mg_fetch"]) + float(m["mg_flush_writeend"]), m["mg_flushes"]), mix)
            for col in ("faults_read", "faults_write", "coherence_events", "mg_fetch", "mg_flush_writeend"):
                self.assertEqual(float(self.s[(mix, "hw")][col]), 0.0)
                if col.startswith("mg"):
                    self.assertEqual(float(self.s[(mix, "pop")][col]), 0.0)
                else:
                    self.assertEqual(float(self.s[(mix, "mg")][col]), 0.0)

    def test_columns(self):
        h = open(os.path.join(self.o, "summary.csv")).readline().strip().split(",")
        self.assertEqual(h[:11], ["nodes", "mix", "system", "max_under_slo_search_s", "faults_read", "faults_write",
                                  "coherence_events", "mg_fetch", "mg_flush_writeend", "cxl_rd_MBs", "cxl_wr_MBs"])
        st = open(os.path.join(self.o, "steps.csv")).readline().strip().split(",")
        for c in ("coherence_events", "mg_flush_writeend", "tx_wait_ns_per_op", "msg_wait_ns_per_round",
                  "qemu_emu_cpu", "qemu_vhost_cpu", "loadgen_cpu", "emu_pcpu_busy_max"):
            self.assertIn(c, h)
            self.assertIn(c, st)
        self.assertNotIn("mg_inval", h)

    def test_coherence_events(self):
        """coherence_events = is_faults + inv_commits (I->S + I/S->M incl. WP upgrades), per s, summed over VMs"""
        for mix in ("u5", "u50", "u90"):
            p = self.s[(mix, "pop")]
            self.assertTrue(close(p["coherence_events"], float(p["is_faults"]) + float(p["inv_commits"])), mix)
            self.assertGreater(float(p["coherence_events"]), 0)
            self.assertLessEqual(float(p["is_faults"]), float(p["faults_read"]) * (1 + 1e-9))
            ops = float(p["at_result_search_s"]) + float(p["at_result_update_s"])
            self.assertTrue(close(p["coherence_events_per_op"], float(p["coherence_events"]) / ops), mix)
            self.assertEqual(float(self.s[(mix, "hw")]["coherence_events"]), 0.0)

    def test_popcorn_request_wait(self):
        """M5: tx wait histograms are detail-only (empty here, detail=0); per-thread msg wait per round always on"""
        d = f"{RUN}/{LIVES[('u90', 'pop')]}/slo"
        st = rows(f"{d}/stats-steps.csv")
        self.assertTrue(all(float(r["sys.swmc.instr.tx_invalidate.wait_count"]) == 0 for r in st))
        p = self.s[("u90", "pop")]
        self.assertEqual(p["tx_wait_ns_per_op"], "")
        self.assertGreater(float(p["msg_wait_ns_per_round"]), 0)
        self.assertGreater(float(p["msg_wait_ns_per_op"]), 0)
        # step-level check of the formula against the raw per-thread keys
        sv = [r for r in rows(os.path.join(self.o, "steps.csv")) if r["mix"] == "u90" and r["system"] == "pop"]
        r0 = sv[0]
        rs = [r for r in st if int(r["step"]) == int(r0["step"])]
        mw = sum(float(v) for r in rs for k, v in r.items() if k.startswith("thr.") and
                 (k.endswith(".swmc.read_msg_wait_ns") or k.endswith(".swmc.write_msg_wait_ns")) and v)
        mr = sum(float(v) for r in rs for k, v in r.items() if k.startswith("thr.") and
                 (k.endswith(".swmc.read_transactions") or k.endswith(".swmc.write_transactions")) and v)
        self.assertTrue(close(r0["msg_wait_ns_per_round"], mw / mr))

    def test_hostcpu_path(self):
        """M4 / L10: synthetic host-cpu-sampler dir over the hw u50 lifetime (1 s samples): per VM emu +10 ticks/s,
        vhost +50, vcpu +400; cpu16 busy 80 of 100; loadgen +300 ticks/s on one pid; cpu56 busy 50 of 100"""
        hd = os.path.join(OUT, "fake-hostcpu")
        os.makedirs(hd, exist_ok=True)
        st = rows(f"{RUN}/hw-u50-slo-r1/slo/stats-steps.csv")
        b = min(int(r["begin_wall_ns"]) for r in st) - 500_000_000
        e = max(int(r["end_wall_ns"]) for r in st) + 1_000_000_000
        with open(f"{hd}/manifest.txt", "w") as f:
            f.write("clk_tck=100 interval_s=1.0 max_s=1 until_unlock=1 loadgen=/x/loadgen extra_cpus=56\n")
            for d in ("cxl_vm0", "cxl_vm1"):
                f.write(f"domain={d} qemu_pid=1\nthread {d} tid=1 class=emu affinity=16 comm=qemu-system-x86\n")
                f.write(f"thread {d} tid=2 class=vhost affinity=16 comm=vhost-1\n")
                f.write(f"thread {d} tid=3 class=vcpu affinity=0 comm=CPU 0/KVM\n")
            f.write("cpus=16,56\n")
        with open(f"{hd}/samples.csv", "w") as f:
            f.write("epoch_ns,cxl_vm0.emu,cxl_vm0.vhost,cxl_vm0.vcpu,cxl_vm1.emu,cxl_vm1.vhost,cxl_vm1.vcpu,"
                    "cpu16.busy,cpu16.total,cpu56.busy,cpu56.total,loadgen,loadgen_pids\n")
            t, i = b, 0
            while t < e:
                f.write(f"{t},{10*i},{50*i},{400*i},{10*i},{50*i},{400*i},{80*i},{100*i},{50*i},{100*i},{300*i},77\n")
                t += 1_000_000_000
                i += 1
        o = os.path.join(OUT, "export-2vm-hostcpu")
        run(f"{EV}/export_h2n.py", "--run", "1", "--nodes", "2", "--source", "2vm", "--hostcpu", hd, "--out", o, E1)
        s = {(r["mix"], r["system"]): r for r in rows(os.path.join(o, "summary.csv"))}
        h = s[("u50", "hw")]
        for c, v in (("qemu_emu_cpu", 0.2), ("qemu_vhost_cpu", 1.0), ("qemu_vcpu_cpu", 8.0), ("emu_pcpu_busy_max", 0.8),
                     ("loadgen_cpu", 3.0), ("lg_pcpu_busy_mean", 0.5)):
            self.assertTrue(close(h[c], v), (c, h[c]))
        self.assertGreaterEqual(int(float(h["hostcpu_n_samples"])), 10)
        self.assertEqual(s[("u50", "pop")]["qemu_emu_cpu"], "")

    def test_per_vm_rows(self):
        st, vm = rows(os.path.join(self.o, "steps.csv")), rows(os.path.join(self.o, "steps-vm.csv"))
        self.assertEqual(len(vm), 2 * len(st))
        self.assertEqual({r["vm"] for r in vm}, {"0", "1"})

    def test_cxl_path(self):
        sd = os.path.join(OUT, "fake-cxlbw")
        os.makedirs(sd, exist_ok=True)
        st = rows(f"{RUN}/hw-u50-slo-r1/slo/stats-steps.csv")
        b = min(int(r["begin_wall_ns"]) for r in st) / 1e9 - 0.5
        e = max(int(r["end_wall_ns"]) for r in st) / 1e9 + 1
        with open(f"{sd}/start-epoch.txt", "w") as f:
            f.write(f"{b:.9f}\n")
        with open(f"{sd}/perf.csv", "w") as f:
            f.write("# started on test\n\n")
            t = 1.0
            while b + t < e:
                for ev in ("rxc", "txc"):
                    f.write(f"{t:.9f},S0,1,1000000,,unc_cxlcm_{ev}_pack_buf_inserts.mem_data,1,100.00,,\n")
                t += 1.0
        o = os.path.join(OUT, "export-2vm-cxl")
        run(f"{EV}/export_h2n.py", "--run", "1", "--nodes", "2", "--source", "2vm", "--cxlbw", sd, "--out", o, E1)
        s = {(r["mix"], r["system"]): r for r in rows(os.path.join(o, "summary.csv"))}
        self.assertTrue(close(s[("u50", "hw")]["cxl_rd_MBs"], 64.0) and close(s[("u50", "hw")]["cxl_wr_MBs"], 32.0))
        self.assertEqual(s[("u50", "pop")]["cxl_rd_MBs"], "")

    def test_combine(self):
        o = os.path.join(OUT, "combined")
        run(f"{EV}/export_h2n.py", "--combine", "--out", o, self.o, self.o)
        self.assertEqual(len(rows(os.path.join(o, "summary.csv"))), 18)

    def test_fig8_columns(self):
        """Fig 8 (2026-10-22): per-search Popcorn time of the vdb-search threads; the stack adds up to W, W and the
        raw per-thread keys of one step match the formulas, C = the server's own swmc_acct C of search ops
        (opt.search.c_ns), hw has C = 0 and query = W"""
        sv = rows(os.path.join(self.o, "steps.csv"))
        f = lambda r, k: float(r[k]) if r[k] != "" else None  # noqa: E731
        segs = ("fig8_inval_ipi_ns_per_search", "fig8_owner_wait_ns_per_search", "fig8_other_fault_ns_per_search",
                "fig8_query_ns_per_search")
        npop = 0
        for r in sv:
            if r["system"] == "pop" and f(r, "srv_searches"):
                npop += 1
                self.assertTrue(close(sum(f(r, k) for k in segs), f(r, "srch_wall_ns_per_search")), r["step"])
                self.assertGreaterEqual(f(r, "fig8_owner_wait_ns_per_search"), 0)
            if r["system"] == "hw" and f(r, "srv_searches"):
                self.assertEqual(f(r, "srch_C_ns_per_search") or 0.0, 0.0)
                self.assertTrue(close(f(r, "fig8_query_ns_per_search") or f(r, "srch_wall_ns_per_search"),
                                      f(r, "srch_wall_ns_per_search")))
        self.assertGreater(npop, 20)
        d = f"{RUN}/{LIVES[('u90', 'pop')]}/slo"
        st = rows(f"{d}/stats-steps.csv")
        for r0 in [r for r in sv if r["mix"] == "u90" and r["system"] == "pop" and r["srv_searches"] not in ("", "0")]:
            rs = [r for r in st if int(r["step"]) == int(r0["step"])]
            ns = sum(float(r["searches"]) for r in rs)
            g = lambda k: sum(float(r[k] or 0) for r in rs) / ns  # noqa: E731
            self.assertTrue(close(r0["srch_wall_ns_per_search"], g("search_busy_ns")))
            F = g("thr.vdb-search.swmc.is_fault_ns") + g("thr.vdb-search.swmc.sm_fault_ns") + \
                g("thr.vdb-search.swmc.wpu_fault_ns")
            C = F + g("thr.vdb-search.swmc.ipi_coh_ns") - g("thr.vdb-search.swmc.ipi_coh_infault_ns")
            self.assertTrue(close(r0["srch_C_ns_per_search"], C) and close(r0["srch_F_ns_per_search"], F))
            # cross-check with the per-op accounting (opsplit sections; the thread counters cover the stats window):
            # equal within a few % (2-VM data: <= 1.8 %)
            self.assertTrue(close(C, g("opt.search.c_ns"), 0.05), (r0["step"], C, g("opt.search.c_ns")))
            self.assertTrue(close(r0["fig8_owner_wait_ns_per_search"], g("thr.vdb-search.swmc.read_msg_wait_ns")
                                  + g("thr.vdb-search.swmc.write_msg_wait_ns")))

    def test_fig8_csv(self):
        """fig8.csv: per mix the highest ramp offered rate passed by both hw and pop; no higher common pass exists"""
        allf = rows(os.path.join(self.o, "fig8.csv"))
        f8 = {r["mix"]: r for r in allf if r["variant"] == "per_n"}
        self.assertEqual(set(f8), {"u5", "u50", "u90"})
        # one N in this export: the common_n variant (verifier L1) equals per_n, n_set "2"
        cn = {r["mix"]: r for r in allf if r["variant"] == "common_n"}
        self.assertEqual({m: (r["offered_x"], r["n_set"]) for m, r in cn.items()},
                         {m: (r["offered_x"], "2") for m, r in f8.items()})
        sv = rows(os.path.join(self.o, "steps.csv"))
        for mix, r in f8.items():
            ok = {s: {round(float(x["offered_x"]), 6) for x in sv if x["mix"] == mix and x["system"] == s
                      and x["phase"] == "ramp" and x["pass"] == "True"} for s in ("hw", "pop")}
            self.assertEqual(round(float(r["offered_x"]), 6), max(ok["hw"] & ok["pop"]), mix)
            parts = sum(float(r[k]) for k in ("fig8_norm_query", "fig8_norm_other_fault", "fig8_norm_owner_wait",
                                               "fig8_norm_inval_ipi"))
            self.assertTrue(close(parts, r["fig8_norm_pop"]) and float(r["fig8_norm_hw"]) == 1.0, mix)
        o = os.path.join(OUT, "combined-f8")
        run(f"{EV}/export_h2n.py", "--combine", "--out", o, self.o)
        self.assertEqual(len(rows(os.path.join(o, "fig8.csv"))), 6)

    def test_fig8_common_n(self):
        """verifier L1: common_n = per mix the highest ramp rate passed by hw and pop at EVERY N; synthetic steps of
        N = 2, 4 (pass sets {10, 22.5, 50} / {10, 22.5}) -> per_n 50 / 22.5, common_n 22.5 at both N"""
        sys.path.insert(0, EV)
        import export_h2n as X
        st = []
        for n, offs in ((2, (10, 22.5, 50)), (4, (10, 22.5))):
            for s in ("hw", "pop"):
                for i, off in enumerate(offs + (100,)):
                    st.append(dict(nodes=n, mix="u50", system=s, phase="ramp", step=i + 1, offered_x=off,
                                   **{"pass": off != 100}, valid=None, srch_wall_ns_per_search=1e6 * (2 if s == "pop" else 1),
                                   search_s=off / 2, p99_ms=10, run=1, config_sha256="t"))
        f = X.fig8_rows(st)
        got = sorted((r["variant"], r["nodes"], r["offered_x"], r["n_set"]) for r in f)
        self.assertEqual(got, [("common_n", 2, 22.5, "2/4"), ("common_n", 4, 22.5, "2/4"), ("per_n", 2, 50.0, "2"),
                               ("per_n", 4, 22.5, "4")])
        self.assertTrue(all(r["fig8_norm_pop"] == 2.0 for r in f))

    def test_lowest_ramp_columns(self):
        """verifier L3: summary lowest_ramp_* = the lowest measured ramp step of every search (steps.csv)"""
        sv = rows(os.path.join(self.o, "steps.csv"))
        for k, r in self.s.items():
            ramp = [x for x in sv if (x["mix"], x["system"]) == k and x["phase"] == "ramp"]
            lo = min(ramp, key=lambda x: (float(x["offered_x"]), int(x["step"])))
            self.assertEqual(r["lowest_ramp_step"], lo["step"], k)
            self.assertTrue(close(r["lowest_ramp_search_s"], lo["search_s"]) and close(r["lowest_ramp_p99_ms"], lo["p99_ms"]))
            if k[1] == "mg":
                ops = float(lo["search_s"]) + float(lo["update_s"])
                self.assertTrue(close(r["lowest_ramp_mg_fetch_per_op"], float(lo["mg_fetch"]) / ops), k)
            else:
                self.assertEqual(float(r["lowest_ramp_mg_fetch_per_op"]), 0.0)

    @unittest.skipUnless(os.path.isdir(f"{P}/recovery/confirm-rule-test-run1-n2-v1/block"), "evidence absent")
    def test_fig8_instr_detail0(self):
        """instr detail=0 (recovery/confirm-rule-test-run1-n2-v1, pop-u50-n2-r3): every Fig 8 counter is filled and
        C = opt.search.c_ns on every step with searches"""
        o = os.path.join(OUT, "export-crt")
        run(f"{EV}/export_h2n.py", "--run", "1", "--nodes", "2", "--out", o,
            f"{P}/recovery/confirm-rule-test-run1-n2-v1/block")
        st = rows(f"{P}/recovery/confirm-rule-test-run1-n2-v1/block/pop-u50-n2-r3/slo/stats-steps.csv")
        sv = [r for r in rows(os.path.join(o, "steps.csv")) if r["system"] == "pop" and r["srv_searches"] not in ("", "0")]
        self.assertGreater(len(sv), 10)
        for r0 in sv:
            rs = [r for r in st if int(r["step"]) == int(r0["step"])]
            c = sum(float(r["opt.search.c_ns"] or 0) for r in rs) / sum(float(r["searches"]) for r in rs)
            self.assertTrue(close(r0["srch_C_ns_per_search"], c, 0.05), (r0["step"], r0["srch_C_ns_per_search"], c))
            self.assertGreater(float(r0["srch_is_fault_ns_per_search"]), 0)
            self.assertGreater(float(r0["srch_read_msg_wait_ns_per_search"]), 0)

    def test_layout(self):
        out = run(f"{EV}/h2n_layout.py", "--skip-writes")
        self.assertIn("LAYOUT PASS", out)
        for n, md in ((2, 1835008), (4, 917504), (8, 458752)):
            self.assertIn("LAYOUT PASS", run(f"{EV}/h2n_layout.py", "--check", str(n), str(md)))
        r = subprocess.run([sys.executable, "-I", "-B", f"{EV}/h2n_layout.py", "--check", "8", "1835008"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()

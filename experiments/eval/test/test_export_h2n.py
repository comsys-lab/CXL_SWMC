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

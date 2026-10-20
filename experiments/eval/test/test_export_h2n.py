#!/usr/bin/env python3
"""Tests of experiments/eval/export_h2n.py and h2n_layout.py (Host only; evidence read-only, outputs in EVAL_TEST_OUT).

usage: EVAL_TEST_OUT=<scratch dir (new or empty)> python3 -B test_export_h2n.py [-v]
  1. 2-VM vector DB run 1 (recovery/two-workload-eval-run1-vdb-v1) through export_h2n --source 2vm: nine lifetimes
     (hw, pop, mg x u5, u50, u90); max_under_slo_search_s = loadgen confirm x_mean of every lifetime; Popcorn read /
     write faults at the result = export_h3.py hosts-at-max (vm = all) of the same dirs; Megalon mg_fetch / mg_inval
     at the result = the mean over the confirm steps of megalon.read_retry_incoherent / megalon.flushes summed over the
     targets / max window; hw coherence columns 0; per-lifetime step files and per-VM rows present (2 per step).
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
            for col, key in (("mg_fetch", "megalon.read_retry_incoherent"), ("mg_inval", "megalon.flushes")):
                v = []
                for n in at:
                    rs = [r for r in st if int(r["step"]) == n]
                    v.append(sum(float(r[key]) for r in rs) / max(float(r["window_s"]) for r in rs))
                self.assertTrue(close(self.s[(mix, "mg")][col], sum(v) / len(v)), (mix, col))
                self.assertGreater(float(self.s[(mix, "mg")][col]), 0)
            for col in ("faults_read", "faults_write", "mg_fetch", "mg_inval"):
                self.assertEqual(float(self.s[(mix, "hw")][col]), 0.0)
                if col.startswith("mg"):
                    self.assertEqual(float(self.s[(mix, "pop")][col]), 0.0)

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

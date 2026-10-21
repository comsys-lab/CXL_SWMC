#!/usr/bin/env python3
"""Test of the per-step coherence columns of experiments/vectordb/export.py (canon.VDB_COH, 2026-10-22; Fig 3 of
reports/experiments/de-stijl-motivation-isca27.md). Host only; evidence read-only, output in EVAL_TEST_OUT.

usage: EVAL_TEST_OUT=<scratch dir (new or empty)> python3 -B test_export_vdb_coh.py
On recovery/two-workload-eval-run1-vdb-v1 (2 VMs, u5 u50 u90, fixed windows L1/L2):
  1. Megalon rows: mg_fetch + mg_flush_writeend = mg_flushes (per s); one mg fixed window recomputed from the raw stats
     deltas (read_retry_incoherent, flushes, flush_bytes, opt.*.meg.wflush_*, stale/concur counts, searches);
     fig3_lines_per_rop = events per search x read-side bytes per flush / 64 and > 0;
  2. Popcorn rows: fig3_lines_per_rop = pop_search_is_per_rop x 64 and > 0, Megalon columns empty; hw: 0;
  3. slo_steps.csv carries the same columns (an mg SLO step with mg_fetch_per_s > 0).
"""
import csv
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(EXP, "loadgen"))
import stats_delta  # noqa: E402

E1 = "/home/comsys/sungsu/destijl-control/recovery/two-workload-eval-run1-vdb-v1"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")


def rows(p):
    with open(p) as f:
        return list(csv.DictReader(f))


def close(a, b, rel=1e-6):
    return abs(float(a) - float(b)) <= rel * max(1.0, abs(float(a)), abs(float(b)))


@unittest.skipUnless(os.path.isdir(E1), "evidence absent")
class VdbCoh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.o = os.path.join(OUT, "export-vdb")
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(EXP, "vectordb", "export.py"), "--run", "1",
                            "--config-sha256", "t", "--out", cls.o, E1], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]
        cls.fx = rows(os.path.join(cls.o, "fixed.csv"))

    def test_megalon(self):
        mg = [r for r in self.fx if r["system"] == "mg"]
        self.assertEqual(len(mg), 6)
        for r in mg:
            self.assertTrue(close(float(r["mg_fetch_per_s"]) + float(r["mg_flush_writeend_per_s"]), r["mg_flushes_per_s"]))
            want = float(r["mg_search_events_per_rop"]) * float(r["mg_rflush_bytes_per_flush"]) / 64
            self.assertTrue(close(r["fig3_lines_per_rop"], want) and want > 0, r["point"])
        r = next(x for x in mg if x["point"] == "u50" and x["level"] == "L1")
        t = {}
        for fx, d in stats_delta.deltas(os.path.join(r["source_dir"], "loadgen")):
            if fx["step"] == int(r["step"]):
                for k, v in d.items():
                    t[k] = t.get(k, 0) + v
                t["win"] = max(t.get("win", 0), fx["window_s"])
        self.assertTrue(close(r["mg_fetch_per_s"], t["megalon.read_retry_incoherent"] / t["win"]))
        wb = t["opt.search.meg.wflush_bytes"] + t["opt.update.meg.wflush_bytes"]
        wc = t["opt.search.meg.wflush_cnt"] + t["opt.update.meg.wflush_cnt"]
        self.assertTrue(close(r["mg_rflush_bytes_per_rop"], (t["megalon.flush_bytes"] - wb) / t["searches"]))
        self.assertTrue(close(r["mg_rflush_bytes_per_flush"], (t["megalon.flush_bytes"] - wb) / (t["megalon.flushes"] - wc)))
        self.assertTrue(close(r["mg_search_events_per_rop"],
                              (t["opt.search.meg.stale_cnt"] + t["opt.search.meg.concur_cnt"]) / t["searches"]))

    def test_popcorn_hw(self):
        for r in self.fx:
            if r["system"] == "pop":
                self.assertTrue(close(r["fig3_lines_per_rop"], float(r["pop_search_is_per_rop"]) * 64))
                self.assertGreater(float(r["fig3_lines_per_rop"]), 0)
                self.assertEqual(r["mg_fetch_per_s"], "")
            elif r["system"] == "hw":
                self.assertEqual(float(r["fig3_lines_per_rop"]), 0.0)

    def test_slo_steps(self):
        st = rows(os.path.join(self.o, "slo_steps.csv"))
        self.assertIn("fig3_lines_per_rop", st[0])
        self.assertTrue(any(r["system"] == "mg" and r["mg_fetch_per_s"] and float(r["mg_fetch_per_s"]) > 0 for r in st))


if __name__ == "__main__":
    unittest.main()

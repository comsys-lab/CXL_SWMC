#!/usr/bin/env python3
"""Tests of experiments/eval/export_h3.py (Host only; evidence read-only, outputs in EVAL_TEST_OUT).

usage: EVAL_TEST_OUT=<scratch dir> python3 -B test_export_h3.py [-v]
  1. RocksDB H3 pilot evidence (recovery/ROCKSDB-V1-v2-n{2,4,8}-h3/H3-n<N>, the part of the format that overlaps:
     loadgen steps.jsonl + stats-steps.csv per target): export_h3.part_rows aggregate rates equal the columns of
     workspaces/h3-analysis/h3-n2-n4-n8.csv (made by experiments/rocksdb/h3-faults.py from the same dirs); the per-VM
     rows sum to the aggregate; a wrong node count is refused.
  2. cdf_rows equals experiments/rocksdb/h3-page-cdf.py on a synthetic two-VM hist (one Dropped line).
  3. 2-VM vector DB run 1 (recovery/two-workload-eval-run1-vdb-v1, u50) through main(--source 2vm): at_result rows =
     the confirm repeats at the result rate, hosts-at-max result_x = summary confirm x_mean, per-VM rows present.
"""
import csv
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.dirname(HERE)
sys.path.insert(0, EV)
import export_h3  # noqa: E402

P = "/home/comsys/sungsu/destijl-control"
ANA = f"{P}/workspaces/h3-analysis/h3-n2-n4-n8.csv"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")
COLS = ["read_faults_per_s", "write_faults_per_s", "is_faults_per_s", "inv_commits_per_s", "fetch_commits_per_s",
        "unmaps_per_s", "coh_ipis_per_s", "coh_ipi_ns_per_s", "cxl_recv_run_ns_per_s", "thr_is_faults_per_s",
        "thr_is_fault_ns_per_s", "thr_sm_faults_per_s", "thr_wpu_fault_ns_per_s", "thr_nontrans_faults_per_s"]


def close(a, b, rel=1e-9):
    if a in (None, "") or b in (None, ""):
        return a in (None, "") and b in (None, "")
    a, b = float(a), float(b)
    return abs(a - b) <= rel * max(1.0, abs(a), abs(b))


class RocksdbOverlap(unittest.TestCase):
    def test_aggregate_matches_h3_faults(self):
        ref = {(r["run"], r["step"]): r for r in csv.DictReader(open(ANA))}
        for n in (2, 4, 8):
            part = f"{P}/recovery/ROCKSDB-V1-v2-n{n}-h3/H3-n{n}"
            rows, _ = export_h3.part_rows(part, "rocksdb", n, stream="mixed")
            agg = [r for r in rows if r["vm"] == "all"]
            self.assertTrue(agg, part)
            for r in agg:
                x = ref[(f"H3-n{n}", str(r["step"]))]
                self.assertTrue(close(r["window_s"], x["window_s"]), (n, "window_s"))
                self.assertTrue(close(r["achieved_x"], x["achieved"]), (n, "achieved"))
                for c in COLS:
                    self.assertTrue(close(r[c], x[c]), (n, c, r[c], x[c]))
                self.assertTrue(close(r["read_faults_per_rop"], x["read_faults_per_req"]), (n, "per_rop"))
                vms = [v for v in rows if v["vm"] != "all" and v["step"] == r["step"]]
                self.assertEqual(len(vms), n)
                tot = sum(float(v["read_faults_per_s"]) * float(v["window_s"]) for v in vms)
                self.assertTrue(close(tot, float(r["read_faults_per_s"]) * float(r["window_s"]), 1e-6), (n, "vm sum"))

    def test_wrong_nodes_refused(self):
        with self.assertRaises(SystemExit):
            export_h3.part_rows(f"{P}/recovery/ROCKSDB-V1-v2-n4-h3/H3-n4", "rocksdb", 8, stream="mixed")


class Cdf(unittest.TestCase):
    def test_cdf_equals_h3_page_cdf(self):
        d = os.path.join(OUT, "cdf-synth")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "hist-vm0.txt"), "w").write(
            "# event histogram\n{ pfn:        100 } hitcount:          3\n{ pfn:        101 } hitcount:          1\n"
            "\nTotals:\n    Hits: 4\n    Entries: 2\n    Dropped: 0\n")
        open(os.path.join(d, "hist-vm1.txt"), "w").write(
            "{ pfn:        100 } hitcount:          1\n{ pfn:        205 } hitcount:          7\n    Dropped: 0\n")
        rows, tot = export_h3.cdf_rows(d)
        ref = os.path.join(OUT, "cdf-ref.csv")
        subprocess.run([sys.executable, "-I", "-B", f"{EV}/../rocksdb/h3-page-cdf.py", f"{d}/hist-vm0.txt",
                        f"{d}/hist-vm1.txt", "--out", ref], check=True, capture_output=True)
        want = list(csv.DictReader(open(ref)))
        self.assertEqual(len(rows), len(want))
        for r, x in zip(rows, want):
            for c in ("faults_per_page", "pages", "cum_pages_frac", "cum_faults_frac"):
                self.assertTrue(close(r[c], x[c]), c)
        self.assertEqual((tot["pages_total"], tot["faults_total"], tot["dropped"], tot["complete"]), (4, 12, 0, True))


class TwoVm(unittest.TestCase):
    def test_vdb_u50(self):
        E = f"{P}/recovery/two-workload-eval-run1-vdb-v1"
        if not os.path.isdir(E):
            self.skipTest("no 2-VM run 1 evidence")
        out = os.path.join(OUT, "vdb-n2")
        export_h3.main(["--run", "1", "--runset", "h3-vdb-n2", "--config-sha256", "t", "--out", out, "--source", "2vm",
                        "--point", "u50", E])
        hs = list(csv.DictReader(open(os.path.join(out, "hslo.csv"))))
        for s in ("hw", "pop"):
            part = f"{E}/vdb/r1/run/{s}-u50-slo-r1/slo"
            sm = export_h3.canon.summary(part)
            at = [r for r in hs if r["system"] == s and r["vm"] == "all" and r["at_result"] == "True"]
            self.assertTrue(at)
            self.assertTrue(all(r["phase"] == "confirm" for r in at))
            self.assertTrue(all(close(r["offered_x"], sm["max_offered_x_pass"]) for r in at))
            hm = [r for r in csv.DictReader(open(os.path.join(out, "hosts-at-max.csv"))) if r["system"] == s]
            self.assertEqual([r["vm"] for r in hm], ["all", "0", "1"])
            self.assertTrue(close(hm[0]["result_x"], sm["confirm"]["x_mean"]))
            self.assertEqual(hm[0]["nodes"], "2")
            self.assertEqual(hm[0]["vcpus_per_vm"], "16")


if __name__ == "__main__":
    unittest.main()

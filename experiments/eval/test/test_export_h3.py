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
import shutil
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
            # L3 validity from urate-check.csv, L4 source hash = the vdb run set's config_sha256 (registry)
            self.assertTrue(hm[0]["check"].startswith("URATECHECK"))
            self.assertIn(hm[0]["valid_at_result"], ("True", "False"))
            self.assertEqual(hm[0]["source_config_sha256"], "2943b273264ff78a349c9071bc01cf9efe45734236f47454346ab54faeb9731b")
            self.assertTrue(all(r["valid"] in ("True", "False") for r in hs if r["system"] == s and r["vm"] == "all"))


class H3Layout(unittest.TestCase):
    """--source h3 on a synthetic H3 block dir built from copies of the 2-VM pop u50 part (h3-results.tsv with
    max_offered_x_pass, cdf/ with hist, cdf-rate.txt, cdf-setup.txt pfn_mod) and the pre-CDF estimate"""

    def test_h3_source_and_estimate(self):
        src = f"{P}/recovery/two-workload-eval-run1-vdb-v1/vdb/r1/run/pop-u50-slo-r1/slo"
        if not os.path.isdir(src):
            self.skipTest("no 2-VM run 1 evidence")
        E = os.path.join(OUT, "h3E", "block")
        part = os.path.join(E, "pop-n2", "slo")
        os.makedirs(os.path.join(part, "loadgen"), exist_ok=True)
        os.makedirs(os.path.join(E, "cdf"), exist_ok=True)
        for f in ("loadgen/steps.jsonl", "loadgen/summary.json", "stats-steps.csv", "urate-check.csv", "urate-check.txt"):
            shutil.copyfile(os.path.join(src, f), os.path.join(part, f))
        sm = export_h3.canon.summary(part)
        with open(os.path.join(E, "h3-results.tsv"), "w") as f:
            f.write("# name\tsystem\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\n")
            f.write(f"pop-n2\tpop\t2\t16\t{sm['max_offered_x_pass']}\t{sm['confirm']['x_mean']}\tTrue\t\tpop-n2/slo\n")
        with open(os.path.join(E, "h3-params.txt"), "w") as f:
            f.write("writes=x sha256=y U=50\n")
        with open(os.path.join(E, "cdf", "cdf-rate.txt"), "w") as f:
            f.write(f"cdf rate: Popcorn max_offered_x_pass {sm['max_offered_x_pass']} at N=2 (offered rate)\n")
        with open(os.path.join(E, "cdf", "cdf-setup.txt"), "w") as f:
            f.write("2026-10-20T00:00:00 pfn_mod=4 filter=[kind==0 && tr==1 && !(pfn & 3)]\n")
        with open(os.path.join(E, "cdf", "hist-vm0.txt"), "w") as f:
            f.write("{ pfn:          4 } hitcount:          2\n    Dropped: 0\n")
        with open(os.path.join(E, "cdf", "hist-vm1.txt"), "w") as f:
            f.write("{ pfn:          8 } hitcount:          1\n    Dropped: 3\n")
        with open(os.path.join(OUT, "h3E", "eval-manifest.txt"), "w") as f:
            f.write("eval_conf=x sha256=y config_sha256=" + "a" * 64 + "\n")
        out = os.path.join(OUT, "h3-out")
        export_h3.main(["--run", "1", "--runset", "h3-vdb-n2", "--config-sha256", "t", "--out", out, E])
        with open(os.path.join(out, "cdf.csv")) as f:
            cd = list(csv.DictReader(f))
        self.assertEqual(len(cd), 2)
        self.assertEqual((cd[0]["pfn_mod"], cd[0]["complete"], cd[0]["dropped"]), ("4", "False", "3"))
        self.assertTrue(close(cd[0]["offered_x"], sm["max_offered_x_pass"]))
        with open(os.path.join(out, "hosts-at-max.csv")) as f:
            hm = list(csv.DictReader(f))
        self.assertEqual(hm[0]["point"], "u50")
        self.assertEqual(hm[0]["source_config_sha256"], "a" * 64)
        sys.path.insert(0, EV)
        import h3_cdf_estimate
        per, mx, sug = h3_cdf_estimate.estimate(part, 2, 80, 1)
        self.assertEqual(len(per), 2)
        self.assertTrue(all(n == 3 for _, n, _, _ in per))
        self.assertTrue(mx > 0 and sug >= 1)
        _, mx4, _ = h3_cdf_estimate.estimate(part, 2, 80, 4)
        self.assertTrue(close(mx4 * 4, mx, 1e-9))

    def test_cdf_filter(self):
        f = lambda m: subprocess.run(["bash", f"{EV}/h3-cdf.sh", "filter"], env=dict(os.environ, H3_CDF_PFN_MOD=m),
                                     capture_output=True, text=True)
        self.assertEqual(f("1").stdout.strip(), "kind==0 && tr==1")
        self.assertEqual(f("16").stdout.strip(), "kind==0 && tr==1 && !(pfn & 15)")
        self.assertNotEqual(f("12").returncode, 0)


if __name__ == "__main__":
    unittest.main()

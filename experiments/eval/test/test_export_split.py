#!/usr/bin/env python3
"""Test of experiments/vectordb/export.py with several evidence dirs (one run's H1 mixes split over evidence versions,
2026-10-22: eval2 run 1 H1 = v1 u50 u90 + v2 u10). Host only; evidence read-only, output in EVAL_TEST_OUT.

usage: EVAL_TEST_OUT=<scratch dir> python3 -B test_export_split.py [-v]
On recovery/eval2-run1-h1-n2-v1 (u50, u90): builds two view dirs in EVAL_TEST_OUT (eval-manifest.txt copy, vdb/r1/run/
h1-runs.tsv with the u50 rows / the u90 rows, lifetime dirs as symlinks into the evidence) and checks:
  1. export.py --run 1 <view u50> <view u90> = export.py --run 1 <v1> on every canonical CSV (source_dir aside);
  2. a mix present in both dirs, a config_sha256 or run number other than the eval-manifest's: refused (exit != 0).
"""
import csv
import os
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(os.path.dirname(HERE))
EXPORT = os.path.join(EXP, "vectordb", "export.py")
E1 = "/home/comsys/sungsu/destijl-control/recovery/eval2-run1-h1-n2-v1"
SHA = "8a9327ba56a9a7d76a2d33ab65ac774eed4e4f28ea793de7e212a850f7b9f6af"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")
CSVS = ("slo_summary.csv", "slo_steps.csv", "latency_hist.csv", "fixed.csv", "mg_probe.csv")


def view(name, mixes):
    d = os.path.join(OUT, name)
    if os.path.exists(d):
        shutil.rmtree(d)
    run = os.path.join(d, "vdb", "r1", "run")
    os.makedirs(run)
    shutil.copy2(os.path.join(E1, "eval-manifest.txt"), d)
    src = os.path.join(E1, "vdb", "r1", "run")
    with open(os.path.join(src, "h1-runs.tsv")) as f, open(os.path.join(run, "h1-runs.tsv"), "w") as g:
        for line in f:
            x = line.split("\t")
            if line.startswith("#") or x[2] in mixes:
                g.write(line)
                if not line.startswith("#") and not os.path.lexists(os.path.join(run, x[5].split("/")[0])):
                    os.symlink(os.path.join(src, x[5].split("/")[0]), os.path.join(run, x[5].split("/")[0]))
    return d


def export(out, *dirs, run=1, sha=SHA):
    return subprocess.run([sys.executable, "-B", EXPORT, "--run", str(run), "--runset", "vdb", "--config-sha256", sha,
                           "--out", os.path.join(OUT, out), *dirs], capture_output=True, text=True)


def table(d, name):
    with open(os.path.join(OUT, d, name)) as f:
        return sorted(tuple(v for k, v in r.items() if k != "source_dir") for r in csv.DictReader(f))


@unittest.skipUnless(os.path.isdir(E1), "evidence absent")
class Split(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.a, cls.b = view("view-u50", {"u50"}), view("view-u90", {"u90"})
        cls.both = view("view-u50u90", {"u50", "u90"})

    def test_split_equals_single(self):
        p = export("single", E1)
        self.assertEqual(p.returncode, 0, p.stderr)
        p = export("split", self.a, self.b)
        self.assertEqual(p.returncode, 0, p.stderr)
        for n in CSVS:
            self.assertEqual(table("split", n), table("single", n), n)
        self.assertGreater(len(table("split", "fixed.csv")), 0)

    def test_refusals(self):
        p = export("dup", self.a, self.both)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("mix u50", p.stderr)
        p = export("sha", self.a, self.b, sha="0" * 64)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("config_sha256", p.stderr)
        p = export("run", self.a, self.b, run=2)
        self.assertNotEqual(p.returncode, 0)


if __name__ == "__main__":
    unittest.main()

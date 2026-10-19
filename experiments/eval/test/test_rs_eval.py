#!/usr/bin/env python3
"""Tests of the RecSys evaluation paths that have no real evidence yet (Host only; evidence read-only, copies only).

usage: EVAL_TEST_OUT=<scratch dir> python3 -B test_rs_eval.py [-v]
Builds a synthetic rs-h1 run-set root from copies of real RECSYS-stream-v1c part files (steps.jsonl with the real
field layout, plus blank lines; summary.json; stream-check.csv; breakdown.csv):
  probe/ (mg fix-only windows at 50 and 200 samples/s, level Q1) and slo/ (an mg window at 50, level Q1, an mgoff
  window at 50), mg-decision.tsv. Checks: mg_decide.py (blank lines skipped, p95 rule, valid rule; verifier L4),
  export.py: probe row dropped where the run has its own mg window (rate 50), kept where it is the only one (200);
  mg_probe.csv rows; mgoff T joined on the mg row (verifier M5). Also main-block.sh eval_levels_compute: a confirmed
  but not valid result counts as no result (verifier M2).
"""
import csv
import json
import os
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.dirname(HERE)
EXP = os.path.dirname(EV)
sys.path.insert(0, EV)
import mg_decide  # noqa: E402

REC = "/home/comsys/sungsu/destijl-control/recovery/RECSYS-stream-v1c"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")


def part(dst, src, step_p95=None):
    """copy the small files of a real SLO part into <dst>/fix; optional p95 override of every step; blank lines"""
    os.makedirs(os.path.join(dst, "fix", "loadgen"))
    for f in ("stream-check.csv", "breakdown.csv"):
        shutil.copy(os.path.join(src, f), os.path.join(dst, "fix", f))
    shutil.copy(os.path.join(src, "loadgen", "summary.json"), os.path.join(dst, "fix", "loadgen"))
    with open(os.path.join(src, "loadgen", "steps.jsonl")) as fi, \
            open(os.path.join(dst, "fix", "loadgen", "steps.jsonl"), "w") as fo:
        for line in fi:
            d = json.loads(line)
            if step_p95 is not None:
                d["streams"]["query"]["p95_ms"] = step_p95
            fo.write(json.dumps(d) + "\n\n")  # blank lines as a robustness case


def tsv(path, header, rows):
    with open(path, "w") as f:
        f.write(header + "\n")
        for r in rows:
            f.write("\t".join(r) + "\n")


class RsEval(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        E = cls.E = os.path.join(OUT, "rs-h1-synthetic")
        shutil.rmtree(E, ignore_errors=True)
        src = os.path.join(REC, "hw-u50", "slo")
        hdr = "# name\tsystem\trate_sps\tlevel\toffered_q_s\tstep\tvalid"
        part(os.path.join(E, "probe", "mg-u50-fix"), src, 80.0)     # passes the 100 ms rule
        part(os.path.join(E, "probe", "mg-u200-fix"), src, 4700.0)  # fails it
        tsv(os.path.join(E, "probe", "stream-fix.tsv"), hdr,
            [["mg-u50-fix", "mg", "50", "Q1", "1", "1", "1"], ["mg-u200-fix", "mg", "200", "Q1", "1", "1", "1"]])
        tsv(os.path.join(E, "probe", "stream-results.tsv"), "# name", [])
        part(os.path.join(E, "slo", "mg-u50-fix"), src)
        part(os.path.join(E, "slo", "mgoff-u50-fix"), src)
        tsv(os.path.join(E, "slo", "stream-fix.tsv"), hdr,
            [["mg-u50-fix", "mg", "50", "Q1", "1", "2", "1"], ["mgoff-u50-fix", "mgoff", "50", "Q1", "1", "3", "1"]])
        tsv(os.path.join(E, "slo", "stream-results.tsv"), "# name", [])
        cls.dec = mg_decide.decide(os.path.join(E, "probe"), ["50", "200"], 100.0)
        tsv(os.path.join(E, "mg-decision.tsv"), "# rate_sps\tdecision", [x[:2] for x in cls.dec])
        cls.out = os.path.join(OUT, "rs-h1-synthetic-export")
        r = subprocess.run([sys.executable, "-B", os.path.join(EXP, "recsys", "export.py"), "--run", "1", "--runset",
                            "rs-h1", "--config-sha256", "t", "--out", cls.out, E], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr[-2000:]

    def rows(self, name):
        with open(os.path.join(self.out, name)) as f:
            return list(csv.DictReader(f))

    def test_decision(self):
        self.assertEqual([x[:2] for x in self.dec], [["50", "slo"], ["200", "fix"]])
        self.assertEqual(self.dec[0][2], "80.0")

    def test_probe_dedup_and_mgoff(self):
        fx = self.rows("fixed.csv")
        mg = [(r["point"], r["lifetime"]) for r in fx if r["system"] == "mg"]
        self.assertEqual(sorted(mg), [("200", "probe"), ("50", "sep")])
        m50 = next(r for r in fx if r["system"] == "mg" and r["point"] == "50")
        off = next(r for r in fx if r["system"] == "mgoff")
        self.assertEqual(m50["mgoff_T_ms_rop"], off["T_ms_rop"])
        self.assertTrue(all(r["level"] == "Q1" for r in fx))

    def test_mg_probe_csv(self):
        pr = {r["point"]: r for r in self.rows("mg_probe.csv")}
        self.assertEqual(set(pr), {"50", "200"})
        self.assertEqual(pr["50"]["decision"], "slo")
        self.assertEqual(pr["200"]["decision"], "fix")

    def test_levels_require_valid(self):
        d = os.path.join(OUT, "levels-m2")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        with open(os.path.join(REC, "stream-results.tsv")) as fi, open(os.path.join(d, "stream-results.tsv"), "w") as fo:
            for line in fi:
                f = line.rstrip("\n").split("\t")
                if f[0] == "pop-u50":
                    f[8] = "0"
                fo.write("\t".join(f) + "\n")
        with open(os.path.join(d, "stream-levels.tsv"), "w") as f:
            f.write("# h\n")
        mb = os.path.join(EXP, "recsys", "main-block.sh")
        fn = subprocess.run(["sed", "-n", "/^eval_levels_compute() {/,/^}/p", mb], capture_output=True, text=True).stdout
        subprocess.run(["bash", "-c", fn + f"\nE={d}; eval_levels_compute 50; eval_levels_compute 200; true"], check=True)
        with open(os.path.join(d, "stream-levels.tsv")) as f:
            lv = {x.split("\t")[0]: x.rstrip("\n").split("\t") for x in f if not x.startswith("#")}
        self.assertEqual(lv["50"][1], "-")
        self.assertIn("excluded: update stream not sustained", lv["50"][3])
        self.assertEqual(lv["200"][1], "22.027")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests of experiments/vectordb/late_resp.py and of opcoh_check.py on late responses (Host only).

usage: python3 -B late_resp_test.py [-v]          (synthetic tests, temporary dirs)
       OPCOH_TEST_OUT=<scratch dir> python3 -B late_resp_test.py [-v]
         + evidence test: copies recovery/eval2-run1-h1-n2-v1 pop-u10-slo-r1 (late responses in the saturated overload
           steps 23 and 24) and pop-u50-slo-r1 (none) into the scratch dir (opsplit.py writes next to its input; the
           evidence stays read-only) and runs opcoh_check.py popcorn on both: PASS, the u10 one with the late / lost
           NOTE lines (8 late measured records, 2 without a searches.bin record, 56 lost searches).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, "experiments", "vectordb"))
import late_resp  # noqa: E402
import opsplit  # noqa: E402

EV = "/home/comsys/sungsu/destijl-control/recovery/eval2-run1-h1-n2-v1/vdb/r1/run"


def write_lg(d, steps, raws):
    """steps: list of (step, phase, aborted, search timeouts); raws: {step: [(req_id, done, status, measured)]}"""
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "steps.jsonl"), "w") as f:
        for s, ph, ab, to in steps:
            f.write(json.dumps({"step": s, "phase": ph, "aborted": ab, "measure_s": 15,
                                "streams": {"update": {"timeouts": 0}, "search": {"timeouts": to}}}) + "\n")
    for s, rows in raws.items():
        r = np.array([[1, 2, done, (1 << 32) | st | (m << 40)] for _, done, st, m in rows], dtype=np.uint64)
        r.tofile(os.path.join(d, f"raw-step{s}.bin"))
        np.array([q for q, *_ in rows], dtype=np.uint64).tofile(os.path.join(d, f"rawid-step{s}.bin"))


def recs(req_ids, measured=1):
    x = np.zeros(len(req_ids), dtype=opsplit.OPLOG)
    x["op"], x["measured"] = 3, measured
    x["c"]["req_id"] = req_ids
    return x


class LateResp(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.t)

    def test_classes(self):
        lg = os.path.join(self.t, "lg")
        # step 1 ramp (normal), step 2 overload not aborted, step 3 aborted ramp-like step
        write_lg(lg, [(0, "warmup", False, 0), (1, "ramp", False, 1), (2, "overload", False, 2), (3, "fill", True, 1)],
                 {1: [(10, 5, 0, 1), (11, 0, 0, 1), (12, 5, 3, 1)],
                  2: [(20, 5, 0, 1), (21, 0, 0, 1), (22, 0, 0, 1), (23, 5, 4, 1)],
                  3: [(30, 0, 0, 1)]})
        got = late_resp.late(lg, recs([10, 11, 12, 20, 21, 23, 30, 99]))
        self.assertEqual(got, [("ok", 1), ("bad", 1), ("bad", 1), ("ok", 2), ("late", 2), ("late", 2), ("late", 3),
                               ("bad", -1)])
        self.assertEqual(late_resp.saturated_timeouts(lg, "search"), 3)
        self.assertEqual(late_resp.search_timeouts(lg), 4)
        # lost = saturated timeouts 3 - measured late records 2 (21, 30); a non-measured late record does not count
        r = recs([21, 30, 22])
        r["measured"][2] = 0
        self.assertEqual(late_resp.lost(lg, r, "search"), 1)

    def test_no_sidecar(self):
        lg = os.path.join(self.t, "lg")
        write_lg(lg, [(1, "overload", True, 1)], {1: [(10, 0, 0, 1)]})
        os.remove(os.path.join(lg, "rawid-step1.bin"))
        self.assertIsNone(late_resp.raw_rows(lg))
        self.assertEqual(late_resp.late(lg, recs([10])), [("unknown", -1)])
        self.assertIsNone(late_resp.lost(lg, recs([10]), "search"))


@unittest.skipUnless(os.environ.get("OPCOH_TEST_OUT") and os.path.isdir(EV), "OPCOH_TEST_OUT unset or evidence absent")
class Evidence(unittest.TestCase):
    def run_check(self, life):
        out = os.path.join(os.environ["OPCOH_TEST_OUT"], life)
        if os.path.exists(out):
            shutil.rmtree(out)
        os.makedirs(os.path.join(out, "slo"))
        for k in (0, 1):
            shutil.copy2(os.path.join(EV, life, f"node{k}.log"), out)
        shutil.copytree(os.path.join(EV, life, "slo", "loadgen"), os.path.join(out, "slo", "loadgen"))
        p = subprocess.run([sys.executable, "-B", os.path.join(HERE, "opcoh_check.py"), os.path.join(out, "slo"), "popcorn"],
                           env=dict(os.environ, OPCOH_PARTS=os.path.join(out, "slo")), capture_output=True, text=True)
        return p.returncode, p.stdout

    def test_u10_late(self):
        rc, o = self.run_check("pop-u10-slo-r1")
        self.assertEqual(rc, 0, o[-2000:])
        self.assertIn("OPCOH_CHECK PASS", o)
        self.assertIn("2 search records without an OK loadgen response", o)
        self.assertIn("8 measured op records are late responses", o)
        self.assertIn("{'search': 56, 'update': 0}", o)

    def test_u50_exact(self):
        rc, o = self.run_check("pop-u50-slo-r1")
        self.assertEqual(rc, 0, o[-2000:])
        self.assertIn("OPCOH_CHECK PASS", o)
        self.assertNotIn("late responses", o)
        self.assertNotIn("lost responses", o)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Unit test of experiments/rocksdb/slo_result.py (SLO-search cell decision logic) on synthetic step data. Host only.
usage: python3 -I -B test/test_slo_result.py [-v]"""
import json, os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import slo_result as sr  # noqa: E402

SLO = {"stream": "mixed", "pct": 99, "ms": 1}


def st(phase, off, ok, x=None, p99=0.5):
    return {"step": 0, "phase": phase, "offered_x": off, "x": off * 0.99 if x is None else x, "pass": ok,
            "aborted": False, "reason": "", "streams": {"mixed": {"achieved": off, "p99_ms": p99}}}


def confirmed_cell():
    steps = [st("warmup", 500, False, 0), st("ramp", 500, True), st("ramp", 1125, True), st("ramp", 2531, True),
             st("ramp", 5695, False, p99=3), st("bisect", 3797, True), st("bisect", 4650, False, p99=2),
             st("confirm", 4200, False, p99=1.2), st("confirm", 3990, True, x=3985.0, p99=0.8),
             st("confirm", 4095, False, p99=1.1), st("fill", 2793, True), st("overload", 3591, True),
             st("overload", 4389, False, p99=1.4), st("overload", 7980, False, p99=9)]
    summ = {"slo": SLO, "note": "", "confirmed": True, "max_offered_x_pass": 3990, "workload_finish": "ok",
            "confirm": {"reps": 1, "fails": 0, "x_mean": 3985.0, "pslo_mean_ms": 0.8}}
    return summ, steps


class Decide(unittest.TestCase):
    def test_confirmed(self):
        s, steps = confirmed_cell()
        d = sr.decide(s, steps, "pop")
        self.assertEqual(d["check"], "OK", d["why"])
        self.assertEqual((d["max_rps_under_slo"], d["src"]), (3985.0, "confirm"))
        self.assertEqual((d["n_ramp"], d["n_bisect"], d["n_confirm"], d["n_fill"], d["n_overload"]), (4, 2, 3, 1, 3))
        self.assertEqual(d["overload_past_knee"], 2)

    def test_confirm_inconsistent(self):
        s, steps = confirmed_cell()
        s["max_offered_x_pass"] = 4095  # not the highest passing confirm
        d = sr.decide(s, steps, "pop")
        self.assertEqual(d["check"], "ERROR")

    def test_multi_rep_confirm_skips_recompute(self):
        s, steps = confirmed_cell()
        s["confirm"]["reps"] = 3
        s["max_offered_x_pass"] = 4095
        self.assertEqual(sr.decide(s, steps, "pop")["check"], "OK")

    def test_no_point_past_knee_is_warn(self):
        s, steps = confirmed_cell()
        steps = [x for x in steps if x["phase"] != "overload"] + [st("overload", 3591, True)]
        d = sr.decide(s, steps, "hw")
        self.assertEqual(d["check"], "WARN")
        self.assertEqual(d["overload_past_knee"], 0)

    def test_send_lag_is_warn(self):
        s, steps = confirmed_cell()
        s["passing_steps_with_send_lag"] = 2
        d = sr.decide(s, steps, "hw")
        self.assertEqual((d["check"], d["send_lag_steps"], d["max_rps_under_slo"]), ("WARN", 2, 3985.0))

    def test_start_fail_decision_e(self):
        steps = [st("warmup", 500, False, 0), st("ramp", 500, False, x=470.0, p99=4), st("overload", 625, False, p99=5),
                 st("overload", 750, False, p99=7)]
        s = {"slo": SLO, "note": sr.NOTED[0], "confirmed": False, "max_offered_x_pass": None, "workload_finish": "ok"}
        d = sr.decide(s, steps, "pop")
        self.assertEqual((d["check"], d["max_rps_under_slo"], d["src"], d["overload_past_knee"]), ("OK", 470.0, "lowest_step", 2))
        self.assertEqual(sr.decide(s, steps, "hw")["check"], "ERROR")  # never for all-HWcc

    def test_confirm_failed_note(self):
        s, steps = confirmed_cell()
        s.update(note=sr.NOTED[1], confirmed=False, max_offered_x_pass=3990)
        d = sr.decide(s, steps, "ds")
        self.assertEqual((d["check"], d["src"], d["max_rps_under_slo"]), ("OK", "lowest_step", 495.0))
        self.assertIsNone(d["confirm_x_mean"])

    def test_errors(self):
        s, steps = confirmed_cell()
        for mut in ({"note": "streams exhausted during ramp"}, {"workload_finish": "error"},
                    {"slo": {"stream": "mixed", "pct": 99, "ms": 100}}, {"confirmed": False}):
            t = dict(s, **mut)
            self.assertEqual(sr.decide(t, steps, "pop")["check"], "ERROR", mut)


class Files(unittest.TestCase):
    def test_rows_and_exit(self):
        s, steps = confirmed_cell()
        with tempfile.TemporaryDirectory() as td:
            good = os.path.join(td, "pop-u50-n4")
            bad = os.path.join(td, "hw-u5-n2")
            for d, summ in ((good, s), (bad, dict(s, note="max steps reached without an SLO violation; raise --start or --max-steps"))):
                os.makedirs(os.path.join(d, "loadgen"))
                json.dump(summ, open(os.path.join(d, "loadgen", "summary.json"), "w"))
                with open(os.path.join(d, "loadgen", "steps.jsonl"), "w") as f:
                    f.write("\n".join(json.dumps(x) for x in steps) + "\n")
            out = os.path.join(td, "r.tsv")
            self.assertEqual(sr.main(["--out", out, good]), 0)
            rows = [l.split("\t") for l in open(out).read().splitlines()]
            self.assertEqual(rows[0][0], "# name")
            r = dict(zip(sr.COLS, rows[1]))
            self.assertEqual((r["system"], r["mix"], r["U"], r["nodes"], r["max_rps_under_slo"], r["check"]),
                             ("pop", "u50", "50", "4", "3985", "OK"))
            self.assertEqual(sr.main(["--out", out, good]), 2)  # never overwrites
            self.assertEqual(sr.main([good, bad]), 1)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Unit test of experiments/h1/levels.py decision E (user 2026-10-22, de-stijl-motivation-isca27 §6 E). Host only.

usage: python3 -I -B test_levels.py <scratch dir (new or empty)> [-v]
Synthetic SLO runs (h1-runs.tsv + <run>/loadgen/{summary.json,steps.jsonl}) of the vdb plan rows u5 and u90:
  1. every search confirmed: x = confirm.x_mean, x_*_src confirm, L1 = min, L2 = L1 / 2, rates = x x plan factor;
  2. mg u90 "the start rate already violates the SLO" (with start-fail overload steps above the start): x_mg = the
     achieved x of the lowest measured ramp step (not the overload steps, not the warmup), x_mg_src lowest_step,
     weakest mg, L1 = that x; the --mix append mode keeps the older rows and the header;
  3. pop u5 "confirm failed at three rates" (summary still carries a confirm block): x = lowest ramp step as well;
  4. no confirm result without a note: lowest ramp step;
  5. real errors stop (exit 1, LEVELS STOP): another note, workload_finish != ok, SLO != plan, unreadable summary,
     a missing system run, a fallback run without a measured ramp step;
  7. verifier M1: All-HWcc without a confirmed max always stops (both policies);
  8. verifier M2 / user 2026-10-22: plan directive levels_confirm_fail=highest_pass -> a confirm-failed search uses
     its highest passing ramp/bisect step (src highest_pass), a failed start rate still the lowest ramp step;
  6. real data: recovery/vdb-vm-scaling-sq8-run1-n4-v1 mg-u90-n4 (start rate failed): system_x = (1.01415,
     lowest_step), the hatched value of Fig 5; a confirmed hw run there: its confirm x_mean.
"""
import csv
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
H1 = os.path.dirname(HERE)
sys.path.insert(0, H1)
import levels  # noqa: E402

OUT = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else sys.exit("usage: test_levels.py <dir>")
PLAN = os.path.join(OUT, "plan.tsv")  # the vdb u5 and u90 rows of h1-plan.tsv (written in main)
PLAN_HP = os.path.join(OUT, "plan-hp.tsv")  # the same with "#! levels_confirm_fail=highest_pass" (verifier M2)
PLAN_BAD = os.path.join(OUT, "plan-bad.tsv")  # ... with a bad directive value
REAL = "/home/comsys/sungsu/destijl-control/recovery/vdb-vm-scaling-sq8-run1-n4-v1/block"
SLO = {"stream": "search", "pct": 99, "ms": 100}


def step(n, phase, off, x, ok, measure=15):
    return {"step": n, "phase": phase, "offered_x": off, "measure_s": measure, "x": x, "pass": ok, "aborted": False}


def make_run(d, name, confirm=None, note="", finish="ok", slo=SLO, ramp=True, start_fail=False):
    ld = os.path.join(d, name, "loadgen")
    os.makedirs(ld)
    st = [step(0, "warmup", 10, 0, False, 0)]
    if ramp:
        st += [step(1, "ramp", 10, 0.6, not start_fail), step(2, "ramp", 22.5, 1.3, not start_fail)]
    if start_fail:
        st += [step(3, "overload", 15, 0.7, False), step(4, "overload", 22.5, 0.9, False)]
    with open(os.path.join(ld, "steps.jsonl"), "w") as f:
        f.write("".join(json.dumps(s) + "\n" for s in st))
    s = {"mode": "slo", "note": note, "slo": slo, "workload_finish": finish}
    if confirm is not None:
        s["confirm"] = {"reps": 1, "fails": 0, "x_mean": confirm, "x_sd": 0.0}
    json.dump(s, open(os.path.join(ld, "summary.json"), "w"))


def make_stage(d, runs):
    """runs: {(sys, mix): kwargs of make_run}; writes h1-runs.tsv (v2, 8 columns)"""
    os.makedirs(d)
    with open(os.path.join(d, "h1-runs.tsv"), "w") as f:
        f.write("# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n")
        for (s, m), kw in runs.items():
            make_run(d, f"{s}-{m}", **kw)
            f.write(f"{s}-{m}-slo-r1\t{s}\t{m}\tslo\t1\t{s}-{m}\t-\tsep\n")


def run_levels(*a):
    r = subprocess.run([sys.executable, "-I", "-B", os.path.join(H1, "levels.py"), "--plan", PLAN, "--workload", "vdb",
                        *a], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def table(p):
    with open(p) as f:
        return {r["mix"]: r for r in csv.DictReader(f, delimiter="\t")}


def base():
    return {("hw", "u5"): dict(confirm=170.0), ("pop", "u5"): dict(confirm=158.0), ("mg", "u5"): dict(confirm=148.0),
            ("hw", "u90"): dict(confirm=69.0), ("pop", "u90"): dict(confirm=63.0), ("mg", "u90"): dict(confirm=3.2)}


class Levels(unittest.TestCase):
    n = 0

    def stage(self, runs):
        Levels.n += 1
        d = os.path.join(OUT, f"case{Levels.n}")
        make_stage(d, runs)
        return d

    def ok(self, d, *a):
        out = os.path.join(d, "levels.tsv")
        rc, log = run_levels("--out", out, *a, d)
        self.assertEqual(rc, 0, log)
        self.assertIn("LEVELS OK", log)
        return table(out), log

    def stops(self, runs, want, *a):
        d = self.stage(runs)
        rc, log = run_levels("--out", os.path.join(d, "levels.tsv"), *a, d)
        self.assertEqual(rc, 1, log)
        self.assertIn("LEVELS STOP", log)
        self.assertIn(want, log)

    def test_1_all_confirmed(self):
        t, _ = self.ok(self.stage(base()))
        u = t["u90"]
        self.assertEqual((u["weakest"], float(u["L1_x"]), float(u["L2_x"])), ("mg", 3.2, 1.6))
        self.assertEqual((u["L1_rate"], u["L2_rate"]), ("32.0", "16.0"))  # factor 10, 3 decimals
        self.assertEqual([u[f"x_{k}_src"] for k in ("hw", "pop", "mg")], ["confirm"] * 3)
        self.assertEqual(list(t["u5"])[-3:], ["x_hw_src", "x_pop_src", "x_mg_src"])
        self.assertEqual(list(t["u5"])[8:10], ["L1_rate", "L2_rate"])  # v6-block.sh h1_levels reads $9, $10

    def test_2_start_fail_lowest_step(self):
        r = base()
        r[("mg", "u90")] = dict(note=levels.START_NOTE, start_fail=True)
        d = self.stage(r)
        t, log = self.ok(d, "--mix", "u5")  # append mode: u5 first, then u90
        out = os.path.join(d, "levels.tsv")
        rc, log = run_levels("--out", out, "--mix", "u90", d)
        self.assertEqual(rc, 0, log)
        t = table(out)
        self.assertEqual(set(t), {"u5", "u90"})
        u = t["u90"]
        self.assertEqual((u["x_mg_src"], float(u["x_mg"]), u["weakest"], float(u["L1_x"])), ("lowest_step", 0.6, "mg", 0.6))
        self.assertEqual((u["L1_rate"], u["L2_rate"]), ("6.0", "3.0"))
        self.assertEqual(t["u5"]["x_mg_src"], "confirm")
        self.assertIn("decision E: no confirmed max for mg", log)

    def test_3_confirm_failed_lowest_step(self):
        r = base()
        r[("pop", "u5")] = dict(note=levels.CONFIRM_NOTE, confirm=150.0)
        t, _ = self.ok(self.stage(r))
        self.assertEqual((t["u5"]["x_pop_src"], float(t["u5"]["x_pop"]), t["u5"]["weakest"]), ("lowest_step", 0.6, "pop"))

    def test_4_no_confirm_result(self):
        r = base()
        r[("pop", "u90")] = dict()
        t, _ = self.ok(self.stage(r))
        self.assertEqual((t["u90"]["x_pop_src"], float(t["u90"]["x_pop"])), ("lowest_step", 0.6))

    def test_7_hw_never_fallback(self):
        """verifier M1: All-HWcc without a confirmed max (start fail, confirm fail, no result) is a LEVELS STOP,
        under both confirm-failed policies"""
        for kw in (dict(note=levels.START_NOTE, start_fail=True), dict(note=levels.CONFIRM_NOTE, confirm=60.0), dict()):
            for plan in (PLAN, PLAN_HP):
                r = base()
                r[("hw", "u90")] = kw
                self.stops(r, "All-HWcc has no confirmed max", "--plan", plan)
        with self.assertRaises(levels.LevelsError):
            d = self.stage({("hw", "u5"): dict(note=levels.CONFIRM_NOTE, confirm=60.0)})
            levels.system_x(os.path.join(d, "hw-u5"), "search:99:100", "highest_pass", "hw")

    def test_8_highest_pass_switch(self):
        """verifier M2 / user 2026-10-22: plan directive levels_confirm_fail=highest_pass: a confirm-failed search uses
        the highest passing ramp/bisect step (x 1.3 at offered 22.5, src highest_pass); a failed start rate still the
        lowest ramp step; without the directive (PLAN) lowest_step (test 3); a bad value stops"""
        r = base()
        r[("pop", "u5")] = dict(note=levels.CONFIRM_NOTE, confirm=150.0)
        r[("mg", "u90")] = dict(note=levels.START_NOTE, start_fail=True)
        t, _ = self.ok(self.stage(r), "--plan", PLAN_HP)
        self.assertEqual((t["u5"]["x_pop_src"], float(t["u5"]["x_pop"])), ("highest_pass", 1.3))
        self.assertEqual((t["u90"]["x_mg_src"], float(t["u90"]["x_mg"])), ("lowest_step", 0.6))
        self.assertEqual(levels.plan_confirm_fail(PLAN), "lowest_step")
        self.assertEqual(levels.plan_confirm_fail(PLAN_HP), "highest_pass")
        self.stops(base(), "levels_confirm_fail=bogus", "--plan", PLAN_BAD)

    def test_5_real_errors_stop(self):
        for kw, want in ((dict(note="streams exhausted during ramp", confirm=3.0), "not a decision-E outcome"),
                         (dict(confirm=3.0, finish="error: x"), "workload_finish"),
                         (dict(confirm=3.0, slo={"stream": "search", "pct": 95, "ms": 100}), "SLO search:95:100"),
                         (dict(note=levels.START_NOTE, ramp=False), "no measured ramp step")):
            r = base()
            r[("mg", "u90")] = kw
            self.stops(r, want)
        r = base()
        del r[("pop", "u5")]
        self.stops(r, "system pop: 0 SLO runs")
        d = self.stage(base())
        open(os.path.join(d, "hw-u5", "loadgen", "summary.json"), "w").write("{broken")
        rc, log = run_levels("--out", os.path.join(d, "levels.tsv"), d)
        self.assertEqual(rc, 1)
        self.assertIn("cannot read", log)

    @unittest.skipUnless(os.path.isdir(REAL), "real H2 pilot evidence absent")
    def test_6_real_data(self):
        x, sd, p, how = levels.system_x(os.path.join(REAL, "mg-u90-n4", "slo"), "search:99:100")
        self.assertEqual((round(x, 5), how), (1.01415, "lowest_step"))
        x, sd, p, how = levels.system_x(os.path.join(REAL, "hw-u5-n4", "slo"), "search:99:100")
        s = json.load(open(os.path.join(REAL, "hw-u5-n4", "slo", "loadgen", "summary.json")))
        self.assertEqual((x, how), (s["confirm"]["x_mean"], "confirm"))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    if os.listdir(OUT):
        sys.exit(f"{OUT} is not empty")
    with open(os.path.join(H1, "h1-plan.tsv")) as f, open(PLAN, "w") as g:
        rows_ = "".join(l for l in f if l.split("\t")[:2] in (["vdb", "u5"], ["vdb", "u90"]))
        g.write(rows_)
    open(PLAN_HP, "w").write("#! levels_confirm_fail=highest_pass\n" + rows_)
    open(PLAN_BAD, "w").write("#! levels_confirm_fail=bogus\n" + rows_)
    r = unittest.main(exit=False, verbosity=2 if "-v" in sys.argv else 1).result
    print("TEST LEVELS PASS" if r.wasSuccessful() else "TEST LEVELS FAIL")
    sys.exit(0 if r.wasSuccessful() else 1)

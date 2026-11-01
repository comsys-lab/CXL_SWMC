#!/usr/bin/env python3
"""Unit test of experiments/analysis/eval3_extract.py on a synthetic result dir (Host only, no VM data).

usage: python3 -B experiments/analysis/test/eval3_extract_test.py [-v]
       python3 -B experiments/analysis/test/eval3_extract_test.py --write-fixture DIR   (dump the fixture only)

Fixture (written to a temp dir): <run>/block/h2n-results.tsv and two lifetimes, each a slo/ part with steps.csv and
stats-steps.csv for 2 targets and 4 steps (ramp 20, confirm 40, overload 80 = SLO miss, fixed 30 req/s = L1):
  pop-u50-n2: Popcorn build 13 keys ({read,write}_last_{revoke,wb,meta}_ns, *_local_meta_ns, breakdown_faults)
  ds-u50-n2:  De Stijl build 7 keys (no owner phases: two-part split) + ds_stats (fetch/inv/ack, async_*, p95_us)
Per-target values are the same in every step, so every per-fault / per-search / per-second number below is exact.
"""
import csv
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import eval3_extract as E  # noqa: E402

STEPS = [(1, "ramp", 20.0, 40.0, True), (2, "confirm", 40.0, 60.0, True), (3, "overload", 80.0, 150.0, True),
         (4, "fixed", 30.0, 50.0, True), (5, "confirm", 40.0, 70.0, True)]  # MAX pools confirm steps 2 + 5
WIN = 10.0

POP = {  # per target per step
    "searches": 50, "inserts": 50,
    "thr.vdb-search.swmc.is_faults": 100, "thr.vdb-search.swmc.read_faults": 100,
    "thr.vdb-search.swmc.is_fault_ns": 5_000_000, "thr.vdb-search.swmc.read_msg_wait_ns": 3_000_000,
    "thr.vdb-search.swmc.read_owner_h_ns": 800_000, "thr.vdb-search.swmc.read_xport_ns": 2_200_000,
    "thr.vdb-search.swmc.read_owner_h_rounds": 100,
    "thr.vdb-search.swmc.read_last_revoke_ns": 300_000, "thr.vdb-search.swmc.read_last_wb_ns": 100_000,
    "thr.vdb-search.swmc.read_last_meta_ns": 200_000, "thr.vdb-search.swmc.read_acquire_flush_ns": 50_000,
    "thr.vdb-search.swmc.read_local_meta_ns": 150_000, "thr.vdb-search.swmc.read_pte_install_ns": 100_000,
    "thr.vdb-search.swmc.read_local_wait_ns": 200_000, "thr.vdb-search.swmc.breakdown_faults": 100,
    "thr.vdb-search.swmc.nontrans_faults": 0,
    "thr.vdb-writer.swmc.sm_faults": 20, "thr.vdb-writer.swmc.sm_fault_ns": 400_000,
    "thr.vdb-writer.swmc.wpu_faults": 30, "thr.vdb-writer.swmc.wpu_fault_ns": 600_000,
    "thr.vdb-writer.swmc.write_msg_wait_ns": 500_000, "thr.vdb-writer.swmc.write_owner_h_ns": 200_000,
    "thr.vdb-writer.swmc.write_xport_ns": 300_000, "thr.vdb-writer.swmc.write_owner_h_rounds": 50,
    "thr.vdb-writer.swmc.write_last_revoke_ns": 100_000, "thr.vdb-writer.swmc.write_last_wb_ns": 25_000,
    "thr.vdb-writer.swmc.write_last_meta_ns": 25_000, "thr.vdb-writer.swmc.write_acquire_flush_ns": 0,
    "thr.vdb-writer.swmc.write_local_meta_ns": 50_000, "thr.vdb-writer.swmc.write_pte_install_ns": 50_000,
    "thr.vdb-writer.swmc.write_local_wait_ns": 0, "thr.vdb-writer.swmc.breakdown_faults": 50,
    "sys.swmc.instr.serve_fetch.reply_count": 150, "sys.swmc.instr.serve_invalidate.reply_count": 50,
    "sys.swmc.instr.tx_fetch.wait_count": 100, "sys.swmc.instr.tx_invalidate.wait_count": 50,
    "opt.search.ops": 50, "opt.search.t_ns": 500_000_000, "opt.search.wait_ns": 0, "opt.search.c_ns": 50_000_000,
    "opt.search.pop.is_ns": 50_000_000, "opt.search.pop.sm_ns": 0, "opt.search.pop.wp_ns": 0,
    "opt.search.pop.ipi_ns": 0, "opt.search.pop.nontrans_ns": 0,
}
DS = {
    "searches": 50, "inserts": 50,
    "thr.vdb-search.swmc.is_faults": 100, "thr.vdb-search.swmc.read_faults": 100,
    "thr.vdb-search.swmc.is_fault_ns": 2_000_000, "thr.vdb-search.swmc.read_msg_wait_ns": 500_000,
    "thr.vdb-search.swmc.read_owner_h_ns": 0, "thr.vdb-search.swmc.read_xport_ns": 0,
    "thr.vdb-writer.swmc.sm_faults": 0, "thr.vdb-writer.swmc.sm_fault_ns": 0,
    "thr.vdb-writer.swmc.wpu_faults": 50, "thr.vdb-writer.swmc.wpu_fault_ns": 1_000_000,
    "thr.vdb-writer.swmc.write_msg_wait_ns": 600_000,
    "sys.swmc.destijl.fetch_sent": 60, "sys.swmc.destijl.inv_sent": 30, "sys.swmc.destijl.ack_sent": 60,
    "sys.swmc.destijl.async_issued": 45, "sys.swmc.destijl.async_installed": 40,
    "sys.swmc.destijl.async_completed": 40, "sys.swmc.destijl.ss_residence_max_us": 3000,
}
DS_P95 = {0: 900, 1: 1100}  # gauge per target


def write_fixture(root):
    run = os.path.join(root, "eval3-fixture-v1")
    B = os.path.join(run, "block")
    os.makedirs(B, exist_ok=True)
    with open(os.path.join(B, "h2n-results.tsv"), "w") as f:
        f.write("# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\t"
                "run_dir\topcoh_check\n")
        f.write("pop-u50-n2\tpop\tu50\t50\t2\t4\t40\t19.5\tTrue\t\tpop-u50-n2/slo\tPASS\n")
        f.write("ds-u50-n2\tds\tu50\t50\t2\t4\t40\t19.0\tTrue\t\tds-u50-n2/slo\tPASS\n")
    for life, vals in (("pop-u50-n2", POP), ("ds-u50-n2", DS)):
        P = os.path.join(B, life, "slo")
        os.makedirs(P, exist_ok=True)
        with open(os.path.join(P, "steps.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["label", "step", "phase", "measure_s", "pass", "aborted", "stream", "offered", "achieved",
                        "p50_ms", "p95_ms", "p99_ms", "pslo_ms", "max_under_slo", "slo_stream", "slo_pct", "slo_ms",
                        "result_pooled_offered"])
            for n, ph, x, p99, ok in STEPS:
                for s in ("update", "search"):
                    w.writerow(["fixture", n, ph, WIN, ok, False, s, x / 2, x / 2, p99 / 3, p99 / 2, p99, p99,
                                19.5, "search", 99.0, 100.0, 40])
        keys = sorted(vals) + (["sys.swmc.destijl.p95_us"] if life.startswith("ds") else [])
        with open(os.path.join(P, "stats-steps.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s",
                        "srv_window_s"] + keys)
            for n, ph, x, _, _ in STEPS:
                for t in (0, 1):
                    row = {**vals}
                    if life.startswith("ds"):
                        row["sys.swmc.destijl.p95_us"] = DS_P95[t]
                    w.writerow([n, ph, x, t, f"10.0.0.{t}:7000", 0, 0, WIN, WIN] + [row[k] for k in keys])
    return run


def rows(out, name, **match):
    with open(os.path.join(out, name)) as f:
        return [r for r in csv.DictReader(f) if all(r.get(k) == str(v) for k, v in match.items())]


class Eval3ExtractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.rundir = write_fixture(cls.tmp.name)
        cls.out = os.path.join(cls.tmp.name, "out")
        E.extract([cls.rundir], cls.out, {"hw", "pop", "mg", "mgoff", "ds"}, {})

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def one(self, name, **m):
        r = rows(self.out, name, **m)
        self.assertEqual(len(r), 1, f"{name} {m}: {len(r)} rows")
        return r[0]

    def close(self, row, col, want, tol=1e-6):
        self.assertIsNotNone(row.get(col), col)
        self.assertAlmostEqual(float(row[col]), want, delta=tol, msg=col)

    def test_selection(self):
        c = self.one("cells.csv", system="pop")
        self.assertEqual(c["l1_steps"], "4")
        self.assertEqual(c["l1_src"], "fixed step")
        self.assertEqual(c["max_steps"], "2 5")
        self.assertEqual(c["max_src"], "confirm")
        m = self.one("fig-max-under-slo.csv", system="pop")
        self.close(m, "max_offered_total", 40.0)
        self.close(m, "max_slo_stream_s", 19.5)
        lat = rows(self.out, "fig-latency-vs-rps.csv", system="pop")
        self.assertEqual([r["within_slo"] for r in lat], ["True", "True", "False", "True", "True"])

    def test_b13_read(self):
        r = self.one("fig-fault-breakdown.csv", system="pop", step="MAX", **{"class": "read"})
        self.assertEqual(r["mode"], "b13")
        for col, v in (("F_us", 50), ("cat1_comm_us", 24), ("cat2_unmap_tlb_us", 3), ("cat3_flush_us", 1.5),
                       ("cat4_metadata_us", 3.5), ("cat5_others_us", 18), ("pte_install_us", 1),
                       ("local_wait_us", 2), ("residual_us", 15), ("comm_xport_us", 22), ("comm_owner_rest_us", 2),
                       ("sum_check_us", 0), ("norm_F_to_pop", 1), ("faults", 400)):
            self.close(r, col, v)

    def test_b13_write(self):
        r = self.one("fig-fault-breakdown.csv", system="pop", step="L1", **{"class": "write"})
        self.assertEqual(r["mode"], "b13")
        for col, v in (("F_us", 20), ("cat1_comm_us", 7), ("cat2_unmap_tlb_us", 2), ("cat3_flush_us", 0.5),
                       ("cat4_metadata_us", 1.5), ("cat5_others_us", 9), ("residual_us", 8), ("faults", 100),
                       ("sum_check_us", 0)):
            self.close(r, col, v)

    def test_ds_two_part(self):
        r = self.one("fig-fault-breakdown.csv", system="ds", step="MAX", **{"class": "read"})
        self.assertEqual(r["mode"], "ds-2part")
        self.close(r, "F_us", 20)
        self.close(r, "fetch_wait_us", 5)
        self.close(r, "rest_us", 15)
        self.close(r, "async_served_faults", 160)
        self.close(r, "sync_faults", 240)
        self.close(r, "norm_F_to_pop", 0.4)
        w = self.one("fig-fault-breakdown.csv", system="ds", step="MAX", **{"class": "write"})
        self.close(w, "F_us", 20)
        self.close(w, "fetch_wait_us", 12)

    def test_flushed_lines(self):
        r = self.one("fig-flushed-lines-l1.csv", system="pop")
        self.close(r, "lines_per_search", 200 / 100 * 64)
        self.assertEqual(r["step"], "4")

    def test_rates(self):
        p = self.one("fig-coherence-rates.csv", system="pop", step="MAX")
        self.close(p, "read_faults_s", 20)
        self.close(p, "write_faults_s", 10)
        self.close(p, "pop_msgs_s", 80)
        self.close(p, "coh_msgs_s", 80)
        self.close(p, "pop_rounds_s", 30)
        d = self.one("fig-coherence-rates.csv", system="ds", step="MAX")
        self.close(d, "ds_msgs_s", 30)
        self.close(d, "coh_msgs_s", 30)

    def test_search_breakdown(self):
        r = self.one("fig-search-breakdown.csv", system="pop", step="MAX", op="search")
        self.close(r, "t_ms", 10)
        self.close(r, "pop_is_ms", 1)
        self.close(r, "rest_ms", 9)

    def test_staleness(self):
        r = self.one("fig-ds-staleness.csv", system="ds", step="MAX")
        self.close(r, "ss_read_share", 0.4)
        self.close(r, "ss_residence_p95_us_max", 1100)
        self.close(r, "ss_residence_p95_us_mean", 1000)
        self.close(r, "ss_residence_max_us", 3000)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--write-fixture":
        print(write_fixture(sys.argv[2]))
        sys.exit(0)
    unittest.main()

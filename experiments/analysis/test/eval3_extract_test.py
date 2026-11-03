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

# De Stijl build 8 (workspaces/eval3/ds-breakdown PROGRESS.md "Key names"): per-thread read_async_* split, per-node
# owner counters srv_{fetch_sync,inv}_* (ds-u10-n2) or only the instr serve_* aggregates (ds-u90-n2, fallback)
_S, _W = "thr.vdb-search.swmc.", "thr.vdb-writer.swmc."
DS8_THR = {
    "searches": 50, "inserts": 50,
    _S + "is_faults": 100, _S + "read_faults": 100, _S + "is_fault_ns": 3_000_000, _S + "read_transactions": 100,
    _S + "read_msg_wait_ns": 1_400_000, _S + "read_acquire_flush_ns": 120_000, _S + "read_local_meta_ns": 300_000,
    _S + "read_local_wait_ns": 60_000, _S + "read_pte_install_ns": 200_000, _S + "breakdown_faults": 100,
    _S + "read_last_revoke_ns": 0, _S + "read_last_wb_ns": 0, _S + "read_last_meta_ns": 0,
    _S + "read_async_faults": 40, _S + "read_async_is_fault_ns": 400_000, _S + "read_async_breakdown_faults": 40,
    _S + "read_async_msg_wait_ns": 200_000, _S + "read_async_acquire_flush_ns": 40_000,
    _S + "read_async_local_meta_ns": 80_000, _S + "read_async_local_wait_ns": 0,
    _S + "read_async_pte_install_ns": 80_000,
    _W + "sm_faults": 10, _W + "sm_fault_ns": 300_000, _W + "wpu_faults": 40, _W + "wpu_fault_ns": 700_000,
    _W + "write_transactions": 50, _W + "write_msg_wait_ns": 600_000, _W + "write_acquire_flush_ns": 0,
    _W + "write_local_meta_ns": 100_000, _W + "write_pte_install_ns": 50_000, _W + "write_local_wait_ns": 0,
    _W + "breakdown_faults": 50, _W + "read_async_faults": 0,
    "sys.swmc.destijl.ack_sent": 40, "sys.swmc.destijl.async_installed": 40, "sys.swmc.instr.build": 13,
}


def node(fetch_sent, async_issued, evict_m, evict_self, inv_sent, srv=None, serve=None):
    """De Stijl node counters of one target; srv = {class: (count, revoke us, wb us, meta us)} (sums in us)"""
    d = {D + "fetch_sent": fetch_sent, D + "async_issued": async_issued, D + "bpd_evict_m": evict_m,
         D + "evict_self_fetch": evict_self, D + "inv_sent": inv_sent}
    for cls, (n, rv, wb, mt) in (srv or {}).items():
        d.update({f"{D}srv_{cls}_count": n, f"{D}srv_{cls}_revoke_ns": rv * 1000, f"{D}srv_{cls}_wb_ns": wb * 1000,
                  f"{D}srv_{cls}_meta_ns": mt * 1000, f"{D}srv_{cls}_h_ns": (rv + wb + mt) * 1000})
    for f, (n, rv, wb, mt) in (serve or {}).items():
        p = f"sys.swmc.instr.serve_{f}."
        d.update({p + "reply_count": n, p + "revoke_ns": rv * 1000, p + "wb_ns": wb * 1000, p + "meta_ns": mt * 1000})
    return {**DS8_THR, **d}


D = "sys.swmc.destijl."
# N = 2 with srv_*: node 0 sync FETCH rounds 70-40-5 = 25 (evict 6-1 = 5), node 1 95-40-10 = 45 (evict 10)
DS8_N2 = [node(70, 40, 6, 1, 30, srv={"fetch_sync": (50, 100, 50, 25), "inv": (40, 160, 40, 20),
                                      "fetch_evict": (10, 0, 100, 10)}),
          node(95, 40, 10, 0, 40, srv={"fetch_sync": (25, 100, 0, 25), "inv": (30, 60, 30, 30),
                                       "fetch_evict": (5, 0, 25, 5)})]
# N = 4 with srv_*: every node 30 sync FETCH rounds, 30 INVs; node t serves sync FETCHes with mean revoke t+1 us
DS8_N4 = [node(50, 20, 0, 0, 30, srv={"fetch_sync": (10, 10 * (t + 1), 0, 0), "inv": (10, 20, 0, 0),
                                      "fetch_evict": (0, 0, 0, 0)}) for t in range(4)]
# N = 2 without srv_* (current server snapshots): instr serve_* fallback
DS8_SERVE = [node(70, 40, 0, 0, 30, serve={"fetch": (100, 100, 0, 50), "invalidate": (30, 90, 30, 15)})
             for _ in range(2)]
LIVES = (("pop-u50-n2", POP), ("ds-u50-n2", DS), ("ds-u10-n2", DS8_N2), ("ds-u10-n4", DS8_N4),
         ("ds-u90-n2", DS8_SERVE))

# status-delta (block G fixed lifetimes): stats-steps without srv_* (serve_* only), guest status pre/post with the
# DS8_N2 srv_* values as post - pre (pre = a large persistent baseline)
STEPS_ONE = [(1, "fixed", 30.0, 50.0, True)]
_SRV_KEYS = [k for k in DS8_N2[0] if k.startswith(D + "srv_")]
DS8_STAT = [{k: v for k, v in DS8_N2[t].items() if not k.startswith(D + "srv_")} for t in range(2)]
for _t in range(2):
    DS8_STAT[_t].update({k: v for k, v in DS8_SERVE[_t].items() if k.startswith("sys.swmc.instr.serve_")})
STATUS_LIVES = {  # lifetime: (steps, write pre files)
    "ds-u30-n2": (STEPS_ONE, True),   # one step + pre/post -> status-delta
    "ds-u60-n2": (STEPS, True),       # 5 steps -> flagged, serve-all-fetch fallback
    "ds-u70-n2": (STEPS_ONE, False),  # no pre -> flagged, serve-all-fetch fallback
}


def write_status(B, life, pre):
    S = os.path.join(B, f"dsshm-{life}")
    os.makedirs(S, exist_ok=True)
    for t in range(2):
        base = {k: 1_000_000_000 + 7 * i for i, k in enumerate(_SRV_KEYS)}
        hdr = "release=6.14.0-famfs-de-stijl+-ds-destijl-8 loaded=1\nparam.node_id=%d\nds.inspect: page 0 pfn 0x1\n" % t
        body = lambda vals: "".join(f"ds.{k[len(D):]}={int(v)}\n" for k, v in vals.items())  # noqa: E731
        if pre:
            with open(os.path.join(S, f"status-pre-vm{t}.txt"), "w") as f:
                f.write(hdr + body(base) + "ds.lambda_per_s=0 (cold)\n")
        with open(os.path.join(S, f"status-post-vm{t}.txt"), "w") as f:
            f.write(hdr + body({k: base[k] + DS8_N2[t][k] for k in _SRV_KEYS}))


def write_fixture(root):
    run = os.path.join(root, "eval3-fixture-v1")
    B = os.path.join(run, "block")
    os.makedirs(B, exist_ok=True)
    with open(os.path.join(B, "h2n-results.tsv"), "w") as f:
        f.write("# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\t"
                "run_dir\topcoh_check\n")
        f.write("pop-u50-n2\tpop\tu50\t50\t2\t4\t40\t19.5\tTrue\t\tpop-u50-n2/slo\tPASS\n")
        f.write("ds-u50-n2\tds\tu50\t50\t2\t4\t40\t19.0\tTrue\t\tds-u50-n2/slo\tPASS\n")
        f.write("ds-u10-n2\tds\tu10\t10\t2\t4\t40\t19.0\tTrue\t\tds-u10-n2/slo\tPASS\n")
        f.write("ds-u10-n4\tds\tu10\t10\t4\t4\t40\t19.0\tTrue\t\tds-u10-n4/slo\tPASS\n")
        f.write("ds-u90-n2\tds\tu90\t90\t2\t4\t40\t19.0\tTrue\t\tds-u90-n2/slo\tPASS\n")
    lives = [(life, vals, STEPS) for life, vals in LIVES]
    for life, (steps, pre) in STATUS_LIVES.items():
        lives.append((life, DS8_STAT, steps))
        write_status(B, life, pre)
    for life, vals, steps in lives:
        P = os.path.join(B, life, "slo")
        os.makedirs(P, exist_ok=True)
        with open(os.path.join(P, "steps.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["label", "step", "phase", "measure_s", "pass", "aborted", "stream", "offered", "achieved",
                        "p50_ms", "p95_ms", "p99_ms", "pslo_ms", "max_under_slo", "slo_stream", "slo_pct", "slo_ms",
                        "result_pooled_offered"])
            for n, ph, x, p99, ok in steps:
                for s in ("update", "search"):
                    w.writerow(["fixture", n, ph, WIN, ok, False, s, x / 2, x / 2, p99 / 3, p99 / 2, p99, p99,
                                19.5, "search", 99.0, 100.0, 40])
        per_t = vals if isinstance(vals, list) else [vals, vals]
        keys = sorted(set().union(*per_t)) + (["sys.swmc.destijl.p95_us"] if vals is DS else [])
        with open(os.path.join(P, "stats-steps.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s",
                        "srv_window_s"] + keys)
            for n, ph, x, _, _ in steps:
                for t, tv in enumerate(per_t):
                    row = {**tv}
                    if vals is DS:
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
        r = self.one("fig-fault-breakdown.csv", lifetime="ds-u50-n2",step="MAX", **{"class": "read"})
        self.assertEqual(r["mode"], "ds7-2part")
        self.close(r, "F_us", 20)
        self.close(r, "fetch_wait_us", 5)
        self.close(r, "rest_us", 15)
        self.close(r, "async_served_faults", 160)
        self.close(r, "sync_faults", 240)
        self.close(r, "norm_F_to_pop", 0.4)
        w = self.one("fig-fault-breakdown.csv", lifetime="ds-u50-n2",step="MAX", **{"class": "write"})
        self.close(w, "F_us", 20)
        self.close(w, "fetch_wait_us", 12)

    def ds8(self, life, cls, step="L1"):
        return self.one("fig-fault-breakdown.csv", lifetime=life, step=step, **{"class": cls})

    def test_ds8_n2_read_sync(self):
        # owner totals: node 0 <- node 1 means (4, 0, 1 us) x 25 rounds, node 1 <- node 0 means (2, 1, 0.5) x 45
        # = revoke 190, wb 45, meta 47.5 us over 120 sync faults; W 2400, acq 160, local meta 440, F 5200 us
        r = self.ds8("ds-u10-n2", "read_sync")
        self.assertEqual(r["mode"], "ds8")
        self.assertEqual(r["owner_src"], "srv")
        for col, v in (("faults", 120), ("owner_rounds", 70), ("F_us", 5200 / 120), ("W_us", 20),
                       ("cat1_comm_us", (2400 - 190 - 45 - 47.5) / 120), ("cat2_unmap_tlb_us", 190 / 120),
                       ("cat3_flush_us", (45 + 160) / 120), ("cat4_metadata_us", (47.5 + 440) / 120),
                       ("cat5_others_us", 2200 / 120), ("sum_check_us", 0), ("owner_revoke_us", 190 / 120),
                       ("instr_build", 13)):
            self.close(r, col, v)

    def test_ds8_n2_read_async_and_total(self):
        a = self.ds8("ds-u10-n2", "read_async")
        self.assertEqual(a["mode"], "ds8")
        self.assertTrue(a["owner_src"].startswith("none"))
        for col, v in (("faults", 80), ("F_us", 10), ("cat1_comm_us", 5), ("cat2_unmap_tlb_us", 0),
                       ("cat3_flush_us", 1), ("cat4_metadata_us", 2), ("cat5_others_us", 2), ("residual_us", 0)):
            self.close(a, col, v)
        t = self.ds8("ds-u10-n2", "read")
        for col, v in (("faults", 200), ("F_us", 30), ("cat2_unmap_tlb_us", 190 / 200),
                       ("cat1_comm_us", (2800 - 282.5) / 200), ("sum_check_us", 0)):
            self.close(t, col, v)

    def test_ds8_n2_write(self):
        # inv: node 0 <- node 1 (2, 1, 1) x 30, node 1 <- node 0 (4, 1, 0.5) x 40; evict: node 0 <- node 1
        # (0, 5, 1) x 5, node 1 <- node 0 (0, 10, 1) x 10 -> revoke 220, wb 195, meta 65 us over 100 writes
        r = self.ds8("ds-u10-n2", "write")
        self.assertEqual(r["mode"], "ds8")
        for col, v in (("faults", 100), ("owner_rounds", 85), ("F_us", 20), ("cat1_comm_us", 7.2),
                       ("cat2_unmap_tlb_us", 2.2), ("cat3_flush_us", 1.95), ("cat4_metadata_us", 2.65),
                       ("cat5_others_us", 6.0), ("residual_us", 5.0)):
            self.close(r, col, v)

    def test_ds8_n4(self):
        # read owner revoke: sum over nodes i of (100 - 10 (i + 1)) = 300 us over 240 sync faults
        r = self.ds8("ds-u10-n4", "read_sync")
        self.assertEqual(r["mode"], "ds8")
        self.close(r, "cat2_unmap_tlb_us", 300 / 240)
        self.close(r, "owner_rounds", 120)
        w = self.ds8("ds-u10-n4", "write")
        self.assertEqual(w["mode"], "ds8-meanholder")
        self.close(w, "cat2_unmap_tlb_us", 240 / 200)

    def test_ds8_serve_fallback(self):
        r = self.ds8("ds-u90-n2", "read_sync")
        self.assertEqual(r["owner_src"], "serve-all-fetch")
        self.close(r, "cat2_unmap_tlb_us", 60 / 120)
        self.close(r, "cat4_metadata_us", (30 + 440) / 120)
        w = self.ds8("ds-u90-n2", "write")
        self.close(w, "cat2_unmap_tlb_us", 180 / 100)

    def test_status_delta(self):
        # one fixed step, srv_* from status post - pre: same numbers as the srv_* N = 2 cell
        r = self.ds8("ds-u30-n2", "read_sync")
        self.assertEqual(r["owner_src"], "status-delta")
        self.close(r, "cat2_unmap_tlb_us", 190 / 120)
        self.close(r, "cat1_comm_us", (2400 - 190 - 45 - 47.5) / 120)
        w = self.ds8("ds-u30-n2", "write")
        self.close(w, "cat2_unmap_tlb_us", 2.2)
        self.close(w, "cat3_flush_us", 1.95)

    def test_status_delta_flagged(self):
        r = self.ds8("ds-u60-n2", "read_sync")  # 5 measurement steps
        self.assertTrue(r["owner_src"].startswith("serve-all-fetch (status-delta not used: lifetime has 5"),
                        r["owner_src"])
        # serve_fetch mean revoke 1 us x sync FETCH rounds 25 + 45 over 120 sync faults
        self.close(r, "cat2_unmap_tlb_us", 70 / 120)
        r = self.ds8("ds-u70-n2", "read_sync")  # no pre file
        self.assertIn("no status-pre", r["owner_src"])
        self.close(r, "cat2_unmap_tlb_us", 70 / 120)

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
        d = self.one("fig-coherence-rates.csv", lifetime="ds-u50-n2",step="MAX")
        self.close(d, "ds_msgs_s", 30)
        self.close(d, "coh_msgs_s", 30)

    def test_search_breakdown(self):
        r = self.one("fig-search-breakdown.csv", system="pop", step="MAX", op="search")
        self.close(r, "t_ms", 10)
        self.close(r, "pop_is_ms", 1)
        self.close(r, "rest_ms", 9)

    def test_staleness(self):
        r = self.one("fig-ds-staleness.csv", lifetime="ds-u50-n2",step="MAX")
        self.close(r, "ss_read_share", 0.4)
        self.close(r, "ss_residence_p95_us_max", 1100)
        self.close(r, "ss_residence_p95_us_mean", 1000)
        self.close(r, "ss_residence_max_us", 3000)


class PmaxTest(unittest.TestCase):
    """run 2: a pop lifetime with a pmax part (h2n-block.sh H2N_PMAX) = only the fixed step of the slo fixture's rows"""
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        run = write_fixture(cls.tmp.name)
        src, dst = os.path.join(run, "block", "pop-u50-n2", "slo"), os.path.join(run, "block", "pop-u50-n2", "pmax")
        os.makedirs(dst)
        for fn in ("steps.csv", "stats-steps.csv"):
            with open(os.path.join(src, fn)) as f, open(os.path.join(dst, fn), "w", newline="") as g:
                r = list(csv.reader(f))
                w = csv.writer(g)
                w.writerow(r[0])
                ph = r[0].index("phase")
                w.writerows(x for x in r[1:] if x[ph] == "fixed")
        cls.out = os.path.join(cls.tmp.name, "out")
        E.extract([run], cls.out, {"hw", "pop", "mg", "mgoff", "ds"}, {})

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_pmax_selection(self):
        c = rows(self.out, "cells.csv", system="pop", part="pmax")
        self.assertEqual(len(c), 1)
        self.assertEqual(c[0]["pmax_steps"], "4")
        self.assertEqual(c[0]["l1_steps"], "")
        self.assertEqual(float(c[0]["pmax_rate"]), 30.0)
        s = rows(self.out, "cells.csv", system="pop", part="slo")
        self.assertEqual(s[0]["l1_steps"], "4")   # the slo part's own fixed step stays L1
        self.assertEqual(s[0]["pmax_steps"], "")
        f = rows(self.out, "fig-fault-breakdown.csv", system="pop", part="pmax", step="PMAX", **{"class": "read"})
        self.assertEqual(len(f), 1)
        self.assertEqual(f[0]["sel"], "PMAX")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--write-fixture":
        print(write_fixture(sys.argv[2]))
        sys.exit(0)
    unittest.main()

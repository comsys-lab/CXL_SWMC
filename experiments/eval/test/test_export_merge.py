#!/usr/bin/env python3
"""Unit tests of the export and merge layer on existing evidence (read-only) — Host only.

usage: EVAL_TEST_OUT=<scratch dir> python3 -B test_export_merge.py [-v]
Exports recovery/H1-main-v1 (vector DB, H1 layout), recovery/vectorDB-update-rate-v2 and -v3 (update-rate sweep),
recovery/RECSYS-stream-v1c (RecSys streaming) and recovery/RECSYS-V1-v1.4 (RecSys v1 windows) into EVAL_TEST_OUT, checks
the canonical schemas and values the evidence states elsewhere (H1 levels.tsv, urate-results.tsv, stream-results.tsv,
RECSYS-V1 cdiff.csv), then merges synthetic runs 1-3 (run 1 = the H1 export, runs 2/3 = scaled copies) and checks
mean / min / max / n, the per-run ratio and the config_sha256 refusal.
"""
import csv
import os
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(EXP), "figures", "lib"))
import canon  # noqa: E402
import runs as R  # noqa: E402

REC = "/home/comsys/sungsu/destijl-control/recovery"
OUT = os.environ.get("EVAL_TEST_OUT") or sys.exit("set EVAL_TEST_OUT")


def export(script, ev, name, run=1, sha="test"):
    out = os.path.join(OUT, name)
    r = subprocess.run([sys.executable, "-B", script, "--run", str(run), "--runset", "test", "--config-sha256", sha,
                        "--out", out, os.path.join(REC, ev)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-2000:]
    return out


def rows(d, name):
    with open(os.path.join(d, name)) as f:
        return list(csv.DictReader(f))


def tsv(p):
    return [f for f in csv.reader(open(p), delimiter="\t") if f and not f[0].startswith("#")]


class Exports(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        vx, rx = os.path.join(EXP, "vectordb", "export.py"), os.path.join(EXP, "recsys", "export.py")
        cls.h1 = export(vx, "H1-main-v1", "h1-vdb")
        cls.u2 = export(vx, "vectorDB-update-rate-v2", "urate-v2")
        cls.u3 = export(vx, "vectorDB-update-rate-v3", "urate-v3")
        cls.rs = export(rx, "RECSYS-stream-v1c", "rs-stream-v1c")
        cls.v1 = export(rx, "RECSYS-V1-v1.4", "rs-v1.4")

    def test_schemas(self):
        for d in (self.h1, self.u2, self.u3, self.rs, self.v1):
            for name, cols in canon.SCHEMA.items():
                with open(os.path.join(d, name)) as f:
                    self.assertEqual(next(csv.reader(f)), cols, f"{d}/{name}")
                for r in rows(d, name):
                    self.assertTrue(r["workload"] in ("vdb", "recsys") and r["run"] == "1" and r["config_sha256"] == "test")

    def test_h1_vdb_against_levels(self):
        lv = {f[0]: f for f in tsv(os.path.join(REC, "H1-main-v1", "vdb", "levels.tsv"))[1:]}
        s = {(r["system"], r["point"]): r for r in rows(self.h1, "slo_summary.csv")}
        self.assertEqual(len(s), 9)
        for m, f in lv.items():
            for i, sysn in ((2, "hw"), (3, "pop"), (4, "mg")):
                self.assertAlmostEqual(float(s[(sysn, m)]["confirm_x_mean"]), float(f[i]), places=3)
            # result_x is in searches/s (offered total x search share), close to the confirm mean
            self.assertLess(abs(float(s[("hw", m)]["result_x"]) / float(f[2]) - 1), 0.05)
        fx = rows(self.h1, "fixed.csv")
        self.assertEqual(len(fx), 24)  # 3 mixes x 4 systems x L1/L2
        for r in fx:
            lvl = lv[r["point"]]
            want = float(lvl[5] if r["level"] == "L1" else lvl[6])  # L1_x / L2_x in searches/s
            self.assertLess(abs(float(r["offered_x"]) / want - 1), 0.01, r)
            if r["system"] == "mg":
                self.assertTrue(r["mgoff_T_ms_rop"] and float(r["mg_flush_bytes_per_rop"]) > 0)
            if r["system"] == "hw":
                self.assertEqual(float(r["C_ms_rop"]), 0.0)
            if r["system"] == "pop":
                self.assertGreater(float(r["pop_read_faults_per_rop"]), 0)
                self.assertAlmostEqual(float(r["flushed_lines_per_rop"]), float(r["pop_read_faults_per_rop"]) * 64, 3)
        st = rows(self.h1, "slo_steps.csv")
        self.assertTrue(all(r["threads"] == "14" and r["writers"] == "1" for r in st))
        self.assertGreater(len(rows(self.h1, "latency_hist.csv")), 1000)

    def test_latency_hist_matches_loadgen_count(self):
        part = os.path.join(REC, "H1-main-v1", "vdb", "r1", "run", "hw-u50-slo-r1", "slo")
        st = {d["step"]: d for d in canon.measured_steps(part)}
        h = canon.latency_hist(part, "search")
        for step in list(h)[:5]:
            self.assertEqual(sum(n for _, n in h[step]), st[step]["streams"]["search"]["done"]
                             - st[step]["streams"]["search"]["errors"] - st[step]["streams"]["search"]["timeouts"])

    def test_urate_against_results(self):
        for d, ev in ((self.u2, "vectorDB-update-rate-v2"), (self.u3, "vectorDB-update-rate-v3")):
            res = {(f[1], f[2]): f for f in tsv(os.path.join(REC, ev, "urate-results.tsv"))}
            s = {(r["system"], r["point"]): r for r in rows(d, "slo_summary.csv")}
            self.assertEqual(set(s), set(res))
            for k, f in res.items():
                self.assertEqual(s[k]["result_x"], f[4] if f[4] else "", k)
                self.assertEqual(s[k]["valid"], f[9])
                self.assertEqual(s[k]["writers"], f[3])
            self.assertTrue(all(r["level"] in ("L1", "L2") for r in rows(d, "fixed.csv")))
            # M3: validity from urate-check.csv (server write counters), with the done ratio
            st = rows(d, "slo_steps.csv")
            self.assertTrue(all(r["valid"] in ("True", "False") and r["wop_done_ratio"] for r in st))
            self.assertTrue(all(r["wop_offered_per_s"] for r in st))

    def test_h1_validity_unknown_without_counters(self):
        # H1 r1 (vdb/15) has no server write counters: valid empty (unknown), never the loadgen pass (verifier M3)
        self.assertTrue(all(r["valid"] == "" and r["slo_pass"] in ("True", "False") for r in rows(self.h1, "fixed.csv")))
        self.assertTrue(all(r["valid"] == "" for r in rows(self.h1, "slo_steps.csv")))

    def test_recsys_stream_against_results(self):
        res = {(f[1], f[2]): f for f in tsv(os.path.join(REC, "RECSYS-stream-v1c", "stream-results.tsv"))}
        s = {(r["system"], r["point"]): r for r in rows(self.rs, "slo_summary.csv")}
        self.assertEqual(set(s), set(res))
        for k, f in res.items():
            self.assertEqual(s[k]["result_x"], f[3] if f[5] == "True" else "", k)
            self.assertEqual(s[k]["valid"], f[8])
        st = rows(self.rs, "slo_steps.csv")
        self.assertTrue(all(r["threads"] == "14" and r["writers"] == "14" for r in st))
        pop = [r for r in st if r["system"] == "pop" and r["pop_read_faults_per_rop"]]
        self.assertTrue(pop and all(float(r["pop_read_faults_per_rop"]) > 0 for r in pop))

    def test_recsys_v1_against_cdiff(self):
        cd = {r["op"]: r for r in csv.DictReader(open(os.path.join(REC, "RECSYS-V1-v1.4", "cdiff.csv")))}
        fx = {r["system"]: r for r in rows(self.v1, "fixed.csv")}
        self.assertEqual(set(fx), {"hw", "pop", "mg", "mgoff"})
        self.assertAlmostEqual(float(fx["hw"]["T_ms_rop"]), float(cd["query"]["T_hw_ns"]) / 1e6, 2)
        self.assertAlmostEqual(float(fx["mgoff"]["T_ms_rop"]), float(cd["query"]["T_mgoff_ns"]) / 1e6, 2)
        self.assertAlmostEqual(float(fx["mg"]["mgoff_T_ms_rop"]) - float(fx["hw"]["T_ms_rop"]),
                               float(cd["query"]["C_diff_ns"]) / 1e6, 2)
        self.assertAlmostEqual(float(fx["pop"]["T_ms_rop"]), float(cd["query"]["T_pop_ns"]) / 1e6, 2)


class Merge(unittest.TestCase):
    def setUp(self):
        self.root = os.path.join(OUT, "merge-root")
        shutil.rmtree(self.root, ignore_errors=True)
        src = os.path.join(OUT, "h1-vdb")
        if not os.path.isdir(src):
            export(os.path.join(EXP, "vectordb", "export.py"), "H1-main-v1", "h1-vdb")
        for k, f in ((1, 1.0), (2, 1.1), (3, 0.9)):
            d = os.path.join(self.root, "vdb", "vdb", f"run{k}")
            os.makedirs(d)
            for name in ("slo_summary.csv", "fixed.csv"):
                rs = rows(src, name)
                with open(os.path.join(d, name), "w", newline="") as fo:
                    w = csv.DictWriter(fo, fieldnames=list(rs[0]))
                    w.writeheader()
                    for r in rs:
                        r["run"] = str(k)
                        if name == "slo_summary.csv" and r["confirm_x_mean"] and r["system"] != "hw":
                            r["confirm_x_mean"] = repr(float(r["confirm_x_mean"]) * f)
                        if name == "fixed.csv" and r["T_ms_rop"]:
                            r["T_ms_rop"] = repr(float(r["T_ms_rop"]) * f)
                        w.writerow(r)
        self.src = src

    def test_agg_and_ratio(self):
        out = os.path.join(OUT, "merge-out")
        r = subprocess.run([sys.executable, "-B", os.path.join(os.path.dirname(HERE), "merge.py"), "--root", self.root,
                            "--workload", "vdb", "--runset", "vdb", "--out", out], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        base = {(x["system"], x["point"]): float(x["confirm_x_mean"]) for x in rows(self.src, "slo_summary.csv")}
        m = {(x["system"], x["point"]): x for x in rows(out, "slo_summary-merged.csv")}
        for (s, p), x0 in base.items():
            x = m[(s, p)]
            self.assertEqual(x["runs"], "1 2 3")
            self.assertEqual(x["confirm_x_mean_n"], "3")
            self.assertAlmostEqual(float(x["confirm_x_mean_mean"]), x0, 4)
            f = 1.0 if s == "hw" else 1.1
            self.assertAlmostEqual(float(x["confirm_x_mean_max"]), x0 * f, 4)
            r0 = x0 / base[("hw", p)]
            self.assertAlmostEqual(float(x["ratio_to_hw_mean"]), r0, 6)
            self.assertAlmostEqual(float(x["ratio_to_hw_min"]), r0 * (0.9 if s != "hw" else 1.0), 6)
        fm = rows(out, "fixed-merged.csv")
        self.assertEqual(len(fm), 24)

    def test_mixed_config_refused(self):
        p = os.path.join(self.root, "vdb", "vdb", "run2", "slo_summary.csv")
        rs = rows(os.path.dirname(p), "slo_summary.csv")
        for r in rs:
            r["config_sha256"] = "other"
        with open(p, "w", newline="") as fo:
            w = csv.DictWriter(fo, fieldnames=list(rs[0]))
            w.writeheader()
            w.writerows(rs)
        with self.assertRaises(ValueError):
            R.load(self.root, "vdb", "vdb", "slo_summary.csv")
        self.assertEqual(len(R.load(self.root, "vdb", "vdb", "slo_summary.csv", allow_mixed_config=True)), 27)


class CrossRunsetRatio(unittest.TestCase):
    def test_megalon_ratio_uses_rs_main_hw(self):  # verifier L7
        src = os.path.join(OUT, "rs-stream-v1c")
        if not os.path.isdir(src):
            export(os.path.join(EXP, "recsys", "export.py"), "RECSYS-stream-v1c", "rs-stream-v1c")
        root = os.path.join(OUT, "l7-root")
        shutil.rmtree(root, ignore_errors=True)
        rs = rows(src, "slo_summary.csv")
        for runset, keep in (("rs-main", lambda r: True), ("rs-h1", lambda r: r["system"] == "pop")):
            d = os.path.join(root, "recsys", runset, "run1")
            os.makedirs(d)
            with open(os.path.join(d, "slo_summary.csv"), "w", newline="") as fo:
                w = csv.DictWriter(fo, fieldnames=list(rs[0]))
                w.writeheader()
                for r in rs:
                    if keep(r):
                        w.writerow(dict(r, system="mg") if runset == "rs-h1" else r)
        out = os.path.join(OUT, "l7-out")
        subprocess.run([sys.executable, "-B", os.path.join(os.path.dirname(HERE), "merge.py"), "--root", root,
                        "--workload", "recsys", "--runset", "rs-h1", "--out", out], check=True, capture_output=True)
        m = {x["point"]: x for x in rows(out, "slo_summary-merged.csv")}
        hw = {r["point"]: float(r["confirm_x_mean"]) for r in rs if r["system"] == "hw" and r["confirm_x_mean"]}
        pop = {r["point"]: float(r["confirm_x_mean"]) for r in rs if r["system"] == "pop" and r["confirm_x_mean"]}
        for p in pop:
            self.assertAlmostEqual(float(m[p]["ratio_to_hw_mean"]), pop[p] / hw[p], 6)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Merged tables across runs 1..RUNS with the spread (evaluation-pipeline rev 3 §4.3), as CSVs for Excel and checks.

usage: merge.py --root DERIVED_ROOT --workload vdb|recsys --runset R --out DIR [--runs 1,2,3] [--allow-mixed-config]
Writes DIR/<csv>-merged.csv for slo_summary.csv, fixed.csv and (when present) mg_probe.csv: one row per key group
(slo_summary: system, point; fixed: system, point, level; mg_probe: point) with <col>_{mean,min,max,sd,n} of the
numeric columns and "runs" (the runs present). slo_summary also gets ratio_to_hw = confirm_x_mean / all-HWcc's at the
same point, computed per run and then aggregated (min-max spread of the per-run ratios); for run set rs-h1 (Megalon
only) all-HWcc of the same run k is taken from rs-main (verifier L7). Latency curves and steps are
pooled by the figure scripts (latency_hist.csv), not here.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "figures", "lib"))
import runs as R  # noqa: E402
import pandas as pd  # noqa: E402

HW_FROM = {"rs-h1": "rs-main"}  # run sets without all-HWcc: hw of the same run k from this run set (verifier L7)

COLS = {
    "slo_summary.csv": ["result_x", "confirm_x_mean", "ratio_to_hw", "at_result_p95_ms", "at_result_p99_ms",
                        "at_result_wop_per_s", "at_result_T_ms_rop", "at_result_C_ms_rop",
                        "at_result_pop_read_faults_per_rop", "at_result_cxl_recv_cpu_s_per_s", "low_rate_violations"],
    "fixed.csv": ["offered_x", "achieved_x", "p95_ms", "p99_ms", "wop_per_s", "T_ms_rop", "C_ms_rop", "T_ms_wop",
                  "C_ms_wop", "pop_read_faults_per_rop", "pop_write_faults_per_wop", "seg_is_ms_rop", "seg_sm_ms_rop",
                  "seg_wp_ms_rop", "seg_ipi_ms_rop", "seg_nontrans_ms_rop", "seg_owner_wait_ms_rop",
                  "seg_inval_ipis_per_rop", "seg_processing_ms_rop", "mg_flush_bytes_per_rop", "flushed_lines_per_rop",
                  "cxl_recv_cpu_s_per_s", "mgoff_T_ms_rop", "mgoff_T_ms_wop"],
    "mg_probe.csv": ["T_ms_rop", "p95_ms", "achieved_wop_per_s", "backlog_end", "lag_ms_max"],
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--runset", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs")
    ap.add_argument("--allow-mixed-config", action="store_true")
    a = ap.parse_args()
    runs = [int(x) for x in a.runs.split(",")] if a.runs else None
    os.makedirs(a.out, exist_ok=True)
    for name, cols in COLS.items():
        try:
            df = R.load(a.root, a.workload, a.runset, name, runs, a.allow_mixed_config)
        except FileNotFoundError:
            continue
        if df.empty:
            continue
        if name == "slo_summary.csv":
            base = df
            if a.runset in HW_FROM:  # verifier L7: all-HWcc of the same run k comes from another run set
                try:
                    hw = R.load(a.root, a.workload, HW_FROM[a.runset], name, runs, a.allow_mixed_config)
                    base = pd.concat([df, hw[hw["system"] == "hw"]], ignore_index=True)
                except FileNotFoundError:
                    print(f"merge.py: no {HW_FROM[a.runset]} {name}: ratio_to_hw empty", file=sys.stderr)
            df["ratio_to_hw"] = R.ratio_to(base, R.KEYS[name], "confirm_x_mean")[:len(df)]
        m = R.agg(df, R.KEYS[name], [c for c in cols if c in df.columns])
        p = os.path.join(a.out, name.replace(".csv", "-merged.csv"))
        m.to_csv(p, index=False)
        print(f"merge.py: {p} ({len(m)} groups, runs {sorted(df['run'].unique().tolist())})")


if __name__ == "__main__":
    main()

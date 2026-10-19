#!/usr/bin/env python3
"""Merge of runs 1..RUNS and the spread across runs (evaluation-pipeline rev 3 §4.3). Used by the figure scripts and
by experiments/eval/merge.py (CSV export of the merged tables).

  load(root, workload, runset, csvname, runs=None, allow_mixed_config=False) -> DataFrame
      concatenates <root>/<workload>/<runset>/run<k>/<csvname> for k in runs (default: every run<k> present); refuses
      (ValueError) rows whose config_sha256 differs between runs unless allow_mixed_config (pilot data only)
  agg(df, keys, cols) -> DataFrame
      per key group and column: <col>_mean, <col>_min, <col>_max, <col>_sd (sample sd, n >= 2), <col>_n (non-empty
      values); the figure default spread is min-max (n = 3); n < RUNS is visible in <col>_n
  ratio_to(df, keys, col, base_system="hw") -> Series
      per run: col / col of the base system at the same keys (ratio per run, then the caller aggregates: §4.3)
"""
import glob
import os
import re

import pandas as pd

KEYS = {  # merge keys per canonical CSV (besides workload); run is the repetition
    "slo_summary.csv": ["system", "point"],
    "fixed.csv": ["system", "point", "level"],
    "mg_probe.csv": ["point"],
}


def load(root, workload, runset, csvname, runs=None, allow_mixed_config=False):
    base = os.path.join(root, workload, runset)
    found = {}
    for d in glob.glob(os.path.join(base, "run*")):
        m = re.fullmatch(r"run(\d+)", os.path.basename(d))
        if m and os.path.isfile(os.path.join(d, csvname)):
            found[int(m.group(1))] = os.path.join(d, csvname)
    ks = sorted(found) if runs is None else [k for k in runs if k in found]
    if not ks:
        raise FileNotFoundError(f"no {csvname} below {base}/run<k>")
    df = pd.concat([pd.read_csv(found[k], dtype={"point": str, "level": str}) for k in ks], ignore_index=True)
    shas = sorted(df["config_sha256"].dropna().unique())
    if len(shas) > 1 and not allow_mixed_config:
        raise ValueError(f"{workload}/{runset}/{csvname}: runs differ in config_sha256 {shas} (a measurement key changed)")
    return df


def agg(df, keys, cols):
    g = df.groupby(keys, dropna=False, sort=True)
    parts = []
    for c in cols:
        x = pd.to_numeric(df[c], errors="coerce")
        gg = x.groupby([df[k] for k in keys], dropna=False, sort=True)
        parts.append(pd.DataFrame({f"{c}_mean": gg.mean(), f"{c}_min": gg.min(), f"{c}_max": gg.max(),
                                   f"{c}_sd": gg.std(ddof=1), f"{c}_n": gg.count()}))
    out = pd.concat(parts, axis=1).reset_index()
    out.insert(len(keys), "runs", g["run"].apply(lambda s: " ".join(str(v) for v in sorted(set(s)))).values)
    return out


def ratio_to(df, keys, col, base_system="hw"):
    other = [k for k in keys if k != "system"]
    base = df[df["system"] == base_system].set_index(["run"] + other)[col]
    idx = pd.MultiIndex.from_frame(df[["run"] + other])
    b = pd.to_numeric(base.reindex(idx).values, errors="coerce")
    return pd.to_numeric(df[col], errors="coerce").values / b

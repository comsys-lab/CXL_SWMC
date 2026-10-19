#!/usr/bin/env python3
"""RecSys export: canonical CSVs (evaluation-pipeline rev 3 §4.2; experiments/eval/canon.py) from one evidence dir.
Host only, offline; the evidence is only read. Metric formulas live here (breakdown.py / stream_check.py outputs are
read, not recomputed).

usage: export.py --run K --runset R --config-sha256 S --out DIR [--vcpus 16] <evidence dir>
Layouts:
  streaming block (main-block.sh BLOCK=stream; recovery/RECSYS-stream-v*; eval run-set roots whose subdirs block/,
    probe/, slo/, fix/ are such blocks): stream-results.tsv (one row per SLO lifetime, part <name>/slo), eval
    stream-fix.tsv (fixed windows: part <name>/fix, level L1 / L2 / Q<q/s>), root mg-decision.tsv (Megalon probe).
    point = update rate in trace samples/s. Rows of the run-1 Megalon probe block carry lifetime "probe" and stay in
    fixed.csv only where the run has no other window of the same system, rate and level (verifier M5).
  validation block (main-block.sh BLOCK=v1; recovery/RECSYS-V1-v*): <sys>/val (one fixed window, level V1); point =
    the update rate of sequence-update-rate.txt (samples/s, publication period T).
Outputs (DIR): slo_summary.csv, slo_steps.csv, latency_hist.csv (query stream), fixed.csv, mg_probe.csv.
Formulas (per step): achieved_x, p50/p95/p99, n_rop = loadgen query stream; wop_per_s = loadgen update stream
  achieved (samples/s); T_ms_rop / C_ms_rop = breakdown.csv fig2_query_T_ms / fig2_query_C_ms (per query; Megalon C =
  CohSnap derived, all-HWcc 0), T_ms_wop / C_ms_wop = fig2_row_update_* (per row update); pop_read_faults_per_rop =
  serve_is_faults / queries (I->S faults of the serving node per query); segments per query: seg_is / sm / wp /
  nontrans = serve_<kind>_fault_ms_per_query, seg_owner_wait = serve_read_msg_wait_ms_per_query, seg_inval_ipis =
  node1_tlb_irqs_per_query, seg_processing = T - C; cxl_recv_cpu_s_per_s = sum over both nodes of
  kthr.cxl_recv*.run_ns deltas / 1e9 / max target window (same rule as the vector DB); Megalon flush bytes per query =
  (sum over nodes of megalon.flush_bytes - op.*.mg.wflush_bytes) / queries, flushed_lines_per_rop = that / 64
  (Popcorn: read faults x 4096 / 64; all-HWcc 0); valid = stream_check.py per step (stream-check.csv);
  slo_summary valid = stream-results.tsv valid (every judged step valid).
"""
import argparse
import csv
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "eval"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loadgen"))
import canon  # noqa: E402
import stats_delta  # noqa: E402

SYS = {"all-HWcc": "hw", "Megalon": "mg"}


def col(row, prefix):
    for k, v in row.items():
        if k.startswith(prefix):
            return canon.fl(v)
    return None


def tsv(p):
    return [r for r in csv.reader(open(p), delimiter="\t") if r and not r[0].startswith("#")] if os.path.isfile(p) else []


def threads(life):
    st = wr = None
    p = os.path.join(life, "session-manifest.txt")
    if os.path.isfile(p):
        kv = dict(l.rstrip("\n").split("=", 1) for l in open(p) if "=" in l)
        m = re.search(r"--serve-threads (\d+)", kv.get("server_args", ""))
        st = m.group(1) if m else None
        m = re.search(r"--update-threads (\d+)", kv.get("node0_args", "")) or \
            re.search(r"--update-threads (\d+)", kv.get("server_args", ""))
        wr = m.group(1) if m else None
    return st, wr


def stats(part):
    """{step: (window_s, recv_run_ns, flush_bytes, wflush_bytes, has_flush)} summed over targets"""
    out = {}
    try:
        for fx, d in stats_delta.deltas(os.path.join(part, "loadgen")):
            t = out.setdefault(fx["step"], [0.0, 0.0, 0.0, 0.0, False])
            w = canon.fl(fx.get("window_s")) or 0.0
            t[0] = max(t[0], w)
            t[1] += sum(v for k, v in d.items() if k.startswith("kthr.cxl_recv") and k.endswith(".run_ns") and v)
            if "megalon.flush_bytes" in d:
                t[2] += d["megalon.flush_bytes"] or 0
                t[3] += sum(v or 0 for k, v in d.items() if re.fullmatch(r"op\.[a-z_]+\.mg\.wflush_bytes", k))
                t[4] = True
    except Exception as e:  # noqa: BLE001 (analysis only)
        print(f"export.py WARNING: {part}: stats unreadable ({e!r})", file=sys.stderr)
    return out


def step_rows(part, system):
    """per measured step: the canonical per-step metrics"""
    js = {d["step"]: d for d in canon.measured_steps(part)}
    bd = {int(r["step"]): r for r in csv.DictReader(open(os.path.join(part, "breakdown.csv")))} \
        if os.path.isfile(os.path.join(part, "breakdown.csv")) else {}
    sc = {int(r["step"]): r for r in csv.DictReader(open(os.path.join(part, "stream-check.csv")))} \
        if os.path.isfile(os.path.join(part, "stream-check.csv")) else {}
    stt = stats(part)
    out = []
    for n, d in sorted(js.items()):
        q, u, b = d["streams"].get("query", {}), d["streams"].get("update", {}), bd.get(n, {})
        T, C = col(b, "fig2_query_T_ms"), col(b, "fig2_query_C_ms[")
        nq = canon.fl(b.get("queries"))
        isf = canon.fl(b.get("serve_is_faults"))
        rf = isf / nq if isf is not None and nq else (0.0 if system == "hw" and b else None)
        win, recv, fb, wfb, hasf = stt.get(n, (0, 0, 0, 0, False))
        mgfb = (fb - wfb) / nq if hasf and nq else None
        lines = (mgfb / 64 if mgfb is not None else None) if system in ("mg", "mgoff") else \
            (rf * 4096 / 64 if rf is not None else None) if system == "pop" else 0.0
        v = sc.get(n, {}).get("valid")
        out.append(dict(step=n, phase=d["phase"], offered_x=q.get("offered"), achieved_x=q.get("achieved"),
                        n_rop=q.get("done"), p50_ms=q.get("p50_ms"), p95_ms=q.get("p95_ms"), p99_ms=q.get("p99_ms"),
                        pass_=d["pass"], aborted=d.get("aborted"), valid=None if v is None else v == "True",
                        wop_per_s=u.get("achieved"), wop_offered_per_s=u.get("offered"),
                        wop_done_ratio=canon.fl(sc.get(n, {}).get("written_ratio")), slo_pass=d["pass"], T_ms_rop=T, C_ms_rop=C, T_ms_wop=col(b, "fig2_row_update_T_ms"),
                        C_ms_wop=col(b, "fig2_row_update_C_ms["), pop_read_faults_per_rop=rf,
                        owner_wait_ms_rop=canon.fl(b.get("serve_read_msg_wait_ms_per_query")),
                        seg_is_ms_rop=canon.fl(b.get("serve_is_fault_ms_per_query")),
                        seg_sm_ms_rop=canon.fl(b.get("serve_sm_fault_ms_per_query")),
                        seg_wp_ms_rop=canon.fl(b.get("serve_wpu_fault_ms_per_query")),
                        seg_nontrans_ms_rop=canon.fl(b.get("serve_nontrans_fault_ms_per_query")),
                        seg_inval_ipis_per_rop=canon.fl(b.get("node1_tlb_irqs_per_query")),
                        seg_processing_ms_rop=(T - C) if T is not None and C is not None else None,
                        mg_flush_bytes_per_rop=mgfb, flushed_lines_per_rop=lines,
                        cxl_recv_cpu_s_per_s=round(recv / 1e9 / win, 4) if win else None))
    return out


def blocks(E):
    if os.path.isfile(os.path.join(E, "stream-results.tsv")):
        return [E]
    return sorted(os.path.dirname(p) for p in glob.glob(os.path.join(E, "*", "stream-results.tsv")))


def export_stream(E, out, vcpus):
    fixed = []
    for B in blocks(E):
        for f in tsv(os.path.join(B, "stream-results.tsv")):
            name, s, rate = f[0], f[1], f[2]
            part, life = os.path.join(B, name, "slo"), os.path.join(B, name)
            st, wr = threads(life)
            c = dict(system=s, point=rate, rate_unit="samples/s", vcpus_per_vm=vcpus, threads=st, writers=wr)
            rows = step_rows(part, s)
            best, at, cmin, cmax = canon.confirm_stats(part, "query")
            sm = canon.summary(part)
            slo = sm.get("slo", {})
            for r in rows:
                out.add("slo_steps.csv", **c, **{k: r[k] for k in (
                    "step", "phase", "offered_x", "achieved_x", "n_rop", "p50_ms", "p95_ms", "p99_ms", "valid", "aborted",
                    "wop_per_s", "wop_offered_per_s", "wop_done_ratio", "T_ms_rop", "C_ms_rop", "T_ms_wop", "C_ms_wop",
                    "pop_read_faults_per_rop", "owner_wait_ms_rop", "cxl_recv_cpu_s_per_s")}, **{"pass": r["pass_"]}, at_result=int(r["step"] in at),
                        slo_pct=slo.get("pct"), slo_ms=slo.get("ms"), lifetime="sep")
            js = {d["step"]: d for d in canon.measured_steps(part)}
            for step, bins in sorted(canon.latency_hist(part, "query").items()):
                if step in js:
                    for hi, n in bins:
                        out.add("latency_hist.csv", system=s, point=rate, step=step, phase=js[step]["phase"],
                                offered_x=js[step]["offered_x"], bin_hi_us=hi, count=n)
            atr = [r for r in rows if r["step"] in at]

            def mean(k):
                xs = [r[k] for r in atr if r[k] is not None]
                return sum(xs) / len(xs) if xs else None
            cf = sm.get("confirm", {}) if sm.get("confirmed") is True else {}
            out.add("slo_summary.csv", **c, slo_pct=slo.get("pct"), slo_ms=slo.get("ms"), result_x=best,
                    confirm_x_mean=cf.get("x_mean"), confirm_x_sd=cf.get("x_sd"), confirm_x_min=cmin, confirm_x_max=cmax,
                    confirmed=sm.get("confirmed"), valid=f[8], low_rate_violations=len(sm.get("low_rate_violations", [])),
                    ramp_end=sm.get("ramp_policy", {}).get("ramp_end"), knee_x=sm.get("ramp_policy", {}).get("knee_offered"),
                    note=sm.get("note", ""), at_result_achieved_x=mean("achieved_x"), at_result_p95_ms=mean("p95_ms"),
                    at_result_p99_ms=mean("p99_ms"), at_result_wop_per_s=mean("wop_per_s"),
                    at_result_T_ms_rop=mean("T_ms_rop"), at_result_C_ms_rop=mean("C_ms_rop"),
                    at_result_pop_read_faults_per_rop=mean("pop_read_faults_per_rop"),
                    at_result_cxl_recv_cpu_s_per_s=mean("cxl_recv_cpu_s_per_s"), lifetime="sep", source_dir=part)
        for f in tsv(os.path.join(B, "stream-fix.tsv")):
            name, s, rate, level, offered, step, valid = f[:7]
            part, life = os.path.join(B, name, "fix"), os.path.join(B, name)
            st, wr = threads(life)
            r = next((x for x in step_rows(part, s) if x["step"] == int(step)), None)
            if r is None:
                print(f"export.py WARNING: {part}: step {step} missing", file=sys.stderr)
                continue
            fixed.append(fix_row(r, dict(system=s, point=rate, rate_unit="samples/s", vcpus_per_vm=vcpus, threads=st,
                                         writers=wr), level, valid == "1" if valid else None, part,
                                 "probe" if os.path.basename(B) == "probe" else "sep" if name.endswith("-fix") else "cont"))
    probe = os.path.join(E, "probe", "stream-fix.tsv")
    dec = {f[0]: f[1] for f in tsv(os.path.join(E, "mg-decision.tsv"))}
    for f in tsv(probe):
        name, s, rate, level, offered, step, valid = f[:7]
        part = os.path.join(E, "probe", name, "fix")
        r = next((x for x in step_rows(part, s) if x["step"] == int(step)), {})
        scr = {int(x["step"]): x for x in csv.DictReader(open(os.path.join(part, "stream-check.csv")))} \
            if os.path.isfile(os.path.join(part, "stream-check.csv")) else {}
        sc = scr.get(int(step), {})
        out.add("mg_probe.csv", point=rate, offered_x=offered, T_ms_rop=r.get("T_ms_rop"), p95_ms=r.get("p95_ms"),
                achieved_wop_per_s=sc.get("written_per_s"), backlog_end=sc.get("lag_samples_end"),
                lag_ms_max=sc.get("lag_ms_max"), valid=valid == "1", decision=dec.get(rate), source_dir=part)
    return fixed


def fix_row(r, c, level, valid, part, life):
    keep = ("offered_x", "achieved_x", "slo_pass", "n_rop", "p95_ms", "p99_ms", "wop_per_s", "wop_offered_per_s",
            "wop_done_ratio", "T_ms_rop", "C_ms_rop", "T_ms_wop",
            "C_ms_wop", "pop_read_faults_per_rop", "seg_is_ms_rop", "seg_sm_ms_rop", "seg_wp_ms_rop",
            "seg_nontrans_ms_rop", "seg_inval_ipis_per_rop", "seg_processing_ms_rop", "mg_flush_bytes_per_rop",
            "flushed_lines_per_rop", "cxl_recv_cpu_s_per_s")
    return dict(c, level=level, step=r["step"], valid=valid if valid is not None else r["valid"],
                seg_owner_wait_ms_rop=r["owner_wait_ms_rop"], lifetime=life, source_dir=part, **{k: r[k] for k in keep})


def export_v1(E, out, vcpus):
    rate = None
    p = os.path.join(E, "sequence-update-rate.txt")
    if os.path.isfile(p):
        m = re.search(r"^rate_samples_per_s=([\d.]+)", open(p).read(), re.M)
        rate = m.group(1) if m else None
    fixed = []
    for part in sorted(glob.glob(os.path.join(E, "*", "val"))):
        s = os.path.basename(os.path.dirname(part))
        st, wr = threads(os.path.dirname(part))
        for r in step_rows(part, s):
            if r["phase"] == "fixed":
                fixed.append(fix_row(r, dict(system=s, point=rate, rate_unit="samples/s (T publication)",
                                             vcpus_per_vm=vcpus, threads=st, writers=wr), "V1", None, part, "sep"))
    return fixed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", required=True, type=int)
    ap.add_argument("--runset", default="rs-main")
    ap.add_argument("--config-sha256", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--vcpus", type=int, default=16)
    ap.add_argument("E")
    a = ap.parse_args()
    E = os.path.abspath(a.E)
    out = canon.Out("recsys", a.run, a.config_sha256)
    if blocks(E):
        fixed = export_stream(E, out, a.vcpus)
    elif glob.glob(os.path.join(E, "*", "val")):
        fixed = export_v1(E, out, a.vcpus)
    else:
        sys.exit(f"export.py: {E}: no stream-results.tsv and no <sys>/val parts")
    # verifier M5: the run-1 Megalon probe window (lifetime "probe") stays in fixed.csv only where no other Megalon
    # window of the same rate and level exists in this run (then it IS the run's mg window); never two rows per key
    own = {(x["system"], x["point"], x["level"]) for x in fixed if x["lifetime"] != "probe"}
    fixed = [x for x in fixed if x["lifetime"] != "probe" or (x["system"], x["point"], x["level"]) not in own]
    off = {(x["point"], x["level"]): x for x in fixed if x["system"] == "mgoff"}
    for x in fixed:
        if x["system"] == "mg" and (x["point"], x["level"]) in off:
            x["mgoff_T_ms_rop"] = off[(x["point"], x["level"])]["T_ms_rop"]
            x["mgoff_T_ms_wop"] = off[(x["point"], x["level"])]["T_ms_wop"]
        out.add("fixed.csv", **x)
    n = out.write(a.out)
    print("export.py recsys: " + " ".join(f"{k}={v}" for k, v in n.items()) + f" -> {a.out}")


if __name__ == "__main__":
    main()

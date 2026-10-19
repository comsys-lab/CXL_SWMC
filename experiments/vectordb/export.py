#!/usr/bin/env python3
"""Vector DB export: canonical CSVs (evaluation-pipeline rev 3 §4.2; experiments/eval/canon.py) from one evidence dir.
Host only, offline; the evidence is only read. Metric formulas live here (and in urate_report.py, reused).

usage: export.py --run K --runset R --config-sha256 S --out DIR [--vcpus 16] [--round N] <evidence dir>
Layouts:
  H1 hook layout (experiments/eval runset-vdb.sh roots, recovery/H1-main-v*): <E>/vdb/r<n>/run/h1-runs.tsv lists every
    part (<lifetime>/slo, <lifetime>/fix with "<L2 step>,<L1 step>"); point = mix u5/u50/u90 (upd_share 0.05/0.5/0.9).
    One round per export (--round, default: the only round present).
  update-rate sweep layout (urate-block.sh, recovery/vectorDB-update-rate-v*): <E>/urate-results.tsv, parts
    <E>/<sys>-u<R>/slo and <E>/<sys>-u<R>-fix/fix; point = updates/s.
Outputs (DIR): slo_summary.csv, slo_steps.csv, latency_hist.csv (search stream), fixed.csv (header-only mg_probe.csv).
Formulas (per step; opsplit-steps.csv per operation, loadgen stats deltas over the targets):
  achieved_x / p50,p95,p99 = loadgen search stream; wop_per_s = loadgen update stream achieved (urate layout: the
  server's done/s from urate-check.csv when present); T_ms_*, C_ms_* = opsplit T and C per op; pop_read_faults = I->S
  count per op, pop_write_faults = S->M + write-protect count per op; owner_wait_ms_rop = search-thread owner reply
  wait per server search (stats); cxl_recv_cpu_s_per_s = urate_report.py rule (opsplit window, else stats window).
  fixed.csv segments (read op): seg_{is,sm,wp,ipi,nontrans}_ms_rop = opsplit Popcorn time by fault kind,
  seg_owner_wait_ms_rop as above, seg_inval_ipis_per_rop = opsplit IPI count per search, seg_processing_ms_rop = T - C.
  Megalon: mg_wflush_bytes_per_wop = sum over targets of opt.{search,update}.meg.wflush_bytes / server inserts;
  mg_flush_bytes_per_rop = (sum of megalon.flush_bytes - writer flush bytes) / server searches (flushes outside write
  sections, attributed to reads: an inference to be confirmed by the verifier); flushed_lines_per_rop = Megalon
  mg_flush_bytes_per_rop / 64, Popcorn read faults x 4096 / 64, all-HWcc 0 (H1-fig3). mgoff_T_ms_* on Megalon rows =
  T of the timers-off lifetime at the same mix and level (C_diff = T(mg) - T(mgoff) is computed by the plot).
  valid (verifier M3): urate_check.py per step (<part>/urate-check.csv: urate sweep, and every eval op-mix part via
  m4-run.sh EVAL_RUN); empty for evidence without the server write counters (H1 r1, vdb builds < 17). slo_summary
  valid = urate-check.txt verdict (PASS 1 / NOTE 0), n_judged / n_invalid_judged from it. fixed.csv slo_pass = loadgen
  pass of the window (SLO met), not validity.
"""
import argparse
import csv
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "eval"))
import canon  # noqa: E402
import urate_report as ur  # noqa: E402
import stats_delta  # noqa: E402  (urate_report put experiments/loadgen on the path)

SHARE = {"u5": 0.05, "u50": 0.5, "u90": 0.9}
SYSNAME = {"hw": "hw", "pop": "pop", "mg": "mg", "mgoff": "mgoff"}


def server_threads(life):
    st, wr = None, "1"
    p = os.path.join(life, "manifest.txt")
    if os.path.isfile(p):
        for line in open(p):
            if line.startswith("server_args="):
                m = re.search(r"--search-threads (\d+)", line)
                st = m.group(1) if m else None
                m = re.search(r"--writer-threads (\d+)", line)
                wr = m.group(1) if m else "1"
    return st, wr


def parts_h1(E, rnd):
    rs = sorted(glob.glob(os.path.join(E, "vdb", "r*", "run", "h1-runs.tsv")))
    rs = [p for p in rs if re.fullmatch(r"r\d+", p.split(os.sep)[-3])]
    if rnd:
        rs = [p for p in rs if p.split(os.sep)[-3] == f"r{rnd}"]
    if len(rs) != 1:
        sys.exit(f"export.py: {E}: need exactly one round dir with run/h1-runs.tsv (found {len(rs)}; use --round)")
    run = os.path.dirname(rs[0])
    out = []
    for line in open(rs[0]):
        if line.startswith("#") or not line.strip():
            continue
        name, s, mix, ph, r, rd, steps, life = line.rstrip("\n").split("\t")
        lv = {}
        if ph == "fix":
            a, b = steps.split(",")
            lv = {int(a): "L2", int(b): "L1"}
        out.append(dict(system=s, point=mix, upd_share=SHARE.get(mix), rate_unit="mix", phase=ph,
                        part=os.path.join(run, rd), life=os.path.join(run, rd.split("/")[0]), levels=lv, lifetime=life))
    return out


def parts_urate(E):
    out = []
    for f in csv.reader(open(os.path.join(E, "urate-results.tsv")), delimiter="\t"):
        if not f or f[0].startswith("#"):
            continue
        name, s, rate = f[0], f[1], f[2]
        uc = os.path.join(E, name, "slo", "urate-check.txt")
        jd = ur.check_counts(open(uc).read())[:2] if os.path.isfile(uc) else None
        out.append(dict(system=s, point=rate, upd_share=None, rate_unit="updates/s", phase="slo",
                        part=os.path.join(E, name, "slo"), life=os.path.join(E, name), levels={}, lifetime="sep",
                        uvalid=f[9], ujudged=jd))
    for d in sorted(glob.glob(os.path.join(E, "*-u*-fix", "fix"))):
        m = re.fullmatch(r"(hw|pop)-u(\d+)-fix", os.path.basename(os.path.dirname(d)))
        if not m:
            continue
        lv = {}
        p = os.path.join(d, "h1-steps.txt")
        if os.path.exists(p):
            a, _, b = open(p).read().strip().partition(",")
            lv = {int(a): "L2", int(b): "L1"}
        out.append(dict(system=m.group(1), point=m.group(2), upd_share=None, rate_unit="updates/s", phase="fix",
                        part=d, life=os.path.dirname(d), levels=lv, lifetime="sep"))
    return out


def mg_flush(part):
    """{step: (flush_bytes_total, wflush_bytes_total, searches, updates)} summed over targets (stats deltas)"""
    out = {}
    try:
        for fx, d in stats_delta.deltas(os.path.join(part, "loadgen")):
            t = out.setdefault(fx["step"], [0.0, 0.0, 0.0, 0.0, 0])
            t[0] += d.get("megalon.flush_bytes") or 0
            t[1] += (d.get("opt.search.meg.wflush_bytes") or 0) + (d.get("opt.update.meg.wflush_bytes") or 0)
            t[2] += d.get("searches") or 0   # server searches
            t[3] += d.get("inserts") or 0    # server updates (one insert per delete + insert pair)
            t[4] += 1 if "megalon.flush_bytes" in d else 0
    except Exception as e:  # noqa: BLE001 (analysis only)
        print(f"export.py WARNING: {part}: stats unreadable ({e!r})", file=sys.stderr)
    return out


def common(p, vcpus):
    st, wr = server_threads(p["life"])
    return dict(system=p["system"], point=p["point"], upd_share=p["upd_share"], rate_unit=p["rate_unit"],
                vcpus_per_vm=vcpus, threads=st, writers=wr)


def recall(part):
    p = os.path.join(part, "recall.recall.txt")
    if not os.path.isfile(p):
        return None, None
    kv = dict(l.strip().split("=", 1) for l in open(p) if "=" in l and " " not in l.strip())
    return canon.fl(kv.get("recall_measured_ok")), canon.fl(kv.get("recall_tie_aware_measured_ok"))


def export(E, out, rnd, vcpus):
    parts = parts_urate(E) if os.path.isfile(os.path.join(E, "urate-results.tsv")) else parts_h1(E, rnd)
    fixed = []
    for p in parts:
        part, c = p["part"], common(p, vcpus)
        rows = ur.steps_of(part, p["system"] if p["system"] != "mgoff" else "mg")
        js = {d["step"]: d for d in canon.measured_steps(part)}
        s = canon.summary(part)
        slo = s.get("slo", {})
        # loadgen offered_x = total rate of the scaled streams; x = offered searches/s = offered_x x search share
        f0 = next((d for d in js.values() if d.get("offered_x")), None)
        share = f0["streams"]["search"]["offered"] / f0["offered_x"] if f0 else 1.0
        rd = lambda v: None if canon.fl(v) is None else round(float(v) * share, 6)  # noqa: E731
        # update-stream validity (verifier M3): urate_check.py per step (urate sweep; eval op-mix parts via m4-run.sh)
        dr, ucv, ucj = {}, None, None
        if os.path.isfile(os.path.join(part, "urate-check.csv")):
            with open(os.path.join(part, "urate-check.csv")) as f:
                dr = {int(x["step"]): canon.fl(x.get("done_ratio")) for x in csv.DictReader(f)}
        if os.path.isfile(os.path.join(part, "urate-check.txt")):
            txt = open(os.path.join(part, "urate-check.txt")).read()
            ucv = "1" if "URATECHECK PASS" in txt else "0" if "URATECHECK NOTE" in txt else None
            ucj = ur.check_counts(txt)[:2]
        if p["phase"] == "slo":
            best, at, cmin, cmax = canon.confirm_stats(part, "search")
            for r in rows:
                d = js.get(r["step"], {})
                sr, up = d.get("streams", {}).get("search", {}), d.get("streams", {}).get("update", {})
                out.add("slo_steps.csv", **c, step=r["step"], phase=r["phase"], offered_x=rd(r["offered_x"]),
                        achieved_x=r["search_per_s"], n_rop=sr.get("done"), p50_ms=sr.get("p50_ms"),
                        p95_ms=r["search_p95_ms"], p99_ms=r["search_p99_ms"], **{"pass": r["pass"]},
                        valid=r["valid"], at_result=int(r["step"] in at), aborted=d.get("aborted"),
                        wop_per_s=r["updates_per_s"] if r["updates_per_s"] is not None else up.get("achieved"),
                        wop_offered_per_s=up.get("offered"), wop_done_ratio=dr.get(r["step"]),
                        T_ms_rop=r["T_ms_per_search"], C_ms_rop=r["C_ms_per_search"], T_ms_wop=r["T_ms_per_update"],
                        C_ms_wop=r["C_ms_per_update"], pop_read_faults_per_rop=r["pop_read_faults_per_search"],
                        pop_write_faults_per_rop=r["pop_write_faults_per_search"],
                        pop_read_faults_per_wop=r["pop_read_faults_per_update"],
                        pop_write_faults_per_wop=r["pop_write_faults_per_update"],
                        owner_wait_ms_rop=r.get("search_owner_wait_ms"), cxl_recv_cpu_s_per_s=r["cxl_recv_cpu_s_per_s"],
                        slo_pct=slo.get("pct"), slo_ms=slo.get("ms"), lifetime=p["lifetime"])
            for step, bins in sorted(canon.latency_hist(part, "search").items()):
                d = js.get(step)
                if not d:
                    continue
                for hi, n in bins:
                    out.add("latency_hist.csv", system=p["system"], point=p["point"], step=step, phase=d["phase"],
                            offered_x=rd(d["offered_x"]), bin_hi_us=hi, count=n)
            atr = [r for r in rows if r["step"] in at]
            mean = lambda k: canon.fl(ur.mean([r.get(k) for r in atr])) if atr else None  # noqa: E731
            cf = s.get("confirm", {}) if s.get("confirmed") is True else {}
            uv = p.get("uvalid") if p.get("uvalid") is not None else ucv
            jd = p.get("ujudged") or ucj or [None, None]
            r10, r10t = recall(part)
            out.add("slo_summary.csv", **c, slo_pct=slo.get("pct"), slo_ms=slo.get("ms"), result_x=rd(best),
                    confirm_x_mean=cf.get("x_mean"), confirm_x_sd=cf.get("x_sd"), confirm_x_min=cmin, confirm_x_max=cmax,
                    confirmed=s.get("confirmed"), valid=uv if uv is not None else "", n_judged=jd[0],
                    n_invalid_judged=jd[1], low_rate_violations=len(s.get("low_rate_violations", [])),
                    ramp_end=s.get("ramp_policy", {}).get("ramp_end"), knee_x=rd(s.get("ramp_policy", {}).get("knee_offered")),
                    note=s.get("note", ""), recall10=r10, recall10_tie=r10t, at_result_achieved_x=mean("search_per_s"),
                    at_result_p95_ms=mean("search_p95_ms"), at_result_p99_ms=mean("search_p99_ms"),
                    at_result_wop_per_s=mean("updates_per_s"), at_result_T_ms_rop=mean("T_ms_per_search"),
                    at_result_C_ms_rop=mean("C_ms_per_search"),
                    at_result_pop_read_faults_per_rop=mean("pop_read_faults_per_search"),
                    at_result_cxl_recv_cpu_s_per_s=mean("cxl_recv_cpu_s_per_s"), lifetime=p["lifetime"], source_dir=part)
        else:
            mf = mg_flush(part) if p["system"] in ("mg", "mgoff") else {}
            for r in rows:
                if r["phase"] != "fixed":
                    continue
                d = js.get(r["step"], {})
                sr, up = d.get("streams", {}).get("search", {}), d.get("streams", {}).get("update", {})
                T, C = r["T_ms_per_search"], r["C_ms_per_search"]
                fb = wb = None
                if r["step"] in mf and mf[r["step"]][4]:
                    tot, wtot, ns, nu, _ = mf[r["step"]]
                    fb = (tot - wtot) / ns if ns else None
                    wb = wtot / nu if nu else None
                if p["system"] in ("mg", "mgoff"):
                    lines = fb / 64 if fb is not None else None
                elif p["system"] == "pop":
                    rf = r["pop_read_faults_per_search"]
                    lines = rf * 4096 / 64 if rf is not None else None
                else:
                    lines = 0.0
                fixed.append(dict(c, level=p["levels"].get(r["step"], ""), step=r["step"], offered_x=rd(r["offered_x"]),
                                  achieved_x=r["search_per_s"], valid=r["valid"], slo_pass=r["pass"],
                                  wop_offered_per_s=up.get("offered"), wop_done_ratio=dr.get(r["step"]),
                                  n_rop=sr.get("done"), p95_ms=r["search_p95_ms"], p99_ms=r["search_p99_ms"],
                                  wop_per_s=r["updates_per_s"] if r["updates_per_s"] is not None else up.get("achieved"),
                                  T_ms_rop=T, C_ms_rop=C, T_ms_wop=r["T_ms_per_update"], C_ms_wop=r["C_ms_per_update"],
                                  pop_read_faults_per_rop=r["pop_read_faults_per_search"],
                                  pop_write_faults_per_rop=r["pop_write_faults_per_search"],
                                  pop_read_faults_per_wop=r["pop_read_faults_per_update"],
                                  pop_write_faults_per_wop=r["pop_write_faults_per_update"],
                                  seg_is_ms_rop=r.get("search_pop_is_ms"), seg_sm_ms_rop=r.get("search_pop_sm_ms"),
                                  seg_wp_ms_rop=r.get("search_pop_wp_ms"), seg_ipi_ms_rop=r.get("search_pop_ipi_ms"),
                                  seg_nontrans_ms_rop=r.get("search_pop_nontrans_ms"),
                                  seg_owner_wait_ms_rop=r.get("search_owner_wait_ms"),
                                  seg_inval_ipis_per_rop=r.get("search_pop_ipi_cnt"),
                                  seg_processing_ms_rop=(T - C) if T is not None and C is not None else None,
                                  mg_flush_bytes_per_rop=fb, mg_wflush_bytes_per_wop=wb, flushed_lines_per_rop=lines,
                                  cxl_recv_cpu_s_per_s=r["cxl_recv_cpu_s_per_s"], lifetime=p["lifetime"], source_dir=part))
    off = {(x["point"], x["level"]): x for x in fixed if x["system"] == "mgoff"}
    for x in fixed:
        if x["system"] == "mg" and (x["point"], x["level"]) in off:
            x["mgoff_T_ms_rop"] = off[(x["point"], x["level"])]["T_ms_rop"]
            x["mgoff_T_ms_wop"] = off[(x["point"], x["level"])]["T_ms_wop"]
        x.pop("workload", None)
        out.add("fixed.csv", **x)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", required=True, type=int)
    ap.add_argument("--runset", default="vdb")
    ap.add_argument("--config-sha256", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--vcpus", type=int, default=16)
    ap.add_argument("--round", type=int)
    ap.add_argument("E")
    a = ap.parse_args()
    out = canon.Out("vdb", a.run, a.config_sha256)
    export(os.path.abspath(a.E), out, a.round, a.vcpus)
    n = out.write(a.out)
    print("export.py vdb: " + " ".join(f"{k}={v}" for k, v in n.items()) + f" -> {a.out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""H1 main: collect one workload's runs into CSVs for Excel and the Fig 1 / Fig 2 inputs (reports/H1-main-packet.md §6).

Reads only what the workload hooks wrote (never the guests): every <W dir>/{slo,fix}-r*/h1-runs.tsv (name system mix
phase round run_dir; run_dir holds loadgen/ and the run's manifest.txt), <W dir>/levels.tsv (levels.py).
Writes <W dir>/collect/ (new files only; refuses an existing collect/ dir — result dirs stay immutable):
  runs-index.csv     one row per run: workload mix system phase round name run_dir manifest_sha256 system_line
                     kernel(node0) note confirm x_mean/x_sd/pslo_mean, max_offered_x_pass, min_offered_x_fail,
                     n_curve_steps, n_overload_steps
  steps-all.csv      every step x stream of every run (experiments/loadgen/export_csv.py; label
                     <workload>/<mix>/<system>/<phase>-r<round>), the user's Excel input
  slo-summary.csv    per mix x system: max throughput under SLO per round (confirm x_mean +- x_sd, the 3 confirm
                     repeats), mean / sd over rounds when SLO_ROUNDS > 1, ratio to all-HWcc, overload points present
  fix-steps.csv      per fixed-load window: level (L1 | L2, matched by offered rate within 1 %), offered, achieved, SLO
                     percentile, pass, coherence CPU (below)
  fig/               v6_fig1_curves.py per mix (SLO round 1 runs; all rounds stay in the CSVs) and
                     v6_fig2_split.py per mix (L1 / L2 windows) — experiments/analysis, Megalon C per the shim
                     contract, no probe correction (CXL_SWMC 611a7ac6b, 7a2cfbf62)
  notes.txt          COLLECT NOTE lines (missing overload points, missing CPU source, figure script failures)
Coherence CPU per window (CLAUDE.md: CPU spent on coherence next to throughput and latency), seconds summed over nodes:
  recv_cpu_s   Popcorn message receive kthreads cxl_recv* (steps.csv n<k>_recv_cpu_s; every workload)
  meg_bg_cpu_s Megalon background threads, per workload source (the generic export_csv lib_bg_cpu_s is vector DB only:
               it counts every thread not named vdb-*):
               vdb    steps.csv n<k>_lib_bg_cpu_s
               kv, lmdb  opsplit.csv lib_bg_cpu_s[measured] (thread groups not named kv-* / lmdb-*)
               recsys breakdown.csv bg_cpu_ms_node<k>[measured] (thr.nr-log-sync + thr.mg-bg) / 1000
  coh_cpu_vcpus = (recv_cpu_s for Popcorn | meg_bg_cpu_s for Megalon | 0 for all-HWcc) / window_s
usage: collect.py --plan h1-plan.tsv --workload W [--no-figs] WDIR
Exit 0 with "COLLECT OK" (notes allowed), 1 on unreadable inputs ("COLLECT FAIL").
"""
import argparse, csv, glob, hashlib, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(HERE)
SYSTEMS = ("hw", "pop", "mg")
CURVE_PHASES = ("ramp", "bisect", "fill", "overload")
notes = []


def note(msg):
    notes.append(f"COLLECT NOTE {msg}")
    print(notes[-1])


def fail(msg):
    print(f"COLLECT FAIL {msg}")
    sys.exit(1)


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def plan_rows(path, w):
    out = []
    for line in open(path):
        if line.strip() and not line.startswith("#"):
            f = line.rstrip("\n").split("\t")
            if f[0] == w:
                out.append({"mix": f[1], "label": f[6]})
    return out


def runs_of(wdir):
    runs = []
    for idx in sorted(glob.glob(os.path.join(wdir, "*-r*", "h1-runs.tsv"))):
        d = os.path.dirname(idx)
        for line in open(idx):
            if not line.strip() or line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) != 6:
                fail(f"bad line in {idx}: {line.rstrip()}")
            rd = f[5] if os.path.isabs(f[5]) else os.path.join(d, f[5])
            runs.append({"name": f[0], "sys": f[1], "mix": f[2], "phase": f[3], "round": f[4], "dir": rd})
    if not runs:
        fail(f"no h1-runs.tsv under {wdir}")
    return runs


def load_steps(rd):
    p = os.path.join(rd, "loadgen", "steps.jsonl")
    try:
        return [json.loads(l) for l in open(p) if l.strip()]
    except (OSError, ValueError) as e:
        fail(f"{p}: {e}")


def load_summary(rd):
    p = os.path.join(rd, "loadgen", "summary.json")
    try:
        return json.load(open(p))
    except (OSError, ValueError) as e:
        fail(f"{p}: {e}")


def manifest(rd):
    for p in (os.path.join(rd, "manifest.txt"), os.path.join(rd, "session-manifest.txt"),
              os.path.join(os.path.dirname(rd), "session-manifest.txt")):
        if os.path.isfile(p):
            kv = {}
            for line in open(p):
                k, s, v = line.rstrip("\n").partition("=")
                if s and k not in kv:
                    kv[k] = v
            return p, kv
    return None, {}


def csv_rows(p):
    try:
        return list(csv.DictReader(open(p)))
    except OSError:
        return None


def fnum(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def coh_cpu(workload, run, step):
    """(recv_cpu_s, meg_bg_cpu_s, window_s, source) of one step; None where the source is absent."""
    recv = bg = win = None
    src = []
    rows = csv_rows(os.path.join(run["dir"], "steps.csv"))
    if rows:
        r = next((r for r in rows if r.get("step") == str(step)), None)
        if r:
            rv = [fnum(r[k]) for k in r if k.startswith("n") and k.endswith("_recv_cpu_s") and fnum(r[k]) is not None]
            recv = sum(rv) if rv else None
            ws = [fnum(r[k]) for k in r if k.startswith("n") and k.endswith("_window_s") and fnum(r[k]) is not None]
            win = sum(ws) / len(ws) if ws else None
            if workload == "vdb":
                bv = [fnum(r[k]) for k in r if k.endswith("_lib_bg_cpu_s") and fnum(r[k]) is not None]
                bg = sum(bv) if bv else None
                src.append("steps.csv")
    if workload in ("kv", "lmdb"):
        rows = csv_rows(os.path.join(run["dir"], "opsplit.csv"))
        if rows:
            r = next((r for r in rows if r.get("step") == str(step)), None)
            if r and fnum(r.get("lib_bg_cpu_s[measured]")) is not None:
                bg = fnum(r["lib_bg_cpu_s[measured]"])
                src.append("opsplit.csv")
    if workload == "recsys":
        rows = csv_rows(os.path.join(run["dir"], "breakdown.csv"))
        if rows:
            r = next((r for r in rows if r.get("step") == str(step)), rows[0] if len(rows) == 1 else None)
            if r:
                bv = [fnum(r[k]) for k in r if k.startswith("bg_cpu_ms_node") and fnum(r[k]) is not None]
                bg = sum(bv) / 1000 if bv else None
                src.append("breakdown.csv")
    return recv, bg, win, "+".join(src) or "steps.csv"


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--no-figs", action="store_true")
    ap.add_argument("wdir")
    a = ap.parse_args()
    W, wdir = a.workload, a.wdir
    out = os.path.join(wdir, "collect")
    if os.path.exists(out):
        fail(f"{out} exists (result dirs are immutable; collect into a fresh copy)")
    os.makedirs(os.path.join(out, "fig"))
    mixes = plan_rows(a.plan, W)
    runs = runs_of(wdir)
    levels = {}
    lp = os.path.join(wdir, "levels.tsv")
    if os.path.isfile(lp):
        for r in csv.DictReader(open(lp), delimiter="\t"):
            levels[r["mix"]] = r
    elif any(r["phase"] == "fix" for r in runs):
        fail(f"fix runs without {lp}")

    # runs-index.csv + slo-summary.csv
    idx, slo = [], {}
    for r in runs:
        s, st = load_summary(r["dir"]), load_steps(r["dir"])
        mp, mf = manifest(r["dir"])
        c = s.get("confirm", {})
        ncur = sum(1 for x in st if x.get("phase") in CURVE_PHASES)
        nov = sum(1 for x in st if x.get("phase") == "overload")
        if r["phase"] == "slo" and nov == 0:
            note(f"{r['name']}: no overload step past the knee (user rule: curves include points past the SLO)")
        if mp is None:
            note(f"{r['name']}: no manifest found")
        node0 = (mf.get("node0") or "").split()
        idx.append([W, r["mix"], r["sys"], r["phase"], r["round"], r["name"], r["dir"], sha256(mp) if mp else "",
                    mf.get("system", ""), node0[1] if len(node0) > 1 else "", mf.get("cxl_swmc_commit", ""),
                    s.get("note", ""), c.get("x_mean", ""), c.get("x_sd", ""), c.get("pslo_mean_ms", ""),
                    s.get("max_offered_x_pass", ""), s.get("min_offered_x_fail", ""), ncur, nov])
        if r["phase"] == "slo":
            slo.setdefault((r["mix"], r["sys"]), []).append((r["round"], c.get("x_mean"), c.get("x_sd"), nov))
    write_csv(os.path.join(out, "runs-index.csv"),
              ["workload", "mix", "system", "phase", "round", "name", "run_dir", "manifest_sha256", "system_line",
               "kernel_node0", "cxl_swmc_commit", "note", "confirm_x_mean", "confirm_x_sd", "confirm_pslo_mean_ms",
               "max_offered_x_pass", "min_offered_x_fail", "n_curve_steps", "n_overload_steps"], idx)
    rows = []
    for m in mixes:
        hw = slo.get((m["mix"], "hw"), [])
        hwx = [x for _, x, _, _ in hw if x]
        hwm = sum(hwx) / len(hwx) if hwx else None
        for k in SYSTEMS:
            v = sorted(slo.get((m["mix"], k), []))
            xs = [x for _, x, _, _ in v if x]
            mean = sum(xs) / len(xs) if xs else None
            sd = (sum((x - mean) ** 2 for x in xs) / (len(xs) - 1)) ** 0.5 if len(xs) > 1 else ""
            rows.append([W, m["mix"], m["label"], k, len(v), ";".join(f"r{rd}:{x}+-{s}" for rd, x, s, _ in v),
                         mean if mean is not None else "", sd,
                         round(mean / hwm, 4) if mean and hwm else "", all(n > 0 for *_, n in v) if v else ""])
    write_csv(os.path.join(out, "slo-summary.csv"),
              ["workload", "mix", "mix_label", "system", "rounds", "per_round_confirm_x_mean+-sd", "x_mean_over_rounds",
               "x_sd_over_rounds", "ratio_to_all_hwcc", "overload_points_present"], rows)

    # fix-steps.csv
    rows, fig2 = [], {}
    for r in (r for r in runs if r["phase"] == "fix"):
        lv = levels.get(r["mix"])
        if lv is None:
            fail(f"{r['name']}: mix {r['mix']} not in levels.tsv")
        want = {"L1": float(lv["L1_x"]), "L2": float(lv["L2_x"])}
        for s in load_steps(r["dir"]):
            if s.get("phase") != "fixed":
                continue
            off = float(s["offered_x"])
            lvl = [k for k, v in want.items() if abs(off / v - 1) <= 0.01]
            if len(lvl) != 1:
                note(f"{r['name']} step {s['step']}: offered {off} matches no level {want}")
                continue
            recv, bg, win, src = coh_cpu(W, r, s["step"])
            coh = 0.0 if r["sys"] == "hw" else (recv if r["sys"] == "pop" else bg)
            if coh is None:
                note(f"{r['name']} step {s['step']}: no coherence CPU source ({src})")
            st = next(iter(v for k, v in s["streams"].items() if k in ("search", "mixed", "query")), None)
            rows.append([W, r["mix"], r["sys"], r["round"], r["name"], lvl[0], s["step"], off, s.get("x"),
                         st.get("pslo_ms") if st else "", s.get("pass"), s.get("aborted"), recv if recv is not None else "",
                         bg if bg is not None else "", win if win is not None else "",
                         round(coh / win, 4) if coh is not None and win else "", src, r["dir"]])
            fig2.setdefault(r["mix"], []).append((lvl[0], r["sys"], r["round"], r["dir"], s["step"]))
    write_csv(os.path.join(out, "fix-steps.csv"),
              ["workload", "mix", "system", "rep", "name", "level", "step", "offered_x", "achieved_x", "pslo_ms", "pass",
               "aborted", "recv_cpu_s", "meg_bg_cpu_s", "window_s", "coh_cpu_vcpus", "cpu_source", "run_dir"], rows)

    # steps-all.csv (the Excel input; export_csv.py keeps its stable column set)
    specs = [f"{os.path.join(r['dir'], 'loadgen')}={W}/{r['mix']}/{r['sys']}/{r['phase']}-r{r['round']}" for r in runs]
    p = subprocess.run([sys.executable, "-B", os.path.join(EXP, "loadgen", "export_csv.py"), "--out",
                        os.path.join(out, "steps-all.csv")] + specs, capture_output=True, text=True)
    if p.returncode != 0:
        note(f"export_csv.py rc {p.returncode}: {p.stderr.strip()[-300:]}")

    # figures (analysis only: a failure is a note, the data stay)
    if not a.no_figs:
        an = os.path.join(EXP, "analysis")
        for m in mixes:
            r1 = {r["sys"]: r["dir"] for r in runs if r["phase"] == "slo" and r["mix"] == m["mix"] and r["round"] == "1"}
            if set(r1) == set(SYSTEMS):
                cmd = [sys.executable, "-B", os.path.join(an, "v6_fig1_curves.py"), "--out", os.path.join(out, "fig"),
                       "--tag", f"{W}-{m['mix']}"] + [f"{k}={r1[k]}" for k in SYSTEMS]
                p = subprocess.run(cmd, capture_output=True, text=True)
                if p.returncode != 0:
                    note(f"fig1 {m['mix']}: rc {p.returncode}: {(p.stderr or p.stdout).strip()[-300:]}")
            sel = [x for x in fig2.get(m["mix"], []) if x[2] == "1"]
            if {(l, k) for l, k, *_ in sel} == {(l, k) for l in ("L1", "L2") for k in SYSTEMS} and len(sel) == 6:
                cmd = [sys.executable, "-B", os.path.join(an, "v6_fig2_split.py"), "--out", os.path.join(out, "fig"),
                       "--tag", f"{W}-{m['mix']}"] + [f"{l}:{k}={d}:{st}" for l, k, _, d, st in sel]
                p = subprocess.run(cmd, capture_output=True, text=True)
                if p.returncode != 0:
                    note(f"fig2 {m['mix']}: rc {p.returncode}: {(p.stderr or p.stdout).strip()[-300:]}")
            elif fig2.get(m["mix"]):
                note(f"fig2 {m['mix']}: windows {sorted((l, k) for l, k, *_ in sel)} are not L1/L2 x hw/pop/mg")
    with open(os.path.join(out, "notes.txt"), "w") as f:
        f.write("\n".join(notes) + ("\n" if notes else ""))
    print(f"COLLECT OK {W} -> {out} ({len(runs)} runs, {len(notes)} notes)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""H1 main: collect one workload's runs into CSVs for Excel and the Fig 1 / Fig 2 inputs (reports/H1-main-packet.md §6).

Reads only what the workload hooks wrote (never the guests): every h1-runs.tsv below WDIR (name system mix phase round
run_dir; run_dir holds loadgen/ and the run's manifest.txt), levels.tsv (levels.py, written in round 1).
Writes WDIR/<out-name>/ (new files only; refuses an existing dir — result dirs stay immutable):
  runs-index.csv     one row per run: workload mix system phase round name run_dir manifest_sha256 system_line
                     kernel(node0) note confirm x_mean/x_sd/pslo_mean, max_offered_x_pass, min_offered_x_fail,
                     n_curve_steps, n_overload_steps, lifetime, then (2026-10-18 "A+C") bracket_lo, bracket_hi (knee
                     bracket on the offered scale: confirmed max rate under the SLO, lowest failed rate above it;
                     export_csv.knee_bracket: summary.json bracket, older runs from the steps), bracket_hi_phase,
                     bracket_source (summary | steps), confirmed, confirm_probes (confirms after the first),
                     confirm_finish (loadgen confirm_search.finish)
  steps-all.csv      every step x stream of every run (experiments/loadgen/export_csv.py; label
                     <workload>/<mix>/<system>/<phase>-r<round>), the user's Excel input
  slo-summary.csv    per mix x system: max throughput under SLO per round (confirm x_mean +- x_sd, the 3 confirm
                     repeats), mean / sd over the rounds present (rounds_note), ratio to all-HWcc, overload points
                     present, per_round_bracket (r<n>:lo..hi), bracket_lo / bracket_hi (single round: that round's
                     bracket; several rounds: the lowest lo and the highest hi over the rounds)
  fix-steps.csv      per fixed-load window: level (L1 | L2, matched by offered rate within 1 %), offered, achieved, SLO
                     percentile, pass, coherence CPU (below)
  fig/               v6_fig1_curves.py per mix (lowest SLO round present; all rounds stay in the CSVs) and
                     v6_fig2_split.py per mix (L1 / L2 windows of hw, pop, mg, mgoff) — experiments/analysis
  cdiff.csv          extraction of the Fig 2 CSVs of the round (no arithmetic), per mix x load x op: T of hw / pop /
                     Megalon timers off / on, C_diff_ns (the Fig 2 Megalon C, upper bound, dec 2026-10-17 "(a)"),
                     C_sampled_ns, C_method, Popcorn C and pop_T_minus_hw_ns, warn
  notes.txt          COLLECT NOTE lines (missing overload points, missing CPU source, figure script failures)
Coherence CPU per window (CLAUDE.md: CPU spent on coherence next to throughput and latency), seconds summed over nodes:
  recv_cpu_s   Popcorn message receive kthreads cxl_recv* (steps.csv n<k>_recv_cpu_s; every workload)
  meg_bg_cpu_s Megalon background threads, per workload source (the generic export_csv lib_bg_cpu_s is vector DB only:
               it counts every thread not named vdb-*):
               vdb    steps.csv n<k>_lib_bg_cpu_s
               kv, lmdb  opsplit.csv lib_bg_cpu_s[measured] (thread groups not named kv-* / lmdb-*)
               recsys breakdown.csv bg_cpu_ms_node<k>[measured] (thr.nr-log-sync + thr.mg-bg) / 1000
  coh_cpu_vcpus = (recv_cpu_s for Popcorn | meg_bg_cpu_s for Megalon | 0 for all-HWcc) / window_s
usage: collect.py --plan h1-plan.tsv --workload W [--levels levels.tsv] [--out-name collect | --out DIR] [--no-figs] WDIR
  --out DIR (2026-10-22): write the new dir DIR instead of WDIR/<out-name> (frozen evidence, e.g. eval2 run 1 H1 v1;
  check.py --collect DIR reads it)
  WDIR = one round of a workload (<E>/<W>/r<n>: run/ with h1-runs.tsv v2) or the workload root (<E>/<W>, every round; --out-name
  collect-all); runs = every h1-runs.tsv below WDIR outside collect* dirs and outside superseded stage attempts (v0.6.8,
  attempts.py: after `h1-main.sh --retry` only the current attempt r<n>-a<k> of a round counts). Figures use the lowest
  round present.
Systems per workload (h1sys.py, v0.6.7): recsys = hw, pop (user decision 2026-10-18; no Megalon in H1 RecSys):
  slo-summary has hw, pop rows; Fig 1 hw, pop curves; Fig 2 v6_fig2_split.py --megalon-c none (rows All HWcc,
  Popcorn); no cdiff rows; systems.txt (and each <tag>-windows.txt) states that the Megalon RecSys numbers come from
  RECSYS-V1 v1.4.
Exit 0 with "COLLECT OK" (notes allowed), 1 on unreadable inputs ("COLLECT FAIL").
"""
import argparse, csv, glob, hashlib, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(EXP, "loadgen"))
from export_csv import knee_bracket  # noqa: E402
sys.path.insert(0, HERE)
from h1sys import slo_systems, fix_systems, has_megalon, NO_MEGALON_NOTE  # noqa: E402
import attempts  # noqa: E402  (v0.6.8: superseded stage attempts are not collected)
SYSTEMS = ("hw", "pop", "mg")             # SLO phase (Fig 1): Megalon timers on (dec Q6); per workload slo_systems(W)
FIXSYS = ("hw", "pop", "mg", "mgoff")     # fixed phase (Fig 2): + Megalon timers off for C_diff (dec 2026-10-17 "(a)")
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
    try:  # v0.6.8: a workload root may hold superseded attempts (r<n> stopped, r<n>-a<k> current): skip those
        old = attempts.superseded(wdir)
    except ValueError as e:
        fail(f"attempt layout: {e}")
    for idx in sorted(glob.glob(os.path.join(wdir, "**", "h1-runs.tsv"), recursive=True)):
        parts = os.path.relpath(idx, wdir).split(os.sep)[:-1]
        if any(part.startswith("collect") for part in parts) or (parts and parts[0] in old):
            continue
        d = os.path.dirname(idx)
        for line in open(idx):
            if not line.strip() or line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) not in (6, 8):  # v1: 6 columns; v2 (H1-HOOK v2): + steps ("<L2>,<L1>" | "-"), lifetime (sep | cont)
                fail(f"bad line in {idx}: {line.rstrip()}")
            rd = f[5] if os.path.isabs(f[5]) else os.path.join(d, f[5])
            st = f[6].split(",") if len(f) == 8 and f[6] != "-" else None
            runs.append({"name": f[0], "sys": f[1], "mix": f[2], "phase": f[3], "round": f[4], "dir": rd,
                         "steps": [int(x) for x in st] if st else None, "life": f[7] if len(f) == 8 else "sep"})
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
              os.path.join(os.path.dirname(rd), "manifest.txt"), os.path.join(os.path.dirname(rd), "session-manifest.txt")):
        if os.path.isfile(p):
            kv = {}
            for line in open(p):
                k, s, v = line.rstrip("\n").partition("=")
                if s and k not in kv:
                    kv[k] = v
            return p, kv
    return None, {}


def csv_rows(p):
    """rows of a run file; a lifetime part dir (H1-HOOK v2: <lifetime>/<part>/loadgen) falls back to the parent's file"""
    for q in (p, os.path.join(os.path.dirname(os.path.dirname(p)), os.path.basename(p))):
        try:
            return list(csv.DictReader(open(q)))
        except OSError:
            continue
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


CD_HEADER = ["workload", "mix", "load", "op", "T_hw_ns", "T_pop_ns", "T_mg_off_ns", "T_mg_on_ns", "C_mg_diff_ns",
             "C_mg_sampled_ns", "C_method", "C_pop_ns", "pop_T_minus_hw_ns", "warn", "source", "round"]


def cdiff(fig2_csv, W, mix, out_rows, rnd=""):
    """Extraction only (no arithmetic): the analysis Fig 2 CSV (v6_fig2_split.py --megalon-c diff, CXL_SWMC 5b650ab4f)
    publishes per load x op the row "Megalon (timers off)" with C_ns = C_diff_ns = T(mgoff) - T(hw) (upper bound),
    T_mg_on_ns and C_sampled_ns, and the Popcorn row with pop_T_minus_hw_ns. One row per load x op here, all mixes of
    the round in one file for Excel."""
    try:
        text = open(fig2_csv).read().splitlines()
    except OSError:
        note(f"cdiff {mix}: no {fig2_csv}")
        return
    hdr = next((i for i, l in enumerate(text) if l.startswith("load,op,system")), None)
    if hdr is None:
        note(f"cdiff {mix}: no header in {fig2_csv}")
        return
    t = {}
    for r in csv.DictReader(text[hdr:]):
        t[(r["load"], r["op"], r["system"])] = r
    for load, op in sorted({(l, o) for l, o, _ in t}):
        hw, pop, mg = (t.get((load, op, k)) or {} for k in ("All HWcc", "Popcorn", "Megalon (timers off)"))
        out_rows.append([W, mix, load, op, hw.get("T_ns", ""), pop.get("T_ns", ""), mg.get("T_ns", ""),
                         mg.get("T_mg_on_ns", ""), mg.get("C_diff_ns", ""), mg.get("C_sampled_ns", ""),
                         mg.get("C_method", ""), pop.get("C_ns", ""), pop.get("pop_T_minus_hw_ns", ""), mg.get("warn", ""),
                         os.path.basename(fig2_csv), rnd])


def blank(v):
    return "" if v is None else v


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
    ap.add_argument("--levels", help="levels.tsv (default <WDIR>/levels.tsv)")
    ap.add_argument("--out-name", default="collect", help="output dir name below WDIR (default collect)")
    ap.add_argument("--out", help="output dir (default <WDIR>/<out-name>); e.g. outside a frozen evidence dir")
    ap.add_argument("wdir")
    a = ap.parse_args()
    W, wdir = a.workload, a.wdir
    SYSTEMS, FIXSYS, MG = slo_systems(W), fix_systems(W), has_megalon(W)  # per workload (v0.6.7)
    mgnote = NO_MEGALON_NOTE.get(W, f"no Megalon for {W}")
    out = a.out or os.path.join(wdir, a.out_name)
    if os.path.exists(out):
        fail(f"{out} exists (result dirs are immutable; collect into a fresh copy)")
    os.makedirs(os.path.join(out, "fig"))
    if not MG:
        with open(os.path.join(out, "systems.txt"), "w") as f:
            f.write(f"systems {' '.join(SYSTEMS)} (h1sys.py): {mgnote}\n")
    mixes = plan_rows(a.plan, W)
    runs = runs_of(wdir)
    levels = {}
    lp = a.levels or os.path.join(wdir, "levels.tsv")
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
        kb = knee_bracket(s, st) if r["phase"] == "slo" else {}
        cs = s.get("confirm_search", {})
        idx.append([W, r["mix"], r["sys"], r["phase"], r["round"], r["name"], r["dir"], sha256(mp) if mp else "",
                    mf.get("system", ""), node0[1] if len(node0) > 1 else "", mf.get("cxl_swmc_commit", ""),
                    s.get("note", ""), c.get("x_mean", ""), c.get("x_sd", ""), c.get("pslo_mean_ms", ""),
                    s.get("max_offered_x_pass", ""), s.get("min_offered_x_fail", ""), ncur, nov, r["life"],
                    blank(kb.get("lo")), blank(kb.get("hi")), kb.get("hi_phase", ""), kb.get("source", ""),
                    kb.get("confirmed", ""), cs.get("probes", ""), cs.get("finish", "")])
        if r["phase"] == "slo":
            slo.setdefault((r["mix"], r["sys"]), []).append((r["round"], c.get("x_mean"), c.get("x_sd"), nov,
                                                            kb.get("lo"), kb.get("hi")))
    write_csv(os.path.join(out, "runs-index.csv"),
              ["workload", "mix", "system", "phase", "round", "name", "run_dir", "manifest_sha256", "system_line",
               "kernel_node0", "cxl_swmc_commit", "note", "confirm_x_mean", "confirm_x_sd", "confirm_pslo_mean_ms",
               "max_offered_x_pass", "min_offered_x_fail", "n_curve_steps", "n_overload_steps", "lifetime",
               "bracket_lo", "bracket_hi", "bracket_hi_phase", "bracket_source", "confirmed", "confirm_probes",
               "confirm_finish"], idx)
    rows = []
    for m in mixes:
        hw = slo.get((m["mix"], "hw"), [])
        hwx = [x for _, x, *_ in hw if x]
        hwm = sum(hwx) / len(hwx) if hwx else None
        for k in SYSTEMS:
            v = sorted(slo.get((m["mix"], k), []))
            xs = [x for _, x, *_ in v if x]
            los = [lo for *_, lo, _ in v if lo]
            his = [hi for *_, hi in v if hi]
            mean = sum(xs) / len(xs) if xs else None
            sd = (sum((x - mean) ** 2 for x in xs) / (len(xs) - 1)) ** 0.5 if len(xs) > 1 else ""
            rows.append([W, m["mix"], m["label"], k, len(v), ";".join(f"r{rd}:{x}+-{s}" for rd, x, s, *_ in v),
                         mean if mean is not None else "", sd,
                         round(mean / hwm, 4) if mean and hwm else "", all(t[3] > 0 for t in v) if v else "",
                         "single round (no variance)" if len(v) == 1 else f"{len(v)} rounds: mean and sample sd",
                         ";".join(f"r{t[0]}:{blank(t[4])}..{blank(t[5])}" for t in v),
                         min(los) if los else "", max(his) if his else ""])
    write_csv(os.path.join(out, "slo-summary.csv"),
              ["workload", "mix", "mix_label", "system", "rounds", "per_round_confirm_x_mean+-sd", "x_mean_over_rounds",
               "x_sd_over_rounds", "ratio_to_all_hwcc", "overload_points_present", "rounds_note", "per_round_bracket",
               "bracket_lo", "bracket_hi"], rows)

    # fix-steps.csv
    rows, fig2 = [], {}
    for r in (r for r in runs if r["phase"] == "fix"):
        lv = levels.get(r["mix"])
        if lv is None:
            fail(f"{r['name']}: mix {r['mix']} not in levels.tsv")
        # a fixed-mode step's offered_x is the block's rate argument (vector DB: total of search + update streams =
        # L_x / (1 - U/100); observed in recovery/VDB-V1-v1.3.1: offered_x 83.41 at 78.48 search/s), so windows are
        # matched against levels.tsv L*_rate, not L*_x
        want = {"L1": float(lv["L1_rate"]), "L2": float(lv["L2_rate"])}
        named = {r["steps"][0]: "L2", r["steps"][1]: "L1"} if r["steps"] else None  # v2: the hook names the windows
        for s in load_steps(r["dir"]):
            if named is not None:
                if s["step"] not in named:
                    continue  # settle, warm-up or other parts of the lifetime
            elif s.get("phase") != "fixed":
                continue
            off = float(s["offered_x"])
            lvl = [k for k, v in want.items() if abs(off / v - 1) <= 0.01]
            if named is not None and lvl != [named[s["step"]]]:
                note(f"{r['name']} step {s['step']}: named {named[s['step']]} but offered {off} vs levels {want}")
                continue
            if len(lvl) != 1:
                note(f"{r['name']} step {s['step']}: offered {off} matches no level {want}")
                continue
            recv, bg, win, src = coh_cpu(W, r, s["step"])
            coh = 0.0 if r["sys"] == "hw" else (recv if r["sys"] == "pop" else bg)  # mg and mgoff: Megalon background
            if coh is None:
                note(f"{r['name']} step {s['step']}: no coherence CPU source ({src})")
            st = next(iter(v for k, v in s["streams"].items() if k in ("search", "mixed", "query")), None)
            rows.append([W, r["mix"], r["sys"], r["round"], r["name"], lvl[0], s["step"], off, s.get("x"),
                         st.get("pslo_ms") if st else "", s.get("pass"), s.get("aborted"), recv if recv is not None else "",
                         bg if bg is not None else "", win if win is not None else "",
                         round(coh / win, 4) if coh is not None and win else "", src, r["dir"],
                         # fixed mode: offered_x = total rate argument, x = the x-stream only (vector DB: search) ->
                         # the keep-up ratio uses the sum of all streams' achieved rates
                         round(sum(v.get("achieved", 0) for v in s["streams"].values()), 4), r["life"]])
            fig2.setdefault(r["mix"], []).append((lvl[0], r["sys"], r["round"], r["dir"], s["step"], r["life"]))
    write_csv(os.path.join(out, "fix-steps.csv"),
              ["workload", "mix", "system", "rep", "name", "level", "step", "offered_x", "achieved_x", "pslo_ms", "pass",
               "aborted", "recv_cpu_s", "meg_bg_cpu_s", "window_s", "coh_cpu_vcpus", "cpu_source", "run_dir", "achieved_total",
               "lifetime"], rows)

    # steps-all.csv (the Excel input; export_csv.py keeps its stable column set)
    specs = [f"{os.path.join(r['dir'], 'loadgen')}={W}/{r['mix']}/{r['sys']}/{r['phase']}-r{r['round']}" for r in runs]
    p = subprocess.run([sys.executable, "-B", os.path.join(EXP, "loadgen", "export_csv.py"), "--out",
                        os.path.join(out, "steps-all.csv")] + specs, capture_output=True, text=True)
    if p.returncode != 0:
        note(f"export_csv.py rc {p.returncode}: {p.stderr.strip()[-300:]}")

    # figures (analysis only: a failure is a note, the data stay)
    cd_rows = []
    if not a.no_figs:
        an = os.path.join(EXP, "analysis")
        rounds = sorted({r["round"] for r in runs}, key=int)
        multi = len(rounds) > 1  # collect-all over several rounds: one figure set per round, tag ...-r<n>
        for fr in rounds:
            for m in mixes:
                tag = f"{W}-{m['mix']}" + (f"-r{fr}" if multi else "")
                r1 = {r["sys"]: r["dir"] for r in runs if r["phase"] == "slo" and r["mix"] == m["mix"] and r["round"] == fr}
                if set(r1) == set(SYSTEMS):
                    cmd = [sys.executable, "-B", os.path.join(an, "v6_fig1_curves.py"), "--out", os.path.join(out, "fig"),
                           "--tag", tag] + [f"{k}={r1[k]}" for k in SYSTEMS]
                    p = subprocess.run(cmd, capture_output=True, text=True)
                    if p.returncode != 0:
                        note(f"fig1 {tag}: rc {p.returncode}: {(p.stderr or p.stdout).strip()[-300:]}")
                sel = [x for x in fig2.get(m["mix"], []) if x[2] == fr]
                if not sel:
                    continue
                # which lifetime each Fig 2 window came from (user 2026-10-18: r1 mixes hw/pop separate, mg
                # continuous, mgoff separate; r2/r3 hw/pop/mg continuous) -> <tag>-windows.txt beside the figure
                with open(os.path.join(out, "fig", f"{tag}-windows.txt"), "w") as f:
                    f.write(f"# Fig 2 windows of {W} {m['mix']} round {fr}" + ("" if multi else " (single round)") + "\n")
                    if not MG:
                        f.write(f"# {mgnote}\n")
                    for l, k, _, d, st, life in sorted(sel):
                        f.write(f"{l} {k} {'separate' if life == 'sep' else 'continuous'} lifetime, step {st}, {d}\n")
                if {(l, k) for l, k, *_ in sel} == {(l, k) for l in ("L1", "L2") for k in FIXSYS} and len(sel) == 2 * len(FIXSYS):
                    # Megalon C = C_diff = T(mgoff) - T(hw) (dec 2026-10-17 "(a)"): v6_fig2_split.py --megalon-c diff
                    # (default since CXL_SWMC 5b650ab4f) needs all four systems per load and refuses otherwise
                    f2 = os.path.join(an, "v6_fig2_split.py")
                    mc = ["--megalon-c", "diff"] if MG else ["--megalon-c", "none", "--megalon-note", mgnote]
                    cmd = [sys.executable, "-B", f2] + mc + ["--out", os.path.join(out, "fig"),
                           "--tag", tag] + [f"{l}:{k}={d}:{st}" for l, k, _, d, st, _ in sel]
                    p = subprocess.run(cmd, capture_output=True, text=True)
                    if p.returncode != 0:
                        note(f"fig2 {tag}: rc {p.returncode}: {(p.stderr or p.stdout).strip()[-300:]}")
                    elif MG:  # no C_diff without Megalon (v0.6.7 recsys)
                        cdiff(os.path.join(out, "fig", f"{tag}-fig2.csv"), W, m["mix"], cd_rows, fr)
                else:
                    note(f"fig2 {tag}: windows {sorted((l, k) for l, k, *_ in sel)} are not L1/L2 x {'/'.join(FIXSYS)}")
        write_csv(os.path.join(out, "cdiff.csv"), CD_HEADER, cd_rows)
    with open(os.path.join(out, "notes.txt"), "w") as f:
        f.write("\n".join(notes) + ("\n" if notes else ""))
    print(f"COLLECT OK {W} -> {out} ({len(runs)} runs, {len(notes)} notes)")


if __name__ == "__main__":
    main()

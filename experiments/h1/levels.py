#!/usr/bin/env python3
"""H1 main: the two Fig 2 loads of one workload from its SLO phase (reports/H1-main-packet.md §4.3).

MOT1 v6 §3 (decided 2026-10-16) and the user decision of 2026-10-17 (state/TASKS.md): all three systems run at the
SAME offered rate, L1 = the weakest system's max throughput under the SLO, L2 = 0.5 x L1, determined anew in H1 main
(Popcorn build 12 / Megalon 77, pretouch). Applied per mix (inferred from "H1 is measured at three mixes"; packet Q2).

"Max throughput under the SLO" of a system = loadgen summary.json confirm.x_mean of its SLO run (the mean achieved
x-stream rate of the confirm repeats, as every earlier L rule: m4-lib.sh confirm_x, kv pilot-block confirm_l). With
several SLO dirs the per-system value is the mean over them; H1 main calls it only with round 1 (dec Q3: levels from
r1, reused in r2/r3), in r1 per mix through levels-cb.sh --mix.
No confirmed max (decision E, user 2026-10-22 00:1x, reports/experiments/de-stijl-motivation-isca27.md §6 E): an SLO
search that ended with one of the NOTED notes ("the start rate already violates the SLO; lower --start", "confirm
failed at three rates; ...") or without a confirm result is NOT a stop: that system's x for the mix = the achieved x
(loadgen steps.jsonl "x" = achieved searches/s) of its LOWEST ramp step (the measured "ramp" step with the lowest
offered_x; the same step Figs 5 and 7 draw as the hatched point), and the row records x_<sys>_src = lowest_step (else
confirm) so the CSV and the caption can flag the mix. L1 = min over systems as before, L2 = L1 / 2.
Verifier M1 (2026-10-22): never for All-HWcc: an hw search without a confirmed max is a LEVELS STOP (broken lifetime).
Verifier M2 (prepared, waits for the user): the run plan's directive "#! levels_confirm_fail=highest_pass" (conf key
VDB_LEVELS_CONFIRM_FAIL, runset-vdb.sh) makes a CONFIRM-failed search use the achieved x of its highest passing
ramp/bisect step (src highest_pass); a failed start rate always uses the lowest ramp step. Default lowest_step.
Refused (exit 1, "LEVELS STOP <reason>"; real errors only; the sequence stops):
  - a run whose summary.json is unreadable, whose workload_finish != ok, or whose note is not one of NOTED (e.g.
    "streams exhausted", "max steps reached ..."); a fallback run without a measured ramp step with x > 0;
  - a run whose summary SLO differs from the plan row's slo;
  - a mix without exactly one SLO run per system and round (the workload's systems, h1sys.py: hw, pop, mg; recsys
    hw, pop since v0.6.7, user decision 2026-10-18).
L1 = min over the workload's systems; for recsys (no Megalon) the r1 callback runs after the hw and pop SLO-only
lifetimes of the mix (main-block.sh BLOCK=h1), and x_mg is "-".

usage: levels.py --plan h1-plan.tsv --workload W --out levels.tsv SLO_DIR [SLO_DIR ...]
  SLO_DIR  one SLO-phase evidence dir per round (holds the hook's h1-runs.tsv)
levels.tsv (tab separated, one row per mix, header line first):
  mix weakest x_hw x_pop x_mg L1_x L2_x factor L1_rate L2_rate rounds sources x_hw_src x_pop_src x_mg_src
  x_*: per-system x (mean over rounds); L*_rate: the fixed-load rate argument for the workload's block
  (L*_x x factor, rounded to the plan's decimals); sources: run dirs used; x_*_src: confirm | lowest_step |
  highest_pass (decision E;
  several rounds: the per-round sources joined by "+"), "-" for a system not measured. The three src columns are
  appended after the older ones (positional readers, v6-block.sh h1_levels $9/$10, are unchanged).
  Python use: system_x(run_dir, slo) -> (x, sd, path, src) (also v6-block.sh h2_mix, the H2 level set).
"""
import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from h1sys import slo_systems  # noqa: E402  (v0.6.7: systems per workload; recsys = hw, pop)

SYSTEMS = ("hw", "pop", "mg")  # levels.tsv columns x_hw x_pop x_mg (fixed header; "-" for a system not measured)


def stop(msg):
    print(f"LEVELS STOP {msg}")
    sys.exit(1)


def read_plan(path, workload):
    rows = []
    for line in open(path):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) not in (7, 8):
            stop(f"bad plan line: {line.rstrip()}")
        if f[0] == workload:
            rows.append({"mix": f[1], "param": f[2], "factor": float(f[3]), "round": int(f[4]), "slo": f[5]})
    if not rows:
        stop(f"workload {workload} not in {path}")
    return rows


def read_runs(d):
    """h1-runs.tsv of a hook evidence dir: name system mix phase round run_dir (run_dir holds loadgen/)."""
    p = os.path.join(d, "h1-runs.tsv")
    if not os.path.isfile(p):
        stop(f"missing {p}")
    out = []
    for line in open(p):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) not in (6, 8):  # v1: 6 columns; v2 (H1-HOOK v2): + steps, lifetime
            stop(f"bad h1-runs.tsv line in {p}: {line.rstrip()}")
        name, sysk, mix, phase, rnd, rd = f[:6]
        if not os.path.isabs(rd):
            rd = os.path.join(d, rd)
        out.append({"name": name, "sys": sysk, "mix": mix, "phase": phase, "round": rnd, "dir": rd})
    return out


START_NOTE = "the start rate already violates the SLO; lower --start"
CONFIRM_NOTE = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)"
NOTED = (START_NOTE, CONFIRM_NOTE)  # SLO-search outcomes without a confirmed max (decision E); any other note = error


class LevelsError(Exception):
    pass


CONFIRM_FAIL = ("lowest_step", "highest_pass")  # policy for CONFIRM_NOTE (plan directive, see plan_confirm_fail)


def plan_confirm_fail(path):
    """policy for a failed confirm from the plan's directive line "#! levels_confirm_fail=<lowest_step|highest_pass>"
    (runset-vdb.sh writes it into the run plan from the conf key VDB_LEVELS_CONFIRM_FAIL); absent = lowest_step
    (decision E as decided 2026-10-22). highest_pass (verifier M2, waits for the user): the achieved x of the highest
    passing ramp/bisect step; a failed start rate always uses lowest_step."""
    v = "lowest_step"
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("#! levels_confirm_fail="):
                    v = line.split("=", 1)[1].strip()
    except OSError:
        pass
    if v not in CONFIRM_FAIL:
        raise LevelsError(f"{path}: levels_confirm_fail={v} (lowest_step | highest_pass)")
    return v


def _steps(run_dir):
    p = os.path.join(run_dir, "loadgen", "steps.jsonl")
    try:
        with open(p) as f:
            return [json.loads(l) for l in f if l.strip()], p
    except (OSError, ValueError) as e:
        raise LevelsError(f"cannot read {p}: {e}")


def lowest_step_x(run_dir):
    """(achieved x, offered_x, step no) of the measured ramp step with the lowest offered_x (steps.jsonl)"""
    st, p = _steps(run_dir)
    ramp = [s for s in st if s.get("phase") == "ramp" and (s.get("measure_s") or 0) > 0]
    if not ramp:
        raise LevelsError(f"no measured ramp step in {p}")
    s = min(ramp, key=lambda s: (float(s["offered_x"]), s["step"]))
    if not (s.get("x") or 0) > 0:
        raise LevelsError(f"lowest ramp step {s['step']} of {p} has achieved x {s.get('x')}")
    return float(s["x"]), float(s["offered_x"]), s["step"]


def highest_pass_x(run_dir):
    """(achieved x, offered_x, step no) of the passing measured ramp/bisect step with the highest offered_x"""
    st, p = _steps(run_dir)
    ok = [s for s in st if s.get("phase") in ("ramp", "bisect") and (s.get("measure_s") or 0) > 0 and s.get("pass")
          and (s.get("x") or 0) > 0]
    if not ok:
        raise LevelsError(f"no passing ramp/bisect step in {p}")
    s = max(ok, key=lambda s: (float(s["offered_x"]), -s["step"]))
    return float(s["x"]), float(s["offered_x"]), s["step"]


def system_x(run_dir, slo, confirm_fail="lowest_step", system=None):
    """(x, x_sd, summary path, src) of one SLO run; src = confirm | lowest_step | highest_pass (decision E; the
    confirm-failed policy confirm_fail). system="hw": All-HWcc must have a confirmed max (verifier M1: a failed
    All-HWcc search is a broken lifetime, never an L1 source) -> LevelsError. LevelsError = real error."""
    x, sd, p, src = _system_x(run_dir, slo, confirm_fail)
    if system == "hw" and src != "confirm":
        raise LevelsError(f"All-HWcc has no confirmed max ({p}); decision E applies to Popcorn and Megalon only")
    return x, sd, p, src


def _system_x(run_dir, slo, confirm_fail):
    p = os.path.join(run_dir, "loadgen", "summary.json")
    try:
        with open(p) as f:
            s = json.load(f)
    except (OSError, ValueError) as e:
        raise LevelsError(f"cannot read {p}: {e}")
    if s.get("workload_finish") != "ok":
        raise LevelsError(f"workload_finish {s.get('workload_finish')}")
    so = s.get("slo", {})
    try:
        got = f"{so.get('stream')}:{float(so.get('pct')):g}:{float(so.get('ms')):g}" if so else "none"
    except (TypeError, ValueError):
        got = f"unreadable {so}"
    want = slo.split(":")
    want = f"{want[0]}:{float(want[1]):g}:{float(want[2]):g}"
    if got != want:
        raise LevelsError(f"SLO {got} != plan {want}")
    note = s.get("note") or ""
    if note and note not in NOTED:
        raise LevelsError(f"SLO search ended with the note '{note}' (not a decision-E outcome)")
    x = (s.get("confirm") or {}).get("x_mean") or 0
    if not note and x > 0:
        return float(x), float(s["confirm"].get("x_sd", 0.0)), p, "confirm"
    if note == CONFIRM_NOTE and confirm_fail == "highest_pass":
        hx, off, n = highest_pass_x(run_dir)
        return hx, 0.0, f"{p} (no confirmed max: {note}; highest passing step {n} offered {off:g})", "highest_pass"
    lx, off, n = lowest_step_x(run_dir)
    return lx, 0.0, f"{p} (no confirmed max: {note or 'no confirm result'}; lowest ramp step {n} offered {off:g})", \
        "lowest_step"


def confirm_x(run, slo, confirm_fail="lowest_step"):
    try:
        return system_x(run["dir"], slo, confirm_fail, run["sys"])
    except LevelsError as e:
        stop(f"{run['name']}: {e}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mix", help="one mix only, appended to --out (the r1 in-lifetime callback, levels-cb.sh): the row "
                    "must not exist yet; the other mixes of the plan are not required")
    ap.add_argument("slo_dirs", nargs="+")
    a = ap.parse_args()
    plan = read_plan(a.plan, a.workload)
    try:
        cfail = plan_confirm_fail(a.plan)
    except LevelsError as e:
        stop(str(e))
    if a.mix:
        plan = [r for r in plan if r["mix"] == a.mix]
        if not plan:
            stop(f"mix {a.mix} not in the plan for {a.workload}")
    systems = slo_systems(a.workload)
    runs = [r for d in a.slo_dirs for r in read_runs(d) if r["phase"] == "slo"]
    extra = sorted({r["sys"] for r in runs} - set(systems))
    if extra:
        stop(f"SLO runs of systems {extra} not measured for {a.workload} (h1sys.py: {' '.join(systems)})")
    nround = len(a.slo_dirs)
    lines = ["\t".join(["mix", "weakest", "x_hw", "x_pop", "x_mg", "L1_x", "L2_x", "factor", "L1_rate", "L2_rate",
                        "rounds", "sources"] + [f"x_{k}_src" for k in SYSTEMS])]
    for row in plan:
        xs, src, per_round, xsrc = {}, [], [], {}
        for k in systems:
            sel = [r for r in runs if r["mix"] == row["mix"] and r["sys"] == k]
            rounds = sorted(r["round"] for r in sel)
            if len(sel) != nround or len(set(rounds)) != nround:
                stop(f"mix {row['mix']} system {k}: {len(sel)} SLO runs for {nround} rounds ({rounds})")
            vals, srcs = [], []
            for r in sorted(sel, key=lambda r: r["round"]):
                x, sd, p, how = confirm_x(r, row["slo"], cfail)
                vals.append(x)
                srcs.append(how)
                src.append(r["dir"])
                per_round.append(f"{row['mix']} {k} r{r['round']} x={x:g} x_sd={sd:g} src={how} ({p})")
            xs[k] = sum(vals) / len(vals)
            xsrc[k] = "+".join(srcs)
        weakest = min(systems, key=lambda k: xs[k])
        l1 = xs[weakest]
        l2 = 0.5 * l1
        r1, r2 = (round(v * row["factor"], row["round"]) for v in (l1, l2))
        if row["round"] == 0:
            r1, r2 = int(r1), int(r2)
        if r2 <= 0:
            stop(f"mix {row['mix']}: L2 rate {r2} <= 0")
        for v in per_round:
            print(v)
        fb = [k for k in systems if xsrc[k] != "confirm"]
        print(f"{a.workload} {row['mix']}: weakest {weakest} x={l1:g}; L1_x={l1:g} L2_x={l2:g}; "
              f"rates L1={r1} L2={r2} (factor {row['factor']:g})"
              + (f"; decision E: no confirmed max for {' '.join(fb)} (x = lowest ramp step)" if fb else ""))
        lines.append("\t".join([row["mix"], weakest] + [f"{xs[k]:.6g}" if k in xs else "-" for k in SYSTEMS] +
                               [f"{l1:.6g}", f"{l2:.6g}", f"{row['factor']:g}", str(r1), str(r2), str(nround),
                                ",".join(src)] + [xsrc.get(k, "-") for k in SYSTEMS]))
    if a.mix and os.path.isfile(a.out):  # append one row; refuse an existing row for this mix
        old = open(a.out).read().rstrip("\n").split("\n")
        if old[0] != lines[0]:
            stop(f"{a.out}: header differs")
        if any(l.split("\t")[0] == a.mix for l in old[1:]):
            stop(f"{a.out}: mix {a.mix} already has a row")
        lines = old + lines[1:]
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, a.out)
    print(f"LEVELS OK {a.workload} -> {a.out}")


if __name__ == "__main__":
    main()

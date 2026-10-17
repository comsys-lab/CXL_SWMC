#!/usr/bin/env python3
"""H1 main: the two Fig 2 loads of one workload from its SLO phase (reports/H1-main-packet.md §4.3).

MOT1 v6 §3 (decided 2026-10-16) and the user decision of 2026-10-17 (state/TASKS.md): all three systems run at the
SAME offered rate, L1 = the weakest system's max throughput under the SLO, L2 = 0.5 x L1, determined anew in H1 main
(Popcorn build 12 / Megalon 77, pretouch). Applied per mix (inferred from "H1 is measured at three mixes"; packet Q2).

"Max throughput under the SLO" of a system = loadgen summary.json confirm.x_mean of its SLO run (the mean achieved
x-stream rate of the confirm repeats, as every earlier L rule: m4-lib.sh confirm_x, kv pilot-block confirm_l). With
SLO_ROUNDS > 1 the per-system value is the mean over rounds (packet Q3; printed per round as well).
Refused (exit 1, "LEVELS STOP <reason>"; the sequence stops, a methodology judgment waits for the user):
  - a run with a non-empty summary note (e.g. "confirm failed at three rates"), no confirm result, or
    workload_finish != ok;
  - a run whose summary SLO differs from the plan row's slo;
  - a mix without exactly one SLO run per system and round (systems hw, pop, mg).

usage: levels.py --plan h1-plan.tsv --workload W --out levels.tsv SLO_DIR [SLO_DIR ...]
  SLO_DIR  one SLO-phase evidence dir per round (holds the hook's h1-runs.tsv)
levels.tsv (tab separated, one row per mix, header line first):
  mix weakest x_hw x_pop x_mg L1_x L2_x factor L1_rate L2_rate rounds sources
  x_*: per-system x (mean over rounds); L*_rate: the fixed-load rate argument for the workload's block
  (L*_x x factor, rounded to the plan's decimals); sources: run dirs used.
"""
import argparse, json, os, sys

SYSTEMS = ("hw", "pop", "mg")


def stop(msg):
    print(f"LEVELS STOP {msg}")
    sys.exit(1)


def read_plan(path, workload):
    rows = []
    for line in open(path):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) != 7:
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
        if len(f) != 6:
            stop(f"bad h1-runs.tsv line in {p}: {line.rstrip()}")
        name, sysk, mix, phase, rnd, rd = f
        if not os.path.isabs(rd):
            rd = os.path.join(d, rd)
        out.append({"name": name, "sys": sysk, "mix": mix, "phase": phase, "round": rnd, "dir": rd})
    return out


def confirm_x(run, slo):
    p = os.path.join(run["dir"], "loadgen", "summary.json")
    try:
        s = json.load(open(p))
    except (OSError, ValueError) as e:
        stop(f"{run['name']}: cannot read {p}: {e}")
    if s.get("note"):
        stop(f"{run['name']}: SLO search ended with a note ({s['note']}); never used for L1 (packet Q4)")
    if s.get("workload_finish") != "ok":
        stop(f"{run['name']}: workload_finish {s.get('workload_finish')}")
    so = s.get("slo", {})
    got = f"{so.get('stream')}:{so.get('pct'):g}:{so.get('ms'):g}" if so else "none"
    want = slo.split(":")
    want = f"{want[0]}:{float(want[1]):g}:{float(want[2]):g}"
    if got != want:
        stop(f"{run['name']}: SLO {got} != plan {want}")
    x = s.get("confirm", {}).get("x_mean", 0)
    if not x or x <= 0:
        stop(f"{run['name']}: no confirm result")
    return float(x), float(s["confirm"].get("x_sd", 0.0)), p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("slo_dirs", nargs="+")
    a = ap.parse_args()
    plan = read_plan(a.plan, a.workload)
    runs = [r for d in a.slo_dirs for r in read_runs(d) if r["phase"] == "slo"]
    nround = len(a.slo_dirs)
    lines = ["\t".join(["mix", "weakest", "x_hw", "x_pop", "x_mg", "L1_x", "L2_x", "factor", "L1_rate", "L2_rate",
                        "rounds", "sources"])]
    for row in plan:
        xs, src, per_round = {}, [], []
        for k in SYSTEMS:
            sel = [r for r in runs if r["mix"] == row["mix"] and r["sys"] == k]
            rounds = sorted(r["round"] for r in sel)
            if len(sel) != nround or len(set(rounds)) != nround:
                stop(f"mix {row['mix']} system {k}: {len(sel)} SLO runs for {nround} rounds ({rounds})")
            vals = []
            for r in sorted(sel, key=lambda r: r["round"]):
                x, sd, p = confirm_x(r, row["slo"])
                vals.append(x)
                src.append(r["dir"])
                per_round.append(f"{row['mix']} {k} r{r['round']} x_mean={x:g} x_sd={sd:g} ({p})")
            xs[k] = sum(vals) / len(vals)
        weakest = min(SYSTEMS, key=lambda k: xs[k])
        l1 = xs[weakest]
        l2 = 0.5 * l1
        r1, r2 = (round(v * row["factor"], row["round"]) for v in (l1, l2))
        if row["round"] == 0:
            r1, r2 = int(r1), int(r2)
        if r2 <= 0:
            stop(f"mix {row['mix']}: L2 rate {r2} <= 0")
        for v in per_round:
            print(v)
        print(f"{a.workload} {row['mix']}: weakest {weakest} x={l1:g}; L1_x={l1:g} L2_x={l2:g}; "
              f"rates L1={r1} L2={r2} (factor {row['factor']:g})")
        lines.append("\t".join([row["mix"], weakest] + [f"{xs[k]:.6g}" for k in SYSTEMS] +
                               [f"{l1:.6g}", f"{l2:.6g}", f"{row['factor']:g}", str(r1), str(r2), str(nround),
                                ",".join(src)]))
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, a.out)
    print(f"LEVELS OK {a.workload} -> {a.out}")


if __name__ == "__main__":
    main()

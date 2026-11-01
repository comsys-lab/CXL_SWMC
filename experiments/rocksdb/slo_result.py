#!/usr/bin/env python3
"""Result rows of RocksDB SLO-search cells (eval3 blocks D and E; v1-block.sh evidence dirs). Host only, read-only.

One row per KIND=slo run dir (<E>/<sys>-<mix>-n<N>/loadgen/{summary.json,steps.jsonl}); columns as the vector DB
h2n-results.tsv plus the RocksDB / past-the-knee checks:
  name system mix U nodes vcpus_per_vm max_offered_x_pass confirm_x_mean confirmed note max_rps_under_slo src
  confirm_p99_ms n_ramp n_bisect n_confirm n_fill n_overload overload_past_knee send_lag_steps check run_dir
Decision rules (same as the vector DB cells and experiments/h1/levels.py decision E):
  - confirmed search: max_rps_under_slo = confirm.x_mean (mean achieved requests/s of the confirm repeats), src confirm;
    consistency: the highest passing confirm step's offered rate must equal summary max_offered_x_pass
    (single-repeat confirms; with confirm_reps > 1 the pooled verdict is not recomputable from steps.jsonl: skipped);
  - noted notes ("the start rate already violates the SLO; lower --start", "confirm failed at three rates; ..."):
    max_rps_under_slo = achieved x of the lowest-offered measured ramp step, src lowest_step (decision E); never for
    all-HWcc (check ERROR: a broken hw lifetime);
  - any other note, workload_finish != ok, unreadable files, SLO != mixed:99:1: check ERROR, empty max;
  - past the knee (user rule: SLO curves include points past the knee): overload_past_knee = number of overload steps
    with offered > max_offered_x_pass (start rate for a start-fail search) that violate the SLO (pass false);
    0 -> check WARN (the curve has no point past the knee);
  - send_lag_steps = summary passing_steps_with_send_lag; > 0 -> check WARN (the Host loadgen may bound the result,
    a risk at N = 8 hw).
usage: slo_result.py [--slo-ms 1] [--out results.tsv] <run dir> [<run dir> ...]
       run dir name <sys>-<mix>-n<N> (sys hw | pop | ds; mix u<k>); exit 1 if any row is ERROR.
"""
import argparse, json, os, re, sys

NOTED = ("the start rate already violates the SLO; lower --start",
         "confirm failed at three rates; the knee is noisy (longer --confirm-s?)")
COLS = ("name system mix U nodes vcpus_per_vm max_offered_x_pass confirm_x_mean confirmed note max_rps_under_slo src "
        "confirm_p99_ms n_ramp n_bisect n_confirm n_fill n_overload overload_past_knee send_lag_steps check run_dir").split()
NAME_RE = re.compile(r"^(hw|pop|ds)-u(\d+)-n([2-8])$")


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, float):
        return f"{v:.6g}"
    return str(v)


def decide(summary, steps, system, slo_ms=1.0):
    """Pure decision logic on parsed summary.json + steps.jsonl rows; returns a dict of the derived columns."""
    out = {"max_offered_x_pass": summary.get("max_offered_x_pass"), "confirm_x_mean": None,
           "confirmed": summary.get("confirmed"), "note": summary.get("note", ""), "max_rps_under_slo": None,
           "src": "", "confirm_p99_ms": None, "overload_past_knee": 0, "check": "OK", "why": []}
    meas = [s for s in steps if s.get("phase") != "warmup"]
    for ph in ("ramp", "bisect", "confirm", "fill", "overload"):
        out["n_" + ph] = sum(1 for s in meas if s.get("phase") == ph)

    def err(msg):
        out["check"] = "ERROR"
        out["why"].append(msg)

    slo = summary.get("slo") or {}
    if (slo.get("stream"), float(slo.get("pct", 0)), float(slo.get("ms", 0))) != ("mixed", 99.0, float(slo_ms)):
        err(f"slo {slo} != mixed:99:{slo_ms}")
    if summary.get("workload_finish") != "ok":
        err(f"workload_finish {summary.get('workload_finish')}")
    note = out["note"]
    conf = summary.get("confirm") or {}
    if note == "" and summary.get("confirmed") is True:
        out["confirm_x_mean"] = conf.get("x_mean")
        out["confirm_p99_ms"] = conf.get("pslo_mean_ms")
        out["max_rps_under_slo"], out["src"] = conf.get("x_mean"), "confirm"
        if out["max_rps_under_slo"] is None:
            err("confirmed without confirm.x_mean")
        reps = int(conf.get("reps", 1) or 1)
        if reps == 1:
            cp = [s["offered_x"] for s in meas if s.get("phase") == "confirm" and s.get("pass")]
            best = max(cp) if cp else None
            if best is None or abs(best - float(out["max_offered_x_pass"] or -1)) > 1e-6 * max(1.0, best):
                err(f"highest passing confirm step {best} != max_offered_x_pass {out['max_offered_x_pass']}")
    elif note in NOTED:
        ramp = [s for s in meas if s.get("phase") == "ramp"]
        if system == "hw":
            err(f"all-HWcc search without a confirmed max ({note})")
        elif not ramp or not (min(ramp, key=lambda s: s["offered_x"]).get("x", 0) > 0):
            err("decision E: no measured ramp step with x > 0")
        else:
            lo = min(ramp, key=lambda s: s["offered_x"])
            out["max_rps_under_slo"], out["src"] = lo["x"], "lowest_step"
        out["confirm_x_mean"] = conf.get("x_mean") if summary.get("confirmed") else None
    elif note:
        err(f"loadgen note: {note}")
    else:
        err("not confirmed and no note")
    if note == NOTED[0]:
        knee = min((s["offered_x"] for s in meas if s.get("phase") == "ramp"), default=None)
    else:
        knee = out["max_offered_x_pass"]
    if knee is not None:
        out["overload_past_knee"] = sum(1 for s in meas if s.get("phase") == "overload" and s["offered_x"] > knee
                                        and not s.get("pass"))
    if out["check"] == "OK" and out["overload_past_knee"] == 0:
        out["check"] = "WARN"
        out["why"].append("no overload step past the knee violates the SLO")
    # passing steps whose sender lagged its schedule: the Host loadgen, not the system, may bound the result
    out["send_lag_steps"] = int(summary.get("passing_steps_with_send_lag", 0) or 0)
    if out["check"] == "OK" and out["send_lag_steps"] > 0:
        out["check"] = "WARN"
        out["why"].append(f"{out['send_lag_steps']} passing steps with send lag (loadgen-bound?)")
    return out


def row(run_dir, slo_ms, vcpus):
    name = os.path.basename(os.path.normpath(run_dir))
    m = NAME_RE.match(name)
    base = {c: "" for c in COLS}
    base.update(name=name, run_dir=run_dir, vcpus_per_vm=vcpus)
    if not m:
        base.update(check="ERROR", note=f"run dir name {name} is not <sys>-u<k>-n<N>")
        return base, ["bad name"]
    base.update(system=m.group(1), mix="u" + m.group(2), U=m.group(2), nodes=m.group(3))
    try:
        with open(os.path.join(run_dir, "loadgen", "summary.json")) as f:
            summary = json.load(f)
        with open(os.path.join(run_dir, "loadgen", "steps.jsonl")) as f:
            steps = [json.loads(l) for l in f if l.strip()]
    except (OSError, ValueError) as e:
        base.update(check="ERROR")
        return base, [f"unreadable loadgen output: {e}"]
    d = decide(summary, steps, m.group(1), slo_ms)
    for c in COLS:
        if c in d:
            base[c] = d[c]
    return base, d["why"]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--slo-ms", type=float, default=1.0)
    ap.add_argument("--vcpus", default="4")
    ap.add_argument("--out")
    ap.add_argument("runs", nargs="+")
    a = ap.parse_args(argv)
    lines, bad = ["# " + "\t".join(COLS)], 0
    for r in a.runs:
        rw, why = row(r, a.slo_ms, a.vcpus)
        lines.append("\t".join(fmt(rw[c]) for c in COLS))
        if why:
            print(f"{rw['name']}: {rw['check']}: {'; '.join(why)}", file=sys.stderr)
        bad += rw["check"] == "ERROR"
    text = "\n".join(lines) + "\n"
    if a.out:
        if os.path.exists(a.out):
            print(f"refusing: {a.out} exists", file=sys.stderr)
            return 2
        with open(a.out, "w") as f:
            f.write(text)
    sys.stdout.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

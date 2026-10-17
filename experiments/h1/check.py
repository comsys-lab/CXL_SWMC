#!/usr/bin/env python3
"""H1 main stage check: acceptance checks of one workload x round (reports/H1-main-packet.md §8; user decision
2026-10-17: the main session reviews each round-1 result before the next workload; rounds 2/3 stop on a FAIL).

Reads only Host-side results of <E>/<W>/r<n>/ (run/ = the block dir with h1-runs.tsv v2, collect/) and
<E>/<W>/levels.tsv (+ the r1 (and r2) results for n > 1).
Writes <E>/<W>/r<n>/check.txt (one line per check, last line "H1CHECK PASS ..." or "H1CHECK FAIL ..."); exit 1 on FAIL.
FAIL = integrity: the round cannot enter Fig 1 / Fig 2. WARN = plausibility: recorded, judged by the main session
(h1-accept.sh copies the accepted WARN lines).

FAIL checks (every workload):
  F1 completeness: run/h1-runs.tsv: per mix one slo entry for hw, pop, mg and one fix entry for hw, pop, mg, mgoff
     (Megalon timers off), round n, lifetime labels as expected (r1 hw/pop sep, mg cont; r2/r3 cont; mgoff sep)
  F2 per SLO run: empty note (Q4: a noted run stops the workload), workload_finish ok, SLO = plan, confirm reps 3 and
     x_mean > 0, >= 1 fill and >= 1 overload step (points past the knee), >= 3 passing ramp/bisect/fill steps
  F3 per run: h1-runcheck.txt ending in "RUNCHECK PASS" (the hook's per-run validation checks), the workload split
     file (vdb opsplit-steps.csv, kv/lmdb opsplit.csv, recsys breakdown.csv), node0 kernel = Popcorn build 12
     (runs-index.csv kernel_node0 ends with -ds-popcorn-new-12)
  F4 fixed windows: per mix exactly the 8 windows L1/L2 x hw/pop/mg/mgoff (collect fix-steps.csv, offered within 1 % of levels.tsv L*_rate)
  F5 Fig 2 CSV per mix (collect/fig/<W>-<mix>-fig2.csv, v6_fig2_split.py --megalon-c diff, CXL_SWMC 5b650ab4f; rows
     All HWcc, Popcorn, Megalon (timers off)): all-HWcc C_ns = 0; Popcorn 0 <= C_ns <= T_ns and C_ns summed over ops
     and loads > 0; Megalon C_sampled_ns (timers-on run) present and > 0 on every row (C_sampled > T_mg_on is WARN W5)
  F6 coherence CPU: every Popcorn and Megalon (on, off) window has coh_cpu_vcpus; Popcorn recv_cpu_s > 0
  F9 the Fig 2 CSV has a "Megalon (timers off)" row for every load (L1, L2) x op with C_diff_ns present, C_ns =
     C_diff_ns and C_method "diff ..." (the Fig 2 Megalon C, upper bound, user decision 2026-10-17 "(a)")
  F7 collect notes.txt has no "no overload step", "fig1", "fig2" or "export_csv" note
  F8 (n = 1) levels.tsv weakest system = argmin of this round's confirm x_mean per mix
WARN checks:
  W1 all-HWcc below max(Popcorn, Megalon) x 0.98 at a mix
  W2 confirm x_sd / x_mean > 5 % or confirm fails >= 1
  W3 fixed window achieved (all streams) / offered < 0.95 or pass = False (expected possible for the weakest system at L1)
  W4 (n > 1) a system's confirm x_mean differs from round 1 by > 10 %, or this round's weakest system differs from
     levels.tsv
  W5 Megalon C_sampled_ns > T_mg_on_ns on a row
  C1/C2 (n > 1; REPORT, not FAIL: separate vs continuous, user decision 2026-10-18) hw/pop T r1 (separate lifetime)
     vs r<n> (continuous) beyond max(5 %, 2 x run-to-run spread), C_diff beyond max(10 %, 2 x |dT_mg|); see compare().
     REPORT lines go to the user before r3; h1-accept.sh refuses them without --user-ack.
  W6 C_diff_ns < 0 on a row (message carries the Popcorn cross-check pop_T_minus_hw_ns vs its C and the analysis warn)
usage: check.py --plan h1-plan.tsv --workload W --round n [--skip-fig2] E
"""
import argparse, csv, json, os, sys

SYSTEMS = ("hw", "pop", "mg")            # SLO phase (Fig 1, Megalon timers on)
FIXSYS = ("hw", "pop", "mg", "mgoff")    # fixed phase (Fig 2; mgoff = Megalon timers off for C_diff)
SPLIT = {"vdb": "opsplit-steps.csv", "kv": "opsplit.csv", "lmdb": "opsplit.csv", "recsys": "breakdown.csv"}
lines, nfail, nwarn, nrep = [], 0, 0, 0


def res(kind, name, ok, msg=""):
    global nfail, nwarn, nrep
    if ok:
        lines.append(f"OK   {name}")
        return
    if kind == "R":  # separate vs continuous beyond the run-to-run spread: not a FAIL; the user sees it before r3
        nrep += 1
        lines.append(f"REPORT {name}: {msg}")
        return
    if kind == "F":
        nfail += 1
        lines.append(f"FAIL {name}: {msg}")
    else:
        nwarn += 1
        lines.append(f"WARN {name}: {msg}")


def plan_mixes(path, w):
    out = {}
    for line in open(path):
        if line.strip() and not line.startswith("#"):
            f = line.rstrip("\n").split("\t")
            if f[0] == w:
                out[f[1]] = f[5]
    return out


def runs(d):
    p = os.path.join(d, "h1-runs.tsv")
    out = []
    if not os.path.isfile(p):
        return None
    for line in open(p):
        if line.strip() and not line.startswith("#"):
            f = line.rstrip("\n").split("\t")
            if len(f) in (6, 8):  # v2 (H1-HOOK v2): + steps, lifetime
                rd = f[5] if os.path.isabs(f[5]) else os.path.join(d, f[5])
                out.append({"name": f[0], "sys": f[1], "mix": f[2], "phase": f[3], "round": f[4], "dir": rd,
                            "life": f[7] if len(f) == 8 else "sep"})
    return out


def jl(p):
    try:
        return [json.loads(l) for l in open(p) if l.strip()]
    except (OSError, ValueError):
        return None


def js(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None


def rows(p):
    try:
        return list(csv.DictReader(open(p)))
    except OSError:
        return None


def fig2_rows(p):
    """v6_common.write_csv puts meta lines before the header; the header starts with load,op,system."""
    try:
        text = open(p).read().splitlines()
    except OSError:
        return None
    for i, l in enumerate(text):
        if l.startswith("load,op,system"):
            return list(csv.DictReader(text[i:]))
    return None


def fnum(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def fig2_t(E, W, n, m):
    """{(load, op, key): ns} from the round's official Fig 2 CSV: T_ns of hw / pop, T_mg_on_ns of mg (timers on),
    C_diff_ns; None if missing"""
    f2 = fig2_rows(os.path.join(E, W, f"r{n}", "collect", "fig", f"{W}-{m}-fig2.csv"))
    if f2 is None:
        return None
    out = {}
    for x in f2:
        k = (x["load"], x["op"])
        if x["system"] == "All HWcc":
            out[k + ("hw",)] = fnum(x.get("T_ns"))
        elif x["system"] == "Popcorn":
            out[k + ("pop",)] = fnum(x.get("T_ns"))
        elif x["system"] == "Megalon (timers off)":
            out[k + ("mg",)] = fnum(x.get("T_mg_on_ns"))
            out[k + ("cdiff",)] = fnum(x.get("C_diff_ns"))
    return out


def compare(W, n, E, mixes, skip):
    """Separate vs continuous (user decision 2026-10-18; packet §3.4). hw/pop: r1 = separate fixed lifetime, r2/r3 =
    continuous (SLO -> settle -> L2 -> L1); mg is continuous in every round, so its round-to-round T change is the
    run-to-run spread s_mg = |T_mg(n) - T_mg(1)| / T_mg(1) (round 3: max over r1->r3 and r2->r3; hw/pop r2->r3 change
    adds to the spread). REPORT when, per mix x load x op,
      hw or pop:  |T(n) - T(1)| / T(1) > max(5 %, 2 x spread)
      C_diff:     |C_diff(n) - C_diff(1)| > max(10 % x |C_diff(1)|, 2 x |dT_mg|), |dT_mg| = |T_mg(n) - T_mg(1)|
                  (round 3: max with |T_mg(3) - T_mg(2)|)
    (C_diff = T(mgoff) - T(hw): its hw term changes lifetime type between r1 and r2/r3)."""
    for m in mixes:
        if skip:
            res("W", f"C1 {m} separate vs continuous", False, "skipped (--skip-fig2, self-test only)")
            continue
        t1, tn = fig2_t(E, W, 1, m), fig2_t(E, W, n, m)
        t2 = fig2_t(E, W, 2, m) if n == 3 else None
        if t1 is None or tn is None:
            res("F", f"C1 {m} separate vs continuous", False, f"Fig 2 CSV missing (r1 {t1 is not None}, r{n} {tn is not None})")
            continue
        for (load, op) in sorted({(l, o) for l, o, _ in tn}):
            g = lambda t, k: (t or {}).get((load, op, k))
            mg1, mgn = g(t1, "mg"), g(tn, "mg")
            if not (mg1 and mgn):
                res("F", f"C1 {m} {load}/{op} spread", False, f"T_mg_on r1 {mg1} r{n} {mgn}")
                continue
            spread = abs(mgn - mg1) / mg1
            if t2 and g(t2, "mg"):
                spread = max(spread, abs(mgn - g(t2, "mg")) / g(t2, "mg"))
            for k in ("hw", "pop"):
                a1, an = g(t1, k), g(tn, k)
                if not (a1 and an):
                    res("F", f"C1 {m} {load}/{op} {k}", False, f"T r1 {a1} r{n} {an}")
                    continue
                sp = spread
                if t2 and g(t2, k):  # both continuous: r2 -> r3 change of the system itself
                    sp = max(sp, abs(an - g(t2, k)) / g(t2, k))
                d, thr = abs(an - a1) / a1, max(0.05, 2 * sp)
                res("R", f"C1 {m} {load}/{op} {k} T r1-sep vs r{n}-cont", d <= thr,
                    f"|dT|/T {d:.3f} > threshold {thr:.3f} (5 % or 2 x spread {sp:.3f}); T r1 {a1:g} r{n} {an:g} ns")
            c1, cn = g(t1, "cdiff"), g(tn, "cdiff")
            dmg = abs(mgn - mg1)
            if t2 and g(t2, "mg"):  # r3: the r2 -> r3 change of mg is run-to-run spread too (verifier LOW-1)
                dmg = max(dmg, abs(mgn - g(t2, "mg")))
            if c1 is not None and cn is not None:
                thr = max(0.10 * abs(c1), 2 * dmg)
                res("R", f"C2 {m} {load}/{op} C_diff r1 vs r{n}", abs(cn - c1) <= thr,
                    f"|dC_diff| {abs(cn - c1):g} > threshold {thr:g} ns (C_diff r1 {c1:g}, r{n} {cn:g})")


def confirm_x(rd):
    s = js(os.path.join(rd, "loadgen", "summary.json")) or {}
    return s.get("confirm", {}).get("x_mean")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--workload", required=True)
    ap.add_argument("--round", required=True, type=int)
    ap.add_argument("--skip-fig2", action="store_true", help="Host self-test only (stub data has no stats): F5 -> WARN")
    ap.add_argument("E")
    a = ap.parse_args()
    W, n, E = a.workload, a.round, a.E
    S = os.path.join(E, W, f"r{n}")
    mixes = plan_mixes(a.plan, W)
    rs = {}
    allr = runs(os.path.join(S, "run"))  # H1-HOOK v2: one block dir per workload and round
    for ph in ("slo", "fix"):
        # expected lifetime labels (user decision 2026-10-18): r1 hw/pop SLO-only and separate fixed lifetimes, mg
        # continuous; r2/r3 all continuous; mgoff always its own lifetime ("sep")
        want = {}
        for m in mixes:
            for x in (FIXSYS if ph == "fix" else SYSTEMS):
                want[(m, x)] = "sep" if x == "mgoff" or (n == 1 and x in ("hw", "pop")) else "cont"
        r = [x for x in (allr or []) if x["phase"] == ph]
        ok = allr is not None and {(x["mix"], x["sys"]) for x in r} == set(want) and len(r) == len(want) \
            and all(x["round"] == str(n) and x["life"] == want[(x["mix"], x["sys"])] for x in r)
        res("F", f"F1 {ph} runs complete", ok, f"{sorted((x['mix'], x['sys'], x['life']) for x in r)} vs {len(want)} expected")
        rs[ph] = r
    xs = {}
    for r in rs["slo"]:
        s = js(os.path.join(r["dir"], "loadgen", "summary.json")) or {}
        st = jl(os.path.join(r["dir"], "loadgen", "steps.jsonl")) or []
        c = s.get("confirm", {})
        so = s.get("slo", {})
        try:
            slo_ok = f"{so['stream']}:{float(so['pct']):g}:{float(so['ms']):g}" == \
                ":".join([mixes[r["mix"]].split(":")[0]] + [f"{float(v):g}" for v in mixes[r["mix"]].split(":")[1:]])
        except (KeyError, TypeError, ValueError):
            slo_ok = False
        ph = [x.get("phase") for x in st]
        npass = sum(1 for x in st if x.get("phase") in ("ramp", "bisect", "fill") and x.get("pass"))
        errs = []
        if s.get("note"):
            errs.append(f"note '{s['note']}' (Q4: stop this workload and ask)")
        if s.get("workload_finish") != "ok":
            errs.append(f"workload_finish {s.get('workload_finish')}")
        if not slo_ok:
            errs.append(f"SLO {so} != plan {mixes[r['mix']]}")
        if c.get("reps") != 3 or not (c.get("x_mean") or 0) > 0:
            errs.append(f"confirm {c}")
        if "fill" not in ph or "overload" not in ph:
            errs.append("no fill/overload steps")
        if "fixed" in ph:
            errs.append("fixed steps inside the SLO part (contract: one loadgen part per phase)")
        if npass < 3:
            errs.append(f"{npass} passing curve steps")
        res("F", f"F2 {r['name']}", not errs, "; ".join(errs))
        if c.get("x_mean"):
            xs[(r["mix"], r["sys"])] = float(c["x_mean"])
            sd = float(c.get("x_sd") or 0)
            res("W", f"W2 {r['name']} confirm spread", sd / float(c["x_mean"]) <= 0.05 and not c.get("fails"),
                f"x_sd/x_mean {sd / float(c['x_mean']):.3f}, confirm fails {c.get('fails')}")
    idx = {x["name"]: x for x in (rows(os.path.join(S, "collect", "runs-index.csv")) or [])}
    for r in rs["slo"] + rs["fix"]:
        rc_ok = False
        for rc in (os.path.join(r["dir"], "h1-runcheck.txt"), os.path.join(os.path.dirname(r["dir"]), "h1-runcheck.txt")):
            try:  # the part dir, else its lifetime dir
                rc_ok = open(rc).read().rstrip().splitlines()[-1].startswith("RUNCHECK PASS")
                break
            except (OSError, IndexError):
                continue
        k = idx.get(r["name"], {}).get("kernel_node0", "")
        errs = [] if rc_ok else ["h1-runcheck.txt not RUNCHECK PASS"]
        if not any(os.path.isfile(os.path.join(x, SPLIT[W])) for x in (r["dir"], os.path.dirname(r["dir"]))):
            errs.append(f"no {SPLIT[W]}")
        if not k.endswith("-ds-popcorn-new-12"):
            errs.append(f"kernel_node0 '{k}'")
        res("F", f"F3 {r['name']}", not errs, "; ".join(errs))
    fx = rows(os.path.join(S, "collect", "fix-steps.csv")) or []
    for m in mixes:
        got = sorted((x["level"], x["system"]) for x in fx if x["mix"] == m)
        res("F", f"F4 {m} fixed windows", got == sorted((l, s) for l in ("L1", "L2") for s in FIXSYS), f"{got}")
        f2 = fig2_rows(os.path.join(S, "collect", "fig", f"{W}-{m}-fig2.csv"))
        if a.skip_fig2:
            res("W", f"F5 {m} Fig 2", False, "skipped (--skip-fig2, self-test only)")
        elif f2 is None:
            res("F", f"F5 {m} Fig 2 CSV", False, "missing")
        else:
            errs, popc, mgrows = [], 0.0, []
            for x in f2:  # v6_fig2_split.py --megalon-c diff rows: All HWcc, Popcorn, Megalon (timers off)
                T, C, lab, where = fnum(x.get("T_ns")), fnum(x.get("C_ns")), x["system"], f"{x.get('load')}/{x.get('op')}"
                if T is None or C is None:
                    errs.append(f"{where}/{lab} C {C} T {T}")
                elif lab == "All HWcc":
                    if C != 0:
                        errs.append(f"all-HWcc C {C} ({where})")
                elif lab == "Megalon (timers off)":  # sampled C of the timers-on run: missing or 0 = FAIL, > T = WARN
                    mgrows.append(x)
                    cs, ton = fnum(x.get("C_sampled_ns")), fnum(x.get("T_mg_on_ns"))
                    if cs is None or not cs > 0:
                        errs.append(f"Megalon sampled C {cs} ({where})")
                    else:
                        res("W", f"W5 {m} {where} Megalon sampled C <= T", ton is not None and cs <= ton, f"C_sampled {cs} > T_mg_on {ton}")
                elif lab == "Popcorn":
                    if C < 0 or C > T:
                        errs.append(f"Popcorn C {C} T {T} ({where})")
                    else:
                        popc += C
                else:
                    errs.append(f"unexpected system row '{lab}' ({where})")
            if not popc > 0:
                errs.append("Popcorn C summed over ops and loads = 0")
            res("F", f"F5 {m} Fig 2 C/T", not errs and len(f2) > 0, "; ".join(errs[:5]) or "no rows")
        if a.skip_fig2:
            res("W", f"F9 {m} C_diff", False, "skipped (--skip-fig2, self-test only)")
        elif f2 is not None:  # Fig 2 Megalon C = C_diff_ns of the "Megalon (timers off)" rows (dec 2026-10-17 "(a)")
            miss = [f"{x['load']}/{x['op']}" for x in mgrows
                    if fnum(x.get("C_diff_ns")) is None or fnum(x.get("C_diff_ns")) != fnum(x.get("C_ns"))
                    or not x.get("C_method", "").startswith("diff")]
            ops = {(x["load"], x["op"]) for x in f2 if x["system"] == "All HWcc"}
            res("F", f"F9 {m} C_diff present", mgrows and not miss and {(x["load"], x["op"]) for x in mgrows} == ops
                and {l for l, _ in ops} == {"L1", "L2"}, f"{len(mgrows)} Megalon rows for {len(ops)} load x op, bad {miss[:4]}")
            pt = {(x["load"], x["op"]): x for x in f2 if x["system"] == "Popcorn"}
            for x in mgrows:
                v, k = fnum(x.get("C_diff_ns")), (x["load"], x["op"])
                if v is not None:
                    res("W", f"W6 {m} {k[0]}/{k[1]} C_diff >= 0", v >= 0,
                        f"C_diff {v} (T_mg_off {x['T_ns']} - T_hw {x.get('hw_T_ns')}); Popcorn T(pop)-T(hw) "
                        f"{pt.get(k, {}).get('pop_T_minus_hw_ns')} vs C_pop {pt.get(k, {}).get('C_ns')}; warn '{x.get('warn', '')}'")
        for x in fx:
            if x["mix"] != m:
                continue
            if x["system"] in ("pop", "mg", "mgoff"):
                ok = fnum(x["coh_cpu_vcpus"]) is not None and (x["system"] != "pop" or (fnum(x["recv_cpu_s"]) or 0) > 0)
                res("F", f"F6 {m} {x['system']} {x['level']} coherence CPU", ok,
                    f"coh_cpu_vcpus '{x['coh_cpu_vcpus']}' recv_cpu_s '{x['recv_cpu_s']}'")
            ach, off = fnum(x.get("achieved_total")), fnum(x["offered_x"])  # offered_x = total rate argument
            res("W", f"W3 {m} {x['system']} {x['level']} window", ach is not None and off and ach / off >= 0.95
                and x["pass"] == "True", f"achieved {ach} / offered {off}, pass {x['pass']}")
        if all((m, s) in xs for s in SYSTEMS):
            res("W", f"W1 {m} all-HWcc highest", xs[(m, "hw")] >= 0.98 * max(xs[(m, "pop")], xs[(m, "mg")]),
                f"x hw {xs[(m, 'hw')]:g} pop {xs[(m, 'pop')]:g} mg {xs[(m, 'mg')]:g}")
    try:
        bad = [l for l in open(os.path.join(S, "collect", "notes.txt"))
               if any(t in l for t in ("no overload step", "fig1", "fig2", "export_csv"))
               and not (a.skip_fig2 and ("fig1" in l or "fig2" in l))]
    except OSError:
        bad = ["notes.txt missing"]
    res("F", "F7 collect notes", not bad, "; ".join(l.strip() for l in bad[:3]))
    lv = {x["mix"]: x for x in (csv.DictReader(open(os.path.join(E, W, "levels.tsv")), delimiter="\t")
                                if os.path.isfile(os.path.join(E, W, "levels.tsv")) else [])}
    for m in mixes:
        if not all((m, s) in xs for s in SYSTEMS):
            continue
        weakest = min(SYSTEMS, key=lambda s: xs[(m, s)])
        if n == 1:
            res("F", f"F8 {m} levels weakest", lv.get(m, {}).get("weakest") == weakest,
                f"levels.tsv {lv.get(m, {}).get('weakest')} vs round {weakest}")
        else:
            res("W", f"W4 {m} weakest vs r1 levels", lv.get(m, {}).get("weakest") == weakest,
                f"levels.tsv {lv.get(m, {}).get('weakest')} vs round {n} {weakest}")
            for s in SYSTEMS:
                r1 = next((x["dir"] for x in (runs(os.path.join(E, W, "r1", "run")) or [])
                           if x["mix"] == m and x["sys"] == s and x["phase"] == "slo"), "")
                x1 = confirm_x(r1) if r1 else None
                res("W", f"W4 {m} {s} x vs r1", x1 and abs(xs[(m, s)] / float(x1) - 1) <= 0.10,
                    f"r{n} {xs[(m, s)]:g} vs r1 {x1}")
    if n > 1:
        compare(W, n, E, mixes, a.skip_fig2)
    verdict = f"H1CHECK {'FAIL' if nfail else 'PASS'} {W} r{n}: {nfail} FAIL, {nwarn} WARN, {nrep} REPORT"
    with open(os.path.join(S, "check.txt"), "w") as f:
        f.write("\n".join(lines + [verdict]) + "\n")
    print("\n".join(l for l in lines if not l.startswith("OK")))
    print(verdict)
    sys.exit(1 if nfail else 0)


if __name__ == "__main__":
    main()

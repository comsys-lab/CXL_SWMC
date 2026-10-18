#!/usr/bin/env python3
"""MOT1 v6 Fig 2 (H1): processing time per operation, coherence management vs the rest, per system x operation type,
at each measurement load (reports/MOT1-v6-redesign-draft.md §3).

  T_o   = (1/N_o) sum_ops sum_threads (end - start)            = t_ns / ops            (ops, t_ns summed over nodes)
  C_o   = (1/N_o) sum_ops sum_threads delta C                  = C / ops
          C: Popcorn  pop_is_ns + pop_sm_ns + pop_wp_ns + pop_ipi_ns (swmc_acct, kernel clock)
             Megalon  C_check + vcopy_ns_sampled x vcopy_cnt / vcopy_sampled + stale + concur + meta + spin + C_wstart + wflush (CohSnap); C_check
             and C_wstart by workload (v6_common.MEG_RULE): KV check_est - seqlock reads, wstart - wseq, wflush - wseq_end (all-HWcc =
             Megalon hwcc flavor); vector DB / LMDB / DLRM check_est + read anchor, wstart + write anchor (all-HWcc =
             plain backend); check_est = check_ns_sampled x read_sections / check_sampled
             all-HWcc 0 (no coherence actions)
  Rest  = T_o - C_o
  Bars normalized to all-HWcc T_o of the same operation and load: part / T_o(hw, o, load)
Loads (user decision 2026-10-16, draft §3): all three systems at the SAME offered rate, two rates:
  L1 = the weakest system's max throughput under SLO (primary), L2 = 0.5 x L1. No "own max" point.
Each of L1 and L2 needs hw, pop and mg runs; a load whose runs' offered rates (mean offered_x of the selected steps)
differ by more than 1% (max/min > 1.01) is refused. The CSV states the offered rates and L2/L1.

Megalon C method (--megalon-c; user decision 2026-10-17, state/TASKS.md "(a) 차분 방식으로 진행해"):
  diff (default)  C_meg(o) = C_diff = T_o(Megalon timers OFF) - T_o(all-HWcc): an UPPER BOUND (includes every other
                  backend difference), negative values reported with a WARN (no clamp). Each load needs a fourth run
                  mgoff = the Megalon timers-off fixed lifetime (MEGALON_COH_TIMERS=0; checked: every Megalon timed sum
                  0); missing -> refused (no fallback). The Megalon bar is the timers-off run: T = T(mgoff), C =
                  C_diff, rest = T - C_diff. The timers-ON mg run gives the sampled-scaled terms, kept raw and used
                  only to split C_diff (part_i = C_diff x sampled_i / sum sampled), and T(mg on) for the timer
                  overhead. Popcorn C from kernel counters as above, T(pop) - T(hw) as a cross-check column. Same
                  offered rate (1%), same measure window length, same mix (loadgen mix.*) and workload per load.
  sampled         the previous definition (sampled-scaled C of the mg run; no mgoff); output identical to before.
  none            no Megalon (H1 v0.6.7, user decision 2026-10-18: RecSys measures all-HWcc and Popcorn only): each load
                  needs exactly hw and pop (mg / mgoff refused); rows All HWcc and Popcorn as in "sampled"; a CSV meta
                  line "megalon_c" states it, with --megalon-note (where the Megalon numbers are).

usage: v6_fig2_split.py --out DIR --tag kv-ycsb-b {L1|L2}:SYS=DIR[:STEPS] ...   SYS in hw, pop, mg, mgoff
       e.g. L1:hw=R/hw:2 L1:pop=R/pop:2 L1:mg=R/mg:2 L1:mgoff=R/mg-t0:2 L2:hw=R/hw:1 ... L2:mgoff=R/mg-t0:1
       v6_fig2_split.py --megalon-c sampled ... (no mgoff runs)
       v6_fig2_split.py --megalon-c none [--megalon-note TEXT] ... L1:hw=.. L1:pop=.. L2:hw=.. L2:pop=..
One PNG per load (<tag>-fig2-<load>.png) and one CSV for all loads (<tag>-fig2.csv).
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

COMPONENTS = ["Coherence management", "Rest"]  # legend top -> bottom
SHORT = {"hw": "All HWcc", "pop": "Popcorn", "mg": "Megalon"}
LOADS = ("L1", "L2")
RATE_TOL = 1.01


def offered(run, steps):
    o = [s["offered_x"] for s in run.measured() if s["step"] in steps]
    return sum(o) / len(o)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="LOAD:SYS=DIR[:STEPS]")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--ops", help="operation order (default: discovered, sorted)")
    ap.add_argument("--megalon-c", choices=("diff", "sampled", "none"), default="diff",
                    help="Megalon C: diff = T(mg timers off) - T(hw) (default, needs mgoff runs); sampled = old path; "
                         "none = no Megalon runs (hw and pop only)")
    ap.add_argument("--megalon-note", default="", help="--megalon-c none: where the Megalon numbers come from (CSV meta)")
    a = ap.parse_args()
    if a.megalon_c == "diff":
        return main_diff(a)
    loads = {}
    for spec in a.runs:
        load, sep, rest = spec.partition(":")
        if not sep or load not in LOADS:
            sys.exit(f"bad spec {spec!r}: {{L1|L2}}:SYS=DIR[:STEPS]")
        k, d, steps = v6.parse_spec(rest)
        run = v6.Run(d, k)
        loads.setdefault(load, {})[k] = (run, run.select(steps))
    rates = {}
    for load, ent in loads.items():
        need = ("hw", "pop") if a.megalon_c == "none" else ("hw", "pop", "mg")
        miss = [k for k in need if k not in ent]
        if miss:
            sys.exit(f"load {load}: missing runs for {miss} (each load needs {', '.join(need)} at the same rate)")
        if a.megalon_c == "none" and set(ent) != set(need):
            sys.exit(f"load {load}: --megalon-c none takes hw and pop only, got {sorted(ent)}")
        rates[load] = {k: offered(r, st) for k, (r, st) in ent.items()}
        lo, hi = min(rates[load].values()), max(rates[load].values())
        if hi > lo * RATE_TOL:
            sys.exit(f"load {load}: offered rates differ by more than 1%: {rates[load]} (refused)")
    os.makedirs(a.out, exist_ok=True)
    rows, used_all, lean = [], {}, []
    for load in [l for l in LOADS if l in loads]:
        ent = loads[load]
        ops = a.ops.split(",") if a.ops else sorted(set().union(*[set(r.ops(s)) for r, s in ent.values()]))
        S = {}
        for k, (run, steps) in ent.items():
            for op in ops:
                s, used, nodes = v6.op_sums(run, steps, op)
                for c, key in used.items():
                    used_all.setdefault(c, set()).add(key)
                S[(k, op)] = (s, nodes)
                if s["meg_lean_nodes"] or s["lean_est_missing_nodes"]:
                    lean.append(f"{load}:{k}:{op} lean_nodes={s['meg_lean_nodes']} events_always_nodes="
                                f"{s['meg_events_always_nodes']} lean_est_missing_nodes={s['lean_est_missing_nodes']}")
        groups = []
        for op in ops:
            hs, _ = S[("hw", op)]
            base = v6.div(hs["t_ns"], hs["ops"])
            bars = []
            for k in ["hw", "mg", "pop"]:
                if k not in ent:
                    continue
                s, nodes = S[(k, op)]
                run, steps = ent[k]
                T, C = v6.div(s["t_ns"], s["ops"]), v6.div(s["C"], s["ops"])
                rest = None if T is None else T - C
                nC, nR = v6.div(C, base), v6.div(rest, base)
                bars.append((SHORT[k], [nC, nR] if T is not None else None))
                cexp = v6.div(s.get("c_ns_exported"), s["ops"])
                rows.append([load, op, v6.SYSTEMS[k], v6.r(rates[load][k], 2), ",".join(map(str, steps)), nodes, s["ops"], v6.r(T, 1), v6.r(C, 1),
                             v6.r(rest, 1), v6.r(base, 1), v6.r(nC), v6.r(nR), v6.r(v6.div(T, base)), v6.r(cexp, 1),
                             v6.r(v6.div(s["C_pop"], s["ops"]), 1), v6.r(v6.div(s["C_meg"], s["ops"]), 1),
                             s["check_est_missing_nodes"], s["vcopy_est_missing_nodes"], s["anchor_split_unavailable_nodes"],
                             s["meg_rule"] if k == "mg" else "",
                             v6.r(v6.div(s["pop_nontrans_ns"], s["ops"]), 1) if "pop_nontrans_ns" in s else "", run.path])
            groups.append((op, bars))
        png = os.path.join(a.out, f"{a.tag}-fig2-{load}.png")
        v6.stacked(png, groups, COMPONENTS, "Normalized time\nper operation")
        print(f"-> {png}")
    csvp = os.path.join(a.out, f"{a.tag}-fig2.csv")
    # Megalon >= 76 lean sampling: stated only when present, so outputs of older data stay byte-identical
    lean_meta = [("megalon_lean", "Megalon >= 76 timed-section sums scaled per node before C (v6_common LEAN_*): "
                  "stale/concur/meta/spin x read_sections/check_sampled, wstart/wflush/anchor write_lookup/write_nr/"
                  "wseq/wseq_end x write_sections/anchor.write_sampled (no scaling with events_always; no probe "
                  "correction); so those Megalon C terms are sampled estimates, not measured sums: " + "; ".join(lean))] \
        if lean else []
    none_meta = [("megalon_c", "none: no Megalon runs for this figure (all-HWcc and Popcorn only)"
                   + (f"; {a.megalon_note}" if a.megalon_note else ""))] if a.megalon_c == "none" else []
    v6.write_csv(csvp, none_meta + lean_meta + [
        ("figure", f"MOT1 v6 Fig 2 coherence management vs rest per operation ({a.tag}); PNGs {a.tag}-fig2-<load>.png"),
        ("formula", "T_o = t_ns / ops; C_o = C / ops with C = pop_is_ns+pop_sm_ns+pop_wp_ns+pop_ipi_ns (Popcorn) | "
                    "meg_check_C_ns+meg_vcopy_ns_sampled*meg_vcopy_cnt/"
                    "meg_vcopy_sampled (per node)+meg_stale_ns+meg_concur_ns+meg_meta_ns+meg_spin_ns+meg_wstart_C_ns"
                    "+meg_wflush_C_ns (Megalon; meg_check_C_ns / meg_wstart_C_ns by workload rule, column meg_rule: "
                    "hwcc_flavor = check_est - rseq_est, wstart - wseq, wflush - wseq_end; plain = check_est + anchor read est, wstart + "
                    "anchor write; check_est = check_ns_sampled*read_sections/check_sampled) | 0 (all-HWcc); rest = T_o - C_o; norm_* = part / T_o(all-HWcc, same op, "
                    "same load); sums over the listed steps and all nodes"),
        ("sources", "stats/ snapshot deltas (loadgen --stats-op, stats_delta.py): " + "; ".join(
            f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "ops count measured; T_ns measured (rdtsc); C_ns derived from measured kernel/CohSnap durations, "
                 "Megalon check part sampled (ratio estimate); rest_ns, norm_* derived; c_exported_ns = the workload's own c_ns "
                 "(audit, must equal C_ns for pop/mg); nontrans_ns_not_in_C = Popcorn managed faults without a transition per op (own component, not in C; empty until a workload exports it)"),
        ("loads", "; ".join(f"{l}: offered " + ", ".join(f"{k}={v:g}" for k, v in rates[l].items()) for l in rates)
                  + (f"; L2/L1 = {min(rates['L2'].values()) / min(rates['L1'].values()):.3f} (decision: 0.5)"
                     if "L1" in rates and "L2" in rates else "")),
        ("inputs", "; ".join(f"{l}:{k} {r.path} steps {s}" for l, e in loads.items() for k, (r, s) in e.items())),
    ], ["load", "op", "system", "offered", "steps", "node_windows", "ops", "T_ns", "C_ns", "rest_ns", "hw_T_ns", "norm_C",
        "norm_rest", "norm_T", "c_exported_ns", "C_pop_ns", "C_meg_ns", "check_est_missing_nodes", "vcopy_est_missing_nodes",
        "anchor_split_unavailable_nodes", "meg_rule", "nontrans_ns_not_in_C", "run"], rows)
    print(f"-> {csvp}")


DIFF_SYS = {"hw": "hw", "pop": "pop", "mg": "mg", "mgoff": "mg"}  # spec key -> v6 system (formula, source check)


def same_window(load, ent):
    """Refuse a load whose runs differ in workload, mix (loadgen mix.* keys) or measure window length."""
    def mix(r):
        return {k: v for k, v in r.manifest.items() if k.startswith("mix.")}
    ref_k, (ref, ref_st) = next(iter(ent.items()))
    for k, (r, st) in ent.items():
        if r.workload != ref.workload or mix(r) != mix(ref):
            sys.exit(f"load {load}: {k} workload/mix {r.workload} {mix(r)} != {ref_k} {ref.workload} {mix(ref)} (refused)")
        win = sorted(x["measure_s"] for x in r.measured() if x["step"] in st)
        rwin = sorted(x["measure_s"] for x in ref.measured() if x["step"] in ref_st)
        if win != rwin:
            sys.exit(f"load {load}: {k} measure windows {win} s != {ref_k} {rwin} s (refused: same window definition)")


def main_diff(a):
    loads = {}
    for spec in a.runs:
        load, sep, rest = spec.partition(":")
        if not sep or load not in LOADS:
            sys.exit(f"bad spec {spec!r}: {{L1|L2}}:SYS=DIR[:STEPS]")
        k, d, steps = v6.parse_spec(rest, allowed=DIFF_SYS)
        run = v6.Run(d, DIFF_SYS[k])
        loads.setdefault(load, {})[k] = (run, run.select(steps))
    rates = {}
    for load, ent in loads.items():
        miss = [k for k in ("hw", "pop", "mg", "mgoff") if k not in ent]
        if miss:
            sys.exit(f"load {load}: missing runs for {miss} (--megalon-c diff needs hw, pop, mg and mgoff = Megalon "
                     "timers-off lifetime at the same rate; no fallback; --megalon-c sampled = old definition)")
        rates[load] = {k: offered(r, st) for k, (r, st) in ent.items()}
        lo, hi = min(rates[load].values()), max(rates[load].values())
        if hi > lo * RATE_TOL:
            sys.exit(f"load {load}: offered rates differ by more than 1%: {rates[load]} (refused)")
        same_window(load, ent)
    os.makedirs(a.out, exist_ok=True)
    rows, used_all, lean, warns = [], {}, [], []
    parts = [p for p, _ in v6.MEG_PARTS]
    for load in [l for l in LOADS if l in loads]:
        ent = loads[load]
        ops = a.ops.split(",") if a.ops else sorted(set().union(*[set(r.ops(s)) for r, s in ent.values()]))
        off_run, off_steps = ent["mgoff"]
        v6.check_timers_off(off_run, off_steps, ops)
        S = {}
        for k, (run, steps) in ent.items():
            for op in ops:
                s, used, nodes = v6.op_sums(run, steps, op)
                for c, key in used.items():
                    used_all.setdefault(c, set()).add(key)
                S[(k, op)] = (s, nodes)
                if k == "mg" and (s["meg_lean_nodes"] or s["lean_est_missing_nodes"]):
                    lean.append(f"{load}:{k}:{op} lean_nodes={s['meg_lean_nodes']} events_always_nodes="
                                f"{s['meg_events_always_nodes']} lean_est_missing_nodes={s['lean_est_missing_nodes']}")
        groups = []
        for op in ops:
            hs, _ = S[("hw", op)]
            base = v6.div(hs["t_ns"], hs["ops"])
            T_on = v6.div(S[("mg", op)][0]["t_ns"], S[("mg", op)][0]["ops"])
            T_off = v6.div(S[("mgoff", op)][0]["t_ns"], S[("mgoff", op)][0]["ops"])
            T_pop = v6.div(S[("pop", op)][0]["t_ns"], S[("pop", op)][0]["ops"])
            md = v6.meg_diff(T_off, base, S[("mg", op)][0]) if T_off is not None and base is not None else None
            for w in (md or {}).get("warn", []):
                warns.append(f"{load}:{op}: {w}")
                print(f"WARN {load} {op}: {w}", file=sys.stderr)
            bars = []
            for k in ["hw", "mg", "pop"]:
                src = "mgoff" if k == "mg" else k
                s, nodes = S[(src, op)]
                run, steps = ent[src]
                T = v6.div(s["t_ns"], s["ops"])
                C = (md["C_diff"] if md else None) if k == "mg" else v6.div(s["C"], s["ops"])
                rest = None if T is None or C is None else T - C
                nC, nR = v6.div(C, base), v6.div(rest, base)
                bars.append((SHORT[k] + ("*" if k == "mg" else ""), [nC, nR] if T is not None and C is not None else None))
                cexp = v6.div(s.get("c_ns_exported"), s["ops"])
                son = S[("mg", op)][0]
                mgcols = ([v6.r(T_on, 1), v6.r(v6.div(son["C_meg"], son["ops"]), 1), v6.r(md["sampled_sum"], 1) if md else ""]
                          + [v6.r(md["part_" + p], 1) if md else "" for p in parts]
                          + [v6.r(md["sampled_" + p], 1) if md else "" for p in parts]
                          + [ent["mg"][0].path]) if k == "mg" else [""] * (3 + 2 * len(parts) + 1)
                label = "Megalon (timers off)" if k == "mg" else v6.SYSTEMS[k]  # H1 collect.py: "Megalon" + "off"
                rows.append([load, op, label, v6.r(rates[load][src], 2), ",".join(map(str, steps)), nodes,
                             s["ops"], v6.r(T, 1), v6.r(C, 1), v6.r(rest, 1), v6.r(base, 1), v6.r(nC), v6.r(nR),
                             v6.r(v6.div(T, base)), "diff (upper bound)" if k == "mg" else ("kernel counters" if k == "pop" else "0"),
                             v6.r(md["C_diff"], 1) if k == "mg" and md else "",
                             v6.r(cexp, 1), v6.r(v6.div(s["C_pop"], s["ops"]), 1),
                             v6.r(T_pop - base, 1) if k == "pop" and T_pop is not None and base is not None else ""]
                            + mgcols + [s["check_est_missing_nodes"], s["vcopy_est_missing_nodes"],
                                        s["anchor_split_unavailable_nodes"], s["meg_rule"] if k == "mg" else "",
                                        v6.r(v6.div(s["pop_nontrans_ns"], s["ops"]), 1) if "pop_nontrans_ns" in s else "",
                                        "; ".join(md["warn"]) if k == "mg" and md else "", run.path])
            groups.append((op, bars))
        png = os.path.join(a.out, f"{a.tag}-fig2-{load}.png")
        v6.stacked(png, groups, COMPONENTS, "Normalized time\nper operation",
                   title="Megalon*: C = T(Megalon, timers off) - T(All HWcc), an upper bound")
        print(f"-> {png}")
    csvp = os.path.join(a.out, f"{a.tag}-fig2.csv")
    lean_meta = [("megalon_lean", "timers-on mg run: Megalon >= 76 timed-section sums scaled per node (v6_common LEAN_*) "
                  "before the sampled terms used for the split: " + "; ".join(lean))] if lean else []
    v6.write_csv(csvp, lean_meta + [
        ("figure", f"MOT1 v6 Fig 2 coherence management vs rest per operation ({a.tag}); PNGs {a.tag}-fig2-<load>.png"),
        ("megalon_c", "UPPER BOUND: Megalon C = C_diff = T_o(Megalon timers off, run mgoff) - T_o(all-HWcc), per op, same "
                      "offered rate, mix and window (user decision 2026-10-17, state/TASKS.md); includes every other "
                      "backend difference; C_diff < 0 reported as is (WARN, no clamp). The Megalon row (system "
                      "'Megalon (timers off)') has T/C/rest of the timers-off run and C_ns = C_diff_ns; the timers-on run (mg_on_run) gives T_mg_on_ns (timer overhead) and the sampled-"
                      "scaled terms sampled_<p>_ns (raw diagnostics), used only to split C_diff: part_<p>_ns = C_diff x "
                      "sampled_<p> / sampled_sum"),
        ("formula", "T_o = t_ns / ops; C_o = pop_is_ns+pop_sm_ns+pop_wp_ns+pop_ipi_ns (Popcorn, kernel counters) | C_diff "
                    "(Megalon) | 0 (all-HWcc); rest = T_o - C_o; norm_* = part / T_o(all-HWcc, same op, same load); "
                    "pop_T_minus_hw_ns = T_o(Popcorn) - T_o(all-HWcc) (cross-check of Popcorn C); sampled terms: "
                    "v6_common.op_sums C_meg terms (check = meg_check_C_ns by workload rule, vcopy, stale, concur, meta, "
                    "spin, wstart = meg_wstart_C_ns, wflush = meg_wflush_C_ns) per op; sums over the listed steps and all nodes"),
        ("sources", "stats/ snapshot deltas (loadgen --stats-op, stats_delta.py): " + "; ".join(
            f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "ops count measured; T_ns measured (rdtsc); C_ns: Megalon derived (difference of measured T, upper "
                 "bound), Popcorn measured kernel durations; part_* derived; sampled_* sampled (ratio estimates); "
                 "rest_ns, norm_* derived; c_exported_ns = the workload's own c_ns (audit)"),
        ("warnings", "; ".join(warns) if warns else "none"),
        ("loads", "; ".join(f"{l}: offered " + ", ".join(f"{k}={v:g}" for k, v in rates[l].items()) for l in rates)
                  + (f"; L2/L1 = {min(rates['L2'].values()) / min(rates['L1'].values()):.3f} (decision: 0.5)"
                     if "L1" in rates and "L2" in rates else "")),
        ("inputs", "; ".join(f"{l}:{k} {r.path} steps {s}" for l, e in loads.items() for k, (r, s) in e.items())),
    ], ["load", "op", "system", "offered", "steps", "node_windows", "ops", "T_ns", "C_ns", "rest_ns", "hw_T_ns", "norm_C",
        "norm_rest", "norm_T", "C_method", "C_diff_ns", "c_exported_ns", "C_pop_ns", "pop_T_minus_hw_ns", "T_mg_on_ns",
        "C_sampled_ns", "sampled_sum_ns"] + [f"part_{p}_ns" for p in parts] + [f"sampled_{p}_ns" for p in parts]
       + ["mg_on_run", "check_est_missing_nodes", "vcopy_est_missing_nodes", "anchor_split_unavailable_nodes", "meg_rule",
          "nontrans_ns_not_in_C", "warn", "run"], rows)
    print(f"-> {csvp}")


if __name__ == "__main__":
    main()

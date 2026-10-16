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

usage: v6_fig2_split.py --out DIR --tag kv-ycsb-b {L1|L2}:SYS=DIR[:STEPS] ...
       e.g. L1:hw=R/hw-L1 L1:pop=R/pop-L1 L1:mg=R/mg-L1 L2:hw=R/hw-L2 L2:pop=R/pop-L2 L2:mg=R/mg-L2
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
    a = ap.parse_args()
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
        miss = [k for k in ("hw", "pop", "mg") if k not in ent]
        if miss:
            sys.exit(f"load {load}: missing runs for {miss} (each load needs hw, pop and mg at the same rate)")
        rates[load] = {k: offered(r, st) for k, (r, st) in ent.items()}
        lo, hi = min(rates[load].values()), max(rates[load].values())
        if hi > lo * RATE_TOL:
            sys.exit(f"load {load}: offered rates differ by more than 1%: {rates[load]} (refused)")
    os.makedirs(a.out, exist_ok=True)
    rows, used_all = [], {}
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
    v6.write_csv(csvp, [
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


if __name__ == "__main__":
    main()

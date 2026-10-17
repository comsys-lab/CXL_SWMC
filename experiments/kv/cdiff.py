#!/usr/bin/env python3
"""Megalon C by the difference method (user decision 2026-10-17, state/TASKS.md "(a) 차분 방식으로 진행해").

usage: cdiff.py --hw RUN --mgoff RUN [--mg RUN] [--pop RUN] --workload kv|lmdb [--out FILE]
RUN = a run dir with opsplit.csv (experiments/{kv,lmdb}/run.sh). Rows are paired by (step offered rate, op).
  C_diff = T(Megalon, timers OFF) - T(all-HWcc) per operation, same offered rate, mix and window definition.
           An upper bound (includes any other backend difference). C_diff < 0 -> WARN, reported as is (no clamp).
  parts  = C_diff split by the sampled-scaled parts of the timers-ON Megalon run (--mg) at the same rate:
           part_i = C_diff x sampled_i / sum(sampled); the raw sampled parts and C_sampled are printed too
           (diagnostics). kv parts: check-rseq, events (A-D), write; lmdb: check, read_lookup, read_nr, events,
           write, vcopy (the workload's validation copy).
  Popcorn cross-check (--pop): T(Popcorn) - T(all-HWcc) next to the kernel-counter C, where the offered rates match.
Prints one line per pair and "CDIFF DONE pairs=<n> warnings=<w>"; exit 0 unless an input is missing or no pair matches
(exit 2). Never judges magnitudes.
"""
import argparse, csv, os, sys

ap = argparse.ArgumentParser()
ap.add_argument("--hw", required=True)
ap.add_argument("--mgoff", required=True)
ap.add_argument("--mg")
ap.add_argument("--pop")
ap.add_argument("--workload", choices=["kv", "lmdb"], required=True)
ap.add_argument("--out")
a = ap.parse_args()


def load(run):
    p = os.path.join(run, "opsplit.csv")
    if not os.path.exists(p):
        sys.exit(f"cdiff: missing {p}")
    out = {}
    for r in csv.DictReader(open(p)):
        if int(r["ops[measured]"]) > 0:
            out[(r["offered_x"], r["op"])] = r
    return out


f = lambda r, k: float(r.get(k) or 0)
T = lambda r: f(r, "T_us_per_op[measured]")
C = lambda r: f(r, "C_us_per_op[derived]")


def parts(r):
    if a.workload == "kv":
        return {"check": max(0.0, f(r, "meg_check_us_per_op[sampled_xN]") - f(r, "meg_anc_rseq_us_per_op[sampled_xN]")),
                "events": f(r, "meg_events_us_per_op[sampled_xN]"), "write": f(r, "meg_write_us_per_op[sampled_xN]")}
    return {"check": f(r, "meg_check_us_per_op[sampled_xN]"), "read_lookup": f(r, "meg_anc_read_lookup_us_per_op[sampled_xN]"),
            "read_nr": f(r, "meg_anc_read_nr_us_per_op[sampled_xN]"), "events": f(r, "meg_events_us_per_op[sampled_xN]"),
            "write": f(r, "meg_write_us_per_op[sampled_xN]"), "vcopy": f(r, "meg_vcopy_us_per_op[sampled_xN]")}


hw, off = load(a.hw), load(a.mgoff)
mg = load(a.mg) if a.mg else {}
pop = load(a.pop) if a.pop else {}
lines, n, warn = [], 0, 0
keys = sorted(set(hw) & set(off), key=lambda k: (float(k[0] or 0), k[1]))
for k in keys:
    n += 1
    cd = T(off[k]) - T(hw[k])
    s = (f"CDIFF {os.path.basename(a.mgoff.rstrip('/'))} offered={k[0]} op={k[1]} T_hw={T(hw[k]):.4f} "
         f"T_mgoff={T(off[k]):.4f} C_diff={cd:.4f} us")
    if cd < 0:
        warn += 1
        s += " WARN C_diff<0"
    if k in mg:
        ps = parts(mg[k])
        tot = sum(ps.values())
        s += f" | T_mg={T(mg[k]):.4f} C_sampled={C(mg[k]):.4f} sampled/diff={C(mg[k]) / cd:.2f}" if cd else \
             f" | T_mg={T(mg[k]):.4f} C_sampled={C(mg[k]):.4f}"
        s += " split: " + " ".join(f"{p}={cd * v / tot:.4f}" for p, v in ps.items()) if tot else " split: n/a (no sampled parts)"
        s += " raw: " + " ".join(f"{p}={v:.4f}" for p, v in ps.items())
    if k in pop:
        s += f" | pop: T_pop-T_hw={T(pop[k]) - T(hw[k]):.4f} C_pop={C(pop[k]):.4f}"
    lines.append(s)
if not n:
    sys.exit(f"cdiff: no (offered rate, op) pair common to {a.hw} and {a.mgoff}")
lines.append(f"CDIFF DONE pairs={n} warnings={warn}")
txt = "\n".join(lines) + "\n"
if a.out:
    open(a.out, "w").write(txt)
print(txt, end="")

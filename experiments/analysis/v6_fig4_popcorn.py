#!/usr/bin/env python3
"""MOT1 v6 Fig 4 (H3): Popcorn detail, DLRM at the Ekko average and peak update rates
(reports/MOT1-v6-redesign-draft.md §5; counters: reports/P-popcorn-build9.md §1, mapping §1.5).

4a  one I->S coherence fault by phase (mean per fault, stacked durations, us), per load. Sums over the listed steps
    and all nodes; requester quantities per thread (thr.*.swmc.*, server process), owner quantities node-wide
    (sys.swmc.instr.serve_fetch.*). r = read rounds per I->S fault = read_transactions / is_faults.
      F (total)                   is_fault_ns / is_faults
      local handling              F - read_msg_wait_ns / is_faults                       (F - W, W of all rounds)
      transport + owner queueing  (read_xport_ns / read_owner_h_rounds) x r              (mean (W - H) per round)
      owner revoke (mkclean + TLB shootdown send/wait)  revoke_ns / (ack + nack) x r
      owner write-back flush      wb_ns / (ack + nack) x r
      owner reply send            reply_ns / reply_count x r
      owner rest of H             (read_owner_h_ns / read_owner_h_rounds) x r - the three owner parts above
    The stack sums to F up to rounds without H. marker: p99 of F from the fault_full_is histogram (upper bound of the
    p99 power-of-two bucket). CSV also: r, nontrans_faults per I->S fault (read_* rounds include read faults that
    ended without a transition: exact only when this is ~0, build9 §1.5), I->S faults per query.
    Build-8 runs (no build-9 keys) are REFUSED; --approx-build8 draws the old approximation (F = all read faults,
    W = FETCH waits, owner timers over all served requests, H = owner handling sums) with approximate_build8 = 1 and
    an APPROXIMATE plot title.
4b  coherence time per query (us), query operation of the serving threads (swmc_acct per-op deltas):
      I->S                 pop_is_ns / N_query
      S->M / I->M / wp     (pop_sm_ns + pop_wp_ns) / N_query      (fault_cnt[1] includes I->M)
      coherence IPIs       pop_ipi_ns / N_query                   (ipi_coh_*: shootdowns from Popcorn revocations)
      non-transition faults pop_nontrans_ns / N_query: own component, NOT in C, drawn hatched only when a workload
                           exports it per operation; the CSV always gives the window value
                           thr.*.swmc.nontrans_fault_ns / N_query (all threads of the server, not only queries)

usage: v6_fig4_popcorn.py a|b --out DIR --tag dlrm LOAD=DIR[:STEPS] ...    (Popcorn runs; LOAD e.g. avg, peak)
       [--query-op query] [--approx-build8]   (4a only: allow the build-8 approximation, flagged)
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

A_COMP = ["Owner: rest of H", "Owner: reply send", "Owner: write-back flush", "Owner: revoke + TLB shootdown",
          "Transport + owner queueing", "Local handling"]  # legend top -> bottom
B_COMP = ["Coherence IPIs", "S->M / I->M / wp faults", "I->S faults", "Non-transition faults (not in C)"]


def specs(a):
    out = []
    for s in a.runs:
        load, sep, rest = s.partition("=")
        if not sep:
            sys.exit(f"bad spec {s!r}: LOAD=DIR[:STEPS]")
        path, _, st = rest.partition(":")
        run = v6.Run(path, "pop")
        out.append((load, run, run.select([int(x) for x in st.split(",")] if st else None)))
    return out


def us(v):
    return None if v is None else v / 1e3


def phases_b9(n):
    g = lambda k: n.get(k, 0)  # noqa: E731
    nF = g("is_f_cnt")
    F = v6.div(g("is_f_sum_ns"), nF)
    rpf = v6.div(g("rd_rounds"), nF)
    Wf = v6.div(g("rd_w_sum_ns"), nF)
    hr = g("rd_h_rounds")
    served = g("own_ack") + g("own_nack")
    sc = lambda v: None if v is None or rpf is None else v * rpf  # noqa: E731  per round -> per fault
    trans = sc(v6.div(g("rd_xport_ns"), hr))
    H = sc(v6.div(g("rd_h_sum_ns"), hr))
    rev, wb = sc(v6.div(g("own_revoke_ns"), served)), sc(v6.div(g("own_wb_ns"), served))
    rep = sc(v6.div(g("own_reply_ns"), g("own_reply_cnt")))
    rest = None if H is None else H - (rev or 0) - (wb or 0) - (rep or 0)
    local = None if F is None or Wf is None else F - Wf
    return nF, F, Wf, H, rpf, [rest, rep, wb, rev, trans, local]


def phases_b8(n):
    g = lambda k: n.get(k, 0)  # noqa: E731
    nF, nO = g("is_f_cnt"), g("own_cnt")
    F, W = v6.div(g("is_f_sum_ns"), nF), v6.div(g("is_w_sum_ns"), nF)
    H = v6.div(g("own_h_sum_ns"), nO)
    mk, wb = v6.div(g("own_mkclean_ns"), nO), v6.div(g("own_wbflush_ns"), nO)
    rest = None if H is None else H - (mk or 0) - (wb or 0)
    local = None if F is None or W is None else F - W
    trans = None if W is None or H is None else W - H
    return nF, F, W, H, None, [rest, None, wb, mk, trans, local]


def fig_a(a):
    rows, groups, ref, used_all, any_approx = [], [], {None: "p99 of F"}, {}, False
    for load, run, steps in specs(a):
        n, used = v6.node_sums(run, steps, list(v6.NODEKEYS))
        missing = [c for c in v6.FIG4A_B9 if c not in n]
        p99, hpre = v6.hist_pct(run, steps, v6.IS_F_HIST, 99)
        fb = []
        if missing or not hpre:
            if not a.approx_build8:
                sys.exit(f"fig 4a {load} ({run.path}): build-9 counters missing: {missing or ''}"
                         f"{'' if hpre else ' fault_full_is histogram'}. Refused (a build-8 run gives F over all read "
                         "faults but W over FETCH waits only); --approx-build8 draws a flagged approximation")
            n, used = v6.node_sums(run, steps, list(v6.NODEKEYS_B8), v6.NODEKEYS_B8)
            p99, hpre = v6.hist_pct(run, steps, v6.IS_F_HIST_B8, 99)
            fb = [f"{c}={k}" for c, k in sorted(used.items())] + ["H=owner handling sums"]
            nF, F, W, H, rpf, vals = phases_b8(n)
            nt = None
        else:
            nF, F, W, H, rpf, vals = phases_b9(n)
            nt = v6.div(n.get("nontrans_faults", 0), nF) if "nontrans_faults" in n else None
        any_approx |= bool(fb)
        for c, k in used.items():
            used_all.setdefault(c, set()).add(k)
        q, _ = (v6.op_sums(run, steps, a.query_op)[:2] if a.query_op in run.ops(steps) else (None, None))
        per_q = v6.div(q.get("pop_is_cnt", 0), q["ops"]) if q else None
        groups.append((load, [("", [us(v) for v in vals])]))
        ref[(load, "")] = us(p99)
        rows.append([load, nF] + [v6.r(us(v), 3) for v in [F, W, H] + vals] + [v6.r(rpf, 4), v6.r(nt, 5),
                     v6.r(us(p99), 3), hpre or "", v6.r(per_q, 4), int(bool(fb)), "; ".join(fb),
                     ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig4a.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, A_COMP, "Time per I->S\nfault (us)", ref=ref,
               title="APPROXIMATE (build-8 counters, see CSV)" if any_approx else None)
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 4a one I->S coherence fault by phase ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "r = read_transactions/is_faults; F = is_fault_ns/is_faults; W = read_msg_wait_ns/is_faults; "
                    "local = F - W; transport = read_xport_ns/read_owner_h_rounds x r; H = read_owner_h_ns/"
                    "read_owner_h_rounds x r; revoke = serve_fetch revoke_ns/(ack+nack) x r; wbflush = wb_ns/"
                    "(ack+nack) x r; reply = reply_ns/reply_count x r; rest_of_H = H - revoke - wbflush - reply; "
                    "nontrans_per_is = nontrans_faults/is_faults; is_per_query = pop_is_cnt(query op)/N_query; sums "
                    "over steps and all nodes; us = ns/1000 (approximate_build8 rows: build-8 formula, see docstring)"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))
                    + "; p99 histogram prefix in column p99_src (thr.* = sum over the server's thread groups)"),
        ("tags", "F, W, H, xport, owner timers measured (kernel TSC clock; H on the owner clock); counts measured; "
                 "per-fault phases derived; p99 derived from power-of-two buckets (upper bound)"),
        ("inputs", "Popcorn runs per load, see the run column"),
    ], ["load", "n_F", "F_us", "W_us", "H_us", "rest_of_H_us", "reply_us", "wbflush_us", "revoke_us", "transport_us",
        "local_us", "rounds_per_fault", "nontrans_per_is", "F_p99_us", "p99_src", "is_faults_per_query",
        "approximate_build8", "fallbacks", "steps", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def fig_b(a):
    rows, groups, used_all = [], [], {}
    for load, run, steps in specs(a):
        q, used, _ = v6.op_sums(run, steps, a.query_op)
        n, nu = v6.node_sums(run, steps, ["nontrans_fault_ns", "nontrans_faults"])
        for c, k in list(used.items()) + list(nu.items()):
            used_all.setdefault(c, set()).add(k)
        N = q["ops"]
        nt_op = v6.div(q["pop_nontrans_ns"], N) if "pop_nontrans_ns" in q else None
        vals = [v6.div(q.get("pop_ipi_ns", 0), N), v6.div(q.get("pop_sm_ns", 0) + q.get("pop_wp_ns", 0), N),
                v6.div(q.get("pop_is_ns", 0), N), nt_op or 0.0]
        groups.append((load, [("", [us(v) for v in vals])]))
        nt_win = v6.div(n["nontrans_fault_ns"], N) if "nontrans_fault_ns" in n else None
        rows.append([load, N] + [v6.r(us(v), 3) for v in vals[:3]] + [v6.r(us(nt_op), 3), v6.r(us(nt_win), 3)]
                    + [v6.r(v6.div(q.get(c, 0), N), 4) for c in ("pop_is_cnt", "pop_sm_cnt", "pop_wp_cnt", "pop_ipi_cnt")]
                    + [v6.r(v6.div(n["nontrans_faults"], N) if "nontrans_faults" in n else None, 4),
                       v6.r(us(v6.div(q["t_ns"], N)), 3), ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig4b.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, B_COMP, "Coherence time\nper query (us)", hatch_from=3)
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 4b coherence time per query ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "is = pop_is_ns/N_query; sm_wp = (pop_sm_ns + pop_wp_ns)/N_query (I->M included); ipi = "
                    "pop_ipi_ns/N_query (coherence-initiated shootdown IPIs only); nontrans_op = pop_nontrans_ns/"
                    "N_query (own component, not in C; empty while no workload exports it); nontrans_window = "
                    "thr.*.swmc.nontrans_fault_ns/N_query (all server threads, CSV only); query operation of the "
                    "serving threads, sums over steps and nodes; T_query = t_ns/N_query"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "durations measured (swmc_acct / per-thread swmc, kernel clock); counts measured; per-query values "
                 "derived"),
        ("inputs", "Popcorn runs per load, see the run column"),
    ], ["load", "N_query", "ipi_us", "sm_wp_us", "is_us", "nontrans_op_us", "nontrans_window_us", "is_per_query",
        "sm_per_query", "wp_per_query", "ipi_per_query", "nontrans_window_per_query", "T_query_us", "steps", "run"],
        rows)
    print(f"-> {png}\n-> {csvp}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("panel", choices=("a", "b"))
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--query-op", default="query")
    ap.add_argument("--approx-build8", action="store_true", help="4a: allow the build-8 approximation (flagged)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    {"a": fig_a, "b": fig_b}[a.panel](a)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""MOT1 v6 Fig 4 (H3): Popcorn detail, DLRM at the Ekko average and peak update rates
(reports/MOT1-v6-redesign-draft.md §5).

4a  one I->S coherence fault by phase (mean, stacked durations, us), per load:
      local handling              (sum F - sum W) / n_F                  requester: fault F, reply wait W
      transport + owner queueing  (sum W - sum H) / n_F                  H = owner handling time returned in the reply
      owner mkclean (+shootdown)  sum own_mkclean / n_own                owner timers, FETCH requests served
      owner write-back flush      sum own_wbflush / n_own
      owner reply send + rest     (sum own_H - sum own_mkclean - sum own_wbflush) / n_own
    marker: p99 of F (power-of-two histogram: upper bound of the p99 bucket, resolution x2)
    secondary (CSV): I->S faults per query = pop_is_cnt(query op) / N_query
    Sums over the listed steps and all nodes (requester and owner roles of both VMs). Keys: v6_common.NODEKEYS; the
    build-9 names are PROVISIONAL, the build-8 fallbacks are not exact (fault_read = all read faults, serve.mkclean/
    wb_flush = all served requests, H from the owners' own sums): the CSV names every key used. Without a
    requester-side H key, transport is (sum W)/n_F - (sum own_H)/n_own (stated in the CSV).
4b  coherence time per query (us): I->S       pop_is_ns / N_query
                                   S->M / wp  (pop_sm_ns + pop_wp_ns) / N_query
                                   IPI        pop_ipi_ns / N_query      (serving threads, query operation)

usage: v6_fig4_popcorn.py a|b --out DIR --tag dlrm LOAD=DIR[:STEPS] ...    (Popcorn runs; LOAD e.g. avg, peak)
       [--query-op query]
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

A_COMP = ["Owner: reply send + rest", "Owner: write-back flush", "Owner: PTE mkclean + shootdown",
          "Transport + owner queueing", "Local handling"]  # legend top -> bottom
B_COMP = ["IPI handling", "S->M / wp faults", "I->S faults"]


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


def fig_a(a):
    rows, groups, ref, used_all = [], [], {None: "p99 of F"}, {}
    for load, run, steps in specs(a):
        n, used = v6.node_sums(run, steps, list(v6.NODEKEYS))
        for c, k in used.items():
            used_all.setdefault(c, set()).add(k)
        g = lambda k: n.get(k, 0)  # noqa: E731
        nF, nO = g("is_f_cnt"), g("own_cnt")
        F, W = v6.div(g("is_f_sum_ns"), nF), v6.div(g("is_w_sum_ns"), nF)
        Hreq = v6.div(n["is_h_sum_ns"], nF) if "is_h_sum_ns" in n else None
        Hown = v6.div(g("own_h_sum_ns"), nO)
        mk, wb = v6.div(g("own_mkclean_ns"), nO), v6.div(g("own_wbflush_ns"), nO)
        H = Hreq if Hreq is not None else Hown
        local = None if F is None or W is None else F - W
        trans = None if W is None or H is None else W - H
        rest = None if Hown is None else Hown - (mk or 0) - (wb or 0)
        vals = [rest, wb, mk, trans, local]
        p99, hpre = v6.hist_pct(run, steps, v6.IS_F_HIST, 99)
        q, _ = (v6.op_sums(run, steps, a.query_op)[:2] if a.query_op in run.ops(steps) else (None, None))
        per_q = v6.div(q.get("pop_is_cnt", 0), q["ops"]) if q else None
        groups.append((load, [("", [None if v is None else v / 1e3 for v in vals])]))
        ref[(load, "")] = p99 / 1e3 if p99 else None
        rows.append([load, nF, nO] + [v6.r(None if v is None else v / 1e3, 3) for v in [F, W, H] + vals]
                    + ["requester" if Hreq is not None else "owner sums", v6.r(None if p99 is None else p99 / 1e3, 3),
                       hpre or "", v6.r(per_q, 4), ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig4a.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, A_COMP, "Time per I->S\nfault (us)", ref=ref)
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 4a one I->S coherence fault by phase ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "local = (sum F - sum W)/n_F; transport = (sum W - sum H)/n_F (H from the reply if is_h_sum_ns "
                    "exists, else mean owner H = sum own_H / n_own: column H_src); mkclean = sum own_mkclean/n_own; "
                    "wbflush = sum own_wbflush/n_own; reply_rest = sum own_H/n_own - mkclean - wbflush; "
                    "is_per_query = pop_is_cnt(query op)/N_query; sums over steps and all nodes; us = ns/1000"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))
                    + "; p99 histogram prefix in column p99_src"),
        ("tags", "F, W, H, owner timers measured (kernel TSC clock); counts measured; phases derived; p99 derived "
                 "from power-of-two buckets (upper bound)"),
        ("inputs", "Popcorn runs per load, see the run column"),
    ], ["load", "n_F", "n_own", "F_us", "W_us", "H_us", "reply_rest_us", "wbflush_us", "mkclean_us", "transport_us",
        "local_us", "H_src", "F_p99_us", "p99_src", "is_faults_per_query", "steps", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def fig_b(a):
    rows, groups, used_all = [], [], {}
    for load, run, steps in specs(a):
        q, used, _ = v6.op_sums(run, steps, a.query_op)
        for c, k in used.items():
            used_all.setdefault(c, set()).add(k)
        N = q["ops"]
        vals = [v6.div(q.get("pop_ipi_ns", 0), N), v6.div(q.get("pop_sm_ns", 0) + q.get("pop_wp_ns", 0), N),
                v6.div(q.get("pop_is_ns", 0), N)]
        groups.append((load, [("", [None if v is None else v / 1e3 for v in vals])]))
        rows.append([load, N] + [v6.r(None if v is None else v / 1e3, 3) for v in vals]
                    + [v6.r(v6.div(q.get(c, 0), N), 4) for c in ("pop_is_cnt", "pop_sm_cnt", "pop_wp_cnt", "pop_ipi_cnt")]
                    + [v6.r(v6.div(q["t_ns"], N) / 1e3 if N else None, 3), ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig4b.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, B_COMP, "Coherence time\nper query (us)")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 4b coherence time per query ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "is = pop_is_ns/N_query; sm_wp = (pop_sm_ns + pop_wp_ns)/N_query; ipi = pop_ipi_ns/N_query; "
                    "query operation of the serving threads, sums over steps and nodes; T_query = t_ns/N_query"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "durations measured (swmc_acct, kernel clock); counts measured; per-query values derived"),
        ("inputs", "Popcorn runs per load, see the run column"),
    ], ["load", "N_query", "ipi_us", "sm_wp_us", "is_us", "is_per_query", "sm_per_query", "wp_per_query",
        "ipi_per_query", "T_query_us", "steps", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("panel", choices=("a", "b"))
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--query-op", default="query")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    {"a": fig_a, "b": fig_b}[a.panel](a)


if __name__ == "__main__":
    main()

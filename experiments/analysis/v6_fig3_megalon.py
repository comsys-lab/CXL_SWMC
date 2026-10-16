#!/usr/bin/env python3
"""MOT1 v6 Fig 3 (H2): Megalon detail, vector DB, update share 0/5/10/20/50% (reports/MOT1-v6-redesign-draft.md §4).

3a  Megalon coherence time per operation by mechanism (stacked durations, us per operation), per update share:
      search bar:  section checks  meg_check_ns_sampled x check_sample / N_search   [sampled x N]
                   stale copy (A)  meg_stale_ns  / N_search
                   concurrent write (B) meg_concur_ns / N_search
                   metadata change (C)  meg_meta_ns   / N_search
                   writer-lock spin (D) meg_spin_ns   / N_search
      update bar:  write start     meg_wstart_ns / N_update   (incl. switch_rw, reclaim)
                   write-end flush meg_wflush_ns / N_update
    (search-op components from the search operation's CohSnap deltas, update components from the update operation's)
3b  bytes written back per update:  Megalon  meg_wflush_bytes(update) / N_update
                                    Popcorn  pop_remote_wb (node-wide, all nodes) x 4096 / N_update   (contrast)
    reference line: modified bytes  mod_bytes(update) / N_update (bytes the application stored; NOT EXPORTED yet)
3c  false vs true sharing (trace runs, 32 MiB objects): classification by the draft's definition (Dubois et al.):
    an (A)/(B) event of node n on object O is TRUE sharing if, while that copy lives (until n's next (A)/(B) event on
    O, or the end of the log), n reads at least one element modified by the writes that caused the event (writes on O
    with seq_prev < wseq <= seq_seen); otherwise FALSE. y = events / N_search split false/true; secondary = false
    share of the (A)+(B) duration.
    Trace input (PROVISIONAL format, task A6 until A3's trace lands; one dir per update share):
      writes.csv        object,element,wseq                      one row per element written (writer node)
      node<K>.log.csv   kind,object,a,b,c                        rows in the node's own order:
                        R,<object>,<element>,,                   an element read in a read section
                        E,<object>,<A|B>,<seq_prev>,<seq_seen>[,<dur_ns>]  a stale-copy / concurrent-write event
      n_search.txt      N_search of the traced window (searches completed on the traced nodes)

usage: v6_fig3_megalon.py a --out DIR --tag vdb SHARE=DIR[:STEPS] ...           (Megalon runs, SHARE in %)
       v6_fig3_megalon.py b --out DIR --tag vdb SHARE=DIR[:STEPS] ... [--pop SHARE=DIR[:STEPS] ...]
       v6_fig3_megalon.py c --out DIR --tag vdb SHARE=TRACEDIR ...
Options: --search-op search --update-op update (operation names in the per-op stats).
"""
import argparse, bisect, csv, glob, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

A_SEARCH = [("Section checks", "meg_check_est_ns", "sampled x N"), ("Stale copy (A)", "meg_stale_ns", "measured"),
            ("Concurrent write (B)", "meg_concur_ns", "measured"), ("Metadata change (C)", "meg_meta_ns", "measured"),
            ("Writer-lock spin (D)", "meg_spin_ns", "measured")]
A_UPDATE = [("Write start", "meg_wstart_ns", "measured"), ("Write-end flush", "meg_wflush_ns", "measured")]


def share_specs(specs, sysname):
    out = []
    for s in specs:
        share, sep, rest = s.partition("=")
        if not sep:
            sys.exit(f"bad spec {s!r}: SHARE=DIR[:STEPS]")
        path, _, st = rest.partition(":")
        run = v6.Run(path, sysname)
        out.append((float(share), run, run.select([int(x) for x in st.split(",")] if st else None)))
    return sorted(out, key=lambda t: t[0])


def opsum(run, steps, op):
    if op not in run.ops(steps):
        return None, {}
    s, used, _ = v6.op_sums(run, steps, op)
    return s, used


def fig_a(a):
    rows, groups, used_all = [], [], {}
    comps = [c[0] for c in A_SEARCH] + [c[0] for c in A_UPDATE]
    for share, run, steps in share_specs(a.runs, "mg"):
        s, us = opsum(run, steps, a.search_op)
        u, uu = opsum(run, steps, a.update_op)
        for d in (us, uu):
            for c, k in d.items():
                used_all.setdefault(c, set()).add(k)
        sv = [s.get(c, 0) / s["ops"] / 1e3 if s and s["ops"] else None for _, c, _ in A_SEARCH]
        uv = [u.get(c, 0) / u["ops"] / 1e3 if u and u["ops"] else None for _, c, _ in A_UPDATE]
        n = len(A_SEARCH)
        bars = [("search", None if sv[0] is None else sv + [0.0] * len(A_UPDATE)),
                ("update", None if uv[0] is None else [0.0] * n + uv)]
        groups.append((f"{share:g}%", bars))
        rows.append([share, s["ops"] if s else 0, u["ops"] if u else 0] + [v6.r(v, 3) for v in sv + uv]
                    + [v6.r(v6.div(s.get("meg_stale_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_concur_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_meta_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_spin_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(u.get("meg_switch_rw_ns", 0), u["ops"]) / 1e3 if u and u["ops"] else None, 3),
                       v6.r(v6.div(u.get("meg_reclaim_ns", 0), u["ops"]) / 1e3 if u and u["ops"] else None, 3),
                       ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3a.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, comps, "Coherence time\nper operation (us)", hatch_from=len(A_SEARCH),
               xlabel="Update share")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 3a Megalon coherence time per operation by mechanism ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "search components = sum over steps and nodes of the search operation's CohSnap delta / N_search; "
                    "update components = update operation's delta / N_update; section checks = meg_check_ns_sampled x "
                    "check_sample (per node); us = ns / 1000; *_per_search counts = events / N_search"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "; ".join(f"{n}: {t}" for n, _, t in A_SEARCH + A_UPDATE) + "; counts measured; all ratios derived"),
        ("inputs", "Megalon runs per update share, see the run column"),
    ], ["update_share_pct", "N_search", "N_update"] + [f"{c}_us" for c in
        ("check", "stale_A", "concur_B", "meta_C", "spin_D")] + ["wstart_us", "wflush_us", "stale_A_per_search",
        "concur_B_per_search", "meta_C_per_search", "spin_D_per_search", "switch_rw_us_per_update",
        "reclaim_us_per_update", "steps", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def fig_b(a):
    rows, groups, ref, used_all = [], [], {None: "Modified bytes"}, {}
    meg = share_specs(a.runs, "mg")
    pop = {sh: (r, st) for sh, r, st in share_specs(a.pop or [], "pop")}
    for share, run, steps in meg:
        u, uu = opsum(run, steps, a.update_op)
        for c, k in uu.items():
            used_all.setdefault(c, set()).add(k)
        if not u or not u["ops"]:
            rows.append([share, "Megalon", 0, "", "", "", run.path])
            continue
        g = f"{share:g}%"
        mb = v6.div(u["meg_wflush_bytes"], u["ops"]) if "meg_wflush_bytes" in u else None
        mod = v6.div(u["mod_bytes"], u["ops"]) if "mod_bytes" in u else None
        bars = [("Megalon", [mb / 1024 if mb is not None else 0.0])]
        ref[(g, "Megalon")] = mod / 1024 if mod is not None else None
        rows.append([share, "Megalon", u["ops"], v6.r(mb, 1), v6.r(mod, 1), "meg_wflush_bytes", run.path])
        if share in pop:
            pr, pst = pop[share]
            pu, _ = opsum(pr, pst, a.update_op)
            ns, nu = v6.node_sums(pr, pst, ["pop_remote_wb"])
            pb = v6.div(ns.get("pop_remote_wb", 0) * v6.PAGE, pu["ops"]) if pu and pu["ops"] else None
            pmod = v6.div(pu["mod_bytes"], pu["ops"]) if pu and "mod_bytes" in pu else None
            bars.append(("Popcorn", [pb / 1024 if pb is not None else 0.0]))
            ref[(g, "Popcorn")] = pmod / 1024 if pmod is not None else None
            rows.append([share, "Popcorn", pu["ops"] if pu else 0, v6.r(pb, 1), v6.r(pmod, 1),
                         nu.get("pop_remote_wb", "") + " x 4096", pr.path])
        groups.append((g, bars))
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3b.{e}") for e in ("png", "csv"))
    if groups:
        v6.stacked(png, groups, ["Written back"], "KiB written back\nper update", ref=ref, logy=True,
                   xlabel="Update share")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 3b bytes written back per update ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "Megalon: sum meg_wflush_bytes(update op) / N_update; Popcorn: sum over nodes "
                    "pop_remote_wb x 4096 / N_update (contrast); modified bytes: sum mod_bytes(update op) / N_update "
                    "(reference line; empty while no workload exports it); sums over the listed steps and nodes"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))
                    + "; pop_remote_wb=" + "|".join(v6.NODEKEYS["pop_remote_wb"])),
        ("tags", "wflush_bytes measured (every event); remote_writeback_count measured; per-update values derived"),
        ("inputs", "see the run column"),
    ], ["update_share_pct", "system", "N_update", "writeback_bytes_per_update", "modified_bytes_per_update",
        "writeback_source", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def classify(trace):
    """-> list of events (node, object, type, seq_prev, seq_seen, dur_ns, class)."""
    writes = {}
    for row in csv.DictReader(open(os.path.join(trace, "writes.csv"))):
        writes.setdefault(row["object"], []).append((int(row["wseq"]), row["element"]))
    for o in writes:
        writes[o].sort()
    seqs = {o: [w[0] for w in v] for o, v in writes.items()}
    events = []
    for path in sorted(glob.glob(os.path.join(trace, "node*.log.csv"))):
        node = re.search(r"node(\d+)\.log\.csv$", path).group(1)
        open_ev = {}  # object -> (event index, modified element set)
        for row in csv.reader(open(path)):
            if not row or row[0] == "kind":
                continue
            kind, obj = row[0], row[1]
            if kind == "E":
                sp, ss = int(row[3]), int(row[4])
                lo, hi = bisect.bisect_right(seqs.get(obj, []), sp), bisect.bisect_right(seqs.get(obj, []), ss)
                mod = {e for _, e in writes.get(obj, [])[lo:hi]}
                events.append([node, obj, row[2], sp, ss, int(row[5]) if len(row) > 5 and row[5] else 0, "false"])
                open_ev[obj] = (len(events) - 1, mod)
            elif kind == "R":
                ev = open_ev.get(obj)
                if ev and row[2] in ev[1]:
                    events[ev[0]][6] = "true"
                    open_ev[obj] = (ev[0], set())  # classified; nothing more to find in this lifetime
    return events


def fig_c(a):
    rows, groups = [], []
    for spec in a.runs:
        share, _, trace = spec.partition("=")
        share = float(share)
        ev = classify(trace)
        nsearch = float(open(os.path.join(trace, "n_search.txt")).read().split()[0])
        nf = sum(1 for e in ev if e[6] == "false")
        nt = len(ev) - nf
        df = sum(e[5] for e in ev if e[6] == "false")
        dt = sum(e[5] for e in ev)
        with open(os.path.join(a.out, f"{a.tag}-fig3c-events-{share:g}.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["node", "object", "type", "seq_prev", "seq_seen", "dur_ns", "class"])
            w.writerows(ev)
        rows.append([share, nsearch, len(ev), nf, nt, v6.r(v6.div(nf, nsearch), 6), v6.r(v6.div(nt, nsearch), 6),
                     v6.r(v6.div(df, dt), 4), trace])
        groups.append((f"{share:g}%", [("", [v6.div(nf, nsearch), v6.div(nt, nsearch)])]))
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3c.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, ["False sharing", "True sharing"], "(A)+(B) events\nper search", xlabel="Update share")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 3c false vs true sharing at 32 MiB ({a.tag}); PNG {os.path.basename(png)}; "
                   f"per-event classes in {a.tag}-fig3c-events-<share>.csv"),
        ("formula", "event TRUE if the node reads >= 1 element in {writes on the object with seq_prev < wseq <= "
                    "seq_seen} before its next (A)/(B) event on the object (or log end), else FALSE; y = events / "
                    "N_search; false_time_share = sum dur_ns(false) / sum dur_ns(all) (secondary, not drawn)"),
        ("sources", "trace dir writes.csv (object, element, wseq), node<K>.log.csv (R/E rows), n_search.txt "
                    "(PROVISIONAL format, see module docstring)"),
        ("tags", "events count measured (trace); class derived (offline join by sequence numbers, no cross-VM clock); "
                 "dur_ns measured"),
        ("inputs", "see the trace column"),
    ], ["update_share_pct", "N_search", "events", "false", "true", "false_per_search", "true_per_search",
        "false_time_share", "trace"], rows)
    print(f"-> {png}\n-> {csvp}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("panel", choices=("a", "b", "c"))
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--pop", nargs="*", help="3b: Popcorn runs SHARE=DIR[:STEPS] (contrast)")
    ap.add_argument("--search-op", default="search")
    ap.add_argument("--update-op", default="update")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    {"a": fig_a, "b": fig_b, "c": fig_c}[a.panel](a)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""MOT1 v6 Fig 3 (H2): Megalon detail, vector DB, update share 0/5/10/20/50% (reports/MOT1-v6-redesign-draft.md §4).

3a  Megalon coherence time per operation by mechanism (stacked durations, us per operation), per update share:
      search bar:  section checks  meg_check_C_ns / N_search = (check_ns_sampled + anchor read lookup + anchor read
                                   NR, all sampled with the checks) x read_sections / check_sampled  [ratio estimator
                                   per node; read-section checks only (2015a31f3)]. Vector DB rule "plain" (all-HWcc
                                   = plain backend, every Megalon call is C, v6_common.MEG_RULE); the anchor part is
                                   also in the CSV (anchor_read_us_in_check); Megalon < 75 has no AnchorSnap
                                   (anchor_split_unavailable_nodes > 0: check slightly low)
                   validation copy meg_vcopy_ns_sampled x vcopy_cnt / vcopy_sampled / N_search  [sampled, ratio
                                   estimator per node; copy into the scratch buffer kept only because the data must
                                   outlive the read section (§3.1)]
                   stale copy (A)  meg_stale_ns  / N_search
                   concurrent write (B) meg_concur_ns / N_search
                   metadata change (C)  meg_meta_ns   / N_search
                   contended waits (D) meg_spin_ns / N_search  (seqlock version odd + NR combiner / replica
                                   read-lock waits inside ObjectReadStart/End)
      update bar:  write start     meg_wstart_C_ns / N_update = (wstart + anchor write lookup + NR) / N_update
                                   (incl. switch_rw, reclaim)
                   write-end flush meg_wflush_ns / N_update
    (search-op components from the search operation's CohSnap deltas, update components from the update operation's)
3b  bytes written back per update:  Megalon  meg_wflush_bytes(update) / N_update
                                    Popcorn  remote_writeback_count (window delta, all nodes) x 4096 / N_update
                                             (contrast: the real write-back counter; verifier 2026-10-16); secondary
                                             CSV column "M acquisitions x 4 KiB" = (pop_sm_cnt + pop_wp_cnt)(update)
                                             x 4096 / N_update
    reference line: modified bytes  mod_bytes(update) / N_update (opt.update.mod_bytes: bytes the application stored)
3c  false vs true sharing (trace runs, 32 MiB objects): classification by the draft's definition (Dubois et al.):
    an (A)/(B) event of node n on object O is TRUE sharing if, while that copy lives (until n's next (A)/(B) event on
    O, or the end of the log), n reads at least one element modified by the writes that caused the event (writes on O
    with seq_prev < wseq <= seq_seen); otherwise FALSE. y = events / N_search split false/true; secondary = false
    share of the (A)+(B) duration.
    Input per update share (vector DB, workloads/vectordb/tools/classify_sharing.py, CXL_SWMC 03d2a5391):
      SHARE=PREFIX.csv  classify_sharing.py output (authoritative): row --role (default search): true = true_A+true_B,
                        false = false_A+false_B, excluded = no_prior_copy+unexplained, ev_ns_*, searches
      SHARE=DIR         its --a6-dir export, classified again here (cross-check, see classify()):
        writes.csv        object,element,wseq        element "<kind>:<unit>" (vec, link, dlog) or "*" (whole object)
        node<K>.log.csv   kind,object,a,b,c          R,<object>,<element>,,   E,<object>,<A|B>,<seq_prev>,<seq_seen>,<dur_ns>
        n_search.txt      N_search of the traced window

usage: v6_fig3_megalon.py a --out DIR --tag vdb SHARE=DIR[:STEPS] ...           (Megalon runs, SHARE in %)
       v6_fig3_megalon.py b --out DIR --tag vdb SHARE=DIR[:STEPS] ... [--pop SHARE=DIR[:STEPS] ...]
       v6_fig3_megalon.py c --out DIR --tag vdb SHARE=PREFIX.csv|A6DIR ... [--role search]
Options: --search-op search --update-op update (operation names in the per-op stats).
"""
import argparse, bisect, csv, glob, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v6_common as v6  # noqa: E402

A_SEARCH = [("Section checks", "meg_check_C_ns", "sampled (ratio estimate)"),
            ("Validation copy", "meg_vcopy_est_ns", "sampled (ratio estimate)"), ("Stale copy (A)", "meg_stale_ns", "measured"),
            ("Concurrent write (B)", "meg_concur_ns", "measured"), ("Metadata change (C)", "meg_meta_ns", "measured"),
            ("Contended waits (D)", "meg_spin_ns", "measured")]
A_UPDATE = [("Write start", "meg_wstart_C_ns", "measured"), ("Write-end flush", "meg_wflush_C_ns", "measured")]


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
    rows, groups, used_all, lean = [], [], {}, []
    comps = [c[0] for c in A_SEARCH] + [c[0] for c in A_UPDATE]
    for share, run, steps in share_specs(a.runs, "mg"):
        s, us = opsum(run, steps, a.search_op)
        u, uu = opsum(run, steps, a.update_op)
        for d in (us, uu):
            for c, k in d.items():
                used_all.setdefault(c, set()).add(k)
        for o, x in (("search", s), ("update", u)):
            if x and (x["meg_lean_nodes"] or x["lean_est_missing_nodes"]):
                lean.append(f"{share:g}%:{o} lean_nodes={x['meg_lean_nodes']} events_always_nodes="
                            f"{x['meg_events_always_nodes']} lean_est_missing_nodes={x['lean_est_missing_nodes']}")
        sv = [s.get(c, 0) / s["ops"] / 1e3 if s and s["ops"] else None for _, c, _ in A_SEARCH]
        uv = [u.get(c, 0) / u["ops"] / 1e3 if u and u["ops"] else None for _, c, _ in A_UPDATE]
        n = len(A_SEARCH)
        bars = [("search", None if sv[0] is None else sv + [0.0] * len(A_UPDATE)),
                ("update", None if uv[0] is None else [0.0] * n + uv)]
        groups.append((f"{share:g}%", bars))
        rows.append([share, s["ops"] if s else 0, u["ops"] if u else 0] + [v6.r(v, 4) for v in sv + uv]
                    + [v6.r(v6.div(s.get("meg_stale_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_concur_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_meta_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(s.get("meg_spin_cnt", 0), s["ops"]) if s else None, 5),
                       v6.r(v6.div(u.get("meg_switch_rw_ns", 0), u["ops"]) / 1e3 if u and u["ops"] else None, 3),
                       v6.r(v6.div(u.get("meg_reclaim_ns", 0), u["ops"]) / 1e3 if u and u["ops"] else None, 3),
                       v6.r(v6.div(s.get("meg_anchor_rd_est_ns", 0), s["ops"]) / 1e3 if s and s["ops"] else None, 4),
                       s["check_est_missing_nodes"] if s else "", s["vcopy_est_missing_nodes"] if s else "",
                       s["anchor_split_unavailable_nodes"] if s else "", s["meg_rule"] if s else "",
                       ",".join(map(str, steps)), run.path])
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3a.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, comps, "Coherence time\nper operation (us)", hatch_from=len(A_SEARCH),
               xlabel="Update share")
    # Megalon >= 76 lean sampling: the "measured" components are then ratio estimates (stated only when present, so
    # outputs of older data stay byte-identical)
    lean_meta = [("megalon_lean", "Megalon >= 76: stale/concur/meta/spin = timed-section sums x read_sections/"
                  "check_sampled, write start / write-end flush (and switch_rw, reclaim) = timed sums x write_sections/"
                  "anchor.write_sampled per node (v6_common LEAN_*; full sums with events_always; no probe correction); "
                  "the 'measured' tags below are sampled estimates for these runs: " + "; ".join(lean))] if lean else []
    v6.write_csv(csvp, lean_meta + [
        ("figure", f"MOT1 v6 Fig 3a Megalon coherence time per operation by mechanism ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "search components = sum over steps and nodes of the search operation's CohSnap delta / N_search; "
                    "update components = update operation's delta / N_update; section checks = meg_check_C_ns (rule in "
                    "column meg_rule; plain: (check_ns_sampled + anchor.read_lookup_ns_sampled + anchor.read_nr_ns_sampled)"
                    " x read_sections / check_sampled per node; hwcc_flavor: (check_ns_sampled - anchor.rseq_ns_sampled) x "
                    "read_sections / check_sampled); anchor_read_us_in_check = the anchor part (plain rule: inside section "
                    "checks); write start = meg_wstart_C_ns (plain: wstart + anchor.write_lookup_ns + anchor.write_nr_ns); "
                    "validation copy = meg_vcopy_ns_sampled x vcopy_cnt / vcopy_sampled (per node); us = ns / 1000; *_per_search counts = events / N_search"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))),
        ("tags", "; ".join(f"{n}: {t}" for n, _, t in A_SEARCH + A_UPDATE) + "; counts measured; all ratios derived"),
        ("inputs", "Megalon runs per update share, see the run column"),
    ], ["update_share_pct", "N_search", "N_update"] + [f"{c}_us" for c in
        ("check", "vcopy", "stale_A", "concur_B", "meta_C", "waits_D")] + ["wstart_us", "wflush_us", "stale_A_per_search",
        "concur_B_per_search", "meta_C_per_search", "waits_D_per_search", "switch_rw_us_per_update",
        "reclaim_us_per_update", "anchor_read_us_in_check", "check_est_missing_nodes", "vcopy_est_missing_nodes",
        "anchor_split_unavailable_nodes", "meg_rule", "steps", "run"], rows)
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
            rows.append([share, "Megalon", 0, "", "", "", "", run.path])
            continue
        g = f"{share:g}%"
        mb = v6.div(u["meg_wflush_bytes"], u["ops"]) if "meg_wflush_bytes" in u else None
        mod = v6.div(u["mod_bytes"], u["ops"]) if "mod_bytes" in u else None
        bars = [("Megalon", None if mb is None else [mb / 1024])]  # key absent = no data (no bar), not 0
        ref[(g, "Megalon")] = mod / 1024 if mod is not None else None
        rows.append([share, "Megalon", u["ops"], v6.r(mb, 1), v6.r(mod, 1), "",
                     "meg_wflush_bytes" if mb is not None else "NO DATA (meg_wflush_bytes absent)", run.path])
        if share in pop:
            pr, pst = pop[share]
            pu, pk = opsum(pr, pst, a.update_op)
            for c, k in pk.items():
                used_all.setdefault(c, set()).add(k)
            ns, nu = v6.node_sums(pr, pst, ["pop_remote_wb"])  # real write-back counter, all nodes, per window
            pb = ns["pop_remote_wb"] * v6.PAGE / pu["ops"] if pu and pu["ops"] and "pop_remote_wb" in ns else None
            have = pu and pu["ops"] and ("pop_sm_cnt" in pu or "pop_wp_cnt" in pu)  # absent = no data, not 0
            macq = (pu.get("pop_sm_cnt", 0) + pu.get("pop_wp_cnt", 0)) * v6.PAGE / pu["ops"] if have else None
            pmod = v6.div(pu["mod_bytes"], pu["ops"]) if pu and "mod_bytes" in pu else None
            bars.append(("Popcorn", None if pb is None else [pb / 1024]))
            ref[(g, "Popcorn")] = pmod / 1024 if pmod is not None else None
            rows.append([share, "Popcorn", pu["ops"] if pu else 0, v6.r(pb, 1), v6.r(pmod, 1), v6.r(macq, 1),
                         nu["pop_remote_wb"] + " x 4096" if pb is not None else "NO DATA (remote_writeback_count absent)",
                         pr.path])
        groups.append((g, bars))
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3b.{e}") for e in ("png", "csv"))
    if groups:
        v6.stacked(png, groups, ["Written back"], "KiB written back\nper update", ref=ref, logy=True,
                   xlabel="Update share")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 3b bytes written back per update ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "Megalon: sum meg_wflush_bytes(update op) / N_update; Popcorn: sum over nodes of the window "
                    "delta of sys.swmc.page_coherence.remote_writeback_count x 4096 / N_update (contrast; pages "
                    "written back for a peer); secondary column M_acquisitions_x4KiB_per_update = (pop_sm_cnt + "
                    "pop_wp_cnt)(update op) x 4096 / N_update ('M acquisitions x 4 KiB', not drawn); modified bytes: "
                    "sum mod_bytes(update op) / N_update (reference line); sums over the listed steps and nodes"),
        ("sources", "; ".join(f"{c}={'|'.join(sorted(k))}" for c, k in sorted(used_all.items()))
                    + "; pop_remote_wb=" + "|".join(v6.NODEKEYS["pop_remote_wb"])),
        ("tags", "wflush_bytes, mod_bytes, remote_writeback_count, sm/wp fault counts measured (every event); per-update values derived"),
        ("inputs", "see the run column"),
    ], ["update_share_pct", "system", "N_update", "writeback_bytes_per_update", "modified_bytes_per_update",
        "M_acquisitions_x4KiB_per_update", "writeback_source", "run"], rows)
    print(f"-> {png}\n-> {csvp}")


def classify(trace):
    """A6 join on classify_sharing.py --a6-dir output -> events [node, object, type, seq_prev, seq_seen, dur_ns, class].
    Elements "<kind>:<unit>" (vec, link, dlog); "*" = the whole object (a whole-object write modifies every element, a
    whole-object read reads every element). class: true | false | unexplained (no write in (seq_prev, seq_seen]:
    excluded from true/false, as in classify_sharing.py). Cross-check only: writes.csv carries no writer node (own-node
    writes are not excluded) and one E row per section (not the (A)/(B) multiplicity), so classify_sharing.py's
    sharing.csv is the authoritative Fig 3c input."""
    writes = {}
    for row in csv.DictReader(open(os.path.join(trace, "writes.csv"))):
        writes.setdefault(row["object"], []).append((int(row["wseq"]), row["element"]))
    for o in writes:
        writes[o].sort()
    seqs = {o: [w[0] for w in v] for o, v in writes.items()}
    events = []
    for path in sorted(glob.glob(os.path.join(trace, "node*.log.csv"))):
        node = re.search(r"node(\d+)\.log\.csv$", path).group(1)
        open_ev = {}  # object -> (event index, modified element set, whole object modified)
        for row in csv.reader(open(path)):
            if not row or row[0] == "kind":
                continue
            kind, obj = row[0], row[1]
            if kind == "E":
                sp, ss = int(row[3]), int(row[4])
                lo, hi = bisect.bisect_right(seqs.get(obj, []), sp), bisect.bisect_right(seqs.get(obj, []), ss)
                mod = {e for _, e in writes.get(obj, [])[lo:hi]}
                cls = "false" if mod else "unexplained"
                events.append([node, obj, row[2], sp, ss, int(row[5]) if len(row) > 5 and row[5] else 0, cls])
                open_ev[obj] = (len(events) - 1, mod - {"*"}, "*" in mod) if mod else None
            elif kind == "R":
                ev = open_ev.get(obj)
                if ev and (ev[2] or row[2] == "*" or row[2] in ev[1]):
                    events[ev[0]][6] = "true"
                    open_ev[obj] = None  # classified; nothing more to find in this lifetime
    return events


def from_sharing_csv(path, role):
    """classify_sharing.py PREFIX.csv row of the role -> (N_search, true, false, excluded, ev_ns_true, ev_ns_false)."""
    for row in csv.DictReader(open(path)):
        if row["role"] == role:
            g = lambda k: float(row.get(k) or 0)  # noqa: E731
            return (g("searches"), g("true_A") + g("true_B"), g("false_A") + g("false_B"),
                    g("no_prior_copy") + g("unexplained"), g("ev_ns_true"), g("ev_ns_false"))
    sys.exit(f"{path}: no row with role={role}")


def fig_c(a):
    rows, groups = [], []
    for spec in a.runs:
        share, _, src = spec.partition("=")
        share = float(share)
        if src.endswith(".csv"):  # classify_sharing.py output (authoritative)
            nsearch, nt, nf, nx, dtrue, dfalse = from_sharing_csv(src, a.role)
            kind = f"classify_sharing.py role={a.role}"
        else:  # A6 join on the --a6-dir export (cross-check)
            ev = classify(src)
            nsearch = float(open(os.path.join(src, "n_search.txt")).read().split()[0])
            nf = sum(1 for e in ev if e[6] == "false")
            nt = sum(1 for e in ev if e[6] == "true")
            nx = len(ev) - nf - nt
            dfalse = sum(e[5] for e in ev if e[6] == "false")
            dtrue = sum(e[5] for e in ev if e[6] == "true")
            kind = "A6 join (--a6-dir export)"
            with open(os.path.join(a.out, f"{a.tag}-fig3c-events-{share:g}.csv"), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["node", "object", "type", "seq_prev", "seq_seen", "dur_ns", "class"])
                w.writerows(ev)
        rows.append([share, nsearch, nt + nf + nx, nf, nt, nx, v6.r(v6.div(nf, nsearch), 6),
                     v6.r(v6.div(nt, nsearch), 6), v6.r(v6.div(dfalse, dfalse + dtrue), 4), kind, src])
        groups.append((f"{share:g}%", [("", [v6.div(nf, nsearch), v6.div(nt, nsearch)])]))
    png, csvp = (os.path.join(a.out, f"{a.tag}-fig3c.{e}") for e in ("png", "csv"))
    v6.stacked(png, groups, ["False sharing", "True sharing"], "(A)+(B) events\nper search", xlabel="Update share")
    v6.write_csv(csvp, [
        ("figure", f"MOT1 v6 Fig 3c false vs true sharing at 32 MiB ({a.tag}); PNG {os.path.basename(png)}"),
        ("formula", "event TRUE if the node reads >= 1 element modified by the causing writes (seq_prev < wseq <= "
                    "seq_seen; '*' = whole object) before its next (A)/(B) event on the object (or trace end), else "
                    "FALSE; no_prior_copy/unexplained excluded (column excluded); y = false|true / N_search; "
                    "false_time_share = ev_ns_false / (ev_ns_false + ev_ns_true) (secondary, not drawn)"),
        ("sources", "classify_sharing.py PREFIX.csv (true_A+true_B, false_A+false_B, no_prior_copy+unexplained, "
                    "ev_ns_true, ev_ns_false, searches; row role) or its --a6-dir export (writes.csv, "
                    "node<K>.log.csv, n_search.txt; cross-check join); column method"),
        ("tags", "events and dur_ns measured (trace); class derived (offline join by sequence numbers, no cross-VM "
                 "clock); per-search values derived"),
        ("inputs", "see the source column"),
    ], ["update_share_pct", "N_search", "events", "false", "true", "excluded", "false_per_search", "true_per_search",
        "false_time_share", "method", "source"], rows)
    print(f"-> {png}\n-> {csvp}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("panel", choices=("a", "b", "c"))
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--pop", nargs="*", help="3b: Popcorn runs SHARE=DIR[:STEPS] (contrast)")
    ap.add_argument("--search-op", default="search")
    ap.add_argument("--role", default="search", help="3c: classify_sharing.py row (search, writer, main, all)")
    ap.add_argument("--update-op", default="update")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    {"a": fig_a, "b": fig_b, "c": fig_c}[a.panel](a)


if __name__ == "__main__":
    main()

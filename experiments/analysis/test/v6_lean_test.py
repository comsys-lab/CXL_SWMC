#!/usr/bin/env python3
"""Host unit test (no servers, no shared memory) of v6_common.op_sums with Megalon >= 76 lean sampling
(reports/M2-megalon-port-changes.md §18): hand-computed cases on synthetic loadgen run dirs, one per flag convention
(vector DB opt.<op>.meg.flags, KV/LMDB opt.meg_lean / opt.meg_events_always, recsys op.<op>.mg.flags), the
events_always case, a legacy (no flags) case, a missing write_sampled denominator, and a mixed-mode refusal.
usage: python3 v6_lean_test.py <scratch dir (must not exist)>"""
import contextlib, io, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import v6_common as v6  # noqa: E402

fails = 0


def check(c, what):
    global fails
    print(("ok  " if c else "FAIL"), what)
    if not c:
        fails += 1


def close(a, b):
    return abs(a - b) <= 1e-6 * max(1.0, abs(b))


def mkrun(d, workload, nodes):
    """nodes: [(begin gauges, end kv)] per target; counters start at 0 in the begin snapshot, gauges as given."""
    os.makedirs(os.path.join(d, "stats"))
    with open(os.path.join(d, "manifest.txt"), "w") as f:
        f.write(f"workload={workload}\nslo=x:99:1\n")
    with open(os.path.join(d, "steps.jsonl"), "w") as f:
        f.write(json.dumps({"step": 1, "phase": "fixed", "offered_x": 1, "measure_s": 1, "x": 1, "pass": True,
                            "streams": {}}) + "\n")
    for t, (bg, end) in enumerate(nodes):
        b = {k: 0 for k in end}
        b.update(bg)
        for when, kv in (("begin", b), ("end", end)):
            with open(os.path.join(d, "stats", f"step001-{when}-t{t}.txt"), "w") as f:
                f.write(f"# when={when} phase=fixed step=1 target={t} mono_ns={0 if when == 'begin' else 10**9}\n")
                f.writelines(f"{k}={v}\n" for k, v in kv.items())
    return d


def sums(d, op, system="mg"):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        s, used, _ = v6.op_sums(v6.Run(d, system), [1], op)
    return s, used, err.getvalue()


def opt(op, kv):
    return {f"opt.{op}.{k}": v for k, v in kv.items()}


def main():
    S = sys.argv[1]
    os.makedirs(S)

    # ---- 1. vector DB (rule plain), flags opt.search.meg.flags (begin 0, end 3: read from the END snapshot), 2 nodes,
    # different ratios per node (per-node estimators)
    n0 = {"ops": 100, "t_ns": 10**7, "meg.read_sections": 640, "meg.check_sampled": 10, "meg.check_ns_sampled": 1000,
          "meg.anchor.read_sections": 640, "meg.anchor.check_sampled": 10, "meg.anchor.read_lookup_ns_sampled": 200,
          "meg.anchor.read_nr_ns_sampled": 100, "meg.stale_ns": 50, "meg.concur_ns": 10, "meg.meta_ns": 0,
          "meg.spin_ns": 5, "meg.write_sections": 128, "meg.anchor.write_sections": 128, "meg.anchor.write_sampled": 2,
          "meg.wstart_ns": 300, "meg.switch_rw_ns": 100, "meg.wflush_ns": 700, "meg.anchor.write_lookup_ns": 40,
          "meg.anchor.write_nr_ns": 20, "meg.anchor.wseq_ns": 30, "meg.anchor.wseq_end_ns": 10,
          "meg.vcopy_ns_sampled": 80, "meg.vcopy_sampled": 10, "meg.vcopy_cnt": 640, "meg.flags": 3}
    n1 = {"ops": 100, "t_ns": 10**7, "meg.read_sections": 300, "meg.check_sampled": 3, "meg.check_ns_sampled": 600,
          "meg.anchor.read_sections": 300, "meg.anchor.check_sampled": 3, "meg.stale_ns": 20,
          "meg.write_sections": 10, "meg.anchor.write_sampled": 5, "meg.wstart_ns": 100, "meg.wflush_ns": 50,
          "meg.flags": 3}
    vd = {"opt.meg_coh": 1}
    d1 = mkrun(os.path.join(S, "vdb-lean"), "vectordb",
               [({"opt.search.meg.flags": 0}, {**vd, **opt("search", n0)}),
                ({"opt.search.meg.flags": 0}, {**vd, **opt("search", n1)})])
    s, used, _ = sums(d1, "search")
    # node0: fr = fw = 64: check 1000*64 + anchor rd (200+100)*64 = 83200; vcopy 80*640/10 = 5120; events 65*64 = 4160;
    #        wstart (300 + 40 + 20)*64 = 23040; wflush 700*64 = 44800 -> 160320
    # node1: fr = 100, fw = 2: check 60000; events 2000; wstart 200; wflush 100 -> 62300
    check(close(s["C"], 222620), f"vdb lean C = 222620 (got {s['C']})")
    check(close(s["meg_stale_ns"], 5200) and s["meg_stale_ns_timed"] == 70, "vdb lean stale scaled per node, raw kept")
    check(close(s["meg_switch_rw_ns"], 6400), "vdb lean switch_rw x write ratio (Fig 3a column)")
    check(close(s["meg_wseq_ns"], 1920), "vdb lean anchor wseq x write ratio")
    check(s["meg_lean_nodes"] == 2 and s["meg_events_always_nodes"] == 0 and s["lean_est_missing_nodes"] == 0,
          "vdb lean node counters")
    check(used.get("meg_flags") == "opt.<op>.meg.flags", "vdb flags key recorded in sources")

    # ---- 2. legacy (Megalon <= 75): node0 of case 1 without flags and write_sampled -> unchanged formulas
    leg = {k: v for k, v in n0.items() if k not in ("meg.flags", "meg.anchor.write_sampled")}
    d2 = mkrun(os.path.join(S, "vdb-legacy"), "vectordb", [({}, {**vd, **opt("search", leg)})])
    s, used, _ = sums(d2, "search")
    # 64000 + 19200 + 5120 + 65 + (300 + 60) + 700 = 89445
    check(close(s["C"], 89445) and s["meg_lean_nodes"] == 0 and "meg_stale_ns_timed" not in s,
          f"legacy C = 89445, no scaling (got {s['C']})")
    check(isinstance(s["meg_stale_ns"], int) and "meg_flags" not in used, "legacy sums stay integers, no flags source")

    # ---- 3. KV (rule hwcc_flavor), opt.meg_lean = 1 (process-wide gauge)
    kvn = {"ops": 100, "t_ns": 2000000, "meg.read_sections": 100, "meg.check_sampled": 10, "meg.write_sections": 100,
           "meg.anchor.write_sampled": 4, "meg.check_ns_sampled": 10000, "meg.anchor.rseq_ns_sampled": 2000,
           "meg.anchor.read_lookup_ns_sampled": 3000, "meg.anchor.read_nr_ns_sampled": 4000, "meg.stale_ns": 500,
           "meg.wstart_ns": 12000, "meg.anchor.wseq_ns": 4000, "meg.wflush_ns": 8000, "meg.anchor.wseq_end_ns": 2000,
           "meg.anchor.write_lookup_ns": 2800, "meg.anchor.write_nr_ns": 3200}
    g = {"opt.meg_coh": 1, "opt.meg_check_sample": 64, "opt.meg_lean": 1, "opt.meg_events_always": 0}
    d3 = mkrun(os.path.join(S, "kv-lean"), "kv", [(g, {**g, **opt("get", kvn)})])
    s, used, _ = sums(d3, "get")
    # fr = 10, fw = 25: check (10000 - 2000)*10 = 80000; events 5000; wstart (12000 - 4000)*25 = 200000;
    # wflush (8000 - 2000)*25 = 150000 -> 435000 (= kv opsplit 4.35 us/op on the same numbers)
    check(close(s["C"], 435000), f"kv lean C = 435000 (got {s['C']})")
    check(used.get("meg_flags") == "opt.meg_lean", "kv flags from opt.meg_lean")

    # ---- 4. KV with MEGALON_COH_EVENTS=always: every section timed -> full sums, no scaling
    ga = dict(g, **{"opt.meg_events_always": 1})
    kva = dict(kvn, **{"meg.anchor.write_sampled": 100})
    d4 = mkrun(os.path.join(S, "kv-always"), "kv", [(ga, {**ga, **opt("get", kva)})])
    s, _, err = sums(d4, "get")
    # check 80000 (sampled checks keep their estimator) + events 500 + wstart 8000 + wflush 6000 = 94500
    check(close(s["C"], 94500) and s["meg_events_always_nodes"] == 1 and not err, f"kv always C = 94500 (got {s['C']})")
    kvb = dict(kvn)  # write_sampled 4 != write_sections 100 under events_always: warned, still full sums
    d4b = mkrun(os.path.join(S, "kv-always-bad"), "kv", [(ga, {**ga, **opt("get", kvb)})])
    s, _, err = sums(d4b, "get")
    check(close(s["C"], 94500) and "events_always but write_sampled" in err, "kv always write_sampled mismatch warned")

    # ---- 5. recsys (rule plain), op.<op>.mg.* keys, flags op.<op>.mg.flags
    rn = {"op.row_update.n": 10, "op.row_update.t_ns": 100000, "op.row_update.mg.read_sections": 20,
          "op.row_update.mg.check_sampled": 2, "op.row_update.mg.check_ns_sampled": 100,
          "op.row_update.mg.anchor.read_lookup_ns_sampled": 10, "op.row_update.mg.anchor.read_nr_ns_sampled": 10,
          "op.row_update.mg.write_sections": 10, "op.row_update.mg.anchor.write_sampled": 1,
          "op.row_update.mg.wstart_ns": 50, "op.row_update.mg.wflush_ns": 30,
          "op.row_update.mg.anchor.write_lookup_ns": 5, "op.row_update.mg.anchor.write_nr_ns": 5,
          "op.row_update.mg.flags": 3, "op.coh_src": "mg_threads:4"}
    d5 = mkrun(os.path.join(S, "recsys-lean"), "recsys", [({"op.row_update.mg.flags": 3}, rn)])
    s, used, _ = sums(d5, "row_update")
    # fr = 10, fw = 10: check (100 + 10 + 10)*10 = 1200; wstart (50 + 5 + 5)*10 = 600; wflush 300 -> 2100
    check(close(s["C"], 2100), f"recsys lean C = 2100 (got {s['C']})")
    check(used.get("meg_flags") == "op.<op>.mg.flags", "recsys flags key")

    # ---- 6. lean, write side timed but write_sampled missing: estimate unknown -> 0 and counted
    m6 = {"ops": 10, "t_ns": 10**6, "meg.read_sections": 10, "meg.check_sampled": 1, "meg.check_ns_sampled": 5,
          "meg.write_sections": 10, "meg.wstart_ns": 100, "meg.flags": 3}
    d6 = mkrun(os.path.join(S, "vdb-missing"), "vectordb", [({}, {**vd, **opt("update", m6)})])
    s, _, err = sums(d6, "update")
    check(close(s["C"], 50) and s["lean_est_missing_nodes"] == 1 and "lean_est_missing_nodes" in err,
          f"missing write_sampled: C = 50, node counted (got {s['C']})")

    # ---- 7. nodes with sections disagree on the mode (lean vs legacy) -> refused
    d7 = mkrun(os.path.join(S, "vdb-mixed"), "vectordb",
               [({}, {**vd, **opt("search", n0)}), ({}, {**vd, **opt("search", leg)})])
    try:
        sums(d7, "search")
        check(False, "mixed lean/legacy nodes refused")
    except SystemExit as e:
        check("disagree on Megalon lean" in str(e), "mixed lean/legacy nodes refused")

    # ---- 8. Fig 2 end to end: the lean KV run (case 3) beside hw / pop runs: C_meg_ns per op and the megalon_lean
    # metadata line (absent for data without flags, so older outputs stay byte-identical)
    import csv, subprocess
    # (every real server exports opt.<op>.c_ns; Fig 2 reads it as the audit column)
    d8 = mkrun(os.path.join(S, "kv-lean-fig2"), "kv", [(g, {**g, **opt("get", dict(kvn, c_ns=0))})])
    hw = mkrun(os.path.join(S, "kv-hw"), "kv", [({}, opt("get", {"ops": 100, "t_ns": 1000000, "c_ns": 0}))])
    pp = {"opt.pop_threads": 1}
    pop = mkrun(os.path.join(S, "kv-pop"), "kv", [(pp, {**pp, **opt("get", {"ops": 100, "t_ns": 3000000,
                                                                        "c_ns": 100000, "pop.is_ns": 100000})})])
    out = os.path.join(S, "fig2")
    p = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "v6_fig2_split.py"), "--out", out,
                        "--tag", "t", f"L1:hw={hw}", f"L1:pop={pop}", f"L1:mg={d8}"], capture_output=True, text=True)
    check(p.returncode == 0, "fig2 exit 0" + ("" if p.returncode == 0 else ": " + p.stderr[-300:]))
    if p.returncode == 0:
        lines = open(os.path.join(out, "t-fig2.csv")).read().splitlines()
        meta = [l for l in lines if l.startswith("# megalon_lean:")]
        rows = list(csv.DictReader(l for l in lines if not l.startswith("#")))
        mg = [r for r in rows if r["system"] == "Megalon"]
        check(len(meta) == 1 and "L1:mg:get lean_nodes=1" in meta[0], "fig2 megalon_lean line names the lean run")
        check(len(mg) == 1 and close(float(mg[0]["C_meg_ns"]), 4350.0), "fig2 Megalon C per op = 4350 ns")
    d9 = mkrun(os.path.join(S, "kv-mg-legacy"), "kv", [({"opt.meg_coh": 1}, {"opt.meg_coh": 1, **opt("get", {
        "ops": 100, "t_ns": 2000000, "meg.read_sections": 100, "meg.check_sampled": 10, "meg.check_ns_sampled": 100, "c_ns": 1000})})])
    out = os.path.join(S, "fig2-legacy")
    p = subprocess.run([sys.executable, os.path.join(os.path.dirname(HERE), "v6_fig2_split.py"), "--out", out,
                        "--tag", "t", f"L1:hw={hw}", f"L1:pop={pop}", f"L1:mg={d9}"], capture_output=True, text=True)
    check(p.returncode == 0 and "megalon_lean" not in open(os.path.join(out, "t-fig2.csv")).read(),
          "fig2 without flag keys: no megalon_lean line")

    print("PASS" if not fails else f"{fails} FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

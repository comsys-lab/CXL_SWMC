#!/usr/bin/env python3
"""Host unit test (no servers, no shared memory) of the MOT1 v6 analysis modules on synthetic loadgen run dirs:
both per-op naming conventions (opt.* KV/LMDB, op.* recsys), formulas of Fig 1, 2, 3a-c, 4a-b.
usage: python3 v6_selftest.py <scratch dir (must not exist)>"""
import csv, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
AN = os.path.dirname(HERE)
fails = 0


def check(c, what):
    global fails
    if not c:
        fails += 1
        print("FAIL", what)


def mkrun(d, slo, steps, snaps):
    """steps: [(step, phase, offered, x, pslo_ms, pass)]; snaps: {step: [(begin kv, end kv) per target]}."""
    os.makedirs(os.path.join(d, "stats"))
    st, pct, ms = slo
    with open(os.path.join(d, "manifest.txt"), "w") as f:
        f.write(f"target=a:1\ntarget=b:1\nslo={st}:{pct}:{ms}\n")
    with open(os.path.join(d, "summary.json"), "w") as f:
        json.dump({"slo": {"stream": st, "pct": pct, "ms": ms}}, f)
    with open(os.path.join(d, "steps.jsonl"), "w") as f:
        f.write(json.dumps({"step": 0, "phase": "warmup", "offered_x": 1, "measure_s": 0, "x": 0, "pass": False,
                            "streams": {st: {"achieved": 0, "pslo_ms": 0}}}) + "\n")
        for s, ph, off, x, p, ok in steps:
            f.write(json.dumps({"step": s, "phase": ph, "offered_x": off, "measure_s": 5, "x": x, "pass": ok,
                                "streams": {st: {"achieved": x, "pslo_ms": p}, "bg": {"achieved": 1, "pslo_ms": 0}}}) + "\n")
    for s, pairs in snaps.items():
        for t, (b, e) in enumerate(pairs):
            for when, kv in (("begin", b), ("end", e)):
                with open(os.path.join(d, "stats", f"step{s:03d}-{when}-t{t}.txt"), "w") as f:
                    f.write(f"# when={when} phase=fixed step={s} target={t} mono_ns={0 if when == 'begin' else 5e9:.0f}\n")
                    for k, v in kv.items():
                        f.write(f"{k}={v}\n")


def pair(end, gauges=None):
    b = {k: 0 for k in end}
    b.update(gauges or {})
    e = dict(end)
    e.update(gauges or {})
    return b, e


def run(*args):
    p = subprocess.run([sys.executable] + list(args), capture_output=True, text=True)
    if p.returncode:
        print(p.stdout, p.stderr)
    check(p.returncode == 0, "exit 0: " + " ".join(os.path.basename(x) for x in args[:2]))
    return p.stdout


def rows(path):
    lines = [l for l in open(path) if not l.startswith("#")]
    return list(csv.DictReader(lines)), [l for l in open(path) if l.startswith("#")]


def main():
    S = sys.argv[1]
    os.makedirs(S)
    out = os.path.join(S, "figs")
    # ---- KV-style (opt.*): hw, pop, mg; one fixed step 1 + a ramp for Fig 1
    curve = [(1, "fixed", 1000, 990, 0.2, True)]
    ramp = [(2, "ramp", 500, 499, 0.1, True), (3, "ramp", 2000, 1990, 0.3, True), (4, "confirm", 2000, 1980, 9, True),
            (5, "overload", 4000, 3000, 2.0, False)]
    kv = lambda op, ops, t, c, extra: {f"opt.{op}.ops": ops, f"opt.{op}.t_ns": t, f"opt.{op}.c_ns": c,  # noqa: E731
                                       **{f"opt.{op}.{k}": v for k, v in extra.items()}}
    hw = {**kv("get", 1000, 1_000_000, 0, {}), **kv("put", 100, 500_000, 0, {})}
    pop = {**kv("get", 1000, 3_000_000, 1_500_000, {"pop.is_ns": 1_000_000, "pop.sm_ns": 0, "pop.wp_ns": 0,
                                                    "pop.ipi_ns": 500_000, "pop.is_cnt": 50}),
           **kv("put", 100, 1_000_000, 400_000, {"pop.is_ns": 0, "pop.sm_ns": 300_000, "pop.wp_ns": 100_000, "pop.ipi_ns": 0})}
    meg = {**kv("get", 1000, 2_000_000, 0, {"meg.check_ns_sampled": 1000, "meg.stale_ns": 100_000, "meg.concur_ns": 0,
                                            "meg.meta_ns": 0, "meg.spin_ns": 0, "meg.wstart_ns": 0, "meg.wflush_ns": 0}),
           **kv("put", 100, 600_000, 0, {"meg.check_ns_sampled": 0, "meg.stale_ns": 0, "meg.wstart_ns": 20_000,
                                         "meg.wflush_ns": 30_000, "meg.wflush_bytes": 100 * 4096})}
    g = {"opt.meg_check_sample": 64, "opt.tsc_hz": 2_000_000_000, "opt.threads": 14}
    for name, end in (("hw", hw), ("pop", pop), ("mg", meg)):
        mkrun(os.path.join(S, f"kv-{name}"), ("mixed", 99, 1), curve + ramp, {1: [pair(end, g), pair(end, g)]})
    # Fig 1
    run(os.path.join(AN, "v6_fig1_curves.py"), "--out", out, "--tag", "kv", *[f"{k}={S}/kv-{k}" for k in ("hw", "pop", "mg")])
    r, meta = rows(os.path.join(out, "kv-fig1.csv"))
    check(len(r) == 12 and not any(x["phase"] == "confirm" for x in r), "fig1: 4 curve steps x 3, confirm left out")
    base = [x for x in r if x["system"] == "All HWcc" and x["offered"] == "500"][0]
    check(float(base["y_norm"]) == 1.0, "fig1: base = all-HWcc lowest offered rate")
    check(any("SLO 1.0 ms -> 10.0000" in m for m in meta) and any(m.startswith("# formula") for m in meta), "fig1 meta")
    check(os.path.exists(os.path.join(out, "kv-fig1.png")), "fig1 png")
    # Fig 2 (one load label, all three systems; two nodes each)
    run(os.path.join(AN, "v6_fig2_split.py"), "--out", out, "--tag", "kv", *[f"weak:{k}={S}/kv-{k}" for k in ("hw", "pop", "mg")])
    r, meta = rows(os.path.join(out, "kv-fig2.csv"))
    d = {(x["op"], x["system"]): x for x in r}
    f = lambda o, s, k: float(d[(o, s)][k])  # noqa: E731
    check(f("get", "All HWcc", "T_ns") == 1000 and f("get", "All HWcc", "norm_C") == 0, "fig2 hw get T = 1 us, C = 0")
    check(f("get", "Popcorn", "C_ns") == 1500 and f("get", "Popcorn", "norm_C") == 1.5 and f("get", "Popcorn", "norm_rest") == 1.5,
          "fig2 pop get C = (is + ipi) / ops, normalized to hw T")
    check(f("put", "Popcorn", "C_ns") == 4000 and f("put", "Popcorn", "norm_T") == 2.0, "fig2 pop put C = sm + wp")
    check(f("get", "Megalon", "C_ns") == (1000 * 64 + 100_000) / 1000, "fig2 meg get C = check x 64 + stale (per node)")
    check(f("put", "Megalon", "C_ns") == 500 and f("put", "Megalon", "ops") == 200, "fig2 meg put C = wstart + wflush; ops over 2 nodes")
    check(f("get", "Popcorn", "c_exported_ns") == f("get", "Popcorn", "C_ns"), "fig2 audit c_ns")
    check(os.path.exists(os.path.join(out, "kv-fig2-weak.png")), "fig2 png")
    # ---- recsys-style (op.*): Popcorn, Fig 4a/4b; op.query.n must be differenced (counter), check_sample a gauge
    q = {"op.query.n": 200, "op.query.t_ns": 20_000_000, "op.query.c_ns": 0, "op.query.pc.fault_ns.is": 2_000_000,
         "op.query.pc.fault_ns.sm": 100_000, "op.query.pc.fault_ns.wp": 100_000, "op.query.pc.ipi_ns": 200_000,
         "op.query.pc.fault_cnt.is": 400, "op.row_update.n": 10, "op.row_update.t_ns": 1_000_000,
         "sys.swmc.instr.fault_read.sum_ns": 4_000_000, "sys.swmc.instr.fault_read.count": 400,
         "sys.swmc.instr.tx_fetch.wait_sum_ns": 3_000_000, "sys.swmc.instr.serve_fetch.handle_sum_ns": 800_000,
         "sys.swmc.instr.serve_fetch.handle_count": 400, "sys.swmc.instr.serve.mkclean_ns": 200_000,
         "sys.swmc.instr.serve.wb_flush_ns": 400_000, "sys.swmc.instr.fault_read.lt_8192": 390,
         "sys.swmc.instr.fault_read.lt_65536": 10}
    for load in ("avg", "peak"):
        mkrun(os.path.join(S, f"rs-{load}"), ("query", 95, 100), curve, {1: [pair(q, {"op.query.mg.check_sample": 64})]})
    run(os.path.join(AN, "v6_fig4_popcorn.py"), "a", "--out", out, "--tag", "rs", f"avg={S}/rs-avg", f"peak={S}/rs-peak")
    r, meta = rows(os.path.join(out, "rs-fig4a.csv"))
    x = r[0]
    check(float(x["F_us"]) == 10 and float(x["W_us"]) == 7.5 and float(x["local_us"]) == 2.5, "fig4a local = F - W")
    check(float(x["H_us"]) == 2 and float(x["transport_us"]) == 5.5 and x["H_src"] == "owner sums", "fig4a transport = W - H")
    check(float(x["mkclean_us"]) == 0.5 and float(x["wbflush_us"]) == 1 and float(x["reply_rest_us"]) == 0.5, "fig4a owner")
    check(float(x["F_p99_us"]) == 65.536 and float(x["is_faults_per_query"]) == 2, "fig4a p99 = upper bound of the bucket holding rank 396 of 400")
    run(os.path.join(AN, "v6_fig4_popcorn.py"), "b", "--out", out, "--tag", "rs", f"avg={S}/rs-avg", f"peak={S}/rs-peak")
    r, _ = rows(os.path.join(out, "rs-fig4b.csv"))
    x = r[0]
    check(float(x["N_query"]) == 200 and float(x["is_us"]) == 10 and float(x["sm_wp_us"]) == 1 and float(x["ipi_us"]) == 1,
          "fig4b per query (op.query.n differenced)")
    # ---- vector DB Megalon, Fig 3a/3b (op.* names search/update), 3c trace
    for share in (0, 10):
        v = {"op.search.n": 1000, "op.search.t_ns": 9e6, "op.search.mg.check_ns_sampled": 1000, "op.search.mg.stale_ns": 2e6,
             "op.search.mg.stale_cnt": 20, "op.search.mg.concur_ns": 1e6, "op.search.mg.meta_ns": 0, "op.search.mg.spin_ns": 5e5}
        if share:
            v.update({"op.update.n": 100, "op.update.t_ns": 5e6, "op.update.mg.wstart_ns": 1e5, "op.update.mg.wflush_ns": 4e5,
                      "op.update.mg.wflush_bytes": 100 * 32 * 2**20, "op.update.mod_bytes": 100 * 4096})
        mkrun(os.path.join(S, f"vdb-{share}"), ("search", 99, 100), curve, {1: [pair(v, {"op.search.mg.check_sample": 64})]})
    run(os.path.join(AN, "v6_fig3_megalon.py"), "a", "--out", out, "--tag", "vdb", f"0={S}/vdb-0", f"10={S}/vdb-10")
    r, _ = rows(os.path.join(out, "vdb-fig3a.csv"))
    x = r[1]
    check(float(x["check_us"]) == 0.064 and float(x["stale_A_us"]) == 2 and float(x["spin_D_us"]) == 0.5, "fig3a search parts")
    check(float(x["wstart_us"]) == 1 and float(x["wflush_us"]) == 4 and r[0]["wflush_us"] == "", "fig3a update parts")
    run(os.path.join(AN, "v6_fig3_megalon.py"), "b", "--out", out, "--tag", "vdb", f"10={S}/vdb-10")
    r, _ = rows(os.path.join(out, "vdb-fig3b.csv"))
    check(float(r[0]["writeback_bytes_per_update"]) == 32 * 2**20 and float(r[0]["modified_bytes_per_update"]) == 4096, "fig3b")
    t = os.path.join(S, "trace10")
    os.makedirs(t)
    open(os.path.join(t, "writes.csv"), "w").write("object,element,wseq\nO1,e1,1\nO1,e2,2\nO1,e3,5\n")
    open(os.path.join(t, "node0.log.csv"), "w").write(
        "kind,object,a,b,c\nE,O1,A,0,2,100\nR,O1,e9,,\nR,O1,e2,,\nE,O1,B,2,5,300\nR,O1,e1,,\nE,O1,A,5,5,50\n")
    open(os.path.join(t, "n_search.txt"), "w").write("10\n")
    run(os.path.join(AN, "v6_fig3_megalon.py"), "c", "--out", out, "--tag", "vdb", f"10={t}")
    r, _ = rows(os.path.join(out, "vdb-fig3c.csv"))
    check(r[0]["events"] == "3" and r[0]["true"] == "1" and r[0]["false"] == "2", "fig3c: e2 in {e1,e2} true; e1 not in {e3}")
    check(abs(float(r[0]["false_time_share"]) - 350 / 450) < 1e-4, "fig3c false time share")
    print("PASSED" if not fails else f"{fails} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Host unit test (no servers): Fig 1 past-SLO points (user: latency curves include the points past the SLO).
paper_style.curve must draw every failed / overload step (hollow markers, no merge / drop / cut-off), join the overload
steps after the passing curve, grow the y axis up to 2x and put the rest on the top edge; v6_fig1_curves.py marks them
in the CSV column past_slo and names the column after the run's SLO percentile (p95 for DLRM).
usage: python3 fig1_past_test.py <scratch dir (must not exist)> [SYS=RUN_DIR ...]   (stored runs: read-only check that
       every failed / overload step is drawn)"""
import csv, json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
AN = os.path.dirname(HERE)
sys.path.insert(0, AN)
import v6_common as v6  # noqa: E402
import v6_fig1_curves as f1  # noqa: E402
import paper_style as ps  # noqa: E402

fails = 0


def check(c, what):
    global fails
    print(("ok  " if c else "FAIL"), what)
    if not c:
        fails += 1


def main():
    S = sys.argv[1]
    os.makedirs(S)
    # 1. synthetic: 5 passing points, past points: a failed one below the max passing x (bisect), two overload steps
    #    (one passing below the SLO, one at 6.0), one at 50 and one infinite; given top 4 -> axis 8, 9 / 50 / inf off scale
    xs = [1, 2, 3, 4, 5, 3.5, 5.2, 5.5, 5.8, 6.0]
    ys = [1, 1.1, 1.2, 1.3, 1.5, 9.0, 1.8, 6.0, 50.0, float("inf")]
    ok = [True] * 5 + [False, True, False, False, False]  # 5.2 is a passing overload step
    tail = [False] * 6 + [True] * 4
    d = ps.curve(os.path.join(S, "syn.png"), [("All HWcc", xs, ys, ok, tail)], 2.0, "x", "y", (0, 4), [0, 2, 4, 6],
                 [0, 1, 2, 3, 4])
    c = d["series"]["All HWcc"]
    check(c["passing"] == 5 and c["past"] == 4 and c["tail"] == 4 and c["tail_passing"] == 1,
          f"every past point drawn hollow, overload tail 4 incl. 1 passing (filled) ({c})")
    check(d["ylim"][1] == 8 and c["off_scale"] == 3, f"y grows to 2x top (8); 9, 50, inf on the edge ({d})")
    d = ps.curve(os.path.join(S, "syn-fixed.png"), [("All HWcc", xs, ys, ok, tail)], 2.0, "x", "y", (0, 4), [0, 2, 4, 6],
                 [0, 1, 2, 3, 4], extend_y=False)
    check(d["ylim"][1] == 4 and d["series"]["All HWcc"]["off_scale"] == 4, "fixed --ylim: no growth, 4 off scale")
    d = ps.curve(os.path.join(S, "syn-old.png"), [("Megalon", xs[:5], ys[:5])], 2.0, "x", "y", (0, 4), [0, 2, 4, 6],
                 [0, 1, 2, 3, 4])
    check(d["series"]["Megalon"]["past"] == 0 and d["ylim"][1] == 4, "3-tuple series unchanged (no past points)")

    # 2. v6_fig1_curves.py on a synthetic p95 run: CSV column p95_ms, past_slo for failed and overload steps
    run = os.path.join(S, "run")
    os.makedirs(run)
    with open(os.path.join(run, "manifest.txt"), "w") as f:
        f.write("workload=recsys\nslo=query:95:100\n")
    steps = [(1, "ramp", 10, 10, 20, True), (2, "ramp", 20, 20, 40, True), (3, "ramp", 40, 30, 300, False),
             (4, "bisect", 30, 28, 90, True), (5, "confirm", 28, 28, 80, True), (6, "overload", 31, 29, 95, True),
             (7, "overload", 33, 29.5, 400, False)]
    with open(os.path.join(run, "steps.jsonl"), "w") as f:
        f.write(json.dumps({"step": 0, "phase": "warmup", "offered_x": 1, "measure_s": 0, "x": 0, "pass": False,
                            "streams": {"query": {"achieved": 0, "pslo_ms": 0}}}) + "\n")
        for st, ph, off, x, p, okk in steps:
            f.write(json.dumps({"step": st, "phase": ph, "offered_x": off, "measure_s": 5, "x": x, "pass": okk,
                                "streams": {"query": {"achieved": x, "pslo_ms": p}}}) + "\n")
    p = subprocess.run([sys.executable, os.path.join(AN, "v6_fig1_curves.py"), "--out", os.path.join(S, "f1"),
                        "--tag", "t", "--xscale", "1", f"hw={run}"], capture_output=True, text=True)
    check(p.returncode == 0, "fig1 exit 0" + ("" if not p.returncode else ": " + p.stderr[-300:]))
    if not p.returncode:
        lines = open(os.path.join(S, "f1", "t-fig1.csv")).read().splitlines()
        r = list(csv.DictReader(l for l in lines if not l.startswith("#")))
        check("p95_ms" in r[0] and "past_slo" in r[0], "CSV columns p95_ms and past_slo")
        past = {int(x["step"]) for x in r if x["past_slo"] == "True"}
        check(past == {3, 7} and len(r) == 6, f"past_slo = failed steps only {sorted(past)}; confirm excluded")

    # 3. stored runs (read-only): every failed / overload curve step is drawn as a past-SLO point
    specs = sys.argv[2:]
    if specs:
        series, want = [], {}
        for spec in specs:
            k, dpath, _ = v6.parse_spec(spec)
            pts = sorted(f1.points(v6.Run(dpath, k), "x"), key=lambda q: q["x"])
            past = [not q["pass"] for q in pts]
            name = v6.SYSTEMS[k]
            series.append((name, [q["x"] / 1e3 for q in pts], [q["p_ms"] / pts[0]["p_ms"] for q in pts],
                           [not q for q in past], [q["phase"] == "overload" for q in pts]))
            want[name] = (sum(past), sum(q["phase"] == "overload" for q in pts),
                          sum(q["phase"] == "overload" and q["pass"] for q in pts))
        xmax = max(x for s in series for x in s[1])
        d = ps.curve(os.path.join(S, "stored.png"), series, 2.0, "x", "y", (0, 4), v6.nice_ticks(xmax * 1.05, 6),
                     [0, 1, 2, 3, 4])
        for name, (npast, nover, nop) in want.items():
            c = d["series"][name]
            check(c["past"] == npast and c["tail"] == nover and c["tail_passing"] == nop,
                  f"stored {name}: {npast} failed steps drawn hollow ({c['past']}), {nover} overload steps in the tail "
                  f"({nop} passing, filled)")
    print("PASS" if not fails else f"{fails} FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

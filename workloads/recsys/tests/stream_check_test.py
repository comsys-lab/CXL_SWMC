#!/usr/bin/env python3
"""Unit test of experiments/recsys/stream_check.py on synthetic loadgen dirs (no server).
Cases: valid steps -> PASS; written < 0.98 x accepted at the result -> NOTE; Poisson shortfall of sent vs nominal
(written = accepted = 0.95 x R) -> PASS; backlog growth -> NOTE; invalid step
above the result only -> PASS; missing snapshots at the result -> FAIL; batch-mode server -> FAIL.
usage: python3 -I stream_check_test.py   (prints STREAM CHECK TEST PASS or FAIL)"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SC = os.path.join(HERE, "..", "..", "..", "experiments", "recsys", "stream_check.py")
fails = 0


def mk(root, steps, best, mode="stream"):
    lg = os.path.join(root, "loadgen")
    os.makedirs(os.path.join(lg, "stats"))
    with open(os.path.join(lg, "steps.jsonl"), "w") as f:
        for st in steps:
            n, ph, x, ok, R = st["n"], st["phase"], st["x"], st["pass"], st["R"]
            f.write(json.dumps({"step": n, "phase": ph, "offered_x": x, "measure_s": 10, "pass": ok,
                                "streams": {"update": {"offered": R}, "query": {"offered": x}}}) + "\n")
            if st.get("nostats"):
                continue
            for when, (t, pub, acc, lag) in (("begin", st["b"]), ("end", st["e"])):
                with open(os.path.join(lg, "stats", f"step{n:03d}-{when}-t0.txt"), "w") as g:
                    g.write(f"# when={when}\n" + (f"update_mode={mode}\n" if mode else "") + f"stats_mono_ns={t}\npublished_seq={pub}\n"
                            f"update_accepted_seq={acc}\nrows_written={pub * 200}\nupdate_lag_samples={lag}\n"
                            f"update_lag_ns_sum={pub * 1000000}\nupdate_lag_n={pub * 14}\nupdate_lag_ns_max=5000000\n"
                            "update_queue.w0=0\nupdate_queue.w1=3\n")
    s = {"note": ""}
    if best is not None:
        s.update(max_offered_x_pass=best, low_rate_violations=[{"offered_x": 1}])
    json.dump(s, open(os.path.join(lg, "summary.json"), "w"))


def step(n, ph, x, ok, R=400, written=1.0, sent=1.0, lag=None, nostats=False):
    """10 s window. written / sent: fractions of the nominal R x 10 s written / accepted; lag = (begin, end) backlog
    (then accepted = written + growth). Consistent counters: accepted_seq = published_seq + backlog."""
    T = 10 * 10**9
    pub = int(R * 10 * written)
    if lag is None:
        acc = int(R * 10 * sent)
        lag = (0, acc - pub)
    else:
        acc = pub + lag[1] - lag[0]
    return {"n": n, "phase": ph, "x": x, "pass": ok, "R": R, "nostats": nostats,
            "b": (T * n, 1000, 1000 + lag[0], lag[0]), "e": (T * n + T, 1000 + pub, 1000 + pub + lag[1], lag[1])}


def run(name, steps, best, want, mode="stream"):
    global fails
    d = tempfile.mkdtemp(prefix="sct-")
    mk(d, steps, best, mode)
    p = subprocess.run([sys.executable, "-I", SC, d], capture_output=True, text=True)
    last = [l for l in p.stdout.splitlines() if l.startswith("STREAMCHECK")]
    got = last[0].split()[1] if last else "none"
    ok = got == want
    fails += not ok
    print(("ok   " if ok else "FAIL ") + f"{name}: {got} (want {want}) {last[0][:160] if last else p.stdout + p.stderr}")


base = [step(0, "ramp", 1, False), step(1, "ramp", 2.25, True), step(2, "ramp", 5, True), step(3, "ramp", 6, False),
        step(4, "confirm", 5, True), step(5, "confirm", 5, True), step(6, "confirm", 5, True)]
run("all valid", base, 5, "PASS")
b = [dict(s) for s in base]; b[5] = step(5, "confirm", 5, True, written=0.95)
run("written 95% of accepted at the result", b, 5, "NOTE")
b = [dict(s) for s in base]; b[5] = step(5, "confirm", 5, True, written=0.95, sent=0.95)
run("Poisson: 95% of nominal sent, all written", b, 5, "PASS")
b = [dict(s) for s in base]; b[2] = step(2, "ramp", 5, True, lag=(10, 900))
run("backlog grows 10 -> 900 below the result", b, 5, "NOTE")
b = [dict(s) for s in base]; b[2] = step(2, "ramp", 5, True, lag=(10, 60))
run("backlog +50 (written 98.8 % of accepted)", b, 5, "PASS")
b = [dict(s) for s in base]; b[3] = step(3, "ramp", 6, False, written=0.5)
run("invalid only above the result", b, 5, "PASS")
b = [dict(s) for s in base]; b[4] = step(4, "confirm", 5, True, nostats=True)
run("no snapshots at the result", b, 5, "FAIL")
run("batch-mode server (no update_mode key)", base, 5, "FAIL", mode=None)
b = [dict(s) for s in base]; b[2] = step(2, "ramp", 5, True, lag=(2500, 2510))
run("backlog flat but 2510 > 5 s of updates", b, 5, "NOTE")
run("no SLO result", base, None, "NOTE")
# u0 (main-block.sh header "U0"): update offered 0; valid only with zero accepted / published / written rows
u0 = [step(s["n"], s["phase"], s["x"], s["pass"], R=0) for s in base]
run("u0: no update accepted or written", u0, 5, "PASS")
b = [dict(s) for s in u0]; b[5]["e"] = (b[5]["e"][0], 1005, 1005, 0)
run("u0: 5 samples accepted and written at the result", b, 5, "NOTE")
print("STREAM CHECK TEST " + ("FAIL (%d)" % fails if fails else "PASS"))
sys.exit(1 if fails else 0)

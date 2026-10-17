#!/usr/bin/env python3
"""Host unit test (no servers, no shared memory) of the Megalon C difference method (user decision 2026-10-17,
state/TASKS.md "(a) 차분 방식으로 진행해"): v6_common.meg_diff / check_timers_off and v6_fig2_split.py --megalon-c diff,
hand-computed: C_diff split, negative C_diff (WARN, no clamp), missing / timers-on mgoff refused, mix refused, Megalon
on the common Popcorn kernel (swmc_acct registered, idle) accepted, old path only when requested.
usage: python3 v6_cdiff_test.py <scratch dir (must not exist)>"""
import csv, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
AN = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, AN)
import v6_common as v6  # noqa: E402
from v6_lean_test import mkrun, opt, close  # noqa: E402

fails = 0


def check(c, what):
    global fails
    print(("ok  " if c else "FAIL"), what)
    if not c:
        fails += 1


def mk(S, name, kv, mix="5"):
    d = mkrun(os.path.join(S, name), "vectordb", [({}, kv)])
    with open(os.path.join(d, "manifest.txt"), "a") as f:
        f.write(f"mix.search=95\nmix.update={mix}\n")
    return d


def fig2(S, tag, specs, *extra):
    p = subprocess.run([sys.executable, os.path.join(AN, "v6_fig2_split.py"), *extra, "--out", os.path.join(S, "out"),
                        "--tag", tag] + specs, capture_output=True, text=True)
    rows, meta = [], {}
    path = os.path.join(S, "out", f"{tag}-fig2.csv")
    if p.returncode == 0:
        lines = open(path).read().splitlines()
        meta = {l[2:].split(":", 1)[0]: l for l in lines if l.startswith("# ")}
        rows = {r["system"]: r for r in csv.DictReader(l for l in lines if not l.startswith("#"))}
    return p, rows, meta


def main():
    S = sys.argv[1]
    os.makedirs(S)
    mgk = {"opt.meg_coh": 1, "opcoh.pop_source": "swmc_acct"}  # Megalon on the common Popcorn kernel (idle swmc_acct)
    hw = mk(S, "hw", opt("get", {"ops": 100, "t_ns": 1_000_000, "c_ns": 0}))
    pop = mk(S, "pop", {"opt.pop_threads": 1, **opt("get", {"ops": 100, "t_ns": 1_200_000, "c_ns": 50_000,
                                                             "pop.is_ns": 50_000})})
    on = {"ops": 100, "t_ns": 1_400_000, "c_ns": 0, "meg.read_sections": 640, "meg.check_sampled": 10,
          "meg.check_ns_sampled": 500, "meg.stale_ns": 8000, "pop.is_ns": 0, "pop.ipi_ns": 0}
    mg = mk(S, "mg", {**mgk, **opt("get", on)})
    off = {"ops": 100, "t_ns": 1_300_000, "c_ns": 0, "meg.read_sections": 640, "meg.check_sampled": 0,
           "meg.check_ns_sampled": 0, "meg.stale_ns": 0, "pop.is_ns": 0}
    mgoff = mk(S, "mgoff", {**mgk, **opt("get", off)})
    base = [f"L1:hw={hw}", f"L1:pop={pop}", f"L1:mg={mg}"]

    # 1. hand case: T hw 10000, T off 13000 -> C_diff 3000 ns/op; timers-on sampled terms per op: check 500 x 64 / 100
    #    = 320, stale 8000 / 100 = 80 (sum 400) -> parts 3000 x 320/400 = 2400, 3000 x 80/400 = 600; Popcorn C 500,
    #    T(pop) - T(hw) = 2000
    p, r, meta = fig2(S, "a", base + [f"L1:mgoff={mgoff}"])
    check(p.returncode == 0, "diff exit 0" + ("" if not p.returncode else ": " + p.stderr[-300:]))
    m = r.get("Megalon (timers off)", {})
    f = lambda row, k: float(row[k])  # noqa: E731
    check(m and f(m, "T_ns") == 13000 and f(m, "C_ns") == 3000 and f(m, "C_diff_ns") == 3000 and f(m, "rest_ns") == 10000,
          "Megalon (timers off) row: T 13000, C = C_diff 3000, rest 10000")
    check(m and f(m, "part_check_ns") == 2400 and f(m, "part_stale_ns") == 600 and f(m, "part_wstart_ns") == 0,
          "C_diff split by the sampled terms")
    check(m and f(m, "sampled_check_ns") == 320 and f(m, "sampled_stale_ns") == 80 and f(m, "C_sampled_ns") == 400
          and f(m, "T_mg_on_ns") == 14000, "sampled terms raw, T(mg on) kept")
    check(f(r["Popcorn"], "C_ns") == 500 and f(r["Popcorn"], "pop_T_minus_hw_ns") == 2000, "Popcorn C from counters + T diff")
    check("UPPER BOUND" in meta.get("megalon_c", "") and meta.get("warnings", "").endswith("none"), "upper bound stated")

    # 2. negative C_diff: T off 9000 -> -1000, WARN, no clamp
    neg = mk(S, "mgoff-neg", {**mgk, **opt("get", dict(off, t_ns=900_000))})
    p, r, meta = fig2(S, "b", base + [f"L1:mgoff={neg}"])
    m = r.get("Megalon (timers off)", {})
    check(p.returncode == 0 and f(m, "C_diff_ns") == -1000 and f(m, "rest_ns") == 10000 and "C_diff<0" in m["warn"]
          and "C_diff<0" in meta.get("warnings", "") and "WARN" in p.stderr, "negative C_diff reported, WARN, no clamp")
    check(close(f(m, "part_check_ns"), -800), "negative C_diff split too (-1000 x 320/400)")

    # 3. no mgoff: refused (no silent fallback); the old path only on request
    p, _, _ = fig2(S, "c", base)
    check(p.returncode != 0 and "missing runs" in p.stderr and "mgoff" in p.stderr, "missing timers-off run refused")
    p, r, _ = fig2(S, "c2", base, "--megalon-c", "sampled")
    check(p.returncode == 0 and f(r["Megalon"], "C_ns") == 400, "--megalon-c sampled: old definition (C 400)")
    p, _, _ = fig2(S, "c3", base + [f"L1:mgoff={mgoff}"], "--megalon-c", "sampled")
    check(p.returncode != 0 and "bad run spec" in p.stderr, "old path rejects mgoff specs")

    # 4. a timers-on run given as mgoff: refused
    p, _, _ = fig2(S, "d", base + [f"L1:mgoff={mg}"])
    check(p.returncode != 0 and "timers were ON" in p.stderr, "timers-on run as mgoff refused")

    # 5. different mix: refused
    mx = mk(S, "mgoff-mix", {**mgk, **opt("get", off)}, mix="10")
    p, _, _ = fig2(S, "e", base + [f"L1:mgoff={mx}"])
    check(p.returncode != 0 and "workload/mix" in p.stderr, "different mix refused")

    # 6. Megalon run with live Popcorn activity: still refused (mixed sources)
    bad = mk(S, "mg-popactive", {**mgk, **opt("get", dict(on, **{"pop.is_ns": 5}))})
    p, _, _ = fig2(S, "f", [f"L1:hw={hw}", f"L1:pop={pop}", f"L1:mg={bad}", f"L1:mgoff={mgoff}"])
    check(p.returncode != 0 and "coherence source" in p.stderr, "Megalon run with Popcorn activity refused")

    # 7. meg_diff unit: no sampled terms -> no split + sanity WARN; sampled > T -> WARN only
    d0 = v6.meg_diff(13000, 10000, {"ops": 1, "t_ns": 14000})
    check(d0["C_diff"] == 3000 and d0["part_check"] is None and any("<= 0" in w for w in d0["warn"]), "sampled 0: no split")
    d1 = v6.meg_diff(13000, 10000, {"ops": 1, "t_ns": 14000, "meg_check_C_ns": 20000})
    check(d1["part_check"] == 3000 and any("> T" in w for w in d1["warn"]), "sampled > T: WARN, split kept")

    print("PASS" if not fails else f"{fails} FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Format trial of the paper figures on the KV pilot (4M keys, put 5%): throughput vs normalized p99 and the
normalized serving-time breakdown in the pilot's fixed-load windows (identical rate for all three).
usage: paper_figs_kv_pilot.py --root <project root> --out <dir>"""
import argparse, csv, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paper_style as ps


def steps(d):
    return [r for r in csv.DictReader(open(os.path.join(d, "steps.csv"))) if r["stream"] == "mixed" and r["achieved"]
            and float(r["achieved"]) > 0 and r["phase"] in ("ramp", "bisect", "fill", "overload")]  # confirm repeats left out of the curve


def stats(d, step):
    rows = [r for r in csv.DictReader(open(os.path.join(d, "stats-steps.csv"))) if r["step"] == step]
    return lambda k: sum(float(r.get(k) or 0) for r in rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    R = os.path.join(a.root, "recovery")
    os.makedirs(a.out, exist_ok=True)
    D = {"all-HWcc": f"{R}/M5-pilot-kv-hm-v2.1/hw-u5-pslo", "Megalon": f"{R}/M5-pilot-kv-hm-v2.1/mg-u5-pslo",
         "Popcorn": f"{R}/M5-pilot-kv-pop-v2.2/pop-u5-pslo"}
    S = {k: sorted(steps(v), key=lambda r: float(r["achieved"])) for k, v in D.items()}
    hw0 = min(S["all-HWcc"], key=lambda r: float(r["offered"]))
    base = float(hw0["p99_ms"])
    rows, series = [], []
    for name in ("Popcorn", "Megalon", "HWcc"):
        xs = [float(r["achieved"]) / 1e3 for r in S[{"HWcc": "all-HWcc"}.get(name, name)]]
        ys = [float(r["p99_ms"]) / base for r in S[{"HWcc": "all-HWcc"}.get(name, name)]]
        series.append((name, xs, ys))
        rows += [[name, r["step"], r["phase"], r["offered"], r["achieved"], r["p99_ms"], round(y, 3), r["pass"]]
                 for r, y in zip(S[{"HWcc": "all-HWcc"}.get(name, name)], ys)]
    slo = 1.0 / base
    ps.curve(os.path.join(a.out, "kv-pilot-curve.png"), series, slo, "Requests per second (K)",
             "Normalized\np99 latency", *(lambda l: (l[0], list(range(0, 161, 20)), l[1]))(ps.nice_ylim(slo)))
    with open(os.path.join(a.out, "kv-pilot-curve.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([f"# p99 normalized to all-HWcc p99 at its lowest offered rate ({hw0['offered']} req/s): {base} ms; SLO 1 ms -> {slo:.3f}"])
        w.writerow(["system", "step", "phase", "offered", "achieved", "p99_ms", "p99_norm", "pass"])
        w.writerows(rows)

    # breakdown at one identical rate: the pilot's fixed-load windows (L = 0.5 x all-HWcc max = 64.3k req/s; page MSI
    # kept up with the rate but its window stopped at 25 s on the p99 SLO, stats kept)
    F = {k: v.replace("-pslo", "-pfix") for k, v in D.items()}
    m = {k: [r for r in csv.DictReader(open(os.path.join(F[k], "steps.csv"))) if r["stream"] == "mixed"][0] for k in F}
    o = float(m["all-HWcc"]["offered"])
    raw, out = {}, []
    for name in ("HWcc", "Megalon", "Popcorn"):
        key = {"HWcc": "all-HWcc"}.get(name, name)
        g = stats(F[key], m[key]["step"])
        n = g("mixed_reqs")
        svc = g("mixed_svc_ns") / n / 1e3
        if name == "Popcorn":
            f = lambda k: sum(g(f"thr.{t}.swmc.{k}") for t in ("kv-worker", "kv-conn")) / n / 1e3
            msg = f("read_msg_wait_ns") + f("write_msg_wait_ns")
            local = f("read_fault_ns") + f("write_fault_ns") - msg
            raw[name] = {"total": svc, "msg": msg, "local": local}
        else:
            raw[name] = {"total": svc}
        out.append([name, m[key]["step"], m[key]["offered"], m[key]["achieved"], round(svc, 3)]
                   + [round(raw[name].get(k, 0.0), 3) for k in ("total", "msg", "local")])
    # A partition of each system's own serving time (no subtraction across systems): time inside the page-fault
    # handler while waiting for the peer's reply / the rest of the handler / everything outside the handler.
    # Kernel per-thread counters cover dev_dax_swmc_insert (the coherence fault handler); all-HWcc and Megalon take
    # no coherence faults (the KV Megalon backend has no section timers, so its library time stays in the last part).
    comps = ["Remote reply wait", "Fault handling", "Request processing"]
    hw = raw["HWcc"]["total"]
    norm = {k: [r.get("msg", 0.0) / hw, r.get("local", 0.0) / hw,
                (r["total"] - r.get("msg", 0.0) - r.get("local", 0.0)) / hw] for k, r in raw.items()}
    ps.breakdown(os.path.join(a.out, "kv-pilot-breakdown.png"), [(k, norm[k]) for k in ("HWcc", "Megalon", "Popcorn")],
                 comps)
    with open(os.path.join(a.out, "kv-pilot-breakdown.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([f"# fixed-load windows at {o:.1f} req/s (identical offered rate); us per request; normalized to all-HWcc = 1"])
        w.writerow(["system", "step", "offered", "achieved", "svc_us", "total_us", "msg_us", "local_us"] + ["norm_" + c for c in comps])
        w.writerows([r + [round(x, 4) for x in norm[r[0]]] for r in out])
    print("common rate", o, "base p99", base, "SLO norm", round(slo, 3))


if __name__ == "__main__":
    main()

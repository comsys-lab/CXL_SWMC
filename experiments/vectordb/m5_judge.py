#!/usr/bin/env python3
"""M5 pilot judgement tables (reports/M5-pilot-packet.md; MOT1 v5 §3.3). Offline, Host only.

usage: m5_judge.py --out DIR [--eqA DIR --eqB DIR] [--h1 DIR] [--noise-floor 0.03]
Outputs:
  equivalence.csv  per system and kernel: confirm means of the pilot SLO searches; all-HWcc judgement:
                   EQUIVALENT when |mean(B) - mean(A)| <= max(range(A), range(B), noise_floor x mean(A)), else DIFFERENT
                   (range = max - min over the two repeats; noise floor 3%: the 1M pilot's run-to-run noise was
                   2-5 search/s at ~160); Megalon's difference is reported, not judged (one run per kernel)
  h1.csv           per system: max search/s under SLO (pilot), normalized to all-HWcc, H1 threshold (<= 0.70);
                   at L: mean search latency, increase over all-HWcc, coherence thread-time per search on the search
                   path (page MSI: vdb-search managed-fault time; Megalon: read-section checks (sampled, incl. refetch
                   flushes) + re-executed attempts, all threads), explained fraction = coherence / increase (MOT1
                   check >= 0.5), page MSI receive-thread vCPU (reported separately, not counted)
  judgement.txt    the same in words
Runs with a note (confirm failed) are flagged and not used.
"""
import argparse, csv, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import m4_figures as mf  # noqa: E402


def slo_x(d):
    s = json.load(open(os.path.join(d, "loadgen", "summary.json")))
    c = s.get("confirm", {})
    return (None if s.get("note") else c.get("x_mean")), s.get("note", ""), c.get("x_sd")


def at_load(d):
    s = mf.fixed_step(d)
    if not s:
        return None
    lat = mf.mean_latency_ms(d, s["step"], list(s["streams"]).index("search"))
    nodes = mf.node_rows(d, s["step"])
    searches = coh = recv = 0.0
    have = False
    win = 0
    for m, dv in nodes.values():
        searches += dv.get("searches") or 0
        win = max(win, m["window_s"] or 0)
        if m["pop_search_fault_s"] is not None:
            coh += m["pop_search_fault_s"]; have = True
        elif m["meg_rd_check_s"] is not None:
            coh += (m["meg_rd_check_s"] or 0) + (m["meg_reexec_s"] or 0); have = True
        recv += m["recv_cpu_s"] or 0
    return dict(lat=lat, coh_ms=(coh / searches * 1e3) if have and searches else (0.0 if searches else None),
                recv_vcpu=recv / win if win else None, search_per_s=s["streams"]["search"]["achieved"], rate=s["offered_x"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--eqA")
    ap.add_argument("--eqB")
    ap.add_argument("--h1")
    ap.add_argument("--noise-floor", type=float, default=0.03)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    words = []
    if a.eqA and a.eqB:
        rows, means = [], {}
        for tag, d in (("A", a.eqA), ("B", a.eqB)):
            for sysn, pre in (("all-HWcc", "hw"), ("Megalon", "mg")):
                vals = []
                for n in (1, 2):
                    rd = os.path.join(d, f"{pre}-u5-pslo-{tag.lower()}{n}")
                    if os.path.isdir(rd):
                        x, note, sd = slo_x(rd)
                        rows.append(dict(kernel=tag, system=sysn, run=os.path.basename(rd), x_mean=x, x_sd=sd, note=note))
                        if x:
                            vals.append(x)
                means[(tag, sysn)] = vals
        hA, hB = means.get(("A", "all-HWcc"), []), means.get(("B", "all-HWcc"), [])
        verdict = "INCOMPLETE"
        if len(hA) == 2 and len(hB) == 2:
            mA, mB = sum(hA) / 2, sum(hB) / 2
            tol = max(max(hA) - min(hA), max(hB) - min(hB), a.noise_floor * mA)
            verdict = "EQUIVALENT" if abs(mB - mA) <= tol else "DIFFERENT"
            words.append(f"equivalence all-HWcc: A {hA} mean {mA:.1f}, B {hB} mean {mB:.1f}, |diff| {abs(mB - mA):.1f} "
                         f"vs tolerance {tol:.1f} -> {verdict}")
        mgA, mgB = means.get(("A", "Megalon"), []), means.get(("B", "Megalon"), [])
        if mgA and mgB:
            words.append(f"equivalence Megalon (reported): A {mgA[0]:.1f}, B {mgB[0]:.1f}, B/A {mgB[0] / mgA[0]:.3f}")
        for r in rows:
            r["judgement"] = verdict if r["system"] == "all-HWcc" else "reported"
        mf.write(os.path.join(a.out, "equivalence.csv"), ["kernel", "system", "run", "x_mean", "x_sd", "note",
                 "judgement"], rows)
    if a.h1:
        rows = []
        base = {}
        for sysn, pre in (("all-HWcc", "hw"), ("page MSI", "pop"), ("Megalon", "mg")):
            sd = os.path.join(a.h1, f"{pre}-u5-pslo-h")
            fd = os.path.join(a.h1, f"{pre}-u5-pfix-h")
            x, note, xsd = slo_x(sd) if os.path.isdir(sd) else (None, "missing", None)
            f = at_load(fd) if os.path.isdir(fd) else None
            row = dict(system=sysn, search_per_s=x, sd_within=xsd, note=note)
            if f:
                row.update(lat_at_L_ms=f["lat"], coh_ms_per_search=f["coh_ms"], recv_vcpu=f["recv_vcpu"],
                           L_rate=f["rate"], search_per_s_at_L=f["search_per_s"])
            if sysn == "all-HWcc":
                base = row
            rows.append(row)
        for row in rows:
            bx, bl = base.get("search_per_s"), base.get("lat_at_L_ms")
            if row["search_per_s"] and bx:
                row["normalized"] = row["search_per_s"] / bx
                row["h1_le_0.70"] = row["normalized"] <= 0.70
            if row.get("lat_at_L_ms") is not None and bl is not None and row["system"] != "all-HWcc":
                inc = row["lat_at_L_ms"] - bl
                row["latency_increase_ms"] = inc
                if row.get("coh_ms_per_search") is not None and inc > 0:
                    row["explained_fraction"] = row["coh_ms_per_search"] / inc
                    row["check_ge_0.5"] = row["explained_fraction"] >= 0.5
            words.append(f"H1 {row['system']}: " + ", ".join(f"{k}={row[k]:.3g}" if isinstance(row.get(k), float) else
                         f"{k}={row.get(k)}" for k in ("search_per_s", "normalized", "h1_le_0.70", "lat_at_L_ms",
                         "latency_increase_ms", "coh_ms_per_search", "explained_fraction", "check_ge_0.5", "recv_vcpu",
                         "note")))
        mf.write(os.path.join(a.out, "h1.csv"), ["system", "search_per_s", "sd_within", "note", "normalized",
                 "h1_le_0.70", "L_rate", "search_per_s_at_L", "lat_at_L_ms", "latency_increase_ms",
                 "coh_ms_per_search", "explained_fraction", "check_ge_0.5", "recv_vcpu"], rows)
    open(os.path.join(a.out, "judgement.txt"), "w").write("\n".join(words) + "\n")
    print("\n".join(words))


if __name__ == "__main__":
    main()

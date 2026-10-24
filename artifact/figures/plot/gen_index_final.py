"""index.md + all-final.html for a final.py output dir. Usage: python3 -I -B gen_index_final.py <outdir>
Needs <outdir>/numbers.json of a full set (final.py --figs all; artifact/figures/all.sh)."""
import html
import json
import sys

OUT = sys.argv[1]
N = json.load(open(f"{OUT}/numbers.json"))
F, RUNS = N["figs"], N["runs"]
MIXES, NS = ("u10", "u50", "u90"), (2, 4, 8)
RUNTXT = (f"Runs {', '.join(map(str, RUNS))} of de-stijl-motivation-isca27 (eval2); bars and markers = mean over runs "
          "(always the mean; no min-max whiskers in the figures, min-max over runs in every CSV; user 2026-10-23). "
          "Hatched Megalon bars in Fig 5 carry the p99 RANGE over runs as text (e.g. '118-169 ms').")


def f(a, d=2):
    if a["v"] is None:
        return "n/a"
    s = f"{a['v']:.{d}f}" if abs(a["v"]) < 1e4 else f"{a['v']:,.0f}"
    lo = f"{a['lo']:.{d}f}" if abs(a["lo"]) < 1e4 else f"{a['lo']:,.0f}"
    hi = f"{a['hi']:.{d}f}" if abs(a["hi"]) < 1e4 else f"{a['hi']:,.0f}"
    return f"{s} [{lo}-{hi}]" + ("m" if a["stat"] == "median" else "")


src = "; ".join(f"run {k}: {v['h1_export']} ({', '.join(v['h1_evidence'])}), {v['h2_export']} "
                f"({', '.join(v['h2_evidence'])})" for k, v in N["sources"].items() if k != "knee_sweep")
if "knee_sweep" in N["sources"]:
    ks = N["sources"]["knee_sweep"]
    src += f"; knee sweep: plan {ks['plan']}, exports {', '.join(ks['exports'])}"
f1, f5, f6, f7, f8 = F["fig1"], F["fig5"], F["fig6"], F["fig7"], F["fig8"]
PTS = ("Curve source: below 0.9 x base (base = mean confirmed max under SLO of runs 1-3, "
       "CXL_SWMC/experiments/eval/knee-sweep-plan.csv) run 1's SLO-search points (pool.py, 3 % pooling, shape filter); "
       "from 0.9 x base the knee-sweep fixed-rate points (1 repetition, 45 s windows, SLO early abort off; "
       "workspaces/knee-sweep/derived/*/knee-pilot.csv), only lifetime_ok = 1, aborted = 0, after_abort = 0. At and "
       "above the first sweep rate only sweep points are used: every run-1 point at >= 0.97 x the first sweep rate is "
       "dropped (no interleaving). The sweep part is drawn while achieved search/s still rises and stops at the first "
       "point more than 5 % below the max so far (user option a, 2026-10-24). Megalon floor panels "
       "(no rate met the SLO in run 1): run 1's lowest step, then the sweep points. y = p99 normalized to All-HWcc's "
       "run-1 p99 at its lowest offered rate, linear; points above the y top get no marker (the line leaves through "
       "the top edge). Every point with its source and drawn flag is in the CSV.")
H1MAX = (" Max under SLO, search/s, mean [min-max] over runs: " + "; ".join(
    f"{m} " + ", ".join(f"{k} {f(f1['max'][f'{m}-{k}'], 1)}" for k in ("hw", "pop", "mg")) for m in MIXES) +
    ". Ratio to All-HWcc: " + "; ".join(
    f"{m} Popcorn {f(f1['ratio'][f'{m}-pop'], 3)}, Megalon {f(f1['ratio'][f'{m}-mg'], 3)}" for m in MIXES) + ".")
H2MAX = (" Max under SLO, aggregate search/s, mean [min-max] over runs (N = 2 / 4 / 8): " + "; ".join(
    f"{m} " + ", ".join(k + " " + " / ".join(f(F['fig4_max'][f'{m}-n{n}-{k}'], 1) for n in NS) for k in ("hw", "pop", "mg"))
    for m in MIXES) + " (Megalon n/a = no passing rate in any run).")
REQ = (" x = achieved REQUESTS per second (search + update streams of the loadgen, aggregate over VMs), per point "
       "averaged over its steps with the pool.py window weights; same points and shape filter as the search/s version.")
figs = [("Fig 1 - latency-throughput (Hypothesis 1)", "fig1-h1-latency", "fig1-h1-latency.csv, fig1-h1-max-under-slo.csv",
         PTS + H1MAX),
        ("Fig 1 (requests/s) - latency-throughput (Hypothesis 1)", "fig1-h1-latency-req", "fig1-h1-latency-req.csv",
         PTS + REQ + H1MAX)]
for load in ("L1", "L2"):
    d = F["fig2"][load]
    figs.append((f"Fig 2 ({load}) - normalized search latency", f"fig2-h1-search-breakdown-{load}",
                 "fig2-h1-search-breakdown.csv",
                 f"Each run's own {load} window (L1 = Megalon's max under SLO of that run, L2 = L1/2); per run normalized to "
                 "that run's All-HWcc, then averaged; whisker = min-max of the total. Megalon = run without section timers, "
                 "coherence = its time - All-HWcc's (upper bound); Popcorn = kernel counters. Totals: " + "; ".join(
                     f"{m} Megalon {f(d[m]['mg']['T'])}, Popcorn {f(d[m]['pop']['T'], 3)}" for m in MIXES) +
                 ". Offered search/s per run: " + "; ".join(
                     f"{m} " + " / ".join(f"{x:.3g}" for x in d[m]["hw"]["offered"]) for m in MIXES) + "."))
    figs.append((f"Fig 3 ({load}) - average flushed cache lines per search", f"fig3-h1-flushed-lines-per-search-{load}",
                 "fig3-h1-flushed-lines-per-search.csv",
                 "fixed.csv fig3_lines_per_rop (search-only attribution), log y, mean with min-max. " + "; ".join(
                     f"{m} Megalon {f(F['fig3'][f'{load}-{m}-mg'], 0)}, Popcorn {f(F['fig3'][f'{load}-{m}-pop'], 1)}"
                     for m in MIXES) + ". All-HWcc = 0."))
figs.append(("Fig 4 - latency-throughput 3 x 3 (Hypothesis 2)", "fig4-h2-latency", "fig4-h2-latency.csv",
             PTS + H2MAX))
figs.append(("Fig 4 (requests/s) - latency-throughput 3 x 3 (Hypothesis 2)", "fig4-h2-latency-req",
             "fig4-h2-latency-req.csv", PTS + REQ + H2MAX))
AXES = (" Axes (user 2026-10-23): every axis ends at its last labeled tick, plain tick numbers (no scale factor); "
        "x range tight (~5 % headroom){row}; where all of a system's points lie above the SLO-based y top, the top is "
        "raised until that system's first point is inside, so the SLO sits lower than 80-90 % in: {raised}.")
for i, (title, img, c, cap) in enumerate(figs):
    key = {"fig1-h1-latency": "fig1", "fig1-h1-latency-req": "fig1", "fig4-h2-latency": "fig4",
           "fig4-h2-latency-req": "fig4"}.get(img)
    if key:
        inf = F[key]["panels"] if key == "fig1" else F[key]
        rz = [f"{p} (y top {v['y_top']:g}, SLO at {100 * v['slo_frac']:.0f} %)" for p, v in inf.items() if v.get("raised")]
        cl = [f"{p} {s} (collapsed step p99 {v['p'] / 1000:.1f} s, {v['src']})" for p, d in inf.items()
              for s, v in d.get("collapse", {}).items()]
        coll = (" Vertical unmarked segments (curve ended because the next measured step collapsed: aborted or "
                "throughput fell back, with its p99 above the y top): " + ("; ".join(cl) if cl else "none") + ".")
        if any("addendum" in x for x in cl):
            coll += (" Popcorn u90 N=4/8 combine the main sweep's stable points with the addendum lifetime's collapse; "
                     "the collapse point varies between lifetimes (N=8: the main sweep held 1.05 x base at p99 71 ms, "
                     "the addendum collapsed already at 1.00 x).")
        figs[i] = (title, img, c, cap + AXES.format(
            row=", shared by the three N panels of each row" if key == "fig4" else ", per panel",
            raised="; ".join(rz) or "none") + coll)
figs.append(("Fig 5 - max search/s under SLO (Hypothesis 2)", "fig5-h2-max-search-under-slo",
             "fig5-h2-max-search-under-slo.csv",
             "Mean with min-max; hatched = Megalon lowest ramp step (p99 range over runs above). " + "; ".join(
                 f"{m} N={n}: " + ", ".join(f"{k} {f(f5['values'][f'{m}-n{n}-{k}'], 1)}" for k in ("hw", "pop", "mg"))
                 for m in MIXES for n in NS) + ". Popcorn/All-HWcc: " + "; ".join(
                 f"{m} " + " / ".join(f(f5['pop_hw'][f'{m}-n{n}'], 3) for n in NS) for m in MIXES) + "."))
figs.append(("Fig 6a - Popcorn read/write faults per second vs N", "fig6a-h2-popcorn-faults-per-s",
             "fig6-h2-popcorn-faults.csv", "At each run's Popcorn max-under-SLO step; mean with min-max, log y. " + "; ".join(
                 f"{m} read " + " / ".join(f(f6[f'{m}-n{n}-read_per_s'], 0) for n in NS) + ", write " +
                 " / ".join(f(f6[f'{m}-n{n}-write_per_s'], 0) for n in NS) for m in MIXES) + "."))
figs.append(("Fig 6b - Popcorn read faults per search vs N", "fig6b-h2-popcorn-read-faults-per-search",
             "fig6-h2-popcorn-faults.csv", "Mean with min-max, log y. " + "; ".join(
                 f"{m} " + " / ".join(f(f6[f'{m}-n{n}-read_per_search'], 1) for n in NS) for m in MIXES) + "."))
figs.append(("Fig 7 - Megalon stale-object fetches per operation vs N", "fig7-h2-megalon-fetches-per-op",
             "fig7-h2-megalon-fetches-per-op.csv", "Mean with min-max, log y; hatched = lowest ramp step in at least one "
             "run. " + "; ".join(f"{m} " + " / ".join(f(f7[f'{m}-n{n}']) + ("*" if f7[f'{m}-n{n}']['hatched'] else "")
                                                     for n in NS) for m in MIXES) + " (* hatched)."))
COMP = (("query", "query processing"), ("rq", "run-queue delay"), ("e1", "E1 wait"), ("lock", "segment write-lock wait"),
        ("faults", "search page faults"))
for key, suffix, title, rule in (
        ("fig8", "", "Fig 8 - Popcorn search time by cause (100 % stacked, at Popcorn's max under SLO)",
         "Load = Popcorn's own max-under-SLO point of each (N, mix, run): its 90 s confirm window at the confirmed "
         "offered rate (steps.csv at_result step); no matching to All-HWcc is needed for a Popcorn-only share"),
        ("fig8_common", "-common-load", "Fig 8 (secondary) - same, same load in every run",
         "Load per (N, mix) = the highest ramp offered rate that both All-HWcc and Popcorn passed in EVERY run present "
         "(each run's shares computed at that rate, then averaged); cells without such a rate fall back to the per-run "
         "rule and are flagged"),
        ("fig8_perrun", "-perrun-load", "Fig 8 (secondary) - same, per-run per_n load",
         "Load = each run's own per_n step (highest ramp step both systems pass in that run); kept for comparison")):
    g8 = F[key]
    figs.append((title, f"fig8-h2-popcorn-search-time-share{suffix}",
                 f"fig8-h2-popcorn-search-time-share{suffix}.csv, fig8-h2-loads{suffix}.csv",
                 "Popcorn only; server search time W split as workspaces/fig8-cause/compare.py (per run by cause_agg.py): "
                 "search page faults = C + NT, segment write-lock wait, E1 (write-order) wait, run-queue delay, query "
                 f"processing = rest (incl. replay). {rule}. Offered ops/s per run: " + "; ".join(
                     f"{k} " + " / ".join(f"{x:.0f}" for x in v) + ("" if g8["rules"][k] in ("shared", "per-run", "confirm")
                                                                    else " (fallback)") for k, v in g8["loads"].items()) +
                 ". Mean shares over runs (renormalized to 100), min-max in the CSV. " + " ".join(
                     f"{m}: " + "; ".join(lab + " " + " / ".join(f(g8['shares'][f'{m}-n{n}-{k}'], 1) for n in NS)
                                          for k, lab in COMP) + "." for m in MIXES)))

BAND = ("Per run and system the curve is built exactly as in the point figures (pool.py: steps within 3 % offered rate "
        "pooled, shape filter, aborted steps kept; equal offered rates merged with mean x and max p99; p99 = inf held at "
        "1e6 ms). Each run's interpolated curve runs in offered order as long as its achieved search/s still rises "
        "(also past the knee, through the SLO crossing) and stops at the first step whose throughput falls back (> 2 % "
        "below the highest so far) or that the load generator aborted at its queue cap (saturated); steps stopped early "
        "because the SLO percentile was already exceeded are past-SLO measurements and stay on the curve. The runs are put on a common OFFERED-rate grid = the union of those offered rates; "
        "each run is interpolated in offered rate (achieved search/s linear, p99 in log space) only inside its own range "
        "(no extrapolation). At grid points covered by >= 2 runs: x = mean achieved search/s, line = mean normalized "
        "p99 (leaving through the top edge where p99 explodes), shaded band = min-max over runs (same gray, alpha "
        "0.25). Grid points covered by only one run are omitted. After a run's stop point its measured points are drawn "
        "as small circles in the system's gray, those above the top on the top edge. Normalization base per "
        "panel = mean over runs of All-HWcc's p99 at its lowest offered rate. Linear y, SLO at 80-90 % of the height. "
        "No point markers on the mean lines (deviation from STYLE.md: the grid is denser than any one run).")


def band_entry(key, title, img):
    b = F[key]
    single = {}
    for p, v in b.items():
        for s, c in v["single_run_points"].items():
            single[s] = single.get(s, 0) + c
    return (title, img, f"{img}.csv", BAND + " Omitted single-run grid points (all panels): " +
            ", ".join(f"{s} {c}" for s, c in single.items()) + ". Measured past-the-knee points on the top edge: " +
            "; ".join(f"{p}: " + ", ".join(f"{s} {c}" for s, c in v["clipped_past_knee"].items()) for p, v in b.items())
            + ".")


if "fig1_band" in F:
    figs.insert(2, band_entry("fig1_band", "Fig 1 (secondary, band) - latency-throughput, mean of all runs",
                              "fig1-h1-latency-band"))
    i4 = [i for i, x in enumerate(figs) if x[1] == "fig4-h2-latency-req"][0]
    figs.insert(i4 + 1, band_entry("fig4_band", "Fig 4 (secondary, band) - latency-throughput 3 x 3, mean of all runs",
                                   "fig4-h2-latency-band"))


def widest(cells, pp=False):
    """Largest run-to-run range over the figure's cells: relative (max-min)/mean, or in percentage points."""
    best = None
    for lab, a in cells:
        if a.get("v") in (None, 0) or a.get("lo") is None:
            continue
        r = a["hi"] - a["lo"] if pp else (a["hi"] - a["lo"]) / abs(a["v"])
        if best is None or r > best[0]:
            best = (r, lab, a)
    if best is None:
        return ""
    r, lab, a = best
    return (f" Bars = mean over runs (no whiskers; min-max in the CSV); largest run-to-run range: {lab} "
            f"{a['lo']:.4g}-{a['hi']:.4g} ({'%.1f percentage points' % r if pp else '%.0f %% of the mean' % (100 * r)}).")


RANGE = {
    "fig2-h1-search-breakdown-L1": [(f"{m} {s}", v["T"]) for m, d in F["fig2"]["L1"].items() for s, v in d.items()],
    "fig2-h1-search-breakdown-L2": [(f"{m} {s}", v["T"]) for m, d in F["fig2"]["L2"].items() for s, v in d.items()],
    "fig3-h1-flushed-lines-per-search-L1": [(k[3:], v) for k, v in F["fig3"].items() if k.startswith("L1")],
    "fig3-h1-flushed-lines-per-search-L2": [(k[3:], v) for k, v in F["fig3"].items() if k.startswith("L2")],
    "fig5-h2-max-search-under-slo": list(F["fig5"]["values"].items()),
    "fig6a-h2-popcorn-faults-per-s": [(k, v) for k, v in F["fig6"].items() if not k.endswith("read_per_search")],
    "fig6b-h2-popcorn-read-faults-per-search": [(k, v) for k, v in F["fig6"].items() if k.endswith("read_per_search")],
    "fig7-h2-megalon-fetches-per-op": list(F["fig7"].items()),
}
for key, suffix in (("fig8", ""), ("fig8_common", "-common-load"), ("fig8_perrun", "-perrun-load")):
    RANGE[f"fig8-h2-popcorn-search-time-share{suffix}"] = (list(F[key]["shares"].items()), True)
for i, (title, img, c, cap) in enumerate(figs):
    if img in RANGE:
        v = RANGE[img]
        cells, pp = v if isinstance(v, tuple) else (v, False)
        figs[i] = (title, img, c, cap.replace(" min-max in the CSV.", "").replace("Mean with min-max; ", "")
                   .replace("mean with min-max, ", "").replace("Mean with min-max, ", "")
                   .replace("; whisker = min-max of the total", "") + widest(cells, pp))
flags = N["flags"]
md = ["# de-stijl-motivation-isca27 final figure set", "", f"**{RUNTXT}**", "",
      "Regenerate: CXL_SWMC/artifact/figures/all.sh --reprocess (one figure: figN.sh). Flags: " + ("; ".join(flags) if flags else "none (no "
      "Rule E fallback, no mixed hatching, no missing Fig 8 counters)."), "",
      f"Sources: {src}", ""]
for title, img, c, cap in figs:
    md += [f"## {title}", "", f"Files: {img}.{{pdf,png}}; numbers {c}", "", f"Caption: {cap} {RUNTXT}", ""]
open(f"{OUT}/index.md", "w").write("\n".join(md))
h = ["<!doctype html><html><head><meta charset='utf-8'><title>ISCA27 final figures</title><style>"
     "body{font-family:sans-serif;max-width:1100px;margin:16px auto;padding:0 16px;background:#fff;color:#111}"
     "img{max-width:100%;border:1px solid #ddd}figure{margin:0 0 40px}figcaption{font-size:14px;line-height:1.45}"
     "</style></head><body>", "<h1>de-stijl-motivation-isca27: final figures</h1>",
     f"<p><b>{html.escape(RUNTXT)}</b></p>", f"<p>Flags: {html.escape('; '.join(flags) or 'none')}</p>"]
for title, img, c, cap in figs:
    h.append(f"<figure><h2>{html.escape(title)}</h2><img src='{img}.png' alt='{html.escape(title)}'>"
             f"<figcaption>{html.escape(cap)}<br><small>Numbers: {html.escape(c)}</small></figcaption></figure>")
h.append("</body></html>")
open(f"{OUT}/all-final.html", "w").write("\n".join(h))
print("index.md + all-final.html:", len(figs), "entries")

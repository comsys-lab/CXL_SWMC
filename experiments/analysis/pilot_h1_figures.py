#!/usr/bin/env python3
"""MOT1 v5 H1 pilot figures (HNSW 1M + KV 4M on Popcorn build 8), from the pilot evidence dirs.

Writes PNG figures and the CSV behind each into --out. Inputs are read-only:
  HNSW  recovery/M5-pilot-h1-v1.4/{hw,pop,mg}-u5-{pslo,pfix}-h
  KV    recovery/M5-pilot-kv-hm-v2.1/{hw,mg}-u{0,5,50}-{pslo,pfix}, recovery/M5-pilot-kv-pop-v2.2/pop-u{0,5,50}-{pslo,pfix}
Coherence time per HNSW search: time-share over search threads (user rule 2026-10-16):
  coh = (C_search / B_search) * S, S = mean server-side time per search (wait + replay + search).
KV is not intra-request parallel (one worker per request), so per-request = thread totals / requests.
usage: pilot_h1_figures.py --root <project root> --out <dir>
"""
import argparse, csv, json, os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SYS = [("hw", "all-HWcc", "#2a78d6"), ("pop", "page MSI", "#eb6834"), ("mg", "Megalon", "#1baf7a")]
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.size": 10, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2,
                     "ytick.color": INK2, "axes.facecolor": SURF, "figure.facecolor": SURF,
                     "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
                     "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True})


def summary(d):
    return json.load(open(os.path.join(d, "loadgen", "summary.json")))


def stats_sum(d):
    rows = list(csv.DictReader(open(os.path.join(d, "stats-steps.csv"))))
    def g(k):
        return sum(float(r.get(k) or 0) for r in rows)
    return g, rows


def steps(d, stream):
    out = []
    for r in csv.DictReader(open(os.path.join(d, "steps.csv"))):
        if r["stream"] == stream and r["phase"] in ("ramp", "bisect", "confirm") and r["achieved"]:
            out.append((float(r["achieved"]), float(r["p99_ms"]), r["pass"] == "True", r["phase"]))
    return out


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    R = os.path.join(a.root, "recovery")
    os.makedirs(a.out, exist_ok=True)
    hnsw = {s: os.path.join(R, "M5-pilot-h1-v1.4", f"{s}-u5-%s-h") for s, _, _ in SYS}
    def kv(s, u, k):
        blk = "M5-pilot-kv-pop-v2.2" if s == "pop" else "M5-pilot-kv-hm-v2.1"
        return os.path.join(R, blk, f"{s}-u{u}-{k}")

    # ---- Figure 1: normalized maximum throughput under SLO
    groups = [("HNSW\nupdate 5%", lambda s: hnsw[s] % "pslo"), ("KV\nput 0%", lambda s: kv(s, 0, "pslo")),
              ("KV\nput 5%", lambda s: kv(s, 5, "pslo")), ("KV\nput 50%", lambda s: kv(s, 50, "pslo"))]
    rows, norm = [], {}
    for gname, path in groups:
        base = summary(path("hw"))["max_offered_x_pass"]
        for s, label, _ in SYS:
            x = summary(path(s))["max_offered_x_pass"]
            norm[(gname, s)] = x / base
            rows.append([gname.replace("\n", " "), label, round(x, 1), round(x / base, 3)])
    write_csv(os.path.join(a.out, "fig1a-normalized-throughput.csv"),
              ["config", "system", "max_pass_rate", "normalized"], rows)
    fig, ax = plt.subplots(figsize=(7.2, 3.6))
    w = 0.26
    for i, (s, label, col) in enumerate(SYS):
        xs = [j + (i - 1) * (w + 0.02) for j in range(len(groups))]
        ys = [norm[(g, s)] for g, _ in groups]
        bars = ax.bar(xs, ys, w, color=col, label=label, edgecolor=SURF, linewidth=2)
        for x, y in zip(xs, ys):
            if s != "hw":
                ax.text(x, y + 0.02, f"{y:.2f}", ha="center", va="bottom", fontsize=8, color=INK)
    ax.axhline(0.70, color=INK2, linestyle="--", linewidth=1)
    ax.text(-0.45, 0.66, "H1 threshold 0.70", ha="left", va="top", fontsize=8, color=INK2)
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels([g for g, _ in groups])
    ax.set_ylim(0, 1.15)
    ax.set_ylabel("max throughput under SLO\n(normalized to all-HWcc)")
    ax.set_title("H1 pilot: maximum throughput under SLO (Popcorn build 8 kernel)", loc="left", fontsize=10)
    ax.legend(frameon=False, ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.18))
    fig.tight_layout()
    fig.savefig(os.path.join(a.out, "fig1a-normalized-throughput.png"), dpi=150)
    plt.close(fig)

    # ---- Figure 2: throughput vs p99 (SLO search steps)
    panels = [("HNSW, update 5% (search p99 SLO 100 ms)", lambda s: hnsw[s] % "pslo", "search", 100.0, 1.0, "search/s"),
              ("KV, put 5% (request p99 SLO 1 ms)", lambda s: kv(s, 5, "pslo"), "mixed", 1.0, 1e-3, "k requests/s"),
              ("KV, put 50% (request p99 SLO 1 ms)", lambda s: kv(s, 50, "pslo"), "mixed", 1.0, 1e-3, "k requests/s")]
    fig, axs = plt.subplots(1, 3, figsize=(11, 3.4))
    rows = []
    for ax, (title, path, stream, slo, xscale, xlab) in zip(axs, panels):
        for s, label, col in SYS:
            pts = sorted(steps(path(s), stream))
            for p in pts:
                rows.append([title, label, p[3], round(p[0], 1), round(p[1], 4), p[2]])
            ax.plot([p[0] * xscale for p in pts], [p[1] for p in pts], color=col, linewidth=2, marker="o",
                    markersize=4, label=label)
        ax.axhline(slo, color=INK2, linestyle="--", linewidth=1)
        ax.set_yscale("log")
        ax.set_title(title, loc="left", fontsize=9)
        ax.set_xlabel(xlab)
    axs[0].set_ylabel("p99 latency (ms, log)")
    axs[1].legend(frameon=False, ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.22))
    fig.tight_layout()
    fig.savefig(os.path.join(a.out, "fig1-curves-throughput-p99.png"), dpi=150)
    plt.close(fig)
    write_csv(os.path.join(a.out, "fig1-curves-throughput-p99.csv"),
              ["panel", "system", "phase", "achieved", "p99_ms", "pass"], rows)

    # ---- Figure 3: KV, where the serving time goes (per request at the fixed load L)
    comp = [("store work and request handling", "#c3c2b7"), ("FETCH wait (read fault, message)", "#eb6834"),
            ("read fault, local handling", "#f4a37f"), ("INVALIDATE wait (write fault, message)", "#6250d6"),
            ("write fault, local handling", "#a79bea")]
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.8), sharey=True)
    rows = []
    # put 50%: page MSI saturates at L (0.5 x all-HWcc > its own maximum), so its fixed-load window has no stats;
    # use, for every system, the passing SLO-search step closest to page MSI's maximum passing rate (same load).
    target50 = summary(kv("pop", 50, "pslo"))["max_offered_x_pass"]
    def step_stats(d, target):
        st = [r for r in csv.DictReader(open(os.path.join(d, "steps.csv"))) if r["stream"] == "mixed" and r["pass"] == "True"]
        best = min(st, key=lambda r: abs(float(r["offered"]) - target))
        rows = [r for r in csv.DictReader(open(os.path.join(d, "stats-steps.csv"))) if r["step"] == best["step"]]
        def g(k):
            return sum(float(r.get(k) or 0) for r in rows)
        return g, float(best["offered"])
    for ax, u in zip(axs, (5, 50)):
        labels = []
        for i, (s, label, col) in enumerate(SYS):
            if u == 50:
                g, rate = step_stats(kv(s, u, "pslo"), target50)
            else:
                g, _ = stats_sum(kv(s, u, "pfix"))
            reqs = g("mixed_reqs")
            svc = g("mixed_svc_ns") / reqs / 1e3
            parts = [svc, 0, 0, 0, 0]
            if s == "pop":
                rf = sum(g(f"thr.{t}.swmc.read_fault_ns") for t in ("kv-worker", "kv-conn")) / reqs / 1e3
                rw = sum(g(f"thr.{t}.swmc.read_msg_wait_ns") for t in ("kv-worker", "kv-conn")) / reqs / 1e3
                wf = sum(g(f"thr.{t}.swmc.write_fault_ns") for t in ("kv-worker", "kv-conn")) / reqs / 1e3
                ww = sum(g(f"thr.{t}.swmc.write_msg_wait_ns") for t in ("kv-worker", "kv-conn")) / reqs / 1e3
                parts = [max(svc - rf - wf, 0), rw, rf - rw, ww, wf - ww]
            bottom = 0
            for (cname, ccol), v in zip(comp, parts):
                if v > 0:
                    ax.bar(i, v, 0.6, bottom=bottom, color=ccol, edgecolor=SURF, linewidth=2,
                           label=cname if (u == 5 and s == "pop") else None)
                bottom += v
            ax.text(i, bottom + 0.8, f"{svc:.1f} µs", ha="center", va="bottom", fontsize=8, color=INK)
            rows.append([f"put {u}%", label, round(reqs), round(svc, 2)] + [round(p, 2) for p in parts])
            labels.append(label)
        ax.set_xticks(range(3))
        ax.set_xticklabels(labels)
        ax.set_title(f"KV, put {u}%, " + ("fixed load L = 0.5 x all-HWcc max (64.3k req/s)" if u == 5 else
                     f"SLO-search step near page MSI max (~{target50/1e3:.1f}k req/s)"), loc="left", fontsize=9)
    axs[0].set_ylabel("server time per request (µs)")
    h, l = axs[0].get_legend_handles_labels()
    fig.legend(h, l, frameon=False, ncol=3, loc="lower center", fontsize=8)
    fig.tight_layout(rect=(0, 0.12, 1, 1))
    fig.savefig(os.path.join(a.out, "fig3b-kv-where-serving-time-goes.png"), dpi=150)
    plt.close(fig)
    write_csv(os.path.join(a.out, "fig3b-kv-where-serving-time-goes.csv"),
              ["config", "system", "requests", "svc_us_per_req"] + [c for c, _ in comp], rows)

    # ---- Figure 4: page MSI requester wait per transaction (KV put 5% and 50%, fixed load)
    fig, ax = plt.subplots(figsize=(7.2, 3.4))
    rows = []
    cols = {"tx_fetch": "#eb6834", "tx_invalidate": "#6250d6"}
    _, keyrows = stats_sum(kv("pop", 5, "pfix"))
    for u, ls in ((5, "-"), (50, "--")):
        if u == 50:
            g, _ = step_stats(kv("pop", 50, "pslo"), target50)
            srows = keyrows
        else:
            g, srows = stats_sum(kv("pop", u, "pfix"))
        for tx in ("tx_fetch", "tx_invalidate"):
            buckets = sorted({int(k.rsplit("_lt_", 1)[1]) for k in srows[0] if k.startswith(f"sys.swmc.instr.{tx}.wait_lt_")})
            cnt = [g(f"sys.swmc.instr.{tx}.wait_lt_{b}") for b in buckets]
            tot = sum(cnt) or 1
            xs, ys, acc = [], [], 0
            for b, c in zip(buckets, cnt):
                acc += c
                xs.append(b / 1e3)
                ys.append(acc / tot)
                rows.append([f"put {u}%", tx, b, int(c)])
            mean = g(f"sys.swmc.instr.{tx}.wait_sum_ns") / max(g(f"sys.swmc.instr.{tx}.wait_count"), 1) / 1e3
            ax.step(xs, ys, where="post", color=cols[tx], linestyle=ls, linewidth=2,
                    label=f"{tx[3:].upper()} put {u}% (mean {mean:.1f} µs, n={int(g(f'sys.swmc.instr.{tx}.wait_count'))})")
    ax.set_xscale("log")
    ax.set_xlim(1, 1e4)
    ax.set_xlabel("requester wait per transaction (µs, log2 bucket upper bound)")
    ax.set_ylabel("cumulative fraction")
    ax.set_title("page MSI on KV: message wait per transaction (put 5% at L; put 50% near its max)", loc="left", fontsize=9)
    ax.legend(frameon=False, fontsize=7, loc="lower right")
    fig.tight_layout()
    fig.savefig(os.path.join(a.out, "fig-kv-pagemsi-wait-cdf.png"), dpi=150)
    plt.close(fig)
    write_csv(os.path.join(a.out, "fig-kv-pagemsi-wait-cdf.csv"), ["config", "tx", "bucket_lt_ns", "count"], rows)

    # ---- Figure 5: HNSW, server time per search at L with time-share coherence
    fig, ax = plt.subplots(figsize=(6.4, 3.4))
    rows = []
    gh, _ = stats_sum(hnsw["hw"] % "pfix")
    for i, (s, label, col) in enumerate(SYS):
        g, srows = stats_sum(hnsw[s] % "pfix")
        n = g("searches")
        S = (g("wait_ns_total") + g("replay_ns_total") + g("search_ns_total")) / n / 1e6
        B = g("search_busy_ns") / 1e9
        if s == "pop":
            C = (g("thr.vdb-search.swmc.read_fault_ns") + g("thr.vdb-search.swmc.write_fault_ns")) / 1e9
        elif s == "mg":
            C = sum((float(x["megt.rd_start_ns"]) + float(x["megt.rd_end_ns"])) * float(x["megalon.read_sections"])
                    / float(x["megt.rd_sampled"]) for x in srows) / 1e9
        else:
            C = 0.0
        coh = C / B * S if B else 0
        cap = max(B - gh("search_busy_ns") / 1e9, 0) / B * S if s != "hw" else 0
        ax.bar(i, S - coh, 0.6, color="#c3c2b7", edgecolor=SURF, linewidth=2, label="search work" if i == 0 else None)
        ax.bar(i, coh, 0.6, bottom=S - coh, color=col, edgecolor=SURF, linewidth=2)
        ax.text(i, S + 0.1, f"{S:.2f} ms" + (f"\ncoh {coh:.2f} ms (cap {cap:.2f})" if s != "hw" else ""),
                ha="center", va="bottom", fontsize=8, color=INK)
        rows.append([label, int(n), round(S, 3), round(C, 3), round(B, 2), round(coh, 4), round(cap, 4)])
    ax.set_xticks(range(3))
    ax.set_xticklabels([l for _, l, _ in SYS])
    ax.set_ylim(0, 9.5)
    ax.set_ylabel("server time per search (ms)")
    ax.set_title("HNSW, update 5%, fixed load: coherence share per search (time-share)", loc="left", fontsize=9)
    fig.tight_layout()
    fig.savefig(os.path.join(a.out, "fig1b-hnsw-search-time.png"), dpi=150)
    plt.close(fig)
    write_csv(os.path.join(a.out, "fig1b-hnsw-search-time.csv"),
              ["system", "searches", "server_ms_per_search", "C_search_s", "B_search_s", "coh_ms_timeshare", "coh_ms_capped"], rows)
    print("figures in", a.out)


if __name__ == "__main__":
    main()

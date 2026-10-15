#!/usr/bin/env python3
"""MOT1 v5 H1 pilot: exploratory figures over every measured step (SLO-search steps and fixed-load windows).

Same evidence dirs as pilot_h1_figures.py (read-only). Every SLO-search step has its own stats window, so most
figures plot a per-request (KV) or per-search (HNSW) quantity against the achieved load of that step.
Writes PNGs, one CSV per figure, and index.md (figure list with captions) into --out.
usage: pilot_h1_explore.py --root <project root> --out <dir>
"""
import argparse, csv, json, os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SYS = [("hw", "all-HWcc", "#2a78d6"), ("pop", "page MSI", "#eb6834"), ("mg", "Megalon", "#1baf7a")]
COL = {s: c for s, _, c in SYS}
LAB = {s: l for s, l, _ in SYS}
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
plt.rcParams.update({"font.size": 9, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2,
                     "ytick.color": INK2, "axes.facecolor": SURF, "figure.facecolor": SURF,
                     "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
                     "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True})
PUTS = (0, 5, 50)
INDEX = []


class Step:
    """One measurement window: loadgen row(s) + summed server stats rows (both nodes)."""

    def __init__(self, lg, srows):
        self.lg, self.srows = lg, srows
        self.step, self.phase = int(lg["step"]), lg["phase"]
        self.offered, self.achieved = float(lg["offered"] or 0), float(lg["achieved"] or 0)
        self.passed = lg["pass"] == "True"
        self.p50, self.p99 = float(lg["p50_ms"] or 0), float(lg["p99_ms"] or 0)

    def g(self, k):
        return sum(float(r.get(k) or 0) for r in self.srows)

    def gs(self, *ks):
        return sum(self.g(k) for k in ks)


def load(d, stream):
    st = {}
    p = os.path.join(d, "stats-steps.csv")
    if os.path.exists(p):
        for r in csv.DictReader(open(p)):
            st.setdefault(r["step"], []).append(r)
    out = []
    for r in csv.DictReader(open(os.path.join(d, "steps.csv"))):
        if r["stream"] == stream and r["step"] in st and float(r["achieved"] or 0) > 0:
            out.append(Step(r, st[r["step"]]))
    return sorted(out, key=lambda s: s.achieved)


def kvdir(R, s, u, k):
    blk = "M5-pilot-kv-pop-v2.2" if s == "pop" else "M5-pilot-kv-hm-v2.1"
    return os.path.join(R, blk, f"{s}-u{u}-{k}")


def hdir(R, s, k):
    return os.path.join(R, "M5-pilot-h1-v1.4", f"{s}-u5-{k}-h")


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def save(fig, out, name, caption, header=None, rows=None):
    fig.savefig(os.path.join(out, name + ".png"), dpi=140)
    plt.close(fig)
    if header:
        write_csv(os.path.join(out, name + ".csv"), header, rows)
    INDEX.append((name, caption))


def mark(ax, s, xs, ys, passed, **kw):
    """Line through all steps; passing steps filled, failing steps hollow."""
    ax.plot(xs, ys, color=COL[s], linewidth=1.6, label=LAB[s], **kw)
    for x, y, p in zip(xs, ys, passed):
        ax.plot([x], [y], marker="o", markersize=4.5, color=COL[s], markerfacecolor=COL[s] if p else SURF,
                markeredgewidth=1.4, linestyle="none")


def hist(st, prefix):
    """Delta histogram {upper_bound_ns: count} for keys '<prefix><bound>' summed over nodes."""
    ks = {k for r in st.srows for k in r if k.startswith(prefix)}
    h = {}
    for k in ks:
        try:
            b = int(k[len(prefix):])
        except ValueError:
            continue
        h[b] = st.g(k)
    return dict(sorted(h.items()))


def frac_over(h, ns):
    tot = sum(h.values()) or 1
    return sum(c for b, c in h.items() if b > ns) / tot


# ---------------------------------------------------------------- KV
def kv_figs(R, out):
    pslo = {(s, u): load(kvdir(R, s, u, "pslo"), "mixed") for s, _, _ in SYS for u in PUTS}
    pfix = {(s, u): load(kvdir(R, s, u, "pfix"), "mixed") for s, _, _ in SYS for u in PUTS}

    # K1 latency curves p50 / p99
    fig, axs = plt.subplots(2, 3, figsize=(12, 6), sharex="col")
    rows = []
    for j, u in enumerate(PUTS):
        for s, _, _ in SYS:
            st = pslo[(s, u)]
            xs = [x.achieved / 1e3 for x in st]
            mark(axs[0][j], s, xs, [x.p99 for x in st], [x.passed for x in st])
            mark(axs[1][j], s, xs, [x.p50 for x in st], [x.passed for x in st])
            rows += [[u, LAB[s], x.step, x.phase, round(x.achieved, 1), x.p50, x.p99, x.passed] for x in st]
        axs[0][j].axhline(1.0, color=INK2, linestyle="--", linewidth=1)
        for i in (0, 1):
            axs[i][j].set_yscale("log")
        axs[0][j].set_title(f"KV put {u}%", loc="left")
        axs[1][j].set_xlabel("achieved k requests/s")
    axs[0][0].set_ylabel("request p99 (ms, log)")
    axs[1][0].set_ylabel("request p50 (ms, log)")
    axs[0][0].legend(frameon=False)
    fig.suptitle("KV: latency vs load, every SLO-search step (hollow = step failed SLO)", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "kv-01-latency-curves", "KV p99 (top) and p50 (bottom) vs achieved load, all SLO-search steps.",
         ["put_pct", "system", "step", "phase", "achieved", "p50_ms", "p99_ms", "pass"], rows)

    # K2 server time per request vs load
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6), sharey=True)
    rows = []
    for j, u in enumerate(PUTS):
        for s, _, _ in SYS:
            st = [x for x in pslo[(s, u)] if x.g("mixed_reqs")]
            ys = [x.g("mixed_svc_ns") / x.g("mixed_reqs") / 1e3 for x in st]
            mark(axs[j], s, [x.achieved / 1e3 for x in st], ys, [x.passed for x in st])
            rows += [[u, LAB[s], x.step, round(x.achieved, 1), round(y, 2)] for x, y in zip(st, ys)]
        axs[j].set_title(f"KV put {u}%", loc="left")
        axs[j].set_xlabel("achieved k requests/s")
        axs[j].set_yscale("log")
    axs[0].set_ylabel("server time per request (µs, log)")
    axs[0].legend(frameon=False)
    fig.tight_layout()
    save(fig, out, "kv-02-server-time-vs-load", "KV server-side time per 16-op request (worker service, no queueing) vs load.",
         ["put_pct", "system", "step", "achieved", "svc_us_per_req"], rows)

    # K3 page MSI: where the serving time goes, stacked, vs load (every step)
    comp = [("store work + request handling", "#c3c2b7"), ("FETCH wait (read fault)", "#eb6834"),
            ("read fault, local", "#f4a37f"), ("INVALIDATE wait (write fault)", "#6250d6"),
            ("write fault, local", "#a79bea")]
    # write_fault_* include write-protect (upgrade) faults: the kernel accounts SWMC_FAULT_WP in both write_* and wp_*
    TH = ("kv-worker", "kv-conn")

    def pop_parts(x):
        n = x.g("mixed_reqs")
        f = lambda k: sum(x.g(f"thr.{t}.swmc.{k}") for t in TH) / n / 1e3
        svc = x.g("mixed_svc_ns") / n / 1e3
        rf, rw, wf, ww = f("read_fault_ns"), f("read_msg_wait_ns"), f("write_fault_ns"), f("write_msg_wait_ns")
        return svc, [max(svc - rf - wf, 0), rw, rf - rw, ww, wf - ww]

    fig, axs = plt.subplots(1, 3, figsize=(13, 3.9))
    rows = []
    for j, u in enumerate(PUTS):
        st = [x for x in pslo[("pop", u)] if x.g("mixed_reqs")]
        P = [pop_parts(x) for x in st]
        xs = list(range(len(st)))
        bottom = [0] * len(st)
        for ci, (cn, cc) in enumerate(comp):
            v = [p[1][ci] for p in P]
            axs[j].bar(xs, v, 0.75, bottom=bottom, color=cc, edgecolor=SURF, linewidth=1, label=cn if j == 0 else None)
            bottom = [b + w for b, w in zip(bottom, v)]
        axs[j].set_xticks(xs)
        axs[j].set_xticklabels([f"{x.achieved/1e3:.1f}" + ("" if x.passed else "✗") for x in st], rotation=60, fontsize=7)
        axs[j].set_title(f"page MSI, KV put {u}%", loc="left")
        axs[j].set_xlabel("achieved k requests/s (✗ = failed SLO)")
        rows += [[u, x.step, round(x.achieved, 1), x.passed, round(p[0], 2)] + [round(v, 3) for v in p[1]] for x, p in zip(st, P)]
    axs[0].set_ylabel("server time per request (µs)")
    fig.legend(*axs[0].get_legend_handles_labels(), frameon=False, ncol=5, loc="lower center", fontsize=8)
    fig.tight_layout(rect=(0, 0.07, 1, 1))
    save(fig, out, "kv-03-pagemsi-breakdown-vs-load",
         "page MSI KV: per-request server time split into fault components, for every SLO-search step (sorted by load).",
         ["put_pct", "step", "achieved", "pass", "svc_us"] + [c for c, _ in comp], rows)

    # K4 where the serving time goes, all three systems, at a common load for every put ratio
    def near(st, target):
        ok = [x for x in st if x.passed and x.g("mixed_reqs")]
        return min(ok, key=lambda x: abs(x.achieved - target))
    fig, axs = plt.subplots(1, 4, figsize=(14, 3.9), sharey=False)
    rows = []
    cfgs = [(u, 19.2e3, "~19k req/s (all pass)") for u in PUTS] + [(5, 64.3e3, "64.3k req/s (fixed load L)")]
    for ax, (u, target, tl) in zip(axs, cfgs):
        for i, (s, _, _) in enumerate(SYS):
            if target > 60e3:
                x = pfix[(s, u)][0]
            else:
                x = near(pslo[(s, u)], target)
            if s == "pop":
                svc, parts = pop_parts(x)
            else:
                svc = x.g("mixed_svc_ns") / x.g("mixed_reqs") / 1e3
                parts = [svc, 0, 0, 0, 0]
            b = 0
            for (cn, cc), v in zip(comp, parts):
                if v > 0:
                    ax.bar(i, v, 0.6, bottom=b, color=cc,
                           edgecolor=SURF, linewidth=1.5)
                b += v
            ax.text(i, b, f"{svc:.1f}", ha="center", va="bottom", fontsize=8)
            rows.append([u, tl, LAB[s], round(x.achieved, 1), x.p99, round(svc, 2)] + [round(v, 3) for v in parts])
        ax.set_xticks(range(3))
        ax.set_xticklabels([l for _, l, _ in SYS], fontsize=8)
        ax.set_title(f"put {u}%, {tl}", loc="left", fontsize=8.5)
    axs[0].set_ylabel("server time per request (µs)")
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for _, c in comp]
    fig.legend(handles, [c for c, _ in comp], frameon=False, ncol=5, loc="lower center", fontsize=8)
    fig.tight_layout(rect=(0, 0.07, 1, 1))
    save(fig, out, "kv-04-where-serving-time-goes",
         "KV where the serving time goes, all systems, same load across put ratios (~19k req/s) plus the fixed load L.",
         ["put_pct", "load", "system", "achieved", "p99_ms", "svc_us"] + [c for c, _ in comp], rows)

    # K5 page MSI fault/transaction counts per request vs put ratio (at ~19k) and vs load
    keys = [("read_msg_faults", "read faults w/ FETCH"), ("read_faults", "read faults (all)"),
            ("write_msg_faults", "write faults w/ INVALIDATE"), ("write_faults", "write faults (all)"),
            ("wp_faults", "write faults on a read-only mapped page (subset)")]
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6), sharey=True)
    rows = []
    for j, u in enumerate(PUTS):
        st = [x for x in pslo[("pop", u)] if x.g("mixed_reqs")]
        for ki, (k, kl) in enumerate(keys):
            ys = [sum(x.g(f"thr.{t}.swmc.{k}") for t in TH) / x.g("mixed_reqs") for x in st]
            axs[j].plot([x.achieved / 1e3 for x in st], ys, marker="o", markersize=3.5, linewidth=1.5,
                        color=["#eb6834", "#f4a37f", "#6250d6", "#a79bea", "#d9a400"][ki], label=kl)
            rows += [[u, x.step, round(x.achieved, 1), k, round(y, 4)] for x, y in zip(st, ys)]
        axs[j].set_title(f"page MSI, KV put {u}%", loc="left")
        axs[j].set_xlabel("achieved k requests/s")
    axs[0].set_ylabel("faults per 16-op request")
    axs[0].legend(frameon=False, fontsize=7)
    fig.tight_layout()
    save(fig, out, "kv-05-pagemsi-faults-per-request", "page MSI KV: coherence faults per request vs load (serving threads).",
         ["put_pct", "step", "achieved", "counter", "per_request"], rows)

    # K6 fault latency and message-wait distributions (CDF) per put ratio, at ~19k
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6), sharey=True)
    rows = []
    kinds = [("sys.swmc.instr.tx_fetch.wait_lt_", "FETCH wait", "#eb6834", "-"),
             ("sys.swmc.instr.tx_invalidate.wait_lt_", "INVALIDATE wait", "#6250d6", "-"),
             ("sys.swmc.instr.fault_read.lt_", "read fault total", "#eb6834", ":"),
             ("sys.swmc.instr.fault_write.lt_", "write fault, page not mapped", "#6250d6", ":"),
             ("sys.swmc.instr.fault_wp.lt_", "write fault, read-only page (upgrade)", "#d9a400", ":")]
    for j, u in enumerate(PUTS):
        x = near(pslo[("pop", u)], 19.2e3)
        for pre, kl, cc, ls in kinds:
            h = hist(x, pre)
            tot = sum(h.values())
            if not tot:
                continue
            acc, xs, ys = 0, [], []
            for b, c in h.items():
                acc += c
                xs.append(b / 1e3)
                ys.append(acc / tot)
                rows.append([u, kl, b, int(c)])
        if u == 0:
            axs[j].text(0.5, 0.5, "no coherence faults\n(pages preloaded shared, no writes)", transform=axs[j].transAxes,
                        ha="center", color=INK2)
            axs[j].step(xs, ys, where="post", color=cc, linestyle=ls, linewidth=1.8, label=f"{kl} (n={int(tot)})")
        axs[j].set_xscale("log")
        axs[j].set_xlim(0.5, 1e4)
        axs[j].set_title(f"page MSI, KV put {u}%, {x.achieved/1e3:.1f}k req/s", loc="left", fontsize=8.5)
        axs[j].set_xlabel("µs (log2 bucket upper bound)")
        axs[j].legend(frameon=False, fontsize=6.5, loc="lower right")
    axs[0].set_ylabel("cumulative fraction")
    fig.tight_layout()
    save(fig, out, "kv-06-pagemsi-latency-cdf", "page MSI KV: per-transaction message wait and per-fault total latency CDFs.",
         ["put_pct", "kind", "bucket_lt_ns", "count"], rows)

    # K7 tail: fraction of faults slower than 256 µs / 1 ms vs request p99, per step
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.6))
    rows = []
    for u, mk in zip(PUTS, ("o", "s", "^")):
        st = [x for x in pslo[("pop", u)] if x.g("mixed_reqs")]
        for x in st:
            hr = hist(x, "sys.swmc.instr.fault_read.lt_")
            hw = hist(x, "sys.swmc.instr.fault_write.lt_")
            hh = {b: hr.get(b, 0) + hw.get(b, 0) for b in set(hr) | set(hw)}
            slow = sum(c for b, c in hh.items() if b > 262144) / x.g("mixed_reqs")
            fr = frac_over(hh, 262144)
            rows.append([u, x.step, round(x.achieved, 1), x.p99, round(slow, 5), round(fr, 5)])
            axs[0].plot([x.achieved / 1e3], [x.p99], marker=mk, color="#eb6834", markerfacecolor="#eb6834" if x.passed else SURF,
                        linestyle="none", markersize=5)
            axs[1].plot([slow * 100], [x.p99], marker=mk, color="#eb6834", markerfacecolor="#eb6834" if x.passed else SURF,
                        linestyle="none", markersize=5)
    for ax in axs:
        ax.axhline(1.0, color=INK2, linestyle="--", linewidth=1)
        ax.set_yscale("log")
        ax.set_ylabel("request p99 (ms, log)")
    axs[1].set_xscale("symlog", linthresh=0.01)
    axs[0].set_xlabel("achieved k requests/s")
    axs[1].set_xlabel("faults > 256 µs per 100 requests")
    handles = [plt.Line2D([], [], marker=m, color="#eb6834", linestyle="none") for m in ("o", "s", "^")]
    axs[0].legend(handles, [f"put {u}%" for u in PUTS], frameon=False, fontsize=8)
    fig.suptitle("page MSI KV: what sets the p99 (hollow = failed SLO)", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "kv-07-pagemsi-tail", "page MSI KV: request p99 vs load and vs the rate of slow (>256 µs) coherence faults.",
         ["put_pct", "step", "achieved", "p99_ms", "slow_faults_per_req", "slow_fault_fraction"], rows)

    # K8 remote (serving-side) cost and receive-thread CPU
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6))
    rows = []
    for u, ls in zip(PUTS, ("-", "--", ":")):
        st = [x for x in pslo[("pop", u)] if x.g("mixed_reqs")]
        xs = [x.achieved / 1e3 for x in st]
        n = [x.g("mixed_reqs") for x in st]
        sf = [x.g("sys.swmc.instr.serve_fetch.handle_sum_ns") / k / 1e3 for x, k in zip(st, n)]
        si = [x.g("sys.swmc.instr.serve_invalidate.handle_sum_ns") / k / 1e3 for x, k in zip(st, n)]
        rc = [x.gs("kthr.cxl_recv_0.run_ns", "kthr.cxl_recv_1.run_ns") / (x.g("window_s") * 1e9) for x in st]  # window_s sums nodes: CPUs per node
        axs[0].plot(xs, sf, color="#eb6834", linestyle=ls, marker="o", markersize=3, label=f"serve FETCH, put {u}%")
        axs[0].plot(xs, si, color="#6250d6", linestyle=ls, marker="o", markersize=3, label=f"serve INVALIDATE, put {u}%")
        axs[1].plot(xs, rc, color=INK2, linestyle=ls, marker="o", markersize=3, label=f"put {u}%")
        tl = [x.g("irq.TLB") / k for x, k in zip(st, n)]
        axs[2].plot(xs, tl, color="#6250d6", linestyle=ls, marker="o", markersize=3, label=f"put {u}%")
        rows += [[u, x.step, round(x.achieved, 1), round(a, 3), round(b, 3), round(c, 4), round(d, 3)]
                 for x, a, b, c, d in zip(st, sf, si, rc, tl)]
    axs[0].set_ylabel("remote handling time per request (µs)")
    axs[1].set_ylabel("receive kthread busy (CPUs per node; poll mode)")
    axs[2].set_ylabel("TLB shootdown IPIs per request")
    for ax in axs:
        ax.set_xlabel("achieved k requests/s")
        ax.legend(frameon=False, fontsize=6.5)
    fig.suptitle("page MSI KV: serving-side work (peer handles FETCH / INVALIDATE), receive thread, TLB IPIs", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "kv-08-pagemsi-remote-side", "page MSI KV: remote handling time per request, receive-thread CPU, TLB shootdowns.",
         ["put_pct", "step", "achieved", "serve_fetch_us_per_req", "serve_inval_us_per_req", "recv_cpus_per_node_pair", "tlb_ipi_per_req"], rows)

    # K9 node CPU utilization vs load, per system
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6), sharey=True)
    rows = []
    for j, u in enumerate(PUTS):
        for s, _, _ in SYS:
            st = [x for x in pslo[(s, u)]]
            ys = []
            for x in st:
                busy = x.gs("cpu.user", "cpu.system", "cpu.irq", "cpu.softirq")
                tot = busy + x.gs("cpu.idle", "cpu.iowait")
                ys.append(busy / tot * 100 if tot else 0)
            mark(axs[j], s, [x.achieved / 1e3 for x in st], ys, [x.passed for x in st])
            rows += [[u, LAB[s], x.step, round(x.achieved, 1), round(y, 2)] for x, y in zip(st, ys)]
        axs[j].set_title(f"KV put {u}%", loc="left")
        axs[j].set_xlabel("achieved k requests/s")
    axs[0].set_ylabel("guest CPU busy (%, both nodes)")
    axs[0].legend(frameon=False)
    fig.tight_layout()
    save(fig, out, "kv-09-cpu-vs-load", "KV guest CPU utilization (user+system+irq+softirq) vs load.",
         ["put_pct", "system", "step", "achieved", "cpu_busy_pct"], rows)

    # K10 get vs put latency inside the store (sampled kvt timers), at ~19k
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.6))
    rows = []
    for ax, (op, ol) in zip(axs, (("get", "get"), ("put", "put"))):
        w = 0.26
        for i, (s, _, _) in enumerate(SYS):
            ys = []
            for u in PUTS:
                x = near(pslo[(s, u)], 19.2e3)
                t = x.g(f"kvt.{op}_timed")
                ys.append(x.g(f"kvt.{op}_ns") / t / 1e3 if t else 0)
                rows.append([op, u, LAB[s], round(x.achieved, 1), int(t), round(ys[-1], 3)])
            ax.bar([j + (i - 1) * (w + 0.02) for j in range(3)], ys, w, color=COL[s], label=LAB[s], edgecolor=SURF)
        ax.set_xticks(range(3))
        ax.set_xticklabels([f"put {u}%" for u in PUTS])
        ax.set_title(f"store {ol} time per op (sampled), ~19k req/s", loc="left")
        ax.set_ylabel("µs per op")
    axs[0].legend(frameon=False)
    fig.tight_layout()
    save(fig, out, "kv-10-get-put-op-time", "KV store get / put time per operation (sampled kvt timers) by put ratio.",
         ["op", "put_pct", "system", "achieved", "timed_ops", "us_per_op"], rows)

    # K11 message ring (cxl_shm) per transaction: ring RTT, request queueing, delivery, response delay
    fig, ax = plt.subplots(figsize=(7.5, 3.6))
    rows = []
    rk = [("ring_rtt", "ring RTT"), ("req_queue", "request queueing"), ("req_deliver", "request delivery"), ("rsp_delay", "response delay")]
    w = 0.2
    for i, (k, kl) in enumerate(rk):
        ys = []
        for u in PUTS:
            x = near(pslo[("pop", u)], 19.2e3)
            c = x.g(f"sys.cxl_shm.instr.{k}.count")
            ys.append(x.g(f"sys.cxl_shm.instr.{k}.sum_ns") / c / 1e3 if c else 0)
            rows.append([u, k, int(c), round(ys[-1], 3)])
        ax.bar([j + (i - 1.5) * (w + 0.02) for j in range(3)], ys, w, label=kl,
               color=["#2a78d6", "#eb6834", "#1baf7a", "#6250d6"][i], edgecolor=SURF)
    ax.set_xticks(range(3))
    ax.set_xticklabels([f"put {u}%" for u in PUTS])
    ax.set_ylabel("mean µs per message")
    ax.set_title("page MSI KV: message ring timings (~19k req/s)", loc="left")
    ax.legend(frameon=False, fontsize=8)
    fig.tight_layout()
    save(fig, out, "kv-11-pagemsi-ring", "page MSI KV: cxl_shm message-ring timing means by put ratio.",
         ["put_pct", "metric", "count", "mean_us"], rows)


# ---------------------------------------------------------------- HNSW
def hnsw_figs(R, out):
    pslo = {s: load(hdir(R, s, "pslo"), "search") for s, _, _ in SYS}
    pfix = {s: load(hdir(R, s, "pfix"), "search") for s, _, _ in SYS}

    # H1 latency curves
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.6))
    rows = []
    for s, _, _ in SYS:
        st = pslo[s]
        xs = [x.achieved for x in st]
        mark(axs[0], s, xs, [x.p99 for x in st], [x.passed for x in st])
        mark(axs[1], s, xs, [x.p50 for x in st], [x.passed for x in st])
        rows += [[LAB[s], x.step, x.phase, round(x.achieved, 2), x.p50, x.p99, x.passed] for x in st]
    axs[0].axhline(100, color=INK2, linestyle="--", linewidth=1)
    for ax, t in zip(axs, ("search p99", "search p50")):
        ax.set_yscale("log")
        ax.set_xlabel("achieved search/s")
        ax.set_ylabel(t + " (ms, log)")
    axs[0].legend(frameon=False)
    fig.suptitle("HNSW 1M, update 5%: latency vs load (hollow = failed SLO)", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "hnsw-01-latency-curves", "HNSW search p99 / p50 vs achieved search/s, all SLO-search steps.",
         ["system", "step", "phase", "achieved", "p50_ms", "p99_ms", "pass"], rows)

    # H2 server time per search: wait / replay / search, at the fixed load and vs load
    comp = [("wait_ns_total", "queue wait", "#c3c2b7"), ("replay_ns_total", "replay (apply updates)", "#d9a400"),
            ("search_ns_total", "search", "#52514e")]
    fig, axs = plt.subplots(1, 2, figsize=(11, 3.8), gridspec_kw={"width_ratios": [1, 2]})
    rows = []
    for i, (s, _, _) in enumerate(SYS):
        x = pfix[s][0]
        n = x.g("searches")
        b = 0
        for k, kl, cc in comp:
            v = x.g(k) / n / 1e6
            axs[0].bar(i, v, 0.6, bottom=b, color=cc, edgecolor=SURF, label=kl if i == 0 else None)
            b += v
            rows.append(["fixed", LAB[s], round(x.achieved, 2), k, round(v, 4)])
        axs[0].text(i, b, f"{b:.2f}", ha="center", va="bottom", fontsize=8)
    axs[0].set_xticks(range(3))
    axs[0].set_xticklabels([l for _, l, _ in SYS], fontsize=8)
    axs[0].set_ylabel("server time per search (ms)")
    axs[0].set_title("fixed load L (104 search/s)", loc="left")
    axs[0].legend(frameon=False, fontsize=7)
    for s, _, _ in SYS:
        st = [x for x in pslo[s] if x.g("searches")]
        ys = [x.g("search_ns_total") / x.g("searches") / 1e6 for x in st]
        mark(axs[1], s, [x.achieved for x in st], ys, [x.passed for x in st])
        rows += [["pslo", LAB[s], round(x.achieved, 2), "search_ns_total", round(y, 4)] for x, y in zip(st, ys)]
    axs[1].set_xlabel("achieved search/s")
    axs[1].set_ylabel("search execution per search (ms)")
    axs[1].set_title("search execution time vs load", loc="left")
    axs[1].legend(frameon=False)
    fig.tight_layout()
    save(fig, out, "hnsw-02-server-time", "HNSW server time per search split into queue wait / replay / search; search time vs load.",
         ["window", "system", "achieved", "component", "ms_per_search"], rows)

    # H3 coherence per search (time-share) vs load
    def coh(x, s, hw_busy=None):
        n = x.g("searches")
        S = x.gs("wait_ns_total", "replay_ns_total", "search_ns_total") / n / 1e6
        Ssearch = x.g("search_ns_total") / n / 1e6
        B = x.g("search_busy_ns") / 1e9
        if s == "pop":
            C = x.gs("thr.vdb-search.swmc.read_fault_ns", "thr.vdb-search.swmc.write_fault_ns") / 1e9
        elif s == "mg":
            C = sum((float(r["megt.rd_start_ns"]) + float(r["megt.rd_end_ns"])) * float(r["megalon.read_sections"])
                    / max(float(r["megt.rd_sampled"]), 1) for r in x.srows) / 1e9
        else:
            C = 0.0
        return S, Ssearch, C, B, (C / B * Ssearch if B else 0)
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.6))
    rows = []
    for s in ("pop", "mg"):
        st = [x for x in pslo[s] if x.g("searches")]
        v = [coh(x, s) for x in st]
        mark(axs[0], s, [x.achieved for x in st], [c[4] for c in v], [x.passed for x in st])
        mark(axs[1], s, [x.achieved for x in st], [c[4] / c[1] * 100 if c[1] else 0 for c in v], [x.passed for x in st])
        rows += [[LAB[s], x.step, round(x.achieved, 2), round(c[1], 4), round(c[2], 4), round(c[3], 4), round(c[4], 4)]
                 for x, c in zip(st, v)]
    axs[0].set_ylabel("coherence ms per search (time-share)")
    axs[1].set_ylabel("coherence share of search time (%)")
    for ax in axs:
        ax.set_xlabel("achieved search/s")
        ax.legend(frameon=False)
        ax.set_yscale("symlog", linthresh=0.01)
    fig.suptitle("HNSW: coherence time per search, (C_search / B_search) x search time, every step", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "hnsw-03-coherence-per-search", "HNSW coherence time per search (time-share) and its share of search time vs load.",
         ["system", "step", "achieved", "search_ms", "C_s", "B_s", "coh_ms"], rows)

    # H4 Megalon internals per search and per update
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6))
    rows = []
    st = [x for x in pslo["mg"] + pfix["mg"] if x.g("searches")]
    st.sort(key=lambda x: x.achieved)
    xs = [x.achieved for x in st]
    rs = [x.g("megalon.read_sections") / x.g("searches") for x in st]
    rt = [x.g("megalon.read_retry_incoherent") / x.g("searches") for x in st]
    per = lambda k: [x.g(f"megt.{k}") / max(x.g("megt.rd_sampled"), 1) for x in st]
    rds, rde, rdb = per("rd_start_ns"), per("rd_end_ns"), per("rd_body_ns")
    axs[0].plot(xs, rs, color="#1baf7a", marker="o", markersize=3.5, label="read sections / search")
    axs[0].set_ylabel("read sections per search")
    ax2 = axs[1]
    ax2.plot(xs, rds, color="#1baf7a", marker="o", markersize=3.5, label="read_start (validate / refetch)")
    ax2.plot(xs, rde, color="#0d6e4c", marker="s", markersize=3.5, label="read_end (version check)")
    ax2.plot(xs, rdb, color="#c3c2b7", marker="^", markersize=3.5, label="body (user code)")
    ax2.set_ylabel("ns per read section (sampled)")
    ax2.set_yscale("log")
    axs[2].plot(xs, rt, color="#6250d6", marker="o", markersize=3.5, label="incoherent-read retries / search")
    upd = [x.g("updates") for x in st]
    fl = [x.g("megalon.flush_bytes") / u / 1e3 if u else 0 for x, u in zip(st, upd)]
    axs[2].set_ylabel("retries per search")
    for ax in axs:
        ax.set_xlabel("achieved search/s")
        ax.legend(frameon=False, fontsize=7)
    fig.suptitle("Megalon HNSW: read sections per search, per-section cost, retries", x=0.01, ha="left")
    fig.tight_layout()
    rows = [[x.step, x.phase, round(x.achieved, 2), round(a, 2), round(b, 1), round(c, 1), round(d, 1), round(e, 4), round(f, 2)]
            for x, a, b, c, d, e, f in zip(st, rs, rds, rde, rdb, rt, fl)]
    save(fig, out, "hnsw-04-megalon-internals", "Megalon HNSW: read sections per search, sampled ns per section phase, incoherent-read retries.",
         ["step", "phase", "achieved", "read_sections_per_search", "rd_start_ns", "rd_end_ns", "rd_body_ns",
          "retries_per_search", "flush_kB_per_update"], rows)

    # H5 page MSI internals: faults per search, writer faults per update, receive thread CPU
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6))
    rows = []
    st = sorted([x for x in pslo["pop"] + pfix["pop"] if x.g("searches")], key=lambda x: x.achieved)
    xs = [x.achieved for x in st]
    rf = [x.g("thr.vdb-search.swmc.read_faults") / x.g("searches") for x in st]
    rm = [x.g("thr.vdb-search.swmc.read_msg_faults") / x.g("searches") for x in st]
    wf = [x.g("thr.vdb-writer.swmc.write_faults") / max(x.g("updates"), 1) for x in st]
    wm = [x.g("thr.vdb-writer.swmc.write_msg_faults") / max(x.g("updates"), 1) for x in st]
    rc = [x.gs("kthr.cxl_recv_0.run_ns", "kthr.cxl_recv_1.run_ns") / (x.g("window_s") * 1e9) for x in st]  # window_s sums nodes: CPUs per node
    axs[0].plot(xs, rf, color="#f4a37f", marker="o", markersize=3.5, label="read faults")
    axs[0].plot(xs, rm, color="#eb6834", marker="o", markersize=3.5, label="read faults w/ FETCH")
    axs[0].set_ylabel("per search (search threads)")
    axs[1].plot(xs, wf, color="#a79bea", marker="o", markersize=3.5, label="write faults")
    axs[1].plot(xs, wm, color="#6250d6", marker="o", markersize=3.5, label="write faults w/ INVALIDATE")
    axs[1].set_ylabel("per update (writer thread)")
    axs[2].plot(xs, rc, color=INK2, marker="o", markersize=3.5, label="cxl_recv busy")
    axs[2].set_ylabel("receive kthread busy (CPUs per node; poll mode)")
    for ax in axs:
        ax.set_xlabel("achieved search/s")
        ax.legend(frameon=False, fontsize=7)
    fig.suptitle("page MSI HNSW: coherence faults per search / per update, receive-thread CPU", x=0.01, ha="left")
    fig.tight_layout()
    rows = [[x.step, x.phase, round(x.achieved, 2), round(a, 3), round(b, 3), round(c, 2), round(d, 2), round(e, 3)]
            for x, a, b, c, d, e in zip(st, rf, rm, wf, wm, rc)]
    save(fig, out, "hnsw-05-pagemsi-internals", "page MSI HNSW: faults per search and per update, receive-thread CPU.",
         ["step", "phase", "achieved", "read_faults_per_search", "read_msg_faults_per_search", "write_faults_per_update",
          "write_msg_faults_per_update", "recv_cpus"], rows)

    # H6 CPU and busy fractions vs load
    fig, axs = plt.subplots(1, 3, figsize=(12, 3.6))
    rows = []
    for s, _, _ in SYS:
        st = [x for x in pslo[s] if x.g("searches")]
        xs = [x.achieved for x in st]
        cpu, sb, wb = [], [], []
        for x in st:
            busy = x.gs("cpu.user", "cpu.system", "cpu.irq", "cpu.softirq")
            tot = busy + x.gs("cpu.idle", "cpu.iowait")
            cpu.append(busy / tot * 100 if tot else 0)
            win = x.g("window_s") / len(x.srows)  # per-node window
            sb.append(x.g("search_busy_ns") / 1e9 / (win * max(x.g("thr.vdb-search.n"), 1)) * 100)
            wb.append(x.g("writer_busy_ns") / 1e9 / (win * len(x.srows)) * 100)
        mark(axs[0], s, xs, cpu, [x.passed for x in st])
        mark(axs[1], s, xs, sb, [x.passed for x in st])
        mark(axs[2], s, xs, wb, [x.passed for x in st])
        rows += [[LAB[s], x.step, round(x.achieved, 2), round(a, 2), round(b, 2), round(c, 3)] for x, a, b, c in zip(st, cpu, sb, wb)]
    axs[0].set_ylabel("guest CPU busy (%, both nodes)")
    axs[1].set_ylabel("search threads busy (% of thread-time)")
    axs[2].set_ylabel("writer busy (% per node)")
    for ax in axs:
        ax.set_xlabel("achieved search/s")
    axs[0].legend(frameon=False)
    fig.tight_layout()
    save(fig, out, "hnsw-06-cpu-busy", "HNSW guest CPU, search-thread busy fraction and writer busy vs load.",
         ["system", "step", "achieved", "cpu_busy_pct", "search_busy_pct", "writer_busy_pct"], rows)

    # H7 updates: achieved update/s and time per update (writer), fixed load
    fig, axs = plt.subplots(1, 2, figsize=(9, 3.4))
    rows = []
    for i, (s, _, _) in enumerate(SYS):
        x = pfix[s][0]
        u = x.g("updates")
        ups = u / (x.g("window_s") / 2)
        tpu = x.g("update_ns") / u / 1e6 if u else 0
        axs[0].bar(i, ups, 0.6, color=COL[s], edgecolor=SURF)
        axs[1].bar(i, tpu, 0.6, color=COL[s], edgecolor=SURF)
        axs[0].text(i, ups, f"{ups:.1f}", ha="center", va="bottom", fontsize=8)
        axs[1].text(i, tpu, f"{tpu:.2f}", ha="center", va="bottom", fontsize=8)
        rows.append([LAB[s], int(u), round(ups, 2), round(tpu, 4)])
    for ax, t in zip(axs, ("update/s (both nodes)", "writer ms per update")):
        ax.set_xticks(range(3))
        ax.set_xticklabels([l for _, l, _ in SYS])
        ax.set_ylabel(t)
    fig.suptitle("HNSW fixed load: update rate and update cost", x=0.01, ha="left")
    fig.tight_layout()
    save(fig, out, "hnsw-07-updates", "HNSW fixed load: updates per second and writer time per update.",
         ["system", "updates", "update_per_s", "ms_per_update"], rows)

    # H8 page MSI HNSW latency CDF (fixed load)
    fig, ax = plt.subplots(figsize=(7, 3.4))
    rows = []
    x = pfix["pop"][0]
    for pre, kl, cc, ls in [("sys.swmc.instr.tx_fetch.wait_lt_", "FETCH wait", "#eb6834", "-"),
                            ("sys.swmc.instr.tx_invalidate.wait_lt_", "INVALIDATE wait", "#6250d6", "-"),
                            ("sys.swmc.instr.fault_read.lt_", "read fault total", "#eb6834", ":"),
                            ("sys.swmc.instr.fault_write.lt_", "write fault, page not mapped", "#6250d6", ":"),
                            ("sys.swmc.instr.fault_wp.lt_", "write fault, read-only page (upgrade)", "#d9a400", ":")]:
        h = hist(x, pre)
        tot = sum(h.values())
        if not tot:
            continue
        acc, xs, ys = 0, [], []
        for b, c in h.items():
            acc += c
            xs.append(b / 1e3)
            ys.append(acc / tot)
            rows.append([kl, b, int(c)])
        ax.step(xs, ys, where="post", color=cc, linestyle=ls, linewidth=1.8, label=f"{kl} (n={int(tot)})")
    ax.set_xscale("log")
    ax.set_xlim(0.5, 1e4)
    ax.set_xlabel("µs (log2 bucket upper bound)")
    ax.set_ylabel("cumulative fraction")
    ax.set_title("page MSI HNSW, fixed load: message wait and fault latency", loc="left")
    ax.legend(frameon=False, fontsize=7)
    fig.tight_layout()
    save(fig, out, "hnsw-08-pagemsi-latency-cdf", "page MSI HNSW fixed load: per-transaction wait and per-fault latency CDFs.",
         ["kind", "bucket_lt_ns", "count"], rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    R = os.path.join(a.root, "recovery")
    os.makedirs(a.out, exist_ok=True)
    kv_figs(R, a.out)
    hnsw_figs(R, a.out)
    with open(os.path.join(a.out, "index.md"), "w") as f:
        f.write("# H1 pilot exploratory figures\n\nGenerated by experiments/analysis/pilot_h1_explore.py "
                "(one run per configuration; hollow markers = steps that failed the SLO).\n\n")
        for n, c in INDEX:
            f.write(f"## {n}\n\n{c}\n\n![{n}]({n}.png)\n\n")
    print(len(INDEX), "figures in", a.out)


if __name__ == "__main__":
    main()

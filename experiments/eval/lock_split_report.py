#!/usr/bin/env python3
"""popcorn-writer-lock-split analysis (reports/experiments/popcorn-writer-lock-split.md §2; DESIGN.md §19 keys).

usage: lock_split_report.py <evidence dir | part dir> ... [--out DIR]
  evidence dir: recovery/popcorn-writer-lock-split-v<V> (every <E>/block/*-n<N>/<part>/stats-steps.csv); a part dir =
  any dir with stats-steps.csv (part name = its basename; Host tests). --out default:
  workspaces/popcorn-lock-split/derived/<evidence dir name>. Read only on the inputs. Rows: fixed-mode windows
  (stats-steps.csv phase "fixed"), counters summed over the VMs (targets) of a window.

Outputs
  lock-split-windows.csv  one row per window (part, step, offered_x):
    rates (search_s, update_s, inserts), writer hold split: hold_mean_ms = hold_ns / inserts; coh_share = hold_coh /
    hold (I->S + S->M + wp faults + coherence IPIs inside the hold), rq_share = hold_rq / hold (run-queue delay inside
    the hold), rest_share = 1 - coh - rq (insert work and anything else; negative when coh and rq overlap, see
    overlap_frac = inserts with coh + rq > hold), cpu_share = hold_cpu / hold, wp/sm/is/ipi shares of the hold, nt_ms
    per insert (no-transition faults, not in C), sample_us (sampling cost per insert, inside the hold); hold p50/p90/p99
    upper bounds from the log2 histogram (bucket upper edge, ms); per search: search_lock_ms (segment write-lock wait,
    mean), its p99 bound, e1_ms (mean) and p99 bound; ack wait (instr detail=1 only, else empty): tx_invalidate /
    tx_fetch rounds per s, mean and max wait, share of rounds >= ~1 ms; writer thread per update: write_msg_wait_ms,
    write_spin_ms, write_sleep_ms, write_owner_h_ms (swmc per-thread split), writer run-queue ms (schedstat);
    searches: search_run_ms / search_rq_ms per search (thr.vdb-search run / wait ns), opt_t_ms / opt_c_ms (per-
    search T and C of the response blocks), recv_cpu (cxl_recv kthreads, vCPU per VM), loc_irq_s (local timer
    interrupts per s per VM).
  lock-split-vm.csv       per (window, VM): hold mean / coh / rq shares, writer rq per update, tx_invalidate mean wait
                          and >= 1 ms share, serve_invalidate handle mean and >= 1 ms share (slow responders), receiver
                          CPU. (Which peer ACKed last per round is not recorded by Popcorn build 12; the serve side per
                          VM is the proxy.)
  lock-split-hist.csv     long form: part, step, hist (hold, search_lock, seg_lock, e1, tx_invalidate, tx_fetch,
                          serve_invalidate), lo_ns, hi_ns, count (summed over VMs)
  lock-split-summary.txt  the decision lines: hold split per window; 10 ops/s sleep vs spin (lsleep / lspin): search
                          on-CPU ms per search and its difference
"""
import csv
import glob
import math
import os
import sys

P = "/home/comsys/sungsu/destijl-control"
LS = "lock_split."


def f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def find_parts(args):
    parts = []  # (part name, stats-steps.csv)
    for a in args:
        if os.path.isfile(os.path.join(a, "stats-steps.csv")):
            parts.append((os.path.basename(os.path.normpath(a)), os.path.join(a, "stats-steps.csv")))
            continue
        for p in sorted(glob.glob(os.path.join(a, "block", "*-n[0-9]*", "*", "stats-steps.csv"))):
            parts.append((os.path.basename(os.path.dirname(p)), p))
    return parts


def ls_hist(r, name):
    return [f(r.get(f"{LS}{name}.b{b:02d}")) for b in range(40)]


def pow2_hist(r, prefix):
    """Popcorn swmc_hist keys <prefix>lt_<2^k> (values in [2^(k-1), 2^k)) and <prefix>ge_<max>: [(lo, hi, count)]."""
    out = []
    for k, v in r.items():
        if k.startswith(prefix + "lt_"):
            hi = int(k[len(prefix) + 3:])
            out.append((hi // 2, hi, f(v)))
        elif k.startswith(prefix + "ge_"):
            lo = int(k[len(prefix) + 3:])
            out.append((lo, math.inf, f(v)))
    return sorted(out)


def q_bound(buckets, q):
    """Upper bound of the q-quantile from (lo, hi, count) buckets (hi edge of the bucket holding it; ns)."""
    n = sum(c for _, _, c in buckets)
    if n <= 0:
        return None
    need, acc = q * n, 0.0
    for lo, hi, c in buckets:
        acc += c
        if acc >= need:
            return hi
    return buckets[-1][1]


def ge_share(buckets, ns):
    n = sum(c for _, _, c in buckets)
    return sum(c for lo, _, c in buckets if lo >= ns) / n if n > 0 else None


def lsb(h):  # lock_split log2 buckets -> (lo, hi, count)
    return [(0 if b == 0 else 2 ** b, 2 ** (b + 1) if b < 39 else math.inf, c) for b, c in enumerate(h)]


def ms(x):
    return None if x is None else x / 1e6


def us(x):
    return None if x is None else x / 1e3


def rnd(x, d=4):
    if x is None or (isinstance(x, float) and (math.isnan(x) or math.isinf(x))):
        return ""
    return round(x, d)


def div(a, b):
    return a / b if b else None


def window_rows(parts, phase="fixed"):
    wins = {}  # (part, step) -> list of per-target rows
    order = []
    for part, path in parts:
        for r in csv.DictReader(open(path)):
            if r.get("phase") != phase:
                continue
            key = (part, int(f(r["step"])))
            if key not in wins:
                wins[key] = []
                order.append(key)
            wins[key].append(r)
    return order, wins


def agg(rows, keys):
    return {k: sum(f(r.get(k)) for r in rows) for k in keys}


def sumk(rows, pred):
    return sum(f(v) for r in rows for k, v in r.items() if pred(k))


def main():
    args = [a for a in sys.argv[1:]]
    out = None
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        del args[i:i + 2]
    phase = "fixed"
    if "--phase" in args:  # Host check on older evidence (e.g. --phase confirm); the experiment uses fixed windows
        i = args.index("--phase")
        phase = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    parts = find_parts(args)
    if not parts:
        sys.exit("no stats-steps.csv found")
    if out is None:
        out = os.path.join(P, "workspaces/popcorn-lock-split/derived", os.path.basename(os.path.normpath(args[0])))
    os.makedirs(out, exist_ok=True)
    order, wins = window_rows(parts, phase)
    W, V, H = [], [], []
    for part, step in order:
        rows = wins[(part, step)]
        r0 = rows[0]
        nvm = len(rows)
        win = f(r0.get("window_s")) or 1.0
        g = lambda k: sum(f(r.get(k)) for r in rows)
        ins, hold = g(LS + "inserts"), g(LS + "hold_ns")
        searches, updates = g("searches"), g("updates")
        hh = [sum(x) for x in zip(*[ls_hist(r, "hold_hist") for r in rows])]
        sh = [sum(x) for x in zip(*[ls_hist(r, "search_lock_hist") for r in rows])]
        gh = [sum(x) for x in zip(*[ls_hist(r, "seg_lock_hist") for r in rows])]
        eh = [sum(x) for x in zip(*[ls_hist(r, "e1_hist") for r in rows])]
        tx = {}
        for t in ("tx_invalidate", "tx_fetch", "serve_invalidate"):
            pre = f"sys.swmc.instr.{t}." + ("handle_" if t.startswith("serve") else "wait_")
            b = {}
            for r in rows:
                for lo, hi, c in pow2_hist(r, pre):
                    b[(lo, hi)] = b.get((lo, hi), 0) + c
            base = f"sys.swmc.instr.{t}."  # rounds: ack + nack (+ error) are counted at detail 0 too; the wait /
            # handle histogram only with instr detail = 1
            rounds = g(base + "ack") + g(base + "nack") + g(base + "error")
            tx[t] = ([(lo, hi, c) for (lo, hi), c in sorted(b.items())], g(pre + "count"), g(pre + "sum_ns"),
                     max(f(r.get(pre + "max_ns")) for r in rows), rounds)
        for name, bk in (("hold", lsb(hh)), ("search_lock", lsb(sh)), ("seg_lock", lsb(gh)), ("e1", lsb(eh)),
                         ("tx_invalidate", tx["tx_invalidate"][0]), ("tx_fetch", tx["tx_fetch"][0]),
                         ("serve_invalidate", tx["serve_invalidate"][0])):
            for lo, hi, c in bk:
                if c:
                    H.append([part, step, name, lo, "" if math.isinf(hi) else hi, int(c)])
        txw = lambda t: (div(tx[t][2], tx[t][1]), tx[t][3] if tx[t][1] else None, ge_share(tx[t][0], 1 << 20), tx[t][4] / win)
        ti, tf = txw("tx_invalidate"), txw("tx_fetch")
        recv = sumk(rows, lambda k: k.startswith("kthr.cxl_recv") and k.endswith(".run_ns"))
        sh_ = lambda k: div(g(LS + k), hold)
        coh, rq = sh_("hold_coh_ns"), sh_("hold_rq_ns")
        W.append([part, step, rnd(f(r0.get("offered_x")), 2), rnd(win, 2), nvm, rnd(searches / win, 2), rnd(updates / win, 2),
                  int(ins), rnd(ms(div(hold, ins))), rnd(coh), rnd(rq),
                  rnd(None if coh is None else 1 - coh - rq), rnd(sh_("hold_cpu_ns")), rnd(sh_("hold_wp_ns")),
                  rnd(sh_("hold_sm_ns")), rnd(sh_("hold_is_ns")), rnd(sh_("hold_ipi_ns")),
                  rnd(div(g(LS + "hold_overlap_cnt"), ins)), rnd(ms(div(g(LS + "hold_nt_ns"), ins))),
                  rnd(div(g(LS + "sample_ns"), ins * 1e3) if ins else None, 2),
                  rnd(ms(q_bound(lsb(hh), .5))), rnd(ms(q_bound(lsb(hh), .9))), rnd(ms(q_bound(lsb(hh), .99))),
                  rnd(ms(max(f(r.get(LS + "hold_max_ns")) for r in rows))),
                  rnd(ms(div(g(LS + "search_lock_ns"), g(LS + "searches")))), rnd(ms(q_bound(lsb(sh), .99))),
                  rnd(ms(div(g(LS + "search_e1_ns"), g(LS + "searches")))), rnd(ms(q_bound(lsb(eh), .99))),
                  rnd(ti[3], 1), rnd(us(ti[0]), 2), rnd(ms(ti[1])), rnd(ti[2]),
                  rnd(tf[3], 1), rnd(us(tf[0]), 2), rnd(ms(tf[1])), rnd(tf[2]),
                  rnd(ms(div(g("thr.vdb-writer.swmc.write_msg_wait_ns"), updates))),
                  rnd(ms(div(g("thr.vdb-writer.swmc.write_spin_ns"), updates))),
                  rnd(ms(div(g("thr.vdb-writer.swmc.write_sleep_ns"), updates))),
                  rnd(ms(div(g("thr.vdb-writer.swmc.write_owner_h_ns"), updates))),
                  rnd(ms(div(g("thr.vdb-writer.wait_ns"), updates))),
                  rnd(ms(div(g("thr.vdb-search.run_ns"), searches))), rnd(ms(div(g("thr.vdb-search.wait_ns"), searches))),
                  rnd(ms(div(g("opt.search.t_ns"), g("opt.search.ops")))), rnd(ms(div(g("opt.search.c_ns"), g("opt.search.ops")))),
                  rnd(recv / 1e9 / win / nvm), rnd(g("irq.LOC") / win / nvm, 1)])
        for r in rows:
            gv = lambda k: f(r.get(k))
            vb = pow2_hist(r, "sys.swmc.instr.tx_invalidate.wait_")
            sb = pow2_hist(r, "sys.swmc.instr.serve_invalidate.handle_")
            vi, vh = gv(LS + "inserts"), gv(LS + "hold_ns")
            V.append([part, step, int(gv("target")), int(vi), rnd(ms(div(vh, vi))), rnd(div(gv(LS + "hold_coh_ns"), vh)),
                      rnd(div(gv(LS + "hold_rq_ns"), vh)), rnd(ms(div(gv("thr.vdb-writer.wait_ns"), gv("updates")))),
                      rnd(div(gv("sys.swmc.instr.tx_invalidate.wait_sum_ns"), gv("sys.swmc.instr.tx_invalidate.wait_count") * 1e3)
                          if gv("sys.swmc.instr.tx_invalidate.wait_count") else None, 2), rnd(ge_share(vb, 1 << 20)),
                      rnd(div(gv("sys.swmc.instr.serve_invalidate.handle_sum_ns"), gv("sys.swmc.instr.serve_invalidate.handle_count") * 1e3)
                          if gv("sys.swmc.instr.serve_invalidate.handle_count") else None, 2), rnd(ge_share(sb, 1 << 20)),
                      rnd(sum(f(v) for k, v in r.items() if k.startswith("kthr.cxl_recv") and k.endswith(".run_ns")) / 1e9 / win)])
    WC = ["part", "step", "offered_x", "window_s", "vms", "search_s", "update_s", "inserts", "hold_mean_ms", "coh_share",
          "rq_share", "rest_share", "cpu_share", "wp_share", "sm_share", "is_share", "ipi_share", "overlap_frac",
          "nt_ms_per_insert", "sample_us_per_insert", "hold_p50_le_ms", "hold_p90_le_ms", "hold_p99_le_ms", "hold_max_ms",
          "search_lock_ms", "search_lock_p99_le_ms", "e1_ms", "e1_p99_le_ms", "tx_inv_rounds_s", "tx_inv_wait_mean_us",
          "tx_inv_wait_max_ms", "tx_inv_ge1ms_share", "tx_fetch_rounds_s", "tx_fetch_wait_mean_us", "tx_fetch_wait_max_ms",
          "tx_fetch_ge1ms_share", "writer_msg_wait_ms_per_update", "writer_spin_ms_per_update",
          "writer_sleep_ms_per_update", "writer_owner_h_ms_per_update", "writer_rq_ms_per_update",
          "search_run_ms_per_search", "search_rq_ms_per_search", "opt_search_t_ms", "opt_search_c_ms",
          "recv_cpu_per_vm", "loc_irq_s_per_vm"]
    VC = ["part", "step", "vm", "inserts", "hold_mean_ms", "coh_share", "rq_share", "writer_rq_ms_per_update",
          "tx_inv_wait_mean_us", "tx_inv_ge1ms_share", "serve_inv_handle_mean_us", "serve_inv_ge1ms_share", "recv_cpu"]
    HC = ["part", "step", "hist", "lo_ns", "hi_ns", "count"]
    for name, cols, rows in (("windows", WC, W), ("vm", VC, V), ("hist", HC, H)):
        with open(os.path.join(out, f"lock-split-{name}.csv"), "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(rows)
    S = []
    ix = {c: i for i, c in enumerate(WC)}
    for r in W:
        S.append(f"{r[0]} step {r[1]} offered {r[2]}: hold {r[ix['hold_mean_ms']]} ms/insert = coh {r[ix['coh_share']]} + "
                 f"rq {r[ix['rq_share']]} + rest {r[ix['rest_share']]} (cpu {r[ix['cpu_share']]}, overlap "
                 f"{r[ix['overlap_frac']]}); search lock wait {r[ix['search_lock_ms']]} ms, E1 {r[ix['e1_ms']]} ms; "
                 f"tx_invalidate wait {r[ix['tx_inv_wait_mean_us']]} us (>= 1 ms {r[ix['tx_inv_ge1ms_share']]})")
    lo = {r[0]: r for r in W if r[0] in ("lsleep", "lspin")}
    if "lsleep" in lo and "lspin" in lo:
        a, b = lo["lsleep"][ix["search_run_ms_per_search"]], lo["lspin"][ix["search_run_ms_per_search"]]
        d = "" if "" in (a, b) else round(a - b, 4)
        S.append(f"10 ops/s: search on-CPU per search sleep {a} ms vs poll (spin) {b} ms: difference {d} ms; "
                 f"T sleep {lo['lsleep'][ix['opt_search_t_ms']]} vs poll {lo['lspin'][ix['opt_search_t_ms']]} ms; "
                 f"LOC irq/s/VM {lo['lsleep'][ix['loc_irq_s_per_vm']]} vs {lo['lspin'][ix['loc_irq_s_per_vm']]}; "
                 f"recv CPU/VM {lo['lsleep'][ix['recv_cpu_per_vm']]} vs {lo['lspin'][ix['recv_cpu_per_vm']]}")
    open(os.path.join(out, "lock-split-summary.txt"), "w").write("\n".join(S) + "\n")
    print("\n".join(S))
    print(f"lock_split_report: {len(W)} windows, {len(V)} VM rows -> {out}")


if __name__ == "__main__":
    main()

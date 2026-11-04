#!/usr/bin/env python3
"""Unit test (Host, no servers, no VM): the per-step export of the counters the RocksDB N=4 write-wait RCA needed
(2026-11-05): De Stijl wr_round_ns / wr_rounds / wr_evict_m_self_ns / srv_inv_last_h_ns / srv_inv_pickup_*, cxl_shm
per-kind rx counts, receiver wake outcomes and the recv_adaptive r_sleep_found_us_log2 histogram; stable column set
for Popcorn (no De Stijl counters: empty) and De Stijl lifetimes.

usage: python3 stats_rca_export_test.py <scratch dir> [--proc-bin <systems/common/tests/proc_stats_test binary>]
  without --proc-bin the snapshots are written as proc_stats.h emits them (stats_delta.py only); with it the snapshots
  are the binary's output on a stub counter tree (proc_stats.h + stats_delta.py end to end). Exit 0 = PASS."""
import argparse, csv, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LG = os.path.dirname(HERE)
sys.path.insert(0, LG)
import stats_delta  # noqa: E402

fails = 0


def check(c, what):
    global fails
    if not c:
        fails += 1
        print("FAIL", what)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def stub(root, k):
    """De Stijl + cxl_shm stub tree, counter values scaled by k (k = 1 begin, 3 end)"""
    ds, cs = os.path.join(root, "stub", "destijl"), os.path.join(root, "stub", "cxl_shm")
    for n, v in (("wr_rounds", 10), ("wr_round_ns", 1000), ("wr_evict_m_self_ns", 70), ("srv_inv_last_h_ns", 30),
                 ("srv_inv_pickup_n", 20), ("srv_inv_pickup_bound_ns", 400), ("inv_sent", 12), ("rx_inv", 11),
                 ("fetch_stale", 0), ("ack_ph_count", 2)):
        write(os.path.join(ds, n), f"{v * k}\n")
    write(os.path.join(ds, "spin_budget"), "1071084294 iterations, 28009 ps per iteration\n")
    write(os.path.join(ds, "inspect"), "page 0 pfn 0x690200 LCM S\nreplica: none\n")
    for n, v in (("rx_inv_count", 11), ("rx_fetch_count", 4), ("rx_ack_count", 0), ("r_found_after_timeout", 5),
                 ("r_wake_timeout_timed", 9)):
        write(os.path.join(cs, n), f"{v * k}\n")
    hist = " ".join(str(x * k) for x in [0, 0, 0, 0, 0, 3, 7] + [0] * 17)
    write(os.path.join(cs, "recv_adaptive"), f"gap_ewma_us {100 + k}\ntimed_sleep_us 50\nq_warm 0\nipoll_live 1\n"
          f"r_sleep_found_us_log2 {hist}\nipoll_to_handle_ns_log2 {' '.join(['0'] * 24)}\nodd 1 x\n")
    return cs


def emitted(k, ds=True):
    """the key=value text proc_stats.h emits for stub(k) (cxl_shm tag = the stub dir name)"""
    kv = {"t_mono_ns": k * 1_000_000_000, "sys.cxl_shm.rx_fetch_count": 4 * k, "sys.cxl_shm.r_found_after_timeout": 5 * k,
          "sys.cxl_shm.r_wake_timeout_timed": 9 * k, "sys.cxl_shm.recv_adaptive.gap_ewma_us": 100 + k,
          "sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b5": 3 * k, "sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b6": 7 * k}
    for i in list(range(5)) + list(range(7, 24)):
        kv[f"sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b{i}"] = 0
    if ds:
        kv.update({"sys.cxl_shm.rx_inv_count": 11 * k, "sys.swmc.destijl.wr_rounds": 10 * k, "sys.swmc.destijl.wr_round_ns": 1000 * k,
                   "sys.swmc.destijl.wr_evict_m_self_ns": 70 * k, "sys.swmc.destijl.srv_inv_last_h_ns": 30 * k,
                   "sys.swmc.destijl.srv_inv_pickup_n": 20 * k, "sys.swmc.destijl.srv_inv_pickup_bound_ns": 400 * k})
    return "".join(f"{a}={b}\n" for a, b in kv.items())


def run_dir(base, name, texts):
    run = os.path.join(base, name)
    os.makedirs(os.path.join(run, "stats"), exist_ok=True)
    for tag, t in (("begin", texts[0]), ("end", texts[1])):
        with open(os.path.join(run, "stats", f"step001-{tag}-t0.txt"), "w") as f:
            f.write(f"# when={tag} phase=fixed step=1 offered_x=500 target=0 addr=a:1 status=ok wall_ns=1 mono_ns="
                    f"{1 if tag == 'begin' else 30_000_000_001}\n" + t)
    subprocess.run([sys.executable, os.path.join(LG, "stats_delta.py"), run], check=True, stdout=subprocess.DEVNULL)
    with open(os.path.join(run, "stats-steps.csv")) as f:
        rows = list(csv.DictReader(f))
    return rows[0], list(rows[0].keys())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scratch")
    ap.add_argument("--proc-bin")
    a = ap.parse_args()
    os.makedirs(a.scratch, exist_ok=True)
    if a.proc_bin:  # proc_stats.h end to end on the stub tree
        snaps = []
        for k in (1, 3):
            cs = stub(a.scratch, k)
            out = subprocess.run([os.path.abspath(a.proc_bin), os.path.relpath(cs, a.scratch)], cwd=a.scratch, check=True,
                                 capture_output=True, text=True).stdout
            snaps.append(out)
        kv = dict(l.split("=", 1) for l in snaps[1].splitlines() if "=" in l)
        check(kv.get("sys.swmc.destijl.wr_round_ns") == "3000" and kv.get("sys.swmc.destijl.srv_inv_pickup_bound_ns") == "1200",
              "proc_stats.h: wr_* / srv_* De Stijl files exported")
        check(kv.get("sys.swmc.destijl.fetch_stale") == "0" and kv.get("sys.swmc.destijl.ack_ph_count") == "6", "fetch_stale, ack_ph_*")
        check(not any(k.startswith("sys.swmc.destijl.inspect") or k == "sys.swmc.destijl.spin_budget" for k in kv),
              "inspect / spin_budget not read by the prefix scan")
        check(kv.get("sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b6") == "21" and
              kv.get("sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b23") == "0" and
              "sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b24" not in kv, "log2 histogram buckets b0..b23")
        check(kv.get("sys.cxl_shm.recv_adaptive.gap_ewma_us") == "103" and "sys.cxl_shm.recv_adaptive.odd" not in kv,
              "name value lines kept, mixed lines skipped")
        ds_texts = snaps
    else:
        ds_texts = [emitted(1), emitted(3)]
    d, ds_cols = run_dir(a.scratch, "ds", ds_texts)
    p, pop_cols = run_dir(a.scratch, "pop", [emitted(1, ds=False), emitted(3, ds=False)])
    h, hw_cols = run_dir(a.scratch, "hw", ["t_mono_ns=1000000000\ncpu.idle=5\n", "t_mono_ns=3000000000\ncpu.idle=9\n"])
    f = lambda r, c: float(r[c]) if r.get(c, "") != "" else None
    check(f(d, "sys.swmc.destijl.wr_round_ns") == 2000 and f(d, "sys.swmc.destijl.wr_rounds") == 20, "ds INV round delta")
    check(f(d, "sys.swmc.destijl.srv_inv_pickup_bound_ns") == 800 and f(d, "sys.swmc.destijl.srv_inv_last_h_ns") == 60, "ds serve deltas")
    check(f(d, "sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b6") == 14, "histogram bucket delta")
    check(f(d, "sys.cxl_shm.recv_adaptive.gap_ewma_us") == 103, "recv_adaptive gap_ewma_us is a gauge")
    check(all(c in pop_cols for c in stats_delta.STABLE) and all(c in ds_cols for c in stats_delta.STABLE), "STABLE columns in pop and ds")
    check(p["sys.swmc.destijl.wr_round_ns"] == "" and p["sys.cxl_shm.rx_inv_count"] == "", "pop: De Stijl-only columns empty")
    check(f(p, "sys.cxl_shm.r_found_after_timeout") == 10 and f(p, "sys.cxl_shm.recv_adaptive.r_sleep_found_us_log2.b5") == 6, "pop receiver deltas")
    check(not any(c.startswith("sys.") for c in hw_cols), "all-HWcc run: no STABLE columns")
    print("stats_rca_export_test:", "PASS" if fails == 0 else f"FAIL ({fails})", "(proc_stats.h end to end)" if a.proc_bin else "(stats_delta.py only)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

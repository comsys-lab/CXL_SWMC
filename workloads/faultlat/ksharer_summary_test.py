#!/usr/bin/env python3
"""Host unit test of ksharer_summary.py (synthetic writer raw files and status snapshots; no device, no build).

Usage: python3 -I ksharer_summary_test.py   -> prints "ksharer_summary_test: all PASS" or fails with an assertion.
"""
import csv
import io
import os
import sys
import tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ksharer_summary as ks  # noqa: E402


def raw(path, rows, keys=("write_faults", "write_transactions", "write_msg_wait_ns")):
    with open(path, "w") as f:
        f.write("pass,index,ns," + ",".join(keys) + "\n")
        for i, (ns, wf, tx, w) in enumerate(rows):
            f.write(f"0,{i},{ns},{wf},{tx},{w}\n")


def status(path, d):
    with open(path, "w") as f:
        for k, v in d.items():
            f.write(f"{k}={v}\n")
        f.write("dmesg: shm_cxl something=1\n")


def run(args):
    buf = io.StringIO()
    with redirect_stdout(buf):
        ks.main(args)
    return buf.getvalue()


def main():
    t = tempfile.mkdtemp(prefix="ksharer-test-")
    d = os.path.join(t, "vm0")
    os.mkdir(d)
    # round 0: 100 samples ns 1000..100000 step 1000, wait = ns / 2; round 1: 100 samples ns 101000..200000
    raw(os.path.join(d, "k2_idle_r0_write.csv"), [(1000 * (i + 1), 1, 1, 500 * (i + 1)) for i in range(100)])
    raw(os.path.join(d, "k2_idle_r1_write.csv"), [(1000 * (i + 101), 1 if i else 0, 2 if i == 5 else 1, 500 * (i + 101))
                                                  for i in range(100)])
    # another cell in the same dir must be ignored
    raw(os.path.join(d, "k1_idle_r0_write.csv"), [(5, 1, 1, 5)])
    sd = os.path.join(t, "shm")
    os.mkdir(sd)
    for j in range(4):
        status(os.path.join(sd, f"status-flk-k2-idle-pre-vm{j}.txt"),
               {"ds.inv_wait_spins": 10, "ds.inv_self_remove_retries": 3, "ds.inv_self_remove_atomic": 100,
                "ds.protocol_error": 0, "dmesg_bad": 2})
        status(os.path.join(sd, f"status-flk-k2-idle-post-vm{j}.txt"),
               {"ds.inv_wait_spins": 10 + 7 * j, "ds.inv_self_remove_retries": 3 + j, "ds.inv_self_remove_atomic": 105,
                "ds.protocol_error": 0, "dmesg_bad": 2})
    out = os.path.join(t, "out.csv")
    common = ["--dir", d, "--system", "ds", "--build", "11", "--knobs", "on", "--n", "4", "--k", "2", "--mode", "idle",
              "--csv", out, "--evidence", "recovery/x"]
    run(common + ["--status-dir", sd, "--status-pre", "flk-k2-idle-pre", "--status-post", "flk-k2-idle-post",
                  "--ple-exits", "1234", "--kvm-exits", "5678"])
    rows = list(csv.DictReader(open(out)))
    assert len(rows) == 1, rows
    r = rows[0]
    assert r["samples"] == "200" and r["rounds"] == "2", r
    # 200 sorted samples 1000..200000: p50 = v[100] = 101000 ns, p99 = v[198] = 199000 ns
    assert r["write_p50_us"] == "101.00" and r["write_p99_us"] == "199.00", r
    assert r["inv_wait_p50_us"] == "50.50" and r["inv_wait_p99_us"] == "99.50", r
    assert r["inv_wait_spins_delta"] == str(7 * (0 + 1 + 2 + 3)) and r["inv_self_remove_retries_delta"] == "6", r
    assert r["inv_self_remove_atomic_delta"] == "20" and r["ple_exits_delta"] == "1234" and r["kvm_exits_delta"] == "5678", r
    assert r["bad_samples"] == "1" and r["tx_per_write_mean"] == "1.005" and r["errors"] == "0", r
    assert r["k"] == "2" and r["n"] == "4" and r["build"] == "11" and r["knobs"] == "on", r
    # second row appends under the same header; Popcorn: no ds counters -> empty columns
    for j in range(4):
        status(os.path.join(sd, f"status-p-pre-vm{j}.txt"), {"swmc.transaction_error_count": 1, "dmesg_bad": 0})
        status(os.path.join(sd, f"status-p-post-vm{j}.txt"), {"swmc.transaction_error_count": 1 + (j == 3),
                                                              "dmesg_bad": 0})
    run(["--dir", d, "--system", "pop", "--build", "13-recv2", "--knobs", "-", "--n", "4", "--k", "1", "--mode", "idle",
         "--csv", out, "--status-dir", sd, "--status-pre", "p-pre", "--status-post", "p-post"])
    rows = list(csv.DictReader(open(out)))
    assert len(rows) == 2 and rows[1]["inv_wait_spins_delta"] == "" and rows[1]["errors"] == "1", rows[1]
    assert rows[1]["samples"] == "1" and rows[1]["write_p99_us"] == "0.01", rows[1]
    assert open(out).read().count("system,build,knobs") == 1
    # failures: missing round, missing column, wrong header
    os.rename(os.path.join(d, "k2_idle_r0_write.csv"), os.path.join(d, "k2_idle_r7_write.csv"))
    try:
        run(common)
        raise AssertionError("rounds gap not refused")
    except SystemExit as e:
        assert "rounds" in str(e), e
    os.rename(os.path.join(d, "k2_idle_r7_write.csv"), os.path.join(d, "k2_idle_r0_write.csv"))
    with open(os.path.join(d, "k3_warm_r0_write.csv"), "w") as f:
        f.write("pass,index,ns\n0,0,5\n")
    try:
        run(["--dir", d, "--system", "ds", "--build", "10", "--knobs", "-", "--n", "4", "--k", "3", "--mode", "warm",
             "--csv", out])
        raise AssertionError("missing columns not refused")
    except SystemExit as e:
        assert "columns" in str(e), e
    bad = os.path.join(t, "bad.csv")
    with open(bad, "w") as f:
        f.write("a,b\n")
    try:
        run(common[:-4] + ["--csv", bad])
        raise AssertionError("header mismatch not refused")
    except SystemExit as e:
        assert "header" in str(e), e
    print("ksharer_summary_test: all PASS")


if __name__ == "__main__":
    main()

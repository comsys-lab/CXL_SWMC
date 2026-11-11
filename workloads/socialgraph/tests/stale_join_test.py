#!/usr/bin/env python3
"""Unit test of tools/sg_stale_join.py on synthetic logs (Host only). usage: python3 -I stale_join_test.py <scratch dir>

Host time H (ns). VM 0 clock = H + 2 ms, VM 1 clock = H - 6 ms drifting to H - 4 ms (linear over the clock log).
Record A (node slot 5): VM 0 commits version 2 at H = 10 s and version 3 at H = 20 s; record B (list 7): VM 1 commits
version 1 at H = 15 s. Reads (expected stale age in Host time):
  VM 1 reads A v1 at H = 12 s -> stale, age 2 s (oldest newer = v2 at 10 s)
  VM 1 reads A v1 at H = 25 s -> stale, age 15 s (v2 at 10 s, not v3)
  VM 1 reads A v2 at H = 19 s -> fresh (v3 committed later)
  VM 1 reads A v3 at H = 30 s -> fresh (no newer version)
  VM 0 reads B v0 at H = 15.0005 s -> stale, age 0.5 ms (VM 1's commit, cross-clock)
  VM 0 reads B v0 at H = 14.999 s -> fresh (read before the commit)
  VM 0 reads C v9 at H = 16 s -> fresh (never written)
"""
import importlib.util, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sg_stale_join", os.path.join(HERE, "..", "tools", "sg_stale_join.py"))
J = importlib.util.module_from_spec(spec)
spec.loader.exec_module(J)

S = 10**9
H0 = 1_800_000_000 * S  # Host epoch of the synthetic run


def off_ms(vm, h):  # true guest - host offset (ms) at Host time h
    if vm == 0:
        return 2.0
    return -6.0 + 2.0 * (h - H0) / (40 * S)  # -6 ms at H0, -4 ms at H0 + 40 s


def guest(vm, h):
    return h + int(round(off_ms(vm, h) * 1e6))


def write(path, magic, node, every, entries):
    with open(path, "wb") as f:
        f.write(J.HDR.pack(magic, node, 24, every, H0))
        for e in entries:
            f.write(J.ENT.pack(*e))


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=False)
    A, B, C = (1 << 40) | 5, (2 << 40) | 7, (1 << 40) | 9
    h = lambda s: H0 + int(s * S)
    write(f"{d}/stale-commits-n0.bin", b"SGSTLC01", 0, 1, [(A, 2, guest(0, h(10))), (A, 3, guest(0, h(20)))])
    write(f"{d}/stale-commits-n1.bin", b"SGSTLC01", 1, 1, [(B, 1, guest(1, h(15)))])
    write(f"{d}/stale-reads-n1.bin", b"SGSTLR01", 1, 1000,
          [(A, 1, guest(1, h(12))), (A, 1, guest(1, h(25))), (A, 2, guest(1, h(19))), (A, 3, guest(1, h(30)))])
    write(f"{d}/stale-reads-n0.bin", b"SGSTLR01", 0, 1000,
          [(B, 0, guest(0, h(15.0005))), (B, 0, guest(0, h(14.999))), (C, 9, guest(0, h(16)))])
    # clock log: one ok row per VM every 10 s over [H0, H0 + 40 s] (rtt 0.4 / 0.2 ms), plus an error row
    with open(f"{d}/clock.tsv", "w") as f:
        f.write("host_ns\tvm\toffset_ms\trtt_ms\tstatus\n")
        for k in range(5):
            hh = H0 + k * 10 * S
            f.write(f"{hh}\tvm0\t{off_ms(0, hh)}\t0.4\tok\n{hh}\tvm1\t{off_ms(1, hh)}\t0.2\tok\n")
        f.write(f"{H0 + 5 * S}\tvm1\t\t\tno-reply\n")
    fails = 0

    def check(c, msg):
        nonlocal fails
        if not c:
            print("FAIL", msg)
            fails += 1

    out = J.run(d, [f"{d}/clock.tsv"], {0: "vm0", 1: "vm1"}, None, t_ms=1000.0, system="ds")
    print(json.dumps(out, sort_keys=True))
    al, li = out["all"], out["list"]
    check(al["reads"] == 7 and al["stale"] == 3, "counts (all records)")
    check(abs(al["stale_frac"] - 3 / 7) < 1e-12, "stale_frac (all records)")
    check(abs(al["stale_age_max_ms"] - 15000.0) < 1e-3, "max age (oldest newer version, not the newest)")
    check(abs(al["stale_age_p50_ms"] - 2000.0) < 1e-3, "p50 over stale reads")
    check(abs(al["stale_age_p99_ms"] - 15000.0) < 1e-3, "p99 over stale reads")
    check(abs(al["stale_age_p99_all_ms"] - 15000.0) < 1e-3, "p99 over all reads")
    # join split (verifier M3): top level = node slots A, C (5 reads, 2 stale: 2 s, 15 s); list = B (2 reads, 1 stale 0.5 ms)
    check(out["reads"] == 5 and out["stale"] == 2 and abs(out["stale_frac"] - 0.4) < 1e-12, "node-slot split counts")
    check(abs(out["stale_age_max_ms"] - 15000.0) < 1e-3 and abs(out["stale_age_p50_ms"] - 2000.0) < 1e-3, "node-slot ages")
    check(abs(out["stale_age_p99_all_ms"] - 15000.0) < 1e-3, "node-slot p99 over all reads")
    check(li["reads"] == 2 and li["stale"] == 1 and abs(li["stale_frac"] - 0.5) < 1e-12, "list split counts")
    # 0.5 ms within 1 us (the linear clock interpolation of the drifting VM 1 offset rounds to ns)
    check(abs(li["stale_age_max_ms"] - 0.5) < 1e-3 and abs(li["stale_age_p99_ms"] - 0.5) < 1e-3, "list ages")
    check("pass" not in li and "caveat" in li and out["records"].startswith("node"), "list: caveat, no pass")
    check(out["stale_within_err"] == 0 and li["stale_within_err"] == 0 and li["stale_beyond_err"] == 1,
          "0.5 ms list age > err 0.3 ms: not within the clock error")
    check(out["clock_noise_flag"] == 0, "ds: no clock-noise flag")
    check(out["clock_corrected"] == 1 and abs(out["offset_err_ms"] - 0.3) < 1e-9, "offset error = 0.2 + 0.1 ms")
    check(out["pass"] == 0, "15 s > T + err fails the bound (node slots)")
    check(out["commit_order_errors"] == 0, "commit order")
    # clock noise (L5): a coherent system's 0.1 ms stale age under a 0.3 ms error bound is flagged as clock noise
    jn = J.join([(A, 1, h(1) + 100_000)], [(A, 2, h(1))])
    sn = J.summarize(jn, 0.3, True, system="pop", kind=J.KIND_NODE)
    check(sn["stale"] == 1 and sn["stale_within_err"] == 1 and sn["stale_beyond_err"] == 0 and sn["clock_noise_flag"] == 1,
          "pop: within-error age flagged as clock noise")
    check(J.summarize(jn, 0.3, True, kind=J.KIND_LIST)["reads"] == 0, "empty kind")
    # the cross-clock read of B: age 0.5 ms only after correction
    j = J.join([(B, 0, h(15.0005))], [(B, 1, h(15))])
    check(j["stale"] == 1 and j["ages"] == [500000], "host-time join")
    raw = J.run(d)  # uncorrected: VM 0 reads at H+2 ms vs VM 1 commit at H-~5.5 ms: both B reads look stale
    check(raw["clock_corrected"] == 0 and raw["offset_err_ms"] == 0.0, "uncorrected flags")
    check(raw["all"]["stale"] == 4, f"uncorrected stale count {raw['all']['stale']} (clock offsets matter)")
    # windows: only reads with Host time in [11 s, 13 s] or [24 s, 26 s]
    w = J.run(d, [f"{d}/clock.tsv"], {0: "vm0", 1: "vm1"}, [(h(11), h(13)), (h(24), h(26))])
    check(w["reads"] == 2 and w["stale"] == 2 and w["all"]["reads"] == 2, "windows")
    # a torn last entry is ignored
    with open(f"{d}/stale-reads-n1.bin", "ab") as f:
        f.write(b"\x01\x02\x03")
    check(J.run(d)["all"]["reads"] == 7, "torn tail")
    print(f"stale join test {'PASS' if not fails else 'FAIL'} ({fails} failures)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

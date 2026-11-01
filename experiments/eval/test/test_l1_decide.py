#!/usr/bin/env python3
"""Unit test of l1_decide.py (eval3 L1 step of h2n-block.sh): mg pass, mg start fail, mg confirm fail, no mg row,
later file wins (resume / own block last). Run: python3 -I -B experiments/eval/test/test_l1_decide.py"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "l1_decide.py")
HDR = "# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\topcoh_check\n"


def tsv(d, name, rows):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        f.write(HDR + "".join("\t".join(r) + "\n" for r in rows))
    return p


def run(mix, files, systems=None):
    extra = ["--systems", systems] if systems is not None else []
    r = subprocess.run([sys.executable, "-I", "-B", TOOL, "--mix", mix, "--nodes", "2", "--start", "10"] + extra + files,
                       capture_output=True, text=True)
    return r.returncode, r.stdout.strip().split("\t")


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        b1 = tsv(d, "mg-u10.tsv", [["mg-u10-n2", "mg", "u10", "10", "2", "4", "108.037", "97.7114", "True", "",
                                    "mg-u10-n2/slo", "PASS"]])
        sf = tsv(d, "mg-u90.tsv", [["mg-u90-n2", "mg", "u90", "90", "2", "4", "", "", "", "the start rate already "
                                    "violates the SLO; lower --start", "mg-u90-n2/slo", "PASS"]])
        cf = tsv(d, "mg-u50.tsv", [["mg-u50-n2", "mg", "u50", "50", "2", "4", "21.5", "10.9", "False", "confirm "
                                    "failed at three rates; the knee is noisy (longer --confirm-s?)", "x", "PASS"]])
        v2 = tsv(d, "mg-u10-v2.tsv", [["mg-u10-n2", "mg", "u10", "10", "2", "4", "120", "99.0", "True", "", "x", "PASS"]])
        own = tsv(d, "own.tsv", [["pop-u10-n2", "pop", "u10", "10", "2", "4", "200", "180", "True", "", "x", "PASS"]])
        cases = [
            ("mg pass u10: 97.7114 / 0.9", run("u10", [b1, own]), (0, "108.57", "1")),
            ("mg start fail u90: ramp start, no step", run("u90", [sf, own]), (0, "10", "0")),
            ("mg confirm fail u50: ramp start, no step", run("u50", [cf]), (0, "10", "0")),
            ("no mg row, mg only (B1 rule): exit 1", run("u10", [own, os.path.join(d, "missing.tsv")], "mg"),
             (1, "none", "0")),
            ("no mg row, default systems: pop's max 180 / 0.9", run("u10", [own, os.path.join(d, "missing.tsv")]),
             (0, "200.00", "1")),
            ("min rule: pop below mg -> pop's max", run("u10", [b1, tsv(d, "pop-lo.tsv", [["pop-u10-n2", "pop", "u10",
                "10", "2", "4", "90", "81.0", "True", "", "x", "PASS"]])]), (0, "90.00", "1")),
            ("min rule ignored with --systems mg (B1 reproducible)", run("u10", [b1, os.path.join(d, "pop-lo.tsv")],
                                                                          "mg"), (0, "108.57", "1")),
            ("min over 3: hw lowest", run("u50", [tsv(d, "three.tsv", [
                ["mg-u50-n2", "mg", "u50", "50", "2", "4", "30", "25.0", "True", "", "x", "PASS"],
                ["pop-u50-n2", "pop", "u50", "50", "2", "4", "30", "22.0", "True", "", "x", "PASS"],
                ["hw-u50-n2", "hw", "u50", "50", "2", "4", "30", "21.5", "True", "", "x", "PASS"]])]), (0, "43.00", "1")),
            ("pop start fail -> ramp start", run("u90", [tsv(d, "popsf.tsv", [
                ["mg-u90-n2", "mg", "u90", "90", "2", "4", "5", "4.0", "True", "", "x", "PASS"],
                ["pop-u90-n2", "pop", "u90", "90", "2", "4", "", "", "", "start fail", "x", "PASS"]])]), (0, "10", "0")),
            ("pop confirm fail with a pass is skipped", run("u50", [tsv(d, "popcf.tsv", [
                ["mg-u50-n2", "mg", "u50", "50", "2", "4", "30", "25.0", "True", "", "x", "PASS"],
                ["pop-u50-n2", "pop", "u50", "50", "2", "4", "21.5", "10.9", "False", "confirm failed", "x", "PASS"]])]),
             (0, "50.00", "1")),
            ("ds rows never count", run("u10", [tsv(d, "ds.tsv", [
                ["ds-u10-n2", "ds", "u10", "10", "2", "4", "30", "9.0", "True", "", "x", "PASS"]]), b1]), (0, "108.57", "1")),
            ("later file wins (v2 after v1)", run("u10", [b1, v2]), (0, "110.00", "1")),
            ("wrong node count row ignored", run("u10", [tsv(d, "n4.tsv", [["mg-u10-n4", "mg", "u10", "10", "4", "4",
                                                                          "1", "50", "True", "", "x", "PASS"]])]),
             (1, "none", "0")),
        ]
        for name, (rc, out), (wrc, wl1, wapp) in cases:
            ok = rc == wrc and out[0] == wl1 and out[1] == wapp
            fails += not ok
            print(("PASS" if ok else "FAIL") + f"  {name}: rc={rc} out={out}")
    print(f"L1 DECIDE TEST {'PASS' if not fails else 'FAIL'} ({fails} failures)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Unit test (Host): tools/classify_retries.py on a synthetic trace.  usage: classify_retries_test.py <scratch dir>"""
import csv, os, subprocess, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "tools", "classify_retries.py")
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from classify_retries import RETRY, WSEC  # noqa: E402


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    # writes: (seq, id, off0, len0, off1, len1, t, node)
    w0 = np.array([(1, 0xA, 0, 64, 0, 0, 10, 0), (4, 0xB, 128, 64, 4096, 192, 40, 0)], dtype=WSEC)
    w1 = np.array([(2, 0xA, 1024, 128, 0, 0, 20, 1), (3, 0xA, 0, 64, 0, 0, 30, 1), (5, 0xC, 0, 64, 0, 0, 50, 1)],
                  dtype=WSEC)
    # retries on node 0: (id, off, len, s0, s1, t, node)
    r0 = np.array([(0xA, 2048, 64, 1, 2, 21, 0),    # peer seq 2 on A, disjoint            -> false
                   (0xA, 0, 64, 2, 3, 31, 0),       # peer seq 3 on A [0,64) overlaps      -> true
                   (0xA, 0, 2048, 0, 3, 32, 0),     # peer 2 + 3 (one overlaps); own seq 1 -> true, local 1
                   (0xB, 4096, 64, 3, 4, 41, 0),    # only own write seq 4                  -> unexplained
                   (0xC, 0, 64, 4, 4, 49, 0)],      # empty interval; seq 5 just after     -> unexplained (slack 1: true)
                  dtype=RETRY)
    w0.tofile(os.path.join(d, "node0.megalon-wsec.bin"))
    w1.tofile(os.path.join(d, "node1.megalon-wsec.bin"))
    r0.tofile(os.path.join(d, "node0.megalon-retry.bin"))
    np.zeros(0, dtype=RETRY).tofile(os.path.join(d, "node1.megalon-retry.bin"))
    fails = 0
    for slack, want in [(0, ["false_sharing", "true_sharing", "true_sharing", "unexplained", "unexplained"]),
                        (1, ["false_sharing", "true_sharing", "true_sharing", "unexplained", "true_sharing"])]:
        out = os.path.join(d, f"s{slack}")
        subprocess.run([sys.executable, TOOL, "--trace", d, "--out", out, "--slack", str(slack)], check=True,
                       stdout=subprocess.DEVNULL)
        rows = list(csv.DictReader(open(out + ".retries.csv")))
        got = [r["class"] for r in rows]
        if got != want:
            fails += 1
            print("FAIL slack", slack, got)
        if slack == 0 and (rows[2]["n_local_same_obj"] != "1" or rows[2]["n_peer_same_obj"] != "2"):
            fails += 1
            print("FAIL counts", rows[2])
    print("PASSED" if not fails else f"FAILED ({fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

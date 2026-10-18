#!/usr/bin/env python3
"""Per-page read-fault CDF from ftrace hist dumps (H3 characterization pass; reports/ROCKSDB-V1-packet.md §H3-b).

Input: one or more files holding `cat /sys/kernel/tracing/events/swmc/acct/hist` of one step (one file per VM),
trigger `hist:keys=pfn:vals=hitcount` on the kprobe event swmc/acct (swmc_fault_account, filter kind==0 && tr==1:
I->S read faults). Lines look like "{ pfn:   12345678 } hitcount:   7"; the footer has "Dropped: N".
usage: h3-page-cdf.py HIST [HIST ...] [--out cdf.csv]
Output: faults-per-page distribution over all pages of all VMs (pages = distinct pfn per VM; the same shared page on
two VMs counts once per VM): rows (faults_per_page, pages, cum_pages_frac, cum_faults_frac); prints the totals, the
Dropped counts (must be 0 for a valid CDF) and percentiles.
"""
import argparse
import collections
import csv
import re
import sys

LINE = re.compile(r"\{\s*pfn:\s*(\d+)\s*\}\s*hitcount:\s*(\d+)")
DROP = re.compile(r"Dropped:\s*(\d+)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hists", nargs="+")
    ap.add_argument("--out", default="cdf.csv")
    a = ap.parse_args()
    per_page = []
    dropped = 0
    for h in a.hists:
        for line in open(h, errors="replace"):
            m = LINE.search(line)
            if m:
                per_page.append(int(m.group(2)))
            d = DROP.search(line)
            if d:
                dropped += int(d.group(1))
    if not per_page:
        sys.exit("no hist entries")
    hist = collections.Counter(per_page)
    pages, faults = len(per_page), sum(per_page)
    cp = cf = 0
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["faults_per_page", "pages", "cum_pages_frac", "cum_faults_frac"])
        for k in sorted(hist):
            cp += hist[k]
            cf += k * hist[k]
            w.writerow([k, hist[k], cp / pages, cf / faults])
    s = sorted(per_page)
    pct = {p: s[min(len(s) - 1, int(p / 100 * len(s)))] for p in (50, 90, 99, 99.9)}
    print(f"pages={pages} faults={faults} mean={faults / pages:.3f} p50={pct[50]} p90={pct[90]} p99={pct[99]} "
          f"p99.9={pct[99.9]} max={s[-1]} dropped={dropped} -> {a.out}")
    if dropped:
        print("WARNING: Dropped > 0: the hist map overflowed, the CDF is incomplete")
        sys.exit(1)


if __name__ == "__main__":
    main()

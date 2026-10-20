#!/usr/bin/env python3
"""CXL.mem bandwidth per measurement step (Host only, read only).

usage: cxl-bw.py <sampler dir> <block dir> [<out csv>]
<sampler dir>: output of cxl-bw-sampler.sh (perf.csv, start-epoch.txt). <block dir>: an evaluation block dir; every
*/stats-steps.csv below it is read (one row per step and target; begin_wall_ns / end_wall_ns = guest wall clock).
For every step, the perf intervals lying fully inside [begin, end] are averaged:
  read_MBps  = rxc mem_data x 64 / interval      (Intel PCM rule, SPR non-BHS)
  write_MBps = txc mem_data x 64 x 0.5 / interval
  read_B_per_op, write_B_per_op = bytes / (offered_x x window)  (offered_x = total offered op rate of the step)
Output CSV columns: lifetime,step,phase,offered_x,begin_s,end_s,n_intervals,read_MBps,write_MBps,read_B_per_op,
write_B_per_op. A step with no interval fully inside is written with n_intervals 0 and empty values.
"""
import csv
import glob
import os
import sys

RD, WR = "unc_cxlcm_rxc_pack_buf_inserts.mem_data", "unc_cxlcm_txc_pack_buf_inserts.mem_data"


def intervals(sd):
    t0 = float(open(os.path.join(sd, "start-epoch.txt")).read())
    rows = {}
    for f in csv.reader(open(os.path.join(sd, "perf.csv"))):
        if len(f) < 6 or f[0].startswith("#") or f[5] not in (RD, WR):
            continue
        rows.setdefault(float(f[0]), {})[f[5]] = rows.get(float(f[0]), {}).get(f[5], 0) + int(f[3])
    out, prev = [], 0.0
    for t in sorted(rows):  # perf -I: t = seconds since start at the END of the interval
        out.append((t0 + prev, t0 + t, rows[t].get(RD, 0) * 64, rows[t].get(WR, 0) * 64 * 0.5))
        prev = t
    return out


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    iv = intervals(sys.argv[1])
    w = csv.writer(open(sys.argv[3], "w", newline="") if len(sys.argv) == 4 else sys.stdout)
    w.writerow(["lifetime", "step", "phase", "offered_x", "begin_s", "end_s", "n_intervals", "read_MBps",
                "write_MBps", "read_B_per_op", "write_B_per_op"])
    for p in sorted(glob.glob(os.path.join(sys.argv[2], "**", "stats-steps.csv"), recursive=True)):
        life = os.path.relpath(os.path.dirname(p), sys.argv[2])
        seen = set()
        for r in csv.DictReader(open(p)):
            key = (r["step"], r["phase"])
            if key in seen or not r.get("begin_wall_ns") or not r.get("end_wall_ns"):
                continue  # one row per step (rows repeat per target with the same window)
            seen.add(key)
            b, e = int(r["begin_wall_ns"]) / 1e9, int(r["end_wall_ns"]) / 1e9
            sel = [x for x in iv if x[0] >= b and x[1] <= e]
            if not sel:
                w.writerow([life, r["step"], r["phase"], r["offered_x"], f"{b:.3f}", f"{e:.3f}", 0, "", "", "", ""])
                continue
            dt = sum(x[1] - x[0] for x in sel)
            rb, wb = sum(x[2] for x in sel), sum(x[3] for x in sel)
            ops = float(r["offered_x"] or 0) * dt
            w.writerow([life, r["step"], r["phase"], r["offered_x"], f"{b:.3f}", f"{e:.3f}", len(sel),
                        f"{rb / dt / 1e6:.1f}", f"{wb / dt / 1e6:.1f}",
                        f"{rb / ops:.0f}" if ops > 0 else "", f"{wb / ops:.0f}" if ops > 0 else ""])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""socialgraph staleness join (experiment socialgraph-serving §2 "Observed staleness"). Host only, offline, read only.

Inputs (sg-server --stale-dir, server/stale_log.h): per VM k
  stale-reads-n<k>.bin    32 B header {magic "SGSTLR01", u32 node, u32 entry_bytes = 24, u64 every, u64 t_open_ns}, then
                          {u64 rid, u64 version, u64 t_ns}: 1 in `every` records read (rid = kind << 40 | slot; kind 1
                          node slot, 2 adjacency list), t_ns = CLOCK_REALTIME of VM k right after the read
  stale-commits-n<k>.bin  same layout, magic "SGSTLC01": every committed write of VM k's writer (new version, t_ns =
                          CLOCK_REALTIME of VM k right after the release store of the new version)
  --clock TSV  Host-side clock-offset log as in the RecSys T-sweep (workspaces/clock-offset-log-v1.py): host_ns, vm (IP),
               offset_ms = guest - host (min-RTT ping midpoint, error <= rtt_ms / 2), rtt_ms, status ("ok" rows only)
  --vm K=IP    which clock-log vm is node K (repeat per node; needed with --clock)
  --windows TSV  optional measured windows in Host CLOCK_REALTIME ns ("start_ns<TAB>end_ns" rows, header optional):
               only reads whose Host time lies in a window are counted (commits are always used)
Formulas
  Host time     t_h = t - offset_k(t) * 1e6 for an entry of VM k, offset_k = offset_ms of k's vm linearly interpolated
                between its ok rows (constant beyond the first / last row; as staleness_cdf.py of the RecSys T-sweep);
                without --clock t_h = t (clock_corrected 0)
  stale / age   per read (rid, v, t_h): c = the commit of rid with the smallest version > v (the oldest committed
                version newer than the one read); stale iff c exists and t_h(c) <= t_h(read); age = t_h(read) - t_h(c),
                0 for a fresh read (versions are committed in increasing order per record, so no newer version was
                committed before the read when c was not)
  stale_frac    stale reads / reads; stale_age_{p50,p99,max}_ms over the stale reads (nearest rank; RecSys convention),
                stale_age_p99_all_ms over all reads (fresh = 0)
  offset_err_ms bound of the clock correction error between two VMs: the two largest per-VM max(rtt_ms / 2) (0 uncorrected)
  pass          with --t-ms T: stale_age_max_ms <= T + offset_err_ms
usage: python3 -I sg_stale_join.py --dir D [--clock TSV ...] [--vm K=IP ...] [--windows TSV] [--t-ms T] [--json OUT]
"""
import argparse, bisect, csv, glob, json, math, os, struct, sys

HDR = struct.Struct("<8sIIQQ")
ENT = struct.Struct("<QQQ")


def read_log(path, magic):
    with open(path, "rb") as f:
        b = f.read()
    if len(b) < HDR.size:
        raise ValueError(f"{path}: short header")
    m, node, eb, every, _t0 = HDR.unpack_from(b, 0)
    if m != magic or eb != ENT.size:
        raise ValueError(f"{path}: bad header ({m!r}, entry {eb})")
    n = (len(b) - HDR.size) // ENT.size  # a torn last entry (server killed mid-write) is ignored
    return node, every, [ENT.unpack_from(b, HDR.size + i * ENT.size) for i in range(n)]


def read_clock(paths):
    """vm -> ([host_ns], [offset_ms], [rtt_ms]) of ok rows, sorted by host_ns"""
    rows = {}
    for p in paths:
        for r in csv.DictReader(open(p), delimiter="\t"):
            if r.get("status") != "ok":
                continue
            rows.setdefault(r["vm"], []).append((int(r["host_ns"]), float(r["offset_ms"]), float(r["rtt_ms"])))
    return {vm: ([x[0] for x in sorted(v)], [x[1] for x in sorted(v)], [x[2] for x in sorted(v)]) for vm, v in rows.items()}


def interp(xs, ys, x):
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    i = bisect.bisect_right(xs, x)
    x0, x1, y0, y1 = xs[i - 1], xs[i], ys[i - 1], ys[i]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0) if x1 != x0 else y1


def pct(xs, p):  # nearest rank on a sorted list
    if not xs:
        return None
    return xs[max(0, math.ceil(p / 100.0 * len(xs)) - 1)]


def join(reads, commits, windows=None):
    """reads / commits: [(rid, version, t_host_ns)] -> dict of counts and ages (ns)"""
    by = {}
    for rid, v, t in commits:
        by.setdefault(rid, []).append((v, t))
    idx = {}
    order_errors = 0
    for rid, cs in by.items():
        cs.sort()
        for (v0, t0), (v1, t1) in zip(cs, cs[1:]):
            if v1 == v0 or t1 < t0:
                order_errors += 1
        idx[rid] = ([v for v, _ in cs], [t for _, t in cs])
    win = sorted(windows or [])
    wst = [w[0] for w in win]

    def measured(t):
        if not windows:
            return True
        i = bisect.bisect_right(wst, t) - 1
        return i >= 0 and t <= win[i][1]

    n = stale = 0
    ages = []
    for rid, v, t in reads:
        if not measured(t):
            continue
        n += 1
        if rid not in idx:
            continue
        vs, ts = idx[rid]
        i = bisect.bisect_right(vs, v)
        if i < len(vs) and ts[i] <= t:
            stale += 1
            ages.append(t - ts[i])
    ages.sort()
    return dict(reads=n, stale=stale, ages=ages, commit_order_errors=order_errors)


def summarize(j, err_ms, corrected, t_ms=None):
    ages = j["ages"]
    all_ages = [0] * (j["reads"] - j["stale"]) + ages  # sorted: zeros first
    ms = lambda x: None if x is None else x / 1e6
    out = dict(reads=j["reads"], stale=j["stale"], stale_frac=(j["stale"] / j["reads"]) if j["reads"] else None,
               stale_age_p50_ms=ms(pct(ages, 50)), stale_age_p99_ms=ms(pct(ages, 99)),
               stale_age_max_ms=ms(ages[-1]) if ages else 0.0, stale_age_p99_all_ms=ms(pct(all_ages, 99)),
               clock_corrected=int(corrected), offset_err_ms=err_ms, commit_order_errors=j["commit_order_errors"])
    if t_ms is not None:
        out["t_ms"] = t_ms
        out["pass"] = int(out["stale_age_max_ms"] <= t_ms + err_ms)
    return out


def load_dir(d):
    reads, commits = {}, {}
    for p in sorted(glob.glob(os.path.join(d, "stale-reads-n*.bin"))):
        node, _, e = read_log(p, b"SGSTLR01")
        reads.setdefault(node, []).extend(e)
    for p in sorted(glob.glob(os.path.join(d, "stale-commits-n*.bin"))):
        node, _, e = read_log(p, b"SGSTLC01")
        commits.setdefault(node, []).extend(e)
    return reads, commits


def run(d, clock=None, vms=None, windows=None, t_ms=None):
    reads, commits = load_dir(d)
    if not reads and not commits:
        raise SystemExit(f"sg_stale_join: no stale-*.bin files in {d}")
    corrected, err_ms = False, 0.0
    tf = {}
    if clock:
        clk = read_clock(clock)
        nodes = set(reads) | set(commits)
        missing = [k for k in nodes if k not in (vms or {}) or vms[k] not in clk]
        if missing:
            raise SystemExit(f"sg_stale_join: no clock rows / --vm for nodes {sorted(missing)}")
        for k in nodes:
            xs, ys, rtt = clk[vms[k]]
            tf[k] = (xs, ys)
        half = sorted((max(clk[vms[k]][2]) / 2.0 for k in nodes), reverse=True)
        err_ms = sum(half[:2])
        corrected = True

    def host(k, t):
        if not corrected:
            return t
        xs, ys = tf[k]
        return t - int(round(interp(xs, ys, t) * 1e6))

    R = [(rid, v, host(k, t)) for k, es in reads.items() for rid, v, t in es]
    C = [(rid, v, host(k, t)) for k, es in commits.items() for rid, v, t in es]
    out = summarize(join(R, C, windows), err_ms, corrected, t_ms)
    out["nodes"] = sorted(set(reads) | set(commits))
    out["commits"] = len(C)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--clock", action="append")
    ap.add_argument("--vm", action="append", default=[], help="K=IP")
    ap.add_argument("--windows")
    ap.add_argument("--t-ms", type=float)
    ap.add_argument("--json")
    a = ap.parse_args()
    vms = {int(x.split("=", 1)[0]): x.split("=", 1)[1] for x in a.vm}
    win = None
    if a.windows:
        win = []
        for line in open(a.windows):
            f = line.split()
            if len(f) >= 2 and f[0].isdigit():
                win.append((int(f[0]), int(f[1])))
    out = run(a.dir, a.clock, vms, win, a.t_ms)
    txt = json.dumps(out, indent=1, sort_keys=True)
    if a.json:
        with open(a.json, "w") as f:
            f.write(txt + "\n")
    print(txt)


if __name__ == "__main__":
    main()

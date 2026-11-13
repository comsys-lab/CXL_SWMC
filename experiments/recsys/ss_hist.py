#!/usr/bin/env python3
"""De Stijl SS-residence histogram of one measurement (session.sh measure, De Stijl lifetimes only).

session.sh ss_snap writes, per node k, <M>/ss-residence-pre-t<k>.txt (before loadgen) and ss-residence-post-t<k>.txt
(after loadgen): the guest's /sys/kernel/swmc/destijl/ss_residence_hist (cumulative since reset_counters) and
ss_residence_window_hist (last 1024 completions), each after a "# <file name>" line; kernel format = 40 lines
"<bucket lower bound us> <count>" (log2 us buckets, kernel/swmc/destijl.c ds_hist_emit).
delta: <M>/ss-residence.csv, columns node, hist, lo_us, pre, post, delta (delta = post - pre for the cumulative
histogram = the measurement's SS residences; for the window histogram delta is empty: it is not cumulative), and one
summary line per node (completions in the measurement, bucket lower bounds of the 50th / 95th / max residence).
A node without both files is skipped (no De Stijl kernel, or the read failed: noted, never an error).
usage: ss_hist.py delta <measurement dir>      ss_hist.py --selftest
"""
import csv, glob, math, os, re, sys, tempfile

CUM, WIN = "ss_residence_hist", "ss_residence_window_hist"


def parse(path):
    """-> {hist name: [(lo_us, count), ...]} ; lines outside a "# <name>" section or not two integers are skipped"""
    out, cur = {}, None
    for line in open(path):
        t = line.split()
        if len(t) == 2 and t[0] == "#":
            cur = t[1]
            out.setdefault(cur, [])
        elif cur is not None and len(t) == 2 and t[0].isdigit() and t[1].isdigit():
            out[cur].append((int(t[0]), int(t[1])))
    return out


def lo_at(rows, p):
    n = sum(c for _, c in rows)
    if n == 0:
        return "-"
    k, acc = math.ceil(p / 100 * n), 0
    for lo, c in rows:
        acc += c
        if acc >= k:
            return str(lo)
    return str(rows[-1][0])


def delta(m):
    rows, notes = [], []
    nodes = sorted(int(re.search(r"-t(\d+)\.txt$", p).group(1)) for p in glob.glob(os.path.join(m, "ss-residence-post-t*.txt")))
    for k in nodes:
        a, b = (os.path.join(m, f"ss-residence-{w}-t{k}.txt") for w in ("pre", "post"))
        if not os.path.isfile(a):
            notes.append(f"node{k}: no pre snapshot")
            continue
        pre, post = parse(a), parse(b)
        for h in (CUM, WIN):
            p0, p1 = dict(pre.get(h, [])), post.get(h, [])
            if not p1:
                notes.append(f"node{k}: no {h} in the post snapshot")
                continue
            for lo, c in p1:
                rows.append({"node": k, "hist": h, "lo_us": lo, "pre": p0.get(lo, ""), "post": c,
                             "delta": (c - p0.get(lo, 0)) if h == CUM and lo in p0 else ""})
        d = [(r["lo_us"], r["delta"]) for r in rows if r["node"] == k and r["hist"] == CUM and r["delta"] != ""]
        if d:
            neg = [lo for lo, x in d if x < 0]
            mx = max((lo for lo, x in d if x > 0), default="-")
            notes.append(f"node{k}: {sum(x for _, x in d)} SS residences, p50 bucket {lo_at(d, 50)} us, p95 bucket "
                         f"{lo_at(d, 95)} us, max bucket {mx} us" + (f"; NOTE negative delta at {neg} (counters reset?)" if neg else ""))
    if rows:
        with open(os.path.join(m, "ss-residence.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["node", "hist", "lo_us", "pre", "post", "delta"], lineterminator="\n")
            w.writeheader()
            w.writerows(rows)
    print("SSHIST " + ("; ".join(notes) if notes else "no snapshot"))
    return rows


def selftest():
    def snap(cum, win):
        s = f"# {CUM}\n" + "".join(f"{1 << i if i else 0} {c}\n" for i, c in enumerate(cum))
        return s + f"# {WIN}\n" + "".join(f"{1 << i if i else 0} {c}\n" for i, c in enumerate(win))
    with tempfile.TemporaryDirectory() as m:
        z = [0] * 40
        pre = z[:]; pre[3] = 5
        post = z[:]; post[3] = 15; post[5] = 10; post[10] = 1
        open(os.path.join(m, "ss-residence-pre-t0.txt"), "w").write(snap(pre, z))
        open(os.path.join(m, "ss-residence-post-t0.txt"), "w").write(snap(post, post))
        open(os.path.join(m, "ss-residence-post-t1.txt"), "w").write("cat: No such file\n")   # failed read on node 1
        rows = delta(m)
        r = list(csv.DictReader(open(os.path.join(m, "ss-residence.csv"))))
        assert len(r) == 80 and len(rows) == 80, len(r)
        cum = {int(x["lo_us"]): x["delta"] for x in r if x["hist"] == CUM}
        assert cum[8] == "10" and cum[32] == "10" and cum[1024] == "1" and cum[0] == "0", cum
        assert all(x["delta"] == "" for x in r if x["hist"] == WIN)
        d = [(lo, int(v)) for lo, v in sorted(cum.items())]
        assert lo_at(d, 50) == "32" and lo_at(d, 95) == "32" and lo_at(d, 100) == "1024", (lo_at(d, 50), lo_at(d, 95))
    with tempfile.TemporaryDirectory() as m:   # no snapshot at all (not a De Stijl lifetime): no csv, no error
        assert delta(m) == [] and not os.path.exists(os.path.join(m, "ss-residence.csv"))
    print("SSHIST SELFTEST PASS")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if len(sys.argv) == 3 and sys.argv[1] == "delta":
        delta(sys.argv[2])
        sys.exit(0)
    sys.exit(__doc__)

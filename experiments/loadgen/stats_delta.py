#!/usr/bin/env python3
"""Per-step server counter deltas from loadgen --stats-op snapshots (experiments/loadgen/README.md).

usage: stats_delta.py RUN_DIR [--out RUN_DIR/stats-steps.csv]
RUN_DIR is a loadgen --out dir with stats/step<NNN>-{begin,end}-t<k>.txt (one header line "# when=.. phase=..
step=.. offered_x=.. target=.. addr=.. status=.. wall_ns=.. mono_ns=.. rtt_us=..", then the server's key=value text).

Output: one row per (step, target) that has both snapshots. Fixed columns: step, phase, offered_x, target, addr,
begin_wall_ns, end_wall_ns, window_s (loadgen clock: end mono_ns - begin mono_ns), srv_window_s (server clock:
t_mono_ns delta, if the server emits it), then one column per numeric key (sorted): end - begin, except gauges
(identity values, current sizes and maxima: see GAUGE below), which keep the end value. Non-numeric keys are ignored.
A key missing in one snapshot of a pair is left empty for that row.
"""
import argparse, csv, os, re, sys

FNAME = re.compile(r"^step(\d+)-(begin|end)-t(\d+)\.txt$")
# keys reported as their end value (not differenced)
GAUGE_EXACT = {"node", "write_queue", "search_queue", "megt.sample"}
GAUGE_SUFFIX = (".n", "max_ns", ".in_flight_transaction_count", ".enabled")


def is_gauge(k):
    return k in GAUGE_EXACT or k.endswith(GAUGE_SUFFIX)


def num(v):
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return None


def parse(path):
    hdr, kv = {}, {}
    with open(path) as f:
        first = f.readline()
        if first.startswith("#"):
            for tok in first[1:].split():
                k, _, v = tok.partition("=")
                hdr[k] = v
        for line in f:
            k, sep, v = line.rstrip("\n").partition("=")
            if not sep or not k:
                continue
            x = num(v.strip())
            if x is not None:
                kv[k] = x
    return hdr, kv


def load(run):
    d = os.path.join(run, "stats")
    snaps = {}
    if not os.path.isdir(d):
        return snaps
    for name in os.listdir(d):
        m = FNAME.match(name)
        if m:
            snaps.setdefault((int(m.group(1)), int(m.group(3))), {})[m.group(2)] = parse(os.path.join(d, name))
    return snaps


def deltas(run):
    """[(fixed dict, delta dict)] per (step, target) with both snapshots, in step/target order."""
    rows = []
    for (step, t), pair in sorted(load(run).items()):
        if "begin" not in pair or "end" not in pair:
            continue
        (hb, b), (he, e) = pair["begin"], pair["end"]
        fixed = {"step": step, "phase": he.get("phase", ""), "offered_x": he.get("offered_x", ""), "target": t,
                 "addr": he.get("addr", ""), "begin_wall_ns": hb.get("wall_ns", ""), "end_wall_ns": he.get("wall_ns", ""),
                 "window_s": (int(he["mono_ns"]) - int(hb["mono_ns"])) / 1e9 if "mono_ns" in he and "mono_ns" in hb else "",
                 "srv_window_s": (e["t_mono_ns"] - b["t_mono_ns"]) / 1e9 if "t_mono_ns" in e and "t_mono_ns" in b else ""}
        dv = {}
        for k in set(b) | set(e):
            if k in b and k in e:
                dv[k] = e[k] if is_gauge(k) else e[k] - b[k]
        rows.append((fixed, dv))
    return rows


FIXED = ["step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s", "srv_window_s"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--out")
    a = ap.parse_args()
    rows = deltas(a.run)
    if not rows:
        sys.exit(f"stats_delta: no begin/end snapshot pairs in {a.run}/stats")
    keys = sorted({k for _, dv in rows for k in dv})
    out = a.out or os.path.join(a.run, "stats-steps.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(FIXED + keys)
        for fixed, dv in rows:
            w.writerow([fixed[c] for c in FIXED] + [dv.get(k, "") for k in keys])
    print(f"-> {out} ({len(rows)} step/target rows, {len(keys)} keys)")


if __name__ == "__main__":
    main()

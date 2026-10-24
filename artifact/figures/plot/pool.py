"""Pooled latency-throughput points from loadgen raw per-request rows (read-only).

Every measured step of an SLO search (ramp, bisect, confirm, fill, overload) is a measurement at one offered rate.
Steps at the same offered rate (relative difference <= tol) are merged: their per-request latencies of the SLO
stream are pooled and the percentile is recomputed (nearest rank, as loadgen; never-completed requests count as
infinite); x = completions of the SLO stream per second, the window-weighted mean of the steps' achieved rates
(window = sent / offered stream rate, so aborted steps weigh less).

raw-step<N>.bin rows (CXL_SWMC/experiments/loadgen/README.md): 4 x u64 = sched ns, send ns, done ns (0 = never),
stream << 32 | status | measured << 40; latency = done - sched (loadgen.cc).
"""
import json, math, os, struct


def _raw(d, n):
    b = open(f"{d}/raw-step{n}.bin", "rb").read()
    return [struct.unpack_from("<4Q", b, i) for i in range(0, len(b), 32)]


def _pct(v, p):
    v = sorted(v)
    k = max(0, min(len(v) - 1, math.ceil(p / 100 * len(v)) - 1))
    return v[k]


def steps(d):
    out = []
    for l in open(f"{d}/steps.jsonl"):
        s = json.loads(l)
        if s.get("measure_s", 0) > 0 and s["phase"] != "warmup":
            out.append(s)
    return out


def stream_index(d, st, slo_stream):
    """Raw stream id of the SLO stream: the id whose measured count equals steps.jsonl streams[slo].sent."""
    rows = _raw(d, st["step"])
    cnt = {}
    for _, _, _, f in rows:
        if (f >> 40) & 1:
            cnt[(f >> 32) & 0xFF] = cnt.get((f >> 32) & 0xFF, 0) + 1
    want = st["streams"][slo_stream]["sent"]
    ids = [k for k, v in cnt.items() if v == want]
    others = [st["streams"][k]["sent"] for k in st["streams"] if k != slo_stream]
    assert len(ids) == 1 or (len(ids) == 2 and want in others), (d, cnt, want)
    if len(ids) == 2:  # equal counts: fall back to declaration order of streams in steps.jsonl
        names = list(st["streams"].keys())
        return names.index(slo_stream)
    return ids[0]


def pooled(d, slo_stream, pct, tol=0.0, phases=None, drop_aborted=True, split_at=None):
    """drop_aborted: leave out steps loadgen stopped early (SLO already exceeded): partial windows, few samples.
    split_at: offered rate of the confirmed max under SLO (bracket lo); a group never mixes steps at or below it with
    steps above it, so the first failing rates stay a separate point past the SLO."""
    ss = [s for s in steps(d) if (phases is None or s["phase"] in phases) and not (drop_aborted and s.get("aborted"))]
    sid = stream_index(d, ss[0], slo_stream)
    groups = []  # [rate, [steps]]
    for s in sorted(ss, key=lambda s: s["offered_x"]):
        side = split_at is not None and s["offered_x"] > split_at * (1 + 1e-9)
        gside = groups and split_at is not None and groups[-1][0] > split_at * (1 + 1e-9)
        if groups and abs(s["offered_x"] - groups[-1][0]) <= tol * groups[-1][0] and side == bool(gside):
            groups[-1][1].append(s)
        else:
            groups.append([s["offered_x"], [s]])
    pts = []
    for rate, g in groups:
        lat, xw, w = [], 0.0, 0.0
        for s in g:
            for sc, _, dn, f in _raw(d, s["step"]):
                if (f >> 40) & 1 and ((f >> 32) & 0xFF) == sid:
                    lat.append((dn - sc) / 1e6 if dn else math.inf)
            so = s["streams"][slo_stream]
            win = so["sent"] / so["offered"] if so["offered"] else s["measure_s"]
            xw += s["x"] * win; w += win
        pts.append({"offered": rate, "x": xw / w, "p": _pct(lat, pct), "n": len(lat), "steps": [s["step"] for s in g],
                    "phases": sorted({s["phase"] for s in g}), "step_p": [s["streams"][slo_stream]["pslo_ms"] for s in g]})
    return pts


def _chain(pts, idxs, dip, start=None):
    """Longest chain over pts[idxs] (offered order) with rising x and latency >= dip x previous; start = (x, p) the
    chain must continue from. Ties keep the chain ending at the highest offered rate."""
    n = len(idxs)
    ok0 = [start is None or (pts[k]["x"] > start[0] and pts[k]["p"] >= dip * start[1]) for k in idxs]
    best, prev = [1 if ok0[a] else 0 for a in range(n)], [-1] * n
    for b in range(n):
        for a in range(b):
            if best[a] and pts[idxs[b]]["x"] > pts[idxs[a]]["x"] and pts[idxs[b]]["p"] >= dip * pts[idxs[a]]["p"] \
                    and best[a] + 1 >= best[b]:
                best[b], prev[b] = best[a] + 1, a
    if not n or max(best) == 0:
        return []
    b = max(range(n), key=lambda k: (best[k], k))
    out = []
    while b >= 0:
        out.append(idxs[b]); b = prev[b]
    return out[::-1]


def shape_filter(pts, dip=0.95, slo=None, split_at=None):
    """Display filter for the curve shape (user 2026-10-18: drop points that hide the shape; show the SLO crossing).
    Points at offered rates up to split_at (the confirmed max under SLO): the longest chain in offered order whose
    throughput rises and whose latency never falls below dip x the previous drawn point. Points above split_at:
    every point past the SLO, in offered-rate order, even where the throughput goes back (the system falls
    behind), so the curve always shows the SLO crossing. Returns drawn flags; the CSV keeps every point with the flag."""
    n = len(pts)
    if split_at is None or slo is None:
        sel = _chain(pts, list(range(n)), dip)
    else:
        lo = [k for k in range(n) if pts[k]["offered"] <= split_at * (1 + 1e-9)]
        sel = _chain(pts, lo, dip)
        hi = [k for k in range(n) if k not in lo and pts[k]["p"] > slo]
        tail = hi  # every past-SLO point above the max-under-SLO rate, in offered order, even if the throughput
        #          goes back (user 2026-10-18: "include it even if it bends back")
        sel += tail
    keep = [False] * n
    for k in sel:
        keep[k] = True
    return keep

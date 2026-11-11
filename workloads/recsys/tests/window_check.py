#!/usr/bin/env python3
"""Checks of the windowed update publisher (server --publish-window-s W, reports/experiments/recsys-windowed-update.md)
from a Host test's node-0 --publish-trace file (tests/window_host_test.sh).

usage: window_check.py --trace F --W S --image IMG [--stale1 F] [--region F --swcc-offset N] [--late-tol-s 0.05]

Trace lines: "U <win> <gslot> <seq> <t_ns>" (owner DRAM update of window win), "B <win> <boundary_ns> <n> <b>" (end
of window win: its list of n distinct rows, b rows/s), "P <win> <gslot> <seq> <csum> <t_ns>" (publish of a row of
window win's list).
(1) per window: the published rows of list w = the distinct rows updated in window w, each exactly once; publish i of
    the list never before boundary + i / b s; per-second count <= b; every publish inside [boundary, boundary + W +
    tol) when no backlog; lateness (t - due) reported (p50 / p99 / max).
(2) value: every publish carries the seq of one of the row's DRAM updates and is not older than the row's last update
    of its window (last write wins); node 1 serving reads (--stale1, stale log with every row sampled) only ever see
    the initial image seq or a published seq; with --region (plain backend): every row of the shared table equals the
    image record (never published) or the row's last published (seq, csum), and every published record's csum is
    valid (key, seq, emb).
Last line: WINDOW CHECK PASS | WINDOW CHECK FAIL (<reasons>).
"""
import argparse, collections, struct, sys

HDR = 4096


def csum(key, seq, emb):
    h = (0x811c9dc5 ^ (key & 0xffffffff) ^ (key >> 32) ^ ((seq & 0xffffffff) * 0x9e3779b1)) & 0xffffffff
    for (w,) in struct.iter_unpack("<I", emb):
        h = ((h ^ w) * 0x01000193) & 0xffffffff
    return h | 1


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--trace", required=True)
    a.add_argument("--W", type=int, required=True)
    a.add_argument("--image", required=True)
    a.add_argument("--stale1")
    a.add_argument("--region")
    a.add_argument("--swcc-offset", type=int)
    a.add_argument("--late-tol-s", type=float, default=0.05)
    o = a.parse_args()
    fails = []
    U = collections.defaultdict(dict)        # win -> gslot -> max seq
    useqs = collections.defaultdict(set)     # gslot -> seqs of DRAM updates
    B = {}
    P = collections.defaultdict(list)        # win -> [(gslot, seq, csum, t)]
    for line in open(o.trace):
        f = line.split()
        if not f:
            continue
        if f[0] == "U":
            w, g, s = int(f[1]), int(f[2]), int(f[3])
            U[w][g] = max(U[w].get(g, 0), s)
            useqs[g].add(s)
        elif f[0] == "B":
            B[int(f[1])] = (int(f[2]), int(f[3]), int(f[4]))
        elif f[0] == "P":
            P[int(f[1])].append((int(f[2]), int(f[3]), int(f[4]), int(f[5])))
    W = o.W * 10**9
    late_all = []
    nonempty = 0
    last_pub = {}
    for w in sorted(B):
        bound, n, b = B[w]
        rows = U.get(w, {})
        if n != len(rows):
            fails.append(f"window {w}: list size {n} != distinct updated rows {len(rows)}")
        pl = P.get(w, [])
        if n == 0:
            if pl:
                fails.append(f"window {w}: empty list but {len(pl)} publishes")
            continue
        nonempty += 1
        got = collections.Counter(g for g, _, _, _ in pl)
        if set(got) != set(rows) or any(c != 1 for c in got.values()):
            fails.append(f"window {w}: published rows != distinct rows of the window (published {len(pl)}, "
                         f"distinct {len(rows)}, dup {sum(1 for c in got.values() if c > 1)}, "
                         f"missing {len(set(rows) - set(got))}, extra {len(set(got) - set(rows))})")
        per_s = collections.Counter()
        late = []
        for i, (g, s, c, t) in enumerate(pl):
            due = bound + (i // b) * 10**9 + (i % b) * 10**9 // b
            if t < due:
                fails.append(f"window {w}: publish {i} at {t} before its due time {due}")
                break
            late.append((t - due) / 1e9)
            per_s[(t - bound) // 10**9] += 1
            if s not in useqs[g]:
                fails.append(f"window {w}: row {g} published seq {s} that no DRAM update wrote")
            if s < rows.get(g, 0):
                fails.append(f"window {w}: row {g} published seq {s} older than its last update {rows.get(g)} of the window")
            last_pub[g] = (s, c)
        if max(per_s.values()) > b:
            fails.append(f"window {w}: a second holds {max(per_s.values())} publishes > budget {b}")
        if max(late) <= o.late_tol_s and pl[-1][3] >= bound + W + int(o.late_tol_s * 1e9):
            fails.append(f"window {w}: last publish after the window end")
        late.sort()
        late_all += late
        print(f"window {w}: distinct={n} budget={b}/s published={len(pl)} seconds_used={len(per_s)} "
              f"per_s_min={min(per_s.values())} per_s_max={max(per_s.values())} late_p50_s={late[len(late) // 2]:.4f} "
              f"late_max_s={late[-1]:.4f}")
    if not nonempty:
        fails.append("no non-empty window list")
    if late_all:
        late_all.sort()
        p99 = late_all[min(len(late_all) - 1, int(0.99 * len(late_all)))]
        print(f"lateness over {len(late_all)} publishes: p50 {late_all[len(late_all) // 2]:.4f} s p99 {p99:.4f} s "
              f"max {late_all[-1]:.4f} s")
        if p99 > o.late_tol_s:
            fails.append(f"publish lateness p99 {p99:.3f} s > {o.late_tol_s} s")
    extra = set(P) - set(B)
    if extra:
        fails.append(f"publishes of windows without a boundary line: {sorted(extra)}")
    pubseqs = collections.defaultdict(set)
    for w in P:
        for g, s, c, t in P[w]:
            pubseqs[g].add(s)
    img = open(o.image, "rb")
    ih = img.read(HDR)
    rb, rows_total = struct.unpack_from("<IQ", ih, 12)
    dim, elt = struct.unpack_from("<II", ih, 24)
    ebytes = dim * elt

    def img_rec(g):
        img.seek(HDR + g * rb)
        return img.read(rb)
    if o.stale1:
        d = open(o.stale1, "rb").read()
        n_ok = n_pub = 0
        bad = 0
        for g, s, t in struct.iter_unpack("<QQQ", d[64:]):
            if s in pubseqs.get(g, ()):
                n_pub += 1
            elif s == struct.unpack_from("<Q", img_rec(g), 8)[0]:
                n_ok += 1
            else:
                bad += 1
        print(f"node 1 reads: {n_pub} saw a published value, {n_ok} the initial image value, {bad} other")
        if bad:
            fails.append(f"node 1 read {bad} values neither initial nor published")
        if not n_pub:
            fails.append("node 1 never read a published value")
    if o.region:
        reg = open(o.region, "rb")
        nbad = npub = 0
        for g in range(rows_total):
            reg.seek(o.swcc_offset + g * rb)
            r = reg.read(rb)
            if g in last_pub:
                npub += 1
                key, seq, cs = struct.unpack_from("<QQI", r, 0)
                if (seq, cs) != last_pub[g] or csum(key, seq, r[64:64 + ebytes]) != cs:
                    nbad += 1
            elif r != img_rec(g):
                nbad += 1
        print(f"shared table: {rows_total} rows, {npub} published rows = last published (seq, csum), csum valid; "
              f"{rows_total - npub} rows = image; mismatches {nbad}")
        if nbad:
            fails.append(f"shared table: {nbad} rows differ from the last published value / the image")
    print("WINDOW CHECK PASS" if not fails else "WINDOW CHECK FAIL (" + "; ".join(fails[:8]) + ")")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())

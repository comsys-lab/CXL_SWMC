#!/usr/bin/env python3
"""SWcc layout of the vector DB plain backend (all-HWcc, Popcorn) per VM count N (new H2, vector DB VM-count scaling).
Host only, read only (reads the writes files and the region config; no device access).

Formulas = workloads/vectordb/server/backend.h PlainBackend + layout.h + shm_hnsw.h GraphParams (bytes):
  capacity = ceil(max_ids / segments); vrec = 64 + 4 dim; per_chunk = chunk_bytes // vrec; groups = ceil(capacity /
  per_chunk); vstride = page(per_chunk vrec); lstride = page(per_chunk links0 + (per_chunk 4 // (M-1) + 64) links);
  seg_bytes = align2M(groups (vstride + lstride)); dlog_node = align2M(ceil(max_deletes / dlog_chunk) dlog_chunk 64);
  end = swcc_offset + segments seg_bytes + N dlog_node; fits = end <= swcc_end (= device end: reserved [] in the region).
The delete log is per node (backend.h:34-35). Rule (h2n): total delete-log capacity constant across N:
  max_deletes(N) = floor(2 x X_MAXD(2) / N / dlog_chunk) x dlog_chunk, X_MAXD(2) = 1835008 (the 2-VM value), and it
  must cover the largest per-VM delete count of the N-target writes file (deletes are executed by the target VM's
  writer; the file's total deletes are unchanged: 3,400,000 for every N).
usage: h2n_layout.py [--vec-format fp32|sq8] [--writes-n2 F] [--writes-n4 F] [--writes-n8 F] [--csv OUT] [--skip-writes]
Prints one row per N and "LAYOUT PASS" / "LAYOUT FAIL: ..."; exit 1 on FAIL.
"""
import argparse
import csv
import os
import sys

P = "/home/comsys/sungsu/destijl-control"
DEVICE_SIZE = 103060340736          # /sys/bus/dax/devices/dax0.0/size (region device_size: auto; observed)
HWCC_SIZE = 268435456
ALIGN = 2 << 20
SEGMENTS, DIM, M, CHUNK = 32, 768, 16, 32 << 20
MAX_IDS = 30470752                  # eval.conf VDB_X_MAXIDS (28m-x)
DLOG_CHUNK = 4096
MAXD2 = 1835008                     # eval.conf VDB_X_MAXD (2 VMs, per node)
# Megalon (VDB_MG_CAPACITY=h1, m4-run.sh X_MEGALON_H1CAP=1): --max-ids 28000000 --max-deletes 1048576 per node
MG_MAX_IDS, MG_MAXD2 = 28000000, 1048576


def page(x):
    return (x + 4095) // 4096 * 4096


def align(x):
    return (x + ALIGN - 1) // ALIGN * ALIGN


def maxd(n, base=MAXD2):
    return (2 * base // n) // DLOG_CHUNK * DLOG_CHUNK


VEC_FORMAT = "fp32"  # --vec-format: fp32 vrec = 64 + 4 dim; sq8 vrec = whole lines of 64 + dim (shm_hnsw.h vrec_bytes)


def layout(n, max_deletes, max_ids=MAX_IDS):
    vrec = 64 + 4 * DIM if VEC_FORMAT == "fp32" else (64 + DIM + 63) // 64 * 64
    per_chunk = CHUNK // vrec
    cap = (max_ids + SEGMENTS - 1) // SEGMENTS
    groups = (cap + per_chunk - 1) // per_chunk
    links0 = (4 * (1 + 2 * M) + 63) // 64 * 64
    links = (4 * (1 + M) + 63) // 64 * 64
    lchunk = per_chunk * links0 + (per_chunk * 4 // (M - 1) + 64) * links
    vstride, lstride = page(per_chunk * vrec), page(lchunk)
    seg = align(groups * (vstride + lstride))
    dlog_node = align((max_deletes + DLOG_CHUNK - 1) // DLOG_CHUNK * DLOG_CHUNK * 64)
    swcc_off = align(HWCC_SIZE)
    end = swcc_off + SEGMENTS * seg + n * dlog_node
    return dict(nodes=n, max_deletes_per_node=max_deletes, dlog_chunks_per_node=(max_deletes + DLOG_CHUNK - 1) // DLOG_CHUNK,
                dlog_node_bytes=dlog_node, dlog_total_bytes=n * dlog_node, groups_per_segment=groups,
                seg_bytes=seg, segs_total_bytes=SEGMENTS * seg, swcc_offset=swcc_off, swcc_used_end=end,
                swcc_end=DEVICE_SIZE, headroom_bytes=DEVICE_SIZE - end, fits=end <= DEVICE_SIZE)


def deletes_per_target(path, n):
    import numpy as np
    dt = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"), ("vec", "<u4"),
                   ("pad1", "<u4")])
    w = np.memmap(path, dtype=dt, mode="r")
    d = w["target"][w["op"] == 2]
    c = np.bincount(d, minlength=n)
    return [int(x) for x in c], int(len(d)), sorted(set(np.unique(w["target"]).tolist()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--writes-n2", default=f"{P}/builds/vdb-inputs/3/writes-a27m-b3400k-u3400k.bin")
    ap.add_argument("--writes-n4", default=f"{P}/builds/vdb-inputs/4/writes-a27m-b3400k-u3400k-vms4.bin")
    ap.add_argument("--writes-n8", default=f"{P}/builds/vdb-inputs/4/writes-a27m-b3400k-u3400k-vms8.bin")
    ap.add_argument("--csv")
    ap.add_argument("--skip-writes", action="store_true", help="layout only (no writes-file read)")
    ap.add_argument("--check", nargs=2, type=int, metavar=("N", "MAX_DELETES"),
                    help="one line for this N and per-node max_deletes (h2n-block.sh); exit 1 if it does not fit")
    ap.add_argument("--vec-format", choices=("fp32", "sq8"), default="fp32", help="stored vector format (server --vec-format)")
    # verifier L4 (2026-10-22): deletes one lifetime can reach per VM = aggregate update rate x lifetime / N (printed
    # next to the delete-log size; informational, never a FAIL). Defaults above every pilot rate: plain backend 3600
    # updates/s (2 x the SQ8 pilot hw u90 N=8 max 195 search/s x 9), Megalon 100 updates/s (pilot <= ~12), lifetime
    # 2400 s (an SLO lifetime incl. warmup and overload steps <= ~25 min)
    ap.add_argument("--update-rate", type=float, default=3600.0, help="aggregate updates/s bound, plain backend")
    ap.add_argument("--mg-update-rate", type=float, default=100.0, help="aggregate updates/s bound, Megalon")
    ap.add_argument("--lifetime-s", type=float, default=2400.0, help="lifetime length bound (s)")
    a = ap.parse_args()
    global VEC_FORMAT
    VEC_FORMAT = a.vec_format
    if a.check:
        n, md = a.check
        r = layout(n, md)
        ok = r["fits"] and r["dlog_total_bytes"] <= layout(2, MAXD2)["dlog_total_bytes"]
        print(f"LAYOUT {'PASS' if ok else 'FAIL'}: {'vec=sq8 ' if VEC_FORMAT == 'sq8' else ''}N={n} max_deletes={md} dlog_node={r['dlog_node_bytes']} "
              f"swcc_used_end={r['swcc_used_end']} device={DEVICE_SIZE} headroom={r['headroom_bytes']}")
        sys.exit(0 if ok else 1)
    fails, rows = [], []
    base = layout(2, MAXD2)
    for n in (2, 4, 8):
        r = layout(n, maxd(n))
        mg = layout(n, maxd(n, MG_MAXD2), MG_MAX_IDS)
        r.update(mg_max_deletes_per_node=maxd(n, MG_MAXD2), mg_dlog_total_bytes=mg["dlog_total_bytes"])
        if not args_skip(a):
            f = getattr(a, f"writes_n{n}")
            per, tot, targets = deletes_per_target(f, n)
            r.update(writes=os.path.basename(f), deletes_total=tot, deletes_max_per_vm=max(per), deletes_min_per_vm=min(per),
                     targets_ok=targets == list(range(n)), delete_margin=r["max_deletes_per_node"] - max(per))
            if targets != list(range(n)):
                fails.append(f"N={n}: writes targets {targets} != 0..{n - 1}")
            if max(per) > r["max_deletes_per_node"]:
                fails.append(f"N={n}: largest per-VM delete count {max(per)} > max_deletes {r['max_deletes_per_node']}")
            if tot != 3400000:
                fails.append(f"N={n}: total deletes {tot} != 3400000")
        b = int(a.update_rate * a.lifetime_s / n)
        mb = int(a.mg_update_rate * a.lifetime_s / n)
        if r.get("deletes_max_per_vm") is not None:  # the writes file caps it as well
            b, mb = min(b, r["deletes_max_per_vm"]), min(mb, r["deletes_max_per_vm"])
        r.update(delete_bound_per_vm=b, delete_bound_fits=b <= r["max_deletes_per_node"],
                 mg_delete_bound_per_vm=mb, mg_delete_bound_fits=mb <= r["mg_max_deletes_per_node"])
        if not r["fits"]:
            fails.append(f"N={n}: swcc_used_end {r['swcc_used_end']} > device {DEVICE_SIZE}")
        if r["dlog_total_bytes"] > base["dlog_total_bytes"]:
            fails.append(f"N={n}: delete-log total {r['dlog_total_bytes']} > the 2-VM total")
        rows.append(r)
    cols = list(rows[0].keys())
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(r.get(c, "")) for c in cols))
    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(rows)
    print(f"DELETE BOUND (update rate x lifetime / N, capped by the writes file; plain {a.update_rate:g}/s, Megalon "
          f"{a.mg_update_rate:g}/s, lifetime {a.lifetime_s:g} s): " + "; ".join(
              f"N={r['nodes']} plain {r['delete_bound_per_vm']} <= {r['max_deletes_per_node']} {r['delete_bound_fits']}, "
              f"Megalon {r['mg_delete_bound_per_vm']} <= {r['mg_max_deletes_per_node']} {r['mg_delete_bound_fits']}"
              for r in rows))
    print("LAYOUT " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
    sys.exit(1 if fails else 0)


def args_skip(a):
    return a.skip_writes


if __name__ == "__main__":
    main()

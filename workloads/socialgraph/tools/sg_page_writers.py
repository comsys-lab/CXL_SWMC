#!/usr/bin/env python3
"""Writer VMs per 4 KiB page of a socialgraph image under each write route (Host only, offline, read-only on the image).

For N writer VMs (one writer per VM) and a route (server/layout.h slot_owner / pool_owner, mirrored below):
  mod    owner(slot) = slot % N (original slots, slack slots and pool blocks alike; the current default)
  range  contiguous spans: original slots [0, n_orig), slack slots [n_orig, n_nodes) and pool blocks [ovf_built,
         ovf_blocks) each split into N ranges of ceil(count / N): owner = (index - first) // ceil(count / N)
a page's writer set = the owners of every record with bytes on it. Reported per N and route:
  node pages   pages of the node-slot array (128 B slots, 32 per page; original + slack slots) with > 1 writer VM
  list pages   pages of the packed primary adjacency array (block of slot s = [adj_index[s], next block) owned by
               owner(s); a block <= 4 KiB touches one or two pages) with > 1 writer VM
  ovf pages    overflow blocks are whole pages (built: the list owner; pool: pool_owner): never > 1 writer VM
Static ownership only (every original record is a possible write target of the loadgen's keyed writes).
usage: python3 -I sg_page_writers.py --image graph.img [--nodes 2,4,8] [--json OUT]
"""
import argparse, json, struct, sys

import numpy as np

PAGE, SLOT = 4096, 128
HDR = struct.Struct("<QIIQQQQQQQQQQQQQQQ")  # layout.h ImageHeader up to total_bytes (offsets 0..127)
FIELDS = ("magic", "layout_version", "header_bytes", "id_base", "n_orig", "node_slack", "n_links", "adj_index_off",
          "adj_index_bytes", "nodes_off", "nodes_bytes", "adj_off", "adj_bytes", "ovf_off", "ovf_built", "ovf_pool",
          "total_bytes", "seed")
MAGIC = 0x31474D4947474753


def header(path):
    with open(path, "rb") as f:
        h = dict(zip(FIELDS, HDR.unpack(f.read(HDR.size))))
    if h["magic"] != MAGIC:
        sys.exit(f"{path}: not a socialgraph image (magic {h['magic']:#x})")
    return h


def span_owner(route, idx, first, count, n):
    """layout.h span_owner (numpy arrays): idx % n (mod) or (idx - first) // ceil(count / n) (range)"""
    if n <= 1:
        return np.zeros_like(idx)
    if route == "mod":
        return idx % n
    per = -(-count // n)
    return (idx - first) // per if per else np.zeros_like(idx)


def slot_owner(route, slot, n_orig, slack, n):
    orig = slot < n_orig
    return np.where(orig, span_owner(route, slot, 0, n_orig, n), span_owner(route, slot, n_orig, slack, n))


def multi(pages, owners, npages):
    """number of pages (0..npages-1) whose owners (one entry per (record, page) pair) are not all equal"""
    lo = np.full(npages, np.iinfo(np.int64).max, dtype=np.int64)
    hi = np.full(npages, -1, dtype=np.int64)
    np.minimum.at(lo, pages, owners)
    np.maximum.at(hi, pages, owners)
    used = hi >= 0
    return int(np.count_nonzero(used & (lo != hi))), int(np.count_nonzero(used))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", required=True)
    ap.add_argument("--nodes", default="2,4,8")
    ap.add_argument("--json")
    a = ap.parse_args()
    h = header(a.image)
    n_orig, slack = h["n_orig"], h["node_slack"]
    n_nodes = n_orig + slack
    if h["adj_index_bytes"] != 8 * n_nodes or h["nodes_bytes"] != SLOT * n_nodes:
        sys.exit("unexpected array sizes")
    if h["nodes_off"] % PAGE or h["adj_off"] % PAGE:
        sys.exit("arrays not page aligned")
    idx = np.fromfile(a.image, dtype="<u8", count=n_nodes, offset=h["adj_index_off"])
    start = idx[:n_orig].astype(np.int64)
    if np.any(idx[:n_orig] == np.uint64(2**64 - 1)) or np.any(np.diff(start) <= 0):
        sys.exit("original slots without a packed primary block (adj_index not increasing)")
    end = np.append(start[1:], h["adj_bytes"])
    p0, p1 = start // PAGE, (end - 1) // PAGE
    if np.any(p1 - p0 > 1):
        sys.exit("a primary block spans more than two pages")
    lslot = np.concatenate([np.arange(n_orig), np.arange(n_orig)[p1 != p0]])
    lpage = np.concatenate([p0, p1[p1 != p0]])
    nlp = int(-(-h["adj_bytes"] // PAGE))
    nslot = np.arange(n_nodes, dtype=np.int64)
    npage = nslot // (PAGE // SLOT)
    nnp = int(-(-n_nodes * SLOT // PAGE))
    out = {"image": a.image, "n_orig": n_orig, "node_slack": slack, "adj_bytes": h["adj_bytes"],
           "node_pages": nnp, "list_pages": nlp, "straddling_blocks": int(np.count_nonzero(p1 != p0)),
           "ovf_pages": h["ovf_built"] + h["ovf_pool"], "rows": []}
    print(f"image {a.image}: n_orig {n_orig}, slack {slack}, node pages {nnp}, list pages {nlp} "
          f"({out['straddling_blocks']} blocks straddle a page), ovf pages {out['ovf_pages']} (one writer each)")
    print("N\troute\tnode_pages_multi\tnode_frac\tlist_pages_multi\tlist_frac")
    for n in [int(x) for x in a.nodes.split(",")]:
        for route in ("mod", "range"):
            nm, nu = multi(npage, slot_owner(route, nslot, n_orig, slack, n), nnp)
            lm, lu = multi(lpage, slot_owner(route, lslot, n_orig, slack, n), nlp)
            r = {"N": n, "route": route, "node_pages_multi": nm, "node_pages_used": nu, "node_frac": nm / nu,
                 "list_pages_multi": lm, "list_pages_used": lu, "list_frac": lm / lu}
            out["rows"].append(r)
            print(f"{n}\t{route}\t{nm}\t{nm / nu:.6f}\t{lm}\t{lm / lu:.6f}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

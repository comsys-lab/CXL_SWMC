#!/usr/bin/env python3
"""Checks of the per-operation time split (DESIGN.md §15) on a host_smoke.sh scratch dir (Host only).

usage: opcoh_check.py <scratch dir> fake|megalon|none
  every mode: one v2 record per OK search response (op-coh.bin vs searches.bin, joined by seq) and per OK update
              (vectordb.txt updates_ok_without_coh=0, records = server updates); search sections = segments + 1,
              update sections = 1; t_ns > 0; c_ns = Popcorn parts + Megalon parts; the server's opt.<op>.* totals at
              stop (nodes summed) equal the records' sums (ops, t_ns, c_ns, mod_bytes, pop.*, meg.wflush_bytes);
              opcoh.read_errors = register_errors = 0; search mod_bytes = 0; update mod_bytes >= vector record +
              level-0 block + delete-log entry; opsplit.py writes rows for both operation types and the column table.
  fake (VDB_OPCOH_FAKE=1): per search pf_ns[0] = dists of searches.bin and pf_cnt[0] = segments, ipi_ns <= dists/8;
              per update pf_ns[1] = 1000, pf_cnt[1] = 1.
  megalon:    Megalon build without CohSnap (fallback shim): src bit 2 = 0 and every mg_* field 0 (opt.meg_coh=0);
              Popcorn source none; with CohSnap: mg_read_sections > 0 on searches, mg_wflush_bytes > 0 on updates.
  none:       plain backend, no counter source: c_ns = 0.
"""
import csv, os, subprocess, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, "experiments", "vectordb"))
import opsplit  # noqa: E402
import qcoh  # noqa: E402  (searches.bin layout)

S, mode = sys.argv[1], sys.argv[2]
fails = []


def check(c, msg):
    if not c:
        fails.append(msg)


def final_stats(path):
    t = open(path).read()
    t = t[t.index("vdb-server: stopping"):]
    d = {}
    for line in t.splitlines():
        k, s, v = line.partition("=")
        if s:
            try:
                d[k] = int(v)
            except ValueError:
                d[k] = v
    return d


lg = os.path.join(S, "loadgen")
logs = np.fromfile(os.path.join(lg, "op-coh.bin"), dtype=opsplit.OPLOG)
sr = np.fromfile(os.path.join(lg, "searches.bin"), dtype=qcoh.search_dtype(10))
ok = sr[sr["status"] == 0]
st = [final_stats(os.path.join(S, f"node{k}.log")) for k in (0, 1)]
vt = dict(x.strip().split("=", 1) for x in open(os.path.join(lg, "vectordb.txt")) if "=" in x)
c = logs["c"]
srch, upd = logs[logs["op"] == 3], logs[logs["op"] == 4]
cs, cu = srch["c"], upd["c"]
print(f"op records {len(logs)} (search {len(srch)}, update {len(upd)}), OK searches {len(ok)}, "
      f"server updates {sum(s['updates'] for s in st)}")
check(len(logs) and (c["version"] == 2).all(), "version 2")
check(np.array_equal(np.sort(srch["seq"]), np.sort(ok["seq"])), "one search record per OK search response")
check(vt.get("updates_ok_without_coh") == "0" and vt.get("bad_coh_version") == "0", "no response without a v2 block")
check(len(upd) == sum(s["updates"] for s in st) and len(upd) > 0, "one update record per update")
seg = int(ok["segs"][0]) if len(ok) else 0
check((cs["sections"] == seg + 1).all() and (cu["sections"] == 1).all(), "sections")
check((c["t_ns"] > 0).all(), "t_ns > 0")
chk = np.array([int(x["mg_check_ns_sampled"]) * int(x["mg_read_sections"]) // int(x["mg_check_sampled"])
                if x["mg_check_sampled"] else 0 for x in c], dtype=np.uint64)
mg = (chk + c["mg_stale_ns"] + c["mg_concur_ns"] + c["mg_meta_ns"]
      + c["mg_spin_ns"] + c["mg_wstart_ns"] + c["mg_wflush_ns"])
check((c["c_ns"] == c["pf_ns"].sum(axis=1) + c["ipi_ns"] + mg).all(), "c_ns = parts")
for op, x in (("search", cs), ("update", cu)):
    tot = lambda k: sum(s[f"opt.{op}.{k}"] for s in st)  # noqa: E731
    check(tot("ops") == len(x), f"opt.{op}.ops = records")
    for k, v in (("t_ns", x["t_ns"]), ("c_ns", x["c_ns"]), ("mod_bytes", x["mod_bytes"]), ("pop.is_ns", x["pf_ns"][:, 0]),
                 ("pop.sm_ns", x["pf_ns"][:, 1]), ("pop.ipi_ns", x["ipi_ns"]), ("meg.wflush_bytes", x["mg_wflush_bytes"])):
        check(tot(k) == int(v.astype(np.uint64).sum()), f"opt.{op}.{k} = records' sum ({tot(k)} vs {int(v.sum())})")
check(all(s["opcoh.read_errors"] == 0 and s["opcoh.register_errors"] == 0 for s in st), "no counter read/register errors")
check((cs["mod_bytes"] == 0).all(), "search mod_bytes 0")
check((cu["mod_bytes"] >= 3136 + 192 + 64).all(), "update mod_bytes >= record + level-0 block + delete-log entry")
by = {int(q): i for i, q in enumerate(ok["seq"])}
oi = np.array([by[int(q)] for q in srch["seq"]], dtype=np.int64)
if mode == "fake":
    check(all(s["opcoh.pop_source"] == "fake" for s in st), "source fake")
    check(np.array_equal(cs["pf_ns"][:, 0], ok["dists"][oi].astype(np.uint64)), "search pf_ns[0] = dists")
    check((cs["pf_cnt"][:, 0] == seg).all() and (cs["ipi_ns"] <= cs["pf_ns"][:, 0] // 8).all(), "search fake counts")
    check((cu["pf_ns"][:, 1] == 1000).all() and (cu["pf_cnt"][:, 1] == 1).all(), "update fake S->M 1000 ns")
elif mode == "megalon":
    snap = all(s["opt.meg_coh"] == 1 for s in st)
    print(f"megalon cohsnap {snap}")
    if snap:
        check((cs["mg_read_sections"] > 0).all() and (cu["mg_wflush_bytes"] > 0).all(), "CohSnap values present")
        check(((c["src"] & 4) == 4).all(), "src bit 2")
    else:
        mgf = [f for f in opsplit.OPCOH.names if f.startswith("mg_")]
        check(all((c[f] == 0).all() for f in mgf) and ((c["src"] & 4) == 0).all(), "no CohSnap: mg fields 0")
    check(all(s["opcoh.pop_source"] == "none" for s in st), "popcorn source none on the Host")
    check(all(s["megt.writer.wr_sections"] > 0 for s in st), "writer write sections")
elif mode == "none":
    check(all(s["opcoh.pop_source"] == "none" for s in st), "source none")
    check((c["c_ns"] == 0).all(), "c_ns 0")
r = subprocess.run([sys.executable, os.path.join(ROOT, "experiments", "vectordb", "opsplit.py"), S],
                   capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip())
check(r.returncode == 0, "opsplit.py runs")
if r.returncode == 0:
    rows = list(csv.DictReader(open(os.path.join(S, "opsplit-steps.csv"))))
    tags = {x["column"]: x["tag"] for x in csv.DictReader(open(os.path.join(S, "opsplit-steps.columns.csv")))}
    check({x["op"] for x in rows} == {"search", "update"}, "rows for search and update")
    check(all(x["unmatched"] == "0" for x in rows), "every measured record matched")
    check(tags.get("T_ms") == "measured" and tags.get("C_ms") == "derived" and tags.get("mg_check_ms", "").startswith("sampled×"),
          "column tags")
    for x in rows:
        if x["op"] == "update" and x["win_n"]:
            check(abs(float(x["win_T_ms"]) - float(x["T_ms"])) <= 0.5 * float(x["T_ms"]) + 1e-6, "window T ~ record T")
print("OPCOH_CHECK " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
sys.exit(1 if fails else 0)

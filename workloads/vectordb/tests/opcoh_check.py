#!/usr/bin/env python3
"""Checks of the per-operation time split (DESIGN.md §15) on a host_smoke.sh scratch dir (Host only).

usage: opcoh_check.py <run or scratch dir> fake|megalon|none|hwcc|popcorn|megalon-vm|megalon-t0
  (host_smoke.sh scratch dirs and run.sh run dirs have the same layout: loadgen/, node<k>.log)
  N nodes (h2n blocks, N = 2..8): OPCOH_NODES=N, else every contiguous node<k>.log from node0; server totals are
  summed over all N nodes ("both nodes" below = every node).
  H1-HOOK v2 parts (several loadgen invocations in one server lifetime, run.sh PARTS): <dir> = one part dir
  (<lifetime>/<part>/loadgen); node<k>.log is read from <dir>, else from its parent (the lifetime dir). The server's
  totals at stop cover the whole lifetime, so the closure checks (opt.<op>.* = records' sums, one update record per
  update) use the records of every part named in OPCOH_PARTS (space-separated part dirs of the lifetime, default
  <dir>); every other check uses <dir>'s records only.
  every mode: one v2 record per OK search response (op-coh.bin vs searches.bin, joined by seq) and per OK update
              (vectordb.txt updates_ok_without_coh=0, records = server updates); search sections = segments + 1,
              update sections = 1; t_ns > 0; c_ns = Popcorn parts + Megalon parts (proto.h RD / EV / WR: Megalon >= 76
              lean sampling, src bit 4, scales the timed-section sums per side); the server's opt.<op>.* totals at
              stop (nodes summed) equal the records' sums (ops, t_ns, c_ns, mod_bytes, pop.*, meg.wflush_bytes);
              opcoh.read_errors = register_errors = 0; search mod_bytes = 0; update mod_bytes >= vector record +
              level-0 block + delete-log entry; opsplit.py writes rows for both operation types and the column table.
  fake (VDB_OPCOH_FAKE=1): per search pf_ns[0] = dists of searches.bin and pf_cnt[0] = segments, ipi_ns <= dists/8;
              per update pf_ns[1] = 1000, pf_cnt[1] = 1.
  megalon:    Megalon build without CohSnap (fallback shim): src bit 2 = 0 and every mg_* field 0 (opt.meg_coh=0);
              Popcorn source none; with CohSnap: mg_read_sections > 0 on searches, mg_wflush_bytes > 0 on updates.
  none:       plain backend, no counter source: c_ns = 0.
  VM modes (reports/VDB-V1-packet.md):
  hwcc:       all-HWcc (plain backend, cxl_shm unloaded): any Popcorn source, every Popcorn and Megalon part 0, c_ns 0.
  popcorn:    Popcorn (plain backend, cxl_shm loaded): source swmc_acct registered on both nodes (no register errors);
              sum of c_ns > 0 over the measured updates (writer faults) and over the searches of ALL measured steps
              together (warm-up excluded for both); a
              measured step whose searches have C = 0 prints "OPCOH_CHECK NOTE" (few invalidated pages read at a low
              rate), not a failure; no Megalon part.
  megalon-vm: Megalon with CohSnap + AnchorSnap (shim v3): both present on every record, sum of c_ns > 0 per op type,
              validation copies counted; every Popcorn part 0 (cxl_shm unloaded); MEGALON_LEAN=1 in the environment
              (Megalon >= 76 runs, reports/VDB-V1-packet.md v1.3): lean bit on and events_always off on every record,
              timed write sections > 0 over the updates.
  every mode: a step whose C_ms exceeds T_ms prints "OPCOH_CHECK WARN" (never a failure; sampled Megalon C is biased
              upward, Fig 2 uses C_diff, experiments/vectordb/cdiff.py).
  every Megalon mode with lean records: mg_write_sampled <= mg_write_sections; a record without timed read sections
              has no read-side event time and one without timed write sections has no write-side time (contract
              megalon_objapi.h: durations only in timed sections).
  megalon-t0: as megalon-vm with MEGALON_COH_TIMERS=0: CohSnap/AnchorSnap present, Megalon durations may be 0 (counts
              kept), no C > 0 requirement.
"""
import csv, glob, os, subprocess, sys

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
def node_log(k):
    p = os.path.join(S, f"node{k}.log")
    return p if os.path.exists(p) else os.path.join(os.path.dirname(os.path.abspath(S)), f"node{k}.log")


def node_count():
    """N servers of the lifetime: env OPCOH_NODES (the block's --nodes N), else the contiguous node<k>.log files from
    node0 (2-VM run dirs: node0, node1). Every closure sums over all N nodes."""
    if os.environ.get("OPCOH_NODES"):
        n = int(os.environ["OPCOH_NODES"])
        assert 2 <= n <= 8, "OPCOH_NODES must be 2..8"
        missing = [k for k in range(n) if not os.path.exists(node_log(k))]
        assert not missing, f"OPCOH_NODES={n} but no node log for nodes {missing}"
        return n
    n = 0
    while os.path.exists(node_log(n)):
        n += 1
    assert n >= 2, "fewer than two node<k>.log files"
    return n


NODES = node_count()
st = [final_stats(node_log(k)) for k in range(NODES)]
print(f"nodes {NODES}")
vt = dict(x.strip().split("=", 1) for x in open(os.path.join(lg, "vectordb.txt")) if "=" in x)
c = logs["c"]
srch, upd = logs[logs["op"] == 3], logs[logs["op"] == 4]
cs, cu = srch["c"], upd["c"]
parts = os.environ.get("OPCOH_PARTS", "").split() or [S]
assert os.path.abspath(S) in [os.path.abspath(x) for x in parts], "OPCOH_PARTS must include the checked part"
alll = np.concatenate([np.fromfile(os.path.join(x, "loadgen", "op-coh.bin"), dtype=opsplit.OPLOG) for x in parts])
acs, acu = alll[alll["op"] == 3]["c"], alll[alll["op"] == 4]["c"]  # closure: every part of the lifetime
print(f"op records {len(logs)} (search {len(srch)}, update {len(upd)}), OK searches {len(ok)}, "
      f"server updates {sum(s['updates'] for s in st)}")
check(len(logs) and (c["version"] == 2).all(), "version 2")
check(np.array_equal(np.sort(srch["seq"]), np.sort(ok["seq"])), "one search record per OK search response")
check(vt.get("updates_ok_without_coh") == "0" and vt.get("bad_coh_version") == "0", "no response without a v2 block")
check(len(acu) == sum(s["updates"] for s in st) and len(upd) > 0, "one update record per update")
seg = int(ok["segs"][0]) if len(ok) else 0
check((cs["sections"] == seg + 1).all() and (cu["sections"] == 1).all(), "sections")
check((c["t_ns"] > 0).all(), "t_ns > 0")
chk = np.array([int(x["mg_check_ns_sampled"]) * int(x["mg_read_sections"]) // int(x["mg_check_sampled"])
                if x["mg_check_sampled"] else 0 for x in c], dtype=np.uint64)
vce = np.array([int(x["vcopy_ns_sampled"]) * int(x["vcopy_cnt"]) // int(x["vcopy_sampled"]) if x["vcopy_sampled"] else 0
                for x in c], dtype=np.uint64)
anr = np.array([(int(x["an_read_lookup_ns_sampled"]) + int(x["an_read_nr_ns_sampled"])) * int(x["mg_read_sections"])
                // int(x["mg_check_sampled"]) if x["mg_check_sampled"] else 0 for x in c], dtype=np.uint64)
lean_r = (c["src"] & 16) != 0      # Megalon >= 76 lean sampling (proto.h src bit 4)
always_r = (c["src"] & 32) != 0    # MEGALON_COH_EVENTS=always (bit 5)


def ev_est(x):  # proto.h EV: read-side events
    ev = int(x["mg_stale_ns"]) + int(x["mg_concur_ns"]) + int(x["mg_meta_ns"]) + int(x["mg_spin_ns"])
    if (x["src"] & 16) and not (x["src"] & 32):
        return ev * int(x["mg_read_sections"]) // int(x["mg_check_sampled"]) if x["mg_check_sampled"] else 0
    return ev


def wr_est(v, x):  # proto.h WR: write side
    if x["src"] & 16:
        return v * int(x["mg_write_sections"]) // int(x["mg_write_sampled"]) if x["mg_write_sampled"] else 0
    return v


mg = np.array([ev_est(x) + wr_est(int(x["mg_wstart_ns"]) + int(x["mg_wflush_ns"]), x)
               + wr_est(int(x["an_write_lookup_ns"]) + int(x["an_write_nr_ns"]), x) for x in c], dtype=np.uint64)
mg = mg + chk + vce + anr
check((c["c_ns"] == c["pf_ns"].sum(axis=1) + c["ipi_ns"] + mg).all(), "c_ns = parts")
if lean_r.any():
    lr = c[lean_r]
    check((lr["mg_write_sampled"] <= lr["mg_write_sections"]).all(), "lean: timed write sections <= write sections")
    wz = lr[lr["mg_write_sampled"] == 0]
    check(all((wz[f] == 0).all() for f in ("mg_wstart_ns", "mg_wflush_ns", "an_write_lookup_ns", "an_write_nr_ns",
                                           "an_wseq_ns", "an_wseq_end_ns")), "lean: no write-side time without timed writes")
    rz = lr[(lr["mg_check_sampled"] == 0) & ((lr["src"] & 32) == 0)]
    check(all((rz[f] == 0).all() for f in ("mg_stale_ns", "mg_concur_ns", "mg_meta_ns", "mg_spin_ns")),
          "lean: no read-side event time without timed read sections")
for op, x in (("search", acs), ("update", acu)):
    tot = lambda k: sum(s[f"opt.{op}.{k}"] for s in st)  # noqa: E731
    check(tot("ops") == len(x), f"opt.{op}.ops = records")
    for k, v in (("t_ns", x["t_ns"]), ("c_ns", x["c_ns"]), ("mod_bytes", x["mod_bytes"]), ("pop.is_ns", x["pf_ns"][:, 0]),
                 ("pop.sm_ns", x["pf_ns"][:, 1]), ("pop.ipi_ns", x["ipi_ns"]), ("meg.wflush_bytes", x["mg_wflush_bytes"])):
        check(tot(k) == int(v.astype(np.uint64).sum()), f"opt.{op}.{k} = records' sum ({tot(k)} vs {int(v.sum())})")
for op, x in (("search", acs), ("update", acu)):
    check(sum(s[f"opt.{op}.meg.vcopy_cnt"] for s in st) == int(x["vcopy_cnt"].astype(np.uint64).sum()), f"opt.{op}.meg.vcopy_cnt")
check(all(s["opcoh.read_errors"] == 0 and s["opcoh.register_errors"] == 0 for s in st), "no counter read/register errors")
check((cs["mod_bytes"] == 0).all(), "search mod_bytes 0")
check((cs["wait_ns"] <= cs["t_ns"]).all() and (cu["wait_ns"] == 0).all(), "E1 wait inside search T, 0 for updates")
for op, x in (("search", acs), ("update", acu)):
    check(sum(s[f"opt.{op}.wait_ns"] for s in st) == int(x["wait_ns"].sum()), f"opt.{op}.wait_ns = records' sum")
check((cu["mod_bytes"] >= 3136 + 192 + 64).all(), "update mod_bytes >= record + level-0 block + delete-log entry")
by = {int(q): i for i, q in enumerate(ok["seq"])}
oi = np.array([by[int(q)] for q in srch["seq"]], dtype=np.int64)
if mode == "fake":
    check(all(s["opcoh.pop_source"] == "fake" for s in st), "source fake")
    check(np.array_equal(cs["pf_ns"][:, 0], ok["dists"][oi].astype(np.uint64)), "search pf_ns[0] = dists")
    check((cs["pf_cnt"][:, 0] == seg).all() and (cs["ipi_ns"] <= cs["pf_ns"][:, 0] // 8).all(), "search fake counts")
    check((cu["pf_ns"][:, 1] == 1000).all() and (cu["pf_cnt"][:, 1] == 1).all(), "update fake S->M 1000 ns")
    check((cu["nontrans_ns"] == 500).all() and (cu["nontrans_cnt"] == 1).all() and (cs["nontrans_ns"] == 0).all(),
          "update fake no-transition 500 ns")
    check((cu["c_ns"] == 1000).all(), "no-transition faults are not part of C")
    check(sum(s["opt.update.pop.nontrans_ns"] for s in st) == 500 * len(acu), "opt.update.pop.nontrans_ns")
pop_zero = ((c["pf_ns"] == 0).all() and (c["pf_cnt"] == 0).all() and (c["ipi_ns"] == 0).all()
            and (c["nontrans_ns"] == 0).all())
mg_fields = [f for f in opsplit.OPCOH.names if f.startswith("mg_") or f.startswith("an_") or f.startswith("vcopy")]
if mode == "hwcc":
    check(pop_zero and all((c[f] == 0).all() for f in mg_fields) and (c["c_ns"] == 0).all(), "all-HWcc: C = 0")
elif mode == "popcorn":
    check(all(s["opcoh.pop_source"] == "swmc_acct" and s["opcoh.register_errors"] == 0 for s in st)
          and ((c["src"] & 3) == 1).all(), "swmc_acct registered on every node")
    meas = logs["measured"] == 1  # both sums over the measured steps only (warm-up excluded for both)
    check(int(logs["c"]["c_ns"][(logs["op"] == 4) & meas].sum()) > 0, "Popcorn update C > 0 over all measured steps")
    check(int(logs["c"]["c_ns"][(logs["op"] == 3) & meas].sum()) > 0, "Popcorn search C > 0 over all measured steps")
    check(all((c[f] == 0).all() for f in mg_fields), "no Megalon part")
elif mode in ("megalon-vm", "megalon-t0"):
    check(all(s["opt.meg_coh"] == 1 and s.get("opt.meg_anchor") == 1 for s in st), "CohSnap and AnchorSnap on every node")
    check(((c["src"] & 12) == 12).all(), "src bits 2 and 3 on every record")
    check(pop_zero, "every Popcorn part 0 (cxl_shm unloaded)")
    check((cs["vcopy_cnt"] > 0).all() and (cs["mg_read_sections"] > 0).all(), "validation copies and read sections counted")
    if mode == "megalon-vm":
        check(int(cs["c_ns"].sum()) > 0 and int(cu["c_ns"].sum()) > 0, "Megalon C > 0 for searches and updates")
        if os.environ.get("MEGALON_LEAN") == "1":
            check(lean_r.all() and not always_r.any(), "Megalon >= 76: lean sampling on, events_always off")
            check(int(cu["mg_write_sampled"].sum()) > 0, "Megalon >= 76: timed write sections over the updates")
        check(int(c["vcopy_sampled"].sum()) > 0 and int(cu["mg_wflush_bytes"].sum()) > 0, "sampled copies, flush bytes")
    check(all(s["megt.writer.wr_sections"] > 0 for s in st), "writer write sections")
elif mode == "megalon":
    snap = all(s["opt.meg_coh"] == 1 for s in st)
    print(f"megalon cohsnap {snap}")
    if snap:
        check((cs["mg_read_sections"] > 0).all() and (cu["mg_wflush_bytes"] > 0).all(), "CohSnap values present")
        check(((c["src"] & 4) == 4).all(), "src bit 2")
        if all(s.get("opt.meg_anchor") == 1 for s in st):
            # every update's write section is timed only without lean sampling (Megalon <= 75)
            timed_w = cu[cu["mg_write_sampled"] > 0] if lean_r.any() else cu
            check(((c["src"] & 8) == 8).all() and len(timed_w) > 0 and (timed_w["an_write_lookup_ns"] > 0).all() and
                  c["an_read_nr_ns_sampled"].sum() > 0, "AnchorSnap values present")
            for op, x in (("search", acs), ("update", acu)):
                for f in ("read_lookup_ns_sampled", "write_nr_ns", "write_sampled"):
                    rec = "mg_write_sampled" if f == "write_sampled" else "an_" + f
                    if f == "write_sampled" and not all(f"opt.{op}.meg.anchor.{f}" in s for s in st):
                        continue  # vdb builds <= 14 have no write_sampled key (their records carry 0)
                    check(sum(s[f"opt.{op}.meg.anchor.{f}"] for s in st) == int(x[rec].astype(np.uint64).sum()),
                          f"opt.{op}.meg.anchor.{f}")
    else:
        mgf = [f for f in opsplit.OPCOH.names if f.startswith("mg_")]
        check(all((c[f] == 0).all() for f in mgf) and ((c["src"] & 4) == 0).all(), "no CohSnap: mg fields 0")
    check((cs["vcopy_cnt"] > 0).all() and c["vcopy_sampled"].sum() > 0, "validation copies counted and sampled")
    check(pop_zero, "every Popcorn part 0")
    check(all(s["megt.writer.wr_sections"] > 0 for s in st), "writer write sections")
if not mode.startswith("megalon"):
    check((c["vcopy_cnt"] == 0).all(), "plain backend: no validation copies")
if mode == "none":
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
    if glob.glob(os.path.join(lg, "rawid-step*.bin")):
        check(all(x["match"] == "req_id" for x in rows), "id-based matching (rawid sidecars present)")
    check(tags.get("T_ms") == "measured" and tags.get("C_ms") == "derived" and tags.get("mg_check_ms", "").startswith("sampled×"),
          "column tags")
    if mode == "popcorn":
        for x in rows:
            if x["op"] == "search" and x["n_ops"] not in ("", "0") and float(x["C_ms"] or 0) == 0:
                print(f"OPCOH_CHECK NOTE: step {x['step']} ({x['achieved_per_s']} search/s): search C = 0")
    for x in rows:  # sampled C above T: reported, never a failure (Megalon sampled C is biased upward by the probe
        # cost; Fig 2 uses C_diff = T(timers off) - T(all-HWcc), experiments/vectordb/cdiff.py; user decision 2026-10-17)
        if x["n_ops"] not in ("", "0") and x["C_ms"] and x["T_ms"] and float(x["C_ms"]) > float(x["T_ms"]):
            print(f"OPCOH_CHECK WARN: step {x['step']} {x['op']}: C_ms {x['C_ms']} > T_ms {x['T_ms']} (sampled C, not a failure)")
    for x in rows:
        if x["op"] == "update" and x["win_n"] and x["T_ms"]:  # a step without matched update records has no T_ms
            check(abs(float(x["win_T_ms"]) - float(x["T_ms"])) <= 0.5 * float(x["T_ms"]) + 1e-6, "window T ~ record T")
print("OPCOH_CHECK " + ("PASS" if not fails else "FAIL: " + "; ".join(fails)))
sys.exit(1 if fails else 0)

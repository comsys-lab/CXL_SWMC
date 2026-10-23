#!/bin/bash
# Host test of the writer lock split counters (DESIGN.md §19; experiment popcorn-writer-lock-split). Two host_smoke.sh
# runs on scratch files (never /dev/dax*): "on" with VDB_LOCK_SPLIT=1, VDB_OPCOH_FAKE=1, VDB_LOCK_SPLIT_FAKE_NS=$FAKE
# (every insert adds a FAKE ns write-protect fault inside its hold) and "off" (default environment, OPCOH=fake closure
# check as before). Checks (final stats of both nodes and every stats-steps.csv row of "on"):
#   hold_wp_ns = FAKE x inserts, hold_wp_cnt = inserts = lock_split.inserts (final), hold_coh = hold_wp (no other
#   fault inside the hold), hold_coh + hold_rq <= hold, hold_cpu <= hold, sample_ns < hold, rq_errors = coh_unavailable
#   = 0, hist sums = counts, seg_tasks = searches x segments; "off": no lock_split key anywhere, opcoh_check fake PASS.
# usage: lock_split_test.sh <vdb build dir> <loadgen binary> <data dir> <scratch dir (must not exist)>
set -euo pipefail
B=$1 LG=$2 D=$3 S=$4
HERE=$(cd "$(dirname "$0")" && pwd)
FAKE=${FAKE:-1000} SEG=${SEGMENTS:-4}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
rc=0
# "on" runs both servers (writer, 4 searchers, readers each) on CPUS_ON (default 18-19: 2 Host node-1 CPUs inside
# the session cpuset), so the writer
# waits on the run queue and hold_rq > 0 is exercised
env VDB_LOCK_SPLIT=1 VDB_OPCOH_FAKE=1 VDB_LOCK_SPLIT_FAKE_NS=$FAKE TRACE=0 SEGMENTS=$SEG VEC_FORMAT=${VEC_FORMAT:-sq8} \
  CPUS=${CPUS_ON:-18-19} bash "$HERE/host_smoke.sh" "$B" "$LG" "$D" "$S/on" > "$S/on.log" 2>&1 \
  || { echo "host_smoke (on) rc != 0 (see $S/on.log)"; rc=1; }
REC=$([ "${VEC_FORMAT:-sq8}" = sq8 ] && echo 832 || echo 3136)   # opcoh_check level-0 record size (as h2n-block.sh)
env -u VDB_LOCK_SPLIT -u VDB_LOCK_SPLIT_FAKE_NS VDB_OPCOH_FAKE=1 OPCOH=fake OPCOH_RECORD_BYTES=$REC TRACE=0 SEGMENTS=$SEG VEC_FORMAT=${VEC_FORMAT:-sq8} \
  bash "$HERE/host_smoke.sh" "$B" "$LG" "$D" "$S/off" > "$S/off.log" 2>&1 || { echo "host_smoke (off) rc != 0 (see $S/off.log)"; rc=1; }
python3 -I - "$S" "$FAKE" "$SEG" <<'PY' || rc=1
import csv, sys
S, fake, seg = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
bad = []
def final(path):
    t = open(path).read().split("vdb-server: stopping", 1)
    if len(t) < 2: bad.append(f"{path}: no final stats"); return {}
    d = {}
    for l in t[1].splitlines():
        if "=" in l:
            k, v = l.split("=", 1)
            try: d[k] = int(v)
            except ValueError: pass
    return d
def check(tag, d, final_row):
    g = lambda k: d.get("lock_split." + k, 0)
    n = g("inserts")
    hist = lambda h: sum(g(f"{h}.b{b:02d}") for b in range(40))
    # window deltas (stats-steps.csv): the snapshot reads the counters one by one while the writer and the searchers
    # run (the end snapshot is taken before the drain), so counts may differ by a few operations; final: exact
    t = 0 if final_row else 3
    eq = lambda a, b, u=1: abs(a - b) <= t * u
    c = [("hold_wp_ns = FAKE x inserts", eq(g("hold_wp_ns"), fake * n, fake)),
         ("hold_wp_cnt = inserts", eq(g("hold_wp_cnt"), n)),
         ("hold_coh = hold_wp", eq(g("hold_coh_ns"), g("hold_wp_ns"), fake)),
         ("coh + rq <= hold", g("hold_coh_ns") + g("hold_rq_ns") <= g("hold_ns")),
         ("cpu <= hold", g("hold_cpu_ns") <= g("hold_ns")),
         ("sample_ns < hold", n == 0 or g("sample_ns") < g("hold_ns")),
         ("no rq / coh errors", g("rq_errors") == 0 and g("coh_unavailable") == 0),
         ("hold_hist sum = inserts", eq(hist("hold_hist"), n)),
         ("search_lock_hist sum = searches", eq(hist("search_lock_hist"), g("searches"))),
         ("e1_hist sum = searches", eq(hist("e1_hist"), g("searches"))),
         ("seg_lock_hist sum = seg_tasks", eq(hist("seg_lock_hist"), g("seg_tasks"), seg))]
    if final_row:
        c += [("enabled", g("enabled") == 1), ("inserts > 0", n > 0), ("searches > 0", g("searches") > 0),
              ("lock_split.inserts = inserts", n == d.get("inserts")),
              ("lock_split.searches = searches", g("searches") == d.get("searches")),
              ("seg_tasks = searches x segments", g("seg_tasks") == g("searches") * seg)]
    for name, ok in c:
        if not ok: bad.append(f"{tag}: {name}")
    return n, g("hold_ns"), g("hold_coh_ns"), g("hold_rq_ns"), g("hold_cpu_ns"), g("sample_ns"), g("hold_overlap_cnt")
rq_all = 0
for k in (0, 1):
    d = final(f"{S}/on/node{k}.log")
    n, h, co, rq, cpu, smp, ov = check(f"on node{k} final", d, True)
    rq_all += rq
    print(f"on node{k}: inserts={n} hold_mean_us={h / max(n, 1) / 1e3:.1f} coh={co} rq={rq} cpu={cpu} sample_ns_mean={smp / max(n, 1):.0f} overlap={ov}")
if rq_all <= 0: bad.append("on: hold_rq = 0 on both nodes (contended CPUs: the run-queue path is not exercised)")
rows = list(csv.DictReader(open(f"{S}/on/stats-steps.csv")))
for r in rows:
    d = {k: int(float(v)) for k, v in r.items() if k.startswith("lock_split.") and v not in ("", None)}
    check(f"on step {r['step']} target {r['target']}", d, False)
print(f"on: {len(rows)} stats-steps rows checked")
for k in (0, 1):
    if "lock_split" in open(f"{S}/off/node{k}.log").read(): bad.append(f"off node{k}: lock_split keys printed")
if "lock_split" in open(f"{S}/off/stats-steps.csv").readline(): bad.append("off: lock_split columns in stats-steps.csv")
print("\n".join("FAIL " + b for b in bad) if bad else "lock split checks: all PASS")
sys.exit(1 if bad else 0)
PY
grep -h "OPCOH_CHECK" "$S/off.log" || { echo "off: no opcoh_check line"; rc=1; }
grep -q "OPCOH_CHECK PASS" "$S/off.log" || rc=1
echo "LOCK_SPLIT_TEST $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc

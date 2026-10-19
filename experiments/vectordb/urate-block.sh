#!/bin/bash
# Vector DB update-rate sweep (reports/VDB-urate-packet.v1.md; brief reports/VDB-update-rate-axis-brief.md; user
# decisions 2026-10-19; workloads/vectordb/DESIGN.md §17). HNSW VectorDB 28M (as H1 VDB), systems hw (All-HWcc =
# plain server, cxl_shm unloaded) and pop (Popcorn = plain server + cxl_shm build 12, init_state=shared + preload,
# recv_mode poll), both on the Popcorn build-12 kernel, exactly as the H1 VDB lifetimes (recovery/H1-main-v1/vdb).
#   Update stream: absolute rate R updates/s (one update = DELETE + INSERT, one kOpUpdate request), independent of the
#   search rate: loadgen --fixed update=R --mix search=1. Updates go to the VM named by the writes file (gen_writes.py:
#   uniform per update pair, seed 20261015; the same file for every system and rate). R in URATES (default
#   100 200 400 800 1600 3200; > 800 labelled stress in the log). Writer threads per VM: WRITERS (vdb-server
#   --writer-threads, the same for every system; recorded in every manifest and checked per step).
#   Per rate (URATES order), per system (order shuffle(seed vdb-urate-<R>), <E>/order.txt): one server lifetime
#   <sys>-u<R> = m4-run.sh KIND=urate: part warm (1 search/s + the stream, 10 + 50 s, unmeasured) then part slo (search
#   p99 <= 100 ms, knee ramp from URATE_START (1) search/s, >= 100 searches per step, --ramp-knee 2 --ramp-knee-floor
#   1.5, confirm 3 x 30 s, --tol 0.02); then urate_check.py <life>/slo (FAIL stops the block; NOTE "update rate not
#   sustained" recorded) and urate_report.py (one row per lifetime in <E>/urate-results.tsv).
#   Update budget: every lifetime starts from the initial image and may consume at most the writes file's update count
#   (pool B, 1,000,000 updates; ids and capacity of the 28M image allow 1,010,000 inserts). A rate R is refused before
#   the block starts if R x URATE_BUDGET_S (1200 s: warm 60 s + a knee-ramp SLO search; estimate in the packet) exceeds
#   that count (SEQUENCE STOP "update budget"): rates above ~830 updates/s need a longer writes file and more ids, a
#   dataset decision (packet §open questions). A lifetime that still exhausts the stream stops the block (m4-run.sh).
# usage: urate-block.sh <evidence dir (exists, holds only sequence* files)>
# env (required): KPOP GTPOP CPOP (Popcorn release, guest tools, deploy bundle), PLAIN_BUILD VPLAIN (vdb build with the
#   §17 counters + guest dir), LOADGEN_BUILD (loadgen with the knee ramp + vectordb plugin), PRETOUCH_DIR,
#   EXPECT_DAX_UUID, WRITERS (1..16), H1_MEASURE_RUN=1 + MEASURE_PART_DIR + MEASURE_ENV_DIR (loadgen in measure.slice
#   on 56-63 and experiments/h1/h1-gate.sh before every lifetime / part, as H1). Optional: URATES, SYSTEMS (subset of
#   "hw pop"), URATE_START (1), URATE_BUDGET_S (1200), SEED (20261019).
# dax0.0, lock, rollback, Host gate and stop rules: as v6-block.sh (m4-lib.sh; owner VDB-urate-<evidence dir name>).
set -uo pipefail
E=$1 R=0
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
SEED_BASE=${SEED:-20261019} OWNER="VDB-urate-$(basename "${E%/}")"
: "${KPOP:?}" "${GTPOP:?}" "${CPOP:?}" "${PLAIN_BUILD:?}" "${VPLAIN:?}" "${LOADGEN_BUILD:?}" "${PRETOUCH_DIR:?}" "${WRITERS:?}"
URATES=${URATES:-100 200 400 800 1600 3200} SYSTEMS=${SYSTEMS:-hw pop} URATE_START=${URATE_START:-1} BUDGET_S=${URATE_BUDGET_S:-1200}
[[ $WRITERS =~ ^[1-9][0-9]?$ ]] && [ "$WRITERS" -le 16 ] || { echo "SEQUENCE STOP: WRITERS must be 1..16"; exit 2; }
for r in $URATES; do [[ $r =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad URATES entry $r"; exit 2; }; done
for s in $SYSTEMS; do case $s in hw|pop) ;; *) echo "SEQUENCE STOP: SYSTEMS is a subset of 'hw pop'"; exit 2;; esac; done
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad URATE_BUDGET_S"; exit 2; }
[ "${H1_MEASURE_RUN:-0}" = 1 ] && [ -d "${MEASURE_PART_DIR:-}" ] && [ -n "${MEASURE_ENV_DIR:-}" ] \
  || { echo "SEQUENCE STOP: needs H1_MEASURE_RUN=1, MEASURE_PART_DIR and MEASURE_ENV_DIR (loadgen CPUs 56-63 are in measure.slice)"; exit 2; }
[[ "${EXPECT_DAX_UUID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "SEQUENCE STOP: EXPECT_DAX_UUID"; exit 2; }
export H1_MEASURE_RUN MEASURE_PART_DIR MEASURE_ENV_DIR
for b in "$PLAIN_BUILD" "$LOADGEN_BUILD"; do
  grep -q "^source_commit=.* dirty=0$" $b/manifest.txt || { echo "SEQUENCE STOP: $b is not a clean build"; exit 2; }
done
WF=$P/workspaces/vdb-data/writes-a27m-b1m-u1m.bin   # m4-run.sh DATASET=28m
AVAIL=$(( $(stat -c %s "$WF") / 48 ))               # update pairs (2 x 24 B records)
for r in $URATES; do
  [ $(( r * BUDGET_S )) -le $AVAIL ] || { echo "SEQUENCE STOP: update budget: rate $r x ${BUDGET_S} s = $(( r * BUDGET_S )) updates > $AVAIL in $WF (rates above $(( AVAIL / BUDGET_S ))/s need a dataset decision, packet §8)"; exit 2; }
done
GUEST_INIT=/home/comsys/vdb/init/seg32c32m-a27m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
VP=${VPLAIN#/home/comsys/}
INSTALL="$VP/bin/vdb-server $PLAIN_BUILD/bin/vdb-server
$VP/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VP/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
COMMON=(DATASET=28m U=0 KIND=urate PLAIN_BUILD=$PLAIN_BUILD VPLAIN=$VPLAIN LOADGEN_BIN=$LOADGEN_BUILD/loadgen
        "XARGS=--writer-threads $WRITERS" URATE_START=$URATE_START)
PE=(C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=poll)  # m4-run.sh's Popcorn variables (named C8/K8/GT8)
dax_root() {  # before a Popcorn run: back to root:root 600 (no server of ours runs between runs); fresh stat check
  [ $CHOWNED = 1 ] || return 0
  block_stop_servers
  block_dax_root || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600"; exit 1; }
  CHOWNED=0
}
dax_comsys() { [ $CHOWNED = 1 ] || chown_dax; }
pretouch_gate() {  # standing rule: both VMs pre-touched after their last QEMU start (Host-only check)
  bash $X/pretouch-gate.sh "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null \
    || { echo "SEQUENCE STOP: pretouch gate ($1; see $E/pretouch-gate.txt)"; exit 1; }
}
one() {  # <sys> <name> <run-specific env...>
  local s=$1 name=$2; shift 2
  pretouch_gate "$name"
  case $s in
    hw)  dax_comsys; run $name SYS=all-HWcc OPCOH_EXPECT=none OPCOH_CHECK_MODE=hwcc "${COMMON[@]}" "$@";;
    pop) dax_root;   run $name SYS=Popcorn OPCOH_EXPECT=swmc_acct OPCOH_CHECK_MODE=popcorn "${COMMON[@]}" "${PE[@]}" "$@";;
  esac
}
block_start
C8=$CPOP K8=$KPOP GT8=$GTPOP  # block_shm_cleanup (m4-lib.sh) reads C8/K8/GT8
pretouch_gate block-start
precheck "$KPOP"
NLIVE=26990000  # live records (pool A; every update deletes one and inserts one)
{ echo "# vector DB update-rate basis (user 2026-10-19, reports/VDB-update-rate-axis-brief.md §3): absolute updates/s, one update = DELETE + INSERT (2 index writes)"
  echo "rates: $URATES (> 800 = stress); % of corpus per hour = R x 3600 / $NLIVE live records"
  for r in $URATES; do python3 -c 'import sys; r=int(sys.argv[1]); print("u%d: %.3f %% of the corpus per hour" % (r, r * 3600 / int(sys.argv[2]) * 100))' $r $NLIVE; done
  echo "writer threads per VM: $WRITERS (vdb-server --writer-threads; same for every system)"
  echo "update spread: writes file $WF (gen_writes.py seed 20261015, target VM uniform per update pair; identical for every system and rate)"
  echo "update budget per lifetime: $AVAIL updates; URATE_BUDGET_S $BUDGET_S"; } > "$E/rate-basis.txt"
printf '# name\tsystem\trate_ups\twriters\tresult_search_s\tconfirm_x_mean\tconfirmed\tlow_rate_violations\turatecheck\tvalid\tramp_end\tknee_search_s\tnote\n' > "$E/urate-results.tsv"
{ echo "# vector DB update-rate sweep: per rate (URATES order) one lifetime per system, order shuffle(seed vdb-urate-<rate>); loadgen seed $SEED_BASE (slo), +100 (warm)"
  for r in $URATES; do echo "u$r: $(SHUFFLE_SEED=vdb-urate-$r shuffle $SYSTEMS)"; done; } | tee "$E/order.txt"
for r in $URATES; do
  lab=""; [ $r -le 800 ] || lab=" (stress)"
  for s in $(SHUFFLE_SEED=vdb-urate-$r shuffle $SYSTEMS); do
    L=$s-u$r
    echo "$(date -Is) urate u$r$lab system $s"
    one $s $L URATE=$r REP=urate-u$r SEED=$SEED_BASE < /dev/null
    python3 $X/urate_check.py $E/$L/slo --writers $WRITERS > $E/$L/slo/urate-check.txt 2>&1
    python3 $X/urate_check.py $E/$L/warm --writers $WRITERS > $E/$L/warm/urate-check.txt 2>&1
    uc=$(grep -m1 '^URATECHECK' $E/$L/slo/urate-check.txt)
    case "$uc" in "URATECHECK PASS"*|"URATECHECK NOTE"*) ;; *) echo "$(date -Is) SEQUENCE STOP: $L: ${uc:-urate_check.py failed}"; exit 1;; esac
    python3 $X/urate_report.py row $E/$L/slo $L $s $r $WRITERS "$uc" >> "$E/urate-results.tsv" || { echo "SEQUENCE STOP: $L: results row"; exit 1; }
    echo "$L: $uc"
  done
done
python3 $X/urate_report.py table $E > $E/urate-summary.csv 2> $E/urate-summary.err || echo "urate_report.py table failed (analysis only; see urate-summary.err)"
pretouch_gate block-end
echo "$(date -Is) SEQUENCE DONE $OWNER (rates $URATES, writers $WRITERS)"

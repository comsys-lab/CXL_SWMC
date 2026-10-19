#!/bin/bash
# Vector DB update-rate sweep (experiment document reports/experiments/vectorDB-update-rate.md; packets
# reports/packets/VDB-urate-packet.v1.md, v1.1.md; brief reports/VDB-update-rate-axis-brief.md; user
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
#   p99 <= 100 ms, knee ramp from URATE_START (1) search/s, >= 300 searches per step (--min-step-queries 300, user
#   2026-10-20; reports/experiments/vectorDB-update-rate.md), --ramp-knee 2 --ramp-knee-floor 1.5, confirm 3 x 30 s,
#   --tol 0.02); then urate_check.py <life>/slo (FAIL stops the block; NOTE "update rate not sustained" recorded) and
#   urate_report.py (one row per lifetime in <E>/urate-results.tsv).
#   Update budget (verifier MEDIUM-1): every lifetime starts from the initial image and may consume at most the
#   writes file's updates (DATASET 28m: 1,000,000 = pool B; 28m-x: X_NB, sized to the free ids of X_MAXIDS). The
#   worst-case consumption is computed from m4-run.sh's KIND=urate loadgen parameters by urate_budget.py (scenario
#   URATE_XFLOOR / URATE_XKNEE / URATE_GMIN, defaults 10 search/s, 400 search/s, 1.2; recorded in budget.txt). A rate
#   whose bound exceeds the budget is refused before the block starts (SEQUENCE STOP "update budget") unless it is
#   listed in URATE_PARTIAL_OK (explicit user decision): such a lifetime may run out of updates, which m4-run.sh
#   records as a NOTE ("update stream exhausted"; the steps before it are kept, the SLO result may be missing).
#   m4-run.sh writes that NOTE for every KIND=urate slo part; this block accepts it only for rates in URATE_PARTIAL_OK
#   and stops otherwise (SEQUENCE STOP "update stream exhausted", verifier MED-2 2026-10-20).
#   Ramp start per rate (user 2026-10-20): URATE_START_MAP "R:S ..." (default "1600:10 3200:10"; every other rate starts
#   at URATE_START); the same start for both systems at a rate; passed per lifetime (m4-run.sh logs it in runs.log, run.sh
#   records the slo part arguments in the lifetime manifest), listed in rate-basis.txt and used for that rate's budget.
#   Fixed load per rate (user 2026-10-20, as H1): after both SLO lifetimes at R, L1(R) = the lower confirm mean of the
#   systems with a confirmed result without a note (urate_report.py level), L2 = 0.5 x L1 (one system only: its value,
#   logged; none: "fixed skipped: no L1"); then per system (the same shuffled order) a new lifetime <sys>-u<R>-fix =
#   m4-run.sh KIND=urate URATE_PARTS="warm fix" RATE=L2,L1 (warm part as above, then settle 60 s + 60 s windows at L2,
#   L1 with the update stream R unchanged), urate_check.py on its fix part (per-window validity; FAIL stops). Levels in
#   <E>/urate-levels.tsv; urate_report.py table writes <E>/urate-fixed.csv. Its worst-case update use (urate_budget.py
#   --fixed) must fit the budget for every rate (no URATE_PARTIAL_OK exemption), checked before the lock.
# usage: urate-block.sh <evidence dir (exists, holds only sequence* files)>
# env (required): KPOP GTPOP CPOP (Popcorn release, guest tools, deploy bundle), PLAIN_BUILD VPLAIN (vdb build with the
#   §17 counters + guest dir), LOADGEN_BUILD (loadgen with the knee ramp + vectordb plugin), PRETOUCH_DIR,
#   EXPECT_DAX_UUID, WRITERS (1..16), H1_MEASURE_RUN=1 + MEASURE_PART_DIR + MEASURE_ENV_DIR (loadgen in measure.slice
#   on 56-63 and experiments/h1/h1-gate.sh before every lifetime / part, as H1). Optional: URATES, SYSTEMS (subset of
#   "hw pop"), URATE_START (1), URATE_START_MAP ("1600:10 3200:10"; "" = URATE_START for all), URATE_FIXED (1; 0 = no
#   fixed-load lifetimes), URATE_XFLOOR / URATE_XKNEE / URATE_GMIN, URATE_PARTIAL_OK, SEED (20261019),
#   URATE_DATASET (28m | 28m-x; 28m-x needs X_DATA X_WRITES X_NB X_MAXIDS X_MAXW X_MAXD X_INIT_CAP, m4-run.sh, and a
#   vdb build >= 17).
# dax0.0, lock, rollback, Host gate and stop rules: as v6-block.sh (m4-lib.sh; owner VDB-urate-<evidence dir name>).
set -uo pipefail
E=$1 R=0
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
SEED_BASE=${SEED:-20261019} OWNER="VDB-urate-$(basename "${E%/}")"
: "${KPOP:?}" "${GTPOP:?}" "${CPOP:?}" "${PLAIN_BUILD:?}" "${VPLAIN:?}" "${LOADGEN_BUILD:?}" "${PRETOUCH_DIR:?}" "${WRITERS:?}"
URATES=${URATES:-100 200 400 800 1600 3200} SYSTEMS=${SYSTEMS:-hw pop} URATE_START=${URATE_START:-1}
XFLOOR=${URATE_XFLOOR:-10} XKNEE=${URATE_XKNEE:-400} GMIN=${URATE_GMIN:-1.2} PARTIAL_OK=${URATE_PARTIAL_OK:-} DS=${URATE_DATASET:-28m}
[[ $WRITERS =~ ^[1-9][0-9]?$ ]] && [ "$WRITERS" -le 16 ] || { echo "SEQUENCE STOP: WRITERS must be 1..16"; exit 2; }
for r in $URATES; do [[ $r =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad URATES entry $r"; exit 2; }; done
for s in $SYSTEMS; do case $s in hw|pop) ;; *) echo "SEQUENCE STOP: SYSTEMS is a subset of 'hw pop'"; exit 2;; esac; done
for v in "$XFLOOR" "$XKNEE" "$GMIN" "$URATE_START"; do [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "SEQUENCE STOP: bad budget scenario value $v"; exit 2; }; done
for r in $PARTIAL_OK; do [[ " $URATES " == *" $r "* ]] || { echo "SEQUENCE STOP: URATE_PARTIAL_OK entry $r not in URATES"; exit 2; }; done
START_MAP=${URATE_START_MAP-1600:10 3200:10} FIXED=${URATE_FIXED:-1}
[[ $FIXED =~ ^[01]$ ]] || { echo "SEQUENCE STOP: URATE_FIXED is 0 or 1"; exit 2; }
for m in $START_MAP; do
  [[ $m =~ ^[1-9][0-9]*:[0-9]+(\.[0-9]+)?$ ]] || { echo "SEQUENCE STOP: bad URATE_START_MAP entry $m"; exit 2; }
done
start_of() {  # ramp start (search/s) of rate $1: URATE_START_MAP entry, else URATE_START
  local m; for m in $START_MAP; do [ "${m%%:*}" = "$1" ] && { echo "${m#*:}"; return; }; done; echo "$URATE_START"
}
[ "${H1_MEASURE_RUN:-0}" = 1 ] && [ -d "${MEASURE_PART_DIR:-}" ] && [ -n "${MEASURE_ENV_DIR:-}" ] \
  || { echo "SEQUENCE STOP: needs H1_MEASURE_RUN=1, MEASURE_PART_DIR and MEASURE_ENV_DIR (loadgen CPUs 56-63 are in measure.slice)"; exit 2; }
[[ "${EXPECT_DAX_UUID:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "SEQUENCE STOP: EXPECT_DAX_UUID"; exit 2; }
export H1_MEASURE_RUN MEASURE_PART_DIR MEASURE_ENV_DIR
for b in "$PLAIN_BUILD" "$LOADGEN_BUILD"; do
  grep -q "^source_commit=.* dirty=0$" $b/manifest.txt || { echo "SEQUENCE STOP: $b is not a clean build"; exit 2; }
done
case $DS in
  28m) WF=$P/workspaces/vdb-data/writes-a27m-b1m-u1m.bin;;   # m4-run.sh DATASET=28m
  28m-x) WF=${X_WRITES:?URATE_DATASET=28m-x needs X_WRITES}; : "${X_DATA:?}" "${X_NB:?}" "${X_MAXIDS:?}" "${X_MAXW:?}" "${X_MAXD:?}" "${X_INIT_CAP:?}"
         export X_DATA X_WRITES X_NB X_MAXIDS X_MAXW X_MAXD X_INIT_CAP;;
  *) echo "SEQUENCE STOP: URATE_DATASET is 28m or 28m-x"; exit 2;;
esac
AVAIL=$(( $(stat -c %s "$WF") / 48 ))               # update pairs (2 x 24 B records)
[ "$DS" = 28m ] || [ "$X_NB" -ge "$AVAIL" ] || AVAIL=$X_NB
BUDGET=""
for r in $URATES; do  # SLO lifetime: worst case with this rate's ramp start
  b=$(python3 $X/urate_budget.py $X/m4-run.sh --start "$(start_of $r)" --x-floor "$XFLOOR" --x-knee "$XKNEE" --g-min "$GMIN" --rate $r) \
    || { echo "SEQUENCE STOP: urate_budget.py"; exit 2; }
  BUDGET+="u$r: $b"$'\n'
  need=$(echo "$b" | sed -n "s/^rate=$r updates=//p")
  [ -n "$need" ] || { echo "SEQUENCE STOP: no budget for rate $r"; exit 2; }
  [ "$need" -le "$AVAIL" ] || [[ " $PARTIAL_OK " == *" $r "* ]] \
    || { echo "SEQUENCE STOP: update budget: rate $r needs up to $need updates (worst case: $(echo "$b" | head -n 1)) > $AVAIL in $WF; list it in URATE_PARTIAL_OK only with a user decision"; exit 2; }
done
if [ "$FIXED" = 1 ]; then  # fixed-load lifetimes: must fit for every rate (no exemption)
  FB=$(python3 $X/urate_budget.py $X/m4-run.sh --fixed $(for r in $URATES; do echo --rate $r; done)) || { echo "SEQUENCE STOP: urate_budget.py --fixed"; exit 2; }
  BUDGET+="fixed-load lifetime: $FB"$'\n'
  for r in $URATES; do
    need=$(echo "$FB" | sed -n "s/^fixed_rate=$r updates=//p")
    [ -n "$need" ] && [ "$need" -le "$AVAIL" ] \
      || { echo "SEQUENCE STOP: update budget: fixed-load lifetime at rate $r needs up to ${need:-?} updates > $AVAIL in $WF"; exit 2; }
  done
fi
GUEST_INIT=/home/comsys/vdb/init/seg32c32m-a27m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
VP=${VPLAIN#/home/comsys/}
INSTALL="$VP/bin/vdb-server $PLAIN_BUILD/bin/vdb-server
$VP/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VP/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
COMMON=(DATASET=$DS U=0 KIND=urate PLAIN_BUILD=$PLAIN_BUILD VPLAIN=$VPLAIN LOADGEN_BIN=$LOADGEN_BUILD/loadgen
        "XARGS=--writer-threads $WRITERS")  # URATE_START per rate (start_of)
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
  echo "update budget per lifetime: $AVAIL updates (dataset $DS, $WF); worst case per lifetime (urate_budget.py):"
  echo -n "$BUDGET"; echo "rates allowed to exhaust the budget (URATE_PARTIAL_OK): ${PARTIAL_OK:-none}"
  echo "SLO ramp start per rate (search/s; URATE_START=$URATE_START, URATE_START_MAP=[$START_MAP]):$(for r in $URATES; do echo -n " u$r=$(start_of $r)"; done)"
  echo "fixed-load lifetimes (L2 = 0.5 x L1, L1 = lower confirmed confirm mean; settle 60 s + 60 s windows): $([ "$FIXED" = 1 ] && echo yes || echo no)"
  [ "$DS" = 28m ] || echo "dataset 28m-x: X_DATA=$X_DATA X_WRITES=$X_WRITES X_NB=$X_NB X_MAXIDS=$X_MAXIDS X_MAXW=$X_MAXW X_MAXD=$X_MAXD X_INIT_CAP=$X_INIT_CAP"
  echo "writer threads $WRITERS > 1: HNSW graphs are not reproducible record by record (level draws depend on scheduling); recall is reported per system and rung (urate-recall.sh, offline)"; } > "$E/rate-basis.txt"
printf '# name\tsystem\trate_ups\twriters\tresult_search_s\tconfirm_x_mean\tconfirmed\tlow_rate_violations\turatecheck\tvalid\tramp_end\tknee_search_s\tnote\tresult_offered_raw\n' > "$E/urate-results.tsv"
{ echo "# vector DB update-rate sweep: per rate (URATES order) one lifetime per system, order shuffle(seed vdb-urate-<rate>); loadgen seed $SEED_BASE (slo), +100 (warm)"
  for r in $URATES; do echo "u$r: $(SHUFFLE_SEED=vdb-urate-$r shuffle $SYSTEMS)"; done; } | tee "$E/order.txt"
printf '# rate_ups\tsystems\tL1_source\tL1_search_s\tL2_search_s\tnote\n' > "$E/urate-levels.tsv"
for r in $URATES; do
  lab=""; [ $r -le 800 ] || lab=" (stress)"
  for s in $(SHUFFLE_SEED=vdb-urate-$r shuffle $SYSTEMS); do
    L=$s-u$r
    echo "$(date -Is) urate u$r$lab system $s (ramp start $(start_of $r) search/s)"
    one $s $L URATE=$r URATE_START=$(start_of $r) REP=urate-u$r SEED=$SEED_BASE < /dev/null
    python3 $X/urate_check.py $E/$L/slo --writers $WRITERS > $E/$L/slo/urate-check.txt 2>&1
    python3 $X/urate_check.py $E/$L/warm --writers $WRITERS > $E/$L/warm/urate-check.txt 2>&1
    # update stream exhausted (m4-run.sh NOTE, same test as there): allowed only for rates in URATE_PARTIAL_OK
    if grep -q '"reason":"stream [a-z]* exhausted' $E/$L/slo/loadgen/steps.jsonl && [[ " $PARTIAL_OK " != *" $r "* ]]; then
      echo "$(date -Is) SEQUENCE STOP: $L: update stream exhausted at rate $r, which is not in URATE_PARTIAL_OK (${PARTIAL_OK:-none})"; exit 1
    fi
    uc=$(grep -m1 '^URATECHECK' $E/$L/slo/urate-check.txt)
    case "$uc" in "URATECHECK PASS"*|"URATECHECK NOTE"*) ;; *) echo "$(date -Is) SEQUENCE STOP: $L: ${uc:-urate_check.py failed}"; exit 1;; esac
    python3 $X/urate_report.py row $E/$L/slo $L $s $r $WRITERS "$uc" >> "$E/urate-results.tsv" || { echo "SEQUENCE STOP: $L: results row"; exit 1; }
    echo "$L: $uc"
  done
  [ "$FIXED" = 1 ] || continue
  # fixed load at rate r: L1 = lower confirm mean of the systems with a confirmed result without a note, L2 = 0.5 x L1
  L1="" src="" why=""
  for s in $SYSTEMS; do
    x=$(python3 $X/urate_report.py level $E/$s-u$r/slo 2>&1) || { why+=" $s: $x;"; continue; }
    if [ -z "$L1" ] || python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "$x" "$L1"; then L1=$x src=$s; fi
  done
  if [ -z "$L1" ]; then
    printf '%s\t-\t-\t-\t-\tfixed skipped: no L1;%s\n' $r "$why" >> "$E/urate-levels.tsv"
    echo "$(date -Is) u$r: fixed skipped: no L1 ($why)"; continue
  fi
  L2=$(python3 -c 'import sys; print(round(0.5 * float(sys.argv[1]), 3))' "$L1")
  [ -z "$why" ] || echo "$(date -Is) u$r: L1 from $src only ($why)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $r "$SYSTEMS" "$src" "$L1" "$L2" "${why:+one system only:$why}" >> "$E/urate-levels.tsv"
  for s in $(SHUFFLE_SEED=vdb-urate-$r shuffle $SYSTEMS); do
    L=$s-u$r-fix
    echo "$(date -Is) urate u$r$lab fixed load system $s: L2 $L2, L1 $L1 search/s"
    one $s $L URATE=$r URATE_START=$(start_of $r) URATE_PARTS="warm fix" RATE=$L2,$L1 REP=urate-u$r-fix SEED=$SEED_BASE < /dev/null
    python3 $X/urate_check.py $E/$L/fix --writers $WRITERS > $E/$L/fix/urate-check.txt 2>&1
    python3 $X/urate_check.py $E/$L/warm --writers $WRITERS > $E/$L/warm/urate-check.txt 2>&1
    uc=$(grep -m1 '^URATECHECK' $E/$L/fix/urate-check.txt)
    case "$uc" in "URATECHECK PASS"*|"URATECHECK NOTE"*) ;; *) echo "$(date -Is) SEQUENCE STOP: $L: ${uc:-urate_check.py failed}"; exit 1;; esac
    echo "$L: windows $(cat $E/$L/fix/h1-steps.txt) $(python3 -c 'import csv,sys; print(" ".join("step%s valid=%s" % (r["step"], r["valid"]) for r in csv.DictReader(open(sys.argv[1]))))' $E/$L/fix/urate-check.csv)"
  done
done
python3 $X/urate_report.py table $E > $E/urate-summary.csv 2> $E/urate-summary.err || echo "urate_report.py table failed (analysis only; see urate-summary.err)"
pretouch_gate block-end
echo "$(date -Is) SEQUENCE DONE $OWNER (rates $URATES, writers $WRITERS)"

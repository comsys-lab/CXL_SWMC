#!/bin/bash
# Run set "vdb" (evaluation-pipeline rev 3 §3.3; reports/experiments/two-workload-evaluation-2vm.md): the vector DB
# op-mix lifetimes of H1 and H2 in one run set, through the H1 vector DB hook (experiments/h1/hook.sh -> v6-block.sh
# H1-HOOK v2 -> vectordb/m4-run.sh KIND=h1) with the evaluation parameters of eval.conf:
#   run 1 (and every run when VDB_LATER_RUNS=r1): H1 r1 lifetimes per mix (hw, pop SLO-only; mg SLO -> levels -> fix;
#     mgoff fix; hw, pop fix-only), levels L1 = weakest confirmed max, L2 = L1 / 2 (experiments/h1/levels.py)
#   runs k >= 2 (VDB_LATER_RUNS=cont, cut Q8): H1 cont lifetimes (hw, pop, mg each SLO -> fix at the levels of run
#     LEVELS_FROM_RUN; mgoff fix after mg), Latin order rotated by k (needs run LEVELS_FROM_RUN accepted; k <= 3)
#   VDB_H2_LEVELS=1 (user 2026-10-20, M4 = b): per mix also the H2 level set (L1 = lower confirmed max of hw and pop,
#     L2 = L1 / 2; runs >= 2: run LEVELS_FROM_RUN's), hw and pop fix-only lifetimes, skipped where equal to the H1 set
#     (v6-block.sh h2_mix; <run dir>/levels-h2-used.tsv, h2-runs.tsv)
#   every lifetime: 15 search + 1 writer per VM (threads = vCPUs), dataset 28m-x (3.4M pool B), region REGION (2 MiB
#   ring), Popcorn bundle POP_C; Megalon capacity VDB_MG_CAPACITY (h1: --max-ids 28000000, see m4-run.sh).
# Steps of a real run: evidence dir E (new) -> registry "started" -> lock eval-vdb-run<k> -> pretouch + H1 Host gate ->
# hook.sh -> gates -> experiments/h1/collect.py + check.py -> registry "measured" (check PASS) or "stopped" -> export.py.
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/gate-*.txt, E/vdb/r<n>/{run,collect,check.txt}, E/vdb/levels.tsv
# (round n = 1 in r1 mode, = k in cont mode). Acceptance: registry.py accept vdb <k> <E> after reviewing check.txt.
# usage: runset-vdb.sh <k> [--dry] [--v N]   (lib.sh)
RUNSET=vdb WL=vdb
. "$(dirname "$0")/lib.sh"
H=$TREE/experiments/h1 X=$TREE/experiments/vectordb
G=$X/host-gate.sh PG=$X/pretouch-gate.sh PLAN=$H/h1-plan.tsv
[ "$VDB_SYSTEMS" = "hw pop mg" ] || die "VDB_SYSTEMS must be 'hw pop mg' (the H1 hook runs exactly these + mgoff)"
[ "$VDB_MG_POINTS" = "$VDB_POINTS" ] || die "VDB_MG_POINTS must equal VDB_POINTS (the H1 hook runs Megalon at every mix)"
[ "$VDB_SLO_PCT:$VDB_SLO_MS" = 99:100 ] || die "VDB SLO is fixed in the H1 hook (search:99:100)"
[ "$VDB_DATASET" = 28m-x ] || [ "$VDB_DATASET" = 28m ] || die "bad VDB_DATASET"
case $VDB_MG_CAPACITY in h1) XMG=1;; x) XMG=0;; *) die "bad VDB_MG_CAPACITY";; esac
# mixes from the H1 plan (mix tag -> param U=<u>), settle_s of the vdb rows
MIXES="" SETTLE=
for m in $VDB_POINTS; do
  row=$(awk -F'\t' -v m="$m" '!/^#/ && $1 == "vdb" && $2 == m' "$PLAN")
  [ -n "$row" ] || die "mix $m not a vdb row of $PLAN"
  MIXES="$MIXES$m=$(echo "$row" | cut -f3) " SETTLE=$(echo "$row" | cut -f8)
done
MIXES=${MIXES% }
# mode, round label and levels
LV= ROOTS=() MODE=r1 N=1 H2F=
case $VDB_H2_LEVELS in 0|1) ;; *) die "bad VDB_H2_LEVELS";; esac
if [ "$K" -gt 1 ] && [ "$VDB_LATER_RUNS" = cont ]; then
  [ "$K" -le 3 ] || die "cont mode supports runs 2 and 3 (H1 hook)"
  MODE=cont N=$K
  E1=$(run_dir_of vdb "$LEVELS_FROM_RUN") || { [ $DRY = 1 ] && E1=; } || die "run $LEVELS_FROM_RUN of vdb is not accepted (registry.py accept)"
  if [ -n "$E1" ]; then
    LV=$(python3 -I -B $H/attempts.py levels "$E1" vdb) && [ -f "$LV" ] || die "no levels.tsv in $E1"
    ROOTS=(--round-root "1=$E1")
    H2F=$(python3 -I -B $H/attempts.py dir "$E1" vdb 1)/run/levels-h2-used.tsv
    [ "$VDB_H2_LEVELS" != 1 ] || [ -f "$H2F" ] || die "no H2 levels of run $LEVELS_FROM_RUN ($H2F)"
    for j in $(seq 2 $((K - 1))); do Ej=$(run_dir_of vdb $j) || die "run $j of vdb is not accepted"; ROOTS+=(--round-root "$j=$Ej"); done
    plan "levels from run $LEVELS_FROM_RUN: $LV"
  else plan "levels: run $LEVELS_FROM_RUN of vdb not accepted yet (a real run would stop here)"; fi
elif [ "$K" -gt 1 ]; then [ "$VDB_LATER_RUNS" = r1 ] || die "bad VDB_LATER_RUNS"; fi
SEEDB=$((SEED_BASE + K - N))   # loadgen seed of the run = SEED_BASE + k in both modes (hook: H1_SEED_BASE + n)
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_MEG_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" \
  "$VDB_MEG_CFG" "$POP_C/p-popcorn-shm.sh" "$VDB_X_DATA/pool_b.fbin" "$VDB_X_WRITES" "$EVD/pins-vdb.sh"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
APP=$("$VDB_PLAIN_BUILD/bin/vdb-server" --nodes 2 --segments 32 --M 16 --efc 128 --ef 32 --max-writes $VDB_X_MAXW \
  --max-ids $VDB_X_MAXIDS --max-deletes $VDB_X_MAXD --search-threads $VDB_SEARCH_THREADS --wait-timeout-ms 60000 \
  --start-timeout-ms 5400000 --init-capacity $VDB_X_INIT_CAP --print-app-bytes) || die "print-app-bytes"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
plan "app HWcc $APP B + ring $RING B of 268435456 B (hwcc_alloc for the system $((268435456 - APP - RING)) B)"
[ $((APP + RING)) -lt 268435456 ] || die "app + ring exceed the HWcc budget"
( cd "$H" && . "$EVD/pins-vdb.sh" && echo "$PIN_SHA256" | sha256sum --quiet -c - ) || die "eval pins (pins-vdb.sh) do not verify"
plan "pins verify ($EVD/pins-vdb.sh); mode $MODE round $N mixes [$MIXES] settle ${SETTLE}s seed $((SEEDB + N))"
plan "threads: --search-threads $VDB_SEARCH_THREADS + 1 writer; dataset $VDB_DATASET; Megalon capacity $VDB_MG_CAPACITY; region $REGION"
need_env
lock_free
evidence_dir
S=$E/vdb/r$N
HENV=(EVAL_RUN=$K EVAL_REGION=$REGION EVAL_DATASET=$VDB_DATASET VDB_SEARCH_THREADS=$VDB_SEARCH_THREADS
  X_DATA=$VDB_X_DATA X_WRITES=$VDB_X_WRITES X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$VDB_X_MAXD
  X_INIT_CAP=$VDB_X_INIT_CAP X_MEGALON_H1CAP=$XMG H1_SEED_BASE=$SEEDB H1_SETTLE_S=$SETTLE H1_MEASURE_RUN=1
  PRETOUCH_DIR=${PRETOUCH_DIR:-} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-} MEASURE_PART_DIR=${MEASURE_PART_DIR:-})
[ $MODE = r1 ] && HENV+=(H1_LEVELS_CMD=$H/levels-cb.sh H1_PLAN=$PLAN H1_W=vdb H1_LEVELS_OUT=$E/vdb/levels.tsv)
[ "$VDB_H2_LEVELS" = 1 ] && HENV+=(EVAL_H2=1) && [ -n "$H2F" ] && HENV+=(EVAL_H2_FROM=$H2F)
HOOK=(bash $H/hook.sh vdb $MODE $S/run $N "$MIXES" ${LV:+"$LV"})
plan "block: env ${HENV[*]} ${HOOK[*]}"
plan "then: collect.py --plan $PLAN --workload vdb --levels ${LV:-$E/vdb/levels.tsv} $S; check.py --round $N ${ROOTS[*]} $E"
if [ $DRY = 1 ]; then
  [ $MODE = r1 ] || [ -n "$LV" ] || LV=/dev/null   # cont dry without run-1 levels: hook needs a levels arg
  block_dry "missing or not empty" env "${HENV[@]}" bash $H/hook.sh vdb $MODE @DIR@ $N "$MIXES" ${LV:+"$LV"}
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add vdb vdb $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$VDB_PLAIN_BUILD" "$VDB_MEG_BUILD" "$VDB_LOADGEN_BUILD"
$REG add vdb vdb $K "$E" $CSHA started "mode $MODE round $N commit $COMMIT"
OWNER=eval-vdb-run$K
bash $G lock $OWNER || stop "lock"
trap 'bash $G unlock $OWNER' EXIT
gates() {
  bash $PG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null || stop "pretouch gate ($1)"
  MEASURE_ENV_DIR=$MEASURE_ENV_DIR MEASURE_PART_DIR=$MEASURE_PART_DIR bash $H/h1-gate.sh check "$E/gate-$1.txt" || stop "h1 gate ($1)"
  log "gate $1: PASS"
}
mkdir -p "$S/run" || stop "mkdir $S/run"
gates start
log "block start: mode $MODE round $N mixes [$MIXES]"
env "${HENV[@]}" "${HOOK[@]}" || stop "hook (see $S/run/sequence.log)"
gates end
nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload vdb --levels "${LV:-$E/vdb/levels.tsv}" "$S" > "$S/collect.log" 2>&1 \
  || stop "collect: $(tail -n 1 "$S/collect.log")"
python3 -B $H/check.py --plan "$PLAN" --workload vdb --round $N "${ROOTS[@]}" "$E" > "$S/check.log" 2>&1
CRC=$?
log "check: $(tail -n 1 "$S/check.txt" 2>/dev/null || echo 'no check.txt')"
[ $CRC = 0 ] || stop "check FAIL (see $S/check.txt)"
$REG add vdb vdb $K "$E" $CSHA measured "$(tail -n 1 "$S/check.txt" | cut -c1-200)"
export_run "$TREE/experiments/vectordb/export.py" "$E"
log "RUNSET DONE: review $S/check.txt, then: python3 $EVD/registry.py accept vdb $K $E"

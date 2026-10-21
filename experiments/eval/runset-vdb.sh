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
# Optional conf keys (eval2-h1.conf; absent in eval.conf = the behaviour above; never inherited from the environment):
#   VDB_PINS       pins file name next to pins-vdb.sh (e.g. pins-vdb-confirm11.sh for builds/vdb-loadgen/11); used by
#                  this driver's pin check and by hook.sh (EVAL_PINS)
#   VDB_SLO_EXTRA  loadgen arguments appended to every SLO part (m4-run.sh KIND=h1 H1_SLO_EXTRA; fixed-load parts
#                  unchanged), e.g. the 2026-10-21 22:4x confirm rule; check.py expects its last --confirm-reps
RUNSET=vdb WL=vdb
unset VDB_PINS VDB_SLO_EXTRA VDB_LEVELS_CONFIRM_FAIL
. "$(dirname "$0")/lib.sh"
VPINS=$EVD/${VDB_PINS:-pins-vdb.sh}
[[ ${VDB_PINS:-x} != */* ]] || die "VDB_PINS is a file name next to runset-vdb.sh"
[[ ${VDB_SLO_EXTRA:-} =~ ^[-a-z0-9.,\ ]*$ ]] || die "bad VDB_SLO_EXTRA"   # commas: --overload f1,f2 lists
CREPS=3; set -- ${VDB_SLO_EXTRA:-}
while [ $# -gt 0 ]; do [ "$1" = --confirm-reps ] && CREPS=${2:-x}; shift; done
[[ $CREPS =~ ^[1-9]$ ]] || die "bad --confirm-reps in VDB_SLO_EXTRA"
H=$TREE/experiments/h1 X=$TREE/experiments/vectordb
G=$X/host-gate.sh PG=$X/pretouch-gate.sh PLAN=$H/h1-plan.tsv
# VDB_SYSTEMS "hw pop mg" = the H1 hook set (+ mgoff). Popcorn-only mode (VDB_SYSTEMS=pop, e.g. recv-sleep.conf): one
# round r1 without Megalon (hook EVAL_SYSTEMS=pop): per mix pop SLO-only lifetime, pop fix-only lifetime at the H1
# levels and (VDB_H2_LEVELS=1) at the H2 levels of the accepted run LEVELS_FROM_RUN of LEVELS_REGISTRY (LEVELS_SOURCE=
# registry); no collect.py / check.py (3-system H1 figures), recv_check.py instead.
POPONLY=0
case $VDB_SYSTEMS in
  "hw pop mg") [ "$VDB_MG_POINTS" = "$VDB_POINTS" ] || die "VDB_MG_POINTS must equal VDB_POINTS (the H1 hook runs Megalon at every mix)";;
  pop) POPONLY=1
       [ -z "$VDB_MG_POINTS" ] || die "VDB_SYSTEMS=pop needs an empty VDB_MG_POINTS"
       [ "${LEVELS_SOURCE:-}" = registry ] || die "VDB_SYSTEMS=pop takes its levels from another registry (LEVELS_SOURCE=registry)"
       [ "$K" = 1 ] || die "VDB_SYSTEMS=pop supports run 1 only (one r1 round)";;
  *) die "VDB_SYSTEMS must be 'hw pop mg' (the H1 hook runs exactly these + mgoff) or 'pop' (Popcorn-only mode)";;
esac
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
# run plan (2026-10-21, new H1 u10 u95): h1-plan.tsv now has more vdb rows than one run set runs (u5 u10 u50 u90 u95);
# levels-cb.sh, h2_mix, collect.py and check.py take every vdb row of their plan as a mix of the round, so they get
# RPLAN = h1-plan.tsv with the vdb rows restricted to VDB_POINTS (plan order; other workloads' rows kept), written to
# E/vdb/run-plan.tsv at the real start. With eval.conf (u5 u50 u90) its rows equal the vdb rows the plan had before.
RPLAN=   # set after evidence_dir
# VDB_LEVELS_CONFIRM_FAIL (optional; verifier M2, user 2026-10-22: highest_pass in eval2-h1.conf): written as the plan
# directive "#! levels_confirm_fail=<v>" that levels.py, check.py and v6-block.sh h2_mix read (absent = lowest_step)
case ${VDB_LEVELS_CONFIRM_FAIL:-lowest_step} in lowest_step|highest_pass) ;; *) die "bad VDB_LEVELS_CONFIRM_FAIL (lowest_step | highest_pass)";; esac
run_plan() { [ -z "${VDB_LEVELS_CONFIRM_FAIL:-}" ] || echo "#! levels_confirm_fail=$VDB_LEVELS_CONFIRM_FAIL"
  awk -F'\t' -v pts=" $VDB_POINTS " '/^#/ || $1 != "vdb" || index(pts, " " $2 " ")' "$PLAN"; }
[ "$(run_plan | awk -F'\t' '!/^#/ && $1 == "vdb"' | wc -l)" = "$(echo $VDB_POINTS | wc -w)" ] || die "run plan: vdb rows != VDB_POINTS"
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
if [ $POPONLY = 1 ]; then  # levels of the Popcorn-only round: run LEVELS_FROM_RUN of LEVELS_REGISTRY (every mix of VDB_POINTS)
  levels_dir_of vdb || die "no accepted vdb run $LEVELS_FROM_RUN in $LEVELS_REGISTRY"
  E1=$LEVELS_SRC_DIR
  LV=$(python3 -I -B $H/attempts.py levels "$E1" vdb) && [ -f "$LV" ] || die "no levels.tsv in $E1"
  for m in $VDB_POINTS; do awk -F'\t' -v m="$m" 'NR > 1 && $1 == m { f = 1 } END { exit !f }' "$LV" || die "no H1 levels of $m in $LV"; done
  if [ "$VDB_H2_LEVELS" = 1 ]; then
    H2F=$(python3 -I -B $H/attempts.py dir "$E1" vdb 1)/run/levels-h2-used.tsv
    [ -f "$H2F" ] || die "no H2 levels in $E1 ($H2F)"
    for m in $VDB_POINTS; do awk -F'\t' -v m="$m" '$1 == m { f = 1 } END { exit !f }' "$H2F" || die "no H2 levels of $m in $H2F"; done
  fi
  plan "Popcorn-only round (recv_mode $RECV_MODE): levels from $LEVELS_REGISTRY vdb run $LEVELS_FROM_RUN = $E1 (config_sha256 $LEVELS_SRC_SHA): H1 $LV${H2F:+, H2 $H2F}"
  for m in $VDB_POINTS; do
    plan "  $m: H1 L2,L1 rates $(awk -F'\t' -v m="$m" 'NR > 1 && $1 == m { print $10 "," $9 }' "$LV")${H2F:+; H2 L2,L1 rates $(awk -F'\t' -v m="$m" '$1 == m { print $5 "," $4 " (" $6 ")" }' "$H2F")}"
  done
fi
SEEDB=$((SEED_BASE + K - N))   # loadgen seed of the run = SEED_BASE + k in both modes (hook: H1_SEED_BASE + n)
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_MEG_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" \
  "$VDB_MEG_CFG" "$POP_C/p-popcorn-shm.sh" "$VDB_X_DATA/pool_b.fbin" "$VDB_X_WRITES" "$VPINS"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
APP=$("$VDB_PLAIN_BUILD/bin/vdb-server" --nodes 2 --segments 32 --M 16 --efc 128 --ef 32 --max-writes $VDB_X_MAXW \
  --max-ids $VDB_X_MAXIDS --max-deletes $VDB_X_MAXD --search-threads $VDB_SEARCH_THREADS --wait-timeout-ms 60000 \
  --start-timeout-ms 5400000 --init-capacity $VDB_X_INIT_CAP --print-app-bytes) || die "print-app-bytes"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
plan "app HWcc $APP B + ring $RING B of 268435456 B (hwcc_alloc for the system $((268435456 - APP - RING)) B)"
[ $((APP + RING)) -lt 268435456 ] || die "app + ring exceed the HWcc budget"
( cd "$H" && . "$VPINS" && echo "$PIN_SHA256" | sha256sum --quiet -c - ) || die "eval pins ($VPINS) do not verify"
plan "pins verify ($VPINS); mode $MODE round $N mixes [$MIXES] settle ${SETTLE}s seed $((SEEDB + N))"
plan "slo part extra loadgen args: [${VDB_SLO_EXTRA:-}] (check.py confirm reps $CREPS); loadgen $VDB_LOADGEN_BUILD"
plan "threads: --search-threads $VDB_SEARCH_THREADS + 1 writer; dataset $VDB_DATASET; Megalon capacity $VDB_MG_CAPACITY; region $REGION"
need_env
lock_free
evidence_dir
S=$E/vdb/r$N RPLAN=$E/vdb/run-plan.tsv
plan "levels on a failed confirm: ${VDB_LEVELS_CONFIRM_FAIL:-lowest_step} (failed start rate: lowest_step; All-HWcc must be confirmed)"
plan "run plan $RPLAN (written at the start): vdb rows $(run_plan | awk -F'\t' '!/^#/ && $1 == "vdb" { printf "%s ", $2 "(" $3 ",x" $4 ")" }')"
HENV=(EVAL_RUN=$K EVAL_REGION=$REGION EVAL_DATASET=$VDB_DATASET VDB_SEARCH_THREADS=$VDB_SEARCH_THREADS
  X_DATA=$VDB_X_DATA X_WRITES=$VDB_X_WRITES X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$VDB_X_MAXD
  X_INIT_CAP=$VDB_X_INIT_CAP X_MEGALON_H1CAP=$XMG H1_SEED_BASE=$SEEDB H1_SETTLE_S=$SETTLE H1_MEASURE_RUN=1
  PRETOUCH_DIR=${PRETOUCH_DIR:-} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-} MEASURE_PART_DIR=${MEASURE_PART_DIR:-}
  EVAL_RECV_MODE=$RECV_MODE)
[ -z "${VDB_PINS:-}" ] || HENV+=(EVAL_PINS=$VDB_PINS)
[ -z "${VDB_SLO_EXTRA:-}" ] || HENV+=("H1_SLO_EXTRA=$VDB_SLO_EXTRA")
if [ $POPONLY = 1 ]; then HENV+=(EVAL_SYSTEMS=pop)   # r1 with the given levels LV (hook.sh EVAL_SYSTEMS)
elif [ $MODE = r1 ]; then HENV+=(H1_LEVELS_CMD=$H/levels-cb.sh H1_PLAN=$RPLAN H1_W=vdb H1_LEVELS_OUT=$E/vdb/levels.tsv); fi
[ "$VDB_H2_LEVELS" = 1 ] && HENV+=(EVAL_H2=1) && [ -n "$H2F" ] && HENV+=(EVAL_H2_FROM=$H2F)
HOOK=(bash $H/hook.sh vdb $MODE $S/run $N "$MIXES" ${LV:+"$LV"})
plan "block: env ${HENV[*]} ${HOOK[*]}"
if [ $POPONLY = 1 ]; then plan "then: recv_check.py $S/run --mode $RECV_MODE (no collect.py / check.py: 3-system H1 figures)"
else plan "then: collect.py --plan $RPLAN --workload vdb --levels ${LV:-$E/vdb/levels.tsv} $S; check.py --round $N ${ROOTS[*]} $E"; fi
if [ $DRY = 1 ]; then
  [ $MODE = r1 ] || [ -n "$LV" ] || LV=/dev/null   # cont dry without run-1 levels: hook needs a levels arg
  block_dry "missing or not empty" env "${HENV[@]}" bash $H/hook.sh vdb $MODE @DIR@ $N "$MIXES" ${LV:+"$LV"}
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" && mkdir "$E/vdb" && run_plan > "$RPLAN" || die "mkdir $E / run plan"
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
if [ $POPONLY = 1 ]; then  # Popcorn-only round: hook checked h1-runs.tsv and every lifetime's RUNCHECK; receive mode check
  python3 -I -B $EVD/recv_check.py "$S/run" --mode "$RECV_MODE" > "$S/recv-check.log" 2>&1
  CRC=$?
  log "recv check: $(tail -n 1 "$S/run/recv-check.txt" 2>/dev/null || echo 'no recv-check.txt')"
  [ $CRC = 0 ] || stop "recv check FAIL (see $S/run/recv-check.txt)"
  $REG add vdb vdb $K "$E" $CSHA measured "$(tail -n 1 "$S/run/recv-check.txt" | cut -c1-200)"
  export_run "$TREE/experiments/vectordb/export.py" "$E"
  log "RUNSET DONE: review $S/run/recv-check.txt and $S/run/*/h1-runcheck.txt, then: ${REGISTRY:+EVAL_REGISTRY=$REGISTRY }python3 $EVD/registry.py accept vdb $K $E"
  exit 0
fi
nice -n 19 python3 -B $H/collect.py --plan "$RPLAN" --workload vdb --levels "${LV:-$E/vdb/levels.tsv}" "$S" > "$S/collect.log" 2>&1 \
  || stop "collect: $(tail -n 1 "$S/collect.log")"
H1_CONFIRM_REPS=$CREPS python3 -B $H/check.py --plan "$RPLAN" --workload vdb --round $N "${ROOTS[@]}" "$E" > "$S/check.log" 2>&1
CRC=$?
log "check: $(tail -n 1 "$S/check.txt" 2>/dev/null || echo 'no check.txt')"
[ $CRC = 0 ] || stop "check FAIL (see $S/check.txt)"
$REG add vdb vdb $K "$E" $CSHA measured "$(tail -n 1 "$S/check.txt" | cut -c1-200)"
export_run "$TREE/experiments/vectordb/export.py" "$E"
log "RUNSET DONE: review $S/check.txt, then: python3 $EVD/registry.py accept vdb $K $E"

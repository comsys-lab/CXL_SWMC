#!/bin/bash
# Run set "rs-main" (evaluation-pipeline rev 3 §3.3, §6.3; reports/experiments/two-workload-evaluation-2vm.md): RecSys
# streaming SLO lifetimes of all-HWcc and Popcorn at RS_POINTS samples/s (experiments/recsys/main-block.sh
# BLOCK=stream with EVAL_RUN), threads = vCPUs (node 0: RS_THREADS update threads, node 1: RS_THREADS serving), region
# REGION (2 MiB ring), and the fixed-load windows of user decision 2026-10-20:
#   RS_FIX_LEVELS (L1 L2: L1 = lower confirmed max of hw and pop at the rate, L2 = L1 / 2), a RS_FIX_FALLBACK_Q window
#   where hw or pop has no confirmed result, plus a RS_MG_COMPARE_Q window at the RS_MG_POINTS rates (comparison with
#   the Megalon windows of run set rs-h1); RS_FIX_SEP=1: per system a fix-only lifetime after both SLO lifetimes.
#   Runs k != LEVELS_FROM_RUN take the levels of that run (its stream-levels.tsv; cut Q8); RS_LATER_FIX_SEP=0 then
#   measures them in the SLO lifetime instead of separate lifetimes.
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/block/ (the block's evidence dir: stream-results.tsv,
# stream-fix.tsv, stream-levels.tsv, <sys>-u<R>/{slo,fix}, <sys>-u<R>-fix/fix, rs-check.txt).
# The block takes and releases the measurement lock itself (owner RECSYS-stream-block).
# usage: runset-rs-main.sh <k> [--dry] [--v N]   (lib.sh)
RUNSET=rs-main WL=recsys
. "$(dirname "$0")/lib.sh"
rs_checks
for s in $RS_SYSTEMS; do case $s in hw|pop) ;; *) die "RS_SYSTEMS are hw, pop (Megalon: run set rs-h1)";; esac; done
MAP=""
for r in $RS_MG_POINTS; do
  [[ " $RS_POINTS " == *" $r "* ]] || die "RS_MG_POINTS rate $r not in RS_POINTS"
  [ -z "$RS_MG_COMPARE_Q" ] || MAP="$MAP $r=$(echo $RS_FIX_LEVELS | tr ' ' ','),$RS_MG_COMPARE_Q"
done
# eval3 (block C): RS_FIX_LEVELS, RS_MG_COMPARE_Q and RS_FIX_FALLBACK_Q all empty = SLO lifetimes only (the 1 q/s
# start step of every SLO search is the L1 step); rs_check.py then expects no fixed windows
FIXSYS=$RS_SYSTEMS
[ -n "$RS_FIX_LEVELS${MAP# }$RS_FIX_FALLBACK_Q" ] || FIXSYS=
SEP=$RS_FIX_SEP LVF=
if [ "$K" != "$LEVELS_FROM_RUN" ] || [ "${LEVELS_SOURCE:-}" = registry ]; then
  [ "$K" = "$LEVELS_FROM_RUN" ] || SEP=$RS_LATER_FIX_SEP
  if levels_dir_of rs-main; then
    LVF=$LEVELS_SRC_DIR/block/stream-levels.tsv; need_files "$LVF"
    [ -z "${LEVELS_SOURCE:-}" ] || plan "levels from $LEVELS_REGISTRY rs-main run $LEVELS_FROM_RUN: $LVF (config_sha256 $LEVELS_SRC_SHA)"
  elif [ $DRY = 1 ]; then plan "levels: run $LEVELS_FROM_RUN of rs-main not accepted yet (a real run would stop here)"
  else die "run $LEVELS_FROM_RUN of rs-main is not accepted (registry.py accept)"; fi
fi
[[ " $RS_SYSTEMS " != *" pop "* ]] || recv_pop_check 2   # receiver of the Popcorn lifetimes (recv-mode.sh)
need_env
lock_free
evidence_dir
rs_env
RSENV+=(SYSTEMS="$RS_SYSTEMS" STREAM_RATES="$RS_POINTS" STREAM_FIX_LEVELS="$RS_FIX_LEVELS" STREAM_FIX_LEVELS_MAP="${MAP# }"
  STREAM_FIX_FALLBACK=$RS_FIX_FALLBACK_Q STREAM_FIX_SEP=$SEP STREAM_LEVELS=$LVF)
BLK=(bash $TREE/experiments/recsys/main-block.sh $E/block)
plan "rates [$RS_POINTS] systems [$RS_SYSTEMS] fix levels [$RS_FIX_LEVELS] map [${MAP# }] fallback ${RS_FIX_FALLBACK_Q:-none} sep $SEP levels ${LVF:-computed in this run}"
plan "block: env ${RSENV[*]} ${BLK[*]}"
plan "then: rs_check.py $E/block --rates '$RS_POINTS' --slo-systems '$RS_SYSTEMS' --fix-systems '$FIXSYS'"
RSPRM=${POP_RECV_MODE:-$RECV_MODE}
[ "$RSPRM" = poll ] || plan "then: recv_check.py $E/block --mode $RSPRM (RS_PROC_CXL_SHM=${RS_PROC_CXL_SHM:-0})"
if [ $DRY = 1 ]; then
  block_dry "missing or not empty" env "${RSENV[@]}" bash $TREE/experiments/recsys/main-block.sh @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add recsys rs-main $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$RS_PLAIN_BUILD" "$RS_MEG_BUILD" "$(dirname "$RS_LOADGEN")"
$REG add recsys rs-main $K "$E" $CSHA started "commit $COMMIT"
log "block start"
env "${RSENV[@]}" "${BLK[@]}" > "$E/block/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/block/sequence.log")"
python3 -I -B $EVD/rs_check.py "$E/block" --rates "$RS_POINTS" --slo-systems "$RS_SYSTEMS" --fix-systems "$FIXSYS" > /dev/null
log "check: $(tail -n 1 "$E/block/rs-check.txt")"
tail -n 1 "$E/block/rs-check.txt" | grep -q "^RSCHECK PASS" || stop "check FAIL (see $E/block/rs-check.txt)"
if [ "$RSPRM" != poll ]; then  # receive mode of every Popcorn lifetime (e.g. recv-sleep.conf; run 2 adaptive)
  python3 -I -B $EVD/recv_check.py "$E/block" --mode "$RSPRM" > /dev/null
  log "recv check: $(tail -n 1 "$E/block/recv-check.txt" 2>/dev/null || echo 'no recv-check.txt')"
  tail -n 1 "$E/block/recv-check.txt" | grep -q "^RECVCHECK PASS" || stop "recv check FAIL (see $E/block/recv-check.txt)"
fi
$REG add recsys rs-main $K "$E" $CSHA measured "$(tail -n 1 "$E/block/rs-check.txt")"
export_run "$TREE/experiments/recsys/export.py" "$E"
log "RUNSET DONE: review $E/block/rs-check.txt, then: ${REGISTRY:+EVAL_REGISTRY=$REGISTRY }python3 $EVD/registry.py accept rs-main $K $E"

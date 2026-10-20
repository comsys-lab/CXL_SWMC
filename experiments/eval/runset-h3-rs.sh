#!/bin/bash
# Run set "h3-rs-n<N>" (H3 on RecSys at N VMs; RUN-H3.md; user H3 design 2026-10-20): experiments/eval/h3-block.sh with
# H3_WL=recsys on the N-VM topology: node 0 = updater (VCPU update threads) of the streaming trace at H3_RS_RATE
# samples/s, nodes 1..N-1 serve (VCPU serving threads each), queries round robin over them (loadgen query_spread=rr);
# per system in H3_SYSTEMS one aggregate SLO search (query p95 <= 100 ms, the BLOCK=stream rules); + the CDF lifetime
# when N = H3_CDF_N and k is in H3_CDF_RUNS. N = 2 (H3_N2_SOURCE=2vm): the rs-main run set of the same k.
# Layout and acceptance as runset-h3-vdb.sh.
# usage: runset-h3-rs.sh <N> <k> [--dry] [--v V]   (evidence <RESULTS_ROOT>/<prefix>-run<k>-h3-rs-n<N>-v<V>)
N=${1:-}; shift || true
[[ $N =~ ^[2-8]$ ]] || { echo "RUNSET STOP: usage runset-h3-rs.sh <N> <k> [--dry] [--v V]"; exit 2; }
RUNSET=h3-rs-n$N WL=recsys CONF_WL=h3-recsys
. "$(dirname "$0")/lib.sh"
[[ " $H3_NODES " == *" $N "* ]] || die "N=$N not in H3_NODES ($H3_NODES)"
[ "$N" != 2 ] || [ "$H3_N2_SOURCE" != 2vm ] || die "N = 2 comes from the rs-main run set of run $K (H3_N2_SOURCE=2vm): export only (RUN-H3.md)"
[ $((H3_TOTAL_VCPU % N)) = 0 ] && [ $((H3_TOTAL_RAM_GB % N)) = 0 ] || die "H3 totals not divisible by N"
VCPU=$((H3_TOTAL_VCPU / N))
[[ " $RS_POINTS " == *" $H3_RS_RATE "* ]] || die "H3_RS_RATE $H3_RS_RATE not in RS_POINTS (no N = 2 point)"
[ "$H3_RS_QUERY_SPREAD" = rr ] || die "H3_RS_QUERY_SPREAD must be rr"
for s in $H3_SYSTEMS; do case $s in hw|pop) ;; mg) die "Megalon in H3 needs Megalon builds with LOGICAL_NODE_NUM = $N (RUN-H3.md)";; *) die "bad H3_SYSTEMS entry $s";; esac; done
CDF=0; [ "$N" = "$H3_CDF_N" ] && [[ " $H3_CDF_RUNS " == *" $K "* ]] && CDF=1
need_files "$RS_PLAIN_BUILD/bin/recsys-server" "$REGION" "$POP_C/p-popcorn-shm.sh" "$RS_INPUTS/MANIFEST.txt" \
  "$EVD/h3-block.sh" "$EVD/h3-cdf.sh"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
( cd "$RS_INPUTS" && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  (updates-day23-0-2M\.smp|queries-day23-89137318-1M\.smp|dist_quantile\.txt)$' MANIFEST.txt) ) \
  || die "RecSys inputs differ from $RS_INPUTS/MANIFEST.txt"
if [ ! -x "$H3_RS_LOADGEN" ]; then
  [ $DRY = 1 ] || die "missing $H3_RS_LOADGEN (recsys-loadgen build with query_spread: RUN-H3.md 'Pending')"
  plan "loadgen $H3_RS_LOADGEN missing (pending build; a real run stops here)"
fi
plan "N=$N vCPU/VM=$VCPU RAM/VM=$((H3_TOTAL_RAM_GB / N)) GB; rate $H3_RS_RATE samples/s; systems [$H3_SYSTEMS]; node 0 $VCPU update threads, nodes 1..$((N - 1)) $VCPU serving threads (serving vCPUs $((VCPU * (N - 1)))); CDF=$CDF"
plan "N = 2 point: rs-main run $K ($(run_dir_of rs-main "$K" || echo 'not accepted yet'))"
need_env
lock_free
evidence_dir
BENV=(H3_WL=recsys H3_N=$N H3_TOTAL_VCPU=$H3_TOTAL_VCPU "SYSTEMS=$H3_SYSTEMS" EVAL_RUN=$K SEED=$((SEED_BASE + K)) REGION=$REGION
  C8=$POP_C K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  CDF=$CDF CDF_S=$H3_CDF_S H3_CDF_PFN_MOD=$H3_CDF_PFN_MOD VM_PLAIN=$RS_VM_PLAIN PLAIN_BUILD=$RS_PLAIN_BUILD LOADGEN=$H3_RS_LOADGEN D=$RS_INPUTS
  RATE=$H3_RS_RATE XT=$RS_XT)
for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!v:-}" ] || BENV+=("$v=${!v}"); done
plan "block: env ${BENV[*]} bash $EVD/h3-block.sh <E>/block"
if [ $DRY = 1 ]; then
  block_dry "evidence-dir check reached" env H3_BLOCK_DRY=1 "${BENV[@]}" bash "$EVD/h3-block.sh" @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add recsys $RUNSET $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$RS_PLAIN_BUILD" "$(dirname "$H3_RS_LOADGEN")"
$REG add recsys $RUNSET $K "$E" $CSHA started "commit $COMMIT N=$N"
log "block start (N=$N, CDF=$CDF)"
env "${BENV[@]}" bash "$EVD/h3-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || stop "block did not finish (see $E/sequence.log, $E/block/block.log)"
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || stop "rollback / cleanup failure lines (manual check)"
[ "$(grep -vc '^#' "$E/block/h3-results.tsv")" = "$(echo $H3_SYSTEMS | wc -w)" ] || stop "h3-results.tsv rows != systems"
$REG add recsys $RUNSET $K "$E" $CSHA measured "$(grep -v '^#' "$E/block/h3-results.tsv" | cut -f2,6,7,10 | tr '\t\n' ' ;' | cut -c1-200)"
export_run "$EVD/export_h3.py" "$E/block"
log "RUNSET DONE: review $E/block/h3-results.tsv and block.log, then: python3 $EVD/registry.py accept $RUNSET $K $E"

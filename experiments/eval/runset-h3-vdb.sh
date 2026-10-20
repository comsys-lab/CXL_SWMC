#!/bin/bash
# Run set "h3-vdb-n<N>" (H3 on the vector DB at N VMs; RUN-H3.md; user H3 design 2026-10-20): experiments/eval/
# h3-block.sh with H3_WL=vdb on the N-VM topology (cxl_vm0..N-1, 192.168.122.100..), per system in H3_SYSTEMS one
# aggregate SLO search at the op mix H3_VDB_POINT (one writer per VM, VCPU-1 search threads, VCPU = H3_TOTAL_VCPU / N),
# + the CDF lifetime when N = H3_CDF_N and k is in H3_CDF_RUNS. N = 2 (H3_N2_SOURCE=2vm) is not measured here: its
# point is the vdb run set of the same k (export: RUN-H3.md "N = 2").
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/sequence.log, E/block/ (h3-block.sh evidence: h3-results.tsv,
# <sys>-n<N>/, cdf/, block.log). Acceptance: review E/block/h3-results.tsv + block.log (BLOCK DONE, no ROLLBACK FAIL),
# then registry.py accept h3-vdb-n<N> <k> <E>.
# usage: runset-h3-vdb.sh <N> <k> [--dry] [--v V]   (lib.sh; evidence <RESULTS_ROOT>/<prefix>-run<k>-h3-vdb-n<N>-v<V>)
N=${1:-}; shift || true
[[ $N =~ ^[2-8]$ ]] || { echo "RUNSET STOP: usage runset-h3-vdb.sh <N> <k> [--dry] [--v V]"; exit 2; }
RUNSET=h3-vdb-n$N WL=vdb CONF_WL=h3-vdb
. "$(dirname "$0")/lib.sh"
H=$TREE/experiments/h1
[[ " $H3_NODES " == *" $N "* ]] || die "N=$N not in H3_NODES ($H3_NODES)"
[ "$N" != 2 ] || [ "$H3_N2_SOURCE" != 2vm ] || die "N = 2 comes from the vdb run set of run $K (H3_N2_SOURCE=2vm): export only (RUN-H3.md)"
[ $((H3_TOTAL_VCPU % N)) = 0 ] && [ $((H3_TOTAL_RAM_GB % N)) = 0 ] || die "H3 totals not divisible by N"
VCPU=$((H3_TOTAL_VCPU / N))
[[ " $VDB_POINTS " == *" $H3_VDB_POINT "* ]] || die "H3_VDB_POINT $H3_VDB_POINT not in VDB_POINTS (no N = 2 point)"
row=$(awk -F'\t' -v m="$H3_VDB_POINT" '!/^#/ && $1 == "vdb" && $2 == m' "$H/h1-plan.tsv")
U=$(echo "$row" | cut -f3 | sed -n 's/^U=\([0-9]*\)$/\1/p'); [ -n "$U" ] || die "no U for $H3_VDB_POINT in h1-plan.tsv"
[ "$VDB_DATASET" = 28m-x ] || die "H3 uses the 28m-x dataset (VDB_DATASET)"
for s in $H3_SYSTEMS; do case $s in hw|pop) ;; mg) die "Megalon in H3 needs Megalon builds with LOGICAL_NODE_NUM = $N (RUN-H3.md)";; *) die "bad H3_SYSTEMS entry $s";; esac; done
CDF=0; [ "$N" = "$H3_CDF_N" ] && [[ " $H3_CDF_RUNS " == *" $K "* ]] && CDF=1
WRITES=$H3_VDB_WRITES_DIR/writes-a27m-b3400k-u3400k-vms$N.bin
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" "$POP_C/p-popcorn-shm.sh" \
  "$VDB_X_DATA/pool_b.fbin" "$EVD/h3-block.sh" "$EVD/h3-cdf.sh"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
( cd "$H" && . "$EVD/pins-vdb.sh" && echo "$PIN_SHA256" | sha256sum --quiet -c - ) || die "eval pins (pins-vdb.sh: builds, data, region) do not verify"
WOK=1
if [ ! -f "$WRITES" ]; then
  WOK=0; [ $DRY = 1 ] || die "missing $WRITES (generate it: RUN-H3.md 'Pending')"
  plan "writes file $WRITES missing (pending generation; a real run stops here)"
fi
plan "N=$N vCPU/VM=$VCPU RAM/VM=$((H3_TOTAL_RAM_GB / N)) GB; mix $H3_VDB_POINT (U=$U); systems [$H3_SYSTEMS]; threads $((VCPU - 1)) search + 1 writer; CDF=$CDF (H3_CDF_N=$H3_CDF_N runs [$H3_CDF_RUNS], ${H3_CDF_S}s)"
plan "N = 2 point: vdb run $K ($(run_dir_of vdb "$K" || echo 'not accepted yet'))"
need_env
lock_free
evidence_dir
BENV=(H3_WL=vdb H3_N=$N H3_TOTAL_VCPU=$H3_TOTAL_VCPU "SYSTEMS=$H3_SYSTEMS" EVAL_RUN=$K SEED=$((SEED_BASE + K)) REGION=$REGION
  C8=$POP_C K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  CDF=$CDF CDF_S=$H3_CDF_S H3_CDF_PFN_MOD=$H3_CDF_PFN_MOD VPLAIN=$VDB_VPLAIN PLAIN_BUILD=$VDB_PLAIN_BUILD LOADGEN=$VDB_LOADGEN_BUILD/loadgen
  X_DATA=$VDB_X_DATA X_WRITES=$WRITES X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$VDB_X_MAXD
  X_INIT_CAP=$VDB_X_INIT_CAP U=$U)
for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!v:-}" ] || BENV+=("$v=${!v}"); done
plan "block: env ${BENV[*]} bash $EVD/h3-block.sh <E>/block"
if [ $DRY = 1 ]; then
  block_dry "evidence-dir check reached" env H3_BLOCK_DRY=1 "${BENV[@]}" bash "$EVD/h3-block.sh" @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add vdb $RUNSET $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$VDB_PLAIN_BUILD" "$VDB_LOADGEN_BUILD"
echo "writes $(sha256sum "$WRITES")" >> "$E/eval-manifest.txt"
$REG add vdb $RUNSET $K "$E" $CSHA started "commit $COMMIT N=$N"
log "block start (N=$N, CDF=$CDF)"
env "${BENV[@]}" bash "$EVD/h3-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || stop "block did not finish (see $E/sequence.log, $E/block/block.log)"
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || stop "rollback / cleanup failure lines (manual check)"
[ "$(grep -vc '^#' "$E/block/h3-results.tsv")" = "$(echo $H3_SYSTEMS | wc -w)" ] || stop "h3-results.tsv rows != systems"
$REG add vdb $RUNSET $K "$E" $CSHA measured "$(grep -v '^#' "$E/block/h3-results.tsv" | cut -f2,6,7 | tr '\t\n' ' ;' | cut -c1-200)"
export_run "$EVD/export_h3.py" "$E/block"
log "RUNSET DONE: review $E/block/h3-results.tsv and block.log, then: python3 $EVD/registry.py accept $RUNSET $K $E"

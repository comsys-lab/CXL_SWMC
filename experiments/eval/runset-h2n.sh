#!/bin/bash
# Run set "h2n-n<N>" (new H2 = vector DB VM-count scaling; RUN-H2N.md; user decisions 2026-10-20 22:3x): experiments/
# eval/h2n-block.sh on N VMs of the VM8 topology (cxl_vm0..N-1, 192.168.122.100.., EVERY VM 4 vCPU / 24 GB), one
# aggregate SLO search per (system, mix), lifetimes in the order systems H2N_SYSTEMS (outer) x mixes H2N_POINTS (inner).
# Config: EVAL_CONF=experiments/eval/h2n.conf (RUNSETS h2n-n2 h2n-n4 h2n-n8; eval.conf refuses: no H2N_* keys).
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/sequence.log, E/block/ (h2n-block.sh evidence: h2n-results.tsv,
# <sys>-<mix>-n<N>/, cxlbw/, block.log). Acceptance: review E/block/h2n-results.tsv + block.log (BLOCK DONE, no
# ROLLBACK FAIL), then EVAL_REGISTRY=<REGISTRY> registry.py accept h2n-n<N> <k> <E>.
# usage: runset-h2n.sh <N> <k> [--dry] [--v V] [--from <sys>:<mix>] [--only "<sys>:<mix> ..."]
#   --from  resume: start the lifetime list at this lifetime (a stopped block's finished lifetimes stay in its own,
#           immutable evidence dir; export_h2n.py takes several evidence dirs per N, later dirs win per lifetime)
#   --only  run exactly these lifetimes (in the given order), e.g. a single re-run; exclusive with --from
N=${1:-}; shift || true
[[ $N =~ ^[2-8]$ ]] || { echo "RUNSET STOP: usage runset-h2n.sh <N> <k> [--dry] [--v V] [--from sys:mix] [--only 'sys:mix ...']"; exit 2; }
K_ARG=${1:-}; shift || true
FROM= ONLY= REST=()
while [ $# -gt 0 ]; do
  case $1 in --from) FROM=${2:-}; shift 2;; --only) ONLY=${2:-}; shift 2;; *) REST+=("$1"); shift;; esac
done
set -- "$K_ARG" "${REST[@]}"
RUNSET=h2n-n$N WL=vdb CONF_WL=h2n
. "$(dirname "$0")/lib.sh"
H=$TREE/experiments/h1
[ -n "${H2N_NODES:-}" ] || die "EVAL_CONF has no H2N_* keys (use EVAL_CONF=$EVD/h2n.conf)"
[[ " $H2N_NODES " == *" $N "* ]] || die "N=$N not in H2N_NODES ($H2N_NODES)"
[ "$H2N_TOPO" = 8 ] && [ "$VCPUS_PER_VM" = 4 ] && [ "$H2N_RAM_GB" = 24 ] || die "h2n needs the VM8 topology with 4 vCPU / 24 GB per VM"
[ "$VDB_DATASET" = 28m-x ] || die "h2n uses the 28m-x dataset (VDB_DATASET)"
[ "$VDB_SLO_PCT:$VDB_SLO_MS" = 99:100 ] || die "VDB SLO is search p99 <= 100 ms (the SLO part arguments are fixed)"
[ "$VDB_MG_CAPACITY" = h1 ] || die "h2n Megalon capacity is VDB_MG_CAPACITY=h1"
[ -n "$FROM" ] && [ -n "$ONLY" ] && die "--from and --only are exclusive"
# lifetime list: systems outer, mixes inner
ALL=()
for s in $H2N_SYSTEMS; do
  case $s in hw|pop|mg|mgoff) ;; *) die "bad H2N_SYSTEMS entry $s";; esac
  for m in $H2N_POINTS; do
    row=$(awk -F'\t' -v m="$m" '!/^#/ && $1 == "vdb" && $2 == m' "$H/h1-plan.tsv")
    [ "$(echo "$row" | cut -f3)" = "U=${m#u}" ] || die "mix $m: h1-plan.tsv has no vdb row with U=${m#u}"
    ALL+=("$s:$m")
  done
done
LIVES=("${ALL[@]}")
if [ -n "$FROM" ]; then
  i=-1; for j in "${!ALL[@]}"; do [ "${ALL[$j]}" = "$FROM" ] && i=$j; done
  [ $i -ge 0 ] || die "--from $FROM is not one of [${ALL[*]}]"
  LIVES=("${ALL[@]:$i}")
elif [ -n "$ONLY" ]; then
  LIVES=()
  for l in $ONLY; do [[ " ${ALL[*]} " == *" $l "* ]] || die "--only $l is not one of [${ALL[*]}]"; LIVES+=("$l"); done
fi
HASMG=0; for l in "${LIVES[@]}"; do case ${l%%:*} in mg|mgoff) HASMG=1;; esac; done
v() { local x=H2N_$1_N$N; echo "${!x:-}"; }
WRITES=$(v WRITES) MAXD=$(v MAXD)
[ -n "$WRITES" ] && [[ $MAXD =~ ^[1-9][0-9]*$ ]] || die "H2N_WRITES_N$N / H2N_MAXD_N$N missing"
MGB=$(v MG_BUILD) MGV=$(v VMEG) MGC=$(v MG_CFG) MGL=$(v MG_LIB) MGD=$(v MG_MAXD)
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" "$POP_C/p-popcorn-shm.sh" \
  "$VDB_X_DATA/pool_b.fbin" "$WRITES" "$EVD/h2n-block.sh" "$EVD/h2n_layout.py"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
( cd "$H" && . "$EVD/pins-vdb.sh" && echo "$PIN_SHA256" | sha256sum --quiet -c - ) || die "eval pins (pins-vdb.sh: builds, data, region, N = 2 Megalon) do not verify"
if [ $HASMG = 1 ]; then
  MGPEND=
  for x in "$MGB" "$MGV" "$MGC" "$MGL"; do [[ $x == *PLACEHOLDER* ]] && MGPEND="$MGPEND $x"; done
  if [ -n "$MGPEND" ]; then
    [ $DRY = 1 ] || die "Megalon inputs for N = $N are placeholders ($MGPEND): fill H2N_MG_*_N$N in $EVAL_CONF (megalon-n agent) or run without mg (--only)"
    plan "Megalon N = $N inputs pending:$MGPEND (a real run stops here)"
  fi
  [[ $MGD =~ ^[1-9][0-9]*$ ]] || die "H2N_MG_MAXD_N$N missing"
fi
plan "N=$N vCPU/VM=$VCPUS_PER_VM RAM/VM=${H2N_RAM_GB} GB; threads $VDB_SEARCH_THREADS search + 1 writer; recv_mode $RECV_MODE"
plan "lifetimes (${#LIVES[@]}): ${LIVES[*]}${FROM:+ (resume from $FROM)}${ONLY:+ (only)}"
plan "writes $WRITES; max_deletes/node $MAXD$([ $HASMG = 1 ] && echo "; Megalon build $MGB lib $MGL cfg $MGC guest $MGV max_deletes/node $MGD")"
need_env
lock_free
evidence_dir
BENV=(H2N_N=$N H2N_VCPU=$VCPUS_PER_VM "H2N_LIFETIMES=${LIVES[*]}" EVAL_RUN=$K SEED=$((SEED_BASE + K)) REGION=$REGION
  C8=$POP_C K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  VPLAIN=$VDB_VPLAIN PLAIN_BUILD=$VDB_PLAIN_BUILD LOADGEN=$VDB_LOADGEN_BUILD/loadgen X_DATA=$VDB_X_DATA X_WRITES=$WRITES
  X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$MAXD X_INIT_CAP=$VDB_X_INIT_CAP
  "H2N_SLO_PART=$H2N_SLO_PART" H2N_OPCOH_STRICT=$H2N_OPCOH_STRICT H2N_CXLBW=$H2N_CXLBW)
[ $HASMG = 0 ] || BENV+=(MEG_BUILD=$MGB VMEG=$MGV MEG_CFG=$MGC MEG_LIB=$MGL MG_MAXD=$MGD)
for x in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!x:-}" ] || BENV+=("$x=${!x}"); done
plan "block: env ${BENV[*]} bash $EVD/h2n-block.sh <E>/block"
if [ $DRY = 1 ]; then
  block_dry "evidence-dir check reached" env H2N_BLOCK_DRY=1 "${BENV[@]}" bash "$EVD/h2n-block.sh" @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add vdb $RUNSET $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$VDB_PLAIN_BUILD" "$VDB_LOADGEN_BUILD" $([ $HASMG = 1 ] && echo "$MGB")
{ echo "writes $(sha256sum "$WRITES")"; echo "lifetimes=${LIVES[*]} from=${FROM:-} only=${ONLY:-}"
  python3 -I -B "$EVD/h2n_layout.py" --check "$N" "$MAXD"; } >> "$E/eval-manifest.txt"
$REG add vdb $RUNSET $K "$E" $CSHA started "commit $COMMIT N=$N lifetimes ${#LIVES[@]}${FROM:+ from $FROM}"
log "block start (N=$N, ${#LIVES[@]} lifetimes)"
env "${BENV[@]}" bash "$EVD/h2n-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || stop "block did not finish (see $E/sequence.log, $E/block/block.log)"
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || stop "rollback / cleanup failure lines (manual check)"
[ "$(grep -vc '^#' "$E/block/h2n-results.tsv")" = "${#LIVES[@]}" ] || stop "h2n-results.tsv rows != lifetimes"
$REG add vdb $RUNSET $K "$E" $CSHA measured "$(grep -v '^#' "$E/block/h2n-results.tsv" | cut -f1,7,9 | tr '\t\n' ' ;' | cut -c1-200)"
out=$DERIVED_ROOT/vdb/$RUNSET/run$K
mkdir -p "$out" && python3 -I -B "$EVD/export_h2n.py" --run "$K" --nodes "$N" --config-sha256 "$CSHA" --out "$out" "$E/block" > "$out/export.log" 2>&1 \
  && log "export: $out" || log "RUNSET NOTE: export failed (see $out/export.log; the run itself is unaffected)"
log "RUNSET DONE: review $E/block/h2n-results.tsv and block.log, then: EVAL_REGISTRY=${REGISTRY:-} python3 $EVD/registry.py accept $RUNSET $K $E"

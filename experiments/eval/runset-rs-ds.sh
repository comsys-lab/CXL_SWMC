#!/bin/bash
# Run set "rs-ds" (eval3 block C, reports/experiments/de-stijl-evaluation-run1-schedule.md §2 RecSys): De Stijl v2 RecSys
# streaming SLO lifetimes at RS_POINTS samples/s, the same block, threads, SLO, ramp and seeds as run set rs-main
# (experiments/recsys/main-block.sh BLOCK=stream with EVAL_RUN, SYSTEMS=ds), on the De Stijl guest kernel (both VMs;
# deployed and rolled back by the chain, never by this driver). SLO lifetimes only: the 1 q/s start step of every SLO
# search is the L1 step (hw / pop levels do not apply on another kernel).
# Conf keys (all RS_*, so they are in config_sha256(recsys); unset before lib.sh, never inherited from the environment):
#   RS_DS_C           De Stijl bundle dir (p-destijl-shm.sh, packet.sha256, tools/cxl_region.yaml)
#   RS_DS_BUNDLE_SHA  sha256 of RS_DS_C/packet.sha256
#   RS_DS_K           guest release (-ds-destijl-<n>)
#   RS_DS_GT          guest tools dir of that deploy (cxl_region.yaml compared with RS_DS_VM_PLAIN's at every load)
#   RS_DS_REGION      region config of every ds lifetime (= RS_DS_C/tools/cxl_region.yaml; config/cxl_region-destijl.yaml)
#   RS_DS_VM_PLAIN    guest install dir of RS_PLAIN_BUILD with RS_DS_REGION (rs14ds: workspaces/eval3/recsys-ds/rs14ds-install.sh)
#   RS_DS_T_US        staleness bound T in us (servers: ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=<T>; 0 = synchronous).
#                     The literal @MAIN_T@ is the unresolved placeholder: a dry start plans with T = 0 and says so, a
#                     real run stops. T > 0 needs a libdestijl server (RS_PLAIN_BUILD: de_stijl_set_staleness).
#   RS_DS_RECV_EXTRA  optional "idle_sleep_us=<n> idle_spin_us=<n> fault_poll=<0|1>" (any subset; fault_poll: build >= 9,
#                     run 2 = 0): De Stijl receiver parameters (sleep tier / fault-entry polling),
#                     appended to the cxl_shm load of every ds lifetime and checked after the enable (main-block.sh
#                     DS_RECV_EXTRA; user 2026-11-02 17:0x: 200 / 50 for every ds cell from now on). Empty = defaults.
#   RS_DS_REPLICA_MODE  optional off | all (default off = no replica step, plans unchanged; damon: refused, the RecSys
#                     harness has no DAMON control): all = De Stijl replica_mode all on both VMs for every ds lifetime
#                     (main-block.sh DS_REPLICA_MODE, experiments/recsys/ds-replica.sh; run 2 widening 2026-11-06,
#                     T = 1000 ms accuracy + staleness). Needs a bundle built with CONFIG_SWMC_DE_STIJL_REPL=y.
#   RS_DS_REPLICA_POOL_BYTES  pool cap with all (required, >= 1 GiB): per VM pool = min(cap, MemAvailable - 4 GiB)
#                     at each lifetime start; recv_check.py then runs with --replica-mode all (pool full = FAIL)
#   RS_DS_WAIT_ASSIST optional 0 | 1 (empty = no step, plans unchanged): De Stijl build >= 13 kernel switch
#                     /sys/kernel/swmc/destijl/wait_assist, written on both VMs after the enable of every ds lifetime,
#                     read back after the enable and before the teardown, 0 after the teardown (main-block.sh
#                     DS_WAIT_ASSIST; block/ds-wait-assist-<name>.txt). Needs a build >= 13 bundle (RS_DS_K -ds-destijl-<n>).
#                     Build 13's extra ds.wa_* status keys / sys.swmc.destijl.wa_* columns are ignored by recv_check.py and
#                     breakdown.py (checked with experiments/eval/wa_cols_fixture.py)
# After the block: rs_check.py (SLO ds at every rate, no fixed windows) and recv_check.py --mode RECV_MODE (De Stijl
# lifetime rules: protocol destijl, tx_timeout / protocol_error deltas 0, per-step sys.swmc.destijl.* columns).
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/block/ (stream-results.tsv, ds-u<R>/slo, dsshm-ds-u<R>/, rs-check.txt,
# recv-check.txt). The block takes and releases the measurement lock itself.
# usage: runset-rs-ds.sh <k> [--dry] [--v N]   (lib.sh)
RUNSET=rs-ds WL=recsys
unset RS_DS_C RS_DS_BUNDLE_SHA RS_DS_K RS_DS_GT RS_DS_REGION RS_DS_VM_PLAIN RS_DS_T_US RS_DS_RECV_EXTRA \
  RS_DS_REPLICA_MODE RS_DS_REPLICA_POOL_BYTES DS_REPLICA_MODE DS_REPLICA_POOL_BYTES RS_DS_WAIT_ASSIST DS_WAIT_ASSIST
. "$(dirname "$0")/lib.sh"
RSRX=${RS_DS_RECV_EXTRA:-}
[[ $RSRX =~ ^(((idle_sleep_us|idle_spin_us)=[0-9]+|fault_poll=[01])( |$))*$ ]] || die "bad RS_DS_RECV_EXTRA ($RSRX: 'idle_sleep_us=<n> idle_spin_us=<n> fault_poll=<0|1>')"
rs_checks
for x in RS_DS_C RS_DS_BUNDLE_SHA RS_DS_K RS_DS_GT RS_DS_REGION RS_DS_VM_PLAIN RS_DS_T_US; do
  [ -n "${!x:-}" ] || die "rs-ds needs $x in $EVAL_CONF"
done
[[ $RS_DS_K == *-ds-destijl-* ]] || die "RS_DS_K=$RS_DS_K is not a De Stijl release (-ds-destijl-<n>)"
[[ $RS_DS_GT =~ ^/home/comsys/[A-Za-z0-9._-]+$ && $RS_DS_VM_PLAIN =~ ^/home/comsys/[A-Za-z0-9._-]+$ ]] || die "bad RS_DS_GT / RS_DS_VM_PLAIN"
[ "$RS_DS_VM_PLAIN" != "$RS_VM_PLAIN" ] || die "RS_DS_VM_PLAIN must be its own install (De Stijl region), not RS_VM_PLAIN"
need_files "$RS_DS_C/tools/destijl.env"
why=$(recv_rules ds "$RECV_MODE" "$RS_DS_C" 2) || die "De Stijl receiver: $why"   # recv-mode.sh (adaptive: build >= 9 bundle)
T=$RS_DS_T_US
if [ "$T" = @MAIN_T@ ]; then
  [ $DRY = 1 ] || die "RS_DS_T_US is the unresolved placeholder @MAIN_T@ (resolve it into a conf copy first)"
  plan "RS_DS_T_US=@MAIN_T@ unresolved: dry start plans with T = 0 (a real run stops here)"; T=0
fi
[[ $T =~ ^(0|[1-9][0-9]*)$ ]] || die "bad RS_DS_T_US ($T: integer us, 0 = synchronous)"
need_files "$RS_DS_C/p-destijl-shm.sh" "$RS_DS_C/packet.sha256" "$RS_DS_C/tools/cxl_region.yaml" "$RS_DS_REGION"
[ "$(sha256sum < "$RS_DS_C/packet.sha256" | cut -c1-64)" = "$RS_DS_BUNDLE_SHA" ] || die "De Stijl bundle packet.sha256 != RS_DS_BUNDLE_SHA"
(cd "$RS_DS_C" && sha256sum -c --quiet packet.sha256) || die "De Stijl bundle files differ from its packet.sha256"
cmp -s "$RS_DS_REGION" "$RS_DS_C/tools/cxl_region.yaml" || die "RS_DS_REGION differs from the De Stijl bundle's region config"
[ "$T" = 0 ] || grep -qa de_stijl_set_staleness "$RS_PLAIN_BUILD/bin/recsys-server" || die "RS_DS_T_US=$T needs a libdestijl recsys-server ($RS_PLAIN_BUILD has none)"
RSREPL=${RS_DS_REPLICA_MODE:-off} RSRPOOL=${RS_DS_REPLICA_POOL_BYTES:-}
case $RSREPL in
  off) [ -z "$RSRPOOL" ] || die "RS_DS_REPLICA_POOL_BYTES without RS_DS_REPLICA_MODE=all";;
  all) [[ $RSRPOOL =~ ^[1-9][0-9]*$ ]] && [ "$RSRPOOL" -ge 1073741824 ] || die "RS_DS_REPLICA_MODE=all needs RS_DS_REPLICA_POOL_BYTES >= 1073741824 (got '$RSRPOOL')"
       grep -qx "CONFIG_SWMC_DE_STIJL_REPL=y" "$RS_DS_C/kernel.config" || die "RS_DS_REPLICA_MODE=all: $RS_DS_C/kernel.config lacks CONFIG_SWMC_DE_STIJL_REPL=y"
       grep -q "^replica-mode)" "$RS_DS_C/tools/p-destijl-guest.sh" || die "RS_DS_REPLICA_MODE=all: the bundle's p-destijl-guest.sh has no replica-mode";;
  damon) die "RS_DS_REPLICA_MODE=damon is not supported by the RecSys harness (no DAMON control; vector DB h2n-block.sh only)";;
  *) die "bad RS_DS_REPLICA_MODE ($RSREPL: off | all)";;
esac
plan "De Stijl: bundle $RS_DS_C release $RS_DS_K guest tools $RS_DS_GT region $RS_DS_REGION guest dir $RS_DS_VM_PLAIN T=$T us recv_mode $RECV_MODE"
[ "$RSREPL" = off ] || plan "De Stijl replica_mode $RSREPL, pool cap $RSRPOOL bytes (per VM min(cap, MemAvailable - 4 GiB) at each lifetime start; back to off after every ds lifetime); recv_check.py --replica-mode $RSREPL"
RCX=(); [ "$RSREPL" = off ] || RCX=(--replica-mode "$RSREPL")
RSWA=${RS_DS_WAIT_ASSIST:-}
if [ -n "$RSWA" ]; then
  [[ $RSWA =~ ^[01]$ ]] || die "bad RS_DS_WAIT_ASSIST ($RSWA: 0 | 1)"
  _dsn=${RS_DS_K##*-ds-destijl-}
  [[ $_dsn =~ ^[0-9]+$ ]] && [ "$_dsn" -ge 13 ] || die "RS_DS_WAIT_ASSIST needs De Stijl build >= 13 (RS_DS_K=$RS_DS_K)"
  plan "De Stijl wait assist: /sys/kernel/swmc/destijl/wait_assist=$RSWA on both VMs for every ds lifetime (after the enable, read back; 0 after the teardown)"
fi
need_env
lock_free
evidence_dir
rs_env   # incl. the optional conf key RS_SLO_TOL -> STREAM_SLO_TOL (SLO-search loadgen --tol; lib.sh)
RSENV+=(REGION=$RS_DS_REGION VM_PLAIN=$RS_DS_VM_PLAIN SYSTEMS=ds STREAM_RATES="$RS_POINTS" STREAM_FIX_LEVELS= STREAM_FIX_SEP=1
  DS_C=$RS_DS_C DS_BUNDLE_SHA=$RS_DS_BUNDLE_SHA DS_K=$RS_DS_K DS_GT=$RS_DS_GT RS_DS_T_US=$T)   # later assignments win in env
[ -z "$RSRX" ] || { RSENV+=("DS_RECV_EXTRA=$RSRX"); plan "De Stijl receiver parameters: $RSRX (cxl_shm load, checked after the enable)"; }
[ "$RSREPL" = off ] || RSENV+=("DS_REPLICA_MODE=$RSREPL" "DS_REPLICA_POOL_BYTES=$RSRPOOL")
[ -z "$RSWA" ] || RSENV+=("DS_WAIT_ASSIST=$RSWA")
BLK=(bash $TREE/experiments/recsys/main-block.sh $E/block)
plan "rates [$RS_POINTS] system ds, SLO lifetimes only"
plan "block: env ${RSENV[*]} ${BLK[*]}"
rs_auc_args ds   # run-2 fixed-rate AUC lifetimes (RS_AUC_Q; RS_AUC_ONLY=1: no SLO lifetime)
plan "then: rs_check.py $E/block --rates '$RS_POINTS' --slo-systems '$SLOSYS' --fix-systems '' --auc-systems '$AUCSYS' --auc-rates '$AUCRATES'; recv_check.py $E/block --mode $RECV_MODE${RCX[*]:+ ${RCX[*]}}"
if [ $DRY = 1 ]; then
  block_dry "missing or not empty" env "${RSENV[@]}" bash $TREE/experiments/recsys/main-block.sh @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add recsys rs-ds $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$RS_PLAIN_BUILD" "$(dirname "$RS_LOADGEN")"
echo "destijl bundle $RS_DS_C packet_sha256=$RS_DS_BUNDLE_SHA release=$RS_DS_K gt=$RS_DS_GT region_sha256=$(sha256sum < "$RS_DS_REGION" | cut -c1-64) guest_dir=$RS_DS_VM_PLAIN t_us=$T" >> "$E/eval-manifest.txt"
[ "$RSREPL" = off ] || echo "destijl replica_mode=$RSREPL replica_pool_cap_bytes=$RSRPOOL (per VM pool: block/ds-replica-pool-<name>-vm<i>)" >> "$E/eval-manifest.txt"
[ -z "$RSWA" ] || echo "destijl wait_assist=$RSWA (both VMs, every ds lifetime; readbacks: block/ds-wait-assist-<name>.txt)" >> "$E/eval-manifest.txt"
$REG add recsys rs-ds $K "$E" $CSHA started "commit $COMMIT T=$T us"
log "block start (T = $T us)"
env "${RSENV[@]}" "${BLK[@]}" > "$E/block/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/block/sequence.log")"
python3 -I -B $EVD/rs_check.py "$E/block" --rates "$RS_POINTS" --slo-systems "$SLOSYS" --fix-systems "" --auc-systems "$AUCSYS" --auc-rates "$AUCRATES" > /dev/null
log "check: $(tail -n 1 "$E/block/rs-check.txt")"
tail -n 1 "$E/block/rs-check.txt" | grep -q "^RSCHECK PASS" || stop "check FAIL (see $E/block/rs-check.txt)"
python3 -I -B $EVD/recv_check.py "$E/block" --mode "$RECV_MODE" "${RCX[@]}" > /dev/null
log "recv check: $(tail -n 1 "$E/block/recv-check.txt" 2>/dev/null || echo 'no recv-check.txt')"
tail -n 1 "$E/block/recv-check.txt" | grep -q "^RECVCHECK PASS" || stop "recv check FAIL (see $E/block/recv-check.txt)"
$REG add recsys rs-ds $K "$E" $CSHA measured "$(tail -n 1 "$E/block/rs-check.txt") T=$T us"
export_run "$TREE/experiments/recsys/export.py" "$E"
log "RUNSET DONE: review $E/block/rs-check.txt and recv-check.txt, then: ${REGISTRY:+EVAL_REGISTRY=$REGISTRY }python3 $EVD/registry.py accept rs-ds $K $E"

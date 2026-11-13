#!/bin/bash
# Block driver of experiment vector-db-staleness-recall (approved 2026-11-13; reports/experiments/vector-db-staleness-
# recall.md; workloads/vectordb/DESIGN.md §20). ONE All-HWcc server lifetime on cxl_vm0 (writer node: every update,
# --writer-threads 4, no searches) + cxl_vm1 (search node: every search) with the run-2 hw cell's server, image, region,
# guest install and checks: experiments/eval/h2n-block.sh, fixed-window lifetime hw:u0 (keys H2N_PLAIN_SERVER_EXTRA,
# H2N_WRITES_TARGETS, H2N_LG_STREAMS, H2N_FIXED_UPDATE, H2N_FIXED_SKIP_CMD), config experiments/eval/vector-db-staleness-
# recall.conf (lib.sh: live-tree / clean-tree / lock / measurement-env rules of every run-set driver).
# Loadgen (builds/vdb-loadgen/13): search groups STALE_QUERY_RATE/s to vm1, each = len(STALE_MS) requests
# (--opt stale_ms, copy i at snapshot ref_w(t - T_i)), update stream --fixed update=R (all to vm0, writes file inputs/6).
# usage: staleness-block.sh pilot <evidence dir> [--dry-run]
#        staleness-block.sh measure <R updates/s> <evidence dir> [--dry-run]
#   evidence dir: recovery/vector-db-staleness-recall-<part>-v<N> (absolute or relative to the project root; must not
#   exist). Real runs: from the live tree CXL_SWMC after the merge, PRETOUCH_DIR / MEASURE_ENV_DIR / MEASURE_PART_DIR set
#   (as for runset-h2n.sh), launched with setsid nohup (> log 2>&1 &).
# pilot   parts p<R> for R in STALE_PILOT_RATES (1000 2000 3000 4000 6000 8000), in that order: STALE_PILOT_WARMUP_S
#         (15) s at R + STALE_PILOT_MEASURE_S (60) s measured each, same search load as measure; a part runs only while
#         every earlier step was sustained (staleness-pilot-skip.sh: urate_check.py of the previous part). Budget
#         asserted: sum(R) x (warmup + window) <= STALE_UPDATE_BUDGET (1,835,008 deletes per lifetime). Result (Host,
#         after the block): <E>/analysis/pilot.tsv + "PILOT RESULT highest_clean_rate=<R|none>" (the highest step whose
#         urate_check.py verdict is valid, every lower step valid too).
# measure part m: STALE_MEASURE_WARMUP_S (25 = 15 s warmup + 10 s lookback) + W measured, W = min(STALE_MEASURE_S (600),
#         floor(STALE_UPDATE_BUDGET / R) - 25 - STALE_MARGIN_S (10)) (user 2026-11-13: R 4000 -> 423 s, 6000 -> 270 s,
#         8000 -> 194 s); R must be one of STALE_PILOT_RATES. Then on the Host (nice 19, node 1):
#         staleness_recall.py --check -> <E>/analysis/steps.csv (+ copy in DERIVED_ROOT/<evidence name>/).
# --dry-run: every Host check (pins, writes file equivalence, budgets, the block's own dry check H2N_BLOCK_DRY=1), then
#         prints every command the block would run on the Host and on the VMs (ssh / scp) in order, and exits 0 before
#         the lock; nothing is written.
set -uo pipefail
XV=$(cd "$(dirname "$0")" && pwd); EVD=$(cd "$XV/../eval" && pwd)
U="usage: staleness-block.sh pilot <evidence dir> [--dry-run] | staleness-block.sh measure <R> <evidence dir> [--dry-run]"
SPART=${1:-}; shift || true
case $SPART in
  pilot) ;;
  measure) RATE=${1:-}; shift || true; [[ $RATE =~ ^[1-9][0-9]*$ ]] || { echo "STALE STOP: $U"; exit 2; };;
  *) echo "STALE STOP: $U"; exit 2;;
esac
EARG=${1:-}; shift || true
DRYRUN=0; [ "${1:-}" = --dry-run ] && { DRYRUN=1; shift; }
[ -n "$EARG" ] && [ $# = 0 ] || { echo "STALE STOP: $U"; exit 2; }
export EVAL_CONF=${EVAL_CONF:-$EVD/vector-db-staleness-recall.conf}
RUNSET=vector-db-staleness-recall WL=vdb CONF_WL=h2n
if [ $DRYRUN = 1 ]; then set -- 1 --dry; else set -- 1; fi
. "$EVD/lib.sh"   # conf keys, P, TREE, die/plan, need_env, lock_free, manifest, DRY
# ---- evidence dir
case $EARG in /*) E=$EARG;; *) E=$P/$EARG;; esac
E=${E%/}
EN=${E##*/}
[ "${E%/*}" = "$P/recovery" ] && [[ $EN =~ ^vector-db-staleness-recall-$SPART-v[1-9][0-9]*$ ]] \
  || die "evidence dir must be $P/recovery/vector-db-staleness-recall-$SPART-v<N> (got $E)"
[ ! -e "$E" ] || die "$E exists (evidence dirs are immutable; bump v<N>)"
plan "part $SPART${RATE:+ R=$RATE}, evidence dir $E (absent: OK)"
# ---- conf values
for x in STALE_MS STALE_SEARCH_TARGET STALE_QUERY_RATE STALE_PILOT_RATES STALE_PILOT_WARMUP_S STALE_PILOT_MEASURE_S \
  STALE_MEASURE_WARMUP_S STALE_MEASURE_S STALE_MARGIN_S STALE_DRAIN_S STALE_UPDATE_BUDGET STALE_TOPK STALE_TOPK_SHA256 \
  STALE_SOURCE_WRITES H2N_PLAIN_SERVER_EXTRA H2N_WRITES_TARGETS; do [ -n "${!x:-}" ] || die "$EVAL_CONF lacks $x"; done
[ "$H2N_TOPO:$VCPUS_PER_VM:$H2N_RAM_GB:$H2N_NODES" = "2:4:96:2" ] || die "the experiment runs on the 2-VM topology, 4 vCPU per VM"
[[ $STALE_MS =~ ^0(,[1-9][0-9]*)*$ ]] || die "bad STALE_MS ($STALE_MS: starts with 0, integers ms)"
[[ " $STALE_PILOT_RATES " =~ ^(\ [1-9][0-9]*)+\ $ ]] || die "bad STALE_PILOT_RATES"
X_WRITES=$H2N_WRITES_N2
[ "$X_WRITES" = "$VDB_X_WRITES" ] || die "H2N_WRITES_N2 != VDB_X_WRITES"
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" "$POP_C/p-popcorn-shm.sh" "$VDB_X_DATA/pool_b.fbin" \
  "$X_WRITES" "$STALE_SOURCE_WRITES" "$STALE_TOPK" "$EVD/h2n-block.sh" "$XV/staleness_recall.py" "$XV/staleness-pilot-skip.sh" "$H2N_HOST_IMAGE/SHA256SUMS"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
# ---- pins (the run-2 hw cell's inputs: pins-vdb-run2.sh values; the new loadgen and writes file)
PIN="de3d8480fe7fcf606d0190013b879b5ab713b37f29567ca4ec4633889d77ec17  $VDB_PLAIN_BUILD/manifest.txt
bd0365b365542aa2efd78055b7977cea5268daf9348f40c90b2cf9d3603203dd  $VDB_PLAIN_BUILD/bin/vdb-server
65eb0e24964585a6abeb5699f55af595e8c9c9f4564801738306ef215c93e0aa  $VDB_LOADGEN_BUILD/manifest.txt
ebd12a6866abb1f5dcd3fc7fad84e85da2b8bb74d956c7d950d5310bc1e9f59c  $VDB_LOADGEN_BUILD/loadgen
dc85f4c57055225bc20d990764a1b3c7a28aed21598121a7a07937c6e57782ae  $REGION
bb52e76c5f2bedbe8661e61026cc8c7c267f4c310465cfa29ffddae002bd971f  $H2N_HOST_IMAGE/SHA256SUMS
925e5a0c57bbccdaeab2d4fe17fcf5871559d90c9a1af6af62626aa1a6b05afc  $P/builds/vdb-inputs/5/SHA256SUMS
8ad2e82a3710ef331c50ea8c2fc1f1fad29b536611a0e850030af4c0d9a3e0a1  $STALE_SOURCE_WRITES
6a2ede0ca46f4b4d7f28123a9d5435a1cb96ea6f53333e171981d68e2e4afa13  $X_WRITES
$STALE_TOPK_SHA256  $STALE_TOPK"
echo "$PIN" | sha256sum --quiet -c - || die "pins do not verify (builds, region, image, data, writes, top-K' file)"
plan "pins verified: server $VDB_PLAIN_BUILD, loadgen $VDB_LOADGEN_BUILD, region, image, inputs/5, writes $X_WRITES, top-K' $STALE_TOPK"
grep -qa cxl_ipoll "$VDB_PLAIN_BUILD/bin/vdb-server" || die "$VDB_PLAIN_BUILD is not the run-2 server (no cxl_ipoll)"
# writes file = the run-2 writes file record by record, every target 0 (the Host prediction applies record by record)
python3 -I -B - "$X_WRITES" "$STALE_SOURCE_WRITES" <<'PY' || die "$X_WRITES is not $STALE_SOURCE_WRITES with every target 0"
import sys, numpy as np
d = np.dtype([("op", "u1"), ("target", "u1"), ("pad0", "<u2"), ("w_seq", "<u4"), ("id", "<u8"), ("vec_ref", "<u4"), ("pad1", "<u4")])
a, b = np.memmap(sys.argv[1], dtype=d, mode="r"), np.memmap(sys.argv[2], dtype=d, mode="r")
ok = len(a) == len(b) and (a["target"] == 0).all() and all((a[f] == b[f]).all() for f in ("op", "w_seq", "id", "vec_ref"))
sys.exit(0 if ok else 1)
PY
plan "writes file = $STALE_SOURCE_WRITES with every target 0 (op / w_seq / id / vec_ref equal)"
# ---- part spec and update budget
Q=$STALE_QUERY_RATE NCOP=$(echo "$STALE_MS" | tr ',' '\n' | wc -l) DR=$STALE_DRAIN_S BUD=$STALE_UPDATE_BUDGET
[ "$BUD" = "$H2N_MAXD_N2" ] && [ "$BUD" = "$VDB_X_MAXD" ] || die "STALE_UPDATE_BUDGET ($BUD) != the server's --max-deletes ($H2N_MAXD_N2)"
FIX= FUPD= WIN=
if [ $SPART = pilot ]; then
  PW=$STALE_PILOT_WARMUP_S PM=$STALE_PILOT_MEASURE_S SUM=0
  for r in $STALE_PILOT_RATES; do FIX+="${FIX:+ }hw/p$r/-/-/$Q/$PW/$PM/$DR"; FUPD+="${FUPD:+ }p$r:$r"; SUM=$((SUM + r)); done
  WIN=$PM
  # every step's window and its warmup at the step's rate, all steps run (the worst case): sum x window <= budget - warmup updates
  [ $((SUM * PM)) -le $((BUD - SUM * PW)) ] || die "pilot steps [$STALE_PILOT_RATES]: $((SUM * PM)) window updates > budget $BUD - $((SUM * PW)) warmup updates"
  plan "pilot: steps [$STALE_PILOT_RATES] updates/s, each ${PW} s warmup + ${PM} s window, stop at the first unsustained step; worst case $((SUM * (PW + PM))) updates <= budget $BUD"
else
  [[ " $STALE_PILOT_RATES " == *" $RATE "* ]] || die "R=$RATE is not one of the pilot rates [$STALE_PILOT_RATES] (approved: the highest clean pilot rate)"
  MW=$STALE_MEASURE_WARMUP_S
  WIN=$(( BUD / RATE - MW - STALE_MARGIN_S )); [ "$WIN" -le "$STALE_MEASURE_S" ] || WIN=$STALE_MEASURE_S
  [ "$WIN" -ge 60 ] || die "R=$RATE leaves a window of $WIN s (< 60 s)"
  [ $((RATE * (MW + WIN))) -le "$BUD" ] || die "R=$RATE x ($MW + $WIN) s > budget $BUD"
  FIX="hw/m/-/-/$Q/$MW/$WIN/$DR" FUPD="m:$RATE"
  plan "measure: R=$RATE updates/s, ${MW} s warmup (15 + 10 s lookback) + W=${WIN} s window (= min($STALE_MEASURE_S, floor($BUD / $RATE) - $MW - $STALE_MARGIN_S)); $((RATE * (MW + WIN))) updates <= budget $BUD"
  plan "measure: expected searches per T = $Q query/s x $WIN s = $((Q * WIN)) (x $NCOP copies = $((Q * WIN * NCOP)) search requests)"
fi
LGSTR="--mix search=1 --opt stale_ms=$STALE_MS --opt search_target=$STALE_SEARCH_TARGET"
SKIPC=; [ $SPART = pilot ] && SKIPC="bash $TREE/experiments/vectordb/staleness-pilot-skip.sh"
need_env
lock_free
BENV=(H2N_N=2 H2N_VCPU=$VCPUS_PER_VM H2N_LIFETIMES=hw:u0 EVAL_RUN=1 SEED=$((SEED_BASE + 1)) REGION=$REGION
  C8=$POP_C K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  VPLAIN=$VDB_VPLAIN PLAIN_BUILD=$VDB_PLAIN_BUILD LOADGEN=$VDB_LOADGEN_BUILD/loadgen X_DATA=$VDB_X_DATA X_WRITES=$X_WRITES
  X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$H2N_MAXD_N2 X_INIT_CAP=$VDB_X_INIT_CAP X_NA=$VDB_X_NA
  "H2N_SLO_PART=$H2N_SLO_PART" H2N_OPCOH_STRICT=$H2N_OPCOH_STRICT H2N_CXLBW=$H2N_CXLBW H2N_HOSTCPU=$H2N_HOSTCPU
  H2N_VEC_FORMAT=$H2N_VEC_FORMAT H2N_EF=$H2N_EF H2N_INIT=$H2N_INIT H2N_HOST_IMAGE=$H2N_HOST_IMAGE "H2N_FIXED=$FIX"
  "H2N_PLAIN_SERVER_EXTRA=$H2N_PLAIN_SERVER_EXTRA" "H2N_WRITES_TARGETS=$H2N_WRITES_TARGETS" "H2N_LG_STREAMS=$LGSTR"
  "H2N_FIXED_UPDATE=$FUPD")
[ -z "$SKIPC" ] || BENV+=("H2N_FIXED_SKIP_CMD=$SKIPC")
[ ${#RECVENV[@]} = 0 ] || BENV+=("${RECVENV[@]}")
for x in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!x:-}" ] || BENV+=("$x=${!x}"); done
RUNN=hw-u0-n2 RD=$E/block/hw-u0-n2
analysis_cmds() {  # the Host commands after the block (printed by --dry-run, run by a real run)
  local NICE="nice -n 19 numactl --cpunodebind=1 --membind=1"
  if [ $SPART = pilot ]; then
    for r in $STALE_PILOT_RATES; do
      echo "[ -d $RD/p$r/loadgen ] && python3 -I -B $XV/urate_check.py $RD/p$r --writers ${H2N_PLAIN_SERVER_EXTRA##* } > $E/analysis/urate-p$r.txt"
    done
  else
    echo "$NICE python3 -I -B $XV/staleness_recall.py --searches $RD/m/loadgen/searches.bin --stale $RD/m/loadgen/stale.bin --writes $X_WRITES --topk $STALE_TOPK --out $E/analysis/steps.csv --run $EN --rate $RATE --window-s $WIN --check > $E/analysis/staleness-recall.txt"
    echo "mkdir -p $DERIVED_ROOT/$EN && cp $E/analysis/steps.csv $E/analysis/staleness-recall.txt $DERIVED_ROOT/$EN/"
  fi
}
if [ $DRYRUN = 1 ]; then
  # the block's own dry check (lib.sh block_dry rules: a non-empty temp dir as E, gate dirs default to RESULTS_ROOT)
  td=$(mktemp -d /tmp/stale-dry-XXXXXX) && touch "$td/not-empty" || die "mktemp"
  out=$(env PRETOUCH_DIR=${PRETOUCH_DIR:-$RESULTS_ROOT} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-$RESULTS_ROOT} \
    MEASURE_PART_DIR=${MEASURE_PART_DIR:-$RESULTS_ROOT} H2N_BLOCK_DRY=1 "${BENV[@]}" bash "$EVD/h2n-block.sh" "$td" 2>&1); brc=$?
  rm -rf "$td"
  echo "$out" | sed 's/^/  block dry: /'
  [ $brc = 0 ] && [[ $(echo "$out" | tail -n 1) == *"evidence-dir check reached"* ]] || die "the block's dry check failed (rc $brc)"
  SA=$(echo "$out" | sed -n 's/.*BLOCK PLAN: server_args plain=\[\(.*\)\].*/\1/p' | head -1)
  [ -n "$SA" ] || die "no server_args line in the block's dry output"
  [[ " $SA " == *" $H2N_PLAIN_SERVER_EXTRA "* ]] || die "server args lack $H2N_PLAIN_SERVER_EXTRA"
  APP=$(env "$VDB_PLAIN_BUILD/bin/vdb-server" $SA --print-app-bytes) || die "print-app-bytes"
  IPS=(192.168.122.100 192.168.122.101) SSH="ssh -o BatchMode=yes -o ConnectTimeout=8" V=$VDB_VPLAIN G=$V/runs/$RUNN-'<rid>'
  echo "==== DRY RUN: commands of a real run, in order (Host = run on the Host; vmK = over ssh to cxl_vmK) ===="
  c() { echo "  $*"; }
  c "Host: mkdir $E $E/block; lib.sh manifest -> $E/eval-manifest.txt; $E/staleness-manifest.txt"
  c "Host: env ${BENV[*]} bash $EVD/h2n-block.sh $E/block > $E/sequence.log 2>&1"
  echo " -- inside h2n-block.sh (hw fixed-window lifetime $RUNN; scripts/host/h3-gate.sh, run.sh, vdb-node.sh):"
  c "Host: bash $TREE/scripts/host/h3-gate.sh lock eval-h2n-n2-run1"
  c "Host: bash $TREE/experiments/rocksdb/pretouch-check-n.sh \$PRETOUCH_DIR $E/block/pretouch-check-start.txt"
  c "Host: bash $TREE/scripts/host/h3-gate.sh check $E/block/gate-H0.txt"
  for i in 0 1; do
    c "vm$i: $SSH comsys@${IPS[$i]} \"PRECHECK_ALLOW_DETAIL=0 EXPECT_K=$POP_K EXPECT_DAX_UUID=$EXPECT_DAX_UUID INIT_DIR=$H2N_INIT INIT_SUMS=<sha256 of $H2N_HOST_IMAGE/SHA256SUMS> INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) INSTALL_DIRS='${V#/home/comsys/}/bin/vdb-server ...' bash -s\" < $XV/m4-precheck.sh"
    c "vm$i: $SSH comsys@${IPS[$i]} nproc   (must be $VCPUS_PER_VM)"
    c "vm$i: $SSH comsys@${IPS[$i]} 'dmesg | wc -l'   (baseline)"
  done
  c "Host: bash $TREE/scripts/host/h3-gate.sh check $E/block/gate-$RUNN.txt"
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} \"pgrep -c -f -- '[/]bin/vdb-server( |\$)'\"   (servers_gone: 0)"; done
  echo " -- run.sh $RUNN (SYSTEM=all-HWcc, PARTS=[$(for t in $FIX; do IFS=/ read -r _ p _ <<< "$t"; printf '%s ' "$p"; done)]):"
  for i in 0 1; do
    c "vm$i: $SSH comsys@${IPS[$i]} \"uname -r; sha256sum $V/bin/vdb-server $V/cfg/cxl_region.yaml ...; nproc\""
  done
  c "vm0: $SSH comsys@${IPS[0]} \"sha256sum $H2N_INIT/SHA256SUMS | cut -d' ' -f1\""
  for i in 0 1; do
    c "vm$i: $SSH comsys@${IPS[$i]} \"$V/bin/vdb-node.sh start $V $G $i <rid> $APP $SA --port 7000$([ $i = 0 ] && echo " --init-dir $H2N_INIT")\""
  done
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} \"$V/bin/vdb-node.sh ready $G $i 5400\""; done
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} \"ss -ltn | awk ...:7000\"; Host: bash -c 'exec 3<>/dev/tcp/${IPS[$i]}/7000'"; done
  first=1
  for t in $FIX; do
    IFS=/ read -r _ p _ _ frt fw fm fdr <<< "$t"
    [ -z "$SKIPC" ] || c "Host: FIXED_RUN_DIR=$RD FIXED_PARTS=... $SKIPC $p   (rc 0 = skip: the previous step not sustained)"
    [ $first = 1 ] || c "Host: bash $TREE/scripts/host/h3-gate.sh check $E/block/gate-$RUNN-$p.txt"
    c "Host: bash $EVD/fixed-part-hook.sh pre hw $p   (hw: no VM write; reads nothing for detail/recv '-')"
    for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} 'head -1 /proc/stat'   (cpu snapshot before)"; done
    c "Host: bash $TREE/scripts/host/measure-run.sh -- numactl --physcpubind=56-63 --membind=1 $VDB_LOADGEN_BUILD/loadgen --workload vectordb --target ${IPS[0]}:7000,${IPS[1]}:7000 --out $RD/$p/loadgen --stats-op 10 --opt data=$VDB_X_DATA --opt writes=$X_WRITES --opt k=10 $LGSTR --x-stream search --raw --mode fixed --rates $frt --warmup-s 0 --step-warmup-s $fw --step-measure-s $fm --drain-s $fdr --fixed update=$([ $SPART = pilot ] && echo "${p#p}" || echo "$RATE") --opt seed=$((SEED_BASE + 1)) --seed $((SEED_BASE + 1)) --opt w_start=<next_w of the previous part, 0 first>"
    for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} 'head -1 /proc/stat'   (cpu snapshot after)"; done
    c "Host: bash $EVD/fixed-part-hook.sh post hw $p"
    first=0
  done
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} \"$V/bin/vdb-node.sh stop $G $i\"; Host: scp -q comsys@${IPS[$i]}:$G/node$i.* $RD/"; done
  c "Host: run.sh post outputs (stats_delta.py, export_csv.py, opsplit.py, plot_slo.py) per part"
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} \"pgrep -c -f -- '[/]bin/vdb-server( |\$)'\"   (servers_gone)"; done
  c "Host: per part: opsplit.py, opcoh_check.py hwcc (recorded), urate_check.py --writers ${H2N_PLAIN_SERVER_EXTRA##* }, e1_check.py (stop on a violation)"
  for i in 0 1; do c "vm$i: $SSH comsys@${IPS[$i]} 'dmesg | tail -n +<base+1>'   (dmesg check $RUNN)"; done
  c "Host: bash $TREE/experiments/rocksdb/pretouch-check-n.sh \$PRETOUCH_DIR $E/block/pretouch-check-end.txt"
  echo " -- EXIT trap (finish):"
  for i in 0 1; do
    c "vm$i: $SSH comsys@${IPS[$i]} \"pkill -u comsys -f -- '[/]bin/vdb-server( |\$)'; ... pkill -9 ...; echo procs=\$(pgrep -c ...)\""
    c "vm$i: $SSH comsys@${IPS[$i]} 'f=\$(sudo -n fuser /dev/dax0.0 2>&1); r=\$?; echo \"dax_users=[\$f] rc=\$r\"'"
    c "vm$i: $SSH comsys@${IPS[$i]} 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; stat -c \"%U:%G %a\" /dev/dax0.0'"
    c "vm$i: $SSH comsys@${IPS[$i]} 'dmesg | tail -n +<base+1>'   (final dmesg check)"
  done
  c "Host: bash $TREE/scripts/host/h3-gate.sh unlock eval-h2n-n2-run1"
  echo " -- Host analysis after the block:"
  analysis_cmds | sed 's/^/  Host: /'
  echo "STALE DRY RUN OK ($SPART${RATE:+ R=$RATE}${WIN:+ W=$WIN s}): stops here, before the lock"
  exit 0
fi
# ---- real run
mkdir "$E" && mkdir "$E/block" "$E/analysis" || die "mkdir $E"
log() { echo "$(date -Is) [$EN] $*" | tee -a "$E/staleness-state.txt"; }
manifest "$VDB_PLAIN_BUILD" "$VDB_LOADGEN_BUILD"
{ echo "# vector-db-staleness-recall $SPART (experiments/vectordb/staleness-block.sh)"
  echo "part=$SPART rate=${RATE:-} window_s=$WIN query_rate=$Q stale_ms=$STALE_MS copies=$NCOP search_target=$STALE_SEARCH_TARGET"
  echo "fixed=[$FIX] fixed_update=[$FUPD] lg_streams=[$LGSTR] skip_cmd=[$SKIPC] budget=$BUD"
  echo "writes=$X_WRITES sha256=6a2ede0ca46f4b4d7f28123a9d5435a1cb96ea6f53333e171981d68e2e4afa13 source=$STALE_SOURCE_WRITES"
  echo "topk=$STALE_TOPK sha256=$STALE_TOPK_SHA256"
  echo "loadgen=$VDB_LOADGEN_BUILD/loadgen sha256=$(sha256sum < "$VDB_LOADGEN_BUILD/loadgen" | cut -c1-64) server=$VDB_PLAIN_BUILD/bin/vdb-server sha256=$(sha256sum < "$VDB_PLAIN_BUILD/bin/vdb-server" | cut -c1-64)"
  echo "block_env=${BENV[*]}"; } > "$E/staleness-manifest.txt"
log "block start ($SPART${RATE:+ R=$RATE} W=$WIN s)"
env "${BENV[@]}" bash "$EVD/h2n-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || { log "STALE STOP: block did not finish (see $E/sequence.log, $E/block/block.log)"; exit 1; }
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || { log "STALE STOP: rollback / cleanup failure lines"; exit 1; }
if [ $SPART = pilot ]; then
  printf '# rate\tran\tvalid\tdone_per_s\tbacklog\tstep_line\n' > "$E/analysis/pilot.tsv"
  best=none prev_ok=1
  for r in $STALE_PILOT_RATES; do
    if [ -d "$RD/p$r/loadgen" ]; then
      python3 -I -B "$XV/urate_check.py" "$RD/p$r" --writers "${H2N_PLAIN_SERVER_EXTRA##* }" > "$E/analysis/urate-p$r.txt" 2>&1
      st=$(grep '^STEP ' "$E/analysis/urate-p$r.txt" | tail -n 1)
      v=False; [[ $st == *" valid=True "* ]] && v=True
      printf '%s\tyes\t%s\t%s\t%s\t%s\n' "$r" "$v" "$(echo "$st" | sed -n 's/.* done=\([^ ]*\) .*/\1/p')" "$(echo "$st" | sed -n 's/.* backlog=\([^ ]*\) .*/\1/p')" "$st" >> "$E/analysis/pilot.tsv"
      if [ $v = True ] && [ $prev_ok = 1 ]; then best=$r; else prev_ok=0; fi
    else
      printf '%s\tno\t-\t-\t-\tskipped (an earlier step was not sustained)\n' "$r" >> "$E/analysis/pilot.tsv"; prev_ok=0
    fi
  done
  log "PILOT RESULT highest_clean_rate=$best (steps [$STALE_PILOT_RATES]; $E/analysis/pilot.tsv)"
else
  mkdir -p "$DERIVED_ROOT/$EN"
  nice -n 19 numactl --cpunodebind=1 --membind=1 python3 -I -B "$XV/staleness_recall.py" --searches "$RD/m/loadgen/searches.bin" \
    --stale "$RD/m/loadgen/stale.bin" --writes "$X_WRITES" --topk "$STALE_TOPK" --out "$E/analysis/steps.csv" --run "$EN" \
    --rate "$RATE" --window-s "$WIN" --check > "$E/analysis/staleness-recall.txt" 2>&1; arc=$?
  cp "$E/analysis/steps.csv" "$E/analysis/staleness-recall.txt" "$DERIVED_ROOT/$EN/" 2>/dev/null
  log "analysis rc $arc: $(tail -n 1 "$E/analysis/staleness-recall.txt") (steps.csv: $E/analysis/steps.csv, copy $DERIVED_ROOT/$EN/; W=$WIN s, expected searches per T $((Q * WIN)))"
  [ $arc = 0 ] || { log "STALE NOTE: staleness_recall.py --check failed (see staleness-recall.txt)"; exit 1; }
fi
log "STALE DONE $SPART"

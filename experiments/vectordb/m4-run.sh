#!/bin/bash
# One VectorDB run of the M4 / M5 packets (reports/M4-vdb-packet.md, reports/M5-pilot-packet.md; MOT1 v5 §3.3, §4.3):
# Host gate, system setup, run.sh, post checks, E1 check, load times.
# usage: m4-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon | Popcorn), U (update %: 0 | 5 | 10 | 20 | 50 | 90; MOT1 v6 H1 mixes
#   search/update 95/5, 50/50, 10/90 = U 5, 50, 90; H2 shares 0/5/10/20/50),
#   KIND: functional | slo (MOT1 step 1) | fixed (step 2, 60 s) | pslo (pilot SLO search: steps 2 s + 8 s, confirm
#   1 x 15 s, no fill/overload) | pfix (pilot fixed load, 30 s)
#   KIND=fixed|pfix: RATE (total req/s of the scaled streams = L / (1 - U/100)); TRACE (0 | 1, default 0; Megalon only)
#   DATASET: 28m (default: pubmed-a27m-b1m-q10k, image seg32c32m-a27m) | 1m (pubmed-a1m-b1m-q10k, writes
#   writes-a1m-b1m-u1m.bin, image seg32c32m)
#   Builds / guest install dirs (defaults = M4): LOADGEN_BIN (builds/loadgen/4/loadgen), PLAIN_BUILD (builds/vdb/8), VPLAIN (/home/comsys/vdb8),
#   MEG_BUILD (builds/vdb-megalon/6), VMEG (/home/comsys/vdbm6-28m)
#   SYS=Popcorn: C8 (build-8 deploy bundle dir), K8 (release), GT8 (guest tools dir), RECV_MODE (poll | idle | sleep)
# optional: REP (repeat label, recorded), SEED (loadgen --seed, default 20261015), GATE=0 (skip the Host gate:
#   refused unless KIND=functional), QCOH_EXPECT (none | swmc: per-query coherence, vdb build >= 9, DESIGN.md §14; both
#   servers must log "query coherence on, page MSI source <QCOH_EXPECT>", end with qcoh.read_errors=0 and
#   qcoh.open_errors=0, and every OK search response must carry the block (vectordb.txt ok_without_coh=0,
#   bad_coh_version=0); then qcoh.py writes <run>/qcoh-steps.csv). Use QCOH_EXPECT only with builds <= 9.
#   OPCOH_EXPECT (vdb builds >= 10; per-operation time split, DESIGN.md §15): the system's own coherence source,
#   mandatory for every non-functional run (unless QCOH_EXPECT is given for an old build) and bound to SYS:
#   Popcorn = swmc_acct (servers log "popcorn source swmc_acct"), Megalon = cohsnap ("megalon cohsnap on"),
#   all-HWcc = none (no source required). Servers must end with opcoh.read_errors=0 and opcoh.register_errors=0 and
#   every OK search/update must carry the v2 block; then opsplit.py writes <run>/opsplit-steps.csv + .columns.csv and
#   must succeed (it refuses runs with mixed coherence sources).
#   OPCOH_CHECK_MODE (hwcc | popcorn | megalon | megalon-t0; optional): after opsplit, workloads/vectordb/tests/
#   opcoh_check.py <run> <mode> must print OPCOH_CHECK PASS (closure: server opt.* totals = response blocks; mode
#   checks per system; output in <run>/opcoh-check.txt).
#   XENV (optional): extra "ENV:K=V" tokens for every node (e.g. ENV:MEGALON_COH_TIMERS=0); XARGS (optional): extra
#   vdb-server arguments of the measured server (e.g. --trace-max-mb 2048); both recorded in the run manifest.
# Prints "M4RUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE (NOTE = a loadgen SLO-search outcome that is a
# result, not an error: "confirm failed at three rates"), 1 for STOP (the sequence stops).
set -uo pipefail
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/vectordb
: "${SYS:?}" "${U:?}" "${KIND:?}"
TRACE=${TRACE:-0} SEED=${SEED:-20261015} XENV=${XENV:-} XARGS=${XARGS:-}
for t in $XENV; do [[ $t =~ ^ENV:[A-Z_][A-Z0-9_]*=[A-Za-z0-9_./-]*$ ]] || { echo "M4RUN $NAME STOP bad XENV token $t"; exit 1; }; done
[[ "$XARGS" =~ ^[A-Za-z0-9\ ./=-]*$ ]] || { echo "M4RUN $NAME STOP bad XARGS"; exit 1; }
stop() { echo "M4RUN $NAME STOP $*"; exit 1; }
[ -d "$E" ] || stop "missing evidence dir $E"
[ -e "$E/$NAME" ] && stop "$E/$NAME exists"
case "${DATASET:-28m}" in
  28m) D=$P/workspaces/vdb-data/pubmed-a27m-b1m-q10k W=$P/workspaces/vdb-data/writes-a27m-b1m-u1m.bin
       INIT=/home/comsys/vdb/init/seg32c32m-a27m NA=26990000 NB=1000000 MAXIDS=28000000;;
  1m)  D=$P/workspaces/vdb-data/pubmed-a1m-b1m-q10k W=$P/workspaces/vdb-data/writes-a1m-b1m-u1m.bin
       INIT=/home/comsys/vdb/init/seg32c32m NA=1000000 NB=1000000 MAXIDS=2000000;;
  *) stop "bad DATASET";;
esac
PLAIN_BUILD=${PLAIN_BUILD:-$P/builds/vdb/8} VPLAIN=${VPLAIN:-/home/comsys/vdb8}
MEG_BUILD=${MEG_BUILD:-$P/builds/vdb-megalon/6} VMEG=${VMEG:-/home/comsys/vdbm6-28m}
SA="--nodes 2 --segments 32 --M 16 --efc 128 --ef 32 --max-writes 2097152 --max-ids $MAXIDS --max-deletes 1048576
 --search-threads 14 --wait-timeout-ms 60000 --start-timeout-ms 5400000"
SA=$(echo $SA)
export LOADGEN=${LOADGEN_BIN:-$P/builds/loadgen/4/loadgen} READY_TIMEOUT=5400 RUN_KIND=measurement TRACE STATS_OP=10 INIT
[ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc V=$VPLAIN HOST_SERVER=$PLAIN_BUILD/bin/vdb-server SERVER_ARGS="$SA $XARGS" NODE_ENV="$XENV";;
  Megalon) export SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server \
             SERVER_ARGS="--backend megalon $SA $XARGS" NODE_ENV="ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml $XENV" \
             NODE0_ENV="ENV:MEGALON_REINIT=1";;
  Popcorn) : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
           [[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || stop "bad RECV_MODE"
           export SYSTEM=Popcorn-$RECV_MODE V=$VPLAIN HOST_SERVER=$PLAIN_BUILD/bin/vdb-server \
             SERVER_ARGS="$SA --preloaded $XARGS" NODE_ENV="$XENV";;
  *) stop "bad SYS";;
esac
[ "$SYS" = Megalon ] || [ "$TRACE" = 0 ] || stop "TRACE=1 is for Megalon only"
case "$SYS" in Popcorn) OPC_SYS=swmc_acct;; Megalon) OPC_SYS=cohsnap;; *) OPC_SYS=none;; esac
if [ "$KIND" != functional ] && [ -z "${QCOH_EXPECT:-}" ]; then
  [ -n "${OPCOH_EXPECT:-}" ] || stop "OPCOH_EXPECT is mandatory for measurement runs ($SYS: $OPC_SYS)"
fi
[ -z "${OPCOH_EXPECT:-}" ] || [ "$OPCOH_EXPECT" = "$OPC_SYS" ] || stop "OPCOH_EXPECT=$OPCOH_EXPECT does not match $SYS ($OPC_SYS)"
case "$U" in
  0) MIX=search=1;; 5) MIX=update=5,search=95;; 10) MIX=update=10,search=90;; 20) MIX=update=20,search=80;;
  50) MIX=update=50,search=50;; 90) MIX=update=90,search=10;;
  *) stop "bad U";;
esac
LG=(--opt data=$D --opt writes=$W --opt k=10 --opt seed=$SEED --seed "$SEED" --mix "$MIX" --slo search:99:100
    --x-stream search)
case "$KIND" in
  functional) LG+=(--mode fixed --rates 10 --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 30);;
  slo) LG+=(--raw --mode slo --start 10 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --confirm-s 30 --confirm-reps 3);;
  fixed) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --warmup-s 10 --step-warmup-s 10 --step-measure-s 60
            --drain-s 10);;
  pslo) LG+=(--raw --mode slo --start 10 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 2
            --step-measure-s 8 --confirm-s 15 --confirm-reps 1 --fill none --overload none);;
  pfix) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --warmup-s 10 --step-warmup-s 5 --step-measure-s 30
            --drain-s 10);;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
servers_gone() { for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip 'pgrep -c -x vdb-server' < /dev/null)" = 0 ] || return 1; done; }
echo "$(date -Is) $NAME: SYS=$SYS U=$U KIND=$KIND DATASET=${DATASET:-28m} REP=${REP:-} TRACE=$TRACE RATE=${RATE:-} RECV_MODE=${RECV_MODE:-} SEED=$SEED V=$V HOST_SERVER=$HOST_SERVER XENV=[$XENV] XARGS=[$XARGS] OPCOH_EXPECT=${OPCOH_EXPECT:-} OPCOH_CHECK_MODE=${OPCOH_CHECK_MODE:-}"
servers_gone || stop "a vdb-server is running before the run"
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed for KIND=functional only"
if [ "${GATE:-1}" = 1 ]; then bash $X/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # P-popcorn-deploy §6a cycle with build 8 (init_state=shared)
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  SHM=0  # 1 from the load attempt until a successful teardown: any exit in between tears down (EXIT trap)
  shm_down() {
    [ $SHM = 1 ] || return 0
    servers_gone || { echo "M4RUN $NAME: servers still running, teardown skipped (manual: packet rollback)"; return 1; }
    env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown && SHM=0
  }
  trap 'shm_down' EXIT
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  SHM=1
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one (both must exist)
    [ "$($SSH comsys@$ip "test -f $V/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $V/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)
  $SSH comsys@${IPS[0]} "CXL_REGION_CONFIG=$V/cfg/cxl_region.yaml $V/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
    < /dev/null > "$E/preload-$NAME.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$NAME.log"
  { grep -q "PRELOAD DONE" "$E/preload-$NAME.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || stop "enable gate"
  for ip in "${IPS[@]}"; do  # recv_mode is runtime-writable (after enable, before the run)
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    echo "$ip recv_mode=$m" >> "$E/recv-mode-$NAME.txt"
    [ "$m" = "$RECV_MODE" ] || stop "recv_mode on $ip = $m"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || stop "status pre"
  for k in 0 1; do  # build-8 instrumentation must be on (per-query and window page MSI counters)
    grep -qx "instr_enabled=1" "$E/shm-$NAME/status-pre-vm$k.txt" || stop "instr_enabled != 1 on vm$k (status pre)"
  done
fi
bash $X/run.sh "$NAME" "$E" -- "${LG[@]}"
RC=$?
if [ "$SYS" = Popcorn ]; then
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status
  servers_gone || stop "servers left (Popcorn teardown not attempted)"
  shm_down || stop "shm teardown"
fi
servers_gone || stop "servers left"
R=$E/$NAME
[ -d "$R" ] || stop "no run dir"
for k in 0 1; do  # clean stop, final stats, no bad request (E1 wait timeouts are recorded, not fatal: overload steps)
  L=$R/node$k.log
  { grep -q "vdb-server: stopping" $L && [ "$(grep -c '^bad_records=0$' $L)" = 1 ]; } || stop "node$k: no clean stop / bad_records"
  echo "node$k $(grep -h '^timeouts=' $L)" >> $R/timeouts.txt
done
{ echo "# load times $NAME (s): run start -> READY, server log lines"; echo "run_wall_s=$(( $(date +%s) - T0 ))"
  [ -f "$E/preload-$NAME.log" ] && grep -h "PRELOAD DONE\|preload_wall_s" "$E/preload-$NAME.log"
  grep -h "loaded .* initial records\|published preloaded\|warm-up read\|READY node" $R/node*.log
  grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
if [ -n "${QCOH_EXPECT:-}" ]; then  # per-query coherence (DESIGN.md §14)
  for k in 0 1; do
    grep -qE "^vdb-server: query coherence on, page MSI source $QCOH_EXPECT[ :]" $R/node$k.log || stop "node$k: query coherence source != $QCOH_EXPECT"
    { grep -qx "qcoh.read_errors=0" $R/node$k.log && grep -qx "qcoh.open_errors=0" $R/node$k.log; } || stop "node$k: qcoh read/open errors"
  done
  { grep -qx "ok_without_coh=0" $R/loadgen/vectordb.txt && grep -qx "bad_coh_version=0" $R/loadgen/vectordb.txt; } \
    || stop "search responses without a coherence block"
  python3 $X/qcoh.py $R > $R/qcoh.log 2>&1 || echo "M4RUN $NAME: qcoh.py failed (analysis only; see $R/qcoh.log)"
fi
if [ -n "${OPCOH_EXPECT:-}" ]; then  # per-operation time split (vdb build >= 10, DESIGN.md §15)
  for k in 0 1; do
    grep -q "^vdb-server: op coherence on," $R/node$k.log || stop "node$k: op coherence not on"
    case $OPCOH_EXPECT in
      swmc_acct) grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $R/node$k.log || stop "node$k: popcorn source != swmc_acct";;
      cohsnap) grep -qE "^vdb-server: op coherence on, .*megalon cohsnap on," $R/node$k.log || stop "node$k: megalon cohsnap not on";;
    esac
    { grep -qx "opcoh.read_errors=0" $R/node$k.log && grep -qx "opcoh.register_errors=0" $R/node$k.log; } || stop "node$k: opcoh read/register errors"
  done
  { grep -qx "ok_without_coh=0" $R/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $R/loadgen/vectordb.txt &&
    grep -qx "bad_coh_version=0" $R/loadgen/vectordb.txt; } || stop "responses without an op coherence block"
  python3 $X/opsplit.py $R > $R/opsplit.log 2>&1 || stop "opsplit.py failed (see $R/opsplit.log)"
  if [ -n "${OPCOH_CHECK_MODE:-}" ]; then
    python3 $P/CXL_SWMC/workloads/vectordb/tests/opcoh_check.py $R $OPCOH_CHECK_MODE > $R/opcoh-check.txt 2>&1
    grep -q "^OPCOH_CHECK PASS" $R/opcoh-check.txt || stop "opcoh_check $OPCOH_CHECK_MODE (see $R/opcoh-check.txt)"
  fi
fi
python3 $X/e1_check.py --writes $W --na $NA --nb $NB --searches $R/loadgen/searches.bin --out $R/e1 --sample 500 > /dev/null \
  || stop "E1 violation (see $R/e1.e1.txt)"
grep -q "workload_finish\":\"ok" $R/loadgen/summary.json || stop "loadgen workload finish"
if [ $RC != 0 ]; then
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $R/loadgen/summary.json 2>/dev/null)
  [[ $KIND =~ ^p?slo$ ]] && [ "$note" = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" ] \
    && { echo "M4RUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$KIND" = functional ] && ! grep -q '"pass":true' $R/loadgen/steps.jsonl && stop "functional step not PASS"
echo "M4RUN $NAME OK"

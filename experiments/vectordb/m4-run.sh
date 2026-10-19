#!/bin/bash
# One VectorDB run of the M4 / M5 packets (reports/M4-vdb-packet.md, reports/M5-pilot-packet.md; MOT1 v5 §3.3, §4.3):
# Host gate, system setup, run.sh, post checks, E1 check, load times.
# usage: m4-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon | Popcorn), U (update %: 0 | 5 | 10 | 20 | 50 | 90; MOT1 v6 H1 mixes
#   search/update 95/5, 50/50, 10/90 = U 5, 50, 90; H2 shares 0/5/10/20/50),
#   KIND: functional | slo (MOT1 step 1) | fixed (step 2, 60 s) | pslo (pilot SLO search: steps 2 s + 8 s, confirm
#   1 x 15 s, no fill/overload) | pfix (pilot fixed load, 30 s)
#   KIND=h1 (H1-HOOK v2, one server lifetime with loadgen parts, run.sh PARTS): H1_PARTS "slo" | "slo fix" | "fix";
#     part slo = the KIND=slo search; part fix = settle (loadgen --warmup-s SETTLE_S at the first rate, discarded) +
#     60 s windows at L2 then L1 (KIND=fixed step lengths), rates RATE="<L2>,<L1>" or, if RATE is empty, from RATES_CMD
#     ("<L2> <L1>" on stdout, run inside the lifetime after the slo part; failure = "M4RUN <name> STOP LEVELS STOP").
#     Checks per part dir <run>/<part> (opsplit, opcoh_check with OPCOH_PARTS = all parts, E1, loadgen finish; NOTE
#     only for the slo part); fix parts get <run>/fix/h1-steps.txt "<L2 step>,<L1 step>" (measured fixed steps).
#   KIND=urate (update-rate sweep, urate-block.sh; workloads/vectordb/DESIGN.md §17): one server lifetime, parts
#     "warm slo" (run.sh PARTS); U=0 (searches only in --mix) plus the absolute update stream --fixed update=URATE
#     (updates/s, independent of the search rate) and --tol 0.02 in every part; part warm = unmeasured warm-up
#     (1 search/s, 10 + 50 s, its stats snapshots kept, never used); part slo = the knee-ramp SLO search (RecSys
#     methodology 2026-10-19, state/PROJECT.md): --start URATE_START (default 1) --factor 1.5 --precision 0.02,
#     confirm 3 x 30 s as H1, --max-steps 40 --min-step-queries 100 --ramp-knee 2 --ramp-knee-floor 1.5. Seeds: warm
#     SEED + 100, slo SEED. Any loadgen note of the slo part is a NOTE (a result, not an error); warm must end without.
#   KIND=fixed|pfix: RATE (total req/s of the scaled streams = L / (1 - U/100)); TRACE (0 | 1, default 0; Megalon only)
#   DATASET: 28m (default: pubmed-a27m-b1m-q10k, image seg32c32m-a27m) | 1m (pubmed-a1m-b1m-q10k, writes
#   writes-a1m-b1m-u1m.bin, image seg32c32m)
#   Builds / guest install dirs (defaults = M4): LOADGEN_BIN (builds/loadgen/4/loadgen), PLAIN_BUILD (builds/vdb/8), VPLAIN (/home/comsys/vdb8),
#   MEG_BUILD (builds/vdb-megalon/6), VMEG (/home/comsys/vdbm6-28m)
#   SYS=Popcorn: C8 / K8 / GT8 = the Popcorn deploy bundle dir, release and guest tools dir (names kept from build 8;
#   any build >= 8 bundle, e.g. build 10 in reports/VDB-V1-packet.md), RECV_MODE (poll | idle | sleep);
#   PRELOAD_TIMEOUT_S (default 1200): bound of the --preload-only run on node 0 (guest `timeout -k 30`); its pid is
#   written to the guest file $V/runs/preload-<name>.pid and named in <evidence>/preload-<name>.pid, so the block
#   cleanup (m4-lib.sh block_stop_servers) can kill it before teardown and the dax rollback.
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
  h1) [[ "${H1_PARTS:-}" =~ ^(slo|slo\ fix|fix)$ ]] || stop "bad H1_PARTS"
      [[ "${SETTLE_S:-}" =~ ^[1-9][0-9]*$ ]] || stop "bad SETTLE_S"
      if [ "$H1_PARTS" = slo ]; then [ -z "${RATE:-}" ] && [ -z "${RATES_CMD:-}" ] || stop "slo-only lifetime takes no rates"
      elif [ -n "${RATE:-}" ]; then [[ $RATE =~ ^[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?$ ]] && [ -z "${RATES_CMD:-}" ] || stop "bad RATE"
      else [ -n "${RATES_CMD:-}" ] && [ "$H1_PARTS" = "slo fix" ] || stop "RATES_CMD needs H1_PARTS='slo fix'"; fi
      # per-part query seed (fixed by part name, the same for every system and lifetime type): slo = SEED, fix =
      # SEED + 1, so a fix part never replays the slo part's query sequence; run.sh appends it and records it
      NL=(); i=0
      while [ $i -lt ${#LG[@]} ]; do  # drop the common --opt seed=.. and --seed .. (set per part instead)
        case "${LG[$i]}" in --opt) [[ "${LG[$((i+1))]}" == seed=* ]] && { i=$((i+2)); continue; };; --seed) i=$((i+2)); continue;; esac
        NL+=("${LG[$i]}"); i=$((i+1))
      done
      LG=("${NL[@]}" --raw)
      export PART_SEED_slo=$SEED PART_SEED_fix=$((SEED + 1))
      export PARTS=$H1_PARTS PART_RATES=${RATE:-} PART_RATES_CMD=${RATES_CMD:-}
      export PART_ARGS_slo="--mode slo --start 10 --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --confirm-s 30 --confirm-reps 3"
      export PART_ARGS_fix="--mode fixed --rates @RATES@ --warmup-s $SETTLE_S --step-warmup-s 10 --step-measure-s 60 --drain-s 10";;
  urate) [[ "${URATE:-}" =~ ^[1-9][0-9]*$ ]] || stop "bad URATE"
         [ "$U" = 0 ] || stop "KIND=urate needs U=0 (updates come from --fixed update=URATE)"
         US=${URATE_START:-1}; [[ $US =~ ^[0-9]+(\.[0-9]+)?$ ]] || stop "bad URATE_START"
         NL=(); i=0
         while [ $i -lt ${#LG[@]} ]; do  # drop the common --opt seed=.. and --seed .. (set per part, as KIND=h1)
           case "${LG[$i]}" in --opt) [[ "${LG[$((i+1))]}" == seed=* ]] && { i=$((i+2)); continue; };; --seed) i=$((i+2)); continue;; esac
           NL+=("${LG[$i]}"); i=$((i+1))
         done
         LG=("${NL[@]}" --raw --fixed update=$URATE --tol 0.02)
         export PART_SEED_warm=$((SEED + 100)) PART_SEED_slo=$SEED PARTS="warm slo" PART_RATES= PART_RATES_CMD=
         export PART_ARGS_warm="--mode fixed --rates 1 --warmup-s 10 --step-warmup-s 0 --step-measure-s 50 --drain-s 10"
         export PART_ARGS_slo="--mode slo --start $US --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 40 --warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --confirm-s 30 --confirm-reps 3 --min-step-queries 100 --ramp-knee 2 --ramp-knee-floor 1.5";;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
# by command line, not name (renamed Megalon threads; m4-lib.sh VDB_PROCS); any non-"0" answer counts as running
servers_gone() { for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip 'pgrep -c -f "[/]bin/vdb-server( |\$)"' < /dev/null)" = 0 ] || return 1; done; }
# /dev/dax0.0 unused on both guests (sudo -n fuser prints nothing, rc 1; anything else = in use, fail closed)
dax_unused() {
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'f=$(sudo -n fuser /dev/dax0.0 2>&1); r=$?; echo "dax_users=[$f] rc=$r"' < /dev/null 2>&1)
    echo "$(date -Is) $NAME $ip $out" >> "$E/dax-users.txt"
    [ "$out" = "dax_users=[] rc=1" ] || return 1
  done
}
echo "$(date -Is) $NAME: SYS=$SYS U=$U KIND=$KIND URATE=${URATE:-} URATE_START=${URATE_START:-} DATASET=${DATASET:-28m} REP=${REP:-} TRACE=$TRACE RATE=${RATE:-} RECV_MODE=${RECV_MODE:-} SEED=$SEED V=$V HOST_SERVER=$HOST_SERVER XENV=[$XENV] XARGS=[$XARGS] OPCOH_EXPECT=${OPCOH_EXPECT:-} OPCOH_CHECK_MODE=${OPCOH_CHECK_MODE:-}"
servers_gone || stop "a vdb-server is running before the run"
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed for KIND=functional only"
if [ "${GATE:-1}" = 1 ]; then  # H1 measurement runs: experiments/h1/h1-gate.sh (README item 8); validation: host-gate.sh
  if [ "${H1_MEASURE_RUN:-0}" = 1 ]; then
    [ -n "${MEASURE_PART_DIR:-}" ] || stop "H1_MEASURE_RUN=1 needs MEASURE_PART_DIR"
    bash $P/CXL_SWMC/experiments/h1/h1-gate.sh check "$E/gate-$NAME.txt" || stop "H1 gate"
  else bash $X/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # P-popcorn-deploy §6a cycle (bundle C8, build >= 8; init_state=shared)
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  SHM=0  # 1 from the load attempt until a successful teardown: any exit in between tears down (EXIT trap)
  shm_down() {
    [ $SHM = 1 ] || return 0
    servers_gone || { echo "M4RUN $NAME: servers still running, teardown skipped (manual: packet rollback)"; return 1; }
    dax_unused || { echo "M4RUN $NAME: /dev/dax0.0 still in use, teardown skipped (manual: packet rollback; see dax-users.txt)"; return 1; }
    env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown && SHM=0
  }
  trap 'shm_down' EXIT
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  dax_unused || stop "/dev/dax0.0 in use before the cxl_shm load (see $E/dax-users.txt)"
  SHM=1
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one (both must exist)
    [ "$($SSH comsys@$ip "test -f $V/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $V/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s) PIDF=$V/runs/preload-$NAME.pid PT=${PRELOAD_TIMEOUT_S:-1200}
  [[ $PT =~ ^[0-9]+$ ]] || stop "bad PRELOAD_TIMEOUT_S"
  echo "guest=${IPS[0]} pidfile=$PIDF timeout_s=$PT" > "$E/preload-$NAME.pid"
  # the remote shell writes its pid, then execs timeout (same pid), which runs the preload and forwards TERM to it
  $SSH comsys@${IPS[0]} "mkdir -p $V/runs && echo \$\$ > $PIDF && exec timeout -k 30 $PT env CXL_REGION_CONFIG=$V/cfg/cxl_region.yaml $V/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
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
  for k in 0 1; do  # Popcorn instrumentation (build >= 8) must be on (per-thread and window counters)
    grep -qx "instr_enabled=1" "$E/shm-$NAME/status-pre-vm$k.txt" || stop "instr_enabled != 1 on vm$k (status pre)"
  done
fi
bash $X/run.sh "$NAME" "$E" -- "${LG[@]}"
RC=$?
LEVELS=0; [ "$KIND" = h1 ] && [ $RC = 5 ] && LEVELS=1
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
[ $LEVELS = 0 ] || stop "LEVELS STOP (rates command failed inside the lifetime; servers stopped, see $R/manifest.txt)"
if [ -n "${OPCOH_EXPECT:-}" ]; then  # per-operation time split (vdb build >= 10, DESIGN.md §15)
  for k in 0 1; do
    grep -q "^vdb-server: op coherence on," $R/node$k.log || stop "node$k: op coherence not on"
    case $OPCOH_EXPECT in
      swmc_acct) grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $R/node$k.log || stop "node$k: popcorn source != swmc_acct";;
      cohsnap) grep -qE "^vdb-server: op coherence on, .*megalon cohsnap on," $R/node$k.log || stop "node$k: megalon cohsnap not on";;
    esac
    { grep -qx "opcoh.read_errors=0" $R/node$k.log && grep -qx "opcoh.register_errors=0" $R/node$k.log; } || stop "node$k: opcoh read/register errors"
  done
fi
# per loadgen output dir checks (KIND=h1: per part dir; closure of opcoh_check over every part of the lifetime)
PDIRS=$R; [ "$KIND" = h1 ] && PDIRS=$(for p in $H1_PARTS; do echo -n "$R/$p "; done)
[ "$KIND" = urate ] && PDIRS="$R/warm $R/slo"
NOTES=""
for RP in $PDIRS; do
  [ -s $RP/loadgen/summary.json ] || stop "no loadgen output in $RP (lifetime stopped early?)"
  # writes file exhausted: loadgen ends fill/overload silently (note "") or notes "streams exhausted"; both are a STOP
  ! grep -q '"reason":"stream [a-z]* exhausted' $RP/loadgen/steps.jsonl || stop "writes file exhausted in $RP (stream exhausted; packet: bigger writes file needs a dataset decision)"
  if [ -n "${OPCOH_EXPECT:-}" ]; then
    { grep -qx "ok_without_coh=0" $RP/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $RP/loadgen/vectordb.txt &&
      grep -qx "bad_coh_version=0" $RP/loadgen/vectordb.txt; } || stop "responses without an op coherence block ($RP)"
    python3 $X/opsplit.py $RP > $RP/opsplit.log 2>&1 || stop "opsplit.py failed (see $RP/opsplit.log)"
    if [ -n "${OPCOH_CHECK_MODE:-}" ]; then
      OPCOH_PARTS="$PDIRS" python3 $P/CXL_SWMC/workloads/vectordb/tests/opcoh_check.py $RP $OPCOH_CHECK_MODE > $RP/opcoh-check.txt 2>&1
      grep -q "^OPCOH_CHECK PASS" $RP/opcoh-check.txt || stop "opcoh_check $OPCOH_CHECK_MODE (see $RP/opcoh-check.txt)"
    fi
  fi
  python3 $X/e1_check.py --writes $W --na $NA --nb $NB --searches $RP/loadgen/searches.bin --out $RP/e1 --sample 500 > /dev/null \
    || stop "E1 violation (see $RP/e1.e1.txt)"
  grep -q "workload_finish\":\"ok" $RP/loadgen/summary.json || stop "loadgen workload finish ($RP)"
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $RP/loadgen/summary.json 2>/dev/null)
  if [ -n "$note" ] && [ "$KIND" = urate ] && [ "${RP##*/}" = slo ]; then  # knee ramp: every note is a result
    NOTES="$NOTES ${RP##*/}: $note"
  elif [ -n "$note" ]; then
    { [[ $KIND =~ ^p?slo$ ]] || { [ "$KIND" = h1 ] && [ "${RP##*/}" = slo ]; }; } \
      && [ "$note" = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" ] || stop "loadgen note ($RP): $note"
    NOTES="$NOTES ${RP##*/}: $note"
  fi
  if [ "$KIND" = h1 ] && [ "${RP##*/}" = fix ]; then  # the two measured fixed steps: L2 then L1
    python3 -I - $RP/loadgen/steps.jsonl > $RP/h1-steps.txt <<'PY' || stop "fix part steps ($RP)"
import json, sys
st = [s for s in map(json.loads, open(sys.argv[1])) if s.get("measure_s", 0) > 0 and s.get("phase") == "fixed"]
assert len(st) == 2, f"{len(st)} measured fixed steps"
print(f"{st[0]['step']},{st[1]['step']}")
PY
  fi
done
if [ $RC != 0 ] && [ -z "$NOTES" ]; then stop "run.sh rc $RC"; fi
[ "$KIND" = functional ] && ! grep -q '"pass":true' $R/loadgen/steps.jsonl && stop "functional step not PASS"
if [ -n "$NOTES" ]; then echo "M4RUN $NAME NOTE${NOTES}"; else echo "M4RUN $NAME OK"; fi

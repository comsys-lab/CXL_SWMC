#!/bin/bash
# One recommendation-system pilot run (reports/RECSYS-design.md §8, MOT1 v5 pilots): Host gate, system setup,
# run.sh (PROFILE=pilot), post checks. Synthetic ids (workspaces/recsys-data/pilot), 10.0 GiB of slots (--row-div 9),
# random weights. Every system runs on the page MSI kernel (build 8); all-HWcc and Megalon with cxl_shm unloaded.
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon | Popcorn), T_MS (publication interval: 60000 | 1000 | 0),
#   KIND (functional | slo | fixed); KIND=fixed: RATE (query/s = L)
#   SYS=Popcorn: C8 (build-8 deploy bundle dir), K8 (release), GT8 (guest tools dir), RECV_MODE (poll | idle | sleep);
#     /dev/dax0.0 must be root:root 600 (p-popcorn-shm.sh precheck; its teardown restores it)
#   SYS=all-HWcc / Megalon: /dev/dax0.0 owned by comsys (the block chowns it)
#   SYS=Megalon: VM_MEG (guest install dir, default /home/comsys/rsm4), HOST_MEG (default builds/recsys-megalon/4)
# optional: SEED (default 20261016), GATE=0 (skip the Host gate; refused unless KIND=functional), UPD_RATE (default 2100).
# SLO: query p95 <= 100 ms (MOT1 v6, DeepRecSys ISCA'20; reports/MOT1-v6-sources.md §1).
# KIND=functional checks the invariants only (clean stop, torn rows 0, misses 0, no bad requests, loadgen finish ok);
# its p95 is recorded in <run>/functional-slo.txt but a step over 100 ms does not stop the block.
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP (the sequence stops).
set -uo pipefail
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/recsys
: "${SYS:?}" "${T_MS:?}" "${KIND:?}"
SEED=${SEED:-20261016} UPD_RATE=${UPD_RATE:-2100}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
servers_gone() { for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip 'pgrep -c -x recsys-server' < /dev/null)" = 0 ] || return 1; done; }
SHM=0  # page MSI: 1 from the load attempt until a successful teardown; any exit in between tears down (EXIT trap)
shm_down() {
  [ $SHM = 1 ] || return 0
  servers_gone || { echo "PILOTRUN $NAME: servers still running, teardown skipped (block_finish retries)"; return 1; }
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown && SHM=0
}
stop() { echo "PILOTRUN $NAME STOP $*"; exit 1; }
trap 'shm_down' EXIT
trap 'echo "PILOTRUN $NAME STOP interrupted"; exit 130' INT TERM HUP
[ -d "$E" ] || stop "missing evidence dir $E"
[ -e "$E/$NAME" ] && stop "$E/$NAME exists"
[[ $T_MS =~ ^(60000|10000|1000|100|0)$ ]] || stop "bad T_MS"
D=$P/workspaces/recsys-data/pilot
SA="--nodes 2 --row-div 9 --serve-threads 14 --update-threads 4 --load-threads 8 --start-timeout-ms 5400000
 --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
SA=$(echo $SA)
export LOADGEN=$P/builds/recsys-loadgen/1/loadgen READY_TIMEOUT=5400 RUN_KIND=measurement STATS_OP=10 PROFILE=pilot T_MS
[ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
VM_MEG=${VM_MEG:-/home/comsys/rsm4} HOST_MEG=${HOST_MEG:-$P/builds/recsys-megalon/4}
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc V=/home/comsys/rs3 HOST_SERVER=$P/builds/recsys/3/bin/recsys-server SERVER_ARGS="$SA";;
  Megalon) export SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$HOST_MEG/bin/recsys-server SERVER_ARGS="--backend megalon $SA" \
             NODE_ENV="ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=14400" NODE0_ENV="ENV:MEGALON_REINIT=1";;
  Popcorn) : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
           [[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || stop "bad RECV_MODE"
           export SYSTEM=Popcorn-$RECV_MODE V=/home/comsys/rs3 HOST_SERVER=$P/builds/recsys/3/bin/recsys-server \
             SERVER_ARGS="$SA" NODE0_ARGS="--preloaded";;
  *) stop "bad SYS";;
esac
LG=(--opt samples=$D/updates-zipf105-s1-2M.smp --opt queries=$D/queries-zipf105-s2-1M.smp
    --opt quantiles=$D/dist_quantile.txt --opt seed=$SEED --seed "$SEED" --fixed update=$UPD_RATE --mix query=1
    --slo query:95:100 --x-stream query)
case "$KIND" in
  functional) LG+=(--mode fixed --rates 1 --step-warmup-s 5 --step-measure-s 30 --drain-s 30);;
  slo) LG+=(--raw --mode slo --start 1 --factor 1.5 --precision 0.05 --max-steps 20);;
  fixed) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
echo "$(date -Is) $NAME: SYS=$SYS T_MS=$T_MS KIND=$KIND RATE=${RATE:-} RECV_MODE=${RECV_MODE:-} SEED=$SEED UPD_RATE=$UPD_RATE V=$V"
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed only for KIND=functional"
servers_gone || stop "a recsys-server is running before the run"
if [ "${GATE:-1}" = 1 ]; then bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # P-popcorn-deploy §6a cycle with build 8 (init_state=shared), as vectordb m4-run.sh
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  SHM=1
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one (both must exist)
    [ "$($SSH comsys@$ip "test -f $V/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $V/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)  # node 0 writes the initial tables through a plain mapping before coherence is enabled (no HWcc access)
  PD=$V/runs/preload-$NAME-$(date +%s)  # guest dir with node0.pid: the block's stop_servers can stop the preload
  echo "$PD" > "$E/preload-$NAME.dir"
  $SSH comsys@${IPS[0]} "mkdir -p $PD && CXL_REGION_CONFIG=$V/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $PD/node0.pid; exec $V/bin/recsys-server --node 0 --preload-only $SA --publish-ms $T_MS'" \
    < /dev/null > "$E/preload-$NAME.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$NAME.log"
  { grep -q "PRELOAD DONE" "$E/preload-$NAME.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || stop "enable gate"
  for ip in "${IPS[@]}"; do  # recv_mode (runtime-writable) and the instrumentation switch must be as required
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled" < /dev/null)
    echo "$ip recv_mode=$m instr_enabled=$i" >> "$E/recv-mode-$NAME.txt"
    [ "$m" = "$RECV_MODE" ] || stop "recv_mode on $ip = $m"
    [ "$i" = 1 ] || stop "instr enabled on $ip = $i"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || stop "status pre"
fi
bash $X/run.sh "$NAME" "$E" -- "${LG[@]}"
RC=$?
if [ "$SYS" = Popcorn ]; then
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status
  servers_gone || stop "servers left (page MSI teardown not attempted)"
  shm_down || stop "shm teardown"
fi
servers_gone || stop "servers left"
R=$E/$NAME
[ -d "$R" ] || stop "no run dir"
for k in 0 1; do  # invariants (every kind): clean stop and the workload's own checks
  L=$R/node$k.log
  grep -q "recsys-server: stopping" $L || stop "node$k: no clean stop"
  for kv in torn_rows=0 misses=0 update_misses=0 bad_requests=0; do grep -q "^$kv\$" $L || stop "node$k: $kv violated"; done
done
grep -h "^flush_overruns=\|^published_seq=\|^samples=\|^rows_written=" $R/node0.log > $R/updater.txt
{ echo "# load times $NAME (s)"; echo "run_wall_s=$(( $(date +%s) - T0 ))"
  [ -f "$E/preload-$NAME.log" ] && grep -h "PRELOAD DONE\|preload_wall_s\|initial tables" "$E/preload-$NAME.log"
  grep -h "initial tables\|created .* objects\|warm-up read\|preloaded\|READY node" $R/node*.log
  grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
grep -q 'workload_finish":"ok' $R/loadgen/summary.json || stop "loadgen workload finish"
if [ "$KIND" = functional ]; then  # SLO outcome recorded, not an invariant (run.sh must still have succeeded)
  [ $RC = 0 ] || stop "run.sh rc $RC"
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l); q=d["streams"]["query"]; u=d["streams"]["update"]
    if d.get("step",0) > 0: print("step", d["step"], "pass", d["pass"], "query_p99_ms", q["p99_ms"], "query/s", q["achieved"], "update/s", u["achieved"])' \
    $R/loadgen/steps.jsonl > $R/functional-slo.txt
  grep -q "pass True" $R/functional-slo.txt && { echo "PILOTRUN $NAME OK"; exit 0; }
  echo "PILOTRUN $NAME NOTE functional SLO step failed at 1 query/s: $(tr '\n' ' ' < $R/functional-slo.txt)"; exit 0
fi
if [ $RC != 0 ]; then
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [ "$KIND" = slo ] && [ -n "$note" ] && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
echo "PILOTRUN $NAME OK"

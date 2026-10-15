#!/bin/bash
# One KV store run on the 2 VMs (workloads/kv): start a kv-server per VM, drive both from the Host with loadgen (kv
# plugin), stop, collect. Modelled on experiments/vectordb/run.sh. Writes an immutable result dir <out_root>/<name>/
# (manifest.txt, loadgen/, node<k>.{log,env}, host-check.txt, port-check.txt, guest-cpu.txt, steps.csv, ...).
# usage: run.sh <name> <out_root> -- <loadgen args (mode, rates/SLO, --mix get=..,put=.., --opt keys=N ...)>
# env (required): SYSTEM (label: all-HWcc | page-MSI | Megalon), V (guest install dir: bin/kv-server, bin/kv-node.sh,
#   lib/ (libkv-megalon.so + the Megalon build's libraries), cfg/cxl_region.yaml, cfg/megalon.yaml), HOST_SERVER (Host
#   kv-server of the same build: --print-app-bytes / --print-sizes), LOADGEN (loadgen with the kv plugin),
#   SERVER_ARGS (identical on every node; must contain --keys N and --backend plain|megalon).
# optional: NODES (192.168.122.100 192.168.122.101), PORT (7100), LG_CPUS (56-63), READY_TIMEOUT (3600 s: initial load
#   + warm-up), RUN_KIND (measurement [default] | functional: a Host build is recorded, not fatal), NODE_ENV / NODE0_ENV
#   (extra ENV:K=V tokens; RACKOBJ_CONFIG=$V/cfg/megalon.yaml for every node and MEGALON_REINIT=1 for node 0 are always
#   passed: both backends run Megalon's KV library), SERVER_CPUS (guest CPU list; every kv-server thread pinned after
#   READY and verified), TRACE (0; 1 adds --trace-dir <guest run dir>: per-put and per-get logs node<k>.kv-*.bin for
#   MOT1 H2 Figure 2c, fixed-load runs only, never SLO searches), STATS_OP (10 = kv kOpStats; 0 = off).
# Checks before starting: --opt keys=N equals --keys N; the guests' cfg/megalon.yaml has key_space/slots/
#   logical_scr_size equal to `kv-server --print-sizes --keys N` (read-only).
# Stops (and stops the servers) on the first error. Measurement hygiene: no Host build before/after (pgrep).
set -euo pipefail
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7100} LG_CPUS=${LG_CPUS:-56-63} TRACE=${TRACE:-0} STATS_OP=${STATS_OP:-10}
[[ $TRACE =~ ^[01]$ ]] && [[ $STATS_OP =~ ^[0-9]+$ ]] || { echo "bad TRACE/STATS_OP"; exit 2; }
[ -z "${SERVER_CPUS:-}" ] || [[ $SERVER_CPUS =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "bad SERVER_CPUS"; exit 2; }
KEYS=$(sed -n 's/.*--keys \([0-9][0-9]*\).*/\1/p' <<< " $SERVER_ARGS ")
[ -n "$KEYS" ] || { echo "SERVER_ARGS must contain --keys N"; exit 2; }
grep -qE -- "--backend (plain|megalon)( |$)" <<< "$SERVER_ARGS" || { echo "SERVER_ARGS must contain --backend plain|megalon"; exit 2; }
okeys=""; prev=""; for a in "$@"; do [ "$prev" = --opt ] && case "$a" in keys=*) okeys=${a#keys=};; esac; prev=$a; done
[ "$okeys" = "$KEYS" ] || { echo "loadgen --opt keys=$okeys != kv-server --keys $KEYS"; exit 2; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
RUN=$OUT/$NAME
[ -e "$RUN" ] && { echo "refusing: $RUN exists (results are immutable)"; exit 3; }
mkdir -p "$RUN"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)

host_check() {  # any compiler/linker/build tool running on the Host invalidates a measurement
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $1 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RUN/host-check.txt"
  [ -z "$p" ] || [ "${RUN_KIND:-measurement}" = functional ] || { echo "Host build running ($1): $p"; return 1; }
}
STARTED=()  # node indices this run started (only these are stopped/collected)
stop_nodes() {
  local w=15; [ "$TRACE" = 1 ] && w=300  # trace logs are written at stop
  for k in "${STARTED[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/kv-node.sh stop $GRUN $k $w" < /dev/null || true; done
}
collect() {
  for k in "${STARTED[@]}"; do scp -q "comsys@${NODE[$k]}:$GRUN/node$k.*" "$RUN/" 2>/dev/null || true; done
}
trap 'echo "run $NAME: error, stopping servers"; stop_nodes; collect' ERR
trap 'echo "run $NAME: interrupted, stopping servers"; stop_nodes; collect; exit 130' INT TERM HUP

host_check before
RID=0x$(openssl rand -hex 4)$(printf '%08x' $(( (RANDOM << 16 | RANDOM) | 1 )))
GRUN=$V/runs/$NAME-${RID#0x}  # fresh guest dir per run (never reuses an earlier attempt's files)
# shellcheck disable=SC2086
APP=$("$HOST_SERVER" $SERVER_ARGS --print-app-bytes)
SIZES=$("$HOST_SERVER" --print-sizes --keys "$KEYS")
want_cfg=$(grep -E '^(key_space|slots|logical_scr_size)=' <<< "$SIZES" | tr '=' ' ' | sort)
for k in "${!NODE[@]}"; do  # the guest's Megalon config must have been made for this key count
  got=$($SSH comsys@"${NODE[$k]}" "grep -E '^(key_space|slots|logical_scr_size):' $V/cfg/megalon.yaml | sed 's/#.*//; s/: */ /; s/ *\$//'" < /dev/null | sort)
  [ "$got" = "$want_cfg" ] || { printf 'node%s cfg/megalon.yaml does not match --keys %s:\n%s\nwant:\n%s\n' "$k" "$KEYS" "$got" "$want_cfg"; exit 4; }
done
{ echo "# kv run (CXL_SWMC/experiments/kv/run.sh)"; echo "name=$NAME"; echo "system=$SYSTEM"
  echo "start=$(date -Is)"; echo "run_kind=${RUN_KIND:-measurement}"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"
  echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"; echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "node_env=${NODE_ENV:-} node0_env=${NODE0_ENV:-}"; echo "app_hwcc_bytes=$APP"
  echo "keys=$KEYS"; sed 's/^/megalon_sizes./' <<< "$SIZES"; echo "loadgen_args=$*"
  echo "lg_cpus=$LG_CPUS"; echo "trace=$TRACE stats_op=$STATS_OP"
  [ -z "${SERVER_CPUS:-}" ] || echo "server_cpus=$SERVER_CPUS"
  for k in "${!NODE[@]}"; do
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/kv-server $V/bin/kv-node.sh $V/cfg/cxl_region.yaml $V/cfg/megalon.yaml $V/lib/libkv-megalon.so $V/lib/libmegalon.so | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
    [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
    echo "node$k=${NODE[$k]} $info"
  done
  for d in cxl_vm0 cxl_vm1; do
    x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null) || x=""
    [ -n "$x" ] && echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -d' ' -f1)" || echo "vm_xml_error.$d=virsh failed"
  done
} > "$RUN/manifest.txt"

for k in "${!NODE[@]}"; do
  EXTRA=""; XE="ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml ${NODE_ENV:-}"; [ "$k" = 0 ] && XE="$XE ENV:MEGALON_REINIT=1 ${NODE0_ENV:-}"
  [ "$TRACE" = 1 ] && EXTRA="--trace-dir $GRUN"
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "$V/bin/kv-node.sh start $V $GRUN $k $RID $APP $XE $SERVER_ARGS --port $PORT $EXTRA" < /dev/null
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/kv-node.sh ready $GRUN $k ${READY_TIMEOUT:-3600}" < /dev/null; done
server_cpus() {  # $1 = set|check: pin (set) and verify every kv-server thread of this run's session on each node
  for k in "${!NODE[@]}"; do
    $SSH comsys@"${NODE[$k]}" "set -e; S=\$(cat $GRUN/node$k.pid); P=\$(pgrep -u comsys -x -s \$S kv-server)
      [ \$(echo \"\$P\" | wc -w) = 1 ] || { echo \"kv-server pids in session \$S: [\$P]\"; exit 1; }
      [ $1 = set ] && taskset -a -c -p $SERVER_CPUS \$P > /dev/null
      L=\$(taskset -a -c -p \$P); echo \"$1 \$(date -Is) session=\$S pid=\$P threads=\$(echo \"\$L\" | wc -l)\"; echo \"\$L\"
      [ \$(echo \"\$L\" | grep -cv ': $SERVER_CPUS\$') = 0 ] || { echo 'affinity mismatch'; exit 1; }" \
      < /dev/null >> "$RUN/node$k.server-cpus.txt" || { echo "node$k server_cpus $1 failed (see node$k.server-cpus.txt)"; return 1; }
    grep "^$1 " "$RUN/node$k.server-cpus.txt" | tail -1 | sed "s/^/node$k server_cpus /"
  done
}
[ -z "${SERVER_CPUS:-}" ] || server_cpus set
for k in "${!NODE[@]}"; do  # port check: guest listen state + Host TCP connect (fails the run)
  l=$($SSH comsys@"${NODE[$k]}" "ss -ltn | awk '\$4 ~ /:$PORT\$/ {print \$4}'" < /dev/null)
  if timeout 3 bash -c "exec 3<>/dev/tcp/${NODE[$k]}/$PORT" 2>/dev/null; then c=OK; else c=FAILED; fi
  echo "node$k ${NODE[$k]} listen=[$l] host_connect=$c" | tee -a "$RUN/port-check.txt"
  [ -n "$l" ] && [ "$c" = OK ] || { echo "port check failed for node$k"; false; }
done

cpu_snap() {  # guest CPU time counters (/proc/stat "cpu" line) per node, for busy-fraction over the loadgen run
  for k in "${!NODE[@]}"; do echo "$1 node$k $($SSH comsys@"${NODE[$k]}" 'head -1 /proc/stat' < /dev/null)"; done >> "$RUN/guest-cpu.txt"
}
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}  # target order = node order (put writer = target)
cpu_snap before
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
set +e
numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload kv --target "$TARGETS" --out "$RUN/loadgen" \
  "${LG_STATS[@]}" "$@" 2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
[ -z "${SERVER_CPUS:-}" ] || server_cpus check
cpu_snap after
stop_nodes
collect
host_check after
echo "end=$(date -Is) loadgen_rc=$LG" >> "$RUN/manifest.txt"
if [ -s "$RUN/loadgen/steps.jsonl" ] && [ -s "$RUN/loadgen/summary.json" ]; then
  [ ! -d "$RUN/loadgen/stats" ] || python3 "$ROOT/experiments/loadgen/stats_delta.py" "$RUN/loadgen" --out "$RUN/stats-steps.csv" || true
  python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
[ "$TRACE" = 1 ] && { python3 "$ROOT/workloads/kv/tools/kvlog.py" check "$RUN" > "$RUN/kvlog-check.txt" 2>&1 || true; tail -1 "$RUN/kvlog-check.txt"; }
grep -h "kv-server: stopping" -A20 "$RUN"/node*.log | grep -E "^(node|gets|puts|misses|short_reads|bad_requests)=" | tr '\n' ' '; echo
[ -f "$RUN/loadgen/kv.txt" ] && grep -E "^(checked|remote_values|misses|torn|wrong_key|future|stale)=" "$RUN/loadgen/kv.txt" | tr '\n' ' ' && echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
echo "run $NAME: OK -> $RUN"

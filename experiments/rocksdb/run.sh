#!/bin/bash
# One RocksDB run on N VMs (workloads/rocksdb; N = number of NODES): start a rocksdb-server per VM (every node builds
# its own fresh image at start: keys i with i mod N == node, ingested into its own DB), drive all of them from the
# Host with loadgen (rocksdb plugin; request targets uniform over the N VMs, so every VM gets the same request rate),
# verify every node, stop, collect, check. Modelled on experiments/lmdb/run.sh (single part per lifetime).
# Writes an immutable result dir <out_root>/<name>/ (manifest.txt, loadgen/, node<k>.{log,env}, verify-node<k>.txt,
# host-check.txt, port-check.txt, guest-cpu.txt, steps.csv, stats-steps.csv, opsplit.csv, check.txt, ...).
# usage: run.sh <name> <out_root> -- <loadgen args (mode, rates/SLO, --mix mixed=1 --opt update_ratio=R
#        --opt keys=N ...)>
# env (required): SYSTEM (label: all-HWcc | Popcorn), V (guest install dir: bin/rocksdb-server, bin/rocksdb-node.sh,
#   cfg/cxl_region.yaml), HOST_SERVER (Host rocksdb-server of the same build: --print-app-bytes), LOADGEN (loadgen with
#   the rocksdb plugin), SERVER_ARGS (identical on every node; must contain --keys N and --nodes N = number of NODES).
# optional: NODES (192.168.122.100 192.168.122.101; order = node id), PORT (7200), LG_CPUS (56-63), READY_TIMEOUT (7200 s:
#   image build), RUN_KIND (measurement | functional: a Host build is recorded, not fatal), NODE_ENV (extra ENV:K=V
#   tokens for every node), SERVER_CPUS (guest CPU list; every rocksdb-server thread pinned after READY and verified),
#   STATS_OP (10; 0 = off), VERIFY (1), PER_VM_RATES (r1,r2,..: fixed-rate steps given per VM; the harness passes
#   --mode fixed --rates N*r1,N*r2,..), STOP_EXTENTS_FREE (2048 = 2 GiB of file extents) / STOP_BLOCKS_FREE (16):
#   pool floors that every stats snapshot of every node must keep (DESIGN.md §9 MED-5; a lower value FAILS the run).
# Pass criteria (check.txt, DESIGN.md §9): loadgen rc 0 (plugin: no stale/bad/not-found/error), verify of every node,
# check_log (log=1), and on every node at stop: remote_errors = get_errors = update_errors = get_retry_limit =
# remoteN.errors = remoteN.catchup_errors = 0, pools floors in every snapshot.
# Measurement hygiene: no Host build before/after (pgrep). Stops (and stops the servers) on the first error.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
N=${#NODE[@]}
PORT=${PORT:-7200} LG_CPUS=${LG_CPUS:-56-63} STATS_OP=${STATS_OP:-10} VERIFY=${VERIFY:-1}
STOP_EXTENTS_FREE=${STOP_EXTENTS_FREE:-2048} STOP_BLOCKS_FREE=${STOP_BLOCKS_FREE:-16}
[[ $STATS_OP =~ ^[0-9]+$ ]] && [[ $VERIFY =~ ^[01]$ ]] || { echo "bad STATS_OP/VERIFY"; exit 2; }
[ -z "${SERVER_CPUS:-}" ] || [[ $SERVER_CPUS =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "bad SERVER_CPUS"; exit 2; }
KEYS=$(sed -n 's/.* --keys \([0-9][0-9]*\).*/\1/p' <<< " $SERVER_ARGS ")
[ -n "$KEYS" ] || { echo "SERVER_ARGS must contain --keys N"; exit 2; }
SN=$(sed -n 's/.* --nodes \([0-9][0-9]*\).*/\1/p' <<< " $SERVER_ARGS ")
[ "$SN" = "$N" ] || { echo "SERVER_ARGS --nodes $SN != number of NODES $N"; exit 2; }
grep -qE -- "--backend megalon" <<< "$SERVER_ARGS" && { echo "this harness runs the plain backend (all-HWcc, Popcorn)"; exit 2; }
okeys=""; prev=""; for a in "$@"; do [ "$prev" = --opt ] && case "$a" in keys=*) okeys=${a#keys=};; esac; prev=$a; done
[ "$okeys" = "$KEYS" ] || { echo "loadgen --opt keys=$okeys != rocksdb-server --keys $KEYS"; exit 2; }
RATE_ARGS=()
if [ -n "${PER_VM_RATES:-}" ]; then  # same request rate on every VM: total = N x per-VM rate
  tot=$(tr ',' '\n' <<< "$PER_VM_RATES" | awk -v n="$N" '{printf "%s%.3f", (NR > 1 ? "," : ""), $1 * n}')
  RATE_ARGS=(--mode fixed --rates "$tot")
fi
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
RUN=$OUT/$NAME
[ -e "$RUN" ] && { echo "refusing: $RUN exists (results are immutable)"; exit 3; }
mkdir -p "$RUN"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); W=$ROOT/workloads/rocksdb
host_check() {  # any compiler/linker/build tool running on the Host invalidates a measurement
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $1 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RUN/host-check.txt"
  [ -z "$p" ] || [ "${RUN_KIND:-measurement}" = functional ] || { echo "Host build running ($1): $p"; return 1; }
}
STARTED=()
stop_nodes() { for k in "${STARTED[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/rocksdb-node.sh stop $GRUN $k 60" < /dev/null || true; done; }
collect() { for k in "${STARTED[@]}"; do scp -q "comsys@${NODE[$k]}:$GRUN/node$k.*" "$RUN/" 2>/dev/null || true; done; }
trap 'echo "run $NAME: error, stopping servers"; stop_nodes; collect' ERR
trap 'echo "run $NAME: interrupted, stopping servers"; stop_nodes; collect; exit 130' INT TERM HUP

host_check before
RID=0x$(openssl rand -hex 4)$(printf '%08x' $(( (RANDOM << 16 | RANDOM) | 1 )))
GRUN=$V/runs/$NAME-${RID#0x}
# app layout size from the layout parameters only
LAYOUT=$(grep -oE -- "--(nodes|keys|epoch-slots|max-files|max-ext|arena-blocks|file-extents) [0-9]+" <<< "$SERVER_ARGS" | tr '\n' ' ')
# shellcheck disable=SC2086
APP=$("$HOST_SERVER" --print-app-bytes $LAYOUT)
{ echo "# rocksdb run (CXL_SWMC/experiments/rocksdb/run.sh)"; echo "name=$NAME"; echo "system=$SYSTEM"; echo "nodes=$N"
  echo "start=$(date -Is)"; echo "run_kind=${RUN_KIND:-measurement}"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"
  echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"; echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "node_env=${NODE_ENV:-}"; echo "app_hwcc_bytes=$APP"; echo "keys=$KEYS"
  echo "loadgen_args=$* ${RATE_ARGS[*]}"; echo "per_vm_rates=${PER_VM_RATES:-}"; echo "lg_cpus=$LG_CPUS"
  echo "stats_op=$STATS_OP verify=$VERIFY stop_extents_free=$STOP_EXTENTS_FREE stop_blocks_free=$STOP_BLOCKS_FREE"
  echo "block_cache=per DB instance (primary + $((N - 1)) secondaries), RocksDB default 32 MiB each"
  [ -z "${SERVER_CPUS:-}" ] || echo "server_cpus=$SERVER_CPUS"
  for k in "${!NODE[@]}"; do
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/rocksdb-server $V/bin/rocksdb-node.sh $V/cfg/cxl_region.yaml | cut -c1-64; nproc; grep MemTotal /proc/meminfo" < /dev/null | tr '\n' ' ')
    [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
    echo "node$k=${NODE[$k]} $info"
  done
  for d in $(virsh -c qemu:///system list --all --name 2>/dev/null | grep '^cxl_vm[0-9]*$' || true); do
    x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null) || x=""
    [ -n "$x" ] && echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -d' ' -f1)" || echo "vm_xml_error.$d=virsh failed"
  done
} > "$RUN/manifest.txt"

for k in "${!NODE[@]}"; do
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "$V/bin/rocksdb-node.sh start $V $GRUN $k $RID $APP ${NODE_ENV:-} $SERVER_ARGS --port $PORT" < /dev/null
  [ "$k" = 0 ] && sleep 2  # node 0 initialises the app layout first
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/rocksdb-node.sh ready $GRUN $k ${READY_TIMEOUT:-7200}" < /dev/null; done
for k in "${!NODE[@]}"; do  # image build time per node (fresh image every run)
  $SSH comsys@"${NODE[$k]}" "grep -h 'rocksdb-server: IMAGE' $GRUN/node$k.log" < /dev/null | sed "s/^/node$k /" >> "$RUN/manifest.txt" || true
done
server_cpus() {  # $1 = set|check
  for k in "${!NODE[@]}"; do
    $SSH comsys@"${NODE[$k]}" "set -e; S=\$(cat $GRUN/node$k.pid); P=\$(pgrep -u comsys -x -s \$S rocksdb-server)
      [ \$(echo \"\$P\" | wc -w) = 1 ] || { echo \"rocksdb-server pids in session \$S: [\$P]\"; exit 1; }
      [ $1 = set ] && taskset -a -c -p $SERVER_CPUS \$P > /dev/null
      L=\$(taskset -a -c -p \$P); echo \"$1 \$(date -Is) session=\$S pid=\$P threads=\$(echo \"\$L\" | wc -l)\"; echo \"\$L\"
      [ \$(echo \"\$L\" | grep -cv ': $SERVER_CPUS\$') = 0 ] || { echo 'affinity mismatch'; exit 1; }" \
      < /dev/null >> "$RUN/node$k.server-cpus.txt" || { echo "node$k server_cpus $1 failed (see node$k.server-cpus.txt)"; return 1; }
    grep "^$1 " "$RUN/node$k.server-cpus.txt" | tail -1 | sed "s/^/node$k server_cpus /"
  done
}
[ -z "${SERVER_CPUS:-}" ] || server_cpus set
for k in "${!NODE[@]}"; do
  l=$($SSH comsys@"${NODE[$k]}" "ss -ltn | awk '\$4 ~ /:$PORT\$/ {print \$4}'" < /dev/null)
  if timeout 3 bash -c "exec 3<>/dev/tcp/${NODE[$k]}/$PORT" 2>/dev/null; then c=OK; else c=FAILED; fi
  echo "node$k ${NODE[$k]} listen=[$l] host_connect=$c" | tee -a "$RUN/port-check.txt"
  [ -n "$l" ] && [ "$c" = OK ] || { echo "port check failed for node$k"; false; }
done
cpu_snap() { for k in "${!NODE[@]}"; do echo "$1 node$k $($SSH comsys@"${NODE[$k]}" 'head -1 /proc/stat' < /dev/null)"; done >> "$RUN/guest-cpu.txt"; }
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}  # target order = node order
cpu_snap before
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
LGPRE=(); [ "${H1_MEASURE_RUN:-0}" = 1 ] && LGPRE=(bash "$ROOT/scripts/host/measure-run.sh" --)
echo "loadgen_launcher=${LGPRE[*]:-direct}" >> "$RUN/manifest.txt"
set +e
"${LGPRE[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload rocksdb --target "$TARGETS" --out "$RUN/loadgen" \
  "${LG_STATS[@]}" "$@" "${RATE_ARGS[@]}" 2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
[ -z "${SERVER_CPUS:-}" ] || server_cpus check
cpu_snap after
VRC=0
if [ "$VERIFY" = 1 ]; then  # scan of every node's DB after the load, before the stop
  for k in "${!NODE[@]}"; do
    python3 -I -B "$ROOT/workloads/lmdb/tools/lmdb_ctl.py" "${NODE[$k]}:$PORT" verify --expect verify.bad_values=0 \
      verify.misordered=0 verify.end=ok > "$RUN/verify-node$k.txt" 2>&1 || { VRC=1; echo "node$k verify FAILED"; }
    tr '\n' ' ' < "$RUN/verify-node$k.txt"; echo
  done
fi
stop_nodes
collect
host_check after
echo "end=$(date -Is) loadgen_rc=$LG verify_rc=$VRC" >> "$RUN/manifest.txt"
if [ -s "$RUN/loadgen/steps.jsonl" ] && [ -s "$RUN/loadgen/summary.json" ]; then
  if [ -d "$RUN/loadgen/stats" ]; then
    python3 -B "$ROOT/experiments/loadgen/stats_delta.py" "$RUN/loadgen" --out "$RUN/stats-steps.csv" || true
    python3 -I -B "$ROOT/workloads/kv/tools/opsplit.py" "$RUN/loadgen" --system "$SYSTEM" --out "$RUN/opsplit.csv" || true
  fi
  python3 -B "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  python3 -B "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
CRC=skip
if [ -s "$RUN/loadgen/gets.bin" ]; then  # loadgen --opt log=1: exact check
  CRC=0; python3 -I -B "$W/tools/check_log.py" "$RUN/loadgen" > "$RUN/check-log.txt" 2>&1 || CRC=$?
  echo "check_log rc=$CRC" >> "$RUN/check-log.txt"; tail -n 2 "$RUN/check-log.txt"
fi
KRC=0
python3 -I -B "$HERE/check-run.py" "$RUN" --nodes "$N" --keys "$KEYS" --stop-extents-free "$STOP_EXTENTS_FREE" \
  --stop-blocks-free "$STOP_BLOCKS_FREE" > "$RUN/check.txt" 2>&1 || KRC=$?
cat "$RUN/check.txt"
[ -f "$RUN/loadgen/rocksdb.txt" ] && tr '\n' ' ' < "$RUN/loadgen/rocksdb.txt" && echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
[ "$VRC" = 0 ] || { echo "run $NAME: verify failed"; exit 1; }
[ "$CRC" = skip ] || [ "$CRC" = 0 ] || { echo "run $NAME: check_log failed"; exit 1; }
[ "$KRC" = 0 ] || { echo "run $NAME: server checks failed (check.txt)"; exit 1; }
echo "run $NAME: OK -> $RUN"

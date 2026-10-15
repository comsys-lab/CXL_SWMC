#!/bin/bash
# One vectordb run on the 2 VMs: start a vdb-server per VM, drive it from the Host with loadgen, stop, collect.
# Writes an immutable result dir <out_root>/<name>/ (manifest.txt, loadgen/, node<k>.{log,env}, host-check.txt).
# usage: run.sh <name> <out_root> -- <loadgen args (mode, rates/SLO, --opt ...)>
# env (required): SYSTEM (label, e.g. all-HWcc), V (guest install dir), HOST_SERVER (Host vdb-server of the same
#   build, for --print-app-bytes), LOADGEN, SERVER_ARGS (identical on every node), INIT (initial segments dir on
#   node 0's guest); optional: NODES (default 192.168.122.100 192.168.122.101), PORT (7000), LG_CPUS (56-63),
#   RUN_KIND (measurement [default] | functional: correctness-only run; a Host build is recorded, not fatal —
#   CLAUDE.md allows builds during correctness-only runs only with the user's OK, given through the packet),
#   NODE_ENV (ENV:K=V tokens for every node), NODE0_ENV (extra tokens for node 0 only), e.g. for Megalon:
#   NODE_ENV="ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml" NODE0_ENV="ENV:MEGALON_REINIT=1".
#   SERVER_CPUS (unset = no change): guest CPU list (e.g. 0-14); after READY every vdb-server thread on every
#   node is pinned with taskset -a and verified; recorded in the manifest and node<k>.server-cpus.txt.
#   TRACE (default 1): vdb-server --trace-dir <guest run dir> (Megalon: write-section counter in HWcc + write-section
#   and retry logs, collected as node<k>.megalon-{wsec,retry}.bin; plain: nothing); TRACE=0 omits it.
#   STATS_OP (default 10 = vdb kOpStats): loadgen --stats-op, a server stats snapshot per node at the start and end of
#   every measured step (loadgen/stats/); STATS_OP=0 omits it. After the run: stats-steps.csv (stats_delta.py) and
#   steps.csv with the derived per-node columns (export_csv.py).
# Stops (and stops the servers) on the first error. Measurement hygiene: no Host build before/after (pgrep).
set -euo pipefail
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}" "${INIT:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7000} LG_CPUS=${LG_CPUS:-56-63} TRACE=${TRACE:-1} STATS_OP=${STATS_OP:-10}
[[ $TRACE =~ ^[01]$ ]] && [[ $STATS_OP =~ ^[0-9]+$ ]] || { echo "bad TRACE/STATS_OP"; exit 2; }
[ -z "${SERVER_CPUS:-}" ] || [[ $SERVER_CPUS =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "bad SERVER_CPUS"; exit 2; }
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
  for k in "${STARTED[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/vdb-node.sh stop $GRUN $k" < /dev/null || true; done
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
{ echo "# vectordb run (CXL_SWMC/experiments/vectordb/run.sh)"; echo "name=$NAME"; echo "system=$SYSTEM"
  echo "start=$(date -Is)"; echo "run_kind=${RUN_KIND:-measurement}"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"; echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "node_env=${NODE_ENV:-} node0_env=${NODE0_ENV:-}"; echo "app_hwcc_bytes=$APP"; echo "init=$INIT"; echo "loadgen_args=$*"
  echo "lg_cpus=$LG_CPUS"; echo "trace=$TRACE stats_op=$STATS_OP"
  [ -z "${SERVER_CPUS:-}" ] || echo "server_cpus=$SERVER_CPUS"
  for k in "${!NODE[@]}"; do
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/vdb-server $V/cfg/cxl_region.yaml \$(ls $V/lib/libvdb-megalon.so $V/lib/libmegalon.so $V/cfg/megalon.yaml 2>/dev/null) | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
    [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
    echo "node$k=${NODE[$k]} $info"
  done
  echo "init_sha256sums_sha256=$($SSH comsys@"${NODE[0]}" "sha256sum $INIT/SHA256SUMS | cut -d' ' -f1" < /dev/null)"
  for a in "$@"; do  # dataset provenance: every file named by --opt data=/writes=
    case "$a" in
      data=*) for f in pool_b.fbin queries.fbin; do echo "data_sha256.$f=$(sha256sum "${a#data=}/$f" | cut -d' ' -f1)"; done;;
      writes=*) echo "writes_sha256=$(sha256sum "${a#writes=}" | cut -d' ' -f1)";;
    esac
  done
  for d in cxl_vm0 cxl_vm1; do
    x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null) || x=""
    [ -n "$x" ] && echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -d' ' -f1)" || echo "vm_xml_error.$d=virsh failed"
  done
} > "$RUN/manifest.txt"

for k in "${!NODE[@]}"; do
  EXTRA=""; XE="${NODE_ENV:-}"; [ "$k" = 0 ] && EXTRA="--init-dir $INIT" && XE="$XE ${NODE0_ENV:-}"
  [ "$TRACE" = 1 ] && EXTRA="$EXTRA --trace-dir $GRUN"
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "$V/bin/vdb-node.sh start $V $GRUN $k $RID $APP $XE $SERVER_ARGS --port $PORT $EXTRA" < /dev/null
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/vdb-node.sh ready $GRUN $k ${READY_TIMEOUT:-300}" < /dev/null; done
server_cpus() {  # $1 = set|check: pin (set) and verify every vdb-server thread of this run's session on each node
  for k in "${!NODE[@]}"; do
    $SSH comsys@"${NODE[$k]}" "set -e; S=\$(cat $GRUN/node$k.pid); P=\$(pgrep -u comsys -x -s \$S vdb-server)
      [ \$(echo \"\$P\" | wc -w) = 1 ] || { echo \"vdb-server pids in session \$S: [\$P]\"; exit 1; }
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
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}
cpu_snap before
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
set +e
numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload vectordb --target "$TARGETS" --out "$RUN/loadgen" \
  "${LG_STATS[@]}" "$@" 2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
[ -z "${SERVER_CPUS:-}" ] || server_cpus check
cpu_snap after
stop_nodes
collect
host_check after
echo "end=$(date -Is) loadgen_rc=$LG" >> "$RUN/manifest.txt"
# spreadsheet/plot outputs, always (CSV: one row per step and stream; per-step counter deltas)
if [ -s "$RUN/loadgen/steps.jsonl" ] && [ -s "$RUN/loadgen/summary.json" ]; then
  [ ! -d "$RUN/loadgen/stats" ] || python3 "$ROOT/experiments/loadgen/stats_delta.py" "$RUN/loadgen" --out "$RUN/stats-steps.csv" || true
  python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
grep -h "vdb-server: stopping" -A30 "$RUN"/node*.log | grep -E "^(node|P|elements|updates|inserts|deletes|searches|timeouts|bad_records)=" | tr '\n' ' '; echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
echo "run $NAME: OK -> $RUN"

#!/bin/bash
# One vectordb run on the 2 VMs: start a vdb-server per VM, drive it from the Host with loadgen, stop, collect.
# Writes an immutable result dir <out_root>/<name>/ (manifest.txt, loadgen/, node<k>.{log,env}, host-check.txt).
# usage: run.sh <name> <out_root> -- <loadgen args (mode, rates/SLO, --opt ...)>
# env (required): SYSTEM (label, e.g. all-HWcc), V (guest install dir), HOST_SERVER (Host vdb-server of the same
#   build, for --print-app-bytes), LOADGEN, SERVER_ARGS (identical on every node), INIT (initial segments dir on
#   node 0's guest); optional: NODES (default 192.168.122.100 192.168.122.101), PORT (7000), LG_CPUS (56-63).
# Stops (and stops the servers) on the first error. Measurement hygiene: no Host build before/after (pgrep).
set -euo pipefail
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}" "${INIT:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7000} LG_CPUS=${LG_CPUS:-56-63}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
RUN=$OUT/$NAME
[ -e "$RUN" ] && { echo "refusing: $RUN exists (results are immutable)"; exit 3; }
mkdir -p "$RUN"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)

host_check() {  # any compiler/linker/build tool running on the Host invalidates a measurement
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $1 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RUN/host-check.txt"
  [ -z "$p" ] || { echo "Host build running ($1): $p"; return 1; }
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
  echo "start=$(date -Is)"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"; echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "app_hwcc_bytes=$APP"; echo "init=$INIT"; echo "loadgen_args=$*"
  echo "lg_cpus=$LG_CPUS"
  for k in "${!NODE[@]}"; do
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/vdb-server $V/cfg/cxl_region.yaml | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
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
  EXTRA=""; [ "$k" = 0 ] && EXTRA="--init-dir $INIT"
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "$V/bin/vdb-node.sh start $V $GRUN $k $RID $APP $SERVER_ARGS --port $PORT $EXTRA" < /dev/null
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/vdb-node.sh ready $GRUN $k 300" < /dev/null; done

cpu_snap() {  # guest CPU time counters (/proc/stat "cpu" line) per node, for busy-fraction over the loadgen run
  for k in "${!NODE[@]}"; do echo "$1 node$k $($SSH comsys@"${NODE[$k]}" 'head -1 /proc/stat' < /dev/null)"; done >> "$RUN/guest-cpu.txt"
}
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}
cpu_snap before
set +e
numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload vectordb --target "$TARGETS" --out "$RUN/loadgen" "$@" \
  2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
cpu_snap after
stop_nodes
collect
host_check after
echo "end=$(date -Is) loadgen_rc=$LG" >> "$RUN/manifest.txt"
# spreadsheet/plot outputs, always (CSV: one row per step and stream)
if [ -s "$RUN/loadgen/steps.jsonl" ] && [ -s "$RUN/loadgen/summary.json" ]; then
  python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
grep -h "vdb-server: stopping" -A30 "$RUN"/node*.log | grep -E "^(node|elements|inserts|deletes|searches|timeouts|bad_records)=" | tr '\n' ' '; echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
echo "run $NAME: OK -> $RUN"

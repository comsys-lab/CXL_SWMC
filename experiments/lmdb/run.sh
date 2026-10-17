#!/bin/bash
# One shared-LMDB run on the 2 VMs (workloads/lmdb): start an lmdb-server per VM (node 0 loads the initial image),
# drive both from the Host with loadgen (lmdb plugin), verify both nodes, stop, collect. Modelled on
# experiments/kv/run.sh. Writes an immutable result dir <out_root>/<name>/ (manifest.txt, loadgen/, node<k>.{log,env},
# verify-node<k>.txt, host-check.txt, port-check.txt, guest-cpu.txt, steps.csv, stats-steps.csv, opsplit.csv, ...).
# usage: run.sh <name> <out_root> -- <loadgen args (mode, rates/SLO, --mix mixed=1 --opt update_ratio=R
#        --opt records=N ...)>
# env (required): SYSTEM (label: all-HWcc | Megalon; Popcorn needs the preload path, see PRELOADED), V (guest install
#   dir: bin/lmdb-server, bin/lmdb-node.sh, cfg/cxl_region.yaml, [lib/ + cfg/megalon.yaml for the Megalon build]),
#   IMAGE (guest dir of the initial image on node 0: lmdb-image output), HOST_SERVER (Host lmdb-server of the same
#   build: --print-app-bytes), LOADGEN (loadgen with the lmdb plugin), SERVER_ARGS (identical on every node; must
#   contain --records N, --max-pages P and --backend plain|megalon; --readers/--get-threads as needed).
# optional: NODES (192.168.122.100 192.168.122.101), PORT (7100), LG_CPUS (56-63), READY_TIMEOUT (3600 s: prepare +
#   warm-up), RUN_KIND (measurement [default] | functional: a Host build is recorded, not fatal), NODE_ENV / NODE0_ENV
#   (extra ENV:K=V tokens; with --backend megalon RACKOBJ_CONFIG=$V/cfg/megalon.yaml for every node and
#   MEGALON_REINIT=1 for node 0 are always passed), NODE0_ARGS (extra node-0 args, e.g. --prepare-threads 8),
#   PRELOADED (0; 1 = node 0 gets --preloaded: the image is already in SWcc, Popcorn init_state=shared path),
#   SERVER_CPUS (guest CPU list; every lmdb-server thread pinned after READY and verified), STATS_OP (10; 0 = off),
#   VERIFY (1: verify op on both nodes after the load, expect entries = --records, no bad/misordered values).
# Stops (and stops the servers) on the first error. Measurement hygiene: no Host build before/after (pgrep).
# Multi-part lifetime (H1-HOOK v2): env PARTS="<part> ..." (e.g. "slo fix") and PART_ARGS_CMD (a script called as
#   `bash $PART_ARGS_CMD <part> <run dir>` after the servers are READY and before each part; it prints that part's extra
#   loadgen args, one per line; a non-zero exit stops the run: servers stopped, rc 1). Each part writes
#   <run>/<part>/{loadgen/,loadgen.log,stats-steps.csv,opsplit.csv,steps.csv,slo.png,slo-points.txt}; the common args
#   after -- are passed to every part. One server lifetime for all parts; node logs and manifest stay in <run>.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1  # never write __pycache__ (harness snapshots live in recovery/); every python3 call also has -B
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${IMAGE:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7100} LG_CPUS=${LG_CPUS:-56-63} STATS_OP=${STATS_OP:-10} VERIFY=${VERIFY:-1} PRELOADED=${PRELOADED:-0}
[[ $STATS_OP =~ ^[0-9]+$ ]] && [[ $VERIFY =~ ^[01]$ ]] && [[ $PRELOADED =~ ^[01]$ ]] || { echo "bad STATS_OP/VERIFY/PRELOADED"; exit 2; }
[ -z "${SERVER_CPUS:-}" ] || [[ $SERVER_CPUS =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "bad SERVER_CPUS"; exit 2; }
RECORDS=$(sed -n 's/.* --records \([0-9][0-9]*\).*/\1/p' <<< " $SERVER_ARGS ")
[ -n "$RECORDS" ] || { echo "SERVER_ARGS must contain --records N"; exit 2; }
grep -qE -- "--max-pages [0-9]+( |$)" <<< "$SERVER_ARGS" || { echo "SERVER_ARGS must contain --max-pages P"; exit 2; }
BACKEND=$(sed -n 's/.* --backend \(plain\|megalon\)\( .*\)\?$/\1/p' <<< " $SERVER_ARGS ")
[ -n "$BACKEND" ] || { echo "SERVER_ARGS must contain --backend plain|megalon"; exit 2; }
[ "$PRELOADED" = 0 ] || [ "$BACKEND" = plain ] || { echo "PRELOADED=1 is the plain (Popcorn) preload path"; exit 2; }
orec=""; prev=""; for a in "$@"; do [ "$prev" = --opt ] && case "$a" in records=*) orec=${a#records=};; esac; prev=$a; done
[ "$orec" = "$RECORDS" ] || { echo "loadgen --opt records=$orec != lmdb-server --records $RECORDS"; exit 2; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
RUN=$OUT/$NAME
[ -e "$RUN" ] && { echo "refusing: $RUN exists (results are immutable)"; exit 3; }
mkdir -p "$RUN"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); W=$ROOT/workloads/lmdb

host_check() {  # any compiler/linker/build tool running on the Host invalidates a measurement
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $1 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RUN/host-check.txt"
  [ -z "$p" ] || [ "${RUN_KIND:-measurement}" = functional ] || { echo "Host build running ($1): $p"; return 1; }
}
STARTED=()
stop_nodes() { for k in "${STARTED[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/lmdb-node.sh stop $GRUN $k 30" < /dev/null || true; done; }
collect() { for k in "${STARTED[@]}"; do scp -q "comsys@${NODE[$k]}:$GRUN/node$k.*" "$RUN/" 2>/dev/null || true; done; }
trap 'echo "run $NAME: error, stopping servers"; stop_nodes; collect' ERR
trap 'echo "run $NAME: interrupted, stopping servers"; stop_nodes; collect; exit 130' INT TERM HUP

host_check before
RID=0x$(openssl rand -hex 4)$(printf '%08x' $(( (RANDOM << 16 | RANDOM) | 1 )))
GRUN=$V/runs/$NAME-${RID#0x}
# app layout size from the layout parameters only (--nodes --readers --max-pages --records)
LAYOUT=$(grep -oE -- "--(nodes|readers|max-pages|records) [0-9]+" <<< "$SERVER_ARGS" | tr '\n' ' ')
# shellcheck disable=SC2086
APP=$("$HOST_SERVER" --print-app-bytes $LAYOUT)
{ echo "# lmdb run (CXL_SWMC/experiments/lmdb/run.sh)"; echo "name=$NAME"; echo "system=$SYSTEM"; echo "backend=$BACKEND"
  echo "start=$(date -Is)"; echo "run_kind=${RUN_KIND:-measurement}"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"
  echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"; echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "node0_args=${NODE0_ARGS:-} preloaded=$PRELOADED image=$IMAGE"
  echo "node_env=${NODE_ENV:-} node0_env=${NODE0_ENV:-}"; echo "app_hwcc_bytes=$APP"; echo "records=$RECORDS"
  echo "loadgen_args=$*"; echo "lg_cpus=$LG_CPUS"; echo "stats_op=$STATS_OP verify=$VERIFY"
  [ -z "${SERVER_CPUS:-}" ] || echo "server_cpus=$SERVER_CPUS"
  for k in "${!NODE[@]}"; do
    files="$V/bin/lmdb-server $V/bin/lmdb-node.sh $V/cfg/cxl_region.yaml"
    [ "$BACKEND" = megalon ] && files="$files $V/cfg/megalon.yaml $V/lib/libmegalon-objapi.so $V/lib/libmegalon.so"
    [ "$k" = 0 ] && files="$files $IMAGE/meta.txt $IMAGE/pages.bin"
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $files | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
    [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
    echo "node$k=${NODE[$k]} $info"
  done
  for d in cxl_vm0 cxl_vm1; do
    x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null) || x=""
    [ -n "$x" ] && echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -d' ' -f1)" || echo "vm_xml_error.$d=virsh failed"
  done
} > "$RUN/manifest.txt"

for k in "${!NODE[@]}"; do
  XE="${NODE_ENV:-}"; EXTRA=""
  [ "$BACKEND" = megalon ] && XE="ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml $XE"
  if [ "$k" = 0 ]; then
    [ "$BACKEND" = megalon ] && XE="$XE ENV:MEGALON_REINIT=1"
    XE="$XE ${NODE0_ENV:-}"; EXTRA="--image $IMAGE ${NODE0_ARGS:-}"; [ "$PRELOADED" = 1 ] && EXTRA="$EXTRA --preloaded"
  fi
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "$V/bin/lmdb-node.sh start $V $GRUN $k $RID $APP $XE $SERVER_ARGS --port $PORT $EXTRA" < /dev/null
  [ "$k" = 0 ] && sleep 2  # node 0 initialises the app layout (and Megalon) first
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/lmdb-node.sh ready $GRUN $k ${READY_TIMEOUT:-3600}" < /dev/null; done
server_cpus() {  # $1 = set|check
  for k in "${!NODE[@]}"; do
    $SSH comsys@"${NODE[$k]}" "set -e; S=\$(cat $GRUN/node$k.pid); P=\$(pgrep -u comsys -x -s \$S lmdb-server)
      [ \$(echo \"\$P\" | wc -w) = 1 ] || { echo \"lmdb-server pids in session \$S: [\$P]\"; exit 1; }
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
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}  # target order = node order (update writer = target)
cpu_snap before
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
# H1 (H1_MEASURE_RUN=1, README contract item 8): loadgen starts through scripts/host/measure-run.sh in measure.slice
# (clean environment; loadgen needs no variable, so no --env); validation runs start it directly
LGPRE=(); [ "${H1_MEASURE_RUN:-0}" = 1 ] && LGPRE=(bash "$ROOT/scripts/host/measure-run.sh" --)
echo "loadgen_launcher=${LGPRE[*]:-direct}" >> "$RUN/manifest.txt"
if [ -z "${PARTS:-}" ]; then
set +e
"${LGPRE[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload lmdb --target "$TARGETS" --out "$RUN/loadgen" \
  "${LG_STATS[@]}" "$@" 2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
else  # H1-HOOK v2: several loadgen parts in this one server lifetime (see the header)
  : "${PART_ARGS_CMD:?PARTS needs PART_ARGS_CMD}"
  part_post() {  # <part dir>: the per-step tables of one part (as the single-part run below)
    [ -s "$1/loadgen/steps.jsonl" ] && [ -s "$1/loadgen/summary.json" ] || return 0
    if [ -d "$1/loadgen/stats" ]; then
      python3 -B "$ROOT/experiments/loadgen/stats_delta.py" "$1/loadgen" --out "$1/stats-steps.csv" || true
    python3 -I -B "$ROOT/workloads/kv/tools/opsplit.py" "$1/loadgen" --system "$SYSTEM" --out "$1/opsplit.csv" || true
    fi
    python3 -B "$ROOT/experiments/loadgen/export_csv.py" --out "$1/steps.csv" "$1/loadgen=$SYSTEM" > /dev/null || true
    python3 -B "$ROOT/experiments/loadgen/plot_slo.py" --out "$1/slo.png" "$1/loadgen=$SYSTEM" > "$1/slo-points.txt" 2>&1 || true
  }
  LG=0
  for part in $PARTS; do
    mkdir -p "$RUN/$part"
    if ! bash "$PART_ARGS_CMD" "$part" "$RUN" > "$RUN/$part/args.txt" 2> "$RUN/$part/args.err"; then
      echo "run $NAME: part $part args failed: $(tail -n 2 "$RUN/$part/args.err" | tr '\n' ' ')"
      echo "part=$part args_failed $(date -Is)" >> "$RUN/manifest.txt"
      stop_nodes; collect; exit 1
    fi
    mapfile -t PA < "$RUN/$part/args.txt"
    echo "part=$part start=$(date -Is) args=${PA[*]}" >> "$RUN/manifest.txt"
    set +e
    "${LGPRE[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload lmdb --target "$TARGETS" --out "$RUN/$part/loadgen" \
      "${LG_STATS[@]}" "$@" "${PA[@]}" 2>&1 | tee "$RUN/$part/loadgen.log"
    prc=${PIPESTATUS[0]}
    set -e
    echo "part=$part end=$(date -Is) loadgen_rc=$prc" >> "$RUN/manifest.txt"
    [ "$LG" != 0 ] || LG=$prc
    part_post "$RUN/$part"
  done
fi
[ -z "${SERVER_CPUS:-}" ] || server_cpus check
cpu_snap after
VRC=0
if [ "$VERIFY" = 1 ]; then  # full scan of the latest snapshot on both nodes (after the load, before the stop)
  for k in "${!NODE[@]}"; do
    python3 -I -B "$W/tools/lmdb_ctl.py" "${NODE[$k]}:$PORT" verify --expect verify.entries="$RECORDS" verify.bad_values=0 \
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
    # MOT1 v6 Fig 2: per-operation split (T, C, rest per get / update per step; tagged columns)
    python3 -I -B "$ROOT/workloads/kv/tools/opsplit.py" "$RUN/loadgen" --system "$SYSTEM" --out "$RUN/opsplit.csv" || true
  fi
  python3 -B "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  python3 -B "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
CRC=skip
if [ -s "$RUN/loadgen/gets.bin" ]; then  # loadgen --opt log=1: exact MVCC check
  CRC=0; python3 -I -B "$W/tools/check_log.py" "$RUN/loadgen" > "$RUN/check-log.txt" 2>&1 || CRC=$?
  echo "check_log rc=$CRC" >> "$RUN/check-log.txt"; tail -n 2 "$RUN/check-log.txt"
fi
grep -h "lmdb-server: stopping" -A40 "$RUN"/node*.log | grep -E "^(node|gets|updates|get_not_found|update_not_found|get_errors|update_errors)=" | tr '\n' ' '; echo
[ -f "$RUN/loadgen/lmdb.txt" ] && tr '\n' ' ' < "$RUN/loadgen/lmdb.txt" && echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
[ "$VRC" = 0 ] || { echo "run $NAME: verify failed"; exit 1; }
[ "$CRC" = skip ] || [ "$CRC" = 0 ] || { echo "run $NAME: check_log failed"; exit 1; }
echo "run $NAME: OK -> $RUN"

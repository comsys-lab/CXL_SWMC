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
#   TRACE (default 0): TRACE=1 adds vdb-server --trace-dir <guest run dir> (vdb build >= 10, Megalon: sharing trace
#   node<k>.vdbtrace.bin, DESIGN.md §16, classified after the run by tools/classify_sharing.py -> sharing.csv; builds
#   <= 9: node<k>.megalon-{wsec,retry,refetch}.bin; plain: nothing). Dedicated short fixed-load runs only (MOT1 v6
#   Fig 3c), never SLO searches or Fig 1/2 measurements.
#   STATS_OP (default 10 = vdb kOpStats): loadgen --stats-op, a server stats snapshot per node at the start and end of
#   every measured step (loadgen/stats/); STATS_OP=0 omits it. After the run: stats-steps.csv (stats_delta.py) and
#   steps.csv with the derived per-node columns (export_csv.py).
#   PARTS (H1-HOOK v2, optional): space-separated loadgen invocations ("parts") inside ONE server lifetime, e.g.
#   "slo fix" or "fix". Per part p: loadgen args = the common args after -- plus PART_ARGS_<p> (word-split; no spaces in
#   values); output <run>/<p>/loadgen (+ loadgen.log, guest-cpu.txt, stats-steps.csv, steps.csv, opsplit-steps.csv).
#   The token @RATES@ in PART_ARGS_fix becomes "<L2>,<L1>": PART_RATES if set, else the output "<L2> <L1>" of
#   PART_RATES_CMD run right before the fix part (non-zero rc or bad output = LEVELS STOP: servers stopped, exit 5).
#   Parts after the first get --opt w_start=<next_w of the previous part> (the update stream continues; the previous
#   part must end with write_errors=0). A part whose loadgen rc != 0 stops the lifetime unless its summary note is the
#   SLO search's "confirm failed at three rates" (then the next part runs; the caller decides). PART_SEED_<p> (optional):
#   that part's query seed (--opt seed= --seed), recorded in the manifest part line. Per part rc in the
#   manifest (part_<p>_loadgen_rc=); exit 1 if any part rc != 0.
#   Part hooks (H3, experiments/eval/h3-block.sh; all optional, unset = unchanged): PART_GATE_CMD (word-split command,
#   called with the gate log file instead of h1-gate.sh check before every later part when H1_MEASURE_RUN=1),
#   PART_PRE_CMD / PART_POST_CMD (word-split commands called with the part name right before the part's loadgen /
#   right after it, servers up; output in <run>/part-hooks.txt; a failure stops the lifetime, rc 97 / 98).
#   Warmup parts (damon-policy-exploration, experiments/eval/damonx-hook.sh; optional, unset = unchanged):
#   PART_SKIP_CMD (word-split command called with the part name before anything else of that part, output in
#   <run>/part-hooks.txt; rc 0 = the part is skipped: no gate, no loadgen, no dir, manifest "part_<p>=skipped", the
#   next part continues the update stream of the last part that ran; rc 1 = the part runs; any other rc stops the
#   lifetime, rc 96), PART_NOGATE (part names without the part gate before them: unmeasured warmup parts, so the load
#   does not pause between them; the first measured part after them keeps its gate).
#   Decided-rate parts (run 2 pmax step, experiments/eval/h2n-block.sh H2N_PMAX; optional): the token @RATE@ in
#   PART_ARGS_<p> becomes the stdout of PART_RATE_CMD (word-split command called with the part name right before the
#   part, after the previous part ended, servers up; stderr to <run>/part-hooks.txt): a rate, or "skip" = the part is
#   skipped as with PART_SKIP_CMD (manifest "part_<p>=skipped rate_cmd"); rc != 0 or other output stops the lifetime
#   (rc 95). The rc line goes to the manifest ("part <p> rate_cmd rc= out=[..]").
# Stops (and stops the servers) on the first error. Measurement hygiene: no Host build before/after (pgrep).
set -euo pipefail
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}" "${INIT:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7000} LG_CPUS=${LG_CPUS:-56-63} TRACE=${TRACE:-0} STATS_OP=${STATS_OP:-10}
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
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/vdb-server $V/cfg/cxl_region.yaml \$(ls $V/lib/libmegalon-objapi.so $V/lib/libvdb-megalon.so $V/lib/libmegalon.so $V/cfg/megalon.yaml 2>/dev/null) | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
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
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
post_outputs() {  # <dir holding loadgen/>: spreadsheet/plot outputs, always (one row per step and stream; counter deltas)
  local R=$1
  [ -s "$R/loadgen/steps.jsonl" ] && [ -s "$R/loadgen/summary.json" ] || return 0
  [ ! -d "$R/loadgen/stats" ] || python3 "$ROOT/experiments/loadgen/stats_delta.py" "$R/loadgen" --out "$R/stats-steps.csv" || true
  python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$R/steps.csv" "$R/loadgen=$SYSTEM" > /dev/null || true
  [ ! -s "$R/loadgen/op-coh.bin" ] || python3 "$HERE/opsplit.py" "$R" > "$R/opsplit.log" 2>&1 || true
  python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$R/slo.png" "$R/loadgen=$SYSTEM" > "$R/slo-points.txt" 2>&1 || true
}
CONFIRM_NOTE="confirm failed at three rates; the knee is noisy (longer --confirm-s?)"
START_NOTE="the start rate already violates the SLO; lower --start"
# H1 measurement runs (H1_MEASURE_RUN=1, experiments/h1/README.md item 8): loadgen starts inside measure.slice through
# scripts/host/measure-run.sh (clean environment; loadgen needs no variable: everything is on its command line; fail
# closed, exit 125), and every part after the first is preceded by experiments/h1/h1-gate.sh check (MEASURE_PART_DIR).
# Without H1_MEASURE_RUN (validation packets) loadgen starts directly, as before.
LGL=(); [ "${H1_MEASURE_RUN:-0}" = 1 ] && LGL=(bash "$ROOT/scripts/host/measure-run.sh" --)
echo "loadgen_launcher=${LGL[*]:-direct}" >> "$RUN/manifest.txt"
[ -z "${PART_GATE_CMD:-}${PART_PRE_CMD:-}${PART_POST_CMD:-}" ] || \
  echo "part_hooks gate=[${PART_GATE_CMD:-}] pre=[${PART_PRE_CMD:-}] post=[${PART_POST_CMD:-}]" >> "$RUN/manifest.txt"
if [ -z "${PARTS:-}" ]; then
cpu_snap before
set +e
"${LGL[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload vectordb --target "$TARGETS" --out "$RUN/loadgen" \
  "${LG_STATS[@]}" "$@" 2>&1 | tee "$RUN/loadgen.log"
LG=${PIPESTATUS[0]}
set -e
else  # H1-HOOK v2: several loadgen parts in this server lifetime
  LG=0 WS=0 PREV=
  for p in $PARTS; do
    [[ $p =~ ^[a-z0-9]+$ ]] || { echo "bad part name $p"; false; }
    if [ -n "${PART_SKIP_CMD:-}" ]; then  # warmup parts: rc 0 skip, 1 run, else stop (header)
      rc=0; $PART_SKIP_CMD "$p" >> "$RUN/part-hooks.txt" 2>&1 || rc=$?   # || form: no ERR trap (retrospective §3)
      if [ $rc = 0 ]; then echo "part_$p=skipped $(date -Is)" >> "$RUN/manifest.txt"; continue; fi
      [ $rc = 1 ] || { echo "part $p: PART_SKIP_CMD rc $rc (see $RUN/part-hooks.txt)"; LG=96; break; }
    fi
    v=PART_ARGS_$p; PRATE=
    if [[ " ${!v:-} " == *" @RATE@ "* ]]; then  # run-2 pmax step: one rate decided right before the part (header)
      set +e; out=$(${PART_RATE_CMD:?PART_RATE_CMD needed for @RATE@} "$p" 2>> "$RUN/part-hooks.txt"); rc=$?; set -e
      echo "$(date -Is) part $p rate_cmd rc=$rc out=[$out]" >> "$RUN/manifest.txt"
      if [ $rc = 0 ] && [ "$out" = skip ]; then echo "part_$p=skipped rate_cmd $(date -Is)" >> "$RUN/manifest.txt"; continue; fi
      [ $rc = 0 ] && [[ $out =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "part $p: PART_RATE_CMD rc=$rc out=[$out]"; LG=95; break; }
      PRATE=$out
    fi
    PR=$RUN/$p; mkdir "$PR"
    read -r -a PA <<< "${!v:-}"
    [ -z "$PRATE" ] || PA=("${PA[@]/@RATE@/$PRATE}")
    if [ -n "$PREV" ]; then
      WS=$(sed -n 's/^next_w=//p' "$RUN/$PREV/loadgen/vectordb.txt" 2>/dev/null)
      [[ $WS =~ ^[0-9]+$ ]] && grep -qx "write_errors=0" "$RUN/$PREV/loadgen/vectordb.txt" \
        || { echo "part $p: previous part $PREV has no next_w / write errors"; false; }
    fi
    if [[ " ${PA[*]} " == *@RATES@* ]]; then
      RATES=${PART_RATES:-}
      if [ -z "$RATES" ]; then
        set +e; out=$(${PART_RATES_CMD:?PART_RATES or PART_RATES_CMD needed for @RATES@}); rc=$?; set -e
        echo "$(date -Is) part $p rates_cmd rc=$rc out=[$out]" >> "$RUN/manifest.txt"
        if [ $rc != 0 ] || ! [[ $out =~ ^[0-9]+(\.[0-9]+)?\ [0-9]+(\.[0-9]+)?$ ]]; then
          echo "LEVELS STOP (part $p: rates command rc=$rc out=[$out])"; stop_nodes; collect; host_check after || true
          echo "end=$(date -Is) levels_stop=1" >> "$RUN/manifest.txt"; exit 5
        fi
        RATES="${out% *},${out#* }"
      fi
      PA=("${PA[@]/@RATES@/$RATES}")
    fi
    v=PART_SEED_$p; PS=()  # per-part query seed (m4-run.sh KIND=h1: slo SEED, fix SEED+1)
    [ -z "${!v:-}" ] || { [[ ${!v} =~ ^[0-9]+$ ]] || { echo "bad $v"; false; }; PS=(--opt seed=${!v} --seed ${!v}); }
    if [ -n "$PREV" ] && [ "${H1_MEASURE_RUN:-0}" = 1 ] && [[ " ${PART_NOGATE:-} " != *" $p "* ]]; then  # H1 gate before every later part (servers stay up)
      if [ -n "${PART_GATE_CMD:-}" ]; then  # H3 (experiments/eval/h3-block.sh): the N-VM gate scripts/host/h3-gate.sh
        $PART_GATE_CMD "$OUT/gate-$NAME-$p.txt" || { echo "part $p: gate failed (see $OUT/gate-$NAME-$p.txt)"; false; }
      else
        bash "$ROOT/experiments/h1/h1-gate.sh" check "$OUT/gate-$NAME-$p.txt" || { echo "part $p: H1 gate failed (see $OUT/gate-$NAME-$p.txt)"; false; }
      fi
    fi
    if [ -n "${PART_PRE_CMD:-}" ]; then  # H3 CDF: e.g. clear the kprobe hist right before the part (servers up)
      $PART_PRE_CMD "$p" >> "$RUN/part-hooks.txt" 2>&1 || { echo "part $p: PART_PRE_CMD failed (see $RUN/part-hooks.txt)"; LG=97; break; }
    fi
    echo "part_$p=start $(date -Is) w_start=$WS seed=${!v:-common} args=${PA[*]}" >> "$RUN/manifest.txt"
    cpu_snap before; mv "$RUN/guest-cpu.txt" "$PR/guest-cpu.txt" 2>/dev/null || true
    set +e
    "${LGL[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload vectordb --target "$TARGETS" --out "$PR/loadgen" \
      "${LG_STATS[@]}" "$@" "${PA[@]}" "${PS[@]}" --opt w_start=$WS 2>&1 | tee "$PR/loadgen.log"
    rc=${PIPESTATUS[0]}
    set -e
    cpu_snap after; cat "$RUN/guest-cpu.txt" >> "$PR/guest-cpu.txt" 2>/dev/null; rm -f "$RUN/guest-cpu.txt"
    echo "part_${p}_loadgen_rc=$rc end=$(date -Is)" >> "$RUN/manifest.txt"
    if [ $rc != 0 ]; then
      LG=$rc
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note", ""))' "$PR/loadgen/summary.json" 2>/dev/null || true)
      # decision E (2026-10-22): a failed start rate in an slo part is a result as well (the next part, e.g. the H1
      # fix part at the levels from the lowest ramp step, still runs); m4-run.sh judges which notes a caller accepts
      [ "$note" = "$CONFIRM_NOTE" ] || { [ "$p" = slo ] && [ "$note" = "$START_NOTE" ]; } \
        || { echo "part $p: loadgen rc=$rc ($note): lifetime stopped"; break; }
    fi
    if [ -n "${PART_POST_CMD:-}" ]; then  # H3 CDF: e.g. dump the kprobe hist before the servers stop
      $PART_POST_CMD "$p" >> "$RUN/part-hooks.txt" 2>&1 || { echo "part $p: PART_POST_CMD failed (see $RUN/part-hooks.txt)"; LG=98; break; }
    fi
    PREV=$p
  done
fi
[ -z "${SERVER_CPUS:-}" ] || server_cpus check
[ -n "${PARTS:-}" ] || cpu_snap after
stop_nodes
collect
host_check after
echo "end=$(date -Is) loadgen_rc=$LG" >> "$RUN/manifest.txt"
if [ -n "${PARTS:-}" ]; then for p in $PARTS; do [ -d "$RUN/$p" ] && post_outputs "$RUN/$p"; done; fi
if [ -s "$RUN/loadgen/steps.jsonl" ] && [ -s "$RUN/loadgen/summary.json" ]; then
  [ ! -d "$RUN/loadgen/stats" ] || python3 "$ROOT/experiments/loadgen/stats_delta.py" "$RUN/loadgen" --out "$RUN/stats-steps.csv" || true
  python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$RUN/steps.csv" "$RUN/loadgen=$SYSTEM" > /dev/null || true
  [ ! -s "$RUN/loadgen/op-coh.bin" ] || python3 "$HERE/opsplit.py" "$RUN" > "$RUN/opsplit.log" 2>&1 || true
  # sharing trace classifier: Host node 1 only (CPUs and memory), nice 19, address-space cap CLASSIFY_MEM_GB (default
  # 16; ~130 B per record: 2 x 1024 MiB traces need ~9 GB)
  ls "$RUN"/node*.vdbtrace.bin > /dev/null 2>&1 && { (ulimit -v $(( ${CLASSIFY_MEM_GB:-16} * 1024 * 1024 )); exec nice -n 19 \
    numactl --cpunodebind=1 --membind=1 python3 "$ROOT/workloads/vectordb/tools/classify_sharing.py" "$RUN") > "$RUN/sharing.log" 2>&1 || true; }
  python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$RUN/slo.png" "$RUN/loadgen=$SYSTEM" > "$RUN/slo-points.txt" 2>&1 || true
fi
grep -h "vdb-server: stopping" -A30 "$RUN"/node*.log | grep -E "^(node|P|elements|updates|inserts|deletes|searches|timeouts|bad_records)=" | tr '\n' ' '; echo
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
echo "run $NAME: OK -> $RUN"

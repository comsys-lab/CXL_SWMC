#!/bin/bash
# One socialgraph server lifetime on N VMs (experiment socialgraph-serving): start an sg-server per VM
# (scripts/guest/sg-node.sh), drive the N servers from the Host with loadgen --workload socialgraph, stop, collect.
# Modelled on experiments/vectordb/run.sh (same manifest / part / gate conventions); called by sg-block.sh, never by hand
# in a measured run. Writes an immutable result dir <out_root>/<name>/: manifest.txt, node<k>.{log,env},
# stale/stale-{reads,commits}-n<k>.bin, clock-offset.tsv, host-check.txt, port-check.txt, and per part <p>/:
# loadgen/ (steps.jsonl, summary.json, sg.txt, writes.bin, op-coh.bin, stats/), loadgen.log, guest-cpu.txt,
# stats-steps.csv (experiments/loadgen/stats_delta.py).
# usage: sg-run.sh <name> <out_root> -- <loadgen args common to every part (--mix, --opt ...)>
# env (required): SYSTEM (label), V (guest install dir: bin/sg-server, bin/sg-node.sh, cfg/cxl_region.yaml), HOST_SERVER
#   (Host sg-server of the same build: --print-app-bytes), LOADGEN, SERVER_ARGS (identical on every node), PARTS
#   ("slo" or "slo pmax" or "fix"), PART_ARGS_<p> (loadgen arguments of part p, word-split);
#   optional: NODES (guest IPs, default 192.168.122.100 192.168.122.101), PORT (7100), LG_CPUS (56-63), NODE_ENV (ENV:K=V
#   tokens for every node), NODE0_ENV (node 0 only), NODE0_ARGS (server args for node 0 only, e.g. Megalon --image),
#   READY_TIMEOUT (s, default 600), STATS_OP (20 = proto.h kOpStats; 0 = off), STALE_EVERY (1000: 1 in 1000 records read),
#   CLOCK_PERIOD_S (30), PART_GATE_CMD (word-split command, called with a gate file before every later part, when
#   H1_MEASURE_RUN=1), PART_RATE_CMD (word-split, called with the part name; its stdout replaces @RATE@ in PART_ARGS_<p>;
#   "skip" = part skipped), H1_MEASURE_RUN (1 = loadgen inside measure.slice through scripts/host/measure-run.sh),
#   START_FALLBACK (0 default | 1: when the slo part fails at its --start rate, rerun it once with --start
#   START_FALLBACK_RATE (100); first attempt kept as slo-start<rate>/; manifest part_slo_start_fallback= / slo_start_rate=).
# Rules as vectordb/run.sh: a part whose loadgen rc != 0 stops the lifetime unless its note is the SLO search's
# "confirm failed at three rates" or (slo part) "the start rate already violates the SLO"; exit 1 if any part rc != 0.
set -euo pipefail
NAME=$1 OUT=$2; shift 2; [ "${1:-}" = "--" ] && shift
: "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${LOADGEN:?}" "${SERVER_ARGS:?}" "${PARTS:?}"
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
PORT=${PORT:-7100} LG_CPUS=${LG_CPUS:-56-63} STATS_OP=${STATS_OP:-20} STALE_EVERY=${STALE_EVERY:-1000}
CLOCK_PERIOD_S=${CLOCK_PERIOD_S:-30} READY_TIMEOUT=${READY_TIMEOUT:-600}
[[ $STATS_OP =~ ^[0-9]+$ ]] && [[ $STALE_EVERY =~ ^[1-9][0-9]*$ ]] && [[ $READY_TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "bad STATS_OP / STALE_EVERY / READY_TIMEOUT"; exit 2; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
RUN=$OUT/$NAME
[ -e "$RUN" ] && { echo "refusing: $RUN exists (results are immutable)"; exit 3; }
mkdir -p "$RUN" "$RUN/stale"
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)

host_check() {  # any compiler/linker/build tool running on the Host invalidates a measurement (vectordb/run.sh rule)
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $1 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RUN/host-check.txt"
  [ -z "$p" ] || { echo "Host build running ($1): $p"; return 1; }
}
STARTED=() CLK=
stop_nodes() { for k in "${STARTED[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/sg-node.sh stop $GRUN $k" < /dev/null || true; done; }
collect() {
  for k in "${STARTED[@]}"; do
    scp -q "comsys@${NODE[$k]}:$GRUN/node$k.*" "$RUN/" 2>/dev/null || true
    scp -q "comsys@${NODE[$k]}:$GRUN/stale/stale-*-n$k.bin" "$RUN/stale/" 2>/dev/null || true
  done
}
clock_stop() { [ -z "$CLK" ] || { touch "$RUN/clock-offset.stop"; wait "$CLK" 2>/dev/null || true; CLK=; }; }
trap 'echo "run $NAME: error, stopping servers"; stop_nodes; collect; clock_stop' ERR
trap 'echo "run $NAME: interrupted, stopping servers"; stop_nodes; collect; clock_stop; exit 130' INT TERM HUP

host_check before
RID=0x$(openssl rand -hex 4)$(printf '%08x' $(( (RANDOM << 16 | RANDOM) | 1 )))
GRUN=$V/runs/$NAME-${RID#0x}  # fresh guest dir per run
# shellcheck disable=SC2086
APP=$("$HOST_SERVER" $SERVER_ARGS --print-app-bytes)
{ echo "# socialgraph run (CXL_SWMC/experiments/socialgraph/sg-run.sh)"; echo "name=$NAME"; echo "system=$SYSTEM"
  echo "start=$(date -Is)"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"; echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain --untracked-files=no | wc -l)"
  echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
  echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
  echo "server_args=$SERVER_ARGS"; echo "node0_args=${NODE0_ARGS:-}"; echo "node_env=${NODE_ENV:-} node0_env=${NODE0_ENV:-}"
  echo "app_hwcc_bytes=$APP"; echo "loadgen_args=$*"; echo "parts=$PARTS"
  echo "lg_cpus=$LG_CPUS stats_op=$STATS_OP stale_every=$STALE_EVERY clock_period_s=$CLOCK_PERIOD_S nodes=${NODE[*]}"
  for k in "${!NODE[@]}"; do
    info=$($SSH comsys@"${NODE[$k]}" "uname -r; sha256sum $V/bin/sg-server $V/bin/sg-node.sh $V/cfg/cxl_region.yaml \$(ls $V/lib/libmegalon-objapi.so $V/lib/libmegalon.so $V/cfg/megalon.yaml 2>/dev/null) | cut -c1-64; nproc" < /dev/null | tr '\n' ' ')
    [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
    echo "node$k=${NODE[$k]} $info"
  done
} > "$RUN/manifest.txt"

# clock offsets: one round now, every CLOCK_PERIOD_S, one round after the last part (stop file)
python3 -I "$HERE/clock_offset_log.py" --out "$RUN/clock-offset.tsv" --period "$CLOCK_PERIOD_S" --until-file "$RUN/clock-offset.stop" \
  $(printf -- '--vm %s ' "${NODE[@]}") > "$RUN/clock-offset.log" 2>&1 &
CLK=$!
for k in "${!NODE[@]}"; do
  XE="${NODE_ENV:-}" EX=""; [ "$k" = 0 ] && XE="$XE ${NODE0_ENV:-}" && EX="${NODE0_ARGS:-}"
  STARTED+=("$k")
  $SSH comsys@"${NODE[$k]}" "mkdir -p $GRUN/stale && $V/bin/sg-node.sh start $V $GRUN $k $RID $APP $XE $SERVER_ARGS --port $PORT --stale-dir $GRUN/stale --stale-every $STALE_EVERY $EX" < /dev/null
done
for k in "${!NODE[@]}"; do $SSH comsys@"${NODE[$k]}" "$V/bin/sg-node.sh ready $GRUN $k $READY_TIMEOUT" < /dev/null; done
for k in "${!NODE[@]}"; do  # port check: guest listen state + Host TCP connect (fails the run)
  l=$($SSH comsys@"${NODE[$k]}" "ss -ltn | awk '\$4 ~ /:$PORT\$/ {print \$4}'" < /dev/null)
  if timeout 3 bash -c "exec 3<>/dev/tcp/${NODE[$k]}/$PORT" 2>/dev/null; then c=OK; else c=FAILED; fi
  echo "node$k ${NODE[$k]} listen=[$l] host_connect=$c" | tee -a "$RUN/port-check.txt"
  [ -n "$l" ] && [ "$c" = OK ] || { echo "port check failed for node$k"; false; }
done
cpu_snap() { for k in "${!NODE[@]}"; do echo "$1 node$k $($SSH comsys@"${NODE[$k]}" 'head -1 /proc/stat' < /dev/null)"; done >> "$2"; }
TARGETS=$(printf '%s:'"$PORT"',' "${NODE[@]}"); TARGETS=${TARGETS%,}
LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
CONFIRM_NOTE="confirm failed at three rates; the knee is noisy (longer --confirm-s?)"
START_NOTE="the start rate already violates the SLO; lower --start"
LGL=(); [ "${H1_MEASURE_RUN:-0}" = 1 ] && LGL=(bash "$ROOT/scripts/host/measure-run.sh" --)
echo "loadgen_launcher=${LGL[*]:-direct}" >> "$RUN/manifest.txt"
START_FALLBACK=${START_FALLBACK:-0} START_FALLBACK_RATE=${START_FALLBACK_RATE:-100} FB_DIR=
[[ $START_FALLBACK =~ ^[01]$ ]] && [[ $START_FALLBACK_RATE =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] || { echo "bad START_FALLBACK / START_FALLBACK_RATE"; exit 2; }
echo "start_fallback=$START_FALLBACK start_fallback_rate=$START_FALLBACK_RATE" >> "$RUN/manifest.txt"
start_of() { local i; for i in "${!PA[@]}"; do [ "${PA[$i]}" != --start ] || { echo "${PA[$((i + 1))]:--}"; return; }; done; echo -; }
run_part() {  # one loadgen invocation of part $p into $PR (PA = its arguments; "$@" = the common loadgen args) -> rc
  mkdir "$PR"
  echo "part_$p=start $(date -Is) args=${PA[*]}" >> "$RUN/manifest.txt"
  cpu_snap before "$PR/guest-cpu.txt"
  set +e
  "${LGL[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload socialgraph --target "$TARGETS" --out "$PR/loadgen" \
    "${LG_STATS[@]}" "$@" "${PA[@]}" 2>&1 | tee "$PR/loadgen.log"
  rc=${PIPESTATUS[0]}
  set -e
  cpu_snap after "$PR/guest-cpu.txt"
  echo "part_${p}_loadgen_rc=$rc end=$(date -Is)" >> "$RUN/manifest.txt"
}
LG=0 PREV=
for p in $PARTS; do
  [[ $p =~ ^[a-z0-9]+$ ]] || { echo "bad part name $p"; false; }
  v=PART_ARGS_$p; read -r -a PA <<< "${!v:-}"
  if [[ " ${PA[*]} " == *" @RATE@ "* ]]; then  # pmax step: one rate decided right before the part
    set +e; out=$(${PART_RATE_CMD:?PART_RATE_CMD needed for @RATE@} "$p" 2>> "$RUN/part-hooks.txt"); rc=$?; set -e
    echo "$(date -Is) part $p rate_cmd rc=$rc out=[$out]" >> "$RUN/manifest.txt"
    if [ $rc = 0 ] && [ "$out" = skip ]; then echo "part_$p=skipped rate_cmd $(date -Is)" >> "$RUN/manifest.txt"; continue; fi
    [ $rc = 0 ] && [[ $out =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "part $p: PART_RATE_CMD rc=$rc out=[$out]"; LG=95; break; }
    PA=("${PA[@]/@RATE@/$out}")
  fi
  if [ -n "$PREV" ] && [ "${H1_MEASURE_RUN:-0}" = 1 ] && [ -n "${PART_GATE_CMD:-}" ]; then
    $PART_GATE_CMD "$OUT/gate-$NAME-$p.txt" || { echo "part $p: gate failed (see $OUT/gate-$NAME-$p.txt)"; false; }
  fi
  PR=$RUN/$p
  [ "$p" != slo ] || echo "slo_start_rate=$(start_of)" >> "$RUN/manifest.txt"
  run_part "$@"
  note=
  [ $rc = 0 ] || note=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note", ""))' "$PR/loadgen/summary.json" 2>/dev/null || true)
  if [ $rc != 0 ] && [ "$p" = slo ] && [ "$START_FALLBACK" = 1 ] && [ -z "$FB_DIR" ] && [ "$note" = "$START_NOTE" ] && [ "$(start_of)" != - ]; then
    # START_FALLBACK (default off, methodology pending the user): the ramp failed at its start rate -> this part is rerun
    # ONCE in the same server lifetime from START_FALLBACK_RATE; the first attempt stays as slo-start<rate>/ (kept, own
    # stats-steps.csv), the rerun is slo/ (the part every consumer reads); both recorded in manifest.txt
    s0=$(start_of) FB_DIR=slo-start$(start_of)
    mv "$PR" "$RUN/$FB_DIR"
    for i in "${!PA[@]}"; do [ "${PA[$i]}" != --start ] || PA[$((i + 1))]=$START_FALLBACK_RATE; done
    echo "part_slo_start_fallback=$(date -Is) start=$s0 failed (note: $note): first attempt moved to $FB_DIR/, rerun once with --start $START_FALLBACK_RATE (START_FALLBACK=1)" >> "$RUN/manifest.txt"
    echo "slo_start_rate=$START_FALLBACK_RATE" >> "$RUN/manifest.txt"
    if [ "${H1_MEASURE_RUN:-0}" = 1 ] && [ -n "${PART_GATE_CMD:-}" ]; then
      $PART_GATE_CMD "$OUT/gate-$NAME-slo-fallback.txt" || { echo "part slo fallback: gate failed (see $OUT/gate-$NAME-slo-fallback.txt)"; false; }
    fi
    run_part "$@"
    note=
    [ $rc = 0 ] || note=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note", ""))' "$PR/loadgen/summary.json" 2>/dev/null || true)
  fi
  if [ $rc != 0 ]; then
    LG=$rc
    [ "$note" = "$CONFIRM_NOTE" ] || { [ "$p" = slo ] && [ "$note" = "$START_NOTE" ]; } || { echo "part $p: loadgen rc=$rc ($note): lifetime stopped"; break; }
  fi
  PREV=$p
done
stop_nodes
collect
clock_stop
host_check after
echo "end=$(date -Is) loadgen_rc=$LG" >> "$RUN/manifest.txt"
for p in $PARTS $FB_DIR; do
  [ -s "$RUN/$p/loadgen/steps.jsonl" ] || continue
  [ ! -d "$RUN/$p/loadgen/stats" ] || python3 -I "$ROOT/experiments/loadgen/stats_delta.py" "$RUN/$p/loadgen" --out "$RUN/$p/stats-steps.csv" || true
done
{ grep -h "sg-server: stopping" -A80 "$RUN"/node*.log | grep -E "^(node|op\.feed\.(ops|ok|busy|bad)|seq\.(giveups|check_fails)|bad_frames)=" | tr '\n' ' '; echo; } || true
[ "$LG" = 0 ] || { echo "run $NAME: loadgen rc=$LG"; exit 1; }
echo "run $NAME: OK -> $RUN"

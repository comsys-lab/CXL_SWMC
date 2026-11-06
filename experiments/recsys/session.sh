#!/bin/bash
# One recsys server lifetime on the 2 VMs with several loadgen measurements against it (reports/RECSYS-main-packet.md:
# "load once per system", a recorded exception to "every run starts from the initial image"). Same steps as run.sh,
# split into phases so the tables are prepared once and every measurement reads the same server processes:
#   session.sh start   <S>                       S = new session dir: manifest, both servers, READY, port check, load times
#   session.sh measure <S> <name> -- <loadgen args>
#                                                idle check (no queued query, counters still), Host build check, stats
#                                                snapshots before/after, one loadgen run into <S>/<name>/ (manifest.txt,
#                                                loadgen/, steps.csv, stats-steps.csv, breakdown.csv, slo.png), window
#                                                invariants (torn_rows, misses, update_misses, bad_requests deltas = 0),
#                                                torn.txt + torn-steps.csv (torn rows / serving lookups; torn_rows.py)
#   session.sh stop    <S>                       stop both servers, collect node logs, final invariants from the logs,
#                                                torn-lifetime.txt
# Torn rows (user 2026-11-07): start env TORN_POLICY "system=ds T_us=<n> replica_mode=<m>" (main-block.sh, De Stijl
#   lifetimes); torn_rows.py allow decides: T > 0 and replica_mode on = torn rows allowed (reported, no invariant); any
#   other token or none = torn_rows 0 is an invariant; a token inconsistent with SYSTEM / NODE_ENV = exit 2.
# Update seqs continue over the lifetime: measurement i gets --opt seq_base=<last update seq of i-1> --opt wrap=1, so
# the updater replays the trace on from where the previous measurement stopped (recsys plugin; never restarts at 1).
# env (start): SYSTEM, V (guest install dir), HOST_SERVER (Host recsys-server of the same build, --print-app-bytes),
#   SERVER_ARGS (every node; no --publish-ms; --publish-frac allowed), T_MS (--publish-ms), optional NODE0_ARGS, NODE_ENV, NODE0_ENV (ENV:K=V
#   tokens, e.g. ENV:XTIMEOUT=28800), READY_TIMEOUT (s, default 14400), NODES, PORT (7100), HOST_PATH_MAP
#   ("guest=host ..." argument swaps for the Host --print-app-bytes / --print-layout calls only; v7 image / dense).
# env (measure): LOADGEN, optional LG_CPUS (56-63), STATS_OP (10), PROFILE (main | pilot, as run.sh), RUN_KIND
#   (measurement | functional), IDLE_WAIT_S (900), SLO_MS / SLO_RULE (recorded in the manifest only; the SLO itself
#   is the caller's --slo argument).
# SESSION_LOCAL=1 is for Host tests only (tests/session_host_test.sh): guest commands run in a local shell, node k
# listens on PORT+k, no virsh. Exit codes: 0 ok; 1 loadgen rc != 0 (caller reads summary.json note); 3 precondition
# (servers gone, not idle, Host build, existing dir); 4 invariant violated; 5 STATS MISSING (a stats key or file the
# idle check / invariants need is absent); 2 usage.
set -uo pipefail
CMD=${1:-} S=${2:-}
[ -n "$CMD" ] && [ -n "$S" ] || { sed -n 2,20p "$0" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
LOCAL=${SESSION_LOCAL:-0}
rx() {  # rx <node index> <command>: run on the node's guest (Host shell in SESSION_LOCAL=1)
  if [ "$LOCAL" = 1 ]; then bash -c "$2" < /dev/null; else $SSH comsys@"${NODE[$1]}" "$2" < /dev/null; fi
}
fetch() {  # fetch <node index> <guest glob> <local dir>
  if [ "$LOCAL" = 1 ]; then cp $2 "$3/" 2>/dev/null; else scp -q "comsys@${NODE[$1]}:$2" "$3/" 2>/dev/null; fi
}
host_check() {  # <log> <tag>: any compiler/linker/build tool on the Host invalidates a measurement
  local p; p=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' || true)
  echo "$(date -Is) $2 builds=[${p//$'\n'/; }] loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" >> "$1"
  [ -z "$p" ] || [ "${RUN_KIND:-measurement}" = functional ] || { echo "Host build running ($2): $p"; return 1; }
}
kvget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }  # kvget <file> <key>
kvnum() {  # kvnum <var> <file> <key>: integer value or "STATS MISSING <key> in <file>" and exit 5 (never a silent abort)
  local _kvn; _kvn=$(kvget "$2" "$3")
  [[ $_kvn =~ ^-?[0-9]+$ ]] || { echo "STATS MISSING $3 in $2"; exit 5; }
  printf -v "$1" "%s" "$_kvn"
}

case "$CMD" in
start)
  : "${SYSTEM:?}" "${V:?}" "${HOST_SERVER:?}" "${SERVER_ARGS:?}" "${T_MS:?}"
  [[ $T_MS =~ ^[0-9]+$ ]] || { echo "bad T_MS"; exit 2; }
  # only --publish-ms is owned by T_MS; --publish-frac (Ekko operating point, main-block v6) belongs to SERVER_ARGS
  case " $SERVER_ARGS " in *" --publish-ms "*|*" --publish-ms="*) echo "SERVER_ARGS must not set --publish-ms; use T_MS"; exit 2;; esac
  [ -e "$S" ] && { echo "refusing: $S exists"; exit 3; }
  # torn-row policy (user 2026-11-07, torn_rows.py): TORN_POLICY "system=ds T_us=<n> replica_mode=<m>" (main-block.sh,
  # De Stijl lifetimes) allows torn rows only for T > 0 with replica_mode on; everything else keeps torn_rows = 0
  TA=
  if [ -n "${TORN_POLICY:-}" ]; then
    tp=$(python3 -I -B "$HERE/torn_rows.py" allow --system "$SYSTEM" --node-env "${NODE_ENV:-}" --policy "$TORN_POLICY"); trc=$?
    echo "$tp"
    case $trc in 0) TA=$TORN_POLICY;; 1) ;; *) exit 2;; esac
  fi
  mkdir -p "$S" || exit 3
  SA="$SERVER_ARGS --publish-ms $T_MS"
  if [ "$LOCAL" = 1 ]; then read -r -a NODE <<< "${NODES:-127.0.0.1 127.0.0.1}"; else read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"; fi
  PORT=${PORT:-7100}
  PORTS=(); for k in "${!NODE[@]}"; do [ "$LOCAL" = 1 ] && PORTS+=($((PORT + k))) || PORTS+=("$PORT"); done
  RID=0x$(openssl rand -hex 4)$(printf '%08x' $(( (RANDOM << 16 | RANDOM) | 1 )))
  GRUN=$V/runs/session-$(basename "$S")-${RID#0x}
  # Host-side server calls: HOST_PATH_MAP "guest=host ..." swaps guest-only file arguments (v7 --image /
  # --model-dense) for their Host copies; the guest servers keep SA as is
  HSA=() HSUB=""
  # shellcheck disable=SC2086
  for w in $SA; do
    for m in ${HOST_PATH_MAP:-}; do
      [ "${m%%=*}" = "$w" ] && [ -n "${m#*=}" ] && { [ -e "${m#*=}" ] || { echo "HOST_PATH_MAP: ${m#*=} missing on the Host"; exit 2; }
        HSUB="$HSUB $w->${m#*=}"; w=${m#*=}; break; }
    done
    HSA+=("$w")
  done
  APP=$("$HOST_SERVER" "${HSA[@]}" --print-app-bytes) || { echo "print-app-bytes failed"; exit 2; }
  LAYOUT=$("$HOST_SERVER" "${HSA[@]}" --print-layout | head -1)
  { echo "SYSTEM='$SYSTEM'"; echo "V='$V'"; echo "HOST_SERVER='$HOST_SERVER'"; echo "T_MS='$T_MS'"; echo "SA='$SA'"
    echo "RID='$RID'"; echo "GRUN='$GRUN'"; echo "APP='$APP'"; echo "NODES_S='${NODE[*]}'"; echo "PORTS_S='${PORTS[*]}'"
    echo "LOCAL='$LOCAL'"; echo "NODE0_ARGS_S='${NODE0_ARGS:-}'"; echo "NODE_ENV_S='${NODE_ENV:-}'"; echo "NODE0_ENV_S='${NODE0_ENV:-}'"
    echo "TORN_ALLOW_S='$TA'"
  } > "$S/session.env"
  echo 0 > "$S/seq_base"
  { echo "# recsys session (CXL_SWMC/experiments/recsys/session.sh): one server lifetime, several measurements"
    echo "system=$SYSTEM"; echo "start=$(date -Is)"; echo "run_id=$RID"; echo "guest_run_dir=$GRUN"
    echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"; echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
    echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
    echo "publish_ms=$T_MS"; echo "server_args=$SA"; echo "node_env=${NODE_ENV:-} node0_env=${NODE0_ENV:-}"
    echo "node0_args=${NODE0_ARGS:-}"; echo "torn_rows_policy=$([ -n "$TA" ] && echo "allowed ($TA)" || echo "zero${TORN_POLICY:+ ($TORN_POLICY)}")"
    echo "app_hwcc_bytes=$APP"; echo "layout=$LAYOUT"; echo "host_path_map=${HSUB# }"
    for k in "${!NODE[@]}"; do
      info=$(rx "$k" "uname -r; sha256sum $V/bin/recsys-server $V/cfg/cxl_region.yaml \$(ls $V/lib/libmegalon-objapi.so $V/lib/libmegalon.so $V/cfg/megalon.yaml 2>/dev/null) | cut -c1-64; nproc" | tr '\n' ' ')
      [ -n "$info" ] || { echo "node$k info empty" >&2; exit 4; }
      echo "node$k=${NODE[$k]}:${PORTS[$k]} $info"
    done
    if [ "$LOCAL" != 1 ]; then
      for d in cxl_vm0 cxl_vm1; do
        x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null) || x=""
        [ -n "$x" ] && echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -d' ' -f1)" || echo "vm_xml_error.$d=virsh failed"
      done
    fi
  } > "$S/session-manifest.txt" || { echo "session manifest failed"; exit 4; }
  STARTED=()
  fail_start() { echo "session start: $1, stopping servers"; for k in "${STARTED[@]}"; do rx "$k" "$V/bin/recsys-node.sh stop $GRUN $k"; done
    for k in "${STARTED[@]}"; do fetch "$k" "$GRUN/node$k.*" "$S"; done; echo "stopped=$(date -Is) start_failed" >> "$S/session-manifest.txt"; exit 1; }
  trap 'fail_start interrupted' INT TERM HUP
  T0=$(date +%s)
  for k in "${!NODE[@]}"; do
    EXTRA=""; XE="${NODE_ENV:-}"; [ "$k" = 0 ] && EXTRA="${NODE0_ARGS:-}" && XE="$XE ${NODE0_ENV:-}"
    STARTED+=("$k")
    rx "$k" "$V/bin/recsys-node.sh start $V $GRUN $k $RID $APP $XE $SA --port ${PORTS[$k]} $EXTRA" || fail_start "node$k start"
  done
  for k in "${!NODE[@]}"; do rx "$k" "$V/bin/recsys-node.sh ready $GRUN $k ${READY_TIMEOUT:-14400}" || fail_start "node$k ready"; done
  T1=$(date +%s)
  for k in "${!NODE[@]}"; do  # port check: guest listen state + Host TCP connect
    l=$(rx "$k" "ss -ltn | awk '\$4 ~ /:${PORTS[$k]}\$/ {print \$4}'")
    if timeout 3 bash -c "exec 3<>/dev/tcp/${NODE[$k]}/${PORTS[$k]}" 2>/dev/null; then c=OK; else c=FAILED; fi
    echo "node$k ${NODE[$k]}:${PORTS[$k]} listen=[$l] host_connect=$c" | tee -a "$S/port-check.txt"
    [ -n "$l" ] && [ "$c" = OK ] || fail_start "port check node$k"
  done
  { echo "# load times (s), session $(basename "$S")"; echo "start_to_ready_s=$((T1 - T0))"
    for k in "${!NODE[@]}"; do
      rx "$k" "grep -h 'initial tables\|created .* objects\|warm-up read\|preloaded\|READY node\|wmeta records\|records' $GRUN/node$k.log | head -20" | sed "s/^/node$k: /"
    done; } > "$S/load-times.txt"
  for k in "${!NODE[@]}"; do python3 "$HERE/stats_snap.py" "${NODE[$k]}:${PORTS[$k]}" "$S/ready-t$k.txt" > /dev/null || fail_start "stats node$k"; done
  echo "ready=$(date -Is) start_to_ready_s=$((T1 - T0))" >> "$S/session-manifest.txt"
  echo "session $(basename "$S"): READY after $((T1 - T0)) s";;

measure)
  NAME=${3:-}; shift 3; [ "${1:-}" = "--" ] && shift
  [ -n "$NAME" ] || exit 2
  : "${LOADGEN:?}"
  [ -f "$S/session.env" ] && [ ! -e "$S/stopped" ] || { echo "no running session in $S"; exit 3; }
  # shellcheck disable=SC1091
  . "$S/session.env"
  read -r -a NODE <<< "$NODES_S"; read -r -a PORTS <<< "$PORTS_S"
  for a in "$@"; do case "$a" in seq_base=*|wrap=*) echo "seq_base/wrap are set by session.sh"; exit 2;; esac; done
  M=$S/$NAME
  [ -e "$M" ] && { echo "refusing: $M exists"; exit 3; }
  mkdir -p "$M"
  case "${PROFILE:-main}" in
    main) PROF=(--warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --drain-s 5 --confirm-reps 3 --confirm-s 30);;
    pilot) PROF=(--warmup-s 10 --step-warmup-s 2 --step-measure-s 8 --drain-s 5 --confirm-reps 1 --confirm-s 15 --fill none --overload none);;
    *) echo "bad PROFILE"; exit 2;;
  esac
  LG_CPUS=${LG_CPUS:-56-63} STATS_OP=${STATS_OP:-10}
  for k in "${!NODE[@]}"; do  # both servers of this session still alive
    rx "$k" "kill -0 \$(cat $GRUN/node$k.pid) 2>/dev/null && ! grep -q FATAL $GRUN/node$k.log" || { echo "node$k server gone"; exit 3; }
  done
  # idle: no queued query, queries / samples / rows_written unchanged and updater CPU < 0.2 s over 5 s (queued queries
  # of an overload step and an overrunning publication round of the previous measurement finish first)
  deadline=$(( $(date +%s) + ${IDLE_WAIT_S:-900} )) n=0
  while :; do
    n=$((n + 1)) ok=1
    for k in "${!NODE[@]}"; do python3 "$HERE/stats_snap.py" "${NODE[$k]}:${PORTS[$k]}" "$M/idle$n-a-t$k.txt" > /dev/null || ok=0; done
    sleep 5
    for k in "${!NODE[@]}"; do
      python3 "$HERE/stats_snap.py" "${NODE[$k]}:${PORTS[$k]}" "$M/idle$n-b-t$k.txt" > /dev/null || ok=0
      [ $ok = 1 ] || continue  # a failed snapshot is retried by the next probe (deadline below)
      for key in queries samples rows_written thr.rs-update.run_ns serve_queue; do
        kvnum va "$M/idle$n-a-t$k.txt" $key; kvnum vb "$M/idle$n-b-t$k.txt" $key
        case $key in
          thr.rs-update.run_ns) ub=$((vb - va)); [ "$ub" -lt 200000000 ] || ok=0;;  # updater < 0.2 s CPU in 5 s
          serve_queue) [ "$vb" = 0 ] || ok=0;;
          *) [ "$va" = "$vb" ] || ok=0;;
        esac
      done
    done
    echo "$(date -Is) idle probe $n ok=$ok updater_run_ns_5s=${ub:-}" >> "$M/idle.txt"
    [ $ok = 1 ] && break
    [ "$(date +%s)" -lt $deadline ] || { echo "servers not idle after ${IDLE_WAIT_S:-900} s"; exit 3; }
    sleep 10
  done
  host_check "$M/host-check.txt" before || exit 3
  SEQB=$(cat "$S/seq_base")
  set -- "${PROF[@]}" "$@" --opt seq_base="$SEQB" --opt wrap=1
  { echo "# recsys measurement (CXL_SWMC/experiments/recsys/session.sh measure)"; echo "name=$NAME"; echo "system=$SYSTEM"
    echo "session=$S"; echo "session_run_id=$RID"; echo "measurement_index=$(ls -d "$S"/*/manifest.txt 2>/dev/null | wc -l)"
    echo "start=$(date -Is)"; echo "run_kind=${RUN_KIND:-measurement}"; echo "guest_run_dir=$GRUN"
    echo "cxl_swmc_commit=$(git -C "$ROOT" rev-parse HEAD)"; echo "cxl_swmc_dirty=$(git -C "$ROOT" status --porcelain | wc -l)"
    echo "host_server=$HOST_SERVER sha256=$(sha256sum "$HOST_SERVER" | cut -d' ' -f1)"
    echo "loadgen=$LOADGEN sha256=$(sha256sum "$LOADGEN" | cut -d' ' -f1)"
    echo "publish_ms=$T_MS"; echo "profile=${PROFILE:-main}"; echo "server_args=$SA"; echo "app_hwcc_bytes=$APP"
    echo "seq_base=$SEQB"; echo "slo_ms=${SLO_MS:-none}"; echo "slo_rule=${SLO_RULE:-}"; echo "loadgen_args=$*"; echo "lg_cpus=$LG_CPUS"; echo "stats_op=$STATS_OP"
    for a in "$@"; do case "$a" in samples=*|queries=*|quantiles=*) echo "${a%%=*}_sha256=$(sha256sum "${a#*=}" | cut -d' ' -f1)";; esac; done
    grep -E '^(node[0-9]+|vm_xml_sha256\.[a-z0-9_]+|vm_xml_error\.[a-z0-9_]+)=' "$S/session-manifest.txt"
  } > "$M/manifest.txt"
  for k in "${!NODE[@]}"; do python3 "$HERE/stats_snap.py" "${NODE[$k]}:${PORTS[$k]}" "$M/pre-t$k.txt" > /dev/null || { echo "stats node$k"; exit 3; }; done
  cpu() { for k in "${!NODE[@]}"; do echo "$1 node$k $(rx "$k" 'head -1 /proc/stat')"; done >> "$M/guest-cpu.txt"; }
  cpu before
  TARGETS=""; for k in "${!NODE[@]}"; do TARGETS="$TARGETS${TARGETS:+,}${NODE[$k]}:${PORTS[$k]}"; done
  LG_STATS=(); [ "$STATS_OP" = 0 ] || LG_STATS=(--stats-op "$STATS_OP")
  # H1 main (H1_MEASURE_RUN=1, experiments/h1/README.md item 8): loadgen starts inside measure.slice through
  # scripts/host/measure-run.sh (clean environment; loadgen needs no variable); fail closed (rc 125, no loadgen run).
  # Validation packets (H1_MEASURE_RUN unset) launch it as before.
  LGPRE=(); [ "${H1_MEASURE_RUN:-0}" = 1 ] && LGPRE=(bash "$ROOT/scripts/host/measure-run.sh" --)
  "${LGPRE[@]}" numactl --physcpubind="$LG_CPUS" --membind=1 "$LOADGEN" --workload recsys --target "$TARGETS" --out "$M/loadgen" \
    "${LG_STATS[@]}" "$@" > "$M/loadgen.log" 2>&1
  LG=$?
  tail -3 "$M/loadgen.log"
  cpu after
  for k in "${!NODE[@]}"; do python3 "$HERE/stats_snap.py" "${NODE[$k]}:${PORTS[$k]}" "$M/post-t$k.txt" > /dev/null || { echo "stats node$k after"; exit 3; }; done
  HC=0; host_check "$M/host-check.txt" after || HC=1
  NEXT=$(kvget "$M/loadgen/recsys.txt" last_update_seq)
  [[ $NEXT =~ ^[0-9]+$ ]] && [ "$NEXT" -ge "$SEQB" ] || { echo "no last_update_seq in $M/loadgen/recsys.txt"; exit 4; }
  echo "$NEXT" > "$S/seq_base"
  # window invariants from the server counters (cumulative, so deltas over this measurement): torn_rows.py window writes
  # invariants.txt (torn_rows / misses / update_misses / bad_requests deltas; a torn delta under the allowed policy is
  # tagged "allowed" and is no violation) and torn.txt (torn_rows, serving lookups, torn_frac per node and total)
  INV=0 TORN_ALLOW_S=${TORN_ALLOW_S:-}
  tw=$(python3 -I -B "$HERE/torn_rows.py" window "$M" --nodes ${#NODE[@]} --allow "$TORN_ALLOW_S"); trc=$?
  [ $trc != 5 ] || { echo "$tw" | grep -m1 '^STATS MISSING'; exit 5; }
  echo "$tw" | tail -1 | sed "s/^/measurement $NAME: /"
  [ $trc = 0 ] || INV=1
  echo "end=$(date -Is) loadgen_rc=$LG host_check_after=$HC invariants=$([ $INV = 0 ] && echo ok || echo VIOLATED) next_seq_base=$NEXT" >> "$M/manifest.txt"
  if [ -s "$M/loadgen/steps.jsonl" ] && [ -s "$M/loadgen/summary.json" ]; then
    [ ! -d "$M/loadgen/stats" ] || python3 "$ROOT/experiments/loadgen/stats_delta.py" "$M/loadgen" --out "$M/stats-steps.csv" > /dev/null 2>&1 || true
    python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$M/steps.csv" "$M/loadgen=$SYSTEM" > /dev/null 2>&1 || true
    [ ! -d "$M/loadgen/stats" ] || python3 "$HERE/breakdown.py" "$M" --out "$M/breakdown.csv" > "$M/breakdown.log" 2>&1 || true
    python3 "$ROOT/experiments/loadgen/plot_slo.py" --out "$M/slo.png" "$M/loadgen=$SYSTEM" > "$M/slo-points.txt" 2>&1 || true
    [ ! -s "$M/stats-steps.csv" ] || python3 -I -B "$HERE/torn_rows.py" steps "$M" > /dev/null 2>&1 || true   # torn-steps.csv
  fi
  [ $INV = 0 ] || { echo "measurement $NAME: invariant violated ($(grep -v '_delta=0$' "$M/invariants.txt" | grep -v ' allowed$' | tr '\n' ' '))"; exit 4; }
  [ $HC = 0 ] || { echo "measurement $NAME: Host build during the measurement"; exit 3; }
  [ "$LG" = 0 ] || { echo "measurement $NAME: loadgen rc=$LG"; exit 1; }
  echo "measurement $NAME: OK -> $M";;

stop)
  [ -f "$S/session.env" ] || { echo "no session in $S"; exit 3; }
  # shellcheck disable=SC1091
  . "$S/session.env"
  read -r -a NODE <<< "$NODES_S"
  RC=0
  for k in "${!NODE[@]}"; do rx "$k" "[ -e $GRUN/node$k.pid ] && $V/bin/recsys-node.sh stop $GRUN $k" >> "$S/stop.txt" 2>&1 || RC=1; done
  for k in "${!NODE[@]}"; do fetch "$k" "$GRUN/node$k.*" "$S"; done
  date -Is > "$S/stopped"
  for k in "${!NODE[@]}"; do  # clean stop and the workload's own cumulative checks
    L=$S/node$k.log
    grep -q "recsys-server: stopping" "$L" 2>/dev/null || { echo "node$k: no clean stop" | tee -a "$S/final-check.txt"; RC=4; }
    for kv in torn_rows=0 misses=0 update_misses=0 bad_requests=0; do
      [ "$kv" != torn_rows=0 ] || [ -z "${TORN_ALLOW_S:-}" ] || continue   # allowed policy: reported below, no check
      grep -q "^$kv\$" "$L" 2>/dev/null || { echo "node$k: $kv violated" | tee -a "$S/final-check.txt"; RC=4; }
    done
  done
  python3 -I -B "$HERE/torn_rows.py" lifetime "$S" > /dev/null 2>&1 || true   # torn-lifetime.txt (torn rows / lookups)
  [ -z "${TORN_ALLOW_S:-}" ] || echo "torn rows allowed ($TORN_ALLOW_S): $(grep '^total ' "$S/torn-lifetime.txt" 2>/dev/null)" | tee -a "$S/final-check.txt"
  grep -h "^flush_overruns=\|^published_seq=\|^samples=\|^rows_written=\|^flushes=\|^queries=\|^mem.vm_hwm_kb=" "$S"/node*.log > "$S/final-counters.txt" 2>/dev/null
  echo "stopped=$(date -Is) stop_rc=$RC" >> "$S/session-manifest.txt"
  [ $RC = 0 ] && echo "session $(basename "$S"): stopped, final checks ok" || echo "session $(basename "$S"): stop rc=$RC"
  exit $RC;;
*) sed -n 2,20p "$0" >&2; exit 2;;
esac

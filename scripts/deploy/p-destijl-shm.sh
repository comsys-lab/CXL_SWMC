#!/bin/bash
# De Stijl v2 shared-memory phases on N = 2..8 VMs, driven from the Host (inside an experiment approval: module load,
# sudo on the guests, /dev/dax0.0 access). Mirror of p-popcorn-shm.sh for cxl_shm v13 protocol=destijl; the guest side
# is p-destijl-guest.sh (+ destijl.env, faultlat, cxl_region.yaml = config/cxl_region-destijl.yaml, tools.sha256) in
# $GT. Usage: p-destijl-shm.sh <phase>
# Node k = position k in DS_IPS (default: POP_IPS, else .100 .101).
#   plan [phase ...]  print the per-VM command plan (nothing is executed; no R needed)
#   precheck  all guests: De Stijl kernel ($K), tools hashes, cxl_shm not loaded, nobody uses /dev/dax0.0,
#             root:root 600, managed_bytes 0 (read-only + sudo status)
#   load      insmod cxl_shm protocol=destijl on node 0, 1, ..., N-1 in turn (node 0 formats the block) with
#             init_state=$INIT_STATE (default shared) and $LOAD_EXTRA (default "recv_mode=sleep": the receiver tier
#             of Popcorn, DS2-decision-points.md §3a D7; guest allowlist); then every node waits (<= STATE_WAIT s)
#             for /sys/kernel/cxl_shm/state = running (barrier + registration)
#   enable    enable_page_coherence (syscall 470) on all N at once; checks protocol = destijl and the managed range
#   chown     /dev/dax0.0 -> comsys (for unprivileged faultlat / servers)
#   smoke     faultlat smoke.sh (N=2) or smoke-n.sh (N>2) --execute (windows from $BASE); acceptance: every step
#             PASS, no new BUG/Oops/WARNING lines, De Stijl messages sent (ds.fetch_sent + ds.inv_sent delta > 0)
#   status    counters and state of every guest -> $R/status-<STATUS_TAG>-vm<k>.txt
#   teardown  waits (<= 120 s) for faultlat to exit; no user of /dev/dax0.0 left; dax0.0 back to root:root 600;
#             disable coherence and unload cxl_shm (node N-1 down to 0; ONLY=<k>: that VM alone)
# Env (required): K GT R; optional: DS_IPS, STATE_WAIT (s, default 60), INIT_STATE, LOAD_EXTRA, BASE (smoke base page,
# default 25000000), RUN (smoke run id), C (bundle dir, for smoke.sh / smoke-n.sh), STATUS_TAG, ONLY.
set -euo pipefail
umask 077
PHASE=${1:-}
: "${K:?}" "${GT:?}"
[ "$PHASE" = plan ] || : "${R:?}"
IPLIST=${DS_IPS:-${POP_IPS:-}}
if [ -n "$IPLIST" ]; then read -r -a IP <<< "$IPLIST"; else IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}"); fi
N=${#IP[@]}
[ "$N" -ge 2 ] && [ "$N" -le 8 ] || { echo "DS_IPS must list 2..8 guests (got $N)"; exit 2; }
for ip in "${IP[@]}"; do [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad IP '$ip' in DS_IPS"; exit 2; }; done
[ "$(printf '%s\n' "${IP[@]}" | sort -u | wc -l)" = "$N" ] || { echo "DS_IPS has duplicates"; exit 2; }
[[ "$K" == *-ds-destijl-* ]] || { echo "K=$K is not a De Stijl release (-ds-destijl-<n>)"; exit 2; }
ALL=(); for ((k = 0; k < N; k++)); do ALL+=("$k"); done
REV=(); for ((k = N - 1; k >= 0; k--)); do REV+=("$k"); done
STATE_WAIT=${STATE_WAIT:-60}
NARG=; [ "$N" -gt 2 ] && NARG="nodes=$N"   # N=2: PARAMS; N>2: PARAMS_N<N> of destijl.env
BASE=${BASE:-25000000}
INIT_STATE=${INIT_STATE:-shared}
[[ "$INIT_STATE" =~ ^(invalid|shared)$ ]] || { echo "INIT_STATE must be invalid or shared"; exit 2; }
LOAD_EXTRA=${LOAD_EXTRA-recv_mode=sleep}
[[ "$LOAD_EXTRA" =~ ^([a-z_]+=-?[a-z0-9]+( |$))*$ ]] || { echo "LOAD_EXTRA must be 'name=value ...'"; exit 2; }
# Same ssh options as p-popcorn-shm.sh
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
on() { local k=$1; shift; ssh -T "${FLAGS[@]}" "comsys@${IP[$k]}" "$@" < /dev/null; }
G() { local k=$1; shift; on "$k" "sudo -n $GT/p-destijl-guest.sh $*"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
[ "$PHASE" = plan ] || [ -d "$R" ] || { test -d "$(dirname "$R")" && mkdir -m 0700 "$R"; }
SEL=("${ALL[@]}")
if [ -n "${ONLY:-}" ]; then
  [[ "$ONLY" =~ ^[0-7]$ ]] && [ "$ONLY" -lt "$N" ] || { echo "ONLY must be 0..$((N - 1))"; exit 2; }
  SEL=("$ONLY")
fi
wait_no_faultlat() {  # bounded wait (120 s) until no faultlat runs on the given nodes
  local i k busy
  for ((i = 0; i < 60; i++)); do
    busy=0
    for k in "$@"; do [ -z "$(on "$k" "pgrep -x faultlat || true")" ] || busy=1; done
    [ "$busy" = 0 ] && return 0
    sleep 2
  done
  return 1
}
smoke_accept() {  # smoke_accept <before> <after> <node>: dmesg and De Stijl message counters
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
def kv(p):
    d = {}
    for l in open(p):
        if '=' in l and not l.startswith('dmesg: '):
            k, v = l.rstrip('\n').split('=', 1); d[k] = v
    return d
b, a, node = kv(sys.argv[1]), kv(sys.argv[2]), sys.argv[3]
def delta(k):
    try:
        return int(a.get(k, '0')) - int(b.get(k, '0'))
    except ValueError:
        return 0
bad = []
msgs = delta('ds.fetch_sent') + delta('ds.inv_sent')
if msgs <= 0: bad.append('ds.fetch_sent + ds.inv_sent delta %d' % msgs)
if a.get('dmesg_bad') != b.get('dmesg_bad'): bad.append('new dmesg BUG/Oops/WARNING lines: %s -> %s' % (b.get('dmesg_bad'), a.get('dmesg_bad')))
print('vm%s acceptance: ds_messages_delta=%d %s' % (node, msgs, 'OK' if not bad else 'FAIL ' + ', '.join(bad)))
sys.exit(1 if bad else 0)
PY
}

case "$PHASE" in
plan)
  shift
  ph=("$@"); [ ${#ph[@]} -gt 0 ] || ph=(precheck load enable chown status teardown)
  echo "# plan: N=$N K=$K GT=$GT INIT_STATE=$INIT_STATE LOAD_EXTRA='$LOAD_EXTRA' (nothing executed)"
  for k in "${ALL[@]}"; do echo "# node $k = comsys@${IP[$k]}"; done
  g() { echo "ssh comsys@${IP[$1]} 'sudo -n $GT/p-destijl-guest.sh ${*:2}'"; }
  for p in "${ph[@]}"; do
    echo "## $p"
    case $p in
      precheck) for k in "${ALL[@]}"; do echo "ssh comsys@${IP[$k]} 'uname -r; cd $GT && sha256sum --quiet -c tools.sha256'"; g "$k" status; done ;;
      load) for k in "${ALL[@]}"; do g "$k" load "$k" "$INIT_STATE" $NARG $LOAD_EXTRA; done
            for k in "${ALL[@]}"; do g "$k" wait-state "$STATE_WAIT"; done ;;
      enable) for k in "${ALL[@]}"; do [ "$k" = 0 ] && continue; echo "$(g "$k" enable 30) &"; done; g 0 enable 30; echo "wait" ;;
      chown) for k in "${ALL[@]}"; do echo "ssh comsys@${IP[$k]} 'sudo -n chown comsys /dev/dax0.0'"; done ;;
      smoke) echo "(smoke.sh / smoke-n.sh --execute from \$C, base $BASE)" ;;
      status) for k in "${ALL[@]}"; do g "$k" status; done ;;
      teardown) for k in "${SEL[@]}"; do echo "ssh comsys@${IP[$k]} 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0'"; done
                for k in "${REV[@]}"; do [[ " ${SEL[*]} " == *" $k "* ]] || continue; g "$k" disable; g "$k" unload; done ;;
      *) echo "(no plan for phase $p)" ;;
    esac
  done ;;
precheck)
  for k in "${ALL[@]}"; do
    test "$(on $k 'uname -r')" = "$K"
    on $k "cd $GT && sha256sum --quiet -c tools.sha256"
    G $k status > "$R/status-pre-vm$k.txt"
    grep -qx "release=$K loaded=0" "$R/status-pre-vm$k.txt"
    grep -qx 'dax_users=' "$R/status-pre-vm$k.txt"
    grep -qx 'dax0.0=root:root 600' "$R/status-pre-vm$k.txt"
    grep -qx 'swmc.managed_bytes=0' "$R/status-pre-vm$k.txt"
  done
  log "ds shm precheck PASS" ;;
load)
  for k in "${ALL[@]}"; do
    # shellcheck disable=SC2086
    G $k load $k "$INIT_STATE" $NARG $LOAD_EXTRA | tee "$R/load-vm$k.txt"; grep -q "load OK (node $k)" "$R/load-vm$k.txt"
    grep -qx "init_state=$INIT_STATE" "$R/load-vm$k.txt" && grep -qx "nr_nodes=$N" "$R/load-vm$k.txt" &&
      grep -qx "protocol=destijl" "$R/load-vm$k.txt" ||
      { log "STOP: vm$k loaded with unexpected protocol/init_state/nr_nodes"; exit 1; }
  done
  for k in "${ALL[@]}"; do G $k wait-state "$STATE_WAIT" | tee "$R/state-vm$k.txt"; grep -q 'state OK' "$R/state-vm$k.txt"; done
  log "load PASS (N=$N, protocol=destijl, state running on all)" ;;
enable)
  pids=()
  for k in "${ALL[@]}"; do [ "$k" = 0 ] && continue; G $k enable 30 > "$R/enable-vm$k.txt" 2>&1 & pids+=($!); done
  G 0 enable 30 > "$R/enable-vm0.txt" 2>&1 || true
  for p in "${pids[@]}"; do wait "$p" || true; done
  ok=0
  for k in "${ALL[@]}"; do cat "$R/enable-vm$k.txt"; grep -q 'enable OK' "$R/enable-vm$k.txt" || ok=1; done
  [ "$ok" = 0 ] || { log "STOP: enable failed"; exit 1; }
  log "enable PASS (N=$N, protocol=destijl)" ;;
chown)
  for k in "${ALL[@]}"; do
    on $k 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' | tee "$R/chown-vm$k.txt"
    grep -qx 'comsys:root 600' "$R/chown-vm$k.txt"
  done
  log "chown PASS" ;;
smoke)
  : "${RUN:?}" "${C:?}"
  for k in "${ALL[@]}"; do G $k status > "$R/status-smoke-before-vm$k.txt"; done
  rc=0
  if [ "$N" = 2 ]; then
    NODE0=comsys@${IP[0]} NODE1=comsys@${IP[1]} GDIR=$GT GOUT=/home/comsys/destijl-results \
      CXL_REGION_CONFIG=$GT/cxl_region.yaml bash "$C/smoke.sh" "$RUN" "$BASE" --execute 2>&1 | tee "$R/smoke.log" || rc=$?
  else
    NODE_HOSTS="$(for ip in "${IP[@]}"; do printf 'comsys@%s ' "$ip"; done)" GDIR=$GT GOUT=/home/comsys/destijl-results \
      CXL_REGION_CONFIG=$GT/cxl_region.yaml bash "$C/smoke-n.sh" "$RUN" "$BASE" --execute 2>&1 | tee "$R/smoke.log" || rc=$?
  fi
  if [ "$rc" != 0 ] || ! grep -q "smoke $RUN: PASS" "$R/smoke.log"; then
    wait_no_faultlat "${ALL[@]}" && log "faultlat gone on all guests" || log "faultlat still running after 120 s"
    for k in "${ALL[@]}"; do G $k status > "$R/status-smoke-failed-vm$k.txt" || true; done
    log "STOP: smoke failed ($RUN, rc $rc); next: teardown"; exit 1
  fi
  ok=0
  for k in "${ALL[@]}"; do
    G $k status > "$R/status-smoke-after-vm$k.txt"
    mkdir -p "$R/smoke-vm$k"
    scp -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/destijl-results/$RUN/*" "$R/smoke-vm$k/"
    smoke_accept "$R/status-smoke-before-vm$k.txt" "$R/status-smoke-after-vm$k.txt" $k | tee -a "$R/smoke-acceptance.txt" || ok=1
  done
  [ "$ok" = 0 ] || { log "STOP: smoke acceptance failed ($RUN)"; exit 1; }
  log "smoke PASS ($RUN, acceptance OK)" ;;
status)
  for k in "${ALL[@]}"; do G $k status > "$R/status-${STATUS_TAG:-now}-vm$k.txt"; done
  log "status recorded (${STATUS_TAG:-now})" ;;
teardown)
  wait_no_faultlat "${SEL[@]}" || { log "STOP: faultlat still running after 120 s"; exit 1; }
  for k in "${SEL[@]}"; do
    on $k "pgrep -a -x 'vdb-server|recsys-server|faultlat' || true" > "$R/procs-teardown-vm$k.txt"
    test ! -s "$R/procs-teardown-vm$k.txt" || { log "STOP: processes still running on vm$k"; exit 1; }
    G $k status > "$R/status-teardown-vm$k.txt"
    grep -qx 'dax_users=' "$R/status-teardown-vm$k.txt" || { log "STOP: /dev/dax0.0 still in use on vm$k"; exit 1; }
    on $k 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' \
      | tee "$R/unchown-vm$k.txt"
    grep -qx 'root:root 600' "$R/unchown-vm$k.txt"
  done
  for k in "${REV[@]}"; do
    [[ " ${SEL[*]} " == *" $k "* ]] || continue
    G $k disable | tee -a "$R/teardown-vm$k.txt"   # 0 also when already off; EBUSY = mappings left -> stop
    G $k unload | tee -a "$R/teardown-vm$k.txt"
    grep -q 'unload OK\|cxl_shm not loaded' "$R/teardown-vm$k.txt"
  done
  log "teardown PASS on vm${SEL[*]} (coherence off, cxl_shm unloaded, dax0.0 root:root 600)" ;;
*) sed -n '2,24p' "$0"; exit 2 ;;
esac

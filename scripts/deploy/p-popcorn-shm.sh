#!/bin/bash
# Popcorn shared-memory phases on the 2 VMs, driven from the Host (grant-gated:
# module load, sudo on the guests, /dev/dax0.0 access). Usage: p-popcorn-shm.sh <phase>
#   precheck  both guests: Popcorn kernel, tools hashes, cxl_shm not loaded,
#             nobody uses /dev/dax0.0, root:root 600 (read-only + sudo status)
#   load      insmod cxl_shm on VM0 (node 0), then VM1 (node 1), with
#             init_state=$INIT_STATE (invalid|shared, default invalid); wait for the link
#   enable    enable_page_coherence on both at once (init_state=shared: barrier)
#   chown     /dev/dax0.0 -> comsys (for unprivileged faultlat / vdb-server)
#   preload   init_state=shared only, before enable: node 0 writes pattern P
#             through a plain mapping on PPAGES pages from PBASE (faultlat)
#   shared-check  after enable: node 1 and node 0 read P with no coherence
#             transaction (init S), then node 1 writes Q (INVALIDATE) and node 0
#             reads Q (FETCH); checks data and counter deltas
#   smoke     faultlat smoke.sh --execute (windows from $BASE), collect results
#   status    counters and state of both guests -> $R/status-<STATUS_TAG>-vm<k>.txt
#   teardown  waits (<= 120 s) for faultlat to exit; no user of /dev/dax0.0
#             left; dax0.0 back to root:root 600; disable coherence and unload
#             cxl_shm (VM1, then VM0). ONLY=<k> tears down that VM alone (the
#             other one is unreachable and goes to p-popcorn-deploy.sh rollback).
# smoke also checks acceptance: per node, counter deltas transaction_error /
# send_drop / late_response = 0, remote_request_count delta > 0, and no
# BUG/Oops/WARNING in dmesg; on a failed step it waits (<= 120 s) until no
# faultlat runs on either guest, then stops.
# Env (required): K GT R; optional: IP0 IP1 (default .100/.101), BASE (smoke
# base page, default 25000000), RUN (smoke run id), C (bundle dir, for smoke.sh),
# STATUS_TAG, ONLY, INIT_STATE, PBASE (default 25010000), PPAGES (default 1024),
# PRUN (preload run id, default preload-v1).
set -euo pipefail
umask 077
: "${K:?}" "${GT:?}" "${R:?}"
IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}")
BASE=${BASE:-25000000}
INIT_STATE=${INIT_STATE:-invalid}
[[ "$INIT_STATE" =~ ^(invalid|shared)$ ]] || { echo "INIT_STATE must be invalid or shared"; exit 2; }
PBASE=${PBASE:-25010000} PPAGES=${PPAGES:-1024} PRUN=${PRUN:-preload-v1}
PA=0x7777000000000000 PB=0x8888000000000000
fl() {  # fl <node> <step> <faultlat args...>: one faultlat step on a guest (results in popcorn-results/$PRUN)
  local k=$1; shift
  echo "[$(date +%T)] vm$k $1"
  on "$k" "CXL_REGION_CONFIG=$GT/cxl_region.yaml $GT/run.sh /home/comsys/popcorn-results/$PRUN $* --cpu 2"
}
jdelta() {  # jdelta <json> <counter>: kernel counter delta from a faultlat step JSON
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel"][sys.argv[2] + "_delta"])' "$1" "$2"
}
# Same ssh options as p-popcorn-deploy.sh
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
on() { local k=$1; shift; ssh -T "${FLAGS[@]}" "comsys@${IP[$k]}" "$@" < /dev/null; }
G() { local k=$1; shift; on "$k" "sudo -n $GT/p-popcorn-guest.sh $*"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
[ -d "$R" ] || { test -d "$(dirname "$R")" && mkdir -m 0700 "$R"; }
NODES=(0 1)
if [ -n "${ONLY:-}" ]; then [[ "$ONLY" =~ ^[01]$ ]] || { echo "ONLY must be 0 or 1"; exit 2; }; NODES=("$ONLY"); fi
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
smoke_accept() {  # smoke_accept <before> <after> <node>: counters and dmesg
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys
def kv(p):
    d = {}
    for l in open(p):
        if '=' in l and not l.startswith('dmesg: '):
            k, v = l.rstrip('\n').split('=', 1); d[k] = v
    return d
b, a, node = kv(sys.argv[1]), kv(sys.argv[2]), sys.argv[3]
bad = []
for c in ('transaction_error_count', 'send_drop_count', 'late_response_count'):
    if int(a['swmc.' + c]) - int(b['swmc.' + c]) != 0: bad.append(c)
rr = int(a['swmc.remote_request_count']) - int(b['swmc.remote_request_count'])
if rr <= 0: bad.append('remote_request_count delta %d' % rr)
if a.get('dmesg_bad') != '0': bad.append('dmesg BUG/Oops/WARNING lines: %s' % a.get('dmesg_bad'))
print('vm%s acceptance: remote_request_delta=%d %s' % (node, rr, 'OK' if not bad else 'FAIL ' + ', '.join(bad)))
sys.exit(1 if bad else 0)
PY
}

case "${1:-}" in
precheck)
  for k in 0 1; do
    test "$(on $k 'uname -r')" = "$K"
    on $k "cd $GT && sha256sum --quiet -c tools.sha256"
    G $k status > "$R/status-pre-vm$k.txt"
    grep -qx "release=$K loaded=0" "$R/status-pre-vm$k.txt"
    grep -qx 'dax_users=' "$R/status-pre-vm$k.txt"
    grep -qx 'dax0.0=root:root 600' "$R/status-pre-vm$k.txt"
    grep -qx 'swmc.managed_bytes=0' "$R/status-pre-vm$k.txt"
  done
  log "shm precheck PASS" ;;
load)
  G 0 load 0 "$INIT_STATE" | tee "$R/load-vm0.txt"; grep -q 'load OK (node 0)' "$R/load-vm0.txt"
  G 1 load 1 "$INIT_STATE" | tee "$R/load-vm1.txt"; grep -q 'load OK (node 1)' "$R/load-vm1.txt"
  grep -qx "init_state=$INIT_STATE" "$R/load-vm0.txt" && grep -qx "init_state=$INIT_STATE" "$R/load-vm1.txt"
  for k in 0 1; do G $k wait-link 30 | tee "$R/link-vm$k.txt"; grep -q 'link OK' "$R/link-vm$k.txt"; done
  log "load PASS (links up)" ;;
enable)
  # Both at once: with init_state=shared the first enable is a cross-node barrier (<= 600 s in the kernel).
  G 1 enable 30 > "$R/enable-vm1.txt" 2>&1 & p1=$!
  G 0 enable 30 > "$R/enable-vm0.txt" 2>&1 || true
  wait "$p1" || true
  cat "$R/enable-vm0.txt" "$R/enable-vm1.txt"
  grep -q 'enable OK' "$R/enable-vm0.txt" && grep -q 'enable OK' "$R/enable-vm1.txt" || { log "STOP: enable failed"; exit 1; }
  log "enable PASS" ;;
chown)
  for k in 0 1; do
    on $k 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' | tee "$R/chown-vm$k.txt"
    grep -qx 'comsys:root 600' "$R/chown-vm$k.txt"
  done
  log "chown PASS" ;;
smoke)
  : "${RUN:?}" "${C:?}"
  for k in 0 1; do G $k status > "$R/status-smoke-before-vm$k.txt"; done
  rc=0
  NODE0=comsys@${IP[0]} NODE1=comsys@${IP[1]} GDIR=$GT GOUT=/home/comsys/popcorn-results \
    CXL_REGION_CONFIG=$GT/cxl_region.yaml bash "$C/smoke.sh" "$RUN" "$BASE" --execute 2>&1 | tee "$R/smoke.log" || rc=$?
  if [ "$rc" != 0 ] || ! grep -q "smoke $RUN: PASS" "$R/smoke.log"; then
    # a failed pair step can leave the other node's faultlat running (or waiting in a fault): let it end first
    wait_no_faultlat 0 1 && log "faultlat gone on both guests" || log "faultlat still running after 120 s"
    for k in 0 1; do G $k status > "$R/status-smoke-failed-vm$k.txt" || true; done
    log "STOP: smoke failed ($RUN, rc $rc); next: teardown"; exit 1
  fi
  ok=0
  for k in 0 1; do
    G $k status > "$R/status-smoke-after-vm$k.txt"
    mkdir -p "$R/smoke-vm$k"
    scp -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/popcorn-results/$RUN/*" "$R/smoke-vm$k/"
    smoke_accept "$R/status-smoke-before-vm$k.txt" "$R/status-smoke-after-vm$k.txt" $k | tee -a "$R/smoke-acceptance.txt" || ok=1
  done
  [ "$ok" = 0 ] || { log "STOP: smoke acceptance failed ($RUN)"; exit 1; }
  log "smoke PASS ($RUN, acceptance OK)" ;;
preload)
  [ "$INIT_STATE" = shared ] || { echo "preload needs INIT_STATE=shared"; exit 2; }
  for k in 0 1; do
    G $k status > "$R/status-preload-before-vm$k.txt"
    grep -qx 'swmc.init_state=shared' "$R/status-preload-before-vm$k.txt"   # loaded shared, not yet enabled
    grep -qx 'dax0.0=comsys:root 600' "$R/status-preload-before-vm$k.txt"
  done
  fl 0 p0_preload_write access --op write --pages "$PPAGES" --page-offset "$PBASE" --pattern $PA | tee -a "$R/preload.log"
  wait_no_faultlat 0 1
  log "preload PASS (node 0 wrote $PPAGES pages from swcc page $PBASE through a plain mapping)" ;;
shared-check)
  [ "$INIT_STATE" = shared ] || { echo "shared-check needs INIT_STATE=shared"; exit 2; }
  for k in 0 1; do G $k status | grep -qx 'swmc.init_state=shared (initialized)'; done
  fl 1 p1_read_init access --op read --pages "$PPAGES" --page-offset "$PBASE" --expect $PA
  fl 0 p2_read_init access --op read --pages "$PPAGES" --page-offset "$PBASE" --expect $PA
  fl 1 p3_write access --op write --pages "$PPAGES" --page-offset "$PBASE" --pattern $PB
  fl 0 p4_read access --op read --pages "$PPAGES" --page-offset "$PBASE" --expect $PB
  for k in 0 1; do
    mkdir -p "$R/$PRUN-vm$k"
    scp -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/popcorn-results/$PRUN/*" "$R/$PRUN-vm$k/"
  done
  d1=$R/$PRUN-vm1/p1_read_init.json d2=$R/$PRUN-vm0/p2_read_init.json d3=$R/$PRUN-vm1/p3_write.json d4=$R/$PRUN-vm0/p4_read.json
  {
    echo "p1 vm1 read init-S: transactions $(jdelta $d1 transaction_count) faults $(jdelta $d1 fault_count)"
    echo "p2 vm0 read init-S: transactions $(jdelta $d2 transaction_count) faults $(jdelta $d2 fault_count)"
    echo "p3 vm1 write: transactions $(jdelta $d3 transaction_count)"
    echo "p4 vm0 read after write: transactions $(jdelta $d4 transaction_count)"
  } | tee "$R/shared-check.txt"
  [ "$(jdelta $d1 transaction_count)" = 0 ] && [ "$(jdelta $d2 transaction_count)" = 0 ] &&
  [ "$(jdelta $d1 fault_count)" -ge "$PPAGES" ] && [ "$(jdelta $d2 fault_count)" -ge "$PPAGES" ] &&
  [ "$(jdelta $d3 transaction_count)" -ge "$PPAGES" ] && [ "$(jdelta $d4 transaction_count)" -ge "$PPAGES" ] ||
    { log "STOP: shared-check counters unexpected"; exit 1; }
  log "shared-check PASS (init-S reads without messages; first write INVALIDATE; data checked)" ;;
status)
  for k in 0 1; do G $k status > "$R/status-${STATUS_TAG:-now}-vm$k.txt"; done
  log "status recorded (${STATUS_TAG:-now})" ;;
teardown)
  wait_no_faultlat "${NODES[@]}" || { log "STOP: faultlat still running after 120 s"; exit 1; }
  for k in "${NODES[@]}"; do
    on $k "pgrep -a -x 'vdb-server|faultlat' || true" > "$R/procs-teardown-vm$k.txt"
    test ! -s "$R/procs-teardown-vm$k.txt" || { log "STOP: processes still running on vm$k"; exit 1; }
    G $k status > "$R/status-teardown-vm$k.txt"
    grep -qx 'dax_users=' "$R/status-teardown-vm$k.txt" || { log "STOP: /dev/dax0.0 still in use on vm$k"; exit 1; }
    on $k 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' \
      | tee "$R/unchown-vm$k.txt"
    grep -qx 'root:root 600' "$R/unchown-vm$k.txt"
  done
  for k in 1 0; do
    [[ " ${NODES[*]} " == *" $k "* ]] || continue
    G $k disable | tee -a "$R/teardown-vm$k.txt"   # 0 also when already off; EBUSY = mappings left -> stop
    G $k unload | tee -a "$R/teardown-vm$k.txt"
    grep -q 'unload OK\|cxl_shm not loaded' "$R/teardown-vm$k.txt"
  done
  log "teardown PASS on vm${NODES[*]} (coherence off, cxl_shm unloaded, dax0.0 root:root 600)" ;;
*) sed -n '2,32p' "$0"; exit 2 ;;
esac

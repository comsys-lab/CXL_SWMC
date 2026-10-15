#!/bin/bash
# Popcorn shared-memory phases on the 2 VMs, driven from the Host (grant-gated:
# module load, sudo on the guests, /dev/dax0.0 access). Usage: p-popcorn-shm.sh <phase>
#   precheck  both guests: Popcorn kernel, tools hashes, cxl_shm not loaded,
#             nobody uses /dev/dax0.0, root:root 600 (read-only + sudo status)
#   load      insmod cxl_shm on VM0 (node 0), then VM1 (node 1); wait for the link
#   enable    enable_page_coherence on both (after the link is up)
#   chown     /dev/dax0.0 -> comsys (for unprivileged faultlat / vdb-server)
#   smoke     faultlat smoke.sh --execute (windows from $BASE), collect results
#   status    counters and state of both guests -> $R/status-<STATUS_TAG>-vm<k>.txt
#   teardown  no user of /dev/dax0.0 left; dax0.0 back to root:root 600;
#             disable coherence and unload cxl_shm on both (VM1, then VM0)
# Env (required): K GT R; optional: IP0 IP1 (default .100/.101), BASE (smoke
# base page, default 25000000), RUN (smoke run id), C (bundle dir, for smoke.sh),
# STATUS_TAG.
set -euo pipefail
umask 077
: "${K:?}" "${GT:?}" "${R:?}"
IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}")
BASE=${BASE:-25000000}
FLAGS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes)
on() { local k=$1; shift; ssh -T "${FLAGS[@]}" "comsys@${IP[$k]}" "$@" < /dev/null; }
G() { local k=$1; shift; on "$k" "sudo -n $GT/p-popcorn-guest.sh $*"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
[ -d "$R" ] || { test -d "$(dirname "$R")" && mkdir -m 0700 "$R"; }

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
  G 0 load 0 | tee "$R/load-vm0.txt"; grep -q 'load OK (node 0)' "$R/load-vm0.txt"
  G 1 load 1 | tee "$R/load-vm1.txt"; grep -q 'load OK (node 1)' "$R/load-vm1.txt"
  for k in 0 1; do G $k wait-link 30 | tee "$R/link-vm$k.txt"; grep -q 'link OK' "$R/link-vm$k.txt"; done
  log "load PASS (links up)" ;;
enable)
  for k in 0 1; do G $k enable 30 | tee "$R/enable-vm$k.txt"; grep -q 'enable OK' "$R/enable-vm$k.txt"; done
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
  NODE0=comsys@${IP[0]} NODE1=comsys@${IP[1]} GDIR=$GT GOUT=/home/comsys/popcorn-results \
    CXL_REGION_CONFIG=$GT/cxl_region.yaml bash "$C/smoke.sh" "$RUN" "$BASE" --execute 2>&1 | tee "$R/smoke.log"
  grep -q "smoke $RUN: PASS" "$R/smoke.log"
  for k in 0 1; do
    G $k status > "$R/status-smoke-after-vm$k.txt"
    mkdir -p "$R/smoke-vm$k"
    scp -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/popcorn-results/$RUN/*" "$R/smoke-vm$k/"
  done
  log "smoke PASS ($RUN)" ;;
status)
  for k in 0 1; do G $k status > "$R/status-${STATUS_TAG:-now}-vm$k.txt"; done
  log "status recorded (${STATUS_TAG:-now})" ;;
teardown)
  for k in 0 1; do
    on $k "pgrep -a -x 'vdb-server|faultlat' || true" > "$R/procs-teardown-vm$k.txt"
    test ! -s "$R/procs-teardown-vm$k.txt" || { log "STOP: processes still running on vm$k"; exit 1; }
    G $k status > "$R/status-teardown-vm$k.txt"
    grep -qx 'dax_users=' "$R/status-teardown-vm$k.txt" || { log "STOP: /dev/dax0.0 still in use on vm$k"; exit 1; }
    on $k 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' \
      | tee "$R/unchown-vm$k.txt"
    grep -qx 'root:root 600' "$R/unchown-vm$k.txt"
  done
  for k in 1 0; do
    G $k disable | tee -a "$R/teardown-vm$k.txt"   # 0 also when already off; EBUSY = mappings left -> stop
    G $k unload | tee -a "$R/teardown-vm$k.txt"
    grep -q 'unload OK\|cxl_shm not loaded' "$R/teardown-vm$k.txt"
  done
  log "teardown PASS (coherence off, cxl_shm unloaded, dax0.0 root:root 600)" ;;
*) sed -n '2,17p' "$0"; exit 2 ;;
esac

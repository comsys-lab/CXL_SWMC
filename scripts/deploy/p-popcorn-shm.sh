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
#   instr-check  (build >= 8, after enable + chown) both guests: instr/ sysfs
#             present and enabled, a comsys process touches one page of IPAGE
#             (read, then write) and reads its own /proc/thread-self/swmc
#             ("name value" lines, mode 0400, its uid; read/wp counts >= 1).
#             Line count by build (from K): <= 8: 16, 9: 57, 10: 59, >= 11: 62.
#             Build >= 11 also: instr/detail = 0 and instr/sample_shift present.
#             Build >= 9 also: the build-9 instr files, and the process
#             registers a swmc_acct area (/proc/thread-self/swmc_acct, 0600)
#             before the faults: version 1, is/wpu fault counts >= 1,
#             acct_syncs >= 1, acct_errors 0; unregistered afterwards.
#   instr-on  (build >= 8) set instrumentation enabled=1 (ONLY=<k>: one VM); recovery
#             after an interrupted `overhead` (teardown refuses instr_enabled != 1)
#   overhead  (build >= 8) faultlat with instrumentation on vs off on both
#             nodes (/sys/kernel/swmc/instr/enabled), OREPS repeats per
#             setting in ABBA order, fresh pages from OBASE; prints a table
#             (numbers only; stops only on errors); ends with enabled=1.
#             Build >= 9 (faultlat >= 4): a third setting "a" = enabled 1
#             with faultlat --acct 0 (no user area: notify-resume cost);
#             settings per repeat 1 0 a / a 0 1 alternating.
#   teardown  waits (<= 120 s) for faultlat to exit; no user of /dev/dax0.0
#             left; dax0.0 back to root:root 600; disable coherence and unload
#             cxl_shm (VM1, then VM0). ONLY=<k> tears down that VM alone (the
#             other one is unreachable and goes to p-popcorn-deploy.sh rollback).
#             Requires the line instr_enabled=1 (Popcorn build >= 8 only; see instr-on).
# smoke also checks acceptance: per node, counter deltas transaction_error /
# send_drop / late_response = 0, remote_request_count delta > 0, and no
# BUG/Oops/WARNING in dmesg; on a failed step it waits (<= 120 s) until no
# faultlat runs on either guest, then stops.
# Env (required): K GT R; optional: IP0 IP1 (default .100/.101), BASE (smoke
# base page, default 25000000), RUN (smoke run id), C (bundle dir, for smoke.sh),
# STATUS_TAG, ONLY, INIT_STATE, PBASE (default 25010000), PPAGES (default 1024),
# PRUN (preload run id, default preload-v1), IPAGE (instr-check page,
# default 25019000), OBASE (overhead base page, default 25020000), OREPS
# (default 3), ORUN (overhead run id, default overhead-v1), OPAGES (default 1024).
set -euo pipefail
umask 077
: "${K:?}" "${GT:?}" "${R:?}"
IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}")
BASE=${BASE:-25000000}
INIT_STATE=${INIT_STATE:-invalid}
[[ "$INIT_STATE" =~ ^(invalid|shared)$ ]] || { echo "INIT_STATE must be invalid or shared"; exit 2; }
PBASE=${PBASE:-25010000} PPAGES=${PPAGES:-1024} PRUN=${PRUN:-preload-v1}
PA=0x7777000000000000 PB=0x8888000000000000
IPAGE=${IPAGE:-25019000} OBASE=${OBASE:-25020000} OREPS=${OREPS:-3} ORUN=${ORUN:-overhead-v1} OPAGES=${OPAGES:-1024}
# Popcorn build number from the release (…-ds-popcorn-new-<n>); selects the build-8/9/10 expectations.
PBUILD=$(sed -n 's/.*-ds-popcorn-new-\([0-9]\{1,\}\)$/\1/p' <<<"$K")
[ -n "$PBUILD" ] || PBUILD=0
if [ "$PBUILD" -ge 11 ]; then SWMC_LINES=62; elif [ "$PBUILD" -ge 10 ]; then SWMC_LINES=59; elif [ "$PBUILD" -ge 9 ]; then SWMC_LINES=57; else SWMC_LINES=16; fi
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
  # status to a file first: `ssh | grep -q` under pipefail fails with 255 (grep exits early, ssh gets EPIPE)
  for k in 0 1; do G $k status > "$R/status-sharedcheck-vm$k.txt"; grep -qx 'swmc.init_state=shared (initialized)' "$R/status-sharedcheck-vm$k.txt"; done
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
instr-check)
  for k in 0 1; do
    G $k status > "$R/status-instr-vm$k.txt"
    grep -qx 'instr_enabled=1' "$R/status-instr-vm$k.txt" || { log "STOP: instr not enabled on vm$k"; exit 1; }
    grep -qx 'dax0.0=comsys:root 600' "$R/status-instr-vm$k.txt" || { log "STOP: dax0.0 not comsys-owned on vm$k (chown phase?)"; exit 1; }
    G $k instr-dump > "$R/instr-before-vm$k.txt"
    for f in swmc.tx_fetch.wait_count swmc.tx_invalidate.wait_count swmc.serve.unmap_ns swmc.fault_wp.count \
             cxl_shm.ring_rtt.count cxl_shm.counters.tsc_khz; do
      grep -q "^$f " "$R/instr-before-vm$k.txt" || { log "STOP: $f missing on vm$k"; exit 1; }
    done
    if [ "$PBUILD" -ge 9 ]; then
      for f in swmc.fault_full_is.count swmc.fault_full_nontrans.count swmc.ipi.coh_ns swmc.serve_fetch.reply_ns \
               swmc.serve_invalidate.revoke_ns cxl_shm.counters.kthread_work_ns; do
        grep -q "^$f " "$R/instr-before-vm$k.txt" || { log "STOP: $f missing on vm$k (build $PBUILD)"; exit 1; }
      done
    fi
    if [ "$PBUILD" -ge 11 ]; then
      # instr-dump prints single-value files as <dir>.<file>.<value>
      grep -qx "swmc.detail.0" "$R/instr-before-vm$k.txt" && grep -qx "swmc.sample_shift.[0-9]*" "$R/instr-before-vm$k.txt" &&
        grep -qx "swmc.serve_fetch.phase_samples [0-9]*" "$R/instr-before-vm$k.txt" ||
        { log "STOP: build-11 instr files (detail 0, sample_shift, phase_samples) missing on vm$k"; exit 1; }
    fi
  done
  for k in 0 1; do
    page=$((IPAGE + k))   # one fresh page per node
    ssh -T "${FLAGS[@]}" "comsys@${IP[$k]}" "python3 -I - $GT/popcorn.env $page $PBUILD" > "$R/thread-swmc-vm$k.txt" <<'PY'
import ctypes, mmap, os, re, struct, sys
env, page, pbuild = open(sys.argv[1]).read(), int(sys.argv[2]), int(sys.argv[3])
swcc = int(re.search(r'^MANAGED_BASE_OFF=(\d+)$', env, re.M).group(1))   # = managed_offset = swcc start
off = swcc + page * 4096
acct = None
if pbuild >= 9:   # register a struct swmc_acct (128 B, 64-aligned: an anonymous page) before the faults
    acct = mmap.mmap(-1, 4096)
    addr = ctypes.addressof(ctypes.c_char.from_buffer(acct))
    ast = os.stat('/proc/thread-self/swmc_acct')
    with open('/proc/thread-self/swmc_acct', 'w') as f:
        f.write(hex(addr))
fd = os.open('/dev/dax0.0', os.O_RDWR)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
_ = m[0:8]                         # read fault (I -> S, FETCH)
m[8:16] = (page ^ 0x9999).to_bytes(8, 'little')   # write-protect fault (S -> M, INVALIDATE)
p = '/proc/thread-self/swmc'
st = os.stat(p)
lines = open(p).read().splitlines()
area = struct.unpack_from('<II10Q', acct, 0) if acct is not None else None
if acct is not None:
    with open('/proc/thread-self/swmc_acct', 'w') as f:
        f.write('0')               # unregister before the buffer goes away
m.close(); os.close(fd)
print('mode=%o uid=%d me=%d lines=%d' % (st.st_mode & 0o777, st.st_uid, os.getuid(), len(lines)))
for l in lines:
    print(l)
if area is not None:
    print('@acct_mode %o' % (ast.st_mode & 0o777))
    print('@acct_area ' + ' '.join(str(x) for x in area))
PY
    python3 -I - "$R/thread-swmc-vm$k.txt" "$SWMC_LINES" "$PBUILD" <<'PY' || { log "STOP: per-thread file check failed on vm$k"; exit 1; }
import re, sys
t = open(sys.argv[1]).read().splitlines()
nlines, pbuild = sys.argv[2], int(sys.argv[3])
h = dict(re.findall(r'(\w+)=(\d+)', t[0]))
extra = {l.split(' ', 1)[0][1:]: l.split(' ', 1)[1] for l in t[1:] if l.startswith('@')}
kv = dict(l.split(' ') for l in t[1:] if not l.startswith('@'))
assert h['mode'] == '400' and h['uid'] == h['me'] and h['lines'] == nlines, h
if pbuild >= 9:
    a = [int(x) for x in extra['acct_area'].split()]   # version, flags, fault_ns[3], fault_cnt[3], ipi_ns, ipi_cnt, r0, r1
    assert extra['acct_mode'] == '600', extra
    assert a[0] == 1 and a[1] == 0, a
    assert a[5] >= 1 and a[7] >= 1 and a[2] > 0 and a[4] > 0, a           # is and wpu counted, with time
    assert int(kv['is_faults']) >= 1 and int(kv['wpu_faults']) >= 1, kv
    assert int(kv['acct_syncs']) >= 1 and int(kv['acct_errors']) == 0, kv
    print('acct area OK:', a)
assert all(re.fullmatch(r'[a-z0-9_]+', k) and v.isdigit() for k, v in kv.items()), kv
assert int(kv['read_faults']) >= 1 and int(kv['wp_faults']) >= 1 and int(kv['write_faults']) >= 1, kv
assert int(kv['fault_errors']) == 0, kv
print('per-thread file OK:', ' '.join('%s=%s' % (k, kv[k]) for k in ('read_faults', 'read_transactions',
      'read_msg_wait_ns', 'write_faults', 'wp_faults', 'write_transactions', 'write_msg_wait_ns')))
PY
  done | tee "$R/instr-check.txt"
  for k in 0 1; do G $k instr-dump > "$R/instr-after-vm$k.txt"; done
  log "instr-check PASS (instr/ present and enabled; per-thread file readable by its owner on both)" ;;
overhead)
  PRUN=$ORUN   # fl() writes to popcorn-results/$PRUN
  for k in 0 1; do G $k status > "$R/status-overhead-before-vm$k.txt"; done
  order=()
  for ((r = 0; r < OREPS; r++)); do
    if [ "$PBUILD" -ge 9 ]; then if ((r % 2)); then order+=(a 0 1); else order+=(1 0 a); fi
    elif ((r % 2)); then order+=(0 1); else order+=(1 0); fi
  done
  i=0; rc=0
  for e in "${order[@]}"; do
    w=$((OBASE + i * 3 * OPAGES)); tag=o$(printf %02d $i)_e$e
    ie=$e; xa=(); if [ "$e" = a ]; then ie=1; xa=(--acct 0); fi   # "a": instr on, no user area
    for k in 0 1; do G $k instr "$ie" > /dev/null || { rc=1; break 2; }; done
    if ! {
      fl 1 ${tag}_prep access --op write --pages "$OPAGES" --page-offset "$w" "${xa[@]}" &&
      fl 0 ${tag}_readM access --op read --pages "$OPAGES" --page-offset "$w" "${xa[@]}" &&
      fl 0 ${tag}_writeI access --op write --pages "$OPAGES" --page-offset $((w + OPAGES)) "${xa[@]}" &&
      nonce=$(( $(date +%s) * 1000 + i )) && pp=$((w + 2 * OPAGES)) &&
      { fl 1 ${tag}_pp1 pingpong --role 1 --nonce $nonce --iters 10000 --page-offset $pp "${xa[@]}" & x=$!;
        a=0; fl 0 ${tag}_pp0 pingpong --role 0 --nonce $nonce --iters 10000 --page-offset $pp "${xa[@]}" || a=$?;
        wait $x && [ $a = 0 ]; }
    } 2>&1 | tee -a "$R/overhead.log"; then rc=1; break; fi
    i=$((i + 1))
  done
  for k in 0 1; do G $k instr 1 | tee -a "$R/overhead.log" || rc=1; done   # always end with instrumentation on
  if [ "$rc" != 0 ]; then
    wait_no_faultlat 0 1 || true
    for k in 0 1; do G $k status > "$R/status-overhead-failed-vm$k.txt" || true; done
    log "STOP: overhead step failed (see overhead.log); next: teardown"; exit 1
  fi
  ok=0
  for k in 0 1; do
    G $k status > "$R/status-overhead-after-vm$k.txt"
    mkdir -p "$R/$ORUN-vm$k"
    scp -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/popcorn-results/$ORUN/*" "$R/$ORUN-vm$k/"
    smoke_accept "$R/status-overhead-before-vm$k.txt" "$R/status-overhead-after-vm$k.txt" $k | tee -a "$R/overhead-acceptance.txt" || ok=1
  done
  [ "$ok" = 0 ] || { log "STOP: overhead acceptance failed"; exit 1; }
  python3 -I - "$R/$ORUN-vm0" <<'PY' | tee "$R/overhead.txt"
import json, pathlib, statistics, sys
d = pathlib.Path(sys.argv[1]); rows = {}
for f in sorted(d.glob('o*_e[01a]_*.json')):
    j = json.loads(f.read_text()); tag, e, kind = f.stem.split('_', 2); e = e[1:]
    key = {'readM': 'pass0_read', 'writeI': 'pass0_write', 'pp0': 'round_trip'}.get(kind)
    if key:
        s = j['passes'][key]; rows.setdefault((kind, e), []).append((s['mean_ns'], s['p50_ns'], s['p99_ns']))
print('scenario instr n mean_ns(avg+-sd over repeats) p50_ns(avg) p99_ns(avg)')
for (kind, e), v in sorted(rows.items()):
    m = [x[0] for x in v]
    print('%s %s %d %.0f+-%.0f %.0f %.0f' % (kind, e, len(v), statistics.mean(m),
          statistics.stdev(m) if len(m) > 1 else 0, statistics.mean(x[1] for x in v), statistics.mean(x[2] for x in v)))
for kind in ('readM', 'writeI', 'pp0'):
    if (kind, '1') in rows and (kind, '0') in rows:
        a = statistics.mean(x[0] for x in rows[(kind, '1')]); b = statistics.mean(x[0] for x in rows[(kind, '0')])
        print('%s overhead mean: %+.0f ns (%+.1f%%)' % (kind, a - b, 100 * (a - b) / b))
    if (kind, 'a') in rows and (kind, '1') in rows:
        a = statistics.mean(x[0] for x in rows[(kind, '1')]); c = statistics.mean(x[0] for x in rows[(kind, 'a')])
        print('%s user-area (notify-resume) cost mean: %+.0f ns (%+.1f%%)' % (kind, a - c, 100 * (a - c) / c))
PY
  log "overhead done ($((i)) runs; numbers in overhead.txt; instrumentation enabled=1 on both)" ;;
instr-on)
  # recovery after an interrupted `overhead`: instrumentation back on (ONLY=<k> for one VM)
  for k in "${NODES[@]}"; do
    G $k instr 1 > "$R/instr-on-vm$k.txt"; cat "$R/instr-on-vm$k.txt"
    G $k status > "$R/status-instr-on-vm$k.txt"
    grep -qx 'instr_enabled=1' "$R/status-instr-on-vm$k.txt" || { log "STOP: instr still not enabled on vm$k"; exit 1; }
  done
  log "instr-on PASS on vm${NODES[*]}" ;;
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
    # kernels with instrumentation (build >= 8): it must be back on (an interrupted `overhead` may leave 0;
    # recovery: `p-popcorn-shm.sh instr-on`, then teardown again)
    grep -qx 'instr_enabled=1' "$R/status-teardown-vm$k.txt" ||
      { log "STOP: instr_enabled=1 missing on vm$k (run: env R=... p-popcorn-shm.sh instr-on, then teardown)"; exit 1; }
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
*) sed -n '2,40p' "$0"; exit 2 ;;
esac

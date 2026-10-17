#!/bin/bash
# One KV pilot block (reports/M5-pilot-kv.md): a fixed list of pilot-run.sh runs on page MSI build 8 (all systems on
# the same kernel; all-HWcc and Megalon with cxl_shm unloaded, as the M5 HNSW pilots).
# usage: pilot-block.sh <block> <evidence dir (exists, empty except sequence.*)>
#   hm:  functional all-HWcc and Megalon (put ratio 0.5); pilot SLO searches all-HWcc and Megalon at put ratio
#        0.05 (H1), 0 and 0.5 (H2) (order shuffled); then untraced 30 s fixed-load windows at L = 0.5 x the all-HWcc
#        result at the same ratio (shuffled); then one traced window per system at 0.5 (ptrace, Figure 2c logs only).
#   pop: page MSI (C8 K8 GT8 RECV_MODE): functional (0.5), pilot SLO searches at 0.05 / 0 / 0.5 (shuffled), untraced
#        fixed-load windows at L from the hm block (LREF = its evidence dir), then the traced 0.5 window.
#   main: H1 MAIN run (reports/KV-main-packet.md; MOT1 v6: per system one full SLO search (KIND=slo) per mix in MIXES,
#        mix order shuffled per system with the same seed; v5 = MIXES=0.05) at put ratio u, KEYS
#        (54000000), order = [hw mg pop] shuffled with seed "KV-main-h1" (order.txt before the first run); dax0.0
#        comsys for all-HWcc/Megalon, back to root:root 600 (fresh stat check) before page MSI. A confirm failure at
#        three rates is a NOTE (recorded, the block continues); every other stop ends the block. FIX_RATE set: after
#        each system's SLO search, a separate run <sys>-u5-fix = one 30 s fixed-load window at FIX_RATE req/s (KIND=fix:
#        no SLO abort; an aborted (saturated) window is a NOTE and is reported).
#   v1val: KV-V1 validation (reports/KV-V1-packet.md): per system (all-HWcc, Megalon timers on and off, Popcorn) and
#        mix (put 0.05, 0.8) one ladder run (low rate, ~0.5 x v5 pilot max), closure checks v1-check.py after each.
#   idle: low-rate latency check: one all-HWcc ladder run (KIND=ladder, RATES, KEYS) tagged CTAG (Host C-state setting,
#        recorded from sysfs before the run).
#   hmtrace: only the traced 0.5 windows of all-HWcc and Megalon (shuffled) at L from an earlier hm block (LREF), e.g.
#        after an hm block that stopped at its ptrace runs.
# env: MEGALON_BUILD_N (75 = CohSnap incl. the KV path + AnchorSnap; the Megalon build the kv-megalon
#   build must name), MIXES (main block: put ratios, default MOT1 v6 "0.05 0.5 0.8" = get/put 95/5, 50/50, 20/80),
#   PIN (harness commit), BUILD_PIN (commit the builds were made from; default PIN; every build manifest must name
#   it with dirty=0, and the server/loadgen sources must not differ between BUILD_PIN and PIN), KV_CFG, K8.
#   PRETOUCH_DIR (required for v1val, optional otherwise): the ENV-pretouch evidence dir of the VMs' current QEMU
#   lifetime; pretouch-check.sh must PASS under the lock before the install/precheck and again after the last run
#   (standing rule 2026-10-17: whole dax0.0 pre-touched on each VM after every QEMU start, before any measurement).
# Holds the measurement lock for the whole block; stops at the first PILOTRUN STOP. On every exit: this block's servers
# stopped, page MSI teardown of every attempted load, /dev/dax0.0 back to root:root 600 on both VMs UNCONDITIONALLY
# (fresh stat check per VM; "ROLLBACK FAIL" otherwise), lock released.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # never write __pycache__ (harness snapshots live in recovery/); every python3 call also has -B
B=$1 E=$2
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/kv G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
K8=${K8:-6.14.0-famfs-de-stijl+-ds-popcorn-new-8}
VP=${VM_PLAIN:-/home/comsys/kv3} VM=${VM_MEG:-/home/comsys/kvm3}
BP=${PLAIN_BUILD:-$P/builds/kv/3} BM=${MEG_BUILD:-$P/builds/kv-megalon/3} BL=${LOADGEN_BUILD:-$P/builds/kv-loadgen/3}
: "${PIN:?PIN = harness commit}"
BPIN=${BUILD_PIN:-$PIN}
[ "$BPIN" = "$PIN" ] || git -C $P/CXL_SWMC diff --quiet "$BPIN" "$PIN" -- workloads/kv/server workloads/kv/loadgen workloads/kv/proto.h \
  systems/common systems/megalon/shim/megalon_objapi.h systems/popcorn_new/include/swmc_acct.h experiments/loadgen/loadgen.cc experiments/loadgen/workload.h experiments/loadgen/frame.h \
  || { echo "SEQUENCE STOP: server/loadgen sources differ between BUILD_PIN $BPIN and PIN $PIN"; exit 2; }
export VM_PLAIN=$VP VM_MEG=$VM PLAIN_BUILD=$BP MEG_BUILD=$BM LOADGEN_BUILD=$BL
CFG=${KV_CFG:?KV_CFG = the megalon.yaml install.sh wrote (<install log>.megalon.yaml)}
# KV_INSTALL=1: install the builds into the (new) guest dirs VM_PLAIN / VM_MEG under the block's lock, before the
#   precheck (install.sh, grant A; refuses existing dirs); KV_CFG must then be <evidence dir>/install.log.megalon.yaml
[ "${KV_INSTALL:-0}" = 0 ] || [ "$CFG" = "$E/install.log.megalon.yaml" ] || { echo "SEQUENCE STOP: KV_INSTALL=1 needs KV_CFG=$E/install.log.megalon.yaml"; exit 2; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="KV-pilot-$B"; [ "$B" = main ] && OWNER="KV-main-h1"; [ "$B" = v1val ] && OWNER="KV-V1-v1"
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
grep -q "^megalon_build=$P/builds/megalon/${MEGALON_BUILD_N:-75}$" "$BM/manifest.txt" && grep -q "^source_commit=$BPIN dirty=0$" "$BM/manifest.txt" \
  || { echo "SEQUENCE STOP: $BM is not a clean build of $BPIN on builds/megalon/${MEGALON_BUILD_N:-75}"; exit 2; }
grep -q "^source_commit=$BPIN dirty=0$" "$BP/manifest.txt" && grep -q "^megalon.flavor=hwcc$" "$BP/manifest.txt" \
  && grep -q "^megalon_build=$P/builds/megalon/${MEGALON_BUILD_N:-75}-hwcc$" "$BP/manifest.txt" \
  || { echo "SEQUENCE STOP: $BP is not a clean hwcc-flavor build of $BPIN on builds/megalon/${MEGALON_BUILD_N:-75}-hwcc (all-HWcc and Megalon KV share the library version)"; exit 2; }
grep -q "^cxl_swmc_commit=$BPIN kv_dirty=0$" "$BL/kv-manifest.txt" \
  && grep -q "^sha256 $(sha256sum "$BL/loadgen" | cut -d' ' -f1)  " "$BL/manifest.txt" \
  || { echo "SEQUENCE STOP: $BL loadgen is not the recorded build of $BPIN"; exit 2; }
bash $G lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
CHOWNED=0
finish() {
  set +eu  # nothing in the trap may abort it before the unlock
  for ip in "${IPS[@]}"; do
    for g in $(sed -n 's/^guest_run_dir=//p' "$E"/*/manifest.txt 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && \$(dirname $g)/../bin/kv-node.sh stop $g \$k; done; true" < /dev/null 2>&1 | sed "s|^|$ip |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip 'echo procs=$(pgrep -c -x kv-server)' < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
  if [ -n "${C8:-}" ]; then  # page MSI: tear down every attempted load without "teardown PASS"
    for r in "$E"/shm-*/; do
      r=${r%/}; [ -f "$r/load-vm0.txt" ] || continue
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
      env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
        || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
             && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: reports/M5-pilot-kv.md §6)" | tee -a "$E/cleanup.out"
    done
  fi
  dax_root_all || true  # unconditional (page MSI chowns through p-popcorn-shm.sh; a failed teardown may leave comsys)
  bash $G unlock "$OWNER"
}
# dax0.0 back to root:root 600 on both VMs; judged on this call's fresh stat output per VM (not on rollback.out)
dax_root_all() {
  local ip out rc=0
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "stat=root:root 600" || { echo "ROLLBACK FAIL: $ip dax0.0 not root:root 600" | tee -a "$E/rollback.out"; rc=1; }
  done
  return $rc
}
dax_comsys_all() {
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
  done
}
trap finish EXIT
run() {  # name, env assignments...
  local name=$1; shift
  env "$@" bash $X/pilot-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  local st=${PIPESTATUS[0]}
  [ $st = 0 ] || { echo "$(date -Is) SEQUENCE STOP at $name"; exit 1; }
}
shuffle() { python3 -B -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_l() {  # 0.5 x the confirm mean of an SLO run without a note (a noted run is never used for L)
  python3 -B -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{})
if s.get("note"): sys.exit("note: " + s["note"])
x=c.get("x_mean",0); assert x > 0, "no confirm result"; print(round(0.5 * x, 3))' "$1"
}
tag() { case $1 in 0) echo u0;; 0.05) echo u5;; 0.2) echo u20;; 0.5) echo u50;; 0.8) echo u80;; esac; }
precheck() {
  local i f files="${VP#/home/comsys/}/bin/kv-server ${VP#/home/comsys/}/bin/kv-node.sh ${VP#/home/comsys/}/lib/libkv-megalon.so ${VP#/home/comsys/}/lib/libmegalon.so ${VP#/home/comsys/}/cfg/cxl_region.yaml ${VP#/home/comsys/}/cfg/megalon.yaml ${VM#/home/comsys/}/bin/kv-server ${VM#/home/comsys/}/lib/libkv-megalon.so ${VM#/home/comsys/}/lib/libmegalon.so ${VM#/home/comsys/}/lib/libmegalon-objapi.so ${VM#/home/comsys/}/cfg/cxl_region.yaml ${VM#/home/comsys/}/cfg/megalon.yaml"
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$K8 INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || { echo "SEQUENCE STOP: precheck ${IPS[$i]}"; exit 1; }
    for f in "${VP#/home/comsys/}/bin/kv-server $BP/bin/kv-server" "${VP#/home/comsys/}/lib/libkv-megalon.so $BP/lib/libkv-megalon.so" \
             "${VP#/home/comsys/}/lib/libmegalon.so $BP/lib/libmegalon.so" "${VM#/home/comsys/}/bin/kv-server $BM/bin/kv-server" \
             "${VM#/home/comsys/}/lib/libkv-megalon.so $BM/lib/libkv-megalon.so" "${VM#/home/comsys/}/lib/libmegalon.so $BM/lib/libmegalon.so" \
             "${VM#/home/comsys/}/lib/libmegalon-objapi.so $BM/lib/libmegalon-objapi.so" \
             "${VP#/home/comsys/}/cfg/megalon.yaml $CFG" "${VM#/home/comsys/}/cfg/megalon.yaml $CFG" \
             "${VP#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" "${VM#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" \
             "${VP#/home/comsys/}/bin/kv-node.sh $P/CXL_SWMC/scripts/guest/kv-node.sh"; do
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" \
        || { echo "SEQUENCE STOP: ${IPS[$i]} /home/comsys/$1 != $2"; exit 1; }
    done
  done
}
echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD))"
[ "$B" != v1val ] || [ -n "${PRETOUCH_DIR:-}" ] || { echo "SEQUENCE STOP: v1val needs PRETOUCH_DIR (standing pretouch rule)"; exit 2; }
ptcheck() {  # tag
  [ -z "${PRETOUCH_DIR:-}" ] && return 0
  bash $X/pretouch-check.sh "$PRETOUCH_DIR" "$E/pretouch-check-$1.txt" | tail -n 1
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "$(date -Is) SEQUENCE STOP: pretouch check ($1), see pretouch-check-$1.txt"; exit 1; }
}
ptcheck start
if [ "${KV_INSTALL:-0}" = 1 ]; then
  : "${KEYS:?KEYS (install.sh sizes cfg/megalon.yaml for it)}"
  echo "$(date -Is) install $BP -> $VP, $BM -> $VM (keys $KEYS)"
  KEYS=$KEYS bash $X/install.sh "$E/install.log" > "$E/install.out" 2>&1 || { echo "SEQUENCE STOP: install (see install.out)"; exit 1; }
  [ "$(grep -c '^ldd_not_found=0$' "$E/install.log")" = 2 ] || { echo "SEQUENCE STOP: install ldd"; exit 1; }
fi
precheck
case "$B" in
  hm|hmtrace)
    dax_comsys_all
    if [ "$B" = hmtrace ]; then
      : "${LREF:?}"
      for s in $(shuffle hw mg); do
        [ $s = hw ] && S=all-HWcc || S=Megalon
        r=$(confirm_l $LREF/hw-u50-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for 0.5 in $LREF"; exit 1; }
        echo "$s u=0.5 L = 0.5 x $LREF/hw-u50-pslo = $r requests/s (trace)" >> "$E/fixed-load-L.txt"
        run $s-u50-ptrace SYS=$S PUT_RATIO=0.5 KIND=ptrace RATE=$r
      done
      ptcheck end
      echo "$(date -Is) SEQUENCE DONE $OWNER"
      exit 0
    fi
    run hw-u50-func SYS=all-HWcc PUT_RATIO=0.5 KIND=functional GATE=0
    run mg-u50-func SYS=Megalon PUT_RATIO=0.5 KIND=functional GATE=0
    for su in $(shuffle hw:0.05 mg:0.05 hw:0 mg:0 hw:0.5 mg:0.5); do
      s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
      run $s-$(tag $u)-pslo SYS=$S PUT_RATIO=$u KIND=pslo
    done
    for su in $(shuffle hw:0.05 mg:0.05 hw:0 mg:0 hw:0.5 mg:0.5); do
      s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
      r=$(confirm_l $E/hw-$(tag $u)-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for put ratio $u"; exit 1; }
      echo "$s u=$u L = 0.5 x hw-$(tag $u)-pslo = $r requests/s" >> "$E/fixed-load-L.txt"
      run $s-$(tag $u)-pfix SYS=$S PUT_RATIO=$u KIND=pfix RATE=$r
    done
    for s in $(shuffle hw mg); do  # traced windows (Figure 2c logs only; not compared)
      [ $s = hw ] && S=all-HWcc || S=Megalon
      r=$(confirm_l $E/hw-u50-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for 0.5"; exit 1; }
      run $s-u50-ptrace SYS=$S PUT_RATIO=0.5 KIND=ptrace RATE=$r
    done;;
  main)
    : "${C8:?}" "${GT8:?}" "${RECV_MODE:?}" "${KEYS:?}"
    ORD=$(shuffle hw mg pop)
    [ $(echo $ORD | wc -w) = 3 ] || { echo "SEQUENCE STOP: run order"; exit 1; }
    [ -z "${FIX_RATE:-}" ] || [[ $FIX_RATE =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad FIX_RATE"; exit 2; }
    MX=${MIXES:-0.05 0.5 0.8}
    for u in $MX; do [[ $u =~ ^(0\.05|0\.5|0\.8)$ ]] || { echo "SEQUENCE STOP: bad mix $u"; exit 2; }; done
    echo "# KV H1 main order (shuffle seed $OWNER): $ORD; mixes [$MX] shuffled per system; keys $KEYS batch 16 Zipf 0.99 request seed ${SEED:-20261016}; per system and mix: slo${FIX_RATE:+, then fix at $FIX_RATE req/s}" | tee "$E/order.txt"
    for s in $ORD; do
      case $s in
        hw)  [ $CHOWNED = 1 ] || dax_comsys_all; SE=(SYS=all-HWcc);;
        mg)  [ $CHOWNED = 1 ] || dax_comsys_all; SE=(SYS=Megalon);;
        pop) if [ $CHOWNED = 1 ]; then dax_root_all || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600 before page MSI"; exit 1; }; CHOWNED=0; fi
             SE=(SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE);;
      esac
      for u in $(shuffle $MX); do
        echo "$s $u" >> "$E/order.txt"
        run $s-$(tag $u)-slo "${SE[@]}" PUT_RATIO=$u KIND=slo KEYS=$KEYS
        [ -z "${FIX_RATE:-}" ] || run $s-$(tag $u)-fix "${SE[@]}" PUT_RATIO=$u KIND=fix RATE=$FIX_RATE KEYS=$KEYS
      done
    done;;
  idle)  # low-rate latency check (reports/KV-idle-check.md): one all-HWcc ladder run; CTAG names the Host C-state setting
    : "${CTAG:?}" "${RATES:?}" "${KEYS:?}"
    [[ $CTAG =~ ^[a-z0-9-]+$ ]] || { echo "SEQUENCE STOP: bad CTAG"; exit 2; }
    for f in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo "$(cat $f/name) disable=$(cat $f/disable)"; done > "$E/host-cstates-$CTAG.txt"
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable; do echo "$c $(cat $c)"; done > "$E/host-cstates-all-$CTAG.txt"
    dax_comsys_all
    run hw-ladder-$CTAG SYS=all-HWcc PUT_RATIO=0.05 KIND=ladder RATES=$RATES KEYS=$KEYS;;
  pop)
    : "${C8:?}" "${GT8:?}" "${RECV_MODE:?}" "${LREF:?}"
    PE=(SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE)
    run pop-u50-func "${PE[@]}" PUT_RATIO=0.5 KIND=functional GATE=0
    for u in $(shuffle 0.05 0 0.5); do run pop-$(tag $u)-pslo "${PE[@]}" PUT_RATIO=$u KIND=pslo; done
    for u in $(shuffle 0.05 0 0.5); do
      r=$(confirm_l $LREF/hw-$(tag $u)-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for $u in $LREF"; exit 1; }
      echo "pop u=$u L = 0.5 x $LREF/hw-$(tag $u)-pslo = $r requests/s" >> "$E/fixed-load-L.txt"
      run pop-$(tag $u)-pfix "${PE[@]}" PUT_RATIO=$u KIND=pfix RATE=$r
    done
    r=$(confirm_l $LREF/hw-u50-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for 0.5 in $LREF"; exit 1; }
    run pop-u50-ptrace "${PE[@]}" PUT_RATIO=0.5 KIND=ptrace RATE=$r;;
  v1val)  # KV-V1 (reports/KV-V1-packet.md): MOT1 v6 KV validation (v1.4: Popcorn build 12, Megalon 77). Per system and mix (u5, u80)
    # one ladder run (one server lifetime): a low step and one at ~0.5 x the v5 pilot max (u80: the u50 pilot max; no
    # u80 pilot exists), no SLO abort; Megalon also with MEGALON_COH_TIMERS=0 at the same rates (instrumentation
    # overhead); closure checks v1-check.py after every run (a FAIL stops the block). Order: all-HWcc / Megalon runs
    # shuffled (dax0.0 comsys), then dax0.0 back to root:root 600, then Popcorn (its own shm cycle per run).
    : "${C8:?}" "${GT8:?}" "${RECV_MODE:?}" "${KEYS:?}"
    LOW=${V1_LOW:-2000}
    hi() {  # system mix -> high rate (requests/s); V1_HI_<sys>_<mix> overrides
      local v="V1_HI_$1_$2"; [ -n "${!v:-}" ] && { echo "${!v}"; return; }
      # mg-u5 = hw-u5 (v1.5: the timers-off Megalon run needs the all-HWcc rates for C_diff; v1.3/v1.4 used 63,900)
      case $1-$2 in hw-u5) echo 64300;; mg-u5) echo 64300;; pop-u5) echo 16400;;
                    hw-u80) echo 44000;; mg-u80) echo 44000;; pop-u80) echo 9700;; esac; }
    # dmesg stop rule: line counts after the precheck; after every run, new lines matching BAD on either VM stop
    BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
    dcount() {  # vm -> integer dmesg line count; rc 1 on an ssh failure or a non-integer
      local c; c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1
      [[ $c =~ ^[0-9]+$ ]] || return 1; echo "$c"
    }
    for i in 0 1; do
      c=$(dcount $i) || { echo "SEQUENCE STOP: dmesg baseline vm$i: ssh failed or the count is not an integer"; exit 1; }
      echo "$c" > "$E/dmesg-base-vm$i.txt"
    done
    v1chk() {  # run name, system, [timers]
      python3 -I -B $X/v1-check.py "$E/$1" --system $2 ${3:+--timers $3} | tee -a "$E/v1-check.log" | grep -q "V1 CHECK PASS" \
        || { echo "$(date -Is) SEQUENCE STOP: v1-check $1"; exit 1; }
      local i n c
      for i in 0 1; do
        n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null)
        [[ $n =~ ^[0-9]+$ ]] || { echo "$(date -Is) SEQUENCE STOP: dmesg baseline of vm$i ('$n') is not an integer"; exit 1; }
        c=$(dcount $i) || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1: ssh failed or the count is not an integer"; exit 1; }
        [ "$c" -ge "$n" ] || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1: line count went down ($n -> $c), ring buffer wrapped"; exit 1; }
        $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 \
          || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1: ssh failed reading the new lines"; exit 1; }
        grep -E "$BAD" "$E/dmesg-new-$1-vm$i.txt" > /dev/null \
          && { echo "$(date -Is) SEQUENCE STOP: new dmesg error/warning on vm$i after $1: $(grep -E "$BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)"; exit 1; }
      done
      true
    }
    ORD=$(shuffle hw:u5 hw:u80 mg:u5 mg:u80 mgoff:u5 mgoff:u80)
    echo "# KV-V1 order (shuffle seed $OWNER): $ORD then pop:u5 pop:u80; keys $KEYS batch 16; low $LOW req/s" | tee "$E/order.txt"
    dax_comsys_all
    for sm in $ORD; do
      s=${sm%%:*} m=${sm#*:}; u=0.05; [ $m = u80 ] && u=0.8
      case $s in
        hw)    run hw-$m-val SYS=all-HWcc PUT_RATIO=$u KIND=ladder RATES=$LOW,$(hi hw $m) KEYS=$KEYS READY_TIMEOUT=1800; v1chk hw-$m-val all-HWcc;;
        mg)    run mg-$m-val SYS=Megalon PUT_RATIO=$u KIND=ladder RATES=$LOW,$(hi mg $m) KEYS=$KEYS COH_TIMERS=1 READY_TIMEOUT=1800; v1chk mg-$m-val Megalon on;;
        mgoff) run mg-$m-val-toff SYS=Megalon PUT_RATIO=$u KIND=ladder RATES=$LOW,$(hi mg $m) KEYS=$KEYS COH_TIMERS=0 READY_TIMEOUT=1800; v1chk mg-$m-val-toff Megalon off;;
      esac
    done
    dax_root_all || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600 before Popcorn"; exit 1; }; CHOWNED=0
    for m in u5 u80; do
      u=0.05; [ $m = u80 ] && u=0.8
      run pop-$m-val SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE PUT_RATIO=$u KIND=ladder RATES=$LOW,$(hi pop $m) KEYS=$KEYS READY_TIMEOUT=1800
      v1chk pop-$m-val Popcorn
    done
    # Megalon C by the difference method (user decision 2026-10-17): T(mg timers off) - T(all-HWcc) per rate and op,
    # split by the timers-on sampled parts; Popcorn T(pop) - T(hw) cross-check where the rates match (low step)
    for m in u5 u80; do
      python3 -I -B $X/cdiff.py --hw "$E/hw-$m-val" --mgoff "$E/mg-$m-val-toff" --mg "$E/mg-$m-val" --pop "$E/pop-$m-val" \
        --workload kv --out "$E/cdiff-$m.txt" >> "$E/v1-check.log" 2>&1 || { echo "$(date -Is) SEQUENCE STOP: cdiff $m"; exit 1; }
      tail -n 1 "$E/cdiff-$m.txt"
    done;;
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
ptcheck end
echo "$(date -Is) SEQUENCE DONE $OWNER"

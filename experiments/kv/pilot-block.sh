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
#   idle: low-rate latency check: one all-HWcc ladder run (KIND=ladder, RATES, KEYS) tagged CTAG (Host C-state setting,
#        recorded from sysfs before the run).
#   hmtrace: only the traced 0.5 windows of all-HWcc and Megalon (shuffled) at L from an earlier hm block (LREF), e.g.
#        after an hm block that stopped at its ptrace runs.
# env: MEGALON_BUILD_N (75 = CohSnap incl. the KV path + AnchorSnap; the Megalon build the kv-megalon
#   build must name), MIXES (main block: put ratios, default MOT1 v6 "0.05 0.5 0.8" = get/put 95/5, 50/50, 20/80),
#   PIN (harness commit), BUILD_PIN (commit the builds were made from; default PIN; every build manifest must name
#   it with dirty=0, and the server/loadgen sources must not differ between BUILD_PIN and PIN), KV_CFG, K8.
# Holds the measurement lock for the whole block; stops at the first PILOTRUN STOP. On every exit: this block's servers
# stopped, page MSI teardown of every attempted load, /dev/dax0.0 back to root:root 600 on both VMs UNCONDITIONALLY
# (fresh stat check per VM; "ROLLBACK FAIL" otherwise), lock released.
set -uo pipefail
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
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="KV-pilot-$B"; [ "$B" = main ] && OWNER="KV-main-h1"
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
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_l() {  # 0.5 x the confirm mean of an SLO run without a note (a noted run is never used for L)
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{})
if s.get("note"): sys.exit("note: " + s["note"])
x=c.get("x_mean",0); assert x > 0, "no confirm result"; print(round(0.5 * x, 3))' "$1"
}
tag() { case $1 in 0) echo u0;; 0.05) echo u5;; 0.2) echo u20;; 0.5) echo u50;; 0.8) echo u80;; esac; }
precheck() {
  local i f files="${VP#/home/comsys/}/bin/kv-server ${VP#/home/comsys/}/bin/kv-node.sh ${VP#/home/comsys/}/lib/libkv-megalon.so ${VP#/home/comsys/}/lib/libmegalon.so ${VP#/home/comsys/}/cfg/cxl_region.yaml ${VP#/home/comsys/}/cfg/megalon.yaml ${VM#/home/comsys/}/bin/kv-server ${VM#/home/comsys/}/lib/libkv-megalon.so ${VM#/home/comsys/}/lib/libmegalon.so ${VM#/home/comsys/}/cfg/cxl_region.yaml ${VM#/home/comsys/}/cfg/megalon.yaml"
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$K8 INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || { echo "SEQUENCE STOP: precheck ${IPS[$i]}"; exit 1; }
    for f in "${VP#/home/comsys/}/bin/kv-server $BP/bin/kv-server" "${VP#/home/comsys/}/lib/libkv-megalon.so $BP/lib/libkv-megalon.so" \
             "${VP#/home/comsys/}/lib/libmegalon.so $BP/lib/libmegalon.so" "${VM#/home/comsys/}/bin/kv-server $BM/bin/kv-server" \
             "${VM#/home/comsys/}/lib/libkv-megalon.so $BM/lib/libkv-megalon.so" "${VM#/home/comsys/}/lib/libmegalon.so $BM/lib/libmegalon.so" \
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
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
echo "$(date -Is) SEQUENCE DONE $OWNER"

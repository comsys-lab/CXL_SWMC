#!/bin/bash
# One KV pilot block (reports/M5-pilot-kv.md): a fixed list of pilot-run.sh runs on page MSI build 8 (all systems on
# the same kernel; all-HWcc and Megalon with cxl_shm unloaded, as the M5 HNSW pilots).
# usage: pilot-block.sh <block> <evidence dir (exists, empty except sequence.*)>
#   hm:  functional all-HWcc and Megalon (put ratio 0.5); pilot SLO searches all-HWcc and Megalon at put ratio
#        0.05 (H1), 0 and 0.5 (H2) (order shuffled); then 30 s fixed-load windows at L = 0.5 x the all-HWcc result at
#        the same ratio (shuffled; TRACE=1 at 0.5).
#   pop: page MSI (C8 K8 GT8 RECV_MODE): functional (0.5), pilot SLO searches at 0.05 / 0 / 0.5 (shuffled), fixed-load
#        windows at L from the hm block (LREF = its evidence dir; TRACE=1 at 0.5).
# Holds the measurement lock for the whole block; stops at the first PILOTRUN STOP; the hm block rolls /dev/dax0.0
# back to root:root 600 at its end or on a stop; page MSI runs tear down per run (and leave dax0.0 root:root 600).
set -uo pipefail
B=$1 E=$2
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/kv G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
K8=${K8:-6.14.0-famfs-de-stijl+-ds-popcorn-new-8}
VP=${VM_PLAIN:-/home/comsys/kv2} VM=${VM_MEG:-/home/comsys/kvm2}
BP=${PLAIN_BUILD:-$P/builds/kv/2} BM=${MEG_BUILD:-$P/builds/kv-megalon/2}
CFG=${KV_CFG:?KV_CFG = the megalon.yaml install.sh wrote (<install log>.megalon.yaml)}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="KV-pilot-$B"
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
grep -q "^megalon_build=$P/builds/megalon/70$" "$BM/manifest.txt" && grep -q "^source_commit=.* dirty=0$" "$BM/manifest.txt" \
  || { echo "SEQUENCE STOP: $BM is not a clean build on builds/megalon/70"; exit 2; }
grep -q "^source_commit=.* dirty=0$" "$BP/manifest.txt" && grep -q "^megalon.flavor=hwcc$" "$BP/manifest.txt" \
  || { echo "SEQUENCE STOP: $BP is not a clean hwcc-flavor build"; exit 2; }
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
  if [ $CHOWNED = 1 ]; then
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
        < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
    done
  fi
  bash $G unlock "$OWNER"
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
tag() { case $1 in 0) echo u0;; 0.05) echo u5;; 0.2) echo u20;; 0.5) echo u50;; esac; }
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
  hm)
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
      CHOWNED=1
      grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
    done
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
      tr=0; [ $u = 0.5 ] && tr=1
      run $s-$(tag $u)-pfix SYS=$S PUT_RATIO=$u KIND=pfix RATE=$r TRACE=$tr
    done;;
  pop)
    : "${C8:?}" "${GT8:?}" "${RECV_MODE:?}" "${LREF:?}"
    PE=(SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE)
    run pop-u50-func "${PE[@]}" PUT_RATIO=0.5 KIND=functional GATE=0
    for u in $(shuffle 0.05 0 0.5); do run pop-$(tag $u)-pslo "${PE[@]}" PUT_RATIO=$u KIND=pslo; done
    for u in $(shuffle 0.05 0 0.5); do
      r=$(confirm_l $LREF/hw-$(tag $u)-pslo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for $u in $LREF"; exit 1; }
      echo "pop u=$u L = 0.5 x $LREF/hw-$(tag $u)-pslo = $r requests/s" >> "$E/fixed-load-L.txt"
      tr=0; [ $u = 0.5 ] && tr=1
      run pop-$(tag $u)-pfix "${PE[@]}" PUT_RATIO=$u KIND=pfix RATE=$r TRACE=$tr
    done;;
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
echo "$(date -Is) SEQUENCE DONE $OWNER"

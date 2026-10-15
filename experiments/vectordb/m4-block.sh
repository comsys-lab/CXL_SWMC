#!/bin/bash
# One M4 block (reports/M4-vdb-packet.md §3): a fixed list of m4-run.sh runs on one kernel, in a recorded order.
# usage: m4-block.sh <block> <round> <evidence dir (exists, empty)>
#   block p1:  Popcorn build 8, update 5%: functional (poll), SLO search per recv_mode (order shuffled), then a
#              60 s fixed-load window per recv_mode at L = 0.5 x the best of the three SLO results.
#   block pop: Popcorn build 8 (RECV_MODE): functional (round 1), SLO search for U in {0,5,20,50} (shuffled);
#              round 2 adds the fixed-load windows U in {5,20,50} at L = 0.5 x all-HWcc round 1 (LREF).
#   block van: vanilla kernel: functional all-HWcc and Megalon (round 1), SLO search for {all-HWcc, Megalon} x U
#              (shuffled); round 1 adds the fixed-load windows (all-HWcc and Megalon, U in {5,20,50}; Megalon U 20/50
#              with TRACE=1, U 5 TRACE=0; L from this block's all-HWcc SLO results).
# env: Popcorn blocks C8 K8 GT8 (and RECV_MODE for pop); pop round 2: LREF (van round-1 evidence dir);
#      KV (vanilla release, default 6.14.0-vanilla-1). Every run: m4-run.sh (Host gate, checks, E1).
# Holds the measurement lock for the whole block. Stops at the first M4RUN STOP; vanilla blocks then roll back
# /dev/dax0.0 (Popcorn runs tear down per run).
set -uo pipefail
B=$1 R=$2 E=$3
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
KV=${KV:-6.14.0-vanilla-1}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
OWNER="M4-$B-r$R"
bash $X/host-gate.sh lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
CHOWNED=0
finish() {
  if [ $CHOWNED = 1 ]; then  # vanilla blocks: rollback (standing grant A2)
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'for r in /home/comsys/vdb8/runs/*/ /home/comsys/vdbm5/runs/*/; do for k in 0 1; do [ -e $r/node$k.pid ] && /home/comsys/vdb8/bin/vdb-node.sh stop $r $k > /dev/null; done; done; echo procs=$(pgrep -c -x vdb-server); sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
        < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
    done
  fi
  bash $X/host-gate.sh unlock "$OWNER"
}
trap finish EXIT
run() {  # name, env assignments...
  local name=$1; shift
  env "$@" bash $X/m4-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^M4RUN|SEQUENCE" ; local st=${PIPESTATUS[0]}
  [ $st = 0 ] || { echo "$(date -Is) SEQUENCE STOP at $name"; exit 1; }
}
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_x() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1])).get("confirm",{}); print(c.get("x_mean",0))' "$1"; }
rate() { python3 -c 'import sys; x,u=float(sys.argv[1]),float(sys.argv[2]); assert x>0; print(round(0.5*x/(1-u/100),3))' "$1" "$2"; }
precheck() {  # kernel release
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$1 INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) bash -s" < $X/m4-precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || { echo "SEQUENCE STOP: precheck ${IPS[$i]}"; exit 1; }
    for f in "vdb8/bin/vdb-server $P/builds/vdb/8/bin/vdb-server" "vdbm5/bin/vdb-server $P/builds/vdb-megalon/5/bin/vdb-server" \
             "vdbm5/lib/libvdb-megalon.so $P/builds/vdb-megalon/5/lib/libvdb-megalon.so" \
             "vdbm5/lib/libmegalon.so $P/builds/vdb-megalon/5/lib/libmegalon.so" \
             "vdbm5/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/vectordb-2vm.yaml" \
             "vdb8/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" "vdbm5/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"; do
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" \
        || { echo "SEQUENCE STOP: ${IPS[$i]} /home/comsys/$1 != $2"; exit 1; }
    done
  done
}
echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD))"
case "$B" in
  p1)
    : "${C8:?}" "${K8:?}" "${GT8:?}"
    precheck "$K8"
    run pop-u5-func-poll SYS=Popcorn U=5 KIND=functional RECV_MODE=poll GATE=0 C8=$C8 K8=$K8 GT8=$GT8
    for m in $(shuffle poll idle sleep); do run pop-u5-slo-$m SYS=Popcorn U=5 KIND=slo RECV_MODE=$m C8=$C8 K8=$K8 GT8=$GT8; done
    best=$(for m in poll idle sleep; do confirm_x $E/pop-u5-slo-$m/loadgen/summary.json; done | sort -g | tail -1)
    r=$(rate "$best" 5) || { echo "SEQUENCE STOP: no SLO result"; exit 1; }
    echo "fixed-load L: 0.5 x best $best search/s -> total rate $r" | tee "$E/fixed-load-L.txt"
    for m in $(shuffle poll idle sleep); do run pop-u5-fix-$m SYS=Popcorn U=5 KIND=fixed RATE=$r RECV_MODE=$m C8=$C8 K8=$K8 GT8=$GT8; done;;
  pop)
    : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
    precheck "$K8"
    PE=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE REP=r$R)
    [ "$R" = 1 ] && run pop-u5-func SYS=Popcorn U=5 KIND=functional GATE=0 "${PE[@]}"
    for u in $(shuffle 0 5 20 50); do run pop-u$u-slo-r$R SYS=Popcorn U=$u KIND=slo "${PE[@]}"; done
    if [ "$R" = 2 ]; then
      : "${LREF:?}"
      for u in $(shuffle 5 20 50); do
        r=$(rate "$(confirm_x $LREF/hw-u$u-slo-r1/loadgen/summary.json)" $u) || { echo "SEQUENCE STOP: L for u$u"; exit 1; }
        echo "u$u L from $LREF/hw-u$u-slo-r1: total rate $r" >> "$E/fixed-load-L.txt"
        run pop-u$u-fix SYS=Popcorn U=$u KIND=fixed RATE=$r "${PE[@]}"
      done
    fi;;
  van)
    precheck "$KV"
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
      CHOWNED=1
      grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
    done
    if [ "$R" = 1 ]; then
      run hw-u5-func SYS=all-HWcc U=5 KIND=functional GATE=0
      run mg-u5-func SYS=Megalon U=5 KIND=functional GATE=0
    fi
    for su in $(shuffle hw:0 hw:5 hw:20 hw:50 mg:0 mg:5 mg:20 mg:50); do
      s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
      run $s-u$u-slo-r$R SYS=$S U=$u KIND=slo REP=r$R
    done
    if [ "$R" = 1 ]; then
      for su in $(shuffle hw:5 hw:20 hw:50 mg:5 mg:20 mg:50); do
        s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
        t=0; [ $s = mg ] && [ $u != 5 ] && t=1
        r=$(rate "$(confirm_x $E/hw-u$u-slo-r1/loadgen/summary.json)" $u) || { echo "SEQUENCE STOP: L for u$u"; exit 1; }
        echo "$s u$u L from hw-u$u-slo-r1: total rate $r trace=$t" >> "$E/fixed-load-L.txt"
        run $s-u$u-fix SYS=$S U=$u KIND=fixed RATE=$r TRACE=$t
      done
    fi;;
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
echo "$(date -Is) SEQUENCE DONE $OWNER"

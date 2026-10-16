#!/bin/bash
# LMDB-F1 block (reports/LMDB-F1-packet.md): first functional run of the shared LMDB on the 2 VMs, all-HWcc (plain) and
# Megalon, after H0 (Host image + gate). Holds the measurement/VM lock (host-gate.sh lock LMDB-F1-v1) for the whole
# block, from G1 (install.sh) to the rollback; on EVERY exit: this block's lmdb processes stopped on both VMs, /dev/dax0.0 back to root:root 600
# on both VMs (fresh stat check per VM; "ROLLBACK FAIL" otherwise), lock released. Stops at the first unexpected result.
# usage: f1-block.sh <evidence dir (exists; empty except gate-H0.txt / tasks-check.txt / image.log)>
# env: POPCORN (0; 1 adds Part P: Popcorn build >= 10 runs, needs C8 K8 GT8 RECV_MODE as experiments/kv/pilot-block),
#   IMG (Host image dir from H0; required), EXPECT_K (guest kernel release, as recorded in state/HANDOFF.md; required), PLAIN_BUILD / MEG_BUILD /
#   LOADGEN_BUILD (pilot-run.sh defaults; PLAIN_BUILD also gives the Host lmdb-server for --print-app-bytes)
set -uo pipefail
E=$1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/lmdb G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
: "${EXPECT_K:?EXPECT_K = guest kernel release}" "${IMG:?IMG = Host image dir (H0)}"
[ "${POPCORN:-0}" = 0 ] || : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
OWNER=LMDB-F1-v1 L=/home/comsys/lmdb R=1000000 MAXP=600000
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -vE '^(gate-H0\.txt|tasks-check\.txt|image\.log)$')" ] || { echo "BLOCK STOP: $E missing or not empty"; exit 2; }
[ -s "$E/tasks-check.txt" ] || { echo "BLOCK STOP: $E/tasks-check.txt missing (state/TASKS.md: no other active VM user)"; exit 2; }
bash $G lock $OWNER || { echo "BLOCK STOP: lock"; exit 2; }
finish() {
  if [ "${POPCORN:-0}" = 1 ]; then  # Popcorn: tear down every attempted cxl_shm load without "teardown PASS"
    for r in "$E"/shm-*/; do
      r=${r%/}; [ -f "$r/load-vm0.txt" ] || continue
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
      env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r" | tee -a "$E/cleanup.out"
    done
  fi
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'pkill -x lmdb-server; pkill -x lmdb-stress; sleep 2; echo procs=$(pgrep -c -x lmdb-server)/$(pgrep -c -x lmdb-stress)' < /dev/null 2>&1 | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0); dmesg | tail -n 5' < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "stat=root:root 600" || echo "ROLLBACK FAIL: $ip dax0.0 not root:root 600" | tee -a "$E/rollback.out"
  done
  bash $G unlock $OWNER
}
trap finish EXIT
stop() { echo "$(date -Is) BLOCK STOP $*" | tee -a "$E/block.log"; exit 1; }
step() { echo "$(date -Is) == $*" | tee -a "$E/block.log"; }

step "G1 install"
IMG=$IMG bash $X/install.sh "$E/install.log" > "$E/install.out" 2>&1 || stop "install"
grep -q "^ldd_not_found=0$" "$E/install.log" && [ "$(grep -c '^ldd_not_found=0$' "$E/install.log")" = 2 ] || stop "install: ldd"
BP=${PLAIN_BUILD:-$P/builds/lmdb/7} BM=${MEG_BUILD:-$P/builds/lmdb-megalon/7}
want="$(sha256sum < $BP/bin/lmdb-server | cut -c1-64) $(sha256sum < $BM/bin/lmdb-server | cut -c1-64) $(sha256sum < $BM/lib/libmegalon-objapi.so | cut -c1-64) $(sha256sum < $BM/lib/libmegalon.so | cut -c1-64) $(sha256sum < $P/CXL_SWMC/config/cxl_region.yaml | cut -c1-64) $(sha256sum < $E/install.log.megalon.yaml | cut -c1-64)"
for i in 0 1; do
  got=$($SSH comsys@${IPS[$i]} "cd $L && for f in plain/bin/lmdb-server megalon/bin/lmdb-server megalon/lib/libmegalon-objapi.so megalon/lib/libmegalon.so plain/cfg/cxl_region.yaml megalon/cfg/megalon.yaml; do sha256sum < \$f | cut -c1-64; done | tr '\n' ' '" < /dev/null)
  [ "${got% }" = "$want" ] || stop "install sha256 vm$i: [$got] != [$want]"
done
want_img="$(sha256sum < $IMG/pages.bin | cut -c1-64)"
[ "$($SSH comsys@${IPS[0]} "sha256sum < $L/img-$R/pages.bin | cut -c1-64" < /dev/null)" = "$want_img" ] || stop "image sha256 vm0"
step "G2 pre-check"
for i in 0 1; do
  ip=${IPS[$i]}
  $SSH comsys@$ip "EXPECT_K=$EXPECT_K INSTALL_FILES='lmdb/plain/bin/lmdb-server lmdb/megalon/bin/lmdb-server lmdb/megalon/lib/libmegalon-objapi.so' bash -s" \
    < $P/CXL_SWMC/experiments/kv/precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i"
  $SSH comsys@$ip 'echo lmdb_procs=$(pgrep -c -x lmdb-server)/$(pgrep -c -x lmdb-stress); dmesg | tail -n 5' < /dev/null >> "$E/precheck-vm$i.txt" 2>&1
  grep -q "^lmdb_procs=0/0$" "$E/precheck-vm$i.txt" || stop "lmdb process on vm$i"
done
step "G3 chown"
for i in 0 1; do
  $SSH comsys@${IPS[$i]} 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-vm$i.out" 2>&1
  grep -qx "comsys:root 600" "$E/chown-vm$i.out" || stop "chown vm$i"
done

# lmdb-stress pair with ONE run id for both nodes; node 1 starts after node 0 printed its node line.
# $1 tag, $2 backend dir (plain|megalon), $3 timeout s per node (stop rule bound), $4.. extra args (both nodes)
stress() {
  local tag=$1 bd=$2 to=$3; shift 3
  local rid=0x$(openssl rand -hex 6) app ev0="" ev1=""
  app=$(${PLAIN_BUILD:-$P/builds/lmdb/7}/bin/lmdb-server --print-app-bytes --nodes 2 --readers 32 --max-pages $MAXP --records $R)
  [ "$bd" = megalon ] && ev0="RACKOBJ_CONFIG=$L/megalon/cfg/megalon.yaml MEGALON_REINIT=1" ev1="RACKOBJ_CONFIG=$L/megalon/cfg/megalon.yaml"
  local A="--nodes 2 --run-id $rid --region $L/$bd/cfg/cxl_region.yaml --max-pages $MAXP --records $R --seconds 30 --reader-threads 4 --hold-us 2000 --keys-per-txn 4 --backend $bd $*"
  echo "$tag run_id=$rid app=$app args=$A" >> "$E/block.log"
  $SSH comsys@${IPS[0]} "cd $L && env CXL_APP_HWCC_BYTES=$app $ev0 timeout $to $bd/bin/lmdb-stress --node 0 --image $L/img-$R $A ${NODE0_STRESS:-}" \
    < /dev/null > "$E/$tag.0.out" 2> "$E/$tag.0.err" &
  local p0=$! t0=$SECONDS
  until grep -q "lmdb-stress: node 0/2" "$E/$tag.0.err" 2>/dev/null; do
    kill -0 $p0 2>/dev/null || stop "$tag: node 0 exited before its node line"
    [ $((SECONDS - t0)) -lt 120 ] || stop "$tag: no node 0 line in 120 s"
    sleep 1
  done
  $SSH comsys@${IPS[1]} "cd $L && env CXL_APP_HWCC_BYTES=$app $ev1 timeout $to $bd/bin/lmdb-stress --node 1 $A" \
    < /dev/null > "$E/$tag.1.out" 2> "$E/$tag.1.err"
  local r1=$?; wait $p0; local r0=$?
  echo "$tag rc0=$r0 rc1=$r1 wall_s=$((SECONDS - t0))" | tee -a "$E/block.log"
  grep -h "RESULT\|final scan\|write_txn_us" "$E/$tag.0.out" "$E/$tag.1.out" | tee -a "$E/block.log"
  [ $r0 = 0 ] && [ $r1 = 0 ] && [ "$(grep -c 'RESULT PASS' "$E/$tag.0.out" "$E/$tag.1.out" | awk -F: '{s+=$2} END {print s}')" = 2 ] \
    && grep -q "final scan .* entries=$R .*bad=0 end=ok" "$E/$tag.0.out" || stop "$tag"
}
run() {  # name, env...
  local name=$1; shift
  step "$name"
  env LOCK_OWNER=$OWNER "$@" bash $X/pilot-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  [ ${PIPESTATUS[0]} = 0 ] || stop "$name"
  grep -q "^PILOTRUN $name OK" "$E/runs.log" || stop "$name not OK"
  local sys; for x in "$@"; do case $x in SYS=*) sys=${x#SYS=};; esac; done
  # closure checks (opsplit vs server counters; all-HWcc C = 0, Megalon C > 0, Popcorn C > 0 via swmc_acct)
  python3 -I $P/CXL_SWMC/experiments/kv/v1-check.py "$E/$name" --system $sys --workload lmdb | tee -a "$E/v1-check.log" \
    | grep -q "V1 CHECK PASS" || stop "$name: v1-check"
}
PL=(VM_PLAIN=$L/plain IMAGE=$L/img-$R RECORDS=$R MAX_PAGES=$MAXP KIND=functional GATE=0 RATES=200,1000)
ML=(VM_MEG=$L/megalon IMAGE=$L/img-$R RECORDS=$R MAX_PAGES=$MAXP KIND=functional GATE=0 RATES=200,1000 PREPARE_THREADS=8)
step "A1 plain stress"; stress A1-stress-plain plain 300
run hw-u50-func SYS=all-HWcc UPDATE_RATIO=0.5 LOG=1 "${PL[@]}"
run hw-u5-func SYS=all-HWcc UPDATE_RATIO=0.05 "${PL[@]}"
run hw-u80-func SYS=all-HWcc UPDATE_RATIO=0.8 "${PL[@]}"
step "B1 Megalon stress"; NODE0_STRESS="--prepare-threads 8" stress B1-stress-megalon megalon 1200
run mg-u50-func SYS=Megalon UPDATE_RATIO=0.5 LOG=1 "${ML[@]}"
run mg-u5-func SYS=Megalon UPDATE_RATIO=0.05 "${ML[@]}"
run mg-u80-func SYS=Megalon UPDATE_RATIO=0.8 "${ML[@]}"
if [ "${POPCORN:-0}" = 1 ]; then  # Part P: dax0.0 back to root:root 600 (p-popcorn-shm.sh owns chown/teardown)
  step "P0 dax0.0 root before Popcorn"
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' < /dev/null 2>&1)
    echo "$ip $out" >> "$E/block.log"; echo "$out" | grep -qx "stat=root:root 600" || stop "dax0.0 root on $ip"
  done
  PP=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE)
  run pop-u50-func SYS=Popcorn UPDATE_RATIO=0.5 LOG=1 "${PL[@]}" "${PP[@]}"
  run pop-u80-func SYS=Popcorn UPDATE_RATIO=0.8 "${PL[@]}" "${PP[@]}"
fi
step "BLOCK DONE"

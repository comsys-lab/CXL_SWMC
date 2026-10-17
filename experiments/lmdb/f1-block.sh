#!/bin/bash
# LMDB-F1 block (reports/LMDB-F1-packet.md): first functional run of the shared LMDB on the 2 VMs, all-HWcc (plain) and
# Megalon, after H0 (Host image + gate). Holds the measurement/VM lock (host-gate.sh lock LMDB-F1-v1) for the whole
# block, from G1 (install.sh) to the rollback; on EVERY exit: this block's lmdb processes stopped on both VMs, /dev/dax0.0 back to root:root 600
# on both VMs (fresh stat check per VM; "ROLLBACK FAIL" otherwise), lock released. Stops at the first unexpected result.
# usage: f1-block.sh <evidence dir (exists; empty except tasks-check.txt / block.out)>
# Steps: lock, G0 image (Host, IMG must not exist), H0 Host gate, G1 install, G2 pre-check, dmesg baseline, G3 chown,
# A1..B3 [, P0..P2]; after every stress pair and pilot-run a dmesg check (new lines matching DMESG_BAD stop the block).
# env: POPCORN (0; 1 adds Part P: Popcorn build >= 10 runs, needs C8 K8 GT8 RECV_MODE as experiments/kv/pilot-block),
#   IMG (Host image dir to create in G0; must not exist; required), EXPECT_K (guest kernel release, as recorded in state/HANDOFF.md; required), PLAIN_BUILD / MEG_BUILD /
#   LOADGEN_BUILD (pilot-run.sh defaults; PLAIN_BUILD also gives the Host lmdb-server for --print-app-bytes),
#   PRETOUCH_DIR (required): the ENV-pretouch evidence dir of the VMs' current QEMU lifetime; experiments/kv/pretouch-check.sh
#     must PASS under the lock before G0 and again before BLOCK DONE (standing rule 2026-10-17: whole dax0.0
#     pre-touched on each VM after every QEMU start, before any measurement),
#   LMDB_GUEST_DIR (guest install dir, new; default /home/comsys/lmdb; install.sh refuses an existing one),
#   BUILD_PIN + MEGALON_BUILD_N (optional, set together): both lmdb build manifests must name source_commit=BUILD_PIN
#     dirty_files=0, MEG_BUILD must be on builds/megalon/MEGALON_BUILD_N, and the loadgen manifest must name BUILD_PIN
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # never write __pycache__ (harness snapshots live in recovery/); every python3 call also has -B
E=$1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/lmdb G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
: "${EXPECT_K:?EXPECT_K = guest kernel release}" "${IMG:?IMG = Host image dir to create (G0)}"
[ "${POPCORN:-0}" = 0 ] || : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
[ "${POPCORN:-0}" = 0 ] || [ "$EXPECT_K" = "$K8" ] || { echo "BLOCK STOP: POPCORN=1 needs EXPECT_K = K8 (the Popcorn release)"; exit 2; }
OWNER=LMDB-F1-v1 L=${LMDB_GUEST_DIR:-/home/comsys/lmdb} R=1000000 MAXP=600000
: "${PRETOUCH_DIR:?PRETOUCH_DIR = ENV-pretouch evidence dir of the current QEMU lifetime (standing pretouch rule)}"
case "$L" in /home/comsys/?*) ;; *) echo "BLOCK STOP: LMDB_GUEST_DIR must be under /home/comsys/"; exit 2;; esac
if [ -n "${BUILD_PIN:-}" ]; then
  : "${MEGALON_BUILD_N:?MEGALON_BUILD_N with BUILD_PIN}"
  BP0=${PLAIN_BUILD:-$P/builds/lmdb/7} BM0=${MEG_BUILD:-$P/builds/lmdb-megalon/7} BL0=${LOADGEN_BUILD:-$P/builds/lmdb-loadgen/6}
  grep -q "^source_commit=$BUILD_PIN dirty_files=0$" "$BP0/manifest.txt" && grep -q "^source_commit=$BUILD_PIN dirty_files=0$" "$BM0/manifest.txt" \
    && grep -q "^megalon_build=$P/builds/megalon/$MEGALON_BUILD_N$" "$BM0/manifest.txt" \
    && grep -q " cxl_swmc_commit=$BUILD_PIN lmdb_dirty=0$" "$BL0/manifest.txt" \
    && grep -q "^sha256 $(sha256sum "$BL0/loadgen" | cut -d' ' -f1)  " "$BL0/manifest.txt" \
    || { echo "BLOCK STOP: builds $BP0 $BM0 $BL0 are not clean builds of $BUILD_PIN on builds/megalon/$MEGALON_BUILD_N"; exit 2; }
fi
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -vE '^(tasks-check\.txt|block\.out)$')" ] || { echo "BLOCK STOP: $E missing or not empty"; exit 2; }
[ -s "$E/tasks-check.txt" ] || { echo "BLOCK STOP: $E/tasks-check.txt missing (state/TASKS.md: no other active VM user)"; exit 2; }
bash $G lock $OWNER || { echo "BLOCK STOP: lock"; exit 2; }
finish() {  # order as experiments/kv/pilot-block.sh: servers first, then Popcorn teardown, then dax0.0, then unlock
  set +eu  # nothing in the trap may abort it before the unlock
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'pkill -x lmdb-server; pkill -x lmdb-stress; sleep 2; echo procs=$(pgrep -c -x lmdb-server)/$(pgrep -c -x lmdb-stress)' < /dev/null 2>&1 | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
  done
  if [ "${POPCORN:-0}" = 1 ]; then  # Popcorn: tear down every attempted cxl_shm load without "teardown PASS"
    for r in "$E"/shm-*/; do
      r=${r%/}; [ -f "$r/load-vm0.txt" ] || continue
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
      env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
        || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
             && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
      grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: reports/M5-pilot-kv.md §6)" | tee -a "$E/cleanup.out"
    done
  fi
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0); dmesg | tail -n 5' < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "stat=root:root 600" || echo "ROLLBACK FAIL: $ip dax0.0 not root:root 600" | tee -a "$E/rollback.out"
  done
  if [ -n "${DMESG_BASE_DONE:-}" ]; then  # recorded only (the block has already ended); never skips the unlock
    ( dmesg_check final ) > "$E/dmesg-final.out" 2>&1 || echo "$(date -Is) final dmesg check: see dmesg-final.out" >> "$E/rollback.out"
  fi
  bash $G unlock $OWNER
}
# dmesg stop rule: line counts at the block start; after every step, new lines matching DMESG_BAD on either VM stop
DMESG_BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
dmesg_count() {  # vm -> prints the integer line count of that VM's dmesg; rc 1 on an ssh failure or a non-integer
  local c
  c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1
  [[ $c =~ ^[0-9]+$ ]] || return 1
  echo "$c"
}
dmesg_base() {
  local i c
  for i in 0 1; do
    c=$(dmesg_count $i) || stop "dmesg baseline vm$i: ssh failed or the count is not an integer"
    echo "$c" > "$E/dmesg-base-vm$i.txt"
  done
  DMESG_BASE_DONE=1
}
dmesg_check() {  # tag; returns 1 on a new bad line, an ssh failure, a bad stored count or a ring-buffer wrap
  local i n c bad=0
  for i in 0 1; do
    n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || { echo "dmesg vm$i ($1): stored baseline '$n' is not an integer" | tee -a "$E/block.log"; bad=1; continue; }
    c=$(dmesg_count $i) || { echo "dmesg vm$i ($1): ssh failed or the count is not an integer" | tee -a "$E/block.log"; bad=1; continue; }
    [ "$c" -ge "$n" ] || { echo "dmesg vm$i ($1): line count went down ($n -> $c): ring buffer wrapped, new lines unknown" | tee -a "$E/block.log"; bad=1; continue; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 \
      || { echo "dmesg vm$i ($1): ssh failed reading the new lines" | tee -a "$E/block.log"; bad=1; continue; }
    grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" > /dev/null && { echo "dmesg vm$i ($1): $(grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)" | tee -a "$E/block.log"; bad=1; }
  done
  return $bad
}
trap finish EXIT
stop() { echo "$(date -Is) BLOCK STOP $*" | tee -a "$E/block.log"; exit 1; }
step() { echo "$(date -Is) == $*" | tee -a "$E/block.log"; }

step "PT pretouch check (start)"
bash $P/CXL_SWMC/experiments/kv/pretouch-check.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start), see pretouch-check-start.txt"
step "G0 image (Host, under the lock, after the owner check)"
[ -e "$IMG" ] && stop "image dir $IMG exists"
nice -n 19 numactl --cpunodebind=1 --membind=1 ${PLAIN_BUILD:-$P/builds/lmdb/7}/bin/lmdb-image --out "$IMG" --records $R 2> "$E/image.log" || stop "image"
grep -q "^records=$R$" "$IMG/meta.txt" && grep -q "^entries=$R$" "$IMG/meta.txt" || stop "image meta"
tail -n 2 "$E/image.log" >> "$E/block.log"
step "H0 Host gate (after the image build)"
bash $G check "$E/gate-H0.txt" || stop "host gate"
step "G1 install"
IMG=$IMG L=$L bash $X/install.sh "$E/install.log" > "$E/install.out" 2>&1 || stop "install"
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
  $SSH comsys@$ip "EXPECT_K=$EXPECT_K INSTALL_FILES='${L#/home/comsys/}/plain/bin/lmdb-server ${L#/home/comsys/}/megalon/bin/lmdb-server ${L#/home/comsys/}/megalon/lib/libmegalon-objapi.so' bash -s" \
    < $P/CXL_SWMC/experiments/kv/precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i"
  $SSH comsys@$ip 'echo lmdb_procs=$(pgrep -c -x lmdb-server)/$(pgrep -c -x lmdb-stress); dmesg | tail -n 5' < /dev/null >> "$E/precheck-vm$i.txt" 2>&1
  grep -q "^lmdb_procs=0/0$" "$E/precheck-vm$i.txt" || stop "lmdb process on vm$i"
done
dmesg_base
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
  dmesg_check "$tag" || stop "$tag: dmesg check failed (new error/warning line, ssh failure or wrap; see block.log)"
}
run() {  # name, env...
  local name=$1; shift
  step "$name"
  env LOCK_OWNER=$OWNER "$@" bash $X/pilot-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  [ ${PIPESTATUS[0]} = 0 ] || stop "$name"
  grep -q "^PILOTRUN $name OK" "$E/runs.log" || stop "$name not OK"
  local sys; for x in "$@"; do case $x in SYS=*) sys=${x#SYS=};; esac; done
  # closure checks (opsplit vs server counters; all-HWcc C = 0, Megalon C > 0, Popcorn C > 0 via swmc_acct)
  python3 -I -B $P/CXL_SWMC/experiments/kv/v1-check.py "$E/$name" --system $sys --workload lmdb | tee -a "$E/v1-check.log" \
    | grep -q "V1 CHECK PASS" || stop "$name: v1-check"
  dmesg_check "$name" || stop "$name: dmesg check failed (new error/warning line, ssh failure or wrap; see block.log)"
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
step "PT pretouch check (end)"
bash $P/CXL_SWMC/experiments/kv/pretouch-check.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end), see pretouch-check-end.txt"
step "BLOCK DONE"

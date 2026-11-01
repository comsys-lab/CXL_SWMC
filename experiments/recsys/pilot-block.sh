#!/bin/bash
# The recommendation-system pilot block (reports/RECSYS-design.md §8): every run on the page MSI kernel (build 8, K8):
# all-HWcc and Megalon with cxl_shm unloaded, page MSI with cxl_shm loaded per run (init_state=shared + preload).
# usage: pilot-block.sh k8|ds <evidence dir (exists, empty)>
# Block ds (De Stijl v2; as experiments/eval/h2n-block.sh ds): every run on the De Stijl kernel DS_K, systems hw / mg /
#   ds (no pop: different guest kernel), ds = pilot-run.sh SYS=DeStijl with DS_C DS_K DS_GT (+ DS_BUNDLE_SHA, sha256 of
#   DS_C/packet.sha256), DS_PLAIN_BUILD (Host recsys build dir of the ds runs) and DS_V (its guest install dir below
#   /home/comsys, cfg/cxl_region.yaml = config/cxl_region-destijl.yaml; both checked by the precheck), optional DS_T_US
#   (De Stijl staleness bound T in us of the embedding tables, default 0; servers get CXL_SYSTEM=ds CXL_DESTIJL_T_US;
#   T > 0 needs a DS_PLAIN_BUILD with libdestijl, e.g. builds/recsys/destijl-check). RECSYS_SET default for ds: the k8
#   set with pop replaced by ds (its ":T" entries are the publication interval T_MS, not the staleness bound).
# env: C8 (= builds/popcorn_new/8/deploy-v3, verified: packet.sha256 hash, sha256sum -c, no SUPERSEDED.txt) K8 GT8
#      RECV_MODE (page MSI build 8); MEG_BUILD (recsys-megalon build on builds/megalon/70, default
#      builds/recsys-megalon/4; its manifest must name builds/megalon/70), VM_MEG (default /home/comsys/rsm4).
# Runs (systems chosen by name; RECSYS_SET / RECSYS_FUNC=0 select a subset, defaults = all below):
#   functional (T = 60 s): all-HWcc, Megalon, page MSI
#   pilot SLO searches, order shuffled (seed = owner): all-HWcc T in {60 s, 1 s, 0}; page MSI T in {60 s, 1 s, 0};
#     Megalon T in {60 s (H1), 0 (H3, reported)}
#   30 s fixed-load windows (shuffled) at L = 0.5 x this block's all-HWcc result at the same T: the same 8 (system, T)
# /dev/dax0.0: owned by comsys for all-HWcc/Megalon runs, back to root:root 600 before every page MSI run (its
# p-popcorn-shm.sh precheck needs it; its teardown restores it). Holds workspaces/MEASUREMENT.lock; stops at the first
# PILOTRUN STOP; on every exit: stop this block's servers (incl. a running --preload-only, via its pid file), tear down any page MSI run without "teardown PASS"
# (instr-on retry), dax0.0 back to root:root 600, unlock (pattern of experiments/vectordb/m4-lib.sh block_finish).
set -uo pipefail
B=$1 E=$2
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/recsys G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
: "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
VM_MEG=${VM_MEG:-/home/comsys/rsm4} MB=${MEG_BUILD:-$P/builds/recsys-megalon/4}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="RECSYS-pilot-$B"
# run selection (H1 only: RECSYS_SET="hw:60000 pop:60000 mg:60000" RECSYS_FUNC=0); every T in the set needs its hw:T
CS=pop; [ "$B" = ds ] && CS=ds   # the coherence system of this block's kernel
SET=${RECSYS_SET:-"hw:60000 hw:1000 hw:0 $CS:60000 $CS:1000 $CS:0 mg:60000 mg:0"} FUNC=${RECSYS_FUNC:-1}
for st in $SET; do
  case $st in hw:*|mg:*|$CS:*) ;; *) echo "SEQUENCE STOP: bad RECSYS_SET entry $st (block $B: hw, mg, $CS)"; exit 2;; esac
  [[ "${st#*:}" =~ ^[0-9]+$ ]] && [[ " $SET " == *" hw:${st#*:} "* ]] || { echo "SEQUENCE STOP: RECSYS_SET entry $st (T must be numeric with hw:T in the set)"; exit 2; }
done
case $FUNC in 0|1) ;; *) echo "SEQUENCE STOP: RECSYS_FUNC must be 0 or 1"; exit 2;; esac
[ "$B" = k8 ] || [ "$B" = ds ] || { echo "SEQUENCE STOP: bad block (k8 | ds)"; exit 2; }
KB=$K8   # kernel every run of the block runs on
if [ "$B" = ds ]; then
  : "${DS_C:?}" "${DS_K:?}" "${DS_GT:?}" "${DS_BUNDLE_SHA:?}" "${DS_PLAIN_BUILD:?}" "${DS_V:?}"
  [[ $DS_K == *-ds-destijl-* ]] || { echo "SEQUENCE STOP: DS_K=$DS_K is not a De Stijl release"; exit 2; }
  [[ $DS_V == /home/comsys/?* ]] || { echo "SEQUENCE STOP: DS_V must be a guest dir below /home/comsys"; exit 2; }
  DST=${DS_T_US:-0}
  [[ $DST =~ ^(0|[1-9][0-9]*)$ ]] || { echo "SEQUENCE STOP: bad DS_T_US ($DST)"; exit 2; }
  [ -x "$DS_PLAIN_BUILD/bin/recsys-server" ] || { echo "SEQUENCE STOP: no $DS_PLAIN_BUILD/bin/recsys-server"; exit 2; }
  [ "$DST" = 0 ] || grep -qa de_stijl_set_staleness "$DS_PLAIN_BUILD/bin/recsys-server" \
    || { echo "SEQUENCE STOP: DS_T_US=$DST needs a DS_PLAIN_BUILD with libdestijl"; exit 2; }
  [ -f "$DS_C/p-destijl-shm.sh" ] && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -d' ' -f1)" = "$DS_BUNDLE_SHA" ] \
    && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: DS_C is not the verified De Stijl bundle"; exit 2; }
  KB=$DS_K
fi
grep -q "^megalon_build=$P/builds/megalon/70$" $MB/manifest.txt || { echo "SEQUENCE STOP: $MB is not on builds/megalon/70"; exit 2; }
# page MSI bundle: deploy-v3 of build 8 (what the VMs run; has instr-on and the instr_enabled teardown gate), unchanged
[ "$C8" = $P/builds/popcorn_new/8/deploy-v3 ] && [ ! -e $C8/SUPERSEDED.txt ] \
  && [ "$(sha256sum < $C8/packet.sha256 | cut -d' ' -f1)" = c67fa82b8649c8de5afcfe65f48657555bef0fcb0e635fc36a751689afead5a4 ] \
  && (cd $C8 && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: C8 is not the verified build-8 deploy-v3 bundle"; exit 2; }
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
bash $G lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
CHOWNED=0
stop_servers() {  # this block's servers only (guest run dirs from this block's run manifests)
  local ip g
  for ip in "${IPS[@]}"; do
    for g in $(sed -n 's/^guest_run_dir=//p' "$E"/*/manifest.txt 2>/dev/null) $(cat "$E"/preload-*.dir 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && /home/comsys/rs3/bin/recsys-node.sh stop $g \$k; done; true" < /dev/null 2>&1 \
        | sed "s|^|$ip $g |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip 'echo procs=$(pgrep -c -x recsys-server)' < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
shm_cleanup() {  # page MSI runs whose load was attempted and that have no "teardown PASS"
  local r
  for r in "$E"/shm-*/; do
    r=${r%/}
    [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
    if ! env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; then
      if grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null; then
        env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
          && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1
      fi
    fi
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
  done
  for r in "$E"/dsshm-*/; do  # De Stijl runs (block ds): same rule, p-destijl-shm.sh teardown
    r=${r%/}
    [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
    env K=$DS_K GT=$DS_GT C=$DS_C R=$r bash $DS_C/p-destijl-shm.sh teardown >> "$E/cleanup.out" 2>&1
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"
  done
}
dax_root_all() {  # writes this check's results to a fresh file ($1, default a new numbered file) and to rollback.out
  local ip f=${1:-$E/dax-root-$(date +%s%N).out}
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
      < /dev/null 2>&1 | sed "s/^/$ip /" | tee -a "$E/rollback.out" > "$f.$ip"
  done
  DAXF=$f
}
finish() { stop_servers; shm_cleanup; [ $CHOWNED = 1 ] && dax_root_all; bash $G unlock "$OWNER"; }
trap finish EXIT
trap 'echo "$(date -Is) SEQUENCE STOP: interrupted"; exit 130' INT TERM HUP
dax_comsys() {  # before an all-HWcc / Megalon run
  [ $CHOWNED = 1 ] && return 0
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
  done
}
dax_root() {  # before a page MSI run (no server of ours runs between runs)
  [ $CHOWNED = 1 ] || return 0
  stop_servers; dax_root_all; CHOWNED=0
  local ip
  for ip in "${IPS[@]}"; do
    [ "$(grep -o 'stat=.*' "$DAXF.$ip")" = "stat=root:root 600" ] || { echo "SEQUENCE STOP: dax0.0 on $ip not back to root:root 600"; exit 1; }
  done
}
run() {  # system name, run name, env assignments...
  local s=$1 name=$2; shift 2
  case $s in hw|mg) dax_comsys;; pop|ds) dax_root;; esac
  local SE
  case $s in
    hw) SE=(SYS=all-HWcc);;
    mg) SE=(SYS=Megalon VM_MEG=$VM_MEG HOST_MEG=$MB);;
    pop) SE=(SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE);;
    ds) SE=(SYS=DeStijl DS_C=$DS_C DS_K=$DS_K DS_GT=$DS_GT RECV_MODE=$RECV_MODE DS_T_US=$DST DS_PLAIN_BUILD=$DS_PLAIN_BUILD DS_V=$DS_V);;
  esac
  env "${SE[@]}" "$@" bash $X/pilot-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  local st=${PIPESTATUS[0]}
  [ $st = 0 ] || { echo "$(date -Is) SEQUENCE STOP at $name"; exit 1; }
}
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_half() {  # 0.5 x the confirm mean of an SLO run without a note (a noted run is never used for L)
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{})
if s.get("note"): sys.exit("note: " + s["note"])
x=c.get("x_mean",0)
if not x > 0: sys.exit("no confirm result")
print(round(0.5 * x, 3))' "$1"
}
precheck() {  # kernel release
  local i f kexp=$1 files="rs3/bin/recsys-server rs3/bin/recsys-node.sh rs3/cfg/cxl_region.yaml ${VM_MEG#/home/comsys/}/bin/recsys-server ${VM_MEG#/home/comsys/}/bin/recsys-node.sh ${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so ${VM_MEG#/home/comsys/}/lib/libmegalon.so ${VM_MEG#/home/comsys/}/cfg/megalon.yaml ${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml"
  local dsv=${DS_V:-} dsf=(); dsv=${dsv#/home/comsys/}   # block ds: the De Stijl install (server of DS_PLAIN_BUILD, De Stijl region)
  if [ "$B" = ds ]; then
    files="$files $dsv/bin/recsys-server $dsv/bin/recsys-node.sh $dsv/cfg/cxl_region.yaml"
    dsf=("$dsv/bin/recsys-server $DS_PLAIN_BUILD/bin/recsys-server" "$dsv/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh"
         "$dsv/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region-destijl.yaml")
  fi
  for i in 0 1; do   # kexp: `set -- $f` below replaces $1
    $SSH comsys@${IPS[$i]} "EXPECT_K=$kexp INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || { echo "SEQUENCE STOP: precheck ${IPS[$i]}"; exit 1; }
    for f in "${dsf[@]}" "rs3/bin/recsys-server $P/builds/recsys/3/bin/recsys-server" "${VM_MEG#/home/comsys/}/bin/recsys-server $MB/bin/recsys-server" \
             "${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so $MB/lib/libmegalon-objapi.so" "${VM_MEG#/home/comsys/}/lib/libmegalon.so $MB/lib/libmegalon.so" \
             "${VM_MEG#/home/comsys/}/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/recsys-pilot-2vm.yaml" \
             "rs3/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" "${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" \
             "rs3/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh" "${VM_MEG#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh"; do
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" \
        || { echo "SEQUENCE STOP: ${IPS[$i]} /home/comsys/$1 != $2"; exit 1; }
    done
  done
  (cd $P/workspaces/recsys-data/pilot && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  ' MANIFEST.txt)) > "$E/inputs-check.out" 2>&1 \
    || { echo "SEQUENCE STOP: pilot inputs differ from their manifest"; exit 1; }
}
tag() { case $1 in 60000) echo t60s;; 1000) echo t1s;; 0) echo t0;; *) echo t$1ms;; esac; }
echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD)) K8=$K8 kernel=$KB RECV_MODE=$RECV_MODE MEG_BUILD=$MB SET=\"$SET\" FUNC=$FUNC"
precheck "$KB"
if [ "$FUNC" = 1 ]; then
  run hw hw-t60s-func T_MS=60000 KIND=functional GATE=0
  run mg mg-t60s-func T_MS=60000 KIND=functional GATE=0
  run $CS $CS-t60s-func T_MS=60000 KIND=functional GATE=0
fi
for st in $(shuffle $SET); do s=${st%:*} t=${st#*:}; run $s $s-$(tag $t)-slo T_MS=$t KIND=slo; done
for st in $(shuffle $SET); do
  s=${st%:*} t=${st#*:}
  r=$(confirm_half $E/hw-$(tag $t)-slo/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for T=$t"; exit 1; }
  echo "$s T=$t L = 0.5 x hw-$(tag $t)-slo (this block, build 8) = $r query/s" >> "$E/fixed-load-L.txt"
  run $s $s-$(tag $t)-fix T_MS=$t KIND=fixed RATE=$r
done
echo "$(date -Is) SEQUENCE DONE $OWNER"

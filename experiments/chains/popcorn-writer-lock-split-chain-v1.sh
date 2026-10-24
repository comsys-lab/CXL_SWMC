#!/bin/bash
# popcorn-writer-lock-split chain v1 (exploratory experiment, reports/experiments/popcorn-writer-lock-split.md,
# approved 2026-10-23; + knee-sweep pilot in the same VM8 lifetime, main session 2026-10-23 absent-user default,
# workspaces/knee-sweep-design/DESIGN.md §3). Main session only (VM, sudo and shared-memory steps). Structure and
# helpers from workspaces/runs123/h2n-chain-v4.sh (same vmN phases, same install path, same block machinery).
# Sequence (2-VM 16-vCPU state at the start, back to it at the end):
#   pre      no MEASUREMENT.lock; live tree clean and has the fixed-window block (H2N_FIXED; branch popcorn-lock-split
#            merged); builds/vdb/21 manifest clean
#   install  2-VM state, VMs 0 1 (before the freeze; guests 2..7 are overlays of vm0): lock-split.conf VDB_VPLAIN
#            (/home/comsys/vdb21r2m <- builds/vdb/21) + the eval2 dirs the pilot uses (knee-sweep-pilot.conf VDB_VPLAIN,
#            Megalon N = 8 dir), init image on vm0; each skipped when it exists (the blocks precheck sha256s)
#   switch   vmN-chain-v2.sh VMN_TOPO=8: nochain-check dry pre gen down freeze overlays net define
#   up       start + pretouch-par 0 1, 2 3, 4 5 6 7 (as h2n-chain-v4 up2/up4/up8), envcheck, installs on 2..7 (skip existing)
#   knee     knee-sweep pilot: runset-h2n.sh 8 1, EVAL_CONF=knee-sweep-pilot.conf (hw, mg, pop fixed-rate lifetimes,
#            eval2 builds, detail 0) -> recovery/knee-sweep-pilot-v<V>; knee_pilot_export.py ->
#            workspaces/popcorn-lock-split/derived/knee-sweep-pilot-v<V>/knee-pilot.csv
#   lock     runset-h2n.sh 8 1, EVAL_CONF=lock-split.conf (one Popcorn lifetime, vdb/21 + VDB_LOCK_SPLIT=1; parts det
#            577/939/985 at detail 1, lsleep / lspin 10 ops/s at detail 0) -> recovery/popcorn-writer-lock-split-v<V>;
#            lock_split_report.py -> workspaces/popcorn-lock-split/derived/popcorn-writer-lock-split-v<V>/lock-split-*
#            (windows, vm, hist CSVs + summary)
#   hook     KNEE-SWEEP HOOK POINT: a later (separately approved) full knee sweep runs here, in the same VM8 lifetime,
#            as further runset-h2n.sh calls with its own conf; not implemented (logs one line)
#   restore  vmN-chain-v2.sh restore: dry-restore r-down r-undefine r-net r-unfreeze r-define r-start, pretouch-par 0 1,
#            envcheck, r-delete
# A failed knee or lock part is logged and the chain goes on (restore always runs unless --no-restore); switch / up /
# restore failures stop the chain (vmN phases are fail-closed; operator rollback, as h2n-chain-v4).
# usage: popcorn-writer-lock-split-chain-v1.sh [--dry-run] [--start install|switch|up|knee|lock|hook|restore]
#          [--skip-knee] [--no-restore]
#   --dry-run  print every command; runs the two runset dry starts (read only, LS_TREE may be a worktree); no VM contact
# env: LS_TREE [$P/CXL_SWMC] code tree (a real run needs the live tree), VMN_E [recovery/VM8-v4-lock-split-v1],
#   VMN_E_RESTORE [recovery/VM8-v4-lock-split-v1-restore], MEASURE_ENV_DIR [recovery/HOST-measure-env-reapply-1],
#   MEASURE_PART_DIR [recovery/HOST-measure-part-apply-2]
# Repo copy (experiments/chains/, README.md there) of workspaces/popcorn-writer-lock-split-chain-v1.sh as it ran; only
# the paths are parameterised (same defaults): DESTIJL_ROOT [/home/comsys/sungsu/destijl-control] = P;
# LOCK_SPLIT_RUN_DIR [$P/workspaces/popcorn-lock-split] state file and install logs; vmN-chain-v2.sh = vmN/ here.
set -uo pipefail
P=${DESTIJL_ROOT:-/home/comsys/sungsu/destijl-control}
CH=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
VMN=$CH/vmN/vmN-chain-v2.sh
W=${LOCK_SPLIT_RUN_DIR:-$P/workspaces/popcorn-lock-split}
DRY=0 START=install RESTORE=1 KNEE=1
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1; shift;; --start) START=${2:-}; shift 2;; --no-restore) RESTORE=0; shift;; --skip-knee) KNEE=0; shift;;
    *) echo "CHAIN STOP: unknown argument $1"; exit 2;;
  esac
done
STEPS=(install switch up knee lock hook restore)
I0=-1; for i in "${!STEPS[@]}"; do [ "${STEPS[$i]}" = "$START" ] && I0=$i; done
[ $I0 -ge 0 ] || { echo "CHAIN STOP: bad --start $START"; exit 2; }
T=${LS_TREE:-$P/CXL_SWMC}
EVD=$T/experiments/eval
KCONF=$EVD/knee-sweep-pilot.conf LCONF=$EVD/lock-split.conf
SW=${VMN_E:-$P/recovery/VM8-v4-lock-split-v1} RS=${VMN_E_RESTORE:-$P/recovery/VM8-v4-lock-split-v1-restore}
MED=${MEASURE_ENV_DIR:-$P/recovery/HOST-measure-env-reapply-1} MPD=${MEASURE_PART_DIR:-$P/recovery/HOST-measure-part-apply-2}
IDS=$P/recovery/VM8-v2.2/topo8/ids.txt
LOG=$W/chain-v1.state
log() { echo "$(date -Is) CHAIN $*"; [ $DRY = 1 ] || echo "$(date -Is) $*" >> "$LOG"; }
FAILED=()
summary() { if [ ${#FAILED[@]} = 0 ]; then log "$1: no failed part"; else log "$1: FAILED ${FAILED[*]}"; fi; }
fail() { log "STOP: $*"; summary "STOPPED"; exit 1; }
q() { local a s=""; for a in "$@"; do if [[ $a =~ [[:space:]\'\"] ]]; then s+=" '${a//\'/\'\\\'\'}'"; else s+=" $a"; fi; done; echo "${s# }"; }
xr() { local l=$1; shift
  if [ $DRY = 1 ]; then echo "  DRY [$l]: $(q "$@")"; return 0; fi
  log "RUN [$l]: $(q "$@")"; "$@"; local rc=$?
  if [ $rc = 0 ]; then log "OK [$l]"; else log "FAIL [$l] rc $rc"; fi; return $rc; }
x() { xr "$@" || fail "[$1] failed"; }
vmn() { x "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_dry() { x "vmN $*" env VMN_TOPO=8 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_soft() { xr "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmr() { x "vmN restore $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
vmr_dry() { x "vmN restore $*" env VMN_TOPO=8 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
confsh() { python3 -I -B $EVD/evalconf.py shell --conf "$1"; }
KSH=$(confsh "$KCONF") || { echo "CHAIN STOP: $KCONF does not parse"; exit 2; }
LSH=$(confsh "$LCONF") || { echo "CHAIN STOP: $LCONF does not parse"; exit 2; }
kc() { echo "$KSH" | sed -n "s/^$1=//p" | tr -d "'"; }
lc() { echo "$LSH" | sed -n "s/^$1=//p" | tr -d "'"; }
vmip() { echo 192.168.122.$((100 + $1)); }
gexists() { ssh -o BatchMode=yes -o ConnectTimeout=8 comsys@$1 "test -e $2" < /dev/null; }
# inst "<vm ids>": vdb/21 plain dir, the eval2 plain dir and the Megalon N = 8 dir on those VMs (skip existing)
inst() { local ids=$1 i ip todo rc=0 what dir build log
  for what in lock knee; do
    if [ $what = lock ]; then dir=$(lc VDB_VPLAIN) build=$(lc VDB_PLAIN_BUILD); else dir=$(kc VDB_VPLAIN) build=$(kc VDB_PLAIN_BUILD); fi
    [ $what = knee ] && [ $KNEE = 0 ] && continue
    todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$dir"; } && todo+="$ip "; done
    if [ -n "$todo" ]; then xr "install plain $dir on ${todo% }" env IPS="${todo% }" VPLAIN=$dir PLAIN_BUILD=$build REGION=$(lc REGION) \
        bash $T/experiments/vectordb/m4-install.sh $W/chain-v1-install-plain-$what.log plain || rc=1
    else log "install: $dir exists on VMs $ids (skipped; the block prechecks its sha256s)"; fi
  done
  if [ $KNEE = 1 ]; then
    dir=$(kc H2N_VMEG_N8)
    todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$dir"; } && todo+="$ip "; done
    if [ -n "$todo" ]; then xr "install megalon N=8 on ${todo% }" env IPS="${todo% }" VMEG=$dir MEG_BUILD=$(kc H2N_MG_BUILD_N8) \
        MEG_CFG=$(kc H2N_MG_CFG_N8) REGION=$(kc REGION) bash $T/experiments/vectordb/m4-install.sh $W/chain-v1-install-megalon-n8.log megalon \
        || { log "install megalon N=8 FAILED: the knee pilot runs without mg"; NOMG=1; }
    else log "install: $dir exists on VMs $ids (skipped)"; fi
  fi
  return $rc; }
NOMG=0
init_vm0() { local hi gi; hi=$(lc H2N_HOST_IMAGE) gi=$(lc H2N_INIT)
  if [ $DRY = 0 ] && gexists $(vmip 0) "$gi/SHA256SUMS"; then log "init image: $gi exists on vm0 (skipped; the block checks it)"; return 0; fi
  xr "copy init image to vm0:$gi" rsync -a --partial "$hi/" comsys@$(vmip 0):"$gi/"; }
RENV=(PRETOUCH_DIR=$SW MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD)
# part <tag> <conf> <evidence name> <report cmd...>: one run set (N = 8, k = 1) + its export; failure = logged
part() { local tag=$1 conf=$2 name=$3 rr=$4 e0 e rc only=; shift 4
  e0=$(ls -d $rr/$name-v* 2>/dev/null | sort -V | tail -1)
  [ $tag = knee ] && [ $NOMG = 1 ] && only="--only hw:u90 pop:u90"
  if [ $DRY = 1 ]; then
    echo "  DRY-CHECK [runset-h2n.sh 8 1 --dry, EVAL_CONF=$conf]:"
    env EVAL_CONF=$conf bash $EVD/runset-h2n.sh 8 1 --dry 2>&1 | grep -E 'lifetimes \(|evidence dir|fixed windows|DRY START OK|RUNSET STOP|pending' | sed 's/^/    /' | cut -c1-260
  fi
  # shellcheck disable=SC2086
  xr "$tag block" env EVAL_CONF=$conf "${RENV[@]}" bash $EVD/runset-h2n.sh 8 1 ${only:+--only "${only#--only }"}; rc=$?
  if [ $DRY = 1 ]; then xr "$tag report" "$@" "$rr/$name-v<V>"; return 0; fi
  e=$(ls -d $rr/$name-v* 2>/dev/null | sort -V | tail -1)
  [ "$e" != "$e0" ] || e=
  if [ $rc = 0 ] && grep -q "RUNSET DONE" "$e/eval-state.txt" 2>/dev/null; then log "$tag done: $e"
  else FAILED+=("$tag (rc $rc, evidence ${e:-none})"); log "$tag FAILED (rc $rc, evidence ${e:-none}); the chain goes on"; fi
  [ -n "$e" ] && [ -d "$e/block" ] && { xr "$tag report" "$@" "$e" || FAILED+=("$tag report"); }
  return 0; }
# ---- pre (every start, read only)
log "start: from $START tree $T knee=$KNEE switch dir $SW restore dir $RS dry=$DRY"
[ -f "$KCONF" ] && [ -f "$LCONF" ] && grep -q H2N_FIXED "$EVD/h2n-block.sh" || fail "$T has no knee-sweep-pilot.conf / lock-split.conf / H2N_FIXED block (merge branch popcorn-lock-split first)"
grep -q "^source_commit=.* dirty=0$" "$(lc VDB_PLAIN_BUILD)/manifest.txt" || fail "$(lc VDB_PLAIN_BUILD) is not a clean build"
if [ $DRY = 0 ]; then
  [ "$T" = "$P/CXL_SWMC" ] || fail "real runs use the live tree $P/CXL_SWMC"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ] || fail "live tree is dirty"
  [ ! -e $P/workspaces/MEASUREMENT.lock ] || fail "MEASUREMENT.lock exists ($(cat $P/workspaces/MEASUREMENT.lock))"
fi
RR=$(lc RESULTS_ROOT)
for i in $(seq $I0 $((${#STEPS[@]} - 1))); do
  s=${STEPS[$i]}
  case $s in
    install)
      log "== install on VMs 0 1 (2-VM state, before the freeze)"
      inst "0 1" || fail "plain server install on VMs 0 1 failed"
      init_vm0 || fail "init image copy to vm0 failed";;
    switch)
      log "== switch 2 -> VM8 topology (4 vCPU / 24 GB per VM)"
      vmn_dry nochain-check
      vmn_dry dry
      for ph in pre gen down freeze overlays net define; do vmn $ph; done;;
    up)
      log "== start + pretouch VMs 0 1, 2 3, 4 5 6 7"
      for g in "0 1" "2 3" "4 5 6 7"; do
        # shellcheck disable=SC2086
        vmn_soft start $g && vmn_soft pretouch-par $g || fail "VM start / pretouch of $g failed (restore by hand: --start restore)"
      done
      vmn_soft envcheck || fail "envcheck after the VM starts"
      inst "2 3 4 5 6 7" || fail "install on VMs 2..7";;
    knee)
      [ $KNEE = 1 ] || { log "== knee-sweep pilot skipped (--skip-knee)"; continue; }
      log "== knee-sweep pilot (H2 N=8 u90, hw mg pop, eval2 builds, detail 0)"
      part knee "$KCONF" "$(kc H2N_EVIDENCE_NAME)" "$RR" python3 -I -B $EVD/knee_pilot_export.py;;
    lock)
      log "== lock-split windows (Popcorn, vdb/21, VDB_LOCK_SPLIT=1)"
      part lock "$LCONF" "$(lc H2N_EVIDENCE_NAME)" "$RR" python3 -I -B $EVD/lock_split_report.py;;
    hook)
      log "== knee-sweep hook point: nothing to run (a full knee sweep needs its own approval; it would run here, VM8 still up)";;
    restore)
      [ $RESTORE = 1 ] || { log "== restore skipped (--no-restore): topology stays at 8 VMs"; continue; }
      log "== restore VM8 -> cxl_vm0 / cxl_vm1 16 vCPU / 96 GB"
      vmr_dry nochain-check
      vmr_dry dry-restore
      for ph in r-down r-undefine r-net r-unfreeze r-define r-start; do vmr $ph; done
      vmr pretouch-par 0 1
      vmr envcheck
      vmr r-delete
      log "restore done: the 2-VM pretouch evidence is $RS (new PRETOUCH_DIR)";;
  esac
done
summary "DONE"
# wall time (h2n-chain-v4 measured phases: switch ~30 min, start + pretouch ~15 min per group, restore ~15-20 min;
# lifetime overhead ~2 min, Popcorn +2 min cxl_shm cycle and preload, block prechecks ~3 min):
#   knee: hw 8 x 65 s + mg 5 x 140 s + pop 8 x 65 s = 29 min loadgen + ~10 min lifetimes/prechecks = ~40 min
#   lock: det 3 x 110 s + 2 x 110 s = 9 min loadgen + ~7 min (Popcorn cycle, prechecks) = ~16 min
[ $DRY = 1 ] && echo "ESTIMATE: install ~5 min, switch ~30, start+pretouch 3 x 15 = 45, knee pilot ~40, lock-split ~16, restore ~20: ~2.6 h (lock-split alone ~1.9 h <= 2.5 h cap; pilot ~0.7 h <= 1 h)"
[ ${#FAILED[@]} = 0 ] || exit 1
exit 0

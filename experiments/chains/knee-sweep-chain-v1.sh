#!/bin/bash
# knee-sweep chain v1 (reports/experiments/knee-sweep.md, approved 2026-10-24 "approve knee-sweep"). Main session only
# (VM, sudo and shared-memory steps). Structure and helpers from workspaces/runs123/h2n-chain-v4.sh and
# workspaces/popcorn-writer-lock-split-chain-v1.sh; blocks = experiments/eval/runset-h2n.sh with the fixed-window
# lifetimes (H2N_FIXED, h2n-block.sh), rates experiments/eval/knee-sweep-plan.csv (knee_sweep_plan.py).
# Sequence (2-VM 16-vCPU state at the start, back to it at the end):
#   pre      no MEASUREMENT.lock; live tree clean, has knee-sweep-h1.conf / knee-sweep-h2.conf and the <sys>@<mix>
#            H2N_FIXED keys (branch knee-sweep merged)
#   h1       Hypothesis 1 on the current 2 x 16 vCPU topology: installs of knee-sweep-h1.conf (vdb/17, vdb-megalon/14)
#            on VMs 0 1 if missing, then runset-h2n.sh 2 1, EVAL_CONF=knee-sweep-h1.conf (9 lifetimes) ->
#            recovery/knee-sweep-h1-v<V>; PRETOUCH_DIR = KS_H1_PRETOUCH_DIR (the current 2-VM QEMU lifetime's pretouch
#            evidence, e.g. the last VM8 restore dir; required for a real run)
#   install  2-VM state, VMs 0 1, before the freeze: knee-sweep-h2.conf dirs (vdb18r2m, vdbm16r2m-n2/n4/n8) and the SQ8
#            init image on vm0, each skipped when present
#   switch   vmN-chain-v2.sh VMN_TOPO=8: nochain-check dry pre gen down freeze overlays net define
#   up2 n2 up4 n4 up8 n8   start + pretouch-par of the new VMs (0 1 / 2 3 / 4 5 6 7), envcheck, installs on new VMs
#            (skip existing); block N = runset-h2n.sh N 1, EVAL_CONF=knee-sweep-h2.conf -> recovery/knee-sweep-h2-n<N>-v<V>
#   restore  vmN-chain-v2.sh restore (dry-restore r-down r-undefine r-net r-unfreeze r-define r-start, pretouch-par 0 1,
#            envcheck, r-delete)
#   export   knee_pilot_export.py over every evidence dir of each group -> workspaces/knee-sweep/derived/<group>/knee-pilot.csv
# Failed cells: a block stops at its first failed lifetime; the chain logs that cell (FAILED) and re-runs the same N with
# --only the lifetimes after it (new evidence dir v<V+1>), until every lifetime has a result row or failed once. A failed
# VM start skips the blocks of that N and larger N; restore and export always run (unless --no-restore). Switch and
# restore failures stop the chain (vmN phases are fail-closed; operator rollback).
# Last line (monitors grep it): "CHAIN DONE: every cell measured" | "CHAIN FAIL (completed; failed cells: ...)" |
# "CHAIN FAIL (stopped: ...)".
# usage: knee-sweep-chain-v1.sh [--dry-run] [--start h1|install|switch|up2|n2|up4|n4|up8|n8|restore|export] [--no-restore]
#   --dry-run  print every command, run the four runset dry starts (read only; LS_TREE may be a worktree); no VM contact
# env: LS_TREE [$P/CXL_SWMC], KS_H1_PRETOUCH_DIR (h1), VMN_E [recovery/VM8-v4-knee-sweep-v1], VMN_E_RESTORE
#   [recovery/VM8-v4-knee-sweep-v1-restore], MEASURE_ENV_DIR [recovery/HOST-measure-env-reapply-1], MEASURE_PART_DIR
#   [recovery/HOST-measure-part-apply-2]
# Repo copy (experiments/chains/, README.md there) of workspaces/knee-sweep-chain-v1.sh as it ran; only the paths are
# parameterised (same defaults): DESTIJL_ROOT [/home/comsys/sungsu/destijl-control] = P; KNEE_SWEEP_RUN_DIR
# [$P/workspaces/knee-sweep] state file, install logs, derived/<group>/ exports; vmN-chain-v2.sh = the copy in vmN/ here.
set -uo pipefail
P=${DESTIJL_ROOT:-/home/comsys/sungsu/destijl-control}
CH=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
VMN=$CH/vmN/vmN-chain-v2.sh
W=${KNEE_SWEEP_RUN_DIR:-$P/workspaces/knee-sweep}
DRY=0 START=h1 RESTORE=1
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1; shift;; --start) START=${2:-}; shift 2;; --no-restore) RESTORE=0; shift;;
    *) echo "CHAIN FAIL (stopped: unknown argument $1)"; exit 2;;
  esac
done
STEPS=(h1 install switch up2 n2 up4 n4 up8 n8 restore export)
I0=-1; for i in "${!STEPS[@]}"; do [ "${STEPS[$i]}" = "$START" ] && I0=$i; done
[ $I0 -ge 0 ] || { echo "CHAIN FAIL (stopped: bad --start $START)"; exit 2; }
T=${LS_TREE:-$P/CXL_SWMC}
EVD=$T/experiments/eval
C1=$EVD/knee-sweep-h1.conf C2=$EVD/knee-sweep-h2.conf
SW=${VMN_E:-$P/recovery/VM8-v4-knee-sweep-v1} RS=${VMN_E_RESTORE:-$P/recovery/VM8-v4-knee-sweep-v1-restore}
MED=${MEASURE_ENV_DIR:-$P/recovery/HOST-measure-env-reapply-1} MPD=${MEASURE_PART_DIR:-$P/recovery/HOST-measure-part-apply-2}
H1PT=${KS_H1_PRETOUCH_DIR:-}
IDS=$P/recovery/VM8-v2.2/topo8/ids.txt
mkdir -p "$W"
LOG=$W/chain-v1.state
log() { echo "$(date -Is) CHAIN $*"; [ $DRY = 1 ] || echo "$(date -Is) $*" >> "$LOG"; }
FAILED=()
fail() { log "FAIL (stopped: $*)${FAILED[*]:+; failed cells: ${FAILED[*]}}"; exit 1; }
q() { local a s=""; for a in "$@"; do if [[ $a =~ [[:space:]\'\"] ]]; then s+=" '${a//\'/\'\\\'\'}'"; else s+=" $a"; fi; done; echo "${s# }"; }
xr() { local l=$1; shift
  if [ $DRY = 1 ]; then echo "  DRY [$l]: $(q "$@")"; return 0; fi
  log "RUN [$l]: $(q "$@")"; "$@"; local rc=$?
  if [ $rc = 0 ]; then log "OK [$l]"; else log "NOTOK [$l] rc $rc"; fi; return $rc; }
x() { xr "$@" || fail "[$1] failed"; }
vmn() { x "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_dry() { x "vmN $*" env VMN_TOPO=8 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_soft() { xr "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmr() { x "vmN restore $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
vmr_dry() { x "vmN restore $*" env VMN_TOPO=8 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
S1=$(python3 -I -B $EVD/evalconf.py shell --conf "$C1") || { echo "CHAIN FAIL (stopped: $C1 does not parse)"; exit 2; }
S2=$(python3 -I -B $EVD/evalconf.py shell --conf "$C2") || { echo "CHAIN FAIL (stopped: $C2 does not parse)"; exit 2; }
c1() { echo "$S1" | sed -n "s/^$1=//p" | tr -d "'"; }
c2() { echo "$S2" | sed -n "s/^$1=//p" | tr -d "'"; }
RR=$(c2 RESULTS_ROOT)
vmip() { echo 192.168.122.$((100 + $1)); }
gexists() { ssh -o BatchMode=yes -o ConnectTimeout=8 comsys@$1 "test -e $2" < /dev/null; }
# inst <conf accessor c1|c2> "<vm ids>" "<N list for Megalon dirs>": plain dir + Megalon dirs, skip existing
inst() { local c=$1 ids=$2 ns=$3 i ip todo rc=0 n d
  d=$($c VDB_VPLAIN)
  todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$d"; } && todo+="$ip "; done
  if [ -n "$todo" ]; then xr "install plain $d on ${todo% }" env IPS="${todo% }" VPLAIN=$d PLAIN_BUILD=$($c VDB_PLAIN_BUILD) \
      REGION=$($c REGION) bash $T/experiments/vectordb/m4-install.sh $W/chain-v1-install-plain.log plain || rc=1
  else log "install: $d exists on VMs $ids (skipped; the block prechecks its sha256s)"; fi
  for n in $ns; do
    d=$($c H2N_VMEG_N$n)
    todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$d"; } && todo+="$ip "; done
    [ -n "$todo" ] || { log "install: $d exists on VMs $ids (skipped)"; continue; }
    xr "install megalon N=$n $d on ${todo% }" env IPS="${todo% }" VMEG=$d MEG_BUILD=$($c H2N_MG_BUILD_N$n) MEG_CFG=$($c H2N_MG_CFG_N$n) \
      REGION=$($c REGION) bash $T/experiments/vectordb/m4-install.sh $W/chain-v1-install-megalon-n$n.log megalon || rc=1
  done; return $rc; }
init_vm0() { local hi gi; hi=$(c2 H2N_HOST_IMAGE) gi=$(c2 H2N_INIT)
  if [ $DRY = 0 ] && gexists $(vmip 0) "$gi/SHA256SUMS"; then log "init image: $gi exists on vm0 (skipped; the block checks it)"; return 0; fi
  xr "copy init image to vm0:$gi" rsync -a --partial "$hi/" comsys@$(vmip 0):"$gi/"; }
# group <tag> <conf> <conf accessor> <N> <pretouch dir>: every lifetime of the conf, resumed after a failed one
group() { local tag=$1 conf=$2 c=$3 n=$4 pt=$5 all=() todo=() s m e0 e rc done_lt l first rest name
  for s in $($c H2N_SYSTEMS); do for m in $($c H2N_POINTS); do all+=("$s:$m"); done; done
  todo=("${all[@]}")
  name=$($c H2N_EVIDENCE_NAME); name=${name//\{N\}/$n}
  if [ $DRY = 1 ]; then
    echo "  DRY-CHECK [runset-h2n.sh $n 1 --dry, EVAL_CONF=$conf]:"
    env EVAL_CONF=$conf bash $EVD/runset-h2n.sh $n 1 --dry 2>&1 | grep -E 'lifetimes \(|evidence dir|DRY START OK|RUNSET STOP|pending' | sed 's/^/    /' | cut -c1-200
    xr "$tag block" env EVAL_CONF=$conf PRETOUCH_DIR=$pt MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD bash $EVD/runset-h2n.sh $n 1 --only "${todo[*]}"
    echo "  DRY [$tag resume rule]: after a failed lifetime: the same command with --only <the lifetimes after it>"
    return 0
  fi
  while [ ${#todo[@]} -gt 0 ]; do
    e0=$(ls -d $RR/$name-v* 2>/dev/null | sort -V | tail -1)
    xr "$tag block [${todo[*]}]" env EVAL_CONF=$conf PRETOUCH_DIR=$pt MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD \
      bash $EVD/runset-h2n.sh $n 1 --only "${todo[*]}"; rc=$?
    e=$(ls -d $RR/$name-v* 2>/dev/null | sort -V | tail -1); [ "$e" != "$e0" ] || e=
    if [ $rc = 0 ] && grep -q "RUNSET DONE" "$e/eval-state.txt" 2>/dev/null; then log "$tag done: $e"; return 0; fi
    done_lt=" "
    [ -n "$e" ] && [ -f "$e/block/h2n-results.tsv" ] && done_lt=" $(grep -v '^#' "$e/block/h2n-results.tsv" | awk -F'\t' '{print $2":"$3}' | tr '\n' ' ')"
    first= rest=()
    for l in "${todo[@]}"; do
      if [ -z "$first" ]; then [[ $done_lt == *" $l "* ]] || first=$l
      else rest+=("$l"); fi
    done
    if [ -z "$e" ]; then  # the run set stopped before its evidence dir: nothing ran, do not loop
      FAILED+=("$tag:all-remaining(${todo[*]// /,}; rc $rc, no evidence dir)"); log "$tag FAILED before any lifetime (rc $rc)"; return 0
    fi
    if ! grep -q "== FIXED " "$e/block/block.log" 2>/dev/null; then  # review M2: stopped in its prechecks / gate
      FAILED+=("$tag:all-remaining(${todo[*]// /,}; rc $rc, stopped before the first lifetime, $e)")
      log "$tag FAILED before its first lifetime (rc $rc, $e: prechecks / gate; see block.log)"; return 0
    fi
    if [ -z "$first" ]; then FAILED+=("$tag:after-last-lifetime($e)"); log "$tag FAILED after its last lifetime (rc $rc, $e)"; return 0; fi
    FAILED+=("$tag:$first($e)")
    log "$tag cell $first FAILED (rc $rc, evidence $e); continuing with [${rest[*]}]"
    todo=("${rest[@]}")
  done
  return 0; }
# ---- pre (read only)
log "start: from $START tree $T switch dir $SW restore dir $RS h1 pretouch ${H1PT:-unset} dry=$DRY"
[ -f "$C1" ] && [ -f "$C2" ] && grep -q 'fkey()' "$EVD/h2n-block.sh" || fail "$T has no knee-sweep confs / <sys>@<mix> H2N_FIXED (merge branch knee-sweep first)"
if [ $DRY = 0 ]; then
  [ "$T" = "$P/CXL_SWMC" ] || fail "real runs use the live tree $P/CXL_SWMC"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ] || fail "live tree is dirty"
  [ ! -e $P/workspaces/MEASUREMENT.lock ] || fail "MEASUREMENT.lock exists ($(cat $P/workspaces/MEASUREMENT.lock))"
  [ $I0 -gt 0 ] || [ -d "$H1PT" ] || fail "KS_H1_PRETOUCH_DIR must name the current 2-VM pretouch evidence dir (h1 step)"
fi
declare -A NEWVMS=([2]="0 1" [4]="2 3" [8]="4 5 6 7")
DOWN=0
for i in $(seq $I0 $((${#STEPS[@]} - 1))); do
  s=${STEPS[$i]}
  case $s in
    h1)
      log "== Hypothesis 1 (2 x 16 vCPU, fp32): installs if missing, 9 lifetimes"
      if inst c1 "0 1" "2"; then group h1 "$C1" c1 2 "${H1PT:-<KS_H1_PRETOUCH_DIR>}"
      else FAILED+=("h1:all(install failed)"); log "h1 install FAILED: Hypothesis 1 not run"; fi;;
    install)
      log "== install Hypothesis 2 dirs on VMs 0 1 (2-VM state, before the freeze)"
      inst c2 "0 1" "2 4 8" || fail "Hypothesis 2 install on VMs 0 1 failed"
      init_vm0 || fail "init image copy to vm0 failed";;
    switch)
      log "== switch 2 -> VM8 topology (4 vCPU / 24 GB per VM)"
      vmn_dry nochain-check
      vmn_dry dry
      for ph in pre gen down freeze overlays net define; do vmn $ph; done;;
    up2|up4|up8)
      n=${s#up}
      [ $DOWN = 0 ] || { log "== start VMs ${NEWVMS[$n]} skipped (an earlier VM start failed)"; continue; }
      log "== start + pretouch VMs ${NEWVMS[$n]} (N=$n)"
      # shellcheck disable=SC2086
      if ! { vmn_soft start ${NEWVMS[$n]} && vmn_soft pretouch-par ${NEWVMS[$n]} && vmn_soft envcheck \
             && { [ $n = 2 ] || inst c2 "${NEWVMS[$n]}" "2 4 8"; }; }; then
        DOWN=1; log "VM start for N=$n FAILED: blocks N >= $n skipped, restore next"
      fi;;
    n2|n4|n8)
      n=${s#n}
      if [ $DOWN = 1 ]; then FAILED+=("h2-n$n:all(VM start failed)"); log "== block N=$n skipped (VMs not started)"; continue; fi
      log "== Hypothesis 2 N=$n (SQ8, 9 lifetimes)"
      group h2-n$n "$C2" c2 $n "$SW";;
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
    export)
      log "== export (knee_pilot_export.py per group, every evidence dir)"
      for g in knee-sweep-h1 knee-sweep-h2-n2 knee-sweep-h2-n4 knee-sweep-h2-n8; do
        if [ $DRY = 1 ]; then xr "export $g" python3 -I -B $EVD/knee_pilot_export.py "$RR/$g-v*" --out $W/derived/$g; continue; fi
        ds=$(ls -d $RR/$g-v* 2>/dev/null | sort -V)
        [ -n "$ds" ] || { log "export $g: no evidence"; continue; }
        # shellcheck disable=SC2086
        xr "export $g" python3 -I -B $EVD/knee_pilot_export.py $ds --out $W/derived/$g > /dev/null || FAILED+=("export:$g")
      done;;
  esac
done
# wall time estimate: lifetimes from knee-sweep-plan.csv (loadgen time + measured overhead per lifetime) H1 119 min,
# H2 N=2 / 4 / 8 114 / 116 / 114 min (plan of 2026-10-24 decisions: Popcorn +1.10/1.15, H2 N=2 u50 Megalon knee set);
# + install ~5, switch ~30, start + pretouch 3 x 15, restore ~20 min
[ $DRY = 1 ] && echo "ESTIMATE: H1 ~2.1 h, install ~0.1 h, switch ~0.5 h, N=2/4/8 (3 x 0.25 start) + 5.7 h, restore ~0.3 h: ~9.5 h"
[ $DRY = 1 ] && { log "DRY-RUN END (nothing ran)"; exit 0; }   # never prints the monitor strings
if [ ${#FAILED[@]} = 0 ]; then log "DONE: every cell measured"; exit 0; fi
log "FAIL (completed; failed cells: ${FAILED[*]})"; exit 1

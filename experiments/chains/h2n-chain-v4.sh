#!/bin/bash
# h2n chain v4 (workspaces/runs123; eval2 runs 1-3 = measurement rule 2026-10-21 22:4x) = v3 with:
#   EVAL_CONF default experiments/eval/eval2-h2.conf; evidence glob <prefix>-run<k>-<EVIDENCE_TAG>-n<N>-v (conf
#   EVIDENCE_TAG, e.g. h2 -> recovery/eval2-run<k>-h2-n<N>-v<V>); switch / restore dirs recovery/VM8-v4-eval2-run<k>
#   (-restore); state, install logs and resume lines under workspaces/runs123 (h2n-chain-v4-*). Called by
#   workspaces/runs123/run-chain-v1.sh (part h2); can run alone with the same arguments as v3.
# h2n chain v3 = v2 + guest installs for builds made after the topology freeze (SQ8, user 2026-10-21):
#   install  on the running guests 0 1 (2-VM or VM8 state): plain server dir (VDB_VPLAIN <- VDB_PLAIN_BUILD), Megalon
#            dirs of N = 2, 4, 8, and the H2N_INIT copy of H2N_HOST_IMAGE on vm0; each skipped when it exists
#   upN      after the new VMs of N start: plain dir + Megalon dirs of every N' >= N on those VMs (guests 2..7 are
#            overlays of the frozen vm0 disk and lack anything installed after the freeze)
#   --start vm8  VM8 topology already running with VMs 0 1 pretouched in VMN_E: install, then N=2 (no switch, no up2)
# h2n chain v2: one run k of new H2 (vector DB VM-count scaling; reports/experiments/vdb-vm-scaling.md + RUN-H2N.md;
# user decisions 2026-10-20 22:3x). Main session only (VM, sudo and shared-memory steps), launched as
#   setsid nohup bash workspaces/h2n/h2n-chain-v2.sh --run <k> > workspaces/h2n/h2n-chain-v2-run<k>.log 2>&1 &
# v2 = v1 + verifier review v1 (workspaces/h2n/review-v1/REVIEW.md) corrections:
#   M1  install step covers N = 2, 4, 8 (every N runs the same vdb server source: vdb-megalon/15-n<N>)
#   M2  evidence dirs <RESULTS_ROOT>/<EVIDENCE_PREFIX>-run<k>-n<N>-v<V> (approved scope); globs read from the conf
#       (v4 / eval2: with EVIDENCE_TAG h2 the dirs are <RESULTS_ROOT>/<EVIDENCE_PREFIX>-run<k>-h2-n<N>-v<V>)
#   M3  a failed N block (or a failed VM start of an N) is logged with its failed lifetime and the resume command, the
#       chain continues with the next N (skipping the N whose VMs did not start), restore always runs (unless
#       --no-restore), export runs on what exists, and the last line names every failed N / system / mix.
#       Install failure of an N: that N's blocks run without the Megalon lifetimes (logged as failed mg lifetimes).
#       Switch or restore failure still stops the chain (vmN phases are fail-closed; operator rollback).
# Sequence (2-VM 16-vCPU state at the start, back to it at the end):
#   pre      checks: no MEASUREMENT.lock, live tree has runset-h2n.sh and is clean, Megalon inputs of every N filled
#   install  2-VM state: Megalon guest dirs of N = 2, 4, 8 on vm0 with m4-install.sh, BEFORE the freeze (guests 2..7
#            are overlays of vm0's frozen disk; vm1 keeps its own disk, so N = 2 installs on vm1 too: m4-install.sh
#            installs on both 2-VM guests); skipped per dir when it already exists on vm0 and vm1 (the block prechecks
#            sha256s)
#   switch   vmN-chain-v2.sh VMN_TOPO=8 (the VM8 XMLs: 4 vCPU / 24 GB per VM, identities of recovery/VM8-v2.2):
#            nochain-check dry pre gen down freeze overlays net define
#   N=2      start 0 1, pretouch-par 0 1, envcheck, runset-h2n.sh 2 k (hw u5 u50 u90, mg ..., pop ...)
#   N=4      start 2 3, pretouch-par 2 3, envcheck, runset-h2n.sh 4 k
#   N=8      start 4 5 6 7, pretouch-par 4 5 6 7, envcheck, runset-h2n.sh 8 k
#   restore  vmN-chain-v2.sh VMN_TOPO=8 restore: dry-restore r-down r-undefine r-net r-unfreeze r-define r-start,
#            pretouch-par 0 1, envcheck, r-delete (cxl_vm0 / cxl_vm1 back to 16 vCPU / 96 GB)
#   export   export_h2n.py per N over every evidence dir of run k (later attempt wins per lifetime), then --combine
# Within an N the order is hw, mg, pop (h2n.conf H2N_SYSTEMS): the two systems without cxl_shm first, so dax0.0 changes
# owner once per N and Popcorn's module cycles come last; mixes u5, u50, u90 inside each system.
# usage: h2n-chain-v2.sh --run K [--dry-run] [--start POINT] [--only-n "N .."] [--from N:<sys>:<mix>].. [--no-restore]
#   --dry-run  print every command (with its environment) and the wall-time estimate; runs nothing that touches a VM,
#              the Host state or the evidence (H2N_DRY_CHECK=1 additionally runs runset-h2n.sh <N> <k> --dry, read only)
#   --start    resume point: switch (default: from install) | N:up (topology switched, start the VMs new at N first)
#              | N (VMs 0..N-1 running and pretouched in VMN_E: the N block) | N:<sys>:<mix> (= --start N --from
#              N:<sys>:<mix>) | restore | export
#   --only-n   run the blocks of these N only (the VM start steps still run up to the largest listed N); the resume
#              form after a restored chain, e.g. --only-n "4" --from 4:mg:u50
#   --from     N:<sys>:<mix>: block N starts at that lifetime (a new evidence dir v<V+1>); repeatable, one per N
#   --no-restore  stop after the last block (topology stays at 8 VMs)
# env (defaults in brackets): H2N_TREE [$P/CXL_SWMC] code tree of the drivers (a real run needs the live tree),
#   EVAL_CONF [$H2N_TREE/experiments/eval/h2n.conf], VMN_E [recovery/VM8-v4-h2n-run<k>] switch evidence dir (= the
#   PRETOUCH_DIR of every block), VMN_E_RESTORE [recovery/VM8-v4-h2n-run<k>-restore], MEASURE_ENV_DIR
#   [recovery/HOST-measure-env-reapply-1], MEASURE_PART_DIR [recovery/HOST-measure-part-apply-2]
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
VMN=$P/workspaces/vmN/vmN-chain-v2.sh
K= DRY=0 START=install RESTORE=1 ONLYN= SKIPSW=0 LTONLY=
declare -A FROM=()
while [ $# -gt 0 ]; do
  case $1 in
    --run) K=${2:-}; shift 2;; --dry-run) DRY=1; shift;; --start) START=${2:-}; shift 2;; --no-restore) RESTORE=0; shift;;
    --only-n) ONLYN=${2:-}; shift 2;;
    --lifetimes) LTONLY=${2:-}; shift 2;;   # v3: e.g. "hw:u5" (pilot) instead of every H2N_SYSTEMS x H2N_POINTS
    --from) [[ ${2:-} =~ ^[248]:[a-z]+:u[0-9]+$ ]] || { echo "CHAIN STOP: bad --from ${2:-} (N:<sys>:<mix>)"; exit 2; }
            FROM[${2%%:*}]=${2#*:}; shift 2;;
    *) echo "CHAIN STOP: unknown argument $1"; exit 2;;
  esac
done
[[ $K =~ ^[1-3]$ ]] || { echo "CHAIN STOP: --run 1..3 required"; exit 2; }
T=${H2N_TREE:-$P/CXL_SWMC}
EVD=$T/experiments/eval
CONF=${EVAL_CONF:-$EVD/eval2-h2.conf}
SW=${VMN_E:-$P/recovery/VM8-v4-eval2-run$K} RS=${VMN_E_RESTORE:-$P/recovery/VM8-v4-eval2-run$K-restore}
R123=$P/workspaces/runs123
MED=${MEASURE_ENV_DIR:-$P/recovery/HOST-measure-env-reapply-1} MPD=${MEASURE_PART_DIR:-$P/recovery/HOST-measure-part-apply-2}
IDS=$P/recovery/VM8-v2.2/topo8/ids.txt
NS="2 4 8"
declare -A NEWVMS=([2]="0 1" [4]="2 3" [8]="4 5 6 7")
for n in $ONLYN; do [[ " $NS " == *" $n "* ]] || { echo "CHAIN STOP: --only-n $n not in $NS"; exit 2; }; done
ONLYN=${ONLYN:-$NS}
MAXN=0; for n in $ONLYN; do [ "$n" -gt $MAXN ] && MAXN=$n; done
for n in "${!FROM[@]}"; do [[ " $ONLYN " == *" $n "* ]] || { echo "CHAIN STOP: --from $n:${FROM[$n]} but N=$n is not run"; exit 2; }; done
# ---- resume point -> first step index
STEPS=(install switch up2 n2 up4 n4 up8 n8 restore export)
case $START in
  install|switch|restore|export) S0=$START;;
  vm8) S0=install SKIPSW=1;;
  [248]) S0=n$START;;
  [248]:up) S0=up${START%:up};;
  [248]:*:*) S0=n${START%%:*} FROM[${START%%:*}]=${START#*:};;
  *) echo "CHAIN STOP: bad --start $START"; exit 2;;
esac
I0=-1; for i in "${!STEPS[@]}"; do [ "${STEPS[$i]}" = "$S0" ] && I0=$i; done
[ $I0 -ge 0 ] || { echo "CHAIN STOP: bad --start $START"; exit 2; }
LOG=$R123/h2n-chain-v4-run$K.state
log() { echo "$(date -Is) CHAIN $*"; [ $DRY = 1 ] || echo "$(date -Is) $*" >> "$LOG"; }
FAILED=()   # "N=<n>:<sys>:<mix> (<reason>)" entries for the last line
summary() {  # last line of every exit path
  if [ ${#FAILED[@]} = 0 ]; then log "$1 run $K: no failed N / system / mix"
  else log "$1 run $K: FAILED ${FAILED[*]}"; fi
}
fail() { log "STOP: $*"; summary "STOPPED"; exit 1; }
q() { local a s=""; for a in "$@"; do if [[ $a =~ [[:space:]\'\"] ]]; then s+=" '${a//\'/\'\\\'\'}'"; else s+=" $a"; fi; done; echo "${s# }"; }
xr() {  # <label> <cmd...>: dry: print, rc 0; real: run, log, return rc
  local l=$1; shift
  if [ $DRY = 1 ]; then echo "  DRY [$l]: $(q "$@")"; return 0; fi
  log "RUN [$l]: $(q "$@")"
  "$@"; local rc=$?
  if [ $rc = 0 ]; then log "OK [$l]"; else log "FAIL [$l] rc $rc"; fi
  return $rc
}
x() { xr "$@" || fail "[$1] failed"; }   # STOP on rc != 0 (switch, restore)
vmn() { x "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_dry() { x "vmN $*" env VMN_TOPO=8 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmn_soft() { xr "vmN $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_E=$SW VMN_IDS_FROM=$IDS bash $VMN "$@"; }
vmr() { x "vmN restore $*" env VMN_TOPO=8 VMN_LIVE=1 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
vmr_dry() { x "vmN restore $*" env VMN_TOPO=8 VMN_SRC=$SW VMN_E=$RS bash $VMN "$@"; }
CONFSH=$(python3 -I -B $EVD/evalconf.py shell --conf "$CONF") || { echo "CHAIN STOP: $CONF does not parse"; exit 2; }
conf() { echo "$CONFSH" | sed -n "s/^$1=//p" | tr -d "'"; }
RR=$(conf RESULTS_ROOT) EP=$(conf EVIDENCE_PREFIX)
[ -n "$RR" ] && [ -n "$EP" ] || { echo "CHAIN STOP: RESULTS_ROOT / EVIDENCE_PREFIX missing in $CONF"; exit 2; }
ETAG=$(conf EVIDENCE_TAG)
evglob() { echo "$RR/$EP-run$K-${ETAG:+$ETAG-}n$1-v"; }   # + '*' : runset-h2n.sh evidence dirs of N (lib.sh evidence_dir, EVIDENCE_TAG)
ALLLT=(); for s in $(conf H2N_SYSTEMS); do for m in $(conf H2N_POINTS); do ALLLT+=("$s:$m"); done; done
if [ -n "$LTONLY" ]; then
  for l in $LTONLY; do [[ " ${ALLLT[*]} " == *" $l "* ]] || { echo "CHAIN STOP: --lifetimes $l not in the conf's systems x points"; exit 2; }; done
  read -ra ALLLT <<< "$LTONLY"
fi
# ---- v3 guest installs: inst "<vm ids>" <min N>: plain dir + Megalon dirs of N >= min N on those VMs (skip existing)
vmip() { echo 192.168.122.$((100 + $1)); }
gexists() { ssh -o BatchMode=yes -o ConnectTimeout=8 comsys@$1 "test -e $2" < /dev/null; }
inst() { local ids=$1 minn=$2 i ip todo n b v c rc=0 REG; REG=$(conf REGION)
  todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$(conf VDB_VPLAIN)"; } && todo+="$ip "; done
  if [ -n "$todo" ]; then xr "install plain on ${todo% }" env IPS="${todo% }" VPLAIN=$(conf VDB_VPLAIN) PLAIN_BUILD=$(conf VDB_PLAIN_BUILD) \
      REGION=$REG bash $T/experiments/vectordb/m4-install.sh $R123/h2n-chain-v4-install-plain-run$K.log plain || rc=1
  else log "install plain: $(conf VDB_VPLAIN) exists on VMs $ids (skipped; the block prechecks its sha256s)"; fi
  for n in $NS; do
    [ "$n" -ge "$minn" ] && [[ " $ONLYN " == *" $n "* ]] || continue
    b=$(conf H2N_MG_BUILD_N$n) v=$(conf H2N_VMEG_N$n) c=$(conf H2N_MG_CFG_N$n)
    todo=; for i in $ids; do ip=$(vmip $i); { [ $DRY = 1 ] || ! gexists $ip "$v"; } && todo+="$ip "; done
    [ -n "$todo" ] || { log "install N=$n: $v exists on VMs $ids (skipped)"; continue; }
    xr "install megalon N=$n on ${todo% }" env IPS="${todo% }" VMEG=$v MEG_BUILD=$b MEG_CFG=$c REGION=$REG \
      bash $T/experiments/vectordb/m4-install.sh $R123/h2n-chain-v4-install-megalon-n$n-run$K.log megalon \
      || { NOMG[$n]=1; log "install N=$n FAILED: N=$n blocks run without the Megalon lifetimes"; }
  done; return $rc; }
init_vm0() { local hi=$(conf H2N_HOST_IMAGE) gi=$(conf H2N_INIT)
  [ -n "$hi" ] && [ -n "$gi" ] || return 0
  if [ $DRY = 0 ] && gexists $(vmip 0) "$gi/SHA256SUMS"; then log "init image: $gi exists on vm0 (skipped; the block checks it)"; return 0; fi
  xr "copy init image to vm0:$gi" rsync -a --partial "$hi/" comsys@$(vmip 0):"$gi/"; }
# ---- pre (every start, read only)
log "start: run $K from $START (step ${STEPS[$I0]}) only-n [$ONLYN] from [$(for n in "${!FROM[@]}"; do printf '%s:%s ' "$n" "${FROM[$n]}"; done)] tree $T conf $CONF evidence $(evglob N)* switch dir $SW restore dir $RS dry=$DRY"
[ -f "$EVD/runset-h2n.sh" ] && [ -f "$CONF" ] || fail "$T has no experiments/eval/runset-h2n.sh / h2n.conf (merge branch h2n first)"
if [ $DRY = 0 ]; then
  [ "$T" = "$P/CXL_SWMC" ] || fail "real runs use the live tree $P/CXL_SWMC"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ] || fail "live tree is dirty"
  [ ! -e $P/workspaces/MEASUREMENT.lock ] || fail "MEASUREMENT.lock exists ($(cat $P/workspaces/MEASUREMENT.lock))"
fi
PEND=$(echo "$CONFSH" | grep -E '^H2N_(MG_|VMEG_).*PLACEHOLDER' | cut -d= -f1 | tr '\n' ' ')
if [ -n "$PEND" ]; then
  [ $DRY = 1 ] || fail "Megalon placeholders in $CONF: $PEND(fill them from workspaces/megalon-n, commit, merge)"
  log "NOTE: Megalon placeholders in $CONF: $PEND(a real run stops here)"
fi
RENV=(EVAL_CONF=$CONF PRETOUCH_DIR=$SW MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD)
declare -A NOMG=() DOWN=()   # N whose Megalon install failed; N whose VMs did not start (skip its block and larger N)
lt_list() {  # <N>: the lifetime list of this attempt (from FROM[N]; without mg when its install failed)
  local n=$1 l out=() on=0
  [ -z "${FROM[$n]:-}" ] && on=1
  for l in "${ALLLT[@]}"; do
    [ "$l" = "${FROM[$n]:-}" ] && on=1
    [ $on = 1 ] || continue
    [ -n "${NOMG[$n]:-}" ] && [[ $l == mg:* || $l == mgoff:* ]] && continue
    out+=("$l")
  done
  echo "${out[*]}"
}
resume_line() {  # <N> <first failed lifetime>
  log "RESUME N=$1 from $2: after this chain's restore: bash $R123/run-chain-v1.sh --run $K --start h2 --h2-args '--only-n $1 --from $1:$2' (install skips present guest dirs; a new evidence dir v<V+1>; the resume needs new VMN_E / VMN_E_RESTORE dirs, e.g. VMN_E=$SW-r2 VMN_E_RESTORE=$SW-r2-restore)"
}
block() {  # <N>
  local n=$1 lts e done_lt l first= rc
  lts=$(lt_list $n)
  if [ -n "${NOMG[$n]:-}" ]; then
    for l in "${ALLLT[@]}"; do [[ $l == mg:* ]] && FAILED+=("N=$n:$l (megalon install failed; not run)"); done
  fi
  [ -n "$lts" ] || { log "N=$n: no lifetimes left to run"; return 0; }
  if [ $DRY = 1 ] && [ "${H2N_DRY_CHECK:-0}" = 1 ]; then
    echo "  DRY-CHECK [runset-h2n.sh $n $K --dry --only '$lts']:"
    env EVAL_CONF=$CONF bash $EVD/runset-h2n.sh $n $K --dry --only "$lts" 2>&1 | grep -E 'lifetimes \(|evidence dir|DRY START OK|RUNSET STOP|pending' | sed 's/^/    /'
  fi
  local e0; e0=$(ls -d "$(evglob $n)"* 2>/dev/null | sort -V | tail -1)
  xr "block N=$n" env "${RENV[@]}" bash $EVD/runset-h2n.sh $n $K --only "$lts"; rc=$?
  [ $DRY = 1 ] && return 0
  e=$(ls -d "$(evglob $n)"* 2>/dev/null | sort -V | tail -1)
  [ "$e" != "$e0" ] || e=   # no new evidence dir: the run set stopped before creating one
  if [ $rc = 0 ] && grep -q "RUNSET DONE" "$e/eval-state.txt" 2>/dev/null; then
    log "N=$n done: $e ($(grep -vc '^#' "$e/block/h2n-results.tsv") lifetimes; $(grep -c 'NOTE' "$e/block/block.log") NOTE lines)"
    return 0
  fi
  # failed: the first lifetime of this attempt without a result row (none = a check after the last lifetime)
  done_lt=" "
  [ -f "$e/block/h2n-results.tsv" ] && [[ $(grep -m1 '^lifetimes=' "$e/eval-manifest.txt" 2>/dev/null) == "lifetimes=$lts "* ]] \
    && done_lt=" $(grep -v '^#' "$e/block/h2n-results.tsv" | awk -F'\t' '{print $2":"$3}' | tr '\n' ' ')"
  for l in $lts; do [[ $done_lt == *" $l "* ]] || { first=$l; break; }; done
  if [ -z "$first" ]; then
    FAILED+=("N=$n:after-last-lifetime (rc $rc; results complete, see $e/eval-state.txt)")
    log "N=$n FAILED after its last lifetime (rc $rc, evidence ${e:-none}): results kept; check $e/eval-state.txt"
  else
    FAILED+=("N=$n:$first (rc $rc, evidence ${e:-none})")
    log "N=$n FAILED at $first (rc $rc, evidence ${e:-none}; lifetimes not run: from $first on)"
    resume_line $n "$first"
  fi
  return 0
}
for i in $(seq $I0 $((${#STEPS[@]} - 1))); do
  s=${STEPS[$i]}
  case $s in
    install)  # guests 0 1 (2-VM state before the freeze, or VM8 state with --start vm8)
      log "== install on VMs 0 1"
      inst "0 1" 2 || fail "plain server install on VMs 0 1 failed"
      init_vm0 || fail "init image copy to vm0 failed";;
    switch)
      [ $SKIPSW = 1 ] && { log "== switch skipped (--start vm8: topology already VM8)"; continue; }
      log "== switch 2 -> VM8 topology (4 vCPU / 24 GB per VM)"
      vmn_dry nochain-check
      vmn_dry dry
      for ph in pre gen down freeze overlays net define; do vmn $ph; done;;
    up2|up4|up8)
      n=${s#up}
      [ $SKIPSW = 1 ] && [ $n = 2 ] && { log "== start VMs 0 1 skipped (--start vm8: already running)"; continue; }
      [ "$n" -le $MAXN ] || { log "== start VMs ${NEWVMS[$n]} skipped (no block at N >= $n)"; continue; }
      if [ -n "${DOWN[x]:-}" ]; then log "== start VMs ${NEWVMS[$n]} skipped (an earlier VM start failed)"; DOWN[$n]=1; continue; fi
      log "== start VMs ${NEWVMS[$n]} (N=$n)"
      up=1; for i in ${NEWVMS[$n]}; do [ "$(virsh -c qemu:///system domstate cxl_vm$i 2>/dev/null)" = running ] || up=0; done
      if [ $DRY = 0 ] && [ $up = 1 ]; then   # v3: started (and pretouched) by an earlier run of this chain, e.g. the pilot
        log "VMs ${NEWVMS[$n]} already running: start + pretouch skipped"
        if ! { vmn_soft envcheck && { [ $n = 2 ] || inst "${NEWVMS[$n]}" $n; }; }; then
          DOWN[x]=1 DOWN[$n]=1; log "VM check/install for N=$n FAILED: blocks N >= $n skipped, restore next"
        fi
      elif ! { vmn_soft start ${NEWVMS[$n]} && vmn_soft pretouch-par ${NEWVMS[$n]} && vmn_soft envcheck \
             && { [ $n = 2 ] || inst "${NEWVMS[$n]}" $n; }; }; then
        DOWN[x]=1 DOWN[$n]=1
        log "VM start for N=$n FAILED: blocks N >= $n skipped, restore next"
      fi;;
    n2|n4|n8)
      n=${s#n}
      [[ " $ONLYN " == *" $n "* ]] || { log "== block N=$n skipped (--only-n $ONLYN)"; continue; }
      if [ -n "${DOWN[$n]:-}" ]; then
        FAILED+=("N=$n:all (VM start failed)"); log "== block N=$n skipped (VMs not started)"
        resume_line $n "$(lt_list $n | cut -d' ' -f1)"; continue
      fi
      log "== block N=$n${FROM[$n]:+ from ${FROM[$n]}}"
      block $n;;
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
      log "== export (every evidence dir of run $K per N, later attempt wins)"
      DR=$(conf DERIVED_ROOT) CS=$(conf CONFIG_SHA256_H2N)
      outs=()
      for n in $NS; do
        o=$DR/vdb/h2n-n$n/run$K-all
        if [ $DRY = 1 ]; then outs+=("$o"); xr "export N=$n" python3 -I -B $EVD/export_h2n.py --run $K --nodes $n --config-sha256 $CS --out $o "$(evglob $n)*/block (sorted by v)"
        else
          ds=$(ls -d "$(evglob $n)"*/block 2>/dev/null | sort -V | while read -r d; do [ -s "$d/h2n-results.tsv" ] && [ "$(grep -vc '^#' "$d/h2n-results.tsv")" -gt 0 ] && echo "$d"; done)
          [ -n "$ds" ] || { log "export N=$n: no evidence with results"; continue; }
          # shellcheck disable=SC2086
          xr "export N=$n" python3 -I -B $EVD/export_h2n.py --run $K --nodes $n --config-sha256 $CS --out $o $ds \
            && outs+=("$o") || FAILED+=("N=$n:export (see the chain log)")
        fi
      done
      if [ ${#outs[@]} -gt 0 ]; then
        xr "export combine" python3 -I -B $EVD/export_h2n.py --combine --out $DR/vdb/h2n/run$K "${outs[@]}" \
          || FAILED+=("combine:export")
      else log "export combine skipped: no per-N export"; fi;;
  esac
done
summary "DONE"
# wall-time estimate (2-VM run 1 lifetimes: hw 9-12.5 min, pop 8.5-9.5 min + ~2 min cxl_shm cycle and preload, mg SLO
# part ~10-15 min; + gates/precheck ~1 min each): per N 9 lifetimes ~1.8-2 h; switch ~30 min; start + pretouch ~15 min
# per N; restore ~15 min. Run k ~= 2.3 h (N=2 incl. switch) + 2.1 h (N=4) + 2.2 h (N=8) + 0.3 h (restore) ~= 7 h.
[ $DRY = 1 ] && echo "ESTIMATE: N=2 ~2.3 h (switch 0.5 + start/pretouch 0.25 + 9 lifetimes ~1.6-1.9), N=4 ~2.1 h, N=8 ~2.2 h, restore ~0.3 h: ~7 h per run"
[ ${#FAILED[@]} = 0 ] || exit 1
exit 0

#!/bin/bash
# vmN chain v1: H3 fixed-total topology (32 vCPUs / 192 GiB split over N VMs; user decision 2026-10-20, state/PROJECT.md;
# spec reports/design/evaluation-pipeline.md 6.1). Generalised from workspaces/vm8-chain-v2.sh (G-VM8 v2.2, chain
# 2053b834..., evidence-pinned and unchanged) with a topology parameter:
#   N=4: 4 x (48 GiB, 8 vCPU = 4 whole node0 cores + HT), overlays /var/lib/libvirt/images/vm4-overlays-v1
#   N=8: 8 x (24 GiB, 4 vCPU = 2 whole node0 cores + HT), overlays /var/lib/libvirt/images/vm8-overlays-v2 (= VM8 v2.2;
#        the generator output is byte-identical to vm8-xml.py's)
#   N=2 is the original cxl_vm0/cxl_vm1 (16 vCPU / 96 GiB): reached by the restore path, never generated.
# Topology changes go through the 2-VM state: 2 -> N=4 (switch) -> 2 (restore) -> N=8 (switch) -> 2 (restore).
# usage: VMN_TOPO=4|8 bash workspaces/vmN/vmN-chain-v1.sh <phase> [vm ids]
# env:  VMN_TOPO       4 or 8 (required for every phase)
#       VMN_E          evidence dir written by a live phase (required; $P/recovery/VM8-v* so that
#                      experiments/rocksdb/pretouch-check-n.sh accepts it, e.g. recovery/VM8-v3-n4; never a finished dir)
#       VMN_SRC        restore only: the switch evidence dir to restore from (before/, freeze/, topo<N>/ids.txt; read-only)
#       VMN_IDS_FROM   switch only (optional): ids.txt of an earlier switch (4 or 8 rows); gen reuses its uuids +
#                      machine-ids by domain name and STOPs unless name/uuid/mac/ip/machine-id of every generated row
#                      equal that file's row and the before/ XMLs equal that run's
#       VMN_LIVE=1     required for live phases
#       VMN_OFFLINE=1  dry / dry-restore only: no ssh, no virsh, no ping, no Host state reads (stat/numastat/measure-env);
#                      inputs from saved files (VMN_BEFORE = dir with cxl_vm{0,1}.inactive.xml, net-default.xml,
#                      vcpupin/emulatorpin; dry-restore: VMN_SRC = an offline dry output or a switch dir). Writes
#                      DRY-OFFLINE, which does NOT satisfy any live binding (live phases need an online DRY-PASS).
#   dry                     read-only, 2-VM state: prechecks, XML generation + validation into workspaces/vmN/dry-n<N>,
#                           plan; writes dry-n<N>/DRY-PASS (chain sha, generator sha, topo, ids). MANDATORY before switch.
#   dry-restore             read-only, N-VM state: live-state + base size/mtime + network checks against VMN_SRC; writes
#                           workspaces/vmN/dry-restore-n<N>/DRY-PASS (chain, generator, topo, src, e). MANDATORY before r-*.
#   switch (live): pre gen down freeze overlays net define, then:
#   start <ids> | stop <ids> | pretouch <id> | pretouch-par <ids> | envcheck   (bound by either DRY-PASS of this N)
#   restore (live): r-down r-undefine r-net r-unfreeze r-define r-start, then pretouch-par 0 1, envcheck, r-delete
# Every live phase is fail-closed (STOP line, exit 1) and appends to $E/steps.log; no automatic VM rollback (packet
# rollback by the operator). pretouch/pretouch-par have their own EXIT restore on every touched VM and unlock.
# Changes vs vm8-chain-v2.sh: topology parameter (ids, CPU/RAM checks, overlay dir, DHCP entries); offline dry modes;
# VM8 LOW-3 (every switch/restore phase refuses to run twice in one evidence dir) and LOW-4 (r-start has the node0
# free-memory and OOM checks of start) fixed.
# v2 (verifier review workspaces/verify-vmN, PASS-with-corrections): r-start retry per VM (MED-1); nochain matches the
# evaluation chains/blocks, any *-chain-v*.sh and a second vmN-chain instance, also in r-down (MED-2); ME_PART apply-2;
# node0 free >= N x RAM + 10 GiB before the first start of a switch; live phases only in an evidence dir whose
# steps.log has this chain's "PRE PASS (topo N)" or "R-DOWN PASS (topo N" (never frozen evidence such as VM8-v2.2);
# N=8 gen with VMN_IDS_FROM and the same overlay dir: XMLs cmp-identical to the earlier run's; phase nochain-check.
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
W=$P/workspaces/vmN
ab() { [ -n "$1" ] && realpath -m "$1"; }
E=$(ab "${VMN_E:-}") S=$(ab "${VMN_SRC:-}") IDS=$(ab "${VMN_IDS_FROM:-}") BEF=$(ab "${VMN_BEFORE:-}")
OFF=${VMN_OFFLINE:-0}
N=${VMN_TOPO:-}
case "$N" in
  4) VCPU=8 RAMG=48 OVL=vm4-overlays-v1 MEM_MIN=48800000 MEM_MAX=50331648 FREE_MIN=60000;;
     # 48 GiB MemTotal: inference from the 24 GiB (24,609,924 kB) and 96 GiB (98,875,388 kB) observations, linear
     # reserve ~0.97 M kB -> ~49.37 M kB expected; upper bound = 48 GiB exactly. FREE_MIN scales the VM8 30000 MB/24 GiB.
  8) VCPU=4 RAMG=24 OVL=vm8-overlays-v2 MEM_MIN=24000000 MEM_MAX=25165824 FREE_MIN=30000;;
     # VM8 values (MEM24 observed 24,609,924 kB on K12, VM8 packet 13)
  *) echo "STOP: VMN_TOPO must be 4 or 8 (N=2 = the restore target)"; exit 2;;
esac
ALL=$(seq 0 $((N - 1)) | tr '\n' ' ') NEW=$(seq 2 $((N - 1)) | tr '\n' ' ')
SRCD=$E   # dir with before/ freeze/ topo<N>/ of the topology in use (restore phases: VMN_SRC)
I=/var/lib/libvirt/images
BASE=$I/cxl_vm0.qcow2
D=$I/$OVL
OVL_ANY="$I/vm4-overlays-v1 $I/vm8-overlays-v2"   # no switch while any N-VM overlay dir exists
K12=6.14.0-famfs-de-stijl+-ds-popcorn-new-12
GEN=$W/vmN-xml.py
TOOL=$P/recovery/ENV-pretouch-v2.1/dax-pretouch.py TOOL_SHA=30d068d606e6d0bc9bbc99a5ecc9ed4d2bc64605a7ddfd430ff6bf43f09410ff
GD=/home/comsys/vm8-pretouch
HR=$P/recovery/P-popcorn-build10-eqF-v1.3/harness/CXL_SWMC
GL="bash $HR/experiments/vectordb/host-gate.sh"
ME=$P/CXL_SWMC/scripts/host/measure-env.sh MEP=$P/CXL_SWMC/scripts/host/measure-env-part.sh
ME_BASE=$P/recovery/HOST-measure-env-reapply-1 ME_PART=$P/recovery/HOST-measure-part-apply-2
DAX_SIZE=103060340736 NPAGES=25161216
MEM96_MIN=98000000 MEM96_MAX=99500000   # 96 GiB VM MemTotal (observed 98,875,388 kB, recovery/R6-20261014-v1 P3c VM0)
BASE_ID="CXL_vm0 21a1a314c19942ebbdc85617855ef95d"   # /etc/hostname and /etc/machine-id of the base root fs
NSUUID=9c7db57f-9f44-4462-b367-95e32b0deef9   # live namespace0.0 label (P3c create-namespace) in the shared label area
FREEZE_REC_OFFLINE=$P/recovery/VM8-v2.2/freeze/stat-before.txt   # offline dry-restore only: placeholder owner/mode
V="virsh -c qemu:///system"
LG=$W/lg-root     # libguestfs cache/tmp for the root-run guestfish (inside this workspace; workspaces/vm8 is not touched)
GF="sudo -n env LIBGUESTFS_BACKEND=direct LIBGUESTFS_CACHEDIR=$LG TMPDIR=$LG guestfish"
FLAGS=(-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8)
PH=${1:-}; shift || true
LIVE=${VMN_LIVE:-0}
ip() { echo 192.168.122.$((100 + $1)); }
mac() { printf '52:54:00:c8:00:%02x' $1; }
dhcp() { echo "<host mac='$(mac $1)' ip='$(ip $1)'/>"; }
on() { local k=$1; shift; ssh -T "${FLAGS[@]}" "comsys@$(ip $k)" "$@" < /dev/null; }
LOGF=/dev/null
log() { echo "$(date +%FT%T) $*" | tee -a $LOGF; }
fail() { log "STOP: $*"; exit 1; }
ok() { grep -q -- " $1" $E/steps.log 2>/dev/null; }
once() { ok "$1" && fail "'$1' is already in $E/steps.log: phase not re-runnable in this evidence dir"; return 0; }
x() { if [ "$LIVE" = 1 ]; then log "RUN: $*"; "$@"; else echo "  DRY: $*"; fi; }   # mutating command
state() { $V domstate "$1" 2>/dev/null | head -1; }
waitoff() { local s; for s in $(seq 300); do [ "$(state $1)" = "shut off" ] && return 0; sleep 1; done; return 1; }
nobuild() { ! pgrep -x 'make|cc1|cc1plus|ld' > /dev/null; }
idf() { grep "^cxl_vm$1 " $SRCD/topo$N/ids.txt; }   # name uuid mac ip disk cpus emu machine-id
# other deploy/run/chain processes (incl. a second vmN-chain instance via the generic *-chain-v*.sh term); this
# process and its own subshells are excluded by pid / parent pid
NOCHAIN_RE='[p]3c-deploy\.sh|[l]-vanilla-deploy|[k]ernel-switch\.sh|[p]-popcorn-(deploy|shm|stress)\.sh|[e]xperiments/[a-z0-9]+/run\.sh|[s]equence[0-9]*\.sh|[h]1-chain|[r]ecsysv1-chain|[v]m8-chain|[e]val-run[0-9]*-chain|[e]xperiments/eval/|[m]ain-block\.sh|[r]ecsys/session\.sh|[n]-smoke-chain|[a-zA-Z0-9]-chain[-a-z0-9.]*\.sh'
NOCHAIN_HIT=
nochain() { local p q anc=" "; NOCHAIN_HIT=
  q=$$; while [ -n "$q" ] && [ "$q" -gt 1 ]; do anc+="$q "; q=$(ps -o ppid= -p $q 2>/dev/null | tr -d ' '); done   # self + ancestors (invoking shells)
  for p in $(pgrep -f "$NOCHAIN_RE"); do
    [[ $anc == *" $p "* ]] && continue
    [ "$(ps -o ppid= -p $p 2>/dev/null | tr -d ' ')" = $$ ] && continue   # own subshells
    kill -0 $p 2>/dev/null || continue
    NOCHAIN_HIT="$NOCHAIN_HIT[$p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-160)] "
  done; [ -z "$NOCHAIN_HIT" ]; }
csum() { echo "$(sha256sum $0 | cut -d' ' -f1) $(sha256sum $GEN | cut -d' ' -f1) topo=$N"; }
inN() { [[ " $ALL" == *" $1 "* ]]; }

livegate() {   # livegate switch|restore|any [new]: VMN_LIVE=1, VMN_E, and an online dry PASS of exactly this chain + generator + N
  # without "new" (pre / r-down create E), E/steps.log must hold this chain's PRE PASS (topo N) or R-DOWN PASS (topo N
  [ "$LIVE" = 1 ] || fail "phase $PH is live: set VMN_LIVE=1 (run 'dry' / 'dry-restore' first)"
  if [ "${2:-}" != new ]; then
    case $1 in
      switch) grep -q " PRE PASS (topo $N)" $E/steps.log 2>/dev/null;;
      restore) grep -q " R-DOWN PASS (topo $N," $E/steps.log 2>/dev/null;;
      any) grep -qE " (PRE PASS \(topo $N\)|R-DOWN PASS \(topo $N,)" $E/steps.log 2>/dev/null;;
    esac || fail "VMN_E $E has no 'PRE PASS (topo $N)' / 'R-DOWN PASS (topo $N' line of this chain (not a vmN evidence dir)"
  fi
  [ "$OFF" = 1 ] && fail "VMN_OFFLINE=1 is for dry / dry-restore only"
  [ -n "$E" ] || fail "VMN_E is not set"
  case "$E" in $P/recovery/VM8-v*) ;; *) fail "VMN_E must be $P/recovery/VM8-v* (pretouch-check-n layout)";; esac
  local f ok1=
  case $1 in
    switch) [ "$(cat $W/dry-n$N/DRY-PASS 2>/dev/null)" = "$(csum) ids=${IDS:--}" ] \
              || fail "no dry PASS for this chain/generator/topo/VMN_IDS_FROM (workspaces/vmN/dry-n$N/DRY-PASS)";;
    restore) [ -n "$S" ] && [ "$S" != "$E" ] || fail "VMN_SRC must be set and differ from VMN_E"
             test ! -e $E/topo4 && test ! -e $E/topo8 || fail "VMN_E $E is a switch dir"
             [ "$(cat $W/dry-restore-n$N/DRY-PASS 2>/dev/null)" = "$(csum) src=$S e=$E" ] \
              || fail "no dry-restore PASS for this chain/generator/topo/VMN_SRC/VMN_E (workspaces/vmN/dry-restore-n$N/DRY-PASS)"
             SRCD=$S;;
    any) test -d $E || fail "no evidence dir $E"
         for f in $W/dry-n$N/DRY-PASS $W/dry-restore-n$N/DRY-PASS; do [ "$(cut -d' ' -f1-3 $f 2>/dev/null)" = "$(csum)" ] && ok1=1; done
         [ -n "$ok1" ] || fail "no dry or dry-restore PASS for this chain/generator/topo";;
  esac
  LOGF=$E/steps.log; }

# guestclean <k>: cxl_shm unloaded, dax0.0 root:root 600, no pretouch tool dir, no comsys process with dax0.0 mapped/open
GCS='echo $(grep -c ^cxl_shm /proc/modules) $(stat -c %U:%G-%a /dev/dax0.0) $(test -e '$GD' && echo tooldir || echo notooldir) $(n=0; for p in /proc/[0-9]*; do [ -O $p ] || continue; if grep -qs /dev/dax0.0 $p/maps || ls -l $p/fd 2>/dev/null | grep -q /dev/dax0.0; then n=$((n+1)); fi; done; echo daxusers=$n)'
guestclean() { [ "$(on $1 "$GCS")" = "0 root:root-600 notooldir daxusers=0" ]; }
nsuuid() { [ "$(on $1 cat /sys/bus/nd/devices/namespace0.0/uuid)" = $NSUUID ]; }
off() { [ "$(state $1)" = "shut off" ]; }
basesz() { stat -c '%s %Y' $BASE; }   # /var/lib/libvirt/images is o+x: no sudo needed (observed 2026-10-18)
frozensz() { awk '{print $3, $4}' $SRCD/freeze/stat-before.txt; }
running() { $V list --name --state-running | grep -E '^cxl_vm[0-7]$' | sed 's/cxl_vm//' | sort -n; }
node0free() { numastat -m | awk '/^MemFree/{f=$2} /^Inactive\(file\)/{c=$2} END{print int(f+c)}'; }
oomk() { awk '/^oom_kill /{print $2}' /proc/vmstat; }

# ---------------------------------------------------------------- read-only prechecks (dry and pre)
prechecks() {   # prechecks <dir for saved XMLs>
  local o=$1 i d
  nobuild || fail "Host build running"
  test ! -e $P/workspaces/MEASUREMENT.lock || fail "MEASUREMENT.lock exists"
  nochain || fail "another deploy/run/chain is running: $NOCHAIN_HIT"
  for d in $OVL_ANY; do test ! -e $d || fail "$d exists (overlays of an earlier switch: r-delete first)"; done
  [ -z "$IDS" ] || test -s $IDS || fail "VMN_IDS_FROM $IDS missing"
  [ "$(state cxl_vm0)" = running ] && [ "$(state cxl_vm1)" = running ] || fail "vm0/vm1 not both running"
  [ "$(state cxl_vmx)" = "shut off" ] || fail "cxl_vmx not shut off"
  for i in 2 3 4 5 6 7; do $V dominfo cxl_vm$i > /dev/null 2>&1 && fail "cxl_vm$i already defined"; done
  for i in 0 1; do [ "$(on $i uname -r)" = $K12 ] || fail "vm$i kernel"; guestclean $i || fail "vm$i not clean (cxl_shm/dax0.0/tool dir)"; nsuuid $i || fail "vm$i namespace0.0 uuid != $NSUUID"; done
  $V net-dumpxml default > $o/net-default.xml || fail "net-dumpxml"
  for i in 2 3 4 5 6 7; do   # all six VM8 addresses must be free, whatever N (no leftover of an earlier topology)
    grep -q "$(ip $i)'" $o/net-default.xml && fail "DHCP entry for $(ip $i) exists"
    grep -qi "$(mac $i)" $o/net-default.xml && fail "MAC $(mac $i) in use"
    ping -c1 -W1 $(ip $i) > /dev/null 2>&1 && fail "$(ip $i) answers ping"
  done
  for d in cxl_vm0 cxl_vm1 cxl_vmx; do $V dumpxml --inactive $d > $o/$d.inactive.xml || fail "dumpxml $d"; done
  for d in cxl_vm0 cxl_vm1; do $V dumpxml $d > $o/$d.live.xml; $V vcpupin $d > $o/$d.vcpupin.txt; $V emulatorpin $d > $o/$d.emulatorpin.txt; done
  grep -q "<source file='$BASE'/>" $o/cxl_vm0.inactive.xml || fail "vm0 disk is not $BASE"
  grep -q "<source file='$I/cxl_vm1.qcow2'/>" $o/cxl_vm1.inactive.xml || fail "vm1 disk"
  $V list --all > $o/virsh-list.txt; numastat -m > $o/numastat-m.txt; df -h / > $o/df.txt; cat /proc/loadavg > $o/loadavg.txt
  bash $ME check $ME_BASE > $o/measure-env-check.txt 2>&1; bash $MEP check $ME_BASE $ME_PART > $o/measure-part-check.txt 2>&1
  log "prechecks PASS (saved in $o)"; }
prechecks_offline() {   # prechecks_offline <dir>: copy the saved 2-VM files from VMN_BEFORE (no Host or guest access)
  local o=$1 f
  [ -n "$BEF" ] || fail "VMN_OFFLINE=1 needs VMN_BEFORE (dir with saved cxl_vm{0,1}.inactive.xml, net-default.xml, pins)"
  for f in cxl_vm0.inactive.xml cxl_vm1.inactive.xml net-default.xml cxl_vm0.vcpupin.txt cxl_vm1.vcpupin.txt \
           cxl_vm0.emulatorpin.txt cxl_vm1.emulatorpin.txt; do
    test -s $BEF/$f || fail "missing $BEF/$f"; cp -p $BEF/$f $o/$f; done
  [ -z "$IDS" ] || test -s $IDS || fail "VMN_IDS_FROM $IDS missing"
  grep -q "<source file='$BASE'/>" $o/cxl_vm0.inactive.xml || fail "vm0 disk is not $BASE"
  grep -q "<source file='$I/cxl_vm1.qcow2'/>" $o/cxl_vm1.inactive.xml || fail "vm1 disk"
  for i in 2 3 4 5 6 7; do grep -q "$(ip $i)'" $o/net-default.xml && fail "saved net-default.xml has a DHCP entry for $(ip $i)"; done
  log "prechecks OFFLINE PASS (saved files from $BEF; NOT checked: lock, build, chains, VM states, guests, ping, overlay dirs, measure-env)"; }

gen() {   # gen <before dir> <out dir>
  local b=$1 o=$2 f n row old
  python3 -I -B $GEN --n $N --vcpus $VCPU --ram-gib $RAMG --vm0 $b/cxl_vm0.inactive.xml --vm1 $b/cxl_vm1.inactive.xml \
    --overlay-dir $D --out $o ${IDS:+--ids-from $IDS} > $o.gen.txt || fail "generator"
  [ "$(wc -l < $o/ids.txt)" = $N ] || fail "ids.txt does not have $N rows"
  if [ -n "$IDS" ]; then   # re-use: same name/uuid/mac/ip/machine-id as the earlier run, from the same base XMLs
    while read -r row; do
      set -- $row; old=$(grep "^$1 " $IDS) || fail "$1 not in VMN_IDS_FROM $IDS"
      [ "$(echo $row | cut -d' ' -f1-4,8)" = "$(echo $old | cut -d' ' -f1-4,8)" ] || fail "$1 identity differs from VMN_IDS_FROM"
    done < $o/ids.txt
    for n in 0 1; do cmp -s $b/cxl_vm$n.inactive.xml $(dirname $IDS)/../before/cxl_vm$n.inactive.xml || fail "cxl_vm$n inactive XML differs from the earlier run's before/"; done
    # same topology and overlay dir as the earlier run (N=8 re-switch of VM8-v2.x): the XMLs must be byte-identical
    if [ "$(wc -l < $IDS)" = $N ] && [ "$(awk 'NR==1{print $5}' $IDS)" = "$D/cxl_vm0.qcow2" ]; then
      for n in $ALL; do cmp -s $o/cxl_vm$n.xml $(dirname $IDS)/cxl_vm$n.xml || fail "cxl_vm$n.xml differs from $(dirname $IDS)/cxl_vm$n.xml"; done
      log "gen: all $N XMLs byte-identical to $(dirname $IDS)"
    fi
  fi
  for n in $ALL; do
    f=$o/cxl_vm$n.xml; virt-xml-validate $f > /dev/null 2>&1 || fail "virt-xml-validate $f"
    # allowed differences vs the base (name/uuid/mac only for new guests; vcpu, pins, memory, topology, cell, disk, kernel dir)
    local base=$b/cxl_vm0.inactive.xml; [ $n = 1 ] && base=$b/cxl_vm1.inactive.xml
    diff <(xmllint --format $base) <(xmllint --format $f) | grep '^[<>]' \
      | grep -vE '^[<>] <domain (xmlns:libosinfo="[^"]*" )?type="kvm">$|libosinfo:libosinfo|<name>|<uuid>|<memory unit=|<currentMemory|<vcpu |<vcpupin|<emulatorpin|<topology |<cell id=|<source file=.(/var/lib/libvirt/images/(cxl_vm[01]|'$OVL'/cxl_vm[0-7])\.qcow2)|<mac address=|<kernel>/var/lib/libvirt/images/popcorn-new-12-vm[01]-v1/bzImage|<initrd>/var/lib/libvirt/images/popcorn-new-12-vm[01]-v1/' \
      > $o/cxl_vm$n.unexpected-diff.txt
    [ -s $o/cxl_vm$n.unexpected-diff.txt ] && fail "unexpected XML diff cxl_vm$n (see $o/cxl_vm$n.unexpected-diff.txt)"
    grep -q "<vcpu placement=.static.>$VCPU</vcpu>" $f && grep -q "<topology sockets=.1. dies=.1. cores=.$((VCPU / 2)). threads=.2." $f \
      && grep -q "<cell id=.0. cpus=.0-$((VCPU - 1)). memory=.$((RAMG * 1048576)). unit=.KiB." $f || fail "cxl_vm$n vcpu/topology/cell"
  done
  (cd $o && sha256sum cxl_vm*.xml ids.txt > SHA256SUMS)
  log "gen PASS ($o)"; }

# ---------------------------------------------------------------- switch phases
ph_pre() { livegate switch new; test ! -e $E || fail "$E exists"; mkdir -p $E/before; LOGF=$E/steps.log
  local d; for d in $OVL_ANY; do sudo -n test ! -e $d || fail "$d exists"; done; prechecks $E/before; log "PRE PASS (topo $N)"; }
ph_gen() { livegate switch; ok "PRE PASS" || fail "pre not passed"; once "GEN PASS"; mkdir -p $E/topo$N; gen $E/before $E/topo$N; log "GEN PASS"; }
ph_down() { livegate switch; ok "GEN PASS" || fail "gen not passed"; once "DOWN PASS"
  for i in 0 1; do guestclean $i || fail "vm$i not clean"; done
  x $V shutdown cxl_vm1; x $V shutdown cxl_vm0
  waitoff cxl_vm1 || fail "vm1 not shut off in 300 s (destroy only with the user's OK)"
  waitoff cxl_vm0 || fail "vm0 not shut off in 300 s (destroy only with the user's OK)"
  log "DOWN PASS"; }
ph_freeze() { livegate switch; ok "DOWN PASS" || fail "down not passed"; once "FREEZE PASS"; mkdir -p $E/freeze
  [ "$(state cxl_vm0)" = "shut off" ] || fail "vm0 running"
  sudo -n stat -c '%U:%G %a %s %Y %n' $BASE > $E/freeze/stat-before.txt || fail "stat"
  sudo -n qemu-img info -U --output=json $BASE > $E/freeze/qemu-img-info.json || fail "qemu-img info"
  grep -q '"backing-filename"' $E/freeze/qemu-img-info.json && fail "base has a backing file"
  x sudo -n chmod 0444 $BASE
  sudo -n stat -c '%U:%G %a %s %Y %n' $BASE > $E/freeze/stat-after.txt
  [ "$(cut -d' ' -f2 $E/freeze/stat-after.txt)" = 444 ] || fail "chmod 0444"
  log "FREEZE PASS ($(cat $E/freeze/stat-before.txt) -> mode 444)"; }
ph_overlays() { livegate switch; ok "FREEZE PASS" || fail "freeze not passed"; once "OVERLAYS PASS"; mkdir -p $E/overlays $LG
  basesz > $E/overlays/base-stat-before.txt; [ "$(cat $E/overlays/base-stat-before.txt)" = "$(frozensz)" ] || fail "base size/mtime changed since freeze"
  sudo -n test ! -e $D || fail "$D exists"
  x sudo -n install -d -o root -g kvm -m 0750 $D
  local i mid out
  for i in $ALL; do
    x sudo -n qemu-img create -q -f qcow2 -F qcow2 -b $BASE $D/cxl_vm$i.qcow2 || fail "qemu-img create vm$i"
  done
  # vm0's overlay (unedited) = the base content: record identity and netplan (incl. 50-cloud-init.yaml) once
  $GF --ro -a $D/cxl_vm0.qcow2 -m /dev/sda1 > $E/overlays/vm0-identity.txt 2>&1 <<'EOF' || fail "guestfish read vm0 overlay"
cat /etc/hostname
cat /etc/machine-id
ls /etc/netplan
cat /etc/netplan/50-cloud-init.yaml
cat /etc/netplan/99-dhcp.yaml
EOF
  [ "$(echo $(grep -v '^[[:space:]]*$' $E/overlays/vm0-identity.txt | head -2))" = "$BASE_ID" ] || fail "base identity not $BASE_ID (wrong fs?)"
  grep -q 'enp1s0' $E/overlays/vm0-identity.txt || fail "99-dhcp.yaml enp1s0 not found"
  $GF --ro -a $D/cxl_vm0.qcow2 -m /dev/sda1 cat /etc/netplan/50-cloud-init.yaml > $E/overlays/vm0-50-cloud-init.yaml 2>&1 || fail "read 50-cloud-init.yaml"
  grep -vE '^[[:space:]]*(#.*)?$|^[[:space:]]*(network|version|ethernets|renderer|enp1s0|eth0|match|macaddress|set-name|dhcp4|dhcp6|optional):' \
    $E/overlays/vm0-50-cloud-init.yaml > $E/overlays/vm0-50-cloud-init.other.txt
  [ -s $E/overlays/vm0-50-cloud-init.other.txt ] && fail "50-cloud-init.yaml has non-network content (see vm0-50-cloud-init.other.txt)"
  for i in $ALL; do
    [ $i = 0 ] && continue
    mid=$(idf $i | cut -d' ' -f8); [ ${#mid} = 32 ] || fail "machine-id vm$i"
    $GF --rw -a $D/cxl_vm$i.qcow2 -m /dev/sda1 > $E/overlays/vm$i-edit.txt 2>&1 <<EOF || fail "guestfish edit vm$i"
write /etc/hostname "cxlvm$i\n"
write /etc/machine-id "$mid\n"
rm-f /etc/netplan/50-cloud-init.yaml
EOF
    out=$($GF --ro -a $D/cxl_vm$i.qcow2 -m /dev/sda1 2>&1 <<'EOF'
cat /etc/hostname
cat /etc/machine-id
exists /etc/netplan/50-cloud-init.yaml
exists /etc/netplan/99-dhcp.yaml
EOF
)
    echo "$out" > $E/overlays/vm$i-verify.txt
    [ "$(echo $out)" = "cxlvm$i $mid false true" ] || fail "overlay vm$i verify: $(echo $out)"
    log "overlay vm$i: hostname cxlvm$i machine-id $mid, 50-cloud-init.yaml removed"
  done
  sudo -n qemu-img info -U --backing-chain $D/cxl_vm$((N - 1)).qcow2 > $E/overlays/chain-vm$((N - 1)).txt
  sudo -n ls -la $D > $E/overlays/ls.txt; sudo -n stat -c '%U:%G %a' $BASE | grep -c ' 444$' > /dev/null || fail "base mode changed"
  basesz > $E/overlays/base-stat-after.txt; [ "$(cat $E/overlays/base-stat-after.txt)" = "$(frozensz)" ] || fail "base size/mtime changed during overlays"
  log "OVERLAYS PASS"; }
ph_net() { livegate switch; ok "OVERLAYS PASS" || fail "overlays not passed"; once "NET PASS"; local i
  for i in $NEW; do
    x $V net-update default add ip-dhcp-host "$(dhcp $i)" --live --config || fail "net-update vm$i"
  done
  $V net-dumpxml default > $E/net-after.xml
  for i in $NEW; do grep -q "$(dhcp $i)" $E/net-after.xml || fail "dhcp $(ip $i)"; done
  $V net-dumpxml --inactive default | grep -c "ip='192.168.122.10[2-7]'" | grep -qx $((N - 2)) || fail "dhcp --config"
  log "NET PASS"; }
ph_define() { livegate switch; ok "NET PASS" || fail "net not passed"; once "DEFINE PASS"; local i
  for i in $ALL; do
    x $V define $E/topo$N/cxl_vm$i.xml || fail "define vm$i"
    $V dumpxml --inactive cxl_vm$i > $E/topo$N/cxl_vm$i.after-define.xml
    [ "$($V domuuid cxl_vm$i)" = "$(idf $i | cut -d' ' -f2)" ] || fail "uuid vm$i"
    grep -q "<vcpu placement='static'>$VCPU</vcpu>" $E/topo$N/cxl_vm$i.after-define.xml && grep -q "$D/cxl_vm$i.qcow2" $E/topo$N/cxl_vm$i.after-define.xml || fail "defined XML vm$i"
  done
  log "DEFINE PASS"; }

# ---------------------------------------------------------------- start / stop / checks
hostexp() { case $1 in 0) echo CXLvm0;; *) echo cxlvm$1;; esac; }
ph_start() { livegate any; ok "DEFINE PASS" || fail "define not passed (start runs in the switch dir)"; local k s oom0 out mid
  for k in "$@"; do
    inN $k || fail "vm id $k not in topology $N"
    [ "$(state cxl_vm$k)" = "shut off" ] || fail "vm$k not shut off"
    test ! -e $P/workspaces/MEASUREMENT.lock || fail "MEASUREMENT.lock exists"
    local j; for j in $(running); do guestclean $j || fail "running vm$j not clean"; done
    local free; free=$(node0free)
    [ "$free" -ge $FREE_MIN ] || fail "node0 MemFree+Inactive(file) $free MB < $FREE_MIN MB"
    if ! ok "START PASS vm"; then   # first start of this switch: the whole topology must fit (N x RAM + 10 GiB)
      [ "$free" -ge $((N * RAMG * 1024 + 10240)) ] || fail "first start: node0 MemFree+Inactive(file) $free MB < $((N * RAMG * 1024 + 10240)) MB"
    fi
    oom0=$(oomk)
    x $V start cxl_vm$k || fail "start vm$k"
    local se=$E/ssh-vm$k-$(date +%H%M%S).err
    for s in $(seq 48); do on $k true 2> $se && break; sleep 5; done
    on $k true 2>> $se || fail "vm$k: no ssh in 240 s (see $se; host key line missing for $(ip $k)?)"
    out=$(on $k "hostname; cat /etc/machine-id; nproc; lscpu | awk '/^Thread\\(s\\) per core/{print \$NF}'; awk '/MemTotal/{print \$2}' /proc/meminfo; uname -r; cat /sys/bus/dax/devices/dax0.0/size; stat -c %U:%G-%a /dev/dax0.0; grep -c ^cxl_shm /proc/modules; ip -4 -br addr show enp1s0 | awk '{print \$3}'; cat /sys/bus/nd/devices/namespace0.0/uuid")
    echo "$out" > $E/start-vm$k-$(date +%H%M%S).txt
    local a; read -r -a a <<< "$(echo $out)"
    mid=$(idf $k | cut -d' ' -f8)
    [ "${a[0]:-}" = "$(hostexp $k)" ] || fail "vm$k hostname ${a[0]:-}"
    [ "${a[1]:-}" = "$mid" ] || fail "vm$k machine-id ${a[1]:-}"
    [ "${a[2]:-}" = $VCPU ] && [ "${a[3]:-}" = 2 ] || fail "vm$k nproc/threads ${a[2]:-}/${a[3]:-} (want $VCPU/2)"
    [ "${a[4]:-0}" -ge $MEM_MIN ] && [ "${a[4]:-0}" -le $MEM_MAX ] || fail "vm$k MemTotal ${a[4]:-} (want $MEM_MIN-$MEM_MAX kB)"
    [ "${a[5]:-}" = $K12 ] && [ "${a[6]:-}" = $DAX_SIZE ] && [ "${a[7]:-}" = root:root-600 ] && [ "${a[8]:-}" = 0 ] || fail "vm$k kernel/dax/cxl_shm: ${a[*]:5:4}"
    [ "${a[9]:-}" = "$(ip $k)/24" ] || fail "vm$k ip ${a[9]:-}"
    [ "${a[10]:-}" = $NSUUID ] || fail "vm$k namespace0.0 uuid ${a[10]:-}"
    [ "$($V vcpupin cxl_vm$k | awk '/^ *[0-9]+ /{printf "%s,",$2}')" = "$(idf $k | cut -d' ' -f6)," ] || fail "vm$k vcpupin"
    [ "$($V emulatorpin cxl_vm$k | awk '/\*:/{print $2}')" = "$(idf $k | cut -d' ' -f7)" ] || fail "vm$k emulatorpin"
    [ "$(oomk)" = "$oom0" ] || fail "Host oom_kill after vm$k start"
    log "START PASS vm$k ($(ip $k), node0 free+inactive-file before ${free} MB)"
  done
  local r; r=$(for k in $(running); do on $k cat /etc/machine-id; done | sort | uniq -d)
  [ -z "$r" ] || fail "duplicate machine-id among running VMs: $r"; }
ph_stop() { livegate any; local k
  for k in "$@"; do inN $k || fail "vm id $k not in topology $N"; guestclean $k || fail "vm$k not clean"; x $V shutdown cxl_vm$k; done
  for k in "$@"; do waitoff cxl_vm$k || fail "vm$k not shut off in 300 s"; log "STOP PASS vm$k"; done; }

# ---------------------------------------------------------------- pretouch (ENV-pretouch v2.1 tool; unchanged from VM8 v2.2)
LOCKED= CHGS=
pt_finish() { local rc=$? k
  if [ $rc != 0 ]; then
    [ -n "$(jobs -p)" ] && kill $(jobs -p) 2> /dev/null
    for k in $CHGS; do
      on $k "pkill -u comsys -f '^python3 -B $GD/dax-pretouch.py'; sleep 2; sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; rm -f $GD/dax-pretouch.py; rmdir $GD 2>/dev/null; stat -c %U:%G-%a /dev/dax0.0" \
        >> $E/pretouch-restore.log 2>&1; log "pretouch vm$k auto-restore: $(tail -1 $E/pretouch-restore.log)"
    done
  fi
  [ -n "$LOCKED" ] && { $GL unlock $LOCKED >> $E/lock.log 2>&1 && log "unlocked $LOCKED" || log "STOP: unlock $LOCKED failed"; }
  echo "PHASE $PH END rc=$rc"; }
pt_pre() {   # pt_pre <k...>: preconditions (before the lock)
  local k j seen=" "
  [ $# -ge 1 ] || fail "no vm ids"
  for k in "$@"; do [[ $k =~ ^[0-7]$ ]] && inN $k || fail "bad vm id $k (topology $N)"; [[ $seen == *" $k "* ]] && fail "vm$k listed twice"; seen+="$k "; done
  [ "$(sha256sum $TOOL | cut -d' ' -f1)" = $TOOL_SHA ] || fail "tool hash"
  for k in "$@"; do [ "$(state cxl_vm$k)" = running ] || fail "vm$k not running"; done
  for j in $(running); do guestclean $j || fail "vm$j not clean (every running VM must be unused during a pretouch)"; done
  nobuild || fail "Host build"; }
pt_setup() {
  local k=$1
  on $k "test ! -e $GD && mkdir -m 0700 $GD" || fail "$GD exists on vm$k"; CHGS="$CHGS $k"
  scp -q "${FLAGS[@]}" $TOOL "comsys@$(ip $k):$GD/dax-pretouch.py" || fail "copy tool vm$k"
  [ "$(on $k "sha256sum $GD/dax-pretouch.py" | cut -d' ' -f1)" = $TOOL_SHA ] || fail "tool hash on vm$k"
  [ "$(on $k 'sudo -n chown comsys /dev/dax0.0 && stat -c %U:%G-%a /dev/dax0.0')" = comsys:root-600 ] || fail "chown vm$k"; }
pt_run() { on $1 "timeout 3600 env PYTHONDONTWRITEBYTECODE=1 python3 -B $GD/dax-pretouch.py" > $2 2>&1; }
pt_done() {
  local k=$1 f=$2
  grep -qx "PRETOUCH DONE pages=$NPAGES" $f || fail "pretouch vm$k: no DONE line"
  [ "$(on $k 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0 && stat -c %U:%G-%a /dev/dax0.0')" = root:root-600 ] || fail "unchown vm$k"
  on $k "rm -f $GD/dax-pretouch.py && rmdir $GD" || fail "remove tool vm$k"
  CHGS=$(for j in $CHGS; do [ $j = $k ] || echo $j; done | tr '\n' ' ')
  cp -p -f $f $E/pretouch-vm$k.txt || fail "copy $f"; }
pt_pass() { log "PRETOUCH PASS vm$1: $(grep -E '^(first|warm) total' $2 | tr '\n' ' ')"; log "T$1 DONE (pretouch-gate layout: pretouch-vm$1.txt)"; }
ph_pretouch() { livegate any; local k=${1:?vm id} f
  pt_pre $k
  trap pt_finish EXIT; trap 'fail "signal received"' INT TERM HUP
  $GL lock VMN-pretouch-vm$k >> $E/lock.log 2>&1 || fail "lock"; LOCKED=VMN-pretouch-vm$k
  pt_setup $k
  log "pretouch vm$k start"
  f=$E/pretouch-vm$k-$(date +%H%M%S).txt
  pt_run $k $f || fail "pretouch vm$k"
  pt_done $k $f
  $GL unlock $LOCKED >> $E/lock.log 2>&1 || fail "unlock"; LOCKED=
  pt_pass $k $f; }
ph_pretouch_par() { livegate any; local ks=("$@") k t pid rc n; declare -A F=() PID=()
  pt_pre "$@"
  trap pt_finish EXIT; trap 'fail "signal received"' INT TERM HUP
  local own="VMN-pretouch-par-$(IFS=-; echo "${ks[*]}")"
  $GL lock $own >> $E/lock.log 2>&1 || fail "lock"; LOCKED=$own
  for k in "${ks[@]}"; do pt_setup $k; done
  t=$(date +%H%M%S)
  for k in "${ks[@]}"; do
    F[$k]=$E/pretouch-vm$k-$t.txt; log "pretouch vm$k start"
    pt_run $k ${F[$k]} & PID[$k]=$!
  done
  n=${#ks[@]}
  while [ $n -gt 0 ]; do
    sleep 5
    for k in "${!PID[@]}"; do
      pid=${PID[$k]}; kill -0 $pid 2> /dev/null && continue
      wait $pid; rc=$?; unset "PID[$k]"; n=$((n - 1))
      [ $rc = 0 ] || fail "pretouch vm$k (rc $rc)"
      grep -qx "PRETOUCH DONE pages=$NPAGES" ${F[$k]} || fail "pretouch vm$k: no DONE line"
      log "pretouch vm$k finished"
    done
  done
  for k in "${ks[@]}"; do pt_done $k ${F[$k]}; done
  $GL unlock $LOCKED >> $E/lock.log 2>&1 || fail "unlock"; LOCKED=
  for k in "${ks[@]}"; do pt_pass $k ${F[$k]}; done
  log "PRETOUCH-PAR PASS (${ks[*]})"; }
ph_envcheck() { livegate any; local t=$(date +%H%M%S)
  bash $ME check $ME_BASE > $E/envcheck-$t-base.txt 2>&1
  bash $MEP check $ME_BASE $ME_PART > $E/envcheck-$t-part.txt 2>&1 && log "ENVCHECK PASS ($(tail -1 $E/envcheck-$t-part.txt))" \
    || fail "measure-env part check FAIL (see envcheck-$t-part.txt): main reapplies measure-env + part into new recovery dirs"; }

# ---------------------------------------------------------------- restore (reads VMN_SRC, writes VMN_E)
ph_r_down() { livegate restore new; mkdir -p $E; LOGF=$E/steps.log; once "R-DOWN PASS"; local k
  test ! -e $P/workspaces/MEASUREMENT.lock || fail "MEASUREMENT.lock exists"
  nochain || fail "another deploy/run/chain is running: $NOCHAIN_HIT"
  for k in $(running); do inN $k || fail "running cxl_vm$k is outside topology $N"; guestclean $k || fail "vm$k not clean"; done
  for k in $(running); do x $V shutdown cxl_vm$k; done
  for k in $ALL; do waitoff cxl_vm$k || fail "vm$k not shut off in 300 s"; done; log "R-DOWN PASS (topo $N, from $S)"; }
ph_r_undefine() { livegate restore; ok "R-DOWN PASS" || fail "r-down not passed"; once "R-UNDEFINE PASS"; local k u
  for k in $ALL; do off cxl_vm$k || fail "cxl_vm$k not shut off (live state)"; done
  for k in $NEW; do
    u=$(idf $k | cut -d' ' -f2)
    [ "$($V domuuid cxl_vm$k)" = "$u" ] || fail "cxl_vm$k uuid is not the one this switch defined"
    $V dumpxml --inactive cxl_vm$k | grep -c "$D/cxl_vm$k.qcow2" > /dev/null || fail "cxl_vm$k disk not the overlay"
    x $V undefine $u || fail "undefine vm$k"
  done; log "R-UNDEFINE PASS"; }
netdiff() {   # netdiff <out>: the --inactive network XML without the N-2 entries vs $SRCD/before/net-default.xml
  diff <(xmllint --format $SRCD/before/net-default.xml | grep -v '<network') \
       <($V net-dumpxml --inactive default | xmllint --format - | grep -v '<network' | grep -vE "<host mac=\"52:54:00:c8:00:0[2-$((N - 1))]\" ip=\"192.168.122.10[2-$((N - 1))]\"/>") > $1; }
ph_r_net() { livegate restore; ok "R-UNDEFINE PASS" || fail "r-undefine not passed"; once "R-NET PASS"; local k
  for k in $NEW; do
    x $V net-update default delete ip-dhcp-host "$(dhcp $k)" --live --config || fail "net delete vm$k"
  done
  $V net-dumpxml --inactive default > $E/net-restored.xml
  grep -q "192.168.122.10[2-7]'" $E/net-restored.xml && fail "a .102-.107 entry is still in the --inactive network XML"
  $V net-dumpxml default | grep -c "192.168.122.10[2-7]'" > /dev/null && fail "a .102-.107 entry is still in the live network XML"
  netdiff $E/net-restore-diff.txt || fail "net differs from before (see net-restore-diff.txt)"
  log "R-NET PASS"; }
ph_r_unfreeze() { livegate restore; ok "R-NET PASS" || fail "r-net not passed"; once "R-UNFREEZE PASS"; local k
  for k in 0 1; do off cxl_vm$k || fail "cxl_vm$k not shut off (live state)"; done
  for k in 2 3 4 5 6 7; do $V dominfo cxl_vm$k > /dev/null 2>&1 && fail "cxl_vm$k still defined"; done
  pgrep -af qemu-system | grep -c "$OVL" > /dev/null && fail "a QEMU still uses an overlay"
  [ "$(basesz)" = "$(frozensz)" ] || fail "base size/mtime differ from freeze record: base was written (overlays invalid; stop, report)"
  local own mode; read own mode _ < $SRCD/freeze/stat-before.txt
  x sudo -n chmod $mode $BASE; x sudo -n chown $own $BASE
  [ "$(stat -c '%U:%G %a' $BASE)" = "$own $mode" ] || fail "base owner/mode not restored"
  log "R-UNFREEZE PASS ($own $mode)"; }
ph_r_define() { livegate restore; ok "R-UNFREEZE PASS" || fail "r-unfreeze not passed"; once "R-DEFINE PASS"; local d
  for d in cxl_vm0 cxl_vm1; do
    off $d || fail "$d not shut off (live state)"
    x $V define $SRCD/before/$d.inactive.xml || fail "define $d"
    diff <($V dumpxml --inactive $d) $SRCD/before/$d.inactive.xml > $E/$d.restore-diff.txt || fail "$d inactive XML differs from before"
  done; log "R-DEFINE PASS"; }
ph_r_start() { livegate restore; ok "R-DEFINE PASS" || fail "r-define not passed"; local k s out free oom0
  for k in 0 1; do
    ok "RSTART PASS vm$k" && continue   # retry after a partial r-start: skip the VMs that already passed
    off cxl_vm$k || fail "vm$k not shut off"
    free=$(node0free); [ "$free" -ge 100000 ] || fail "node0 MemFree+Inactive(file) $free MB < 100000 MB (96 GiB VM)"
    oom0=$(oomk)
    x $V start cxl_vm$k || fail "start vm$k"
    for s in $(seq 48); do on $k true 2> /dev/null && break; sleep 5; done
    out=$(on $k "hostname; nproc; awk '/MemTotal/{print \$2}' /proc/meminfo; uname -r; cat /sys/bus/dax/devices/dax0.0/size; stat -c %U:%G-%a /dev/dax0.0; cat /sys/bus/nd/devices/namespace0.0/uuid") || fail "ssh vm$k"
    echo "$out" > $E/rstart-vm$k-$(date +%H%M%S).txt; local a; read -r -a a <<< "$(echo $out)"
    [ "${a[0]:-}" = "$([ $k = 0 ] && echo CXLvm0 || echo cxlvm1)" ] && [ "${a[1]:-}" = 16 ] && [ "${a[2]:-0}" -ge $MEM96_MIN ] && [ "${a[2]:-0}" -le $MEM96_MAX ] \
      && [ "${a[3]:-}" = $K12 ] && [ "${a[4]:-}" = $DAX_SIZE ] && [ "${a[5]:-}" = root:root-600 ] && [ "${a[6]:-}" = $NSUUID ] || fail "vm$k restore check: $(echo $out)"
    diff <($V vcpupin cxl_vm$k) $SRCD/before/cxl_vm$k.vcpupin.txt > /dev/null && diff <($V emulatorpin cxl_vm$k) $SRCD/before/cxl_vm$k.emulatorpin.txt > /dev/null \
      || fail "vm$k pins differ from before"
    $V domblklist cxl_vm$k | grep -c "$I/cxl_vm$k.qcow2" > /dev/null || fail "vm$k disk"
    [ "$(oomk)" = "$oom0" ] || fail "Host oom_kill after vm$k start"
    log "RSTART PASS vm$k (node0 free+inactive-file before ${free} MB)"
  done; }
ph_r_delete() { livegate restore; ok "RSTART PASS vm1" || fail "r-start not passed"; once "R-DELETE PASS"
  local k; for k in 2 3 4 5 6 7; do $V dominfo cxl_vm$k > /dev/null 2>&1 && fail "cxl_vm$k still defined"; done
  pgrep -af qemu-system | grep -c "$OVL" > /dev/null && fail "a QEMU still uses an overlay"
  for k in 0 1; do $V domblklist cxl_vm$k | grep -c "$OVL" > /dev/null && fail "cxl_vm$k still references an overlay"; done
  for k in $ALL; do x sudo -n rm -f $D/cxl_vm$k.qcow2; done
  x sudo -n rmdir $D || fail "rmdir $D (unexpected files?)"
  log "R-DELETE PASS ($D removed; base $BASE untouched by the overlays)"; }

# ---------------------------------------------------------------- dry (2-VM state) and dry-restore (N-VM state)
plan_switch() {   # printed by dry: every mutating command of the live switch, in order (x = DRY line)
  local k TE=$1 ids=$2
  echo "PLAN switch to N=$N (live, VMN_TOPO=$N VMN_LIVE=1, VMN_E=$TE${IDS:+, VMN_IDS_FROM=$IDS}):"
  echo " pre: mkdir E/before; sudo -n test ! -e $I/vm4-overlays-v1 and $I/vm8-overlays-v2; read-only prechecks -> E/before"
  echo " gen: vmN-xml.py --n $N --vcpus $VCPU --ram-gib $RAMG E/before -> E/topo$N; virt-xml-validate; diff whitelist"
  echo " down:"; x $V shutdown cxl_vm1; x $V shutdown cxl_vm0
  echo " freeze (read: sudo -n stat, sudo -n qemu-img info -U):"; x sudo -n chmod 0444 $BASE
  echo " overlays:"; x sudo -n install -d -o root -g kvm -m 0750 $D
  for k in $ALL; do x sudo -n qemu-img create -q -f qcow2 -F qcow2 -b $BASE $D/cxl_vm$k.qcow2; done
  echo "  DRY: guestfish --ro $D/cxl_vm0.qcow2: cat hostname/machine-id/netplan (base identity = $BASE_ID)"
  for k in $ALL; do [ $k = 0 ] && continue; echo "  DRY: guestfish --rw $D/cxl_vm$k.qcow2: /etc/hostname=cxlvm$k, /etc/machine-id=$(grep "^cxl_vm$k " $ids | cut -d' ' -f8), rm-f /etc/netplan/50-cloud-init.yaml; --ro verify"; done
  echo "  (read: sudo -n qemu-img info -U --backing-chain, sudo -n ls -la $D)"
  echo " net:"; for k in $NEW; do x $V net-update default add ip-dhcp-host "$(dhcp $k)" --live --config; done
  echo " define:"; for k in $ALL; do x $V define E/topo$N/cxl_vm$k.xml; done
  echo " start $ALL(each: virsh start, ssh <= 240 s, identity/nproc $VCPU/MemTotal $MEM_MIN-$MEM_MAX kB/pins/oom checks):"
  for k in $ALL; do x $V start cxl_vm$k; done
  echo " envcheck: bash $MEP check (read-only)"
  echo " pretouch-par $ALL(one Host lock '$GL lock VMN-pretouch-par-$(echo $ALL | tr ' ' '-')'; per VM over ssh: mkdir $GD, scp tool,"
  echo "   sudo -n chown comsys /dev/dax0.0, python3 dax-pretouch.py (content-preserving 1 byte/4 KiB of dax0.0, ~3 min, parallel),"
  echo "   sudo -n chown root:root + chmod 600 /dev/dax0.0, rm tool; unlock)"
  echo " stop <ids>: virsh shutdown cxl_vm<k> (guest clean first)"; }
plan_restore() {   # printed by dry-restore: every mutating command of the live restore, in order
  local k own=$1 mode=$2 src=$3 te=$4
  echo "PLAN restore N=$N -> 2 VMs (live, VMN_TOPO=$N VMN_LIVE=1, VMN_SRC=$src, VMN_E=$te):"
  echo " r-down:"; for k in $ALL; do x $V shutdown cxl_vm$k; done; echo "  (only the running ones; every running VM clean first)"
  echo " r-undefine (uuid-guarded, overlay disk checked):"; for k in $NEW; do x $V undefine $(idf $k | cut -d' ' -f2); done
  echo " r-net:"; for k in $NEW; do x $V net-update default delete ip-dhcp-host "$(dhcp $k)" --live --config; done
  echo " r-unfreeze (base stat = freeze record first):"; x sudo -n chmod $mode $BASE; x sudo -n chown $own $BASE
  echo " r-define (dumpxml --inactive must equal the saved file):"; x $V define $src/before/cxl_vm0.inactive.xml; x $V define $src/before/cxl_vm1.inactive.xml
  echo " r-start (16 vCPU, MemTotal $MEM96_MIN-$MEM96_MAX kB, pins = before, node0 free >= 100000 MB, oom):"; x $V start cxl_vm0; x $V start cxl_vm1
  echo " pretouch-par 0 1 (as in the switch plan); envcheck (read-only)"
  echo " r-delete:"; for k in $ALL; do x sudo -n rm -f $D/cxl_vm$k.qcow2; done; x sudo -n rmdir $D; }
ph_dry() {
  local TE=${E:-"<VMN_E unset>"} o=$W/dry-n$N
  [ -z "$E" ] || test ! -e $E || fail "VMN_E $E exists (the switch needs a new evidence dir)"
  LIVE=0; rm -rf $o $o.gen.txt; mkdir -p $o/before $o/topo$N; E=$o SRCD=$o; LOGF=$o/dry.log
  if [ "$OFF" = 1 ]; then
    log "DRY start OFFLINE topo $N (no ssh, virsh, ping, sudo or Host state reads; before from $BEF; ids from ${IDS:-new})"
    prechecks_offline $o/before
  else
    log "DRY start topo $N (read-only; no sudo, no virsh writes, no guest writes; ids from ${IDS:-new})"
    prechecks $o/before
    [ -x /usr/bin/guestfish ] && [ -r /boot/vmlinuz ] || fail "guestfish/appliance kernel"
  fi
  gen $o/before $o/topo$N
  cat $o/topo$N.gen.txt
  [ "$(sha256sum $TOOL | cut -d' ' -f1)" = $TOOL_SHA ] || fail "pretouch tool hash"
  bash -n $0 || fail "syntax"
  plan_switch "$TE" $o/topo$N/ids.txt | tee $o/plan.txt
  if [ "$OFF" = 1 ]; then
    echo "$(csum) ids=${IDS:--} OFFLINE" > $o/DRY-OFFLINE
    log "DRY OFFLINE PASS (DRY-OFFLINE written; no live binding: run an online dry before the switch)"
  else
    echo "$(csum) ids=${IDS:--}" > $o/DRY-PASS
    log "DRY PASS (DRY-PASS written: chain $(cut -c1-12 $o/DRY-PASS) ...)"
  fi; }
ph_dry_restore() {
  LIVE=0; local o=$W/dry-restore-n$N k f u own mode fr
  rm -rf $o; mkdir -p $o; LOGF=$o/dry.log
  log "DRY-RESTORE start topo $N$([ "$OFF" = 1 ] && echo ' OFFLINE (no ssh, virsh, sudo or Host state reads)') (src=${S:-unset} e=${E:-unset})"
  [ -n "$S" ] && [ -n "$E" ] && [ "$S" != "$E" ] || fail "set VMN_SRC (switch evidence dir) and a different VMN_E (new restore dir)"
  case "$E" in $P/recovery/VM8-v*) ;; *) fail "VMN_E must be $P/recovery/VM8-v*";; esac
  test ! -e $E || fail "VMN_E $E exists"
  SRCD=$S
  fr=$S/freeze/stat-before.txt
  for f in before/cxl_vm0.inactive.xml before/cxl_vm1.inactive.xml before/net-default.xml before/cxl_vm0.vcpupin.txt \
           before/cxl_vm1.vcpupin.txt before/cxl_vm0.emulatorpin.txt before/cxl_vm1.emulatorpin.txt topo$N/ids.txt; do
    test -s $S/$f || fail "missing $S/$f"; done
  [ "$(wc -l < $S/topo$N/ids.txt)" = $N ] || fail "$S/topo$N/ids.txt does not have $N rows"
  grep -q "<source file='$BASE'/>" $S/before/cxl_vm0.inactive.xml && grep -q "<source file='$I/cxl_vm1.qcow2'/>" $S/before/cxl_vm1.inactive.xml || fail "before XML disks"
  if [ "$OFF" = 1 ]; then
    test -s $fr || { fr=$FREEZE_REC_OFFLINE; echo "NOTE: $S has no freeze record (offline source); owner/mode placeholder from $fr" | tee -a $LOGF; }
    read own mode _ < $fr
    log "OFFLINE: NOT checked: DEFINE PASS in steps.log, lock, build, chains, domain uuids/disks, guests, network entries, base stat, overlay dir"
  else
    test -s $fr && test -s $S/steps.log || fail "missing $S/freeze/stat-before.txt or steps.log"
    grep -q " DEFINE PASS" $S/steps.log || fail "$S has no DEFINE PASS"
    nobuild || fail "Host build running"
    test ! -e $P/workspaces/MEASUREMENT.lock || fail "MEASUREMENT.lock exists"
    nochain || fail "another deploy/run/chain is running: $NOCHAIN_HIT"
    [ "$(state cxl_vmx)" = "shut off" ] || fail "cxl_vmx not shut off"
    for k in $ALL; do
      u=$(idf $k | cut -d' ' -f2)
      [ "$($V domuuid cxl_vm$k 2>/dev/null)" = "$u" ] || fail "cxl_vm$k uuid != $S/topo$N/ids.txt"
      $V dumpxml --inactive cxl_vm$k | grep -c "<source file='$D/cxl_vm$k.qcow2'/>" > /dev/null || fail "cxl_vm$k disk is not its overlay"
    done
    for k in $(seq $N 7); do $V dominfo cxl_vm$k > /dev/null 2>&1 && fail "cxl_vm$k is defined (outside topology $N)"; done
    for k in $(running); do inN $k || fail "running cxl_vm$k outside topology $N"; [ "$(on $k uname -r)" = $K12 ] || fail "vm$k kernel"; guestclean $k || fail "vm$k not clean (cxl_shm/dax0.0/tool dir/dax users)"; done
    echo "running: $(running | tr '\n' ' ')" >> $LOGF
    $V net-dumpxml default | grep -c "ip='192.168.122.10[2-7]'" | grep -qx $((N - 2)) || fail "live network: not exactly $((N - 2)) DHCP entries"
    $V net-dumpxml --inactive default | grep -c "ip='192.168.122.10[2-7]'" | grep -qx $((N - 2)) || fail "--inactive network: not exactly $((N - 2)) DHCP entries"
    netdiff $o/net-diff.txt || fail "network minus the $((N - 2)) entries differs from $S/before/net-default.xml (see $o/net-diff.txt)"
    read own mode _ < $fr
    [ "$(stat -c '%U:%G %a' $BASE)" = "$own 444" ] || fail "base owner/mode is not '$own 444'"
    [ "$(basesz)" = "$(frozensz)" ] || fail "base size/mtime differ from the freeze record (base written: overlays invalid)"
    test -e $I/cxl_vm1.qcow2 || fail "cxl_vm1.qcow2 missing"
    [ "$(ls $D 2>/dev/null | tr '\n' ' ')" = "$(for k in $ALL; do echo -n "cxl_vm$k.qcow2 "; done)" ] || fail "$D does not hold exactly the $N overlays"
  fi
  [ "$(sha256sum $TOOL | cut -d' ' -f1)" = $TOOL_SHA ] || fail "pretouch tool hash"
  bash -n $0 || fail "syntax"
  plan_restore "$own" "$mode" "$S" "$E" | tee $o/plan.txt
  if [ "$OFF" = 1 ]; then
    echo "$(csum) src=$S e=$E OFFLINE" > $o/DRY-OFFLINE
    log "DRY-RESTORE OFFLINE PASS (DRY-OFFLINE written; no live binding)"
  else
    echo "$(csum) src=$S e=$E" > $o/DRY-PASS
    log "DRY-RESTORE PASS (DRY-PASS written: chain $(cut -c1-12 $o/DRY-PASS) ...)"
  fi; }

case "$PH" in
  dry) ph_dry ;; dry-restore) ph_dry_restore ;;
  nochain-check) if nochain; then echo "NOCHAIN clear"; else echo "NOCHAIN hit: $NOCHAIN_HIT"; exit 1; fi ;;   # read-only (pgrep/ps)
  pre) ph_pre ;; gen) ph_gen ;; down) ph_down ;; freeze) ph_freeze ;; overlays) ph_overlays ;; net) ph_net ;; define) ph_define ;;
  start) ph_start "$@" ;; stop) ph_stop "$@" ;; pretouch) ph_pretouch "$@" ;; pretouch-par) ph_pretouch_par "$@" ;; envcheck) ph_envcheck ;;
  r-down) ph_r_down ;; r-undefine) ph_r_undefine ;; r-net) ph_r_net ;; r-unfreeze) ph_r_unfreeze ;; r-define) ph_r_define ;;
  r-start) ph_r_start ;; r-delete) ph_r_delete ;;
  *) echo "usage: VMN_TOPO=4|8 $0 dry|dry-restore|pre|gen|down|freeze|overlays|net|define|start <ids>|stop <ids>|pretouch <id>|pretouch-par <ids>|envcheck|r-down|r-undefine|r-net|r-unfreeze|r-define|r-start|r-delete"; exit 2 ;;
esac

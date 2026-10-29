#!/bin/bash
# Standing-rule check (user 2026-10-17, state/TASKS.md grant F extension (2)): after every QEMU start and before any
# measurement, the whole /dev/dax0.0 of EACH VM must have been pre-touched (CXL_SWMC/scripts/guest/dax-pretouch.py run
# by an ENV-pretouch packet, reports/ENV-pretouch-packet.md). Read-only: Host ps/stat/pid files, guest sysfs over ssh.
# usage: pretouch-check-n.sh <ENV-pretouch evidence dir> <out file>   env: NODES (ips), VM_DOMAINS (libvirt names, same order)
# N-VM version of experiments/kv/pretouch-check.sh (verifier HIGH-1 2026-10-18). PASS needs, for every VM k:
#   - the dir is /home/comsys/sungsu/destijl-control/recovery/ENV-pretouch-v*; its steps.log has "T0 DONE" and "T1 DONE"
#     and no line containing "STOP" (a failed part, or the C confirmation over its readM threshold)
#   - <dir>/pretouch-vm<k>.txt has the exact line "PRETOUCH DONE pages=<N>", N = guest dax0.0 size / 4096 (read now)
#   - the QEMU process of cxl_vm<k> (pid from /run/libvirt/qemu/cxl_vm<k>.pid, cmdline "guest=cxl_vm<k>,") started
#     BEFORE the mtime of pretouch-vm<k>.txt (a QEMU restart voids the pretouch)
#   - the guest's namespace0.0 uuid (ndctl list, unprivileged) = PT_UUID (default f61e87a2-aaa7-41a7-94d9-5e74fe078049,
#     the devdax re-created 2026-10-17 18:47); an unreadable uuid is recorded as a NOTE, a different one is a FAIL
# Prints the facts and "PRETOUCH CHECK PASS" or "PRETOUCH CHECK FAIL: <reasons>" (all also into <out file>); exit 1 on FAIL.
set -uo pipefail
D=${1:?ENV-pretouch evidence dir} OUT=${2:?out file}
P=/home/comsys/sungsu/destijl-control
UUID=${PT_UUID:-3d40b5e0-dcaf-427f-bb9b-04fd6c8be26f}   # devdax restore v3 (2026-10-28); before: f61e87a2-aaa7-41a7-94d9-5e74fe078049 (2026-10-17)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
read -r -a IPS <<< "${NODES:-192.168.122.100 192.168.122.101}"; read -r -a DOMS <<< "${VM_DOMAINS:-cxl_vm0 cxl_vm1}"
[ ${#IPS[@]} = ${#DOMS[@]} ] || { echo "PRETOUCH CHECK FAIL: NODES and VM_DOMAINS differ in length" | tee "$OUT"; exit 1; }
fails=() lines=()
say() { lines+=("$*"); }
bad() { fails+=("$*"); say "FAIL $*"; }
D=$(cd "$D" 2>/dev/null && pwd) || { echo "PRETOUCH CHECK FAIL: no dir $1" | tee "$OUT"; exit 1; }
# Two evidence layouts: ENV-pretouch packets (steps.log T0/T1 DONE, no STOP line, pretouch-vm<k>.txt) and the VM8
# chain (recovery/VM8-v*: steps.log "PRETOUCH PASS vm<j>:" per VM, pretouch-vm<j>-<HHMMSS>.txt; its other STOP lines
# are chain steps, not pretouch failures). In the VM8 layout <j> = the libvirt domain's index (cxl_vm<j>), so any
# subset of the 8 VMs is checked by its own files.
case "$D" in
  $P/recovery/ENV-pretouch-v*) LAYOUT=env
    for t in "T0 DONE" "T1 DONE"; do grep -q " $t" "$D/steps.log" 2>/dev/null || bad "steps.log has no '$t'"; done
    grep -q "STOP" "$D/steps.log" 2>/dev/null && bad "steps.log has a STOP line: $(grep -m1 STOP "$D/steps.log")"
    say "c_done=$(grep -m1 ' C DONE' "$D/steps.log" 2>/dev/null || echo none)";;
  $P/recovery/VM8-v*) LAYOUT=vm8;;
  *) LAYOUT=none; bad "dir $D is neither $P/recovery/ENV-pretouch-v* nor $P/recovery/VM8-v*";;
esac
say "pretouch_dir=$D layout=$LAYOUT checked_at=$(date -Is)"
for k in "${!IPS[@]}"; do
  ip=${IPS[$k]} f=$D/pretouch-vm$k.txt
  if [ "$LAYOUT" = vm8 ]; then
    j=${DOMS[$k]#cxl_vm}
    f=$(ls -t "$D"/pretouch-vm$j-*.txt 2>/dev/null | head -1)
    [ -n "$f" ] || f=$D/pretouch-vm$j-MISSING.txt
    grep -q " PRETOUCH PASS vm$j:" "$D/steps.log" 2>/dev/null || bad "vm$k (${DOMS[$k]}): steps.log has no 'PRETOUCH PASS vm$j:'"
    say "vm$k domain=${DOMS[$k]} file=$f"
  fi
  sz=$($SSH comsys@$ip 'cat /sys/bus/dax/devices/dax0.0/size' < /dev/null 2>/dev/null)
  if [[ $sz =~ ^[0-9]+$ ]] && [ $((sz % 4096)) = 0 ]; then
    n=$((sz / 4096)); say "vm$k dax0.0_size=$sz pages=$n"
    grep -qx "PRETOUCH DONE pages=$n" "$f" 2>/dev/null || bad "vm$k: $f has no 'PRETOUCH DONE pages=$n'"
  else
    bad "vm$k: dax0.0 size unreadable ('$sz')"
  fi
  pid=$(cat /run/libvirt/qemu/${DOMS[$k]}.pid 2>/dev/null)
  if [[ $pid =~ ^[0-9]+$ ]] && tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q "guest=${DOMS[$k]},"; then
    st=$(date -d "$(ps -o lstart= -p "$pid")" +%s 2>/dev/null)
    mt=$(stat -c %Y "$f" 2>/dev/null)
    say "vm$k qemu_pid=$pid qemu_start=$(date -d @${st:-0} -Is) pretouch_mtime=$(date -d @${mt:-0} -Is)"
    [[ $st =~ ^[0-9]+$ ]] && [[ $mt =~ ^[0-9]+$ ]] && [ "$st" -lt "$mt" ] \
      || bad "vm$k: QEMU (pid $pid) started at/after the pretouch output ($st >= $mt): pretouch void, new pretouch needed"
  else
    bad "vm$k: no running QEMU for ${DOMS[$k]} (pid file '$pid')"
  fi
  u=$($SSH comsys@$ip 'ndctl list -n namespace0.0' < /dev/null 2>/dev/null | python3 -I -B -c 'import json,sys
try:
    j=json.load(sys.stdin); j=j[0] if isinstance(j,list) else j; print(j.get("uuid",""))
except Exception:
    print("")')
  if [ -z "$u" ]; then say "NOTE vm$k: namespace0.0 uuid unreadable unprivileged (recorded, not judged)"
  elif [ "$u" = "$UUID" ]; then say "vm$k namespace0.0_uuid=$u"
  else bad "vm$k: namespace0.0 uuid $u != $UUID"; fi
done
if [ ${#fails[@]} = 0 ]; then res="PRETOUCH CHECK PASS"; else res="PRETOUCH CHECK FAIL: ${fails[*]}"; fi
printf '%s\n' "${lines[@]}" "$res" | tee "$OUT"
[ ${#fails[@]} = 0 ]

#!/bin/bash
# Host CPU partition for H1 measurements (option (가), user decision 2026-10-18, state/TASKS.md; reports/H1-main-packet.md
# §env). It sits on top of scripts/host/measure-env.sh, which is NOT changed: frozen validation packets pin its sha256,
# and its record/apply/reapply/restore/check modes keep working as before.
# On top of the base apply (C1E/C6 off, irqbalance off, IRQs + unbound workqueues on HK, emulator pins), it moves:
#   - system.slice, user.slice, init.scope: AllowedCPUs SYS = 18-23,50-55 (Host daemons incl. libvirtd/sshd/journald,
#     every login session, agents, builds, PID 1). Before: HK = 18-31,50-63;
#   - new measure.slice: AllowedCPUs MEAS = 24-31,56-63 (loadgen only; started through scripts/host/measure-run.sh).
#     Runtime unit /run/systemd/system/measure.slice: gone after a reboot, nothing persistent.
#   machine.slice (the VMs; vCPUs on node0, emulator threads 16,48 / 17,49 by emulatorpin) is not touched.
#   IRQs and the unbound-workqueue mask stay on HK as in the base apply (kernel work, not schedulable tasks).
# usage (root for record/apply/restore; check needs no root):
#   measure-env-part.sh record  <part record dir (new, empty)>              save slice state + measure.slice state
#   measure-env-part.sh apply   <base state dir> <part record dir> <new apply dir>
#        the base apply must be in place (measure-env.sh check <base> PASS) -> partition -> check; logs/sets in the
#        apply dir (recovery dirs are never rewritten: each apply/reapply uses a new dir)
#   measure-env-part.sh check   <base state dir> <apply dir>               exit 0 + "PART CHECK PASS" only if the
#        base apply is in place except the slice CPU sets, the slices are on SYS and measure.slice is active on MEAS
#   measure-env-part.sh restore <base state dir> <part record dir> <new log dir>
#        slices back to the recorded values (the base apply's HK), measure.slice stopped and its runtime unit removed
#        (if it did not exist at record), then measure-env.sh check <base> must PASS again. The full return to the
#        pre-measurement Host is the existing `measure-env.sh restore <base>` afterwards.
# After a VM restart: measure-env.sh reapply (resets the slices to HK), then apply again into a new apply dir.
set -uo pipefail
CMD=${1:?record|apply|check|restore}
H=$(cd "$(dirname "$0")" && pwd) ME=$(cd "$(dirname "$0")" && pwd)/measure-env.sh
SYS=18-23,50-55 MEAS=24-31,56-63 SLICES=(system.slice user.slice init.scope) UNIT=/run/systemd/system/measure.slice
# emulator CPU sets and HK come from measure-env.sh (one source of truth)
eval "$(grep -m1 '^EMU_cxl_vm0=' "$ME")"
EMU="${EMU_cxl_vm0:?},${EMU_cxl_vm1:?}"
[ "$CMD" = check ] || [ "$(id -u)" = 0 ] || { echo "run as root ($CMD)"; exit 2; }
cpus() { systemctl show -p AllowedCPUs --value "$1" | tr ' ' ','; }
sstate() { for s in "${SLICES[@]}"; do echo "$s $(cpus $s)"; done; }
mstate() { echo "measure.slice load=$(systemctl show -p LoadState --value measure.slice) active=$(systemctl show -p ActiveState --value measure.slice) cpus=$(cpus measure.slice) unit_file=$([ -e $UNIT ] && echo yes || echo no)"; }
case $CMD in
  record)
    P=${2:?part record dir}; mkdir -p "$P"; [ -z "$(ls -A "$P")" ] || { echo "$P not empty"; exit 2; }
    sstate > "$P/slices.txt"; mstate > "$P/measure-slice.txt"; date -Is > "$P/recorded-at.txt"; echo "PART RECORDED $P";;
  apply)
    B=${2:?base state dir} P=${3:?part record dir} A=${4:?new apply dir}
    [ -s "$P/slices.txt" ] || { echo "no part record in $P"; exit 2; }
    mkdir -p "$A"; [ -z "$(ls -A "$A")" ] || { echo "$A not empty"; exit 2; }
    bash "$ME" check "$B" > "$A/base-check-before.txt" 2>&1 || { echo "PART APPLY REFUSED: base apply not in place (see $A/base-check-before.txt)"; exit 1; }
    { echo "[Unit]"; echo "Description=H1 measurement CPUs (runtime, scripts/host/measure-env-part.sh)"
      echo "[Slice]"; echo "AllowedCPUs=$MEAS"; } > "$UNIT"
    systemctl daemon-reload && systemctl start measure.slice && systemctl set-property --runtime measure.slice AllowedCPUs=$MEAS \
      || { echo "PART APPLY FAIL: measure.slice"; exit 1; }
    for s in "${SLICES[@]}"; do systemctl set-property --runtime $s AllowedCPUs=$SYS || { echo "PART APPLY FAIL: $s"; exit 1; }; done
    { echo "sys=$SYS"; echo "meas=$MEAS"; echo "emu=$EMU"; echo "base=$B"; echo "record=$P"; } > "$A/sets.txt"
    date -Is > "$A/applied-at.txt"; sstate > "$A/slices-after.txt"; mstate > "$A/measure-slice-after.txt"
    bash "$0" check "$B" "$A" | tee "$A/check-after.txt"; exit "${PIPESTATUS[0]}";;
  check)
    B=${2:?base state dir} A=${3:?apply dir}; rc=0
    [ -s "$A/sets.txt" ] && grep -qx "sys=$SYS" "$A/sets.txt" && grep -qx "meas=$MEAS" "$A/sets.txt" && grep -qx "emu=$EMU" "$A/sets.txt" \
      || { echo "PART CHECK FAIL: sets.txt in $A missing or different from sys=$SYS meas=$MEAS emu=$EMU"; rc=1; }
    out=$(bash "$ME" check "$B" 2>&1); brc=$?
    # every base check except the three slice CPU sets (those are intentionally different here)
    other=$(printf '%s\n' "$out" | grep '^CHECK FAIL' | grep -vE '^CHECK FAIL: (system\.slice|user\.slice|init\.scope) AllowedCPUs$')
    [ -z "$other" ] || { printf '%s\n' "$other" | sed 's/^/PART CHECK FAIL (base): /'; rc=1; }
    # a non-zero base exit status must be explained by slice lines only (verifier LOW-2: an aborted base check is a FAIL)
    if [ $brc != 0 ] && ! printf '%s\n' "$out" | grep -qE '^CHECK FAIL: (system\.slice|user\.slice|init\.scope) AllowedCPUs$'; then
      echo "PART CHECK FAIL (base): measure-env.sh check exit $brc without a CHECK FAIL slice line: $(printf '%s' "$out" | tail -n 1)"; rc=1
    fi
    for s in "${SLICES[@]}"; do [ "$(cpus $s)" = "$SYS" ] || { echo "PART CHECK FAIL: $s AllowedCPUs=$(cpus $s) (want $SYS)"; rc=1; }; done
    [ "$(systemctl show -p ActiveState --value measure.slice)" = active ] || { echo "PART CHECK FAIL: measure.slice not active"; rc=1; }
    [ "$(cpus measure.slice)" = "$MEAS" ] || { echo "PART CHECK FAIL: measure.slice AllowedCPUs=$(cpus measure.slice) (want $MEAS)"; rc=1; }
    [ $rc = 0 ] && echo "PART CHECK PASS (sys=$SYS meas=$MEAS emu=$EMU)"; exit $rc;;
  restore)
    B=${2:?base state dir} P=${3:?part record dir} O=${4:?new log dir}
    [ -s "$P/slices.txt" ] || { echo "no part record in $P"; exit 2; }
    mkdir -p "$O"; [ -z "$(ls -A "$O")" ] || { echo "$O not empty"; exit 2; }
    while read -r s c; do
      if [ -z "$c" ]; then systemctl set-property --runtime "$s" AllowedCPUs= ; else systemctl set-property --runtime "$s" "AllowedCPUs=$c"; fi
    done < "$P/slices.txt"
    if grep -q " unit_file=no$" "$P/measure-slice.txt"; then
      systemctl stop measure.slice 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload
    fi
    sstate > "$O/slices-after.txt"; mstate > "$O/measure-slice-after.txt"
    rc=0; diff -q "$P/slices.txt" "$O/slices-after.txt" > /dev/null || { echo "PART RESTORE DIFF slices"; rc=1; }
    bash "$ME" check "$B" > "$O/base-check-after.txt" 2>&1 || { echo "PART RESTORE: base check not PASS (see $O/base-check-after.txt)"; rc=1; }
    [ $rc = 0 ] && echo "PART RESTORED (slices as recorded, measure.slice $(systemctl show -p ActiveState --value measure.slice))"; exit $rc;;
  *) echo "usage: $0 record|apply|check|restore ..."; exit 2;;
esac

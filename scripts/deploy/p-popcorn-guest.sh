#!/bin/bash
# Popcorn guest control (runs ON a guest, as root via `sudo -n`; grant-gated).
#   p-popcorn-guest.sh load <node_id> <invalid|shared> [name=value ...] | wait-link <sec> | enable <sec> | status
#                      | disable | unload
#                      | instr <0|1> | instr-dump
# Expected values come from popcorn.env next to this script (frozen in the
# packet): K (kernel release), KO_SHA (sha256 of the installed, signed
# cxl_shm.ko; optional KO_PATH: load that file instead of
# /lib/modules/$K/updates/cxl_shm.ko, e.g. a module-only variant shipped in
# the tools dir), PARAMS (cxl_shm parameters except node_id, = `faultlat params`
# for the region config, with init_state=invalid; `load` substitutes the
# requested init_state), MANAGED_BASE_OFF/MANAGED_BYTES. Every step stops
# (exit != 0) on the first unexpected result and changes nothing more.
#   load      checks release, module not loaded, nobody has /dev/dax0.0 open
#             or mapped, params recomputed from the region config == PARAMS,
#             module hash; then insmod.  Optional name=value arguments add
#             receive-path parameters (only recv_mode, max_workers,
#             worker_spin_us, fallback_us, starve_us; checked after the load
#             in /sys/module/cxl_shm/parameters) (initializes only this node's ring lines
#             at msg_ring, registers the swcc range; no SWcc write)
#   wait-link waits until the link to the peer is up (cxl_shm counters)
#   enable    syscall 470 (enable_page_coherence), retried while EAGAIN;
#             checks the managed range reported by the kernel. With
#             INIT_STATE=shared the first enable blocks in the cross-node
#             barrier until every node enables (run them in parallel).
#   disable   syscall 471 (fails with EBUSY while managed mappings exist)
#   unload    rmmod cxl_shm (writes back this node's S/M pages, withdraws its
#             ring identity; refused while managed mappings exist)
#   instr     (build >= 8) set the measurement-only instrumentation static key
#             (/sys/kernel/swmc/instr/enabled); no protocol effect
#   instr-dump  (build >= 8) every instr file as "<dir>.<file>.<name> <value>"
set -euo pipefail
H=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
. "$H/popcorn.env"
: "${K:?}" "${KO_SHA:?}" "${PARAMS:?}" "${MANAGED_BASE_OFF:?}" "${MANAGED_BYTES:?}"
KO=${KO_PATH:-/lib/modules/$K/updates/cxl_shm.ko}
SYS=/sys/kernel/swmc/page_coherence
CS=/sys/kernel/cxl_shm
test "$(id -u)" -eq 0 || { echo "STOP: must run as root"; exit 1; }
test "$(uname -r)" = "$K" || { echo "STOP: running $(uname -r), expected $K"; exit 1; }
loaded() { grep -q '^cxl_shm ' /proc/modules; }
syscall() {  # syscall <nr>: prints rc and errno name
  python3 -I -c 'import ctypes,errno,sys
l=ctypes.CDLL(None,use_errno=True); r=l.syscall(int(sys.argv[1])); e=ctypes.get_errno()
print(r, errno.errorcode.get(e,"0") if r else "OK")' "$1"
}
dax_users() {  # processes with /dev/dax0.0 open or mapped
  python3 -I -c 'import os
for p in os.listdir("/proc"):
    if not p.isdigit(): continue
    try:
        hit = any(os.readlink(f"/proc/{p}/fd/{f}") == "/dev/dax0.0" for f in os.listdir(f"/proc/{p}/fd"))
        hit = hit or "/dev/dax0.0" in open(f"/proc/{p}/maps").read()
    except OSError:
        continue
    if hit: print(p, open(f"/proc/{p}/comm").read().strip())'
}
links_up() { echo $(( $(cat $CS/link_up) - $(cat $CS/link_down) )); }

case "${1:-}" in
load)
  id=${2:?node_id}; mode=${3:?init_state}; shift 3
  extra=()
  for a in "$@"; do
    [[ "$a" =~ ^(recv_mode|max_workers|worker_spin_us|fallback_us|starve_us)=[a-z0-9]+$ ]] ||
      { echo "STOP: extra parameter '$a' not allowed"; exit 1; }
    extra+=("$a")
  done
  [[ "$id" =~ ^[0-9]$ ]] || { echo "STOP: bad node_id"; exit 1; }
  [[ "$mode" =~ ^(invalid|shared)$ ]] || { echo "STOP: bad init_state"; exit 1; }
  [[ "$PARAMS" == *" init_state=invalid" ]] || { echo "STOP: frozen PARAMS lack init_state=invalid"; exit 1; }
  want="${PARAMS% init_state=invalid} init_state=$mode"
  ! loaded || { echo "STOP: cxl_shm already loaded"; exit 1; }
  u=$(dax_users); [ -z "$u" ] || { echo "STOP: /dev/dax0.0 in use: $u"; exit 1; }
  p=$(CXL_REGION_CONFIG=$H/cxl_region.yaml "$H/faultlat" params --init-state "$mode")
  [ "$p" = "$want" ] || { echo "STOP: params from region config differ: '$p' vs '$want'"; exit 1; }
  [ "$(sha256sum "$KO" | cut -d' ' -f1)" = "$KO_SHA" ] || { echo "STOP: $KO hash differs"; exit 1; }
  [ "$(modinfo -F vermagic "$KO" | cut -d' ' -f1)" = "$K" ] || { echo "STOP: vermagic"; exit 1; }
  # shellcheck disable=SC2086
  insmod "$KO" node_id="$id" $want "${extra[@]}"
  loaded || { echo "STOP: cxl_shm not loaded after insmod"; exit 1; }
  for f in dax_name nr_nodes node_id ring_offset ring_size ring_coherent managed_offset managed_size init_state recv_mode \
           max_workers worker_spin_us fallback_us starve_us; do
    [ -r /sys/module/cxl_shm/parameters/$f ] && echo "$f=$(cat /sys/module/cxl_shm/parameters/$f)"
  done
  for a in "${extra[@]}"; do
    [ "$(cat "/sys/module/cxl_shm/parameters/${a%%=*}" 2>/dev/null)" = "${a#*=}" ] ||
      { echo "STOP: parameter ${a%%=*} is not ${a#*=} after the load"; exit 1; }
  done
  echo "version=$(cat /sys/module/cxl_shm/version 2>/dev/null)"
  dmesg | grep -E 'shm_cxl|swmc-popcorn|swmc_kmsg' | tail -n 8
  echo "load OK (node $id)" ;;
wait-link)
  t=${2:?seconds}
  loaded || { echo "STOP: cxl_shm not loaded"; exit 1; }
  for ((i = 0; i < t * 10; i++)); do
    [ "$(links_up)" -ge 1 ] && { dmesg | grep 'shm_cxl: link to node' | tail -n 2; echo "link OK"; exit 0; }
    sleep 0.1
  done
  dmesg | grep -E 'shm_cxl' | tail -n 5
  echo "STOP: link not up after $t s"; exit 1 ;;
enable)
  t=${2:?seconds}
  loaded || { echo "STOP: cxl_shm not loaded"; exit 1; }
  for ((i = 0; i < t * 10; i++)); do
    read -r rc en < <(syscall 470)
    [ "$rc" = 0 ] && break
    [ "$en" = EAGAIN ] || { echo "STOP: enable_page_coherence: $en"; exit 1; }
    sleep 0.1
  done
  [ "$rc" = 0 ] || { echo "STOP: enable still EAGAIN after $t s"; exit 1; }
  base=$(cat $SYS/managed_base); bytes=$(cat $SYS/managed_bytes)
  start=$(python3 -I -c 'import sys; print(hex(int(open("/sys/bus/dax/devices/dax0.0/resource").read(),0)+int(sys.argv[1])))' "$MANAGED_BASE_OFF")
  [ "$base" = "$start" ] && [ "$bytes" = "$MANAGED_BYTES" ] ||
    { echo "STOP: managed range $base +$bytes, expected $start +$MANAGED_BYTES"; exit 1; }
  is=$(cat $SYS/init_state)
  case "$(cat /sys/module/cxl_shm/parameters/init_state)" in
    shared) [ "$is" = "shared (initialized)" ] || { echo "STOP: init_state '$is'"; exit 1; } ;;
    *) [ "$is" = invalid ] || { echo "STOP: init_state '$is'"; exit 1; } ;;
  esac
  echo "protocol=$(cat $SYS/protocol) managed_base=$base managed_bytes=$bytes init_state=$is"
  dmesg | grep 'swmc-popcorn' | tail -n 3
  echo "enable OK" ;;
status)
  echo "release=$(uname -r) loaded=$(grep -c '^cxl_shm ' /proc/modules)"
  if loaded; then
    for f in /sys/module/cxl_shm/parameters/*; do echo "param.$(basename "$f")=$(cat "$f")"; done
    for f in $CS/*; do [ -f "$f" ] || continue; echo "cxl_shm.$(basename "$f")=$(cat "$f")"; done
  fi
  for f in $SYS/*; do [ "$(basename "$f")" = reset_counters ] || echo "swmc.$(basename "$f")=$(cat "$f")"; done
  [ -r /sys/kernel/swmc/instr/enabled ] && echo "instr_enabled=$(cat /sys/kernel/swmc/instr/enabled)"
  echo "inline_dispatch=$(cat /sys/module/swmc_kmsg/parameters/inline_dispatch)"
  for p in $(pgrep -x 'cxl_recv_[0-9]' || true); do  # coherence CPU: receive thread utime+stime (clock ticks)
    awk -v hz="$(getconf CLK_TCK)" '{print "recv_thread." $2 "=" $14 + $15 " ticks (" hz "/s)"}' "/proc/$p/stat"
  done
  echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
  echo "dmesg_bad=$(dmesg | grep -cE 'BUG:|Oops|WARNING:|Call Trace' || true)"
  echo "dax_users=$(dax_users | tr '\n' ';')"
  echo "dax0.0=$(stat -c '%U:%G %a' /dev/dax0.0)"
  dmesg | grep -E 'shm_cxl|swmc-popcorn|swmc_kmsg|dax:' | tail -n 20 | sed 's/^/dmesg: /' ;;
disable)
  read -r rc en < <(syscall 471)
  [ "$rc" = 0 ] || { echo "STOP: disable_page_coherence: $en"; exit 1; }
  echo "disable OK" ;;
unload)
  loaded || { echo "cxl_shm not loaded"; exit 0; }
  rmmod cxl_shm
  if loaded; then echo "STOP: cxl_shm still loaded"; exit 1; fi
  dmesg | grep -E 'shm_cxl|swmc-popcorn' | tail -n 4
  echo "unload OK" ;;
instr)
  v=${2:?0|1}; [[ "$v" =~ ^[01]$ ]] || { echo "STOP: instr 0|1"; exit 1; }
  f=/sys/kernel/swmc/instr/enabled
  test -w "$f" || { echo "STOP: no $f (kernel without instrumentation)"; exit 1; }
  echo "$v" > "$f"
  [ "$(cat "$f")" = "$v" ] || { echo "STOP: $f reads $(cat "$f")"; exit 1; }
  echo "instr OK (enabled=$v)" ;;
instr-dump)
  for d in /sys/kernel/swmc/instr /sys/kernel/cxl_shm/instr; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      case "$(basename "$f")" in reset) continue ;; esac
      [ -r "$f" ] || continue
      sed "s|^|$(basename "$(dirname "$d")").$(basename "$f").|" "$f"
    done
  done ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac

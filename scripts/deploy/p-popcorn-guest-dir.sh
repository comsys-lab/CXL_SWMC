#!/bin/bash
# Popcorn guest control (runs ON a guest, as root via `sudo -n`; grant-gated).
#   p-popcorn-guest.sh load <node_id> <invalid|shared> [nodes=N] [name=value ...] | wait-link <sec> | enable <sec> | status
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
#             at msg_ring, registers the swcc range; no SWcc write).
#             N nodes (popcorn-n): `nodes=N` (2..8) selects the frozen PARAMS_N<N>
#             from popcorn.env (falls back to PARAMS when N equals its nr_nodes);
#             without it PARAMS is used as before. The region-config check runs
#             `faultlat params --nodes <nr_nodes of the selected PARAMS>`.
#             Popcorn build 14 (p-popcorn-guest-dir.sh = this script + the directory rule; experiment
#             popcorn-directory-reference): extra parameters also directory=none|flat and dir_offset=<bytes>
#             (both read back after the load); directory=flat needs init_state=shared and dir_offset ==
#             DIR_OFFSET of popcorn.env. Region config = config/cxl_region-popcorn-dir.yaml: `faultlat params`
#             reports its msg_ring [RO, RO + RS) as the ring, while the frozen PARAMS carry the real ring =
#             the last RING_SIZE bytes of it; the check therefore requires ring_offset + ring_size == RO + RS,
#             DIR_OFFSET >= RO, DIR_OFFSET + DIR_BYTES == ring_offset (DIR_BYTES = 4096 + PAGE_ALIGN(4 x
#             managed pages)) and everything else of the recomputed params == PARAMS.
#   wait-link waits until the links to all nr_nodes-1 peers are up (cxl_shm counters)
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
: "${K:?}" "${KO_SHA:?}" "${PARAMS:?}" "${MANAGED_BASE_OFF:?}" "${MANAGED_BYTES:?}" "${LOAD_DEFAULTS:?}"
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
  extra=() reqn=
  for a in "$@"; do
    if [[ "$a" =~ ^nodes=([2-8])$ ]]; then reqn=${BASH_REMATCH[1]}; continue; fi
    [[ "$a" =~ ^(recv_mode|max_workers|worker_spin_us|fallback_us|starve_us)=[a-z0-9]+$ ]] ||
      [[ "$a" =~ ^directory=(none|flat)$ ]] || [[ "$a" =~ ^dir_offset=[0-9]+$ ]] ||
      { echo "STOP: extra parameter '$a' not allowed"; exit 1; }
    extra+=("$a")
  done
  : "${DIR_OFFSET:?popcorn.env DIR_OFFSET}" "${DIR_BYTES:?popcorn.env DIR_BYTES}"
  dmode= doff=
  for a in "${extra[@]}"; do case $a in directory=*) dmode=${a#*=};; dir_offset=*) doff=${a#*=};; esac; done
  # explicit only: a load without directory= is refused (no silent broadcast run on the directory bundle)
  [ -n "$dmode" ] || { echo "STOP: build-14 bundle: pass directory=none|flat (popcorn.env LOAD_DEFAULTS='$LOAD_DEFAULTS')"; exit 1; }
  if [ "$dmode" = flat ]; then
    [ "$mode" = shared ] || { echo "STOP: directory=flat needs init_state=shared"; exit 1; }
    [ "$doff" = "$DIR_OFFSET" ] || { echo "STOP: directory=flat needs dir_offset=$DIR_OFFSET (got '${doff:-none}')"; exit 1; }
  fi
  [ "$(( 4096 + (MANAGED_BYTES / 4096 * 4 + 4095) / 4096 * 4096 ))" = "$DIR_BYTES" ] || { echo "STOP: DIR_BYTES $DIR_BYTES != 4096 + PAGE_ALIGN(4 x managed pages)"; exit 1; }
  [[ "$id" =~ ^[0-9]$ ]] || { echo "STOP: bad node_id"; exit 1; }
  [[ "$mode" =~ ^(invalid|shared)$ ]] || { echo "STOP: bad init_state"; exit 1; }
  sel=$PARAMS
  if [ -n "$reqn" ]; then
    v=PARAMS_N$reqn
    if [ -n "${!v:-}" ]; then sel=${!v}
    elif [[ " $PARAMS " != *" nr_nodes=$reqn "* ]]; then echo "STOP: popcorn.env has no $v (nodes=$reqn)"; exit 1; fi
  fi
  [[ "$sel" =~ (^| )nr_nodes=([2-8])( |$) ]] || { echo "STOP: frozen PARAMS lack nr_nodes=2..8"; exit 1; }
  nr=${BASH_REMATCH[2]}
  [ -z "$reqn" ] || [ "$nr" = "$reqn" ] || { echo "STOP: selected PARAMS have nr_nodes=$nr, requested $reqn"; exit 1; }
  [ "$id" -lt "$nr" ] || { echo "STOP: node_id $id >= nr_nodes $nr"; exit 1; }
  [[ "$sel" == *" init_state=invalid" ]] || { echo "STOP: frozen PARAMS lack init_state=invalid"; exit 1; }
  want="${sel% init_state=invalid} init_state=$mode"
  ! loaded || { echo "STOP: cxl_shm already loaded"; exit 1; }
  u=$(dax_users); [ -z "$u" ] || { echo "STOP: /dev/dax0.0 in use: $u"; exit 1; }
  p=$(CXL_REGION_CONFIG=$H/cxl_region.yaml "$H/faultlat" params --nodes "$nr" --init-state "$mode")
  # region msg_ring [mro, mro + mrs) = margin + directory + ring (header above); want carries the real ring
  mro=$(sed -n 's/.* ring_offset=\([0-9]*\) .*/\1/p' <<< " $p ") mrs=$(sed -n 's/.* ring_size=\([0-9]*\) .*/\1/p' <<< " $p ")
  ro=$(sed -n 's/.* ring_offset=\([0-9]*\) .*/\1/p' <<< " $want ") rs=$(sed -n 's/.* ring_size=\([0-9]*\) .*/\1/p' <<< " $want ")
  [ -n "$mro" ] && [ -n "$ro" ] && [ $((ro + rs)) = $((mro + mrs)) ] && [ "$DIR_OFFSET" -ge "$mro" ] && [ $((DIR_OFFSET + DIR_BYTES)) = "$ro" ] ||
    { echo "STOP: region msg_ring [$mro,+$mrs) does not hold directory [$DIR_OFFSET,+$DIR_BYTES) + ring [$ro,+$rs) at its tail"; exit 1; }
  p=${p/ ring_offset=$mro ring_size=$mrs / ring_offset=$ro ring_size=$rs }
  [ "$p" = "$want" ] || { echo "STOP: params from region config differ: '$p' vs '$want'"; exit 1; }
  [ "$(sha256sum "$KO" | cut -d' ' -f1)" = "$KO_SHA" ] || { echo "STOP: $KO hash differs"; exit 1; }
  [ "$(modinfo -F vermagic "$KO" | cut -d' ' -f1)" = "$K" ] || { echo "STOP: vermagic"; exit 1; }
  # shellcheck disable=SC2086
  insmod "$KO" node_id="$id" $want "${extra[@]}"
  loaded || { echo "STOP: cxl_shm not loaded after insmod"; exit 1; }
  for f in dax_name nr_nodes node_id ring_offset ring_size ring_coherent managed_offset managed_size init_state recv_mode \
           max_workers worker_spin_us fallback_us starve_us directory dir_offset; do
    [ -r /sys/module/cxl_shm/parameters/$f ] && echo "$f=$(cat /sys/module/cxl_shm/parameters/$f)"
  done
  for a in "${extra[@]}"; do
    [ "$(cat "/sys/module/cxl_shm/parameters/${a%%=*}" 2>/dev/null)" = "${a#*=}" ] ||
      { echo "STOP: parameter ${a%%=*} is not ${a#*=} after the load"; exit 1; }
  done
  echo "version=$(cat /sys/module/cxl_shm/version 2>/dev/null)"
  dmesg | grep -E 'shm_cxl|swmc-popcorn|swmc_kmsg' | tail -n 8
  echo "load_nodes=$nr"
  echo "load OK (node $id)" ;;
wait-link)
  t=${2:?seconds}
  loaded || { echo "STOP: cxl_shm not loaded"; exit 1; }
  need=$(( $(cat /sys/module/cxl_shm/parameters/nr_nodes) - 1 ))
  [ "$need" -ge 1 ] || { echo "STOP: nr_nodes parameter unreadable"; exit 1; }
  for ((i = 0; i < t * 10; i++)); do
    [ "$(links_up)" -ge "$need" ] &&
      { dmesg | grep 'shm_cxl: link to node' | tail -n "$((need + 1))"; echo "link OK ($(links_up)/$need peers up)"; exit 0; }
    sleep 0.1
  done
  dmesg | grep -E 'shm_cxl' | tail -n $((need + 4))
  echo "STOP: links up $(links_up) of $need after $t s"; exit 1 ;;
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

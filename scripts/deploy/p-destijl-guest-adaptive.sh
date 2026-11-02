#!/bin/bash
# Adaptive-receiver variant (cxl_shm 13.2+, De Stijl build 9 on): p-destijl-bundle.sh --build 9 installs this file as
# tools/p-destijl-guest.sh. Differences from p-destijl-guest.sh (kept unchanged for the build 7/8 guest tools):
# `load` also accepts recv_mode=adaptive and fault_poll=0|1; destijl.env LOAD_DEFAULTS (required, "fault_poll=0"
# for build 9) is applied unless the caller passes the same name, and checked after the load like any extra.
# De Stijl v2 guest control (runs ON a guest, as root via `sudo -n`; inside an experiment approval). Same structure
# and sudo surface as p-popcorn-guest.sh (insmod/rmmod cxl_shm, syscalls 470/471, instr/enabled), for cxl_shm v13
# protocol=destijl (reports/design/DS2-protocol-spec.md §9; module README top block).
#   p-destijl-guest.sh load <node_id> <invalid|shared> [nodes=N] [name=value ...] | wait-state <sec> | enable <sec>
#                      | status | disable | unload | instr <0|1> | instr-dump | replica-mode <off|all>
#                      | replica-check <ds-replica-check.sh args> (replica_mode file / page_digest replica check)
# Expected values come from destijl.env next to this script (frozen in the bundle): K (kernel release, -ds-destijl-<n>),
# KO_SHA (sha256 of the installed cxl_shm.ko v13; optional KO_PATH: load that file instead of
# /lib/modules/$K/updates/cxl_shm.ko), PARAMS (cxl_shm parameters except node_id = `faultlat params --protocol destijl
# --nodes 2` for the region config cxl_region.yaml next to this script, with init_state=invalid; `load` substitutes the
# requested init_state), PARAMS_N<N> for N > 2 (same, --nodes N), MANAGED_BASE_OFF / MANAGED_BYTES. Every step stops
# (exit != 0) on the first unexpected result and changes nothing more.
#   load       checks release, module not loaded, nobody has /dev/dax0.0 open or mapped, params recomputed from the
#              region config == the frozen PARAMS (protocol=destijl, bpd_sets, ring_slots included), module hash and
#              vermagic; then insmod. Node 0 formats the De Stijl block (header, HPD/BPD, rings; init_state=shared puts
#              every HPD sharers = all nodes); the others validate its header. Optional name=value arguments: only
#              recv_mode (poll|sleep|adaptive), fault_poll (0|1), recv_cpu, tick_cpu, fetch_budget, idle_spin_us,
#              idle_sleep_us (+ LOAD_DEFAULTS for names not given); checked after the
#              load in /sys/module/cxl_shm/parameters. `nodes=N` (2..8) selects PARAMS_N<N> (as p-popcorn-guest.sh).
#   wait-state waits until /sys/kernel/cxl_shm/state is `running` (node barrier done, managed range registered,
#              ds_register called; set by the receive thread, insmod does not block); stops at once on `mismatch`
#   enable     syscall 470 (enable_page_coherence), retried while EAGAIN; checks the managed range reported by the
#              kernel and /sys/kernel/swmc/page_coherence/protocol == destijl
#   disable    syscall 471 (EBUSY while managed mappings exist)
#   unload     rmmod cxl_shm (refused while managed mappings exist)
#   instr      set /sys/kernel/swmc/instr/enabled (measurement-only instrumentation, if the kernel has it)
#   instr-dump every instr file as "<dir>.<file>.<name> <value>"
#   status     release, module parameters, /sys/kernel/cxl_shm/* (state, layout, ring/rx counters; multi-line files
#              as "cxl_shm.<file>: <line>"), /sys/kernel/swmc/page_coherence/*, /sys/kernel/swmc/destijl/* counters,
#              receive-thread CPU, dax users, dax0.0 owner, dmesg tail
set -euo pipefail
H=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
. "$H/destijl.env"
: "${K:?}" "${KO_SHA:?}" "${PARAMS:?}" "${MANAGED_BASE_OFF:?}" "${MANAGED_BYTES:?}" "${LOAD_DEFAULTS?}"
EXTRA_RE='^(recv_mode=(poll|sleep|adaptive)|fault_poll=[01]|(recv_cpu|tick_cpu)=-?[0-9]+|(fetch_budget|idle_spin_us|idle_sleep_us)=[0-9]+)$'
KO=${KO_PATH:-/lib/modules/$K/updates/cxl_shm.ko}
SYS=/sys/kernel/swmc/page_coherence
DS=/sys/kernel/swmc/destijl
CS=/sys/kernel/cxl_shm
STATE_READY=running   # cxl_shm v13 README: state after the barrier + swmc_register_region + ds_register
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
# cxl_shm v13 state file: "<state> registered <0|1>" (state_show); the first word is the state
state() { local s; s=$(cat $CS/state 2>/dev/null) || s=absent; echo "${s%% *}"; }
dump_dir() {  # dump_dir <dir> <prefix>: one-line files as prefix.name=value, multi-line as "prefix.name: line"
  local f n
  for f in "$1"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    n=$(basename "$f"); case $n in reset_counters|reset) continue ;; esac
    if [ "$(wc -l < "$f")" -le 1 ]; then echo "$2.$n=$(cat "$f")"; else sed "s|^|$2.$n: |" "$f"; fi
  done
}

case "${1:-}" in
load)
  id=${2:?node_id}; mode=${3:?init_state}; shift 3
  extra=() reqn=
  for a in "$@"; do
    if [[ "$a" =~ ^nodes=([2-8])$ ]]; then reqn=${BASH_REMATCH[1]}; continue; fi
    [[ "$a" =~ $EXTRA_RE ]] || { echo "STOP: extra parameter '$a' not allowed"; exit 1; }
    for e in "${extra[@]}"; do [ "${e%%=*}" != "${a%%=*}" ] || { echo "STOP: parameter ${a%%=*} given twice"; exit 1; }; done
    extra+=("$a")
  done
  for a in $LOAD_DEFAULTS; do   # frozen defaults (destijl.env), unless the caller set the same parameter
    [[ "$a" =~ $EXTRA_RE ]] || { echo "STOP: destijl.env LOAD_DEFAULTS entry '$a' not allowed"; exit 1; }
    d=1; for e in "${extra[@]}"; do [ "${e%%=*}" != "${a%%=*}" ] || d=0; done
    [ $d = 0 ] || extra+=("$a")
  done
  [[ "$id" =~ ^[0-9]$ ]] || { echo "STOP: bad node_id"; exit 1; }
  [[ "$mode" =~ ^(invalid|shared)$ ]] || { echo "STOP: bad init_state"; exit 1; }
  sel=$PARAMS
  if [ -n "$reqn" ]; then
    v=PARAMS_N$reqn
    if [ -n "${!v:-}" ]; then sel=${!v}
    elif [[ " $PARAMS " != *" nr_nodes=$reqn "* ]]; then echo "STOP: destijl.env has no $v (nodes=$reqn)"; exit 1; fi
  fi
  [[ "$sel" =~ (^| )nr_nodes=([2-8])( |$) ]] || { echo "STOP: frozen PARAMS lack nr_nodes=2..8"; exit 1; }
  nr=${BASH_REMATCH[2]}
  [ -z "$reqn" ] || [ "$nr" = "$reqn" ] || { echo "STOP: selected PARAMS have nr_nodes=$nr, requested $reqn"; exit 1; }
  [ "$id" -lt "$nr" ] || { echo "STOP: node_id $id >= nr_nodes $nr"; exit 1; }
  [[ "$sel" == "protocol=destijl "* ]] || { echo "STOP: frozen PARAMS lack protocol=destijl"; exit 1; }
  [[ "$sel" == *" init_state=invalid" ]] || { echo "STOP: frozen PARAMS lack init_state=invalid"; exit 1; }
  want="${sel% init_state=invalid} init_state=$mode"
  ! loaded || { echo "STOP: cxl_shm already loaded"; exit 1; }
  u=$(dax_users); [ -z "$u" ] || { echo "STOP: /dev/dax0.0 in use: $u"; exit 1; }
  bs=$(sed -n 's/.* bpd_sets=\([0-9]*\).*/\1/p' <<< "$sel") rs=$(sed -n 's/.* ring_slots=\([0-9]*\).*/\1/p' <<< "$sel")
  p=$(CXL_REGION_CONFIG=$H/cxl_region.yaml "$H/faultlat" params --protocol destijl --nodes "$nr" --init-state "$mode" \
      --bpd-sets "$bs" --ring-slots "$rs")
  [ "$p" = "$want" ] || { echo "STOP: params from region config differ: '$p' vs '$want'"; exit 1; }
  [ "$(sha256sum "$KO" | cut -d' ' -f1)" = "$KO_SHA" ] || { echo "STOP: $KO hash differs"; exit 1; }
  [ "$(modinfo -F vermagic "$KO" | cut -d' ' -f1)" = "$K" ] || { echo "STOP: vermagic"; exit 1; }
  # shellcheck disable=SC2086
  insmod "$KO" node_id="$id" $want "${extra[@]}"
  loaded || { echo "STOP: cxl_shm not loaded after insmod"; exit 1; }
  for f in protocol dax_name nr_nodes node_id ring_offset ring_size managed_offset managed_size init_state bpd_sets \
           ring_slots fetch_budget recv_mode fault_poll recv_cpu tick_cpu idle_spin_us idle_sleep_us; do
    [ -r /sys/module/cxl_shm/parameters/$f ] && echo "$f=$(cat /sys/module/cxl_shm/parameters/$f)"
  done
  [ "$(cat $CS/protocol 2>/dev/null)" = destijl ] || { echo "STOP: $CS/protocol is not destijl"; exit 1; }
  for a in "${extra[@]}"; do
    [ "$(cat "/sys/module/cxl_shm/parameters/${a%%=*}" 2>/dev/null)" = "${a#*=}" ] ||
      { echo "STOP: parameter ${a%%=*} is not ${a#*=} after the load"; exit 1; }
  done
  echo "version=$(cat /sys/module/cxl_shm/version 2>/dev/null)"
  echo "state=$(state)"
  dmesg | grep -E 'shm_cxl|cxl_shm|destijl' | tail -n 8
  echo "load_nodes=$nr"
  echo "load OK (node $id)" ;;
wait-state)
  t=${2:?seconds}
  loaded || { echo "STOP: cxl_shm not loaded"; exit 1; }
  for ((i = 0; i < t * 10; i++)); do
    s=$(state)
    [ "$s" = "$STATE_READY" ] && { echo "state=$s"; dmesg | grep -E 'shm_cxl|cxl_shm|destijl' | tail -n 4; echo "state OK ($s)"; exit 0; }
    [ "$s" = mismatch ] && break
    sleep 0.1
  done
  dmesg | grep -E 'shm_cxl|cxl_shm|destijl' | tail -n 8
  echo "STOP: cxl_shm state '$(state)' (want $STATE_READY) after $t s"; exit 1 ;;
enable)
  t=${2:?seconds}
  loaded || { echo "STOP: cxl_shm not loaded"; exit 1; }
  [ "$(state)" = "$STATE_READY" ] || { echo "STOP: cxl_shm state '$(state)' before enable (want $STATE_READY)"; exit 1; }
  for ((i = 0; i < t * 10; i++)); do
    read -r rc en < <(syscall 470)
    [ "$rc" = 0 ] && break
    [ "$en" = EAGAIN ] || { echo "STOP: enable_page_coherence: $en"; exit 1; }
    sleep 0.1
  done
  [ "$rc" = 0 ] || { echo "STOP: enable still EAGAIN after $t s"; exit 1; }
  pr=$(cat $SYS/protocol)
  [ "$pr" = destijl ] || { echo "STOP: $SYS/protocol is '$pr', not destijl"; exit 1; }
  base=$(cat $SYS/managed_base); bytes=$(cat $SYS/managed_bytes)
  start=$(python3 -I -c 'import sys; print(hex(int(open("/sys/bus/dax/devices/dax0.0/resource").read(),0)+int(sys.argv[1])))' "$MANAGED_BASE_OFF")
  [ "$base" = "$start" ] && [ "$bytes" = "$MANAGED_BYTES" ] ||
    { echo "STOP: managed range $base +$bytes, expected $start +$MANAGED_BYTES"; exit 1; }
  # page_coherence/init_state reads "<state> (initialized)" after enable (e.g. "invalid (initialized)"); first word = state
  is=$(cat $SYS/init_state 2>/dev/null || echo absent)
  case "$(cat /sys/module/cxl_shm/parameters/init_state)" in
    shared) [[ "$is" == shared* ]] || { echo "STOP: init_state '$is'"; exit 1; } ;;
    *) [[ "$is" == invalid* ]] || { echo "STOP: init_state '$is'"; exit 1; } ;;
  esac
  echo "protocol=$pr managed_base=$base managed_bytes=$bytes init_state=$is"
  dmesg | grep -E 'swmc|destijl' | tail -n 3
  echo "enable OK" ;;
status)
  echo "release=$(uname -r) loaded=$(grep -c '^cxl_shm ' /proc/modules)"
  if loaded; then
    for f in /sys/module/cxl_shm/parameters/*; do echo "param.$(basename "$f")=$(cat "$f")"; done
    dump_dir $CS cxl_shm
  fi
  for f in $SYS/*; do [ "$(basename "$f")" = reset_counters ] || echo "swmc.$(basename "$f")=$(cat "$f")"; done
  [ -d $DS ] && dump_dir $DS ds
  [ -r /sys/kernel/swmc/instr/enabled ] && echo "instr_enabled=$(cat /sys/kernel/swmc/instr/enabled)"
  for p in $(pgrep -x 'cxl_recv_[0-9]' || true); do  # coherence CPU: receive thread utime+stime (clock ticks)
    awk -v hz="$(getconf CLK_TCK)" '{print "recv_thread." $2 "=" $14 + $15 " ticks (" hz "/s)"}' "/proc/$p/stat"
  done
  echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
  echo "dmesg_bad=$(dmesg | grep -cE 'BUG:|Oops|WARNING:|Call Trace' || true)"
  echo "dax_users=$(dax_users | tr '\n' ';')"
  echo "dax0.0=$(stat -c '%U:%G %a' /dev/dax0.0)"
  dmesg | grep -E 'shm_cxl|cxl_shm|destijl|swmc|dax:' | tail -n 20 | sed 's/^/dmesg: /' ;;
disable)
  read -r rc en < <(syscall 471)
  [ "$rc" = 0 ] || { echo "STOP: disable_page_coherence: $en"; exit 1; }
  echo "disable OK" ;;
unload)
  loaded || { echo "cxl_shm not loaded"; exit 0; }
  rmmod cxl_shm
  if loaded; then echo "STOP: cxl_shm still loaded"; exit 1; fi
  dmesg | grep -E 'shm_cxl|cxl_shm|destijl' | tail -n 4
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
replica-mode)
  # off | all (damon: not used by the harness); the kernel accepts it only while no managed VMA exists (EBUSY): the
  # bring-up chain writes it after load / wait-state and before enable. Same sudo surface (this script as root).
  m=${2:?off|all}; [[ "$m" =~ ^(off|all)$ ]] || { echo "STOP: replica-mode off|all"; exit 1; }
  test -w $DS/replica_mode || { echo "STOP: no $DS/replica_mode (kernel without replication)"; exit 1; }
  echo "$m" > $DS/replica_mode || { echo "STOP: write replica_mode=$m refused (EBUSY: managed mapping; EOPNOTSUPP: build without CONFIG_SWMC_DE_STIJL_REPL)"; exit 1; }
  [ "$(cat $DS/replica_mode)" = "$m" ] || { echo "STOP: replica_mode reads $(cat $DS/replica_mode)"; exit 1; }
  echo "replica_mode OK ($m; replica_pages $(cat $DS/replica_pages 2>/dev/null || echo absent))" ;;
replica-check)
  # ds-replica-check.sh next to this script (bundle tools from De Stijl build 4 on); arguments passed through
  shift; test -f "$H/ds-replica-check.sh" || { echo "STOP: no $H/ds-replica-check.sh in the guest tools"; exit 1; }
  exec bash "$H/ds-replica-check.sh" "$@" ;;
*) sed -n '2,36p' "$0"; exit 2 ;;
esac

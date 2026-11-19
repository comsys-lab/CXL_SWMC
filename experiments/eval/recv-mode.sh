# Receiver-mode rules shared by the evaluation blocks (sourced; never run). Run 2 (state/PROJECT.md "Evaluation run 2"):
# adaptive receiver for De Stijl AND Popcorn, fault-entry polling off for both, idle-vCPU pollers on (one pollers-off
# cell). Modes accepted:
#   Popcorn cxl_shm  poll | idle | sleep | adaptive (adaptive = the 13.1-adaptive module, builds/popcorn_new/13-recv<k>)
#   De Stijl         poll | sleep | adaptive (protocol=destijl refuses idle; adaptive needs build >= 9 guest tools)
# adaptive (and Popcorn idle) need ring_coherent=1: the receiver and the idle pollers read ring lines without cache
# maintenance. Refused on the Host when the bundle's PARAMS_N<N> (else PARAMS) carry ring_coherent=0 (Popcorn: the
# token is required and must be 1; De Stijl: absent = coherent, the module itself refuses 0) and checked again on every
# guest after the load (recv_rb_check: /sys/module/cxl_shm/parameters/ring_coherent).
# Popcorn adaptive also needs POP_ADAPT_KO (Host path of the signed adaptive cxl_shm.ko that the Popcorn bundle
# installs, e.g. builds/popcorn_new/13-recv2/stage/lib/modules/<K>/updates/cxl_shm.ko): its sha256 must equal KO_SHA of
# <bundle>/tools/popcorn.env and modinfo must list the ipoll parameter; after the load the guest's
# /sys/module/cxl_shm/srcversion must equal modinfo's srcversion of that file.
# RECV_IPOLL (optional 0 | 1, unset = module default 1): written to /sys/module/cxl_shm/parameters/ipoll on every VM
# after the enable (adaptive only; 0 = the pollers-off cell) and checked in the readback.
# RECV_WATCH_US / RECV_S_MAX_US (optional integers, unset = module default 200 / 200; adaptive only): written to
# /sys/module/cxl_shm/parameters/watch_us and s_max_us on every VM after the enable (after ipoll) and checked in the
# readback (unset = the readback must show the default 200). watch_us 1..1000000; s_max_us s_min_us (50, the module
# default the harness never changes) ..1000000. recv_wsm_check validates both; a pop / ds lifetime whose mode is not
# adaptive refuses them (the blocks stop; recv_apply refuses too), a block without pop / ds lifetimes only notes them.
# RECV_SPIN_US / RECV_SMIN_US (optional integers, unset = module default 50 / 50 = every run before 2026-11-19; adaptive
# only; recsys-amx-2way receiver variant): written to spin_us and s_min_us after s_max_us (so s_min_us never exceeds
# s_max_us between the writes when both grow) and checked in the readback (unset = 50 / 50). spin_us 0..1000000,
# s_min_us 1..1000000; s_max_us (RECV_S_MAX_US, default 200) must be >= s_min_us. Same rules as the two keys above.
# Guest readback (recv-readback.sh via ssh bash -s): one line "recv_mode=.. ring_coherent=.. ipoll=.. fault_poll=..
# spin_us=.. watch_us=.. s_min_us=.. s_max_us=.. idle_spin_us=.. idle_sleep_us=.. srcversion=.. ipoll_threads=..
# ipoll_run_ns=.. recv_run_ns=.." (absent for a parameter the module lacks).

recv_coherent() {  # <env file> <N>: ring_coherent token of PARAMS_N<N> (else PARAMS): 0 | 1 | unset | ERR (no PARAMS)
  local l
  l=$(grep -E "^PARAMS_N$2=" "$1" 2>/dev/null | tail -n 1)
  [ -n "$l" ] || l=$(grep -E '^PARAMS=' "$1" 2>/dev/null | tail -n 1)
  [ -n "$l" ] || { echo ERR; return 0; }
  if [[ $l =~ ring_coherent=([01])([\ \"]|$) ]]; then echo "${BASH_REMATCH[1]}"; else echo unset; fi
}

# recv_rules <pop|ds> <mode> <bundle dir> <N>: prints nothing and returns 0 when the mode is allowed for that bundle;
# else prints the reason and returns 1. Popcorn adaptive reads POP_ADAPT_KO.
recv_rules() {
  local s=$1 m=$2 c=$3 n=$4 env rc ks
  case $s in
    pop) [[ $m =~ ^(poll|idle|sleep|adaptive)$ ]] || { echo "Popcorn recv_mode '$m' (poll | idle | sleep | adaptive)"; return 1; }
         env=$c/tools/popcorn.env;;
    ds)  [[ $m =~ ^(poll|sleep|adaptive)$ ]] || { echo "De Stijl recv_mode '$m' (poll | sleep | adaptive; protocol=destijl refuses idle)"; return 1; }
         env=$c/tools/destijl.env;;
    *) echo "recv_rules: bad system $s"; return 1;;
  esac
  if [ $s = pop ] && [ "$m" = sleep ] && [ -n "${POP_ADAPT_KO:-}" ]; then
    # run 2 sleep 20/50: POP_ADAPT_KO pins the module the bundle installs (same 13-recv2 module as the adaptive runs)
    [ -f "$POP_ADAPT_KO" ] || { echo "POP_ADAPT_KO $POP_ADAPT_KO missing"; return 1; }
    ks=$(sed -n 's/^KO_SHA=//p' "$env" 2>/dev/null | tail -n 1)
    [ "$(sha256sum < "$POP_ADAPT_KO" | cut -c1-64)" = "$ks" ] \
      || { echo "POP_ADAPT_KO $POP_ADAPT_KO sha256 != KO_SHA $ks of $env (the bundle does not install that module)"; return 1; }
    modinfo -F parm "$POP_ADAPT_KO" 2>/dev/null | grep -q '^idle_sleep_us:' || { echo "POP_ADAPT_KO $POP_ADAPT_KO has no idle_sleep_us parameter"; return 1; }
    return 0
  fi
  [[ $m =~ ^(adaptive|idle)$ ]] || return 0
  [ -f "$env" ] || { echo "$env missing (ring_coherent of the bundle unknown)"; return 1; }
  rc=$(recv_coherent "$env" "$n")
  case $s:$rc in
    pop:1|ds:1|ds:unset) ;;
    *) echo "recv_mode=$m needs ring_coherent=1; $env PARAMS(_N$n) has ring_coherent=$rc"; return 1;;
  esac
  [ "$m" = adaptive ] || return 0
  if [ $s = ds ]; then
    grep -qF 'recv_mode=(poll|sleep|adaptive)' "$c/tools/p-destijl-guest.sh" 2>/dev/null \
      || { echo "De Stijl bundle $c: guest tools do not accept recv_mode=adaptive (build >= 9 bundle needed)"; return 1; }
    return 0
  fi
  [ -f "${POP_ADAPT_KO:-}" ] || { echo "Popcorn recv_mode=adaptive needs POP_ADAPT_KO (adaptive cxl_shm.ko; got '${POP_ADAPT_KO:-}')"; return 1; }
  ks=$(sed -n 's/^KO_SHA=//p' "$env" | tail -n 1)
  [ "$(sha256sum < "$POP_ADAPT_KO" | cut -c1-64)" = "$ks" ] \
    || { echo "POP_ADAPT_KO $POP_ADAPT_KO sha256 != KO_SHA $ks of $env (the bundle does not install that module)"; return 1; }
  modinfo -F parm "$POP_ADAPT_KO" 2>/dev/null | grep -q '^ipoll:' || { echo "POP_ADAPT_KO $POP_ADAPT_KO has no ipoll parameter (not the adaptive module)"; return 1; }
  return 0
}

# recv_run2_guard: run-2 confs set REQUIRE_ADAPTIVE=1 (verifier M3, 2026-11-03): a real run needs RECV_MODE=adaptive
# (De Stijl, and Popcorn unless POP_RECV_MODE is set), POP_RECV_MODE empty or adaptive, and POP_ADAPT_KO set; prints
# nothing and returns 0 when satisfied (or REQUIRE_ADAPTIVE unset / 0), else prints why and returns 1. The callers
# stop on 1 in a real run and only print the reason in a dry run (placeholder pins dry-run cleanly).
# REQUIRE_SLEEP2050=1 (run-2 receiver REVISED 2026-11-04, PROJECT.md; replaces REQUIRE_ADAPTIVE in the run-2 confs): a
# real run needs RECV_MODE=sleep, POP_RECV_MODE empty or sleep, POP_ADAPT_KO set (the same 13-recv2 Popcorn module),
# and REQUIRE_ADAPTIVE unset / 0; the readback (recv_rb_check sleep) then asserts idle_spin_us 50 / idle_sleep_us 20
# for pop and ds. Both keys set = refused.
recv_run2_guard() {
  case ${REQUIRE_SLEEP2050:-0} in 0) ;; 1)
    local w=
    [ "${REQUIRE_ADAPTIVE:-0}" = 0 ] || w="REQUIRE_ADAPTIVE=${REQUIRE_ADAPTIVE} with REQUIRE_SLEEP2050=1"
    [ "${RECV_MODE:-}" = sleep ] || w="${w:+$w; }RECV_MODE=${RECV_MODE:-} (want sleep)"
    [[ ${POP_RECV_MODE:-sleep} == sleep ]] || w="${w:+$w; }POP_RECV_MODE=$POP_RECV_MODE (want sleep)"
    [ -n "${POP_ADAPT_KO:-}" ] || w="${w:+$w; }POP_ADAPT_KO unset (the 13-recv2 module must stay)"
    [ -z "$w" ] || { echo "run 2 needs the sleep 20/50 receiver for pop and ds: $w"; return 1; }
    return 0;;
    *) echo "bad REQUIRE_SLEEP2050 '${REQUIRE_SLEEP2050}' (0 | 1)"; return 1;; esac
  case ${REQUIRE_ADAPTIVE:-0} in 0) return 0;; 1) ;; *) echo "bad REQUIRE_ADAPTIVE '${REQUIRE_ADAPTIVE}' (0 | 1)"; return 1;; esac
  local why=
  [ "${RECV_MODE:-}" = adaptive ] || why="RECV_MODE=${RECV_MODE:-} (want adaptive)"
  [[ ${POP_RECV_MODE:-adaptive} == adaptive ]] || why="${why:+$why; }POP_RECV_MODE=$POP_RECV_MODE (want adaptive)"
  [ -n "${POP_ADAPT_KO:-}" ] || why="${why:+$why; }POP_ADAPT_KO unset"
  [ -z "$why" ] || { echo "run 2 needs the adaptive receiver for pop and ds: $why"; return 1; }
}

# recv_wsm_check [<lifetime mode> ...]: RECV_WATCH_US / RECV_S_MAX_US of the environment (see the header). Prints
# nothing and returns 0 when both are unset, or valid and every given mode (the pop / ds lifetime modes of the block)
# is adaptive; returns 1 with the reason for a bad value, 2 with the reason for a non-adaptive mode (callers: 1 = stop,
# 2 = stop in a real run, note in a dry one). No mode given (hw-only block): 0.
RECV_S_MIN_US=50   # module default s_min_us (the readback checks it); s_max_us below it is refused
recv_wsm_check() {
  local w=${RECV_WATCH_US:-} x=${RECV_S_MAX_US:-} sp=${RECV_SPIN_US:-} sn=${RECV_SMIN_US:-} m
  [ -n "$w$x$sp$sn" ] || return 0
  [ -z "$w" ] || { [[ $w =~ ^[1-9][0-9]{0,6}$ ]] && [ "$w" -le 1000000 ]; } || { echo "bad RECV_WATCH_US '$w' (integer us, 1..1000000)"; return 1; }
  [ -z "$sp" ] || { [[ $sp =~ ^(0|[1-9][0-9]{0,6})$ ]] && [ "$sp" -le 1000000 ]; } || { echo "bad RECV_SPIN_US '$sp' (integer us, 0..1000000)"; return 1; }
  [ -z "$sn" ] || { [[ $sn =~ ^[1-9][0-9]{0,6}$ ]] && [ "$sn" -le 1000000 ]; } || { echo "bad RECV_SMIN_US '$sn' (integer us, 1..1000000)"; return 1; }
  [ -z "$x" ] || { [[ $x =~ ^[1-9][0-9]{0,6}$ ]] && [ "$x" -le 1000000 ]; } || { echo "bad RECV_S_MAX_US '$x' (integer us, ${sn:-$RECV_S_MIN_US}..1000000)"; return 1; }
  [ -z "$x" ] || [ "$x" -ge "${sn:-$RECV_S_MIN_US}" ] || { echo "RECV_S_MAX_US=$x < s_min_us ${sn:-$RECV_S_MIN_US} (the sleep tier needs s_max_us >= s_min_us)"; return 1; }
  [ -z "$sn" ] || [ -n "$x" ] || [ "$sn" -le 200 ] || { echo "RECV_SMIN_US=$sn > the default s_max_us 200 (set RECV_S_MAX_US >= $sn)"; return 1; }
  for m in "$@"; do
    [ "$m" = adaptive ] || { echo "RECV_WATCH_US / RECV_S_MAX_US / RECV_SPIN_US / RECV_SMIN_US need recv_mode=adaptive (a pop / ds lifetime runs recv_mode=$m)"; return 2; }
  done
  return 0
}
recv_wsm_desc() {  # plan / manifest text: "watch_us=<v|default> s_max_us=<v|default>" (+ " spin_us=<v> s_min_us=<v>" when set)
  echo "watch_us=${RECV_WATCH_US:-default} s_max_us=${RECV_S_MAX_US:-default}${RECV_SPIN_US:+ spin_us=$RECV_SPIN_US}${RECV_SMIN_US:+ s_min_us=$RECV_SMIN_US}"
}

recv_pop_srcversion() {  # srcversion of POP_ADAPT_KO (- when unset)
  [ -f "${POP_ADAPT_KO:-}" ] && modinfo -F srcversion "$POP_ADAPT_KO" 2>/dev/null || echo -
}

# recv_rb_check <pop|ds> <mode> <readback line> <srcversion | -> <ipoll | -> <fault_poll | -> [<watch_us | ->
# [<s_max_us | -> [<spin_us | -> [<s_min_us | ->]]]]: 0 = OK, else prints why (watch_us / s_max_us: - or absent = the
# module default 200; spin_us / s_min_us: - or absent = the module default 50)
recv_rb_check() {
  local s=$1 m=$2 l=" $3 " sv=$4 ip=$5 fp=$6 ww=${7:--} wx=${8:--} wsp=${9:--} wsn=${10:--} v
  rbv() { v=$(echo "$l" | sed -n "s/.* $1=\([^ ]*\) .*/\1/p"); }
  rbv recv_mode; [ "$v" = "$m" ] || { echo "recv_mode=$v (want $m)"; return 1; }
  if [ "$m" = sleep ] && [ "${REQUIRE_SLEEP2050:-0}" = 1 ]; then
    # run-2 receiver (2026-11-04, PROJECT.md): sleep idle_spin_us 50 / idle_sleep_us 20, same module for pop and ds
    rbv ipoll; [ -n "$v" ] && [ "$v" != absent ] || { echo "no ipoll parameter (module is not the run-2 receiver module)"; return 1; }
    rbv idle_spin_us; [ "$v" = 50 ] || { echo "idle_spin_us=$v (want 50: run-2 sleep 20/50 for pop and ds)"; return 1; }
    rbv idle_sleep_us; [ "$v" = 20 ] || { echo "idle_sleep_us=$v (want 20: run-2 sleep 20/50 for pop and ds)"; return 1; }
    rbv fault_poll; [ $s != ds ] || [ "$fp" = - ] || [ "$v" = "$fp" ] || { echo "fault_poll=$v (want $fp)"; return 1; }
    rbv srcversion; [ "$sv" = - ] || [ "$v" = "$sv" ] || { echo "srcversion=$v (want $sv of POP_ADAPT_KO)"; return 1; }
    return 0
  fi
  [ "$m" = adaptive ] || return 0
  rbv ring_coherent; case $s:$v in pop:1|ds:1|ds:-1) ;; *) echo "ring_coherent=$v with recv_mode=adaptive"; return 1;; esac
  rbv ipoll; [ -n "$v" ] && [ "$v" != absent ] || { echo "no ipoll parameter (module is not the adaptive receiver)"; return 1; }
  [ "$v" = "$([ "$ip" = - ] && echo 1 || echo "$ip")" ] || { echo "ipoll=$v (want ${ip/-/1})"; return 1; }
  # one adaptive configuration for pop and ds (verifier M4): busy tier 50 / 200 us, sleep tier 50..200 us by default;
  # watch_us / s_max_us = RECV_WATCH_US / RECV_S_MAX_US when the conf sets them (same conf keys for pop and ds)
  local p w
  # spin_us / s_min_us = RECV_SPIN_US / RECV_SMIN_US when the conf sets them (default 50 / 50 as before)
  for p in spin_us=${wsp/#-/50} watch_us=${ww/#-/200} s_min_us=${wsn/#-/$RECV_S_MIN_US} s_max_us=${wx/#-/200}; do
    rbv ${p%%=*}; w=${p#*=}; [ "$v" = "$w" ] || { echo "${p%%=*}=$v (want $w: pop and ds use the same adaptive parameters)"; return 1; }
  done
  rbv fault_poll; [ "$fp" = - ] || [ "$v" = absent ] || [ "$v" = "$fp" ] || { echo "fault_poll=$v (want $fp)"; return 1; }
  [ $s != ds ] || [ "$fp" = - ] || [ "$v" = "$fp" ] || { echo "fault_poll=$v (want $fp)"; return 1; }
  rbv srcversion; [ "$sv" = - ] || [ "$v" = "$sv" ] || { echo "srcversion=$v (want $sv of POP_ADAPT_KO)"; return 1; }
  return 0
}

# ---- block side (h2n-block.sh, h3-block.sh, experiments/recsys/main-block.sh, experiments/rocksdb/pilot-run.sh);
# globals of the caller: IPS (guest IPs), SSH, E (evidence dir), stop() (log + exit; RECV_STOP = another function name,
# e.g. one that tears cxl_shm down first), optional DSRX (ds receiver extra "name=value ..."), DSFP (ds fault_poll want,
# default 0), IPOLL (RECV_IPOLL), POPSV (Popcorn srcversion want or -); RECV_WATCH_US / RECV_S_MAX_US from the
# environment (the blocks validate them with recv_wsm_check at start)
RECV_RB_DEFAULT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recv-readback.sh
# recv_apply <pop|ds> <name> <mode>: recv_mode (+ IPOLL, RECV_WATCH_US, RECV_S_MAX_US for adaptive) on every VM, then
# the recv-readback.sh line per VM -> E/recv-mode-<name>.txt ("<ip> recv_mode=.. ... instr_enabled=..", one line per
# VM: recv_check.py reads it) and checked (mode, ring_coherent, adaptive module, ipoll, watch_us, s_max_us, fault_poll,
# Popcorn srcversion); Popcorn also instr_enabled=1, De Stijl protocol=destijl and every DSRX parameter applied. The
# first failure calls the stop function; RECV_WATCH_US / RECV_S_MAX_US with a non-adaptive mode stop before any write.
recv_apply() {
  local s=$1 ip rb i p w x why fp=- ipo=${IPOLL:-} st=${RECV_STOP:-stop} bad= wu=${RECV_WATCH_US:-} su=${RECV_S_MAX_US:-} \
    ssp=${RECV_SPIN_US:-} ssn=${RECV_SMIN_US:-}
  [ $s = ds ] && fp=${DSFP:-0}
  [ $s = pop ] && fp=0
  why=$(recv_wsm_check "$3") || { $st "$2: $why"; return 1; }
  for ip in "${IPS[@]}"; do
    w="echo $3 > /sys/module/cxl_shm/parameters/recv_mode"
    [ -z "$ipo" ] || [ "$3" != adaptive ] || w+=" && echo $ipo > /sys/module/cxl_shm/parameters/ipoll"
    [ -z "$wu" ] || [ "$3" != adaptive ] || w+=" && echo $wu > /sys/module/cxl_shm/parameters/watch_us"
    [ -z "$su" ] || [ "$3" != adaptive ] || w+=" && echo $su > /sys/module/cxl_shm/parameters/s_max_us"
    [ -z "$ssp" ] || [ "$3" != adaptive ] || w+=" && echo $ssp > /sys/module/cxl_shm/parameters/spin_us"
    [ -z "$ssn" ] || [ "$3" != adaptive ] || w+=" && echo $ssn > /sys/module/cxl_shm/parameters/s_min_us"
    $SSH comsys@$ip "sudo -n sh -c '$w'" < /dev/null || { $st "$2: recv_mode write on $ip"; return 1; }
    rb=$($SSH comsys@$ip "bash -s" < "$RECV_RB_DEFAULT" 2>/dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled 2>/dev/null || echo absent" < /dev/null)
    if [ $s = ds ]; then
      p=$($SSH comsys@$ip "cat /sys/kernel/swmc/page_coherence/protocol" < /dev/null)
      echo "$ip $rb protocol=$p instr_enabled=$i" >> "$E/recv-mode-$2.txt"
      [ "$p" = destijl ] || bad="protocol on $ip ($p)"
      for x in ${DSRX:-}; do [[ " $rb " == *" $x "* ]] || bad="receiver parameter $x not applied on $ip ($rb)"; done
    else
      echo "$ip $rb instr_enabled=$i" >> "$E/recv-mode-$2.txt"
      [ "$i" = 1 ] || bad="instr on $ip ($i)"
    fi
    why=$(recv_rb_check $s "$3" "$rb" "$([ $s = pop ] && echo "${POPSV:--}" || echo -)" "${ipo:--}" "$fp" "${wu:--}" "${su:--}" "${ssp:--}" "${ssn:--}") || bad="receiver on $ip: $why"
    [ -z "$bad" ] || { $st "$2: $bad"; return 1; }
  done
}
recv_post() {  # <name>: recv-readback.sh line per VM after the run (lifetime receiver / poller CPU = post - pre)
  local ip rbf=$RECV_RB_DEFAULT
  for ip in "${IPS[@]}"; do echo "$ip $($SSH comsys@$ip "bash -s" < "$rbf" 2>/dev/null)" >> "$E/recv-post-$1.txt"; done
}

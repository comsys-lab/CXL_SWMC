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
recv_run2_guard() {
  case ${REQUIRE_ADAPTIVE:-0} in 0) return 0;; 1) ;; *) echo "bad REQUIRE_ADAPTIVE '${REQUIRE_ADAPTIVE}' (0 | 1)"; return 1;; esac
  local why=
  [ "${RECV_MODE:-}" = adaptive ] || why="RECV_MODE=${RECV_MODE:-} (want adaptive)"
  [[ ${POP_RECV_MODE:-adaptive} == adaptive ]] || why="${why:+$why; }POP_RECV_MODE=$POP_RECV_MODE (want adaptive)"
  [ -n "${POP_ADAPT_KO:-}" ] || why="${why:+$why; }POP_ADAPT_KO unset"
  [ -z "$why" ] || { echo "run 2 needs the adaptive receiver for pop and ds: $why"; return 1; }
}

recv_pop_srcversion() {  # srcversion of POP_ADAPT_KO (- when unset)
  [ -f "${POP_ADAPT_KO:-}" ] && modinfo -F srcversion "$POP_ADAPT_KO" 2>/dev/null || echo -
}

# recv_rb_check <pop|ds> <mode> <readback line> <srcversion | -> <ipoll | -> <fault_poll | ->: 0 = OK, else prints why
recv_rb_check() {
  local s=$1 m=$2 l=" $3 " sv=$4 ip=$5 fp=$6 v
  rbv() { v=$(echo "$l" | sed -n "s/.* $1=\([^ ]*\) .*/\1/p"); }
  rbv recv_mode; [ "$v" = "$m" ] || { echo "recv_mode=$v (want $m)"; return 1; }
  [ "$m" = adaptive ] || return 0
  rbv ring_coherent; case $s:$v in pop:1|ds:1|ds:-1) ;; *) echo "ring_coherent=$v with recv_mode=adaptive"; return 1;; esac
  rbv ipoll; [ -n "$v" ] && [ "$v" != absent ] || { echo "no ipoll parameter (module is not the adaptive receiver)"; return 1; }
  [ "$v" = "$([ "$ip" = - ] && echo 1 || echo "$ip")" ] || { echo "ipoll=$v (want ${ip/-/1})"; return 1; }
  # one adaptive configuration for pop and ds (verifier M4): busy tier 50 / 200 us, sleep tier 50..200 us
  local p w
  for p in spin_us=50 watch_us=200 s_min_us=50 s_max_us=200; do
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
# default 0), IPOLL (RECV_IPOLL), POPSV (Popcorn srcversion want or -)
RECV_RB_DEFAULT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recv-readback.sh
# recv_apply <pop|ds> <name> <mode>: recv_mode (+ IPOLL for adaptive) on every VM, then the recv-readback.sh line per
# VM -> E/recv-mode-<name>.txt ("<ip> recv_mode=.. ... instr_enabled=..", one line per VM: recv_check.py reads it) and
# checked (mode, ring_coherent, adaptive module, ipoll, fault_poll, Popcorn srcversion); Popcorn also instr_enabled=1,
# De Stijl protocol=destijl and every DSRX parameter applied. The first failure calls the stop function.
recv_apply() {
  local s=$1 ip rb i p w x why fp=- ipo=${IPOLL:-} st=${RECV_STOP:-stop} bad=
  [ $s = ds ] && fp=${DSFP:-0}
  [ $s = pop ] && fp=0
  for ip in "${IPS[@]}"; do
    w="echo $3 > /sys/module/cxl_shm/parameters/recv_mode"
    [ -z "$ipo" ] || [ "$3" != adaptive ] || w+=" && echo $ipo > /sys/module/cxl_shm/parameters/ipoll"
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
    why=$(recv_rb_check $s "$3" "$rb" "$([ $s = pop ] && echo "${POPSV:--}" || echo -)" "${ipo:--}" "$fp") || bad="receiver on $ip: $why"
    [ -z "$bad" ] || { $st "$2: $bad"; return 1; }
  done
}
recv_post() {  # <name>: recv-readback.sh line per VM after the run (lifetime receiver / poller CPU = post - pre)
  local ip rbf=$RECV_RB_DEFAULT
  for ip in "${IPS[@]}"; do echo "$ip $($SSH comsys@$ip "bash -s" < "$rbf" 2>/dev/null)" >> "$E/recv-post-$1.txt"; done
}

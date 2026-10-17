#!/bin/bash
# LMDB H1 main block (reports/H1-main-packet.md; MOT1 v6 Fig 1 / Fig 2). H1-HOOK v1 (experiments/h1/README.md): called
# by experiments/h1/hook.sh with the pinned environment of experiments/h1/plugins/pins-lmdb.sh. f1-block.sh is the
# functional validation (LMDB-F1); this block runs the H1 SLO and fixed phases on the LMDB-F1 v1.7.1 guest install.
# usage: h1-block.sh <evidence dir (exists; empty except sequence* files)>
# env (from hook.sh): H1MODE slo|fix, H1_N (round / rep), H1_SEED (loadgen seed, the same for every system of the round),
#   H1_PARENT_LOCK=H1-main (the lock file must name owner=H1-main; this block never locks or unlocks), H1_MIXES
#   "<mix>=UPDATE_RATIO=<0.05|0.5|0.8> ..." (slo) or H1_LEVELS (levels.tsv; fix), PRETOUCH_DIR, MEASURE_ENV_DIR.
# env (from the plugin): EXPECT_K (Popcorn build 12 release), EXPECT_DAX_UUID, PLAIN_BUILD MEG_BUILD LOADGEN_BUILD,
#   BUILD_PIN MEGALON_BUILD_N (manifest gate), LMDB_GUEST_DIR (the install: <L>/plain, <L>/megalon, <L>/img-1000000 on
#   node 0), LMDB_MEG_CFG (the megalon.yaml that install wrote), IMG (Host image dir whose pages.bin was installed),
#   C8 K8 GT8 RECV_MODE (Popcorn build 12 bundle).
# Mixes u5/u50/u80 = get/update 95/5, 50/50, 20/80 (MOT1 v6), 1M records, p99 < 1 ms per request (h1-plan.tsv).
#   slo: per system hw, pop, mg (timers on; base order = shuffle seed "H1-lmdb-r1" rotated left by N-1: Latin square
#        over rounds) and per mix (shuffle seed "H1-lmdb-r<N>-<sys>"): one pilot-run.sh KIND=slo run <sys>-<mix>-slo-r<N>
#        (MOT1 §3.3: ramp from 500 x1.5, bisect 5 %, confirm 3 x 30 s, fill 0.7/0.8/0.9, overload 1.05/1.1/1.2; every
#        step kept). A loadgen note (e.g. "confirm failed at three rates") = NOTE, the block continues.
#   fix: per levels.tsv row (mix) and per system hw, pop, mg, mgoff (shuffle seed "H1-lmdb-fix-r<N>-<mix>"): one lifetime
#        pilot-run.sh KIND=fix2 RATES=<L2_rate>,<L1_rate> (two windows 10 s + 5 s + 30 s, no SLO abort; an aborted window =
#        NOTE) <sys>-<mix>-fix-r<N>; mgoff = Megalon with MEGALON_COH_TIMERS=0 on both nodes (Fig 2 C_diff).
# Per run: pretouch check, Host gate (pilot-run, measure-env against MEASURE_ENV_DIR), pilot-run's checks (clean stop,
#   not-found/errors 0, value checks, opsplit), v1-check.py --workload lmdb (mgoff --timers off; --loadgen-steps: row
#   checks of failed/overload steps are NOTEs), dmesg rule -> <run>/h1-runcheck.txt (last line RUNCHECK PASS [NOTE ...]);
#   <dir>/h1-runs.tsv one line per run; order.txt before the first run.
# EXIT trap (always, in this order): our lmdb processes on both VMs killed by command-line word and verified (procs=0,
#   empty sudo -n fuser /dev/dax0.0), every cxl_shm load without "teardown PASS" torn down (instr-on retry), /dev/dax0.0
#   root:root 600 with a fresh stat on both VMs. A ROLLBACK FAIL / CLEANUP FAILED line = stop and manual check; the later
#   steps are still attempted. No unlock (the parent owns the lock).
# Marker: H1-HOOK v1
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/lmdb K=$P/CXL_SWMC/experiments/kv
LOCKF=$P/workspaces/MEASUREMENT.lock
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
R=1000000 MAXP=600000
PAT='(^|[ /])bin/lmdb-(serve[r]|stres[s])( |$)'  # our processes by command-line word ([x]: not the remote shell's own)
: "${H1MODE:?}" "${H1_N:?}" "${H1_SEED:?}" "${H1_PARENT_LOCK:?}" "${PRETOUCH_DIR:?}" "${MEASURE_ENV_DIR:?}"
: "${EXPECT_K:?}" "${EXPECT_DAX_UUID:?}" "${PLAIN_BUILD:?}" "${MEG_BUILD:?}" "${LOADGEN_BUILD:?}" "${BUILD_PIN:?}" "${MEGALON_BUILD_N:?}"
: "${LMDB_GUEST_DIR:?}" "${LMDB_MEG_CFG:?}" "${IMG:?}" "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
export MEASURE_ENV_DIR
L=$LMDB_GUEST_DIR
[ "$H1_PARENT_LOCK" = H1-main ] || { echo "SEQUENCE STOP: H1_PARENT_LOCK must be H1-main"; exit 2; }
[[ $H1_N =~ ^[1-9]$ ]] && [[ $H1_SEED =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: H1_N / H1_SEED"; exit 2; }
case $H1MODE in slo) : "${H1_MIXES:?}";; fix) [ -f "${H1_LEVELS:-}" ] || { echo "SEQUENCE STOP: no H1_LEVELS"; exit 2; };;
  *) echo "SEQUENCE STOP: bad H1MODE"; exit 2;; esac
[ "$EXPECT_K" = "$K8" ] || { echo "SEQUENCE STOP: EXPECT_K != K8 (all systems run on the Popcorn build)"; exit 2; }
case "$L" in /home/comsys/?*) ;; *) echo "SEQUENCE STOP: LMDB_GUEST_DIR must be under /home/comsys/"; exit 2;; esac
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
grep -q "^source_commit=$BUILD_PIN dirty_files=0$" "$PLAIN_BUILD/manifest.txt" && grep -q "^source_commit=$BUILD_PIN dirty_files=0$" "$MEG_BUILD/manifest.txt" \
  && grep -q "^megalon_build=$P/builds/megalon/$MEGALON_BUILD_N$" "$MEG_BUILD/manifest.txt" \
  && grep -q " cxl_swmc_commit=$BUILD_PIN lmdb_dirty=0$" "$LOADGEN_BUILD/manifest.txt" \
  && grep -q "^sha256 $(sha256sum "$LOADGEN_BUILD/loadgen" | cut -d' ' -f1)  " "$LOADGEN_BUILD/manifest.txt" \
  || { echo "SEQUENCE STOP: builds are not clean builds of $BUILD_PIN on builds/megalon/$MEGALON_BUILD_N"; exit 2; }
OWNER="H1-lmdb-$H1MODE-r$H1_N" CHOWNED=0
parent_lock_check() { grep -q "^owner=$H1_PARENT_LOCK " "$LOCKF" 2>/dev/null \
  || { echo "$(date -Is) SEQUENCE STOP: parent lock $H1_PARENT_LOCK not held ($(cat "$LOCKF" 2>/dev/null))"; exit 1; }; }
parent_lock_check
finish() {  # order: our processes, Popcorn teardown, dax0.0; never unlock (the parent owns the lock)
  set +eu
  local ip out r
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "pkill -u comsys -f '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f '$PAT'); echo fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" && echo "$out" | grep -qx "fuser=\[\]" \
      || echo "ROLLBACK FAIL: $ip lmdb process left or /dev/dax0.0 still in use (see rollback.out)" | tee -a "$E/rollback.out"
  done
  for r in "$E"/shm-*/; do
    r=${r%/}; [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
      || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
           && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: reports/M5-pilot-kv.md §6)" | tee -a "$E/cleanup.out"
  done
  dax_root_all || true
}
dax_root_all() {  # judged on this call's fresh stat per VM
  local ip out rc=0
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "stat=root:root 600" || { echo "ROLLBACK FAIL: $ip dax0.0 not root:root 600" | tee -a "$E/rollback.out"; rc=1; }
  done
  return $rc
}
dax_comsys_all() {
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
  done
}
trap finish EXIT
ptcheck() {  # <tag>: standing pretouch rule (both VMs pre-touched after their current QEMU start)
  bash $K/pretouch-check.sh "$PRETOUCH_DIR" "$E/pretouch-check-$1.txt" > /dev/null \
    || { echo "$(date -Is) SEQUENCE STOP: pretouch check ($1), see pretouch-check-$1.txt"; exit 1; }
}
shuf() { python3 -B -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$@"; }
echo "$(date -Is) block $OWNER start (H1-HOOK v1; guest $L; builds $PLAIN_BUILD $MEG_BUILD $LOADGEN_BUILD)"
ptcheck start
# install check (validation install reused, Q10): every guest file = the pinned builds / config / image
want="$(sha256sum < $PLAIN_BUILD/bin/lmdb-server | cut -c1-64) $(sha256sum < $MEG_BUILD/bin/lmdb-server | cut -c1-64) $(sha256sum < $MEG_BUILD/lib/libmegalon-objapi.so | cut -c1-64) $(sha256sum < $MEG_BUILD/lib/libmegalon.so | cut -c1-64) $(sha256sum < $P/CXL_SWMC/config/cxl_region.yaml | cut -c1-64) $(sha256sum < $P/CXL_SWMC/config/cxl_region.yaml | cut -c1-64) $(sha256sum < $LMDB_MEG_CFG | cut -c1-64) $(sha256sum < $X/lmdb-node.sh | cut -c1-64) $(sha256sum < $X/lmdb-node.sh | cut -c1-64)"
for i in 0 1; do
  got=$($SSH comsys@${IPS[$i]} "cd $L && for f in plain/bin/lmdb-server megalon/bin/lmdb-server megalon/lib/libmegalon-objapi.so megalon/lib/libmegalon.so plain/cfg/cxl_region.yaml megalon/cfg/cxl_region.yaml megalon/cfg/megalon.yaml plain/bin/lmdb-node.sh megalon/bin/lmdb-node.sh; do sha256sum < \$f | cut -c1-64; done | tr '\n' ' '" < /dev/null)
  echo "install vm$i: $got" >> "$E/install-check.txt"
  [ "${got% }" = "$want" ] || { echo "SEQUENCE STOP: install sha256 vm$i: [$got] != [$want]"; exit 1; }
done
[ "$($SSH comsys@${IPS[0]} "sha256sum < $L/img-$R/pages.bin | cut -c1-64" < /dev/null)" = "$(sha256sum < $IMG/pages.bin | cut -c1-64)" ] \
  || { echo "SEQUENCE STOP: image sha256 vm0 ($L/img-$R vs $IMG)"; exit 1; }
for i in 0 1; do
  $SSH comsys@${IPS[$i]} "EXPECT_K=$EXPECT_K EXPECT_DAX_UUID=$EXPECT_DAX_UUID INSTALL_FILES='${L#/home/comsys/}/plain/bin/lmdb-server ${L#/home/comsys/}/megalon/bin/lmdb-server ${L#/home/comsys/}/megalon/lib/libmegalon-objapi.so' bash -s" \
    < $K/precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "^PRECHECK PASS" "$E/precheck-vm$i.txt" || { echo "SEQUENCE STOP: precheck vm$i"; exit 1; }
done
# dmesg rule (validation packets): integer baseline per VM; after every run no new matching line
BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
dcount() { local c; c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1; [[ $c =~ ^[0-9]+$ ]] || return 1; echo "$c"; }
for i in 0 1; do c=$(dcount $i) || { echo "SEQUENCE STOP: dmesg baseline vm$i"; exit 1; }; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
dmesg_check() {  # <run>
  local i n c
  for i in 0 1; do
    n=$(cat "$E/dmesg-base-vm$i.txt"); c=$(dcount $i) || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1"; exit 1; }
    [ "$c" -ge "$n" ] || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1: ring buffer wrapped ($n -> $c)"; exit 1; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 \
      || { echo "$(date -Is) SEQUENCE STOP: dmesg vm$i after $1: ssh"; exit 1; }
    grep -E "$BAD" "$E/dmesg-new-$1-vm$i.txt" > /dev/null \
      && { echo "$(date -Is) SEQUENCE STOP: new dmesg error/warning on vm$i after $1: $(grep -E "$BAD" "$E/dmesg-new-$1-vm$i.txt" | head -2)"; exit 1; }
  done; true
}
uratio() { case $1 in UPDATE_RATIO=0.05) echo 0.05;; UPDATE_RATIO=0.5) echo 0.5;; UPDATE_RATIO=0.8) echo 0.8;;
           *) echo "SEQUENCE STOP: bad mix parameter $1" >&2; return 1;; esac; }
COMMON=(LOCK_OWNER=$H1_PARENT_LOCK PLAIN_BUILD=$PLAIN_BUILD MEG_BUILD=$MEG_BUILD LOADGEN_BUILD=$LOADGEN_BUILD
        VM_PLAIN=$L/plain VM_MEG=$L/megalon IMAGE=$L/img-$R RECORDS=$R MAX_PAGES=$MAXP PREPARE_THREADS=8 SEED=$H1_SEED)
run1() {  # <sys> <mix> <phase> <env...>: one pilot-run + per-run checks + h1-runcheck.txt + h1-runs.tsv line
  local s=$1 m=$2 ph=$3 name=$1-$2-$3-r$H1_N st v1 tm=on sysv SE; shift 3
  parent_lock_check
  ptcheck "$name"
  case $s in
    hw)    [ $CHOWNED = 1 ] || dax_comsys_all; SE=(SYS=all-HWcc); sysv=all-HWcc;;
    mg)    [ $CHOWNED = 1 ] || dax_comsys_all; SE=(SYS=Megalon COH_TIMERS=1); sysv=Megalon;;
    mgoff) [ $CHOWNED = 1 ] || dax_comsys_all; SE=(SYS=Megalon COH_TIMERS=0); sysv=Megalon; tm=off;;
    pop)   if [ $CHOWNED = 1 ]; then dax_root_all || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600 before Popcorn"; exit 1; }; CHOWNED=0; fi
           SE=(SYS=Popcorn C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE); sysv=Popcorn;;
  esac
  echo "$(date -Is) == $name"
  env "${COMMON[@]}" "${SE[@]}" "$@" bash $X/pilot-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "$(date -Is) SEQUENCE STOP at $name"; exit 1; }
  st=$(grep -h "^PILOTRUN $name " "$E/runs.log" | tail -n 1)
  [[ "$st" =~ ^PILOTRUN\ $name\ (OK|NOTE) ]] || { echo "SEQUENCE STOP: $name no PILOTRUN OK/NOTE"; exit 1; }
  v1=$(python3 -I -B $K/v1-check.py "$E/$name" --system $sysv --timers $tm --workload lmdb --loadgen-steps "$E/$name/loadgen/steps.jsonl")
  echo "$name $v1" >> "$E/v1-check.log"
  [[ "$v1" == "V1 CHECK PASS"* ]] || { echo "$(date -Is) SEQUENCE STOP: v1-check $name: $v1"; exit 1; }
  dmesg_check "$name"
  { echo "# H1 per-run checks $name (system $s, mix $m, phase $ph, round $H1_N, seed $H1_SEED; lmdb h1-block.sh, H1-HOOK v1)"
    echo "$st"
    echo "v1-check: $v1"; grep -h "^NOTE \|^WARN " "$E/$name/v1-check.txt" | sed 's/^/v1-check: /' | cut -c1-400
    echo "pretouch: $(tail -n 1 "$E/pretouch-check-$name.txt")"
    echo "dmesg: no new error/warning lines on vm0/vm1 since the block start"
    echo "loadgen: $(python3 -I -B -c 'import json,sys; s=json.load(open(sys.argv[1])); print("workload_finish", s.get("workload_finish"), "note", repr(s.get("note", "")))' "$E/$name/loadgen/summary.json")"
    echo "kernel: $(grep -h '^node0=' "$E/$name/manifest.txt")"
  } > "$E/$name/h1-runcheck.txt"
  grep -q "^loadgen: workload_finish ok" "$E/$name/h1-runcheck.txt" && [ -s "$E/$name/opsplit.csv" ] \
    || { echo "SEQUENCE STOP: $name run checks incomplete"; exit 1; }
  if [[ "$st" =~ \ NOTE\  ]] || [[ "$v1" == *"(notes:"* ]]; then
    nt=""; [[ "$st" =~ \ NOTE\  ]] && nt="${st#PILOTRUN $name NOTE }"; [[ "$v1" == *"(notes:"* ]] && nt="${nt:+$nt; }v1-check${v1#V1 CHECK PASS}"
    echo "RUNCHECK PASS (NOTE: $nt)" >> "$E/$name/h1-runcheck.txt"
  else echo "RUNCHECK PASS" >> "$E/$name/h1-runcheck.txt"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$s" "$m" "$ph" "$H1_N" "$name" >> "$E/h1-runs.tsv"
}
printf '# name\tsystem\tmix\tphase\tround\trun_dir\n' > "$E/h1-runs.tsv"
if [ "$H1MODE" = slo ]; then
  base=($(shuf H1-lmdb-r1 hw pop mg)); rot=$(( (H1_N - 1) % 3 ))
  ord=$(echo "${base[@]:$rot} ${base[@]:0:$rot}")
  mixes=""; for spec in $H1_MIXES; do mixes="$mixes ${spec%%=*}"; uratio "${spec#*=}" > /dev/null || exit 1; done
  { echo "# H1 LMDB SLO round $H1_N (systems: base shuffle seed H1-lmdb-r1 rotated left by $rot; mixes per system: shuffle seed H1-lmdb-r$H1_N-<sys>; loadgen seed $H1_SEED; 1M records)"
    echo "systems: $ord"; for s in $ord; do echo "mixes $s: $(shuf H1-lmdb-r$H1_N-$s $mixes)"; done; echo "H1_MIXES: $H1_MIXES"; } | tee "$E/order.txt"
  for s in $ord; do
    for m in $(shuf H1-lmdb-r$H1_N-$s $mixes); do
      for spec in $H1_MIXES; do [ "${spec%%=*}" = "$m" ] && u=$(uratio "${spec#*=}"); done
      run1 $s $m slo UPDATE_RATIO=$u KIND=slo
    done
  done
else
  { echo "# H1 LMDB fixed phase rep $H1_N (levels $H1_LEVELS; systems per mix: shuffle seed H1-lmdb-fix-r$H1_N-<mix>; loadgen seed $H1_SEED; windows L2 then L1)"
    tail -n +2 "$H1_LEVELS" | while IFS=$'\t' read -r mix rest; do echo "$mix: $(shuf H1-lmdb-fix-r$H1_N-$mix hw pop mg mgoff)"; done; } | tee "$E/order.txt"
  while IFS=$'\t' read -r -a f; do
    mix=${f[0]} l1=${f[8]} l2=${f[9]}
    case $mix in u5) u=0.05;; u50) u=0.5;; u80) u=0.8;; *) echo "SEQUENCE STOP: levels mix $mix"; exit 1;; esac
    [[ $l1 =~ ^[1-9][0-9]*$ ]] && [[ $l2 =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: levels $mix rates $l2/$l1 (integers expected)"; exit 1; }
    for s in $(shuf H1-lmdb-fix-r$H1_N-$mix hw pop mg mgoff); do
      run1 $s $mix fix UPDATE_RATIO=$u KIND=fix2 RATES=$l2,$l1 < /dev/null
    done
  done < <(tail -n +2 "$H1_LEVELS")
fi
ptcheck end
echo "$(date -Is) SEQUENCE DONE H1-lmdb $H1MODE r$H1_N ($(($(wc -l < "$E/h1-runs.tsv") - 1)) runs)"

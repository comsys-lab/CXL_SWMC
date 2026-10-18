#!/bin/bash
# The recommendation-system H1 MAIN block (reports/RECSYS-main-packet.md): full-size tables (26 tables, 26M cap,
# 167,731,776 slots x 576 B = 89.98 GiB), T = 60 s, serving on node 1, MOT1 v6 (user 2026-10-16):
#   SLO query p95 <= 100 ms (DeepRecSys ISCA'20; reports/MOT1-v6-sources.md §1), fixed for every system (<E>/slo.txt);
#   updater on node 0 replays the real MLPerf day-23 multi-hot trace at the Ekko operating point EKKO=avg (3.08% of
#   rows/hour -> PUBLISH_FRAC 0.0308/60 per T) or EKKO=peak (4.3%/10 min -> 0.043/10 per T); the sample rate is
#   computed on the Host by recsys-rate from the trace (<E>/update-rate.txt) so that one T publishes that fraction.
#   (v5 rule "SLO = 5 x all-HWcc p99 at the lowest load" and the fixed 2,100 samples/s are superseded.) Every system on the Popcorn build POP_BUILD (>= 10) kernel (K8): all-HWcc and Megalon with cxl_shm unloaded, page MSI
# with cxl_shm loaded once for its whole server lifetime (init_state=shared + preload, recv_mode RECV_MODE).
# usage: main-block.sh <evidence dir (exists; only sequence* files)>
# env (required): C8 (Popcorn deploy bundle dir, = builds/popcorn_new/10/deploy-v1), K8, GT8 (names kept from v5),
#   RECV_MODE, optional POP_BUILD (10, >= 10), POP_BUNDLE_SHA (build-10 deploy-v1 packet hash), D (inputs dir with MANIFEST.txt),
#   VM_PLAIN (guest dir: build-3 server, all-HWcc + page MSI), VM_MEG (guest dir: Megalon build + recsys-2vm.yaml),
#   MEG_BUILD (recsys-megalon build on MEGALON_BASE, default builds/megalon/75), PLAIN_BUILD (v6 recsys build dir), EKKO
#   (avg | peak), LOADGEN; optional SEED (20261016), UPD_FILE / QRY_FILE (names in D; default the day-23 slices of
#   builds/recsys-inputs/1),
#   ROUNDS (3), FIXED (1; 0 = no fixed-load window), XT (server lifetime bound, s, default 28800),
#   SYSTEMS (subset of "hw pop mg", seeded order kept), L_FROM (fixed-load-L.txt; needed when hw is not in SYSTEMS
#   and FIXED=1).
# Load once per system (recorded exception to "every run starts from the initial image"): per system one server
# lifetime (session.sh) with, in this order,
#   warmup 1 query/s + the updater, 10 s + 70 s, unmeasured (results kept, never used): after the server's own read of
#          every slot (both nodes, before READY; page MSI read first-touch faults happen there), the first T = 60 s
#          publication round (updater write faults / page MSI invalidations) and the query path's first use
#   gate   1 query/s, 60 s, no SLO abort: the lowest-load window. VALID = one step, keeps up, no errors/timeouts,
#          >= 1 query (main_util.py gate, within_slo by p95). all-HWcc: INVALID STOPs the block. page MSI / Megalon:
#          recorded with within_slo (block continues)
#   slo-r1, slo-r2, slo-r3   full MOT1 §3.3 SLO searches (PROFILE=main: warm-up 10 s, steps 3 s + 15 s, bisect 5%,
#          confirm 3 x 30 s with step-down, fill 0.7/0.8/0.9, overload 1.05/1.1/1.2), loadgen seed SEED + round
#   fixed  60 s at L = 0.5 x all-HWcc slo-r1 confirm mean (no SLO abort: the whole window is measured); breakdown.csv
#          must have the system's coherence columns (check_breakdown.py)
# System order: all-HWcc first (its gate sets the block's SLO and its slo-r1 gives every system's L),
#   then page MSI and Megalon in an order shuffled with seed = the block owner (recorded in order.txt).
# /dev/dax0.0: comsys for all-HWcc / Megalon, root:root 600 before page MSI (p-popcorn-shm.sh precheck; its teardown
# restores it). Holds workspaces/MEASUREMENT.lock; Host gate before every measurement; stops at the first MAIN STOP.
# On every exit (finish, not interruptible): stop this block's servers (session dirs and a running --preload-only via its pid file),
# tear down page MSI if loaded without "teardown PASS" (instr-on retry), /dev/dax0.0 back to root:root 600
# UNCONDITIONALLY on both VMs ("ROLLBACK FAIL" if a stat line is not root:root 600 or a recsys-server survived), unlock.
# A measurement whose stats key/file is missing stops the block with "STATS MISSING <key>" (session.sh rc 5).
# BLOCK=v1 (reports/RECSYS-V1-packet.md): validation block instead of the H1 measurements: per system one lifetime
#   with the warm-up and one fixed-load window at V1_RATE (1) query/s for V1_WINDOW_S (130 s, >= 2 rounds of T = 60 s),
#   then v1_check.py (FAIL stops) and check_breakdown.py; systems hw pop mg mgoff (mgoff = Megalon with
#   MEGALON_COH_TIMERS=0, same load, for the timer on/off comparison); no SLO search, no gate, no fixed-L window.
#   After the last lifetime (hw and mgoff present): v1_cdiff.py -> <E>/cdiff.{txt,csv}, Megalon Fig 2 C by the
#   difference method C_diff = T(mgoff) - T(hw) per op (user decision 2026-10-17); CDIFF FAIL (offered rates differ)
#   stops the block; C_diff < 0 and C_sampled > T / > C_diff are WARNs only.
#   v1.4 (reports/RECSYS-V1-packet.v1.4.md): Megalon object granularity. MG_RPO_OPT (server option name, e.g.
#   --mg-rows-per-object; empty = not passed, builds before recsys-megalon/14) is passed with MG_TABLE_N (default 0 =
#   one object per embedding table, the main configuration) to mg and mgoff, and with MG_ROW_N (default 1 = one object
#   per row, the "restructured best case" variant) to the extra system mgrow (BLOCK=v1 only; needs MG_RPO_OPT). The
#   checkers see mgrow as mg (same Megalon checks). v1 order with mgrow: hw pop mgrow mg mgoff. V1_OPFAIL_CONTINUE
#   ("<sys> ...", default empty = the user rule: every V1CHECK FAIL stops): for a listed system, a window that fails
#   ONLY operating-point checks (v1_check.py --oppoint-report rc 3: updater behind, flush overruns,
#   update_rate_sustained, rows per full round) is recorded as "V1CHECK OPFAIL" in <E>/v1-checks.txt and
#   <E>/v1-opfail.txt and the block continues; correctness / system checks still stop. Only with a user decision.
#   MG_COH_SAMPLE (default empty = Megalon's 1 in 64): MEGALON_COH_CHECK_SAMPLE for every Megalon lifetime (mg, mgoff,
#   mgrow; BLOCK v1 and h1) and v1_check.py --mg-sample (the value must reach both servers). v1.4: 1 (user decision
#   2026-10-18: time every section of the table objects, about 26 write sections per round).
# BLOCK=h1 — H1-HOOK v2 (experiments/h1/README.md "Hook contract H1-HOOK v2", reports/H1-main-packet.md v0.3 §2-§3;
#   user decisions 2026-10-18; called once per round by experiments/h1/hook.sh):
#   env H1MODE r1|cont, H1_N, H1_SEED (loadgen seed of every part), H1_MIXES "<mix>=EKKO=<avg|peak> ...", H1_SETTLE_S
#   (60 s = one publication period T), H1_PARENT_LOCK=H1-main (the lock must name owner=H1-main; never lock/unlock),
#   PRETOUCH_DIR (pretouch-gate.sh at block start and end), MEASURE_ENV_DIR (Host gate before every loadgen part),
#   EXPECT_DAX_UUID (guest precheck); r1: H1_LEVELS_CMD (prints "<L2_rate> <L1_rate>" for a mix); cont: H1_LEVELS.
#   One server lifetime holds one or two loadgen parts: <lifetime>/slo = warm-up (1 query/s, unmeasured) + the full SLO
#   search (query p95 <= 100 ms; PROFILE=main ramp/bisect, confirm 3 x 30 s, fill, overload past the knee; --start 1
#   --factor 1.5 --precision 0.05 --max-steps 20); <lifetime>/fix = settle (loadgen --warmup-s H1_SETTLE_S at the
#   L2 rate, discarded, no stats snapshot) + L2 window + L1 window (60 s each, no SLO abort). A fix-only lifetime starts
#   with the settle right after READY (no extra warm-up). The Ekko point (publish_frac, update rate) is per mix.
#   r1, per mix (mix order: shuffle seed H1-recsys-r1): hw and pop SLO-only lifetimes (order seed H1-recsys-r1-<mix>);
#     mg lifetime: slo -> "$H1_LEVELS_CMD" <mix> (non-zero = LEVELS STOP: stop, roll back) -> fix at those rates;
#     mgoff lifetime (MEGALON_COH_TIMERS=0) right after mg: fix only; hw and pop fix-only lifetimes (order seed
#     H1-recsys-r1-<mix>-fix).
#   cont (rounds 2, 3; rates = H1_LEVELS L2_rate / L1_rate of the mix), per mix (order: shuffle seed H1-recsys-r<n>):
#     hw, pop, mg in the order shuffle(seed H1-recsys-latin) rotated left by n, each one lifetime slo -> fix; the mgoff
#     lifetime (fix only) right after mg.
#   Checks per part: v1_check.py <part> <sys> --h1 (SLO part: update/operating-point checks on the passing,
#   non-overload steps only, violations elsewhere NOTE; fix part: every check over the L2+L1 span, FAIL; the settle
#   has no stats snapshot, so it is outside the window, and the v1.2.7 normalisation removes partly fed rounds) and
#   check_breakdown.py -> <lifetime>/h1-runcheck.txt (last line RUNCHECK PASS[ (NOTE: ...)]; a failed check stops).
#   <E>/h1-runs.tsv (8 columns: name system mix phase round run_dir steps lifetime), appended as parts finish;
#   <E>/order.txt before the first lifetime. Lifetime names: r1 <sys>-<mix>-slo-r1 / <sys>-<mix>-fix-r1 (hw, pop),
#   mg-<mix>-r1 (entries -slo / -fix), mgoff-<mix>-fix-r<n>; cont <sys>-<mix>-r<n> (entries -slo / -fix).
set -uo pipefail
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control X=$(cd "$(dirname "$0")" && pwd)
G=$(cd "$X/../vectordb" && pwd)/host-gate.sh PTG=$(cd "$X/../vectordb" && pwd)/pretouch-gate.sh
# Host gate before every loadgen part: H1 main (H1_MEASURE_RUN=1, experiments/h1/README.md item 8) uses
# experiments/h1/h1-gate.sh (partition check with MEASURE_PART_DIR, builds, node1 measurement CPU sets) and session.sh
# starts loadgen through scripts/host/measure-run.sh; otherwise (validation packets) host-gate.sh as before.
GATE=$G
if [ "${H1_MEASURE_RUN:-0}" = 1 ]; then
  GATE=$(cd "$X/../h1" && pwd)/h1-gate.sh
  [ -f "$GATE" ] && [ -d "${MEASURE_PART_DIR:-}" ] || { echo "SEQUENCE STOP: H1_MEASURE_RUN=1 needs experiments/h1/h1-gate.sh and MEASURE_PART_DIR"; exit 2; }
  export H1_MEASURE_RUN MEASURE_PART_DIR
fi
: "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}" "${D:?}" "${VM_PLAIN:?}" "${VM_MEG:?}" "${MEG_BUILD:?}" "${LOADGEN:?}"
: "${PLAIN_BUILD:?}"
MB=$MEG_BUILD SEED=${SEED:-20261016} ROUNDS=${ROUNDS:-3} FIXED=${FIXED:-1} XT=${XT:-28800}
BLOCK=${BLOCK:-main} V1_RATE=${V1_RATE:-1} V1_WINDOW_S=${V1_WINDOW_S:-130}
case $BLOCK in main|v1|h1) ;; *) echo "SEQUENCE STOP: BLOCK must be main, v1 or h1"; exit 2;; esac
if [ $BLOCK = h1 ]; then  # H1-HOOK v2 inputs (see the header)
  [ "${H1_PARENT_LOCK:-}" = H1-main ] || { echo "SEQUENCE STOP: BLOCK=h1 needs H1_PARENT_LOCK=H1-main"; exit 2; }
  [[ "${H1_N:-}" =~ ^[1-9]$ ]] && [[ "${H1_SEED:-}" =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: H1_N / H1_SEED"; exit 2; }
  [[ "${H1_SETTLE_S:-}" =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad H1_SETTLE_S"; exit 2; }
  : "${H1_MIXES:?}"
  case "${H1MODE:-}" in
    r1) [ "$H1_N" = 1 ] && [ -n "${H1_LEVELS_CMD:-}" ] || { echo "SEQUENCE STOP: r1 needs H1_N=1 and H1_LEVELS_CMD"; exit 2; };;
    cont) [ -f "${H1_LEVELS:-}" ] || { echo "SEQUENCE STOP: no H1_LEVELS"; exit 2; };;
    *) echo "SEQUENCE STOP: bad H1MODE (r1|cont)"; exit 2;; esac
  [ -d "${PRETOUCH_DIR:-}" ] && [ -n "${MEASURE_ENV_DIR:-}" ] && [ -n "${EXPECT_DAX_UUID:-}" ] \
    || { echo "SEQUENCE STOP: BLOCK=h1 needs PRETOUCH_DIR, MEASURE_ENV_DIR and EXPECT_DAX_UUID"; exit 2; }
  [ -z "${SYSTEMS:-}" ] || { echo "SEQUENCE STOP: SYSTEMS is not used with BLOCK=h1"; exit 2; }
  [ "${H1_MEASURE_RUN:-0}" = 1 ] || { echo "SEQUENCE STOP: BLOCK=h1 needs H1_MEASURE_RUN=1 (h1-gate.sh + measure-run.sh, README item 8)"; exit 2; }
  SEED=$H1_SEED EKKO=${EKKO:-per-mix}
else
  : "${EKKO:?}"
fi
MEGALON_BASE=${MEGALON_BASE:-$P/builds/megalon/75}
UPD_FILE=${UPD_FILE:-updates-day23-0-2M.smp} QRY_FILE=${QRY_FILE:-queries-day23-89137318-1M.smp}
T_MS=60000 SLO_PCT=95 SLO_MS=100
ekko_set() {  # <avg|peak>: PUBLISH_FRAC, EKKO_RULE and the server arguments SA of that operating point
  case $1 in
    avg) PUBLISH_FRAC=0.000513333333; EKKO_RULE="Ekko OSDI'22 average: 3.08% of rows per hour -> 0.0308/60 per T = 60 s";;
    peak) PUBLISH_FRAC=0.0043; EKKO_RULE="Ekko OSDI'22 peak: 4.3% of rows per 10 min -> 0.043/10 per T = 60 s";;
    *) return 1;;
  esac
  SA="--nodes 2 --row-div 1 --serve-threads 14 --update-threads 4 --load-threads 8 --start-timeout-ms $((XT * 1000 / 2)) --publish-frac $PUBLISH_FRAC
 --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
  SA=$(echo $SA)
}
if [ $BLOCK != h1 ]; then ekko_set "$EKKO" || { echo "SEQUENCE STOP: EKKO must be avg or peak"; exit 2; }; fi
export SLO_MS SLO_RULE="DeepRecSys ISCA'20: query p${SLO_PCT} <= ${SLO_MS} ms (MOT1 v6, user 2026-10-16)"
HOST_PLAIN=$PLAIN_BUILD/bin/recsys-server
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="RECSYS-$BLOCK-$(basename "$E")"; [ $BLOCK = h1 ] && OWNER="H1-recsys-$H1MODE-r$H1_N"
[[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || { echo "SEQUENCE STOP: bad RECV_MODE"; exit 2; }
[[ $ROUNDS =~ ^[1-9]$ ]] || { echo "SEQUENCE STOP: bad ROUNDS"; exit 2; }
# SYSTEMS (subset of "hw pop mg", default all): a rerun of some systems (the SLO is fixed; L for the fixed window
# comes from L_FROM). SLO_MS_FROM (v5) is not used: refused if set.
[ -z "${SLO_MS_FROM:-}" ] || { echo "SEQUENCE STOP: SLO_MS_FROM is a v5 option (v6 SLO is fixed)"; exit 2; }
for s in ${SYSTEMS:-hw pop mg}; do case $s in hw|pop|mg) ;; mgoff|mgrow) [ $BLOCK = v1 ] || { echo "SEQUENCE STOP: $s only with BLOCK=v1"; exit 2; };; *) echo "SEQUENCE STOP: bad SYSTEMS entry $s"; exit 2;; esac; done
# Megalon object granularity (v1.4): MG_RPO_OPT N per Megalon system; mgrow needs the option
MG_RPO_OPT=${MG_RPO_OPT:-} MG_TABLE_N=${MG_TABLE_N:-0} MG_ROW_N=${MG_ROW_N:-1} V1_OPFAIL_CONTINUE=${V1_OPFAIL_CONTINUE:-}
[[ -z "$MG_RPO_OPT" || "$MG_RPO_OPT" =~ ^--[a-z][a-z0-9-]*$ ]] || { echo "SEQUENCE STOP: bad MG_RPO_OPT"; exit 2; }
[[ "$MG_TABLE_N" =~ ^[0-9]+$ && "$MG_ROW_N" =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: bad MG_TABLE_N / MG_ROW_N"; exit 2; }
MG_COH_SAMPLE=${MG_COH_SAMPLE:-}
[[ -z "$MG_COH_SAMPLE" || "$MG_COH_SAMPLE" =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad MG_COH_SAMPLE"; exit 2; }
MGSE=${MG_COH_SAMPLE:+ ENV:MEGALON_COH_CHECK_SAMPLE=$MG_COH_SAMPLE}      # Megalon node env addition
chk_args() { case $1 in mg|mgoff|mgrow) [ -z "$MG_COH_SAMPLE" ] || echo "--mg-sample $MG_COH_SAMPLE";; esac; }   # v1_check.py extra args
[[ " ${SYSTEMS:-} " != *" mgrow "* ]] || [ -n "$MG_RPO_OPT" ] || { echo "SEQUENCE STOP: mgrow needs MG_RPO_OPT"; exit 2; }
for s in $V1_OPFAIL_CONTINUE; do case $s in hw|pop|mg|mgoff|mgrow) ;; *) echo "SEQUENCE STOP: bad V1_OPFAIL_CONTINUE entry $s"; exit 2;; esac; done
[ -z "$V1_OPFAIL_CONTINUE" ] || [ $BLOCK = v1 ] || { echo "SEQUENCE STOP: V1_OPFAIL_CONTINUE only with BLOCK=v1"; exit 2; }
mg_rpo() { [ -z "$MG_RPO_OPT" ] || echo " $MG_RPO_OPT $1"; }   # <N> -> " <opt> N" or nothing
chk_sys() { case $1 in mgrow) echo mg;; *) echo $1;; esac; }   # system name for v1_check.py
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  [ "${FIXED:-1}" = 0 ] || [ -f "${L_FROM:-}" ] || { echo "SEQUENCE STOP: SYSTEMS without hw and FIXED=1 needs L_FROM=<fixed-load-L.txt>"; exit 2; }
fi
case $FIXED in 0|1) ;; *) echo "SEQUENCE STOP: bad FIXED"; exit 2;; esac
grep -q "^megalon_build=$MEGALON_BASE$" $MB/manifest.txt || { echo "SEQUENCE STOP: $MB is not on $MEGALON_BASE"; exit 2; }
[ -x "$HOST_PLAIN" ] && [ -x "$PLAIN_BUILD/bin/recsys-rate" ] || { echo "SEQUENCE STOP: $PLAIN_BUILD is not a v6 recsys build"; exit 2; }
# Popcorn deploy bundle (v6: build >= 10, swmc_acct per-thread accounting; path and packet hash from the Popcorn
# agent's verified bundle): POP_BUILD, POP_BUNDLE_SHA (sha256 of C8/packet.sha256). Build-8 bundles are refused.
POP_BUILD=${POP_BUILD:-10} POP_BUNDLE_SHA=${POP_BUNDLE_SHA:-626f6a0eb265553aaa6efb2d67c185497121e77b8ab0ece2243a461bd4f291c6}
# default: Popcorn build 10, builds/popcorn_new/10/deploy-v1 (release 6.14.0-famfs-de-stijl+-ds-popcorn-new-10;
# sha256 of its packet.sha256 recorded 2026-10-16)
[[ $POP_BUILD =~ ^[0-9]+$ ]] && [ "$POP_BUILD" -ge 10 ] || { echo "SEQUENCE STOP: POP_BUILD must be >= 10 (Fig 2 needs swmc_acct)"; exit 2; }
[ -d "$C8" ] && [ ! -e $C8/SUPERSEDED.txt ] \
  && [ "$(sha256sum < $C8/packet.sha256 | cut -d' ' -f1)" = "$POP_BUNDLE_SHA" ] \
  && (cd $C8 && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: C8 is not the verified Popcorn build-$POP_BUILD bundle"; exit 2; }
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
LOCKF=${LOCK:-$P/workspaces/MEASUREMENT.lock}
if [ $BLOCK = h1 ]; then  # parent lock rule: H1 main holds the lock; this block never locks or unlocks
  grep -q "^owner=H1-main " "$LOCKF" 2>/dev/null || { echo "SEQUENCE STOP: lock $LOCKF not held by H1-main ($(cat "$LOCKF" 2>/dev/null))"; exit 2; }
else
  bash $G lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
fi
export LOADGEN PROFILE=main RUN_KIND=measurement STATS_OP=10 READY_TIMEOUT=$((XT / 2)) IDLE_WAIT_S=2400  # idle: an overrunning T = 60 s round may take > 10 min (Megalon)
SHMR=$E/shm-pop; PS=(K=$K8 GT=$GT8 C=$C8 R=$SHMR INIT_STATE=shared)   # per page MSI lifetime (system(): shm-<name>)
CHOWNED=0
stop_servers() {  # this block's servers only: every session dir's guest run dir + the preload pid dir
  local ip g
  for ip in "${IPS[@]}"; do
    for g in $(sed -n "s/^GRUN='\(.*\)'$/\1/p" "$E"/*/session.env 2>/dev/null) $(cat "$E"/preload-*.dir 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && $VM_PLAIN/bin/recsys-node.sh stop $g \$k; done; true" < /dev/null 2>&1 \
        | sed "s|^|$ip $g |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip "echo procs=\$($PCOUNT)" < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
# Count our servers by command line, not by comm: Megalon renames threads (e.g. "megalon-lib") and pgrep -x matches
# the main thread's comm, so a renamed server would count 0. Every server we start runs "<dir>/bin/recsys-server"
# (session nodes via recsys-node.sh under timeout, and the pop preload); the timeout wrapper matches too. The bracket
# keeps the remote shell's own command line from matching.
PCOUNT="pgrep -c -f -- '[/]bin/recsys-server( |\$)'"
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip "$PCOUNT" < /dev/null)" = 0 ] || return 1; done; }
# dax_free <tag>: no process holds /dev/dax0.0 on either VM (sudo -n fuser: rc 1 and no output = free; anything else,
# incl. sudo denied or ssh failure, counts as not free: fail closed). Output kept in <E>/fuser-<tag>-<ip>.out
dax_free() { local ip f rc ok=0
  for ip in "${IPS[@]}"; do
    f="$E/fuser-$1-$ip.out"
    $SSH comsys@$ip 'sudo -n fuser /dev/dax0.0' < /dev/null > "$f" 2>&1; rc=$?
    echo "rc=$rc" >> "$f"
    [ $rc = 1 ] && [ "$(wc -l < "$f")" = 1 ] || ok=1
  done
  return $ok; }
shm_cleanup() {  # page MSI loaded (load attempted) and no "teardown PASS" (the current page MSI lifetime's dir)
  local r=$SHMR
  [ -f "$r/load-vm0.txt" ] || return 0
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && return 0
  dax_free cleanup || { echo "CLEANUP FAILED: /dev/dax0.0 still in use or fuser not clean on a VM (see $E/fuser-cleanup-*.out); teardown not attempted (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"; return 0; }
  echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
  if ! env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; then
    if grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null; then
      env "${PS[@]}" bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
        && env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1
    fi
  fi
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
}
dax_root_all() {  # both VMs, always; fresh per-check file per VM; DAXOK=1 only if every stat line is root:root 600
  local ip f=$E/dax-root-$(date +%s%N).out
  DAXOK=1
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
      < /dev/null 2>&1 | sed "s/^/$ip /" | tee -a "$E/rollback.out" > "$f.$ip"
    [ "$(grep -o 'stat=.*' "$f.$ip")" = "stat=root:root 600" ] || DAXOK=0
  done
}
finish() {
  trap '' INT TERM HUP  # the rollback itself is not interruptible
  stop_servers; shm_cleanup
  local procs_ok=1
  servers_gone || procs_ok=0
  [ $procs_ok = 1 ] || echo "$(date -Is) ROLLBACK FAIL: a recsys-server process survived on a VM (procs != 0; see $E/rollback.out)" | tee -a "$E/rollback.out"
  dax_free rollback || echo "$(date -Is) ROLLBACK FAIL: /dev/dax0.0 in use (or fuser not clean) on a VM (see $E/fuser-rollback-*.out)" | tee -a "$E/rollback.out"
  dax_root_all
  [ $DAXOK = 1 ] && echo "$(date -Is) rollback: dax0.0 root:root 600 on both VMs" | tee -a "$E/rollback.out" \
    || echo "$(date -Is) ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see $E/rollback.out)" | tee -a "$E/rollback.out"
  [ $BLOCK = h1 ] || bash $G unlock "$OWNER"
}
trap finish EXIT
trap 'echo "$(date -Is) SEQUENCE STOP: interrupted"; exit 130' INT TERM HUP
stop() { echo "$(date -Is) MAIN STOP $*"; exit 1; }
dax_comsys() {  # before an all-HWcc / Megalon session
  local ip
  if [ $CHOWNED = 1 ]; then  # already chowned by this block: fresh stat on both VMs before the next lifetime
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/dax-stat-$ip-$(date +%s%N).out" 2>&1
      grep -qx "comsys:root 600" "$(ls -t "$E"/dax-stat-$ip-*.out | head -1)" || stop "dax0.0 on $ip is not comsys:root 600"
    done
    return 0
  fi
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip-$(date +%s).out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$(ls -t "$E"/chown-$ip-*.out | head -1)" || stop "chown $ip"
  done
}
dax_root() {  # before the page MSI lifetime (no server of ours runs then)
  servers_gone || stop "a recsys-server runs before page MSI"
  dax_free pre-shm-load || stop "/dev/dax0.0 in use before the cxl_shm load"
  [ $CHOWNED = 1 ] || return 0
  dax_root_all; CHOWNED=0
  [ $DAXOK = 1 ] || stop "dax0.0 not back to root:root 600 before page MSI"
}
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_half() { python3 $X/main_util.py half "$1"; }        # 0.5 x confirm mean of an SLO search without a note
gatechk() { python3 $X/main_util.py gate "$1" "$SLO_MS" "$SLO_PCT"; }  # validity + within the SLO (p95)
precheck() {
  local i f h files="${VM_PLAIN#/home/comsys/}/bin/recsys-server ${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh ${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml ${VM_MEG#/home/comsys/}/bin/recsys-server ${VM_MEG#/home/comsys/}/bin/recsys-node.sh ${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so ${VM_MEG#/home/comsys/}/lib/libmegalon.so ${VM_MEG#/home/comsys/}/cfg/megalon.yaml ${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml"
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$K8 MEM_MIN=60 EXPECT_DAX_UUID='${EXPECT_DAX_UUID:-}' INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || stop "precheck ${IPS[$i]}"
    for f in "${VM_PLAIN#/home/comsys/}/bin/recsys-server $HOST_PLAIN" "${VM_MEG#/home/comsys/}/bin/recsys-server $MB/bin/recsys-server" \
             "${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so $MB/lib/libmegalon-objapi.so" "${VM_MEG#/home/comsys/}/lib/libmegalon.so $MB/lib/libmegalon.so" \
             "${VM_MEG#/home/comsys/}/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/recsys-2vm.yaml" \
             "${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" "${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" \
             "${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh" "${VM_MEG#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh"; do
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" || stop "${IPS[$i]} /home/comsys/$1 != $2"
    done
  done
  (cd "$D" && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  ' MANIFEST.txt)) > "$E/inputs-check.out" 2>&1 || stop "inputs differ from $D/MANIFEST.txt"
  for f in "$UPD_FILE" "$QRY_FILE" dist_quantile.txt; do  # the inputs this block uses: listed and sha256-verified
    h=$(sed -n "s/^\([0-9a-f]\{64\}\)  $f\$/\1/p" "$D/MANIFEST.txt")
    [ -n "$h" ] || stop "$f not in $D/MANIFEST.txt"
    [ "$(sha256sum "$D/$f" | cut -d' ' -f1)" = "$h" ] || stop "$D/$f sha256 != MANIFEST"
  done
}
measure() {  # session dir, name, loadgen args... -> rc of session.sh measure
  local S=$1 n=$2; shift 2
  bash $GATE check "$E/gate-$(basename "$S")-$n.txt" || stop "host gate before $(basename "$S")/$n"
  bash $X/session.sh measure "$S" "$n" -- "$@" > "$S.$n.out" 2>&1
  local rc=$?
  tail -2 "$S.$n.out" | sed "s|^|  $(basename "$S")/$n: |"
  [ $rc = 5 ] && stop "$(basename "$S")/$n: $(grep -m1 '^STATS MISSING' "$S.$n.out") (session.sh rc 5)"
  return $rc
}
pop_setup() {  # P-popcorn-deploy §6a cycle with build POP_BUILD (init_state=shared), as pilot-run.sh, once per lifetime
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  local ip m i t
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one
    [ "$($SSH comsys@$ip "test -f $VM_PLAIN/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $VM_PLAIN/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)  # node 0 writes the initial tables through a plain mapping before coherence is enabled (no HWcc access)
  local PD=$VM_PLAIN/runs/preload-main-$(date +%s)
  echo "$PD" > "$E/preload-$NAME.dir"
  $SSH comsys@${IPS[0]} "mkdir -p $PD && CXL_REGION_CONFIG=$VM_PLAIN/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $PD/node0.pid; exec timeout $XT $VM_PLAIN/bin/recsys-server --node 0 --preload-only $SA --publish-ms $T_MS'" \
    < /dev/null > "$E/preload-$NAME.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$NAME.log"
  { grep -q "PRELOAD DONE" "$E/preload-$NAME.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || stop "enable gate"
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled" < /dev/null)
    echo "$ip recv_mode=$m instr_enabled=$i" >> "$E/recv-mode-$NAME.txt"
    [ "$m" = "$RECV_MODE" ] || stop "recv_mode on $ip = $m"
    [ "$i" = 1 ] || stop "instr enabled on $ip = $i"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || stop "status pre"
}
h1_lockchk() {  # BLOCK=h1: the parent lock must still name owner=H1-main (checked at block start and before every lifetime)
  [ $BLOCK = h1 ] || return 0
  grep -q "^owner=H1-main " "$LOCKF" 2>/dev/null || stop "lock $LOCKF not held by H1-main ($(cat "$LOCKF" 2>/dev/null))"
}
life_start() {  # <sys> <name>: prepare + session start of one server lifetime -> LS (session dir), NAME
  local s=$1 SE t0
  h1_lockchk
  NAME=$2 LS=$E/$2
  local S=$LS
  if [ $s = pop ]; then SHMR=$E/shm-$NAME; PS=(K=$K8 GT=$GT8 C=$C8 R=$SHMR INIT_STATE=shared); fi
  t0=$(date +%s)
  echo "$(date -Is) system $s start"
  case $s in
    hw) dax_comsys; SE=(SYSTEM=all-HWcc V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=$XT");;
    mg) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_TABLE_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    mgrow) dax_comsys; SE=(SYSTEM=Megalon-row V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_ROW_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    mgoff) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_TABLE_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0 ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    pop) dax_root; pop_setup
         SE=(SYSTEM=Popcorn-$RECV_MODE V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" NODE0_ARGS=--preloaded "NODE_ENV=ENV:XTIMEOUT=$XT");;
  esac
  servers_gone || stop "a recsys-server runs before $s"
  env "${SE[@]}" T_MS=$T_MS bash $X/session.sh start "$S" > "$S.start.out" 2>&1 || { tail -3 "$S.start.out"; stop "$s session start"; }
  tail -1 "$S.start.out"
  echo "$NAME prepare_wall_s=$(( $(date +%s) - t0 )) (incl. page MSI shm load + preload)" >> "$E/load-times.txt"
  sed "s/^/$NAME /" "$S/load-times.txt" >> "$E/load-times.txt"
}
life_stop() {  # <sys>: session stop, final checks, page MSI teardown (pop)
  local s=$1 S=$LS
  bash $X/session.sh stop "$S" > "$S.stop.out" 2>&1 || { tail -5 "$S.stop.out"; stop "$s session stop / final checks"; }
  tail -1 "$S.stop.out"
  if [ $s = pop ]; then
    env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status
    servers_gone || stop "servers left (page MSI teardown not attempted)"
    dax_free pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm teardown"
    env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown || stop "shm teardown"
    grep -q "teardown PASS" "$SHMR/steps.log" || stop "no teardown PASS"
  fi
  servers_gone || stop "servers left after $NAME"
}
system() {  # one server lifetime (BLOCK main / v1): <hw|pop|mg|mgoff|mgrow> [<name>]
  local s=$1 S rc g L t0 r
  t0=$(date +%s)
  life_start $s ${2:-$1}; S=$LS
  # 1) warm-up (unmeasured): 1 query/s with the updater for 70 s (>= one T = 60 s publication round)
  measure "$S" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 70 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s warm-up rc $rc"
  if [ $BLOCK = v1 ]; then  # validation window (reports/RECSYS-V1-packet.md §3)
    measure "$S" val "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$V1_RATE" \
      --step-warmup-s 5 --step-measure-s "$V1_WINDOW_S" --drain-s 10
    rc=$?
    [ $rc = 0 ] || stop "$s val rc $rc"
    if [[ " $V1_OPFAIL_CONTINUE " == *" $s "* ]]; then  # user decision only: operating-point-only FAIL -> OPFAIL, continue
      python3 $X/v1_check.py "$S/val" $(chk_sys $s) $(chk_args $s) --oppoint-report | sed "s/^\(V1CHECK [A-Z]*\) mg /\1 $s /" | tee "$S/val/v1-check.txt" | tee -a "$E/v1-checks.txt"
      if grep -q "^V1CHECK OPFAIL" "$S/val/v1-check.txt"; then
        echo "$(date -Is) MAIN NOTE $s: operating point not met (V1_OPFAIL_CONTINUE): $(cut -c1-400 "$S/val/v1-check.txt")" | tee -a "$E/v1-opfail.txt"
      else
        grep -q "^V1CHECK PASS" "$S/val/v1-check.txt" || stop "$s: $(cat "$S/val/v1-check.txt")"
      fi
    else
      python3 $X/v1_check.py "$S/val" $(chk_sys $s) $(chk_args $s) | sed "s/^\(V1CHECK [A-Z]*\) mg /\1 $s /" | tee "$S/val/v1-check.txt" | tee -a "$E/v1-checks.txt"
      grep -q "^V1CHECK PASS" "$S/val/v1-check.txt" || stop "$s: $(cat "$S/val/v1-check.txt")"
    fi
    python3 $X/check_breakdown.py "$S/val" | tee "$S/val/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s val: $(cat "$S/val/breakdown-check.txt")"
  else
  # 2) lowest load: 1 query/s, 60 s, no SLO abort
  measure "$S" gate "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates 1 \
    --step-warmup-s 3 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s gate measurement rc $rc"
  g=$(gatechk "$S/gate/loadgen/steps.jsonl")
  echo "$s gate 1 query/s: $g" | tee -a "$E/gate.txt"
  if [ $s = hw ]; then
    case "$g" in VALID*) ;; *) stop "all-HWcc lowest-load window invalid ($g)";; esac
    { echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE"; echo "all-HWcc lowest-load window: $g"; } | tee "$E/slo.txt"
  else
    case "$g" in VALID*) ;; *) echo "MAIN NOTE $s lowest-load window invalid (recorded; the block continues): $g";; esac
  fi
  [ -n "$SLO_MS" ] || stop "no block SLO"
  # 3) SLO searches (block SLO)
  for r in $(seq 1 $ROUNDS); do
    measure "$S" slo-r$r "${LGC[@]}" --opt seed=$((SEED + r)) --seed $((SEED + r)) --slo query:$SLO_PCT:$SLO_MS --raw \
      --mode slo --start 1 --factor 1.5 --precision 0.05 --max-steps 20
    rc=$?
    grep -q 'workload_finish":"ok' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null || stop "$s slo-r$r: loadgen workload finish (rc $rc)"
    if [ $rc = 1 ]; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null)
      [ -n "$note" ] || stop "$s slo-r$r: loadgen rc 1 without a note"
      echo "MAIN NOTE $s slo-r$r: $note"
    elif [ $rc != 0 ]; then stop "$s slo-r$r rc $rc"; fi
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); print(sys.argv[2], "note=%r" % s.get("note",""), "confirm_x_mean=%s sd=%s" % (c.get("x_mean"), c.get("x_sd")))' \
      "$S/slo-r$r/loadgen/summary.json" "$s slo-r$r" | tee -a "$E/slo-results.txt"
    if [ $s = hw ] && [ $r = 1 ] && [ "$FIXED" = 1 ]; then
      L=$(confirm_half "$S/slo-r1/loadgen/summary.json") || stop "no all-HWcc slo-r1 confirm result for L"
      echo "L = 0.5 x all-HWcc slo-r1 confirm mean (this block, Popcorn build $POP_BUILD, T = 60 s) = $L query/s" > "$E/fixed-load-L.txt"
    fi
  done
  # 4) fixed load L, 60 s, whole window (no SLO abort); FIXED=0 skips it (user 2026-10-16: the breakdown is taken
  #    from the SLO-search steps at the highest rate all systems ran; every step has its own stats window)
  if [ "$FIXED" = 1 ]; then
  L=$(sed -n 's/.* = \([0-9.]*\) query\/s$/\1/p' "$E/fixed-load-L.txt")
  [ -n "$L" ] || stop "no L"
  measure "$S" fixed "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$L" \
    --step-warmup-s 5 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s fixed rc $rc"
  python3 $X/check_breakdown.py "$S/fixed" | tee "$S/fixed/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s fixed: $(cat "$S/fixed/breakdown-check.txt")"
  else
  [ -s "$S/slo-r1/stats-steps.csv" ] || stop "$s slo-r1: no per-step stats (stats-steps.csv)"
  fi
  fi  # BLOCK
  life_stop $s
  echo "$(date -Is) MAIN $NAME DONE ($(( $(date +%s) - t0 )) s)"
}
# ---- H1-HOOK v2 parts (see the header) ----
h1_warmup() {  # unmeasured warm-up before an SLO part (as every earlier lifetime): 1 query/s with the updater, 70 s
  measure "$LS" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 70 --drain-s 10
  local rc=$?; [ $rc = 0 ] || stop "$NAME warm-up rc $rc"
}
h1_slo() {  # <sys>: warm-up + full SLO search -> $LS/slo
  local s=$1 rc RD=$LS/slo note=""
  h1_warmup
  measure "$LS" slo "${LGC[@]}" --opt seed=$SEED --seed $SEED --slo query:$SLO_PCT:$SLO_MS --raw \
    --mode slo --start 1 --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 20
  rc=$?
  echo "$NAME slo: loadgen seed $SEED" >> "$E/seeds.txt"
  grep -q 'workload_finish":"ok' "$RD/loadgen/summary.json" 2>/dev/null || stop "$NAME slo: loadgen workload finish (rc $rc)"
  if [ $rc = 1 ]; then
    note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$RD/loadgen/summary.json" 2>/dev/null)
    [ -n "$note" ] || stop "$NAME slo: loadgen rc 1 without a note"
    case "$note" in "confirm failed at three rates"*) ;; *) stop "$NAME slo: loadgen note '$note' (only 'confirm failed at three rates' is a NOTE)";; esac
    echo "MAIN NOTE $NAME slo: $note"
  elif [ $rc != 0 ]; then stop "$NAME slo rc $rc"; fi
  h1_check $s slo "$note"
}
h1_fix() {  # <sys> <L2 rate> <L1 rate>: settle (H1_SETTLE_S at L2, discarded) + L2 + L1 windows -> $LS/fix; H1STEPS
  local s=$1 rc RD=$LS/fix fs=$((SEED + 1))   # fix part seed = SEED + 1 (as the vector DB hook); in loadgen_args
  echo "$NAME fix: loadgen seed $fs (SLO part seed $SEED), settle $H1_SETTLE_S s at L2=$2, L1=$3" >> "$E/seeds.txt"
  measure "$LS" fix "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$2,$3" \
    --warmup-s "$H1_SETTLE_S" --step-warmup-s 5 --step-measure-s 60 --drain-s 10
  rc=$?; [ $rc = 0 ] || stop "$NAME fix rc $rc"
  H1STEPS=$(python3 -I -c 'import json,sys
st=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
m=[d for d in st if d.get("measure_s",0) > 0 and d.get("phase") == "fixed"]
r=[float(sys.argv[2]), float(sys.argv[3])]
assert len(m) == 2 and all(abs(d["offered_x"] - x) <= 1e-6 * max(1, x) for d, x in zip(m, r)), "fixed steps %s != L2,L1 %s" % ([(d["step"], d["offered_x"]) for d in m], r)
print("%d,%d" % (m[0]["step"], m[1]["step"]))' "$RD/loadgen/steps.jsonl" "$2" "$3" 2>&1) || stop "$NAME fix: $H1STEPS"
  h1_check $s fix ""
}
h1_check() {  # <sys> <part> <note>: v1_check --h1 + check_breakdown of <part>; <lifetime>/h1-runcheck.txt ends in RUNCHECK PASS
  local s=$1 r=$LS/$2 f=$LS/h1-runcheck.txt
  python3 $X/v1_check.py "$r" $s $(chk_args $s) --h1 > "$r/v1-check.txt" 2>&1
  python3 $X/check_breakdown.py "$r" > "$r/breakdown-check.txt" 2>&1
  [ -f "$f" ] || echo "# H1 per-run checks of lifetime $NAME (system $s, mix $H1_MIX, round $H1_N, seed $SEED; main-block.sh BLOCK=h1, H1-HOOK v2)" > "$f"
  sed -i '/^RUNCHECK PASS/d' "$f"
  { echo "[$2] v1_check: $(cat "$r/v1-check.txt")"; echo "[$2] check_breakdown: $(cat "$r/breakdown-check.txt")"
    echo "[$2] summary: $(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("mode=%s note=%r workload_finish=%s confirm=%s" % (s.get("mode"), s.get("note",""), s.get("workload_finish"), s.get("confirm",{}).get("x_mean")))' "$r/loadgen/summary.json" 2>&1)"
    [ -z "$3" ] || echo "[$2] NOTE: $3"
    grep -q " NOTES: " "$r/v1-check.txt" && echo "[$2] NOTE: v1_check: $(sed -n 's/.* NOTES: //p' "$r/v1-check.txt" | head -1)"
  } >> "$f"
  grep -q "^V1CHECK PASS" "$r/v1-check.txt" || stop "$NAME $2: $(cat "$r/v1-check.txt")"
  grep -q "^BREAKDOWN PASS" "$r/breakdown-check.txt" || stop "$NAME $2: $(cat "$r/breakdown-check.txt")"
  [ -s "$r/breakdown.csv" ] || stop "$NAME $2: no breakdown.csv"
  local notes; notes=$(sed -n 's/^\[[a-z]*\] NOTE: //p' "$f" | tr '\n' ';' | sed 's/;$//')
  if [ -n "$notes" ]; then echo "RUNCHECK PASS (NOTE: $notes)" >> "$f"; else echo "RUNCHECK PASS" >> "$f"; fi
}
h1_entry() {  # <name> <sys> <phase> <part> <steps> <lifetime kind>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$H1_MIX" "$3" "$H1_N" "${LS#$E/}/$4" "$5" "$6" >> "$E/h1-runs.tsv"
}

echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD)) K8=$K8 RECV_MODE=$RECV_MODE MEG_BUILD=$MB VM_PLAIN=$VM_PLAIN VM_MEG=$VM_MEG D=$D SEED=$SEED ROUNDS=$ROUNDS FIXED=$FIXED XT=$XT MG_RPO_OPT='$MG_RPO_OPT' MG_TABLE_N=$MG_TABLE_N MG_ROW_N=$MG_ROW_N V1_OPFAIL_CONTINUE='$V1_OPFAIL_CONTINUE' MG_COH_SAMPLE='$MG_COH_SAMPLE'"
[ $BLOCK = h1 ] && { bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block start"; }
precheck
# update rate for the Ekko operating point (Host compute, after the lock check and the input sha256 check in
# precheck): samples per T so that one round publishes PUBLISH_FRAC of all rows; checked against the calibration
# file builds/recsys-inputs/1/rate-frac<frac>.txt (+-2 %) when V1_EXPECT_RATE is set or BLOCK=h1
rate_for() {  # <ekko> <out file>: sets UPD_RATE and LGC for that operating point
  ekko_set "$1" || stop "bad Ekko point $1"
  nice -n 19 numactl --cpunodebind=1 --membind=1 "$PLAIN_BUILD/bin/recsys-rate" --samples "$D/$UPD_FILE" --frac $PUBLISH_FRAC \
    --t-ms $T_MS --windows 20 > "$2" || stop "recsys-rate"
  UPD_RATE=$(sed -n 's/^rate_samples_per_s=//p' "$2")
  awk -v x="$UPD_RATE" 'BEGIN{exit !(x > 0)}' || stop "bad update rate $UPD_RATE"
  local ex=${V1_EXPECT_RATE:-}
  [ $BLOCK = h1 ] && ex=$(sed -n 's/^rate_samples_per_s=//p' "$D/rate-frac$PUBLISH_FRAC.txt" 2>/dev/null)
  if [ $BLOCK = h1 ] || [ -n "$ex" ]; then
    [ -n "$ex" ] || stop "no calibration file $D/rate-frac$PUBLISH_FRAC.txt"
    awk -v x="$UPD_RATE" -v y="$ex" 'BEGIN{exit !(x >= 0.98 * y && x <= 1.02 * y)}' \
      || stop "update rate $UPD_RATE differs from the expected $ex by more than 2%"
  fi
  echo "EKKO=$1 publish_frac=$PUBLISH_FRAC update_rate=$UPD_RATE samples/s ($EKKO_RULE; $2)"
  # seq_base and wrap=1 are appended by session.sh measure (it refuses them from the caller)
  LGC=(--opt samples=$D/$UPD_FILE --opt queries=$D/$QRY_FILE
       --opt quantiles=$D/dist_quantile.txt --fixed update=$UPD_RATE --mix query=1 --x-stream query)
}
h1shuffle() { local seed=$1; shift; python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$seed" "$@"; }
h1_ekko() { case $1 in EKKO=avg) echo avg;; EKKO=peak) echo peak;; *) return 1;; esac; }
if [ $BLOCK = h1 ]; then  # H1-HOOK v2 driver (header)
  printf '# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n' > "$E/h1-runs.tsv"
  declare -A EK
  for spec in $H1_MIXES; do EK[${spec%%=*}]=$(h1_ekko "${spec#*=}") || stop "bad mix parameter $spec"; done
  mixes=$(h1shuffle H1-recsys-r$H1_N $(printf "%s\n" "${!EK[@]}" | sort))
  lv_rates() {  # <mix>: "<L2_rate> <L1_rate>" from H1_LEVELS (cont)
    awk -F'\t' -v m="$1" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
      $1 == m { print $(c["L2_rate"]), $(c["L1_rate"]); f = 1 } END { exit f ? 0 : 1 }' "$H1_LEVELS"; }
  if [ $H1MODE = cont ]; then
    base=($(h1shuffle H1-recsys-latin hw pop mg)); rot=$(( H1_N % 3 ))
    ord="${base[*]:$rot} ${base[*]:0:$rot}"; ord=$(echo $ord)
  fi
  { echo "# H1 DLRM recsys $H1MODE round $H1_N (H1-HOOK v2; loadgen seed $SEED; settle $H1_SETTLE_S s at L2; mixes: shuffle seed H1-recsys-r$H1_N)"
    echo "mixes: $mixes"; echo "H1_MIXES: $H1_MIXES"
    for m in $mixes; do
      if [ $H1MODE = r1 ]; then
        echo "$m: slo-only $(h1shuffle H1-recsys-r1-$m hw pop); mg (slo -> levels -> fix); mgoff (fix); fix-only $(h1shuffle H1-recsys-r1-$m-fix hw pop)"
      else
        echo "$m: $ord (each slo -> fix; mgoff fix right after mg; latin seed H1-recsys-latin rotated left by $rot); levels $(lv_rates $m || echo MISSING)"
      fi
    done; } | tee "$E/order.txt"
  for m in $mixes; do
    H1_MIX=$m
    if [ $H1MODE = r1 ]; then
      for s in $(h1shuffle H1-recsys-r1-$m hw pop); do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-slo-r1.txt"
        life_start $s $s-$m-slo-r1; h1_slo $s; h1_entry $NAME $s slo slo - sep; life_stop $s
      done
      rate_for ${EK[$m]} "$E/update-rate-mg-$m-r1.txt"
      life_start mg mg-$m-r1; h1_slo mg; h1_entry $NAME-slo mg slo slo - cont
      lv=$("$H1_LEVELS_CMD" $m 2> "$E/levels-cb-$m.err") || stop "LEVELS STOP $m: $(cat "$E/levels-cb-$m.err")"
      read -r l2 l1 <<< "$lv"
      awk -v a="$l2" -v b="$l1" 'BEGIN { exit !(a > 0 && b > a) }' || stop "LEVELS STOP $m: bad rates '$lv'"
      echo "levels $m: L2=$l2 L1=$l1" | tee -a "$E/levels-used.txt"
      h1_fix mg $l2 $l1; h1_entry $NAME-fix mg fix fix $H1STEPS cont; life_stop mg
      rate_for ${EK[$m]} "$E/update-rate-mgoff-$m-fix-r1.txt"
      life_start mgoff mgoff-$m-fix-r1; h1_fix mgoff $l2 $l1; h1_entry $NAME mgoff fix fix $H1STEPS sep; life_stop mgoff
      for s in $(h1shuffle H1-recsys-r1-$m-fix hw pop); do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-fix-r1.txt"
        life_start $s $s-$m-fix-r1; h1_fix $s $l2 $l1; h1_entry $NAME $s fix fix $H1STEPS sep; life_stop $s
      done
    else
      lv=$(lv_rates $m) || stop "no levels for $m in $H1_LEVELS"
      read -r l2 l1 <<< "$lv"
      awk -v a="$l2" -v b="$l1" 'BEGIN { exit !(a > 0 && b > a) }' || stop "bad levels for $m: '$lv'"
      echo "levels $m: L2=$l2 L1=$l1" | tee -a "$E/levels-used.txt"
      for s in $ord; do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-r$H1_N.txt"
        life_start $s $s-$m-r$H1_N; h1_slo $s; h1_entry $NAME-slo $s slo slo - cont
        h1_fix $s $l2 $l1; h1_entry $NAME-fix $s fix fix $H1STEPS cont; life_stop $s
        if [ $s = mg ]; then
          rate_for ${EK[$m]} "$E/update-rate-mgoff-$m-fix-r$H1_N.txt"
          life_start mgoff mgoff-$m-fix-r$H1_N; h1_fix mgoff $l2 $l1; h1_entry $NAME mgoff fix fix $H1STEPS sep; life_stop mgoff
        fi
      done
    fi
  done
  bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block end"
  echo "$(date -Is) SEQUENCE DONE H1-recsys $H1MODE r$H1_N ($(($(wc -l < "$E/h1-runs.tsv") - 1)) entries)"
  exit 0
fi
RATEF=$E/sequence-update-rate.txt
rate_for "$EKKO" "$RATEF"
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE (fixed; no all-HWcc in this block)" | tee "$E/slo.txt"
  [ -z "${L_FROM:-}" ] || { cp "$L_FROM" "$E/fixed-load-L.txt" && echo "L imported from $L_FROM: $(cat "$E/fixed-load-L.txt")"; }
fi
if [ $BLOCK = v1 ]; then ORDER="hw pop mg mgoff"; [[ " ${SYSTEMS:-} " == *" mgrow "* ]] && ORDER="hw pop mgrow mg mgoff"; else ORDER="hw $(shuffle pop mg)"; fi
echo "system order: $ORDER (all-HWcc first; page MSI / Megalon shuffled with seed $OWNER)" | tee "$E/order.txt"
if [ -n "${SYSTEMS:-}" ]; then  # subset rerun: keep the seeded order, drop the others
  O2=""; for s in $ORDER; do [[ " $SYSTEMS " == *" $s "* ]] && O2="$O2 $s"; done; ORDER=${O2# }
  echo "SYSTEMS=\"$SYSTEMS\" -> run: $ORDER" | tee -a "$E/order.txt"
fi
for s in $ORDER; do system $s; done
if [ $BLOCK = v1 ] && [ -d "$E/hw/val" ] && [ -d "$E/mgoff/val" ]; then  # Megalon C_diff = T(mgoff) - T(hw) (user 2026-10-17)
  python3 $X/v1_cdiff.py "$E" | tee "$E/cdiff.txt" | tee -a "$E/v1-checks.txt"
  grep -q "^CDIFF DONE" "$E/cdiff.txt" || stop "C_diff: $(cat "$E/cdiff.txt")"
fi
echo "$(date -Is) SEQUENCE DONE $OWNER"

#!/bin/bash
# New H2 block (vector DB VM-count scaling; user decisions 2026-10-20 22:3x, state/PROJECT.md; RUN-H2N.md): on N VMs
# (cxl_vm0..N-1 of the VM8 topology, EVERY VM 4 vCPU / 24 GB), the lifetimes of H2N_LIFETIMES in the given order,
# each one server lifetime with ONE aggregate SLO search (HSLO; experiments/eval/h3-block.sh rules): the offered TOTAL
# rate of the mix is split evenly over the N VMs (loadgen draws each search's target uniformly; the update stream's
# targets cover the N VMs, writes file per N), same SLO / ramp / confirm / overload rules as the 2-VM run sets, result =
# aggregate max under the SLO. Per step: stats snapshots of every VM (Popcorn fault counters, Megalon object counters)
# for the fault table at the result. No fixed-load windows, no CDF pass. Generalised from h3-block.sh (vector DB part):
# fixed vCPU per VM (H2N_VCPU, not a total split), the mix per lifetime, Megalon (mg; mgoff = timers off, optional),
# opcoh_check on N nodes, the CXL.mem bandwidth sampler between lock and unlock.
# Called by experiments/eval/runset-h2n.sh (never by hand in a real run).
# usage: h2n-block.sh <evidence dir (exists; empty except sequence*)>
# env: H2N_N (2..8), H2N_VCPU (4; 16 on the 2-VM topology, runset-h2n.sh H2N_TOPO=2), H2N_LIFETIMES ("<sys>:<mix>
#   ..." or "<sys>:<mix>:r<j> ..." in execution order; sys hw | pop | ds | mg | mgoff, mix u5 | u10 | u50 | u90 | u95), EVAL_RUN (k), SEED, REGION, C8 K8 GT8 RECV_MODE POP_BUNDLE_SHA, PRETOUCH_DIR (VM8-v* evidence
#   of the current QEMU lifetimes), MEASURE_ENV_DIR MEASURE_PART_DIR (h3-gate.sh), EXPECT_DAX_UUID,
#   VPLAIN PLAIN_BUILD LOADGEN X_DATA X_WRITES X_NB X_MAXIDS X_MAXW X_MAXD X_INIT_CAP, X_NA (optional: pool A size =
#   the init image's record count, conf VDB_X_NA; unset = 26990000, the 28M image, as every run before 2026-10-30),
#   Megalon (only when a lifetime is mg / mgoff): MEG_BUILD VMEG MEG_CFG MEG_LIB MG_MAXD, MG_CAPACITY (optional,
#   conf VDB_MG_CAPACITY: h1 = --max-ids 28000000 without --init-capacity, the fp32 28M cap, unset = h1 as before;
#   x = the plain layout values --max-ids X_MAXIDS --init-capacity X_INIT_CAP, for the 54M SQ8 set),
#   H2N_SLO_PART (loadgen SLO part arguments), H2N_OPCOH_STRICT (0 | 1), H2N_CXLBW (0 | 1), H2N_HOSTCPU (0 | 1)
#   De Stijl v2 (only when a lifetime is ds; systems/destijl/system.yaml): DS_C (bundle dir with p-destijl-shm.sh and
#   packet.sha256), DS_BUNDLE_SHA (sha256 of that packet.sha256), DS_K (guest release -ds-destijl-<n>: every VM of the
#   block runs it, so hw lifetimes of a ds block run on the De Stijl kernel without cxl_shm, and pop and ds never share
#   a block), DS_GT (guest tools dir: p-destijl-guest.sh, destijl.env, faultlat, cxl_region.yaml), DS_REGION (optional;
#   default config/cxl_region-destijl.yaml; replaces REGION for the whole block: the app area sits below the 16 MiB De
#   Stijl block), H2N_DS_T_US (optional staleness bound T in us for the servers, default 0 = synchronous; passed as
#   ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=<T>). ds cycle = p-destijl-shm.sh precheck / load (protocol=destijl,
#   init_state=shared, recv_mode=RECV_MODE: poll | sleep) / chown / preload (as pop) / enable / recv_mode / status, and
#   teardown after the lifetime. ds lifetimes are checked with opcoh_check.py destijl (popcorn rules + De Stijl
#   counters present, tx_timeout / protocol_error deltas 0; same H2N_OPCOH_STRICT rule as pop) and, after the
#   teardown, recv_check.py --name <lifetime> (E/recv-check-<name>.txt: recv_mode, cxl_shm v13 state, protocol, De
#   Stijl counters, receive thread, tx_timeout / protocol_error status deltas 0, per-step ds columns); a recv check FAIL
#   always stops the block (as runset-vdb.sh / runset-rs-main.sh).
# eval3 (experiment de-stijl-evaluation-run1, 2026-11-02; all optional, unset = unchanged):
#   lifetime id ds:<mix>:t<T>  a ds lifetime with its own staleness bound T us (overrides H2N_DS_T_US for it; run dir
#                       ds-<mix>-n<N>-t<T>); the T sweep of block A in one block (runset-h2n.sh H2N_DS_T_SWEEP)
#   H2N_DS_KERNEL=1     the block runs on the De Stijl kernel even without a ds lifetime (DS_* needed; an hw lifetime
#                       then uses the De Stijl region and release, as hw lifetimes inside a ds block always did)
#   H2N_DS_REPLICA_MODE off | all (default off): ds lifetimes write it with p-destijl-guest.sh replica-mode on every VM
#                       after the cxl_shm load and before the preload / enable (the kernel refuses it once a managed
#                       VMA exists); after the teardown (and in the EXIT trap) back to off. off = only checked (reads off)
#   H2N_DS_REPLICA_POOL_BYTES  /sys/kernel/swmc/destijl/replica_pool_max_bytes for an all lifetime (required with all;
#                       the 54M SQ8 index is ~53 GB > the 48 GB default); the previous value is restored after it
#   H2N_DS_REPLICA_MODE=damon (outline §6, De Stijl + DAMON): replica_mode damon + pool bound (required, >= 1 GiB; the
#                       lifetime stops when pool + 4 GiB > MemAvailable of a VM, checked before the preload and again
#                       after the enable) written directly to sysfs before the preload; after the enable one kdamond per
#                       VM (ds-damon-guest.sh start, DAMON sysfs, paddr, target = the managed CXL range of
#                       /sys/kernel/swmc/destijl/registered, scheme "replicate"); DAMON stats (scheme nr/sz
#                       tried/applied, kdamond CPU ticks, MemAvailable, replica counters) at start, every 10 s during the
#                       run (>= 1 per 15 s step; E/ds-damon-<name>.txt, join to steps.csv by time) and after it; after
#                       60 s a VM with sz_applied=0 and replica_pages=0 -> WARN + RUNLOG NOTE; kdamond stopped before the
#                       teardown (and in the EXIT trap; if that stop fails the cxl_shm teardown is skipped and left to the
#                       De Stijl rollback reboot), replica_mode back to off after the teardown.
#   H2N_DS_DAMON       (with damon, required) "sample_us=<n> aggr_us=<n> update_us=<n> min_regions=<n> max_regions=<n>
#                       min_acc=<n> quota_ms=<n> quota_bytes=<n> reset_ms=<n>" (ds-damon-guest.sh header)
#   H2N_DS_RECV_EXTRA "idle_sleep_us=<n> idle_spin_us=<n>" (either or both; default empty = module defaults 20 / 50):
#                       extra cxl_shm load parameters of the De Stijl receiver (recv_mode=sleep tier), appended to
#                       LOAD_EXTRA of every ds lifetime; after the enable the block reads both values back from
#                       /sys/module/cxl_shm/parameters on every VM (recv-mode-<name>.txt) and stops on a mismatch.
#                       Popcorn lifetimes are not affected (user 2026-11-02: receiver tuning for De Stijl only)
#   H2N_L1=1           hw / pop / ds lifetimes append ONE fixed step at L1 inside the same server lifetime (run.sh
#                       PARTS "slo l1"; loadgen --mode fixed --rates L1, H2N_L1_WARMUP_S (15) s warm-up + H2N_L1_MEASURE_S
#                       (90) s window + H2N_L1_DRAIN_S (5) s drain, no --slo: no early abort), so stats-steps.csv holds
#                       the per-step counters of every system at the same load. L1 (offered ops/s) = the LOWEST max
#                       search/s under the SLO of that mix over the mg / pop / hw rows found (confirm x_mean, confirmed
#                       True; l1_decide.py, outline rule; B1 passed only mg rows in H2N_L1_FROM) x 100 / (100 - U), as
#                       the 2026-10-30 fixed windows (h1-54m-fixed: 97.71 search/s -> 108.57 ops/s). A start-fail row,
#                       or an mg row without a confirmed max (confirm failed): L1 = the ramp start (--start of
#                       H2N_SLO_PART) and NOTHING is appended (the SLO search's first ramp step is that point). Lookup:
#                       the files of H2N_L1_FROM (space-separated globs, {MIX} {N} replaced; newest version last) and
#                       then this block's own h2n-results.tsv (an mg lifetime earlier in the same block wins). No mg row
#                       anywhere: NOTE, the lifetime runs without the step (E/l1.tsv says so). E/l1.tsv: one row per
#                       lifetime (L1, source, appended, l1 part status, achieved search/s, search p99 ms).
#   H2N_ACCURACY_EXPORT=1  <run>/accuracy-export.txt per lifetime: searches.bin (all responses, ref_w = E1 snapshot),
#                       e1.sample.bin (500 measured OK searches, compute_gt.py input), w range (w_start, next_w) per part,
#                       writes file + data dir with sha256, T, replica mode: the inputs of the offline recall@10
#                       (experiments/vectordb/urate-recall.sh / compute_gt.py), Host only after the block
# Order: lock -> [CXL.mem sampler] -> pretouch check (N VMs) -> h3 gate -> guest prechecks + install sha256 vs the Host
# builds -> dmesg baseline -> lifetimes (each: h3 gate, dax owner, [Popcorn: shm load / preload / enable / recv_mode /
# instr], run.sh part slo, checks, [teardown], dmesg check) -> pretouch check (end) -> BLOCK DONE.
# Outputs: E/h2n-results.tsv (one row per lifetime), E/<sys>-<mix>-n<N>/ (run.sh run dir with part slo/), E/cxlbw/
# (sampler: perf.csv, start/stop-epoch.txt), E/hostcpu/ (host-cpu-sampler.py: samples.csv, manifest.txt), E/block.log,
# E/rollback.out. EXIT trap as h3-block.sh (servers stopped,
# cxl_shm teardown, dax0.0 root:root 600, final dmesg check, unlock; the sampler stops itself at the unlock).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control
EV=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EV/../.." && pwd)
XV=$TREE/experiments/vectordb XK=$TREE/experiments/rocksdb
HG=$TREE/scripts/host/h3-gate.sh OPC=$TREE/workloads/vectordb/tests/opcoh_check.py
die() { echo "BLOCK STOP: $*"; exit 2; }
# H2N_BLOCK_DRY=1 (runset-h2n.sh --dry only): every check up to the evidence-dir check, then exit 0 before the lock; a
# pending artifact (per-N Megalon build / install dir / config) is reported, not fatal, in a dry start only
DRYB=${H2N_BLOCK_DRY:-0}
pending() { if [ "$DRYB" = 1 ]; then echo "BLOCK DRY NOTE: $* (a real run stops here)"; else die "$*"; fi; }
: "${H2N_N:?}" "${H2N_VCPU:?}" "${H2N_LIFETIMES:?}" "${H2N_SLO_PART:?}" "${EVAL_RUN:?}" "${SEED:?}" "${C8:?}" "${K8:?}" "${GT8:?}"
: "${RECV_MODE:?}" "${POP_BUNDLE_SHA:?}" "${PRETOUCH_DIR:?}" "${MEASURE_ENV_DIR:?}" "${MEASURE_PART_DIR:?}" "${EXPECT_DAX_UUID:?}"
: "${VPLAIN:?}" "${PLAIN_BUILD:?}" "${LOADGEN:?}" "${X_DATA:?}" "${X_WRITES:?}" "${X_NB:?}" "${X_MAXIDS:?}" "${X_MAXW:?}" "${X_MAXD:?}" "${X_INIT_CAP:?}"
N=$H2N_N VCPU=$H2N_VCPU STRICT=${H2N_OPCOH_STRICT:-0} CXLBW=${H2N_CXLBW:-0} HOSTCPU=${H2N_HOSTCPU:-0}
[[ $N =~ ^[2-8]$ ]] || die "H2N_N must be 2..8"
[[ $VCPU =~ ^[2-9]$|^[1-9][0-9]$ ]] || die "bad H2N_VCPU"
[[ $EVAL_RUN =~ ^[1-9]$ ]] && [[ $SEED =~ ^[0-9]+$ ]] || die "bad EVAL_RUN / SEED"
[[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || die "bad RECV_MODE"
[[ $STRICT =~ ^[01]$ ]] && [[ $CXLBW =~ ^[01]$ ]] && [[ $HOSTCPU =~ ^[01]$ ]] || die "bad H2N_OPCOH_STRICT / H2N_CXLBW / H2N_HOSTCPU"
[[ $X_MAXD =~ ^[1-9][0-9]*$ ]] || die "bad X_MAXD"
# lifetimes: <sys>:<mix> or <sys>:<mix>:r<j> (repeat j, runset-h2n.sh H2N_REPEATS; run dir <sys>-<mix>-n<N>-r<j>), no
# id twice
LIVES=() HASMG=0 HASPOP=0 HASDS=0 HAST=0 seen=" "
for l in $H2N_LIFETIMES; do
  s=${l%%:*} m=${l#*:} m=${m%%:*}
  [[ $l =~ ^[a-z]+:u[0-9]+(:r[1-9]|:t(0|[1-9][0-9]*))?$ ]] || die "bad lifetime id $l (<sys>:<mix>[:r<j>|:t<T us>])"
  [[ $l != *:t* ]] || [ $s = ds ] || die "lifetime $l: :t<T> only for ds"
  [[ $l != *:t* ]] || HAST=1
  case $s in hw|pop) ;; ds) HASDS=1;; mg|mgoff) HASMG=1;; *) die "bad system in $l";; esac
  case $m in u5|u10|u50|u90|u95) ;; *) die "bad mix in $l (u5 | u10 | u50 | u90 | u95)";; esac   # u10 u95: new H1 on H2N_TOPO=2
  [ $s = pop ] && HASPOP=1
  [[ $seen == *" $l "* ]] && die "lifetime $l listed twice"; seen+="$l "
  LIVES+=("$l")
done
[ ${#LIVES[@]} -ge 1 ] || die "no lifetimes"
# De Stijl v2 (ds): its own guest kernel (CONFIG_SWMC_DE_STIJL excludes Popcorn MSI), bundle, region and T
KEXP=$K8 DST=0 DSKER=${H2N_DS_KERNEL:-0}
[[ $DSKER =~ ^[01]$ ]] || die "bad H2N_DS_KERNEL ($DSKER: 0 | 1)"
[ $HASDS = 0 ] || DSKER=1
REPL=${H2N_DS_REPLICA_MODE:-off} RPOOL=${H2N_DS_REPLICA_POOL_BYTES:-} DAMONP=${H2N_DS_DAMON:-}
[[ $REPL =~ ^(off|all|damon)$ ]] || die "bad H2N_DS_REPLICA_MODE ($REPL: off | all | damon)"
[ "$REPL" != all ] || { [[ $RPOOL =~ ^[1-9][0-9]*$ ]] && [ "$RPOOL" -ge 60000000000 ]; } \
  || die "H2N_DS_REPLICA_MODE=all needs H2N_DS_REPLICA_POOL_BYTES >= 60000000000 (54M SQ8 index ~53 GB; got '$RPOOL')"
[ "$REPL" != damon ] || { [[ $RPOOL =~ ^[1-9][0-9]*$ ]] && [ "$RPOOL" -ge 1073741824 ]; } \
  || die "H2N_DS_REPLICA_MODE=damon needs H2N_DS_REPLICA_POOL_BYTES >= 1073741824 (got '$RPOOL')"
[ -z "$RPOOL" ] || [ "$REPL" != off ] || die "H2N_DS_REPLICA_POOL_BYTES without H2N_DS_REPLICA_MODE=all | damon"
[ -z "$DAMONP" ] || [ "$REPL" = damon ] || die "H2N_DS_DAMON without H2N_DS_REPLICA_MODE=damon"
DAMONARGS=
if [ "$REPL" = damon ]; then  # the 9 DAMON parameters, all required, in ds-damon-guest.sh start order
  for x in sample_us aggr_us update_us min_regions max_regions min_acc quota_ms quota_bytes reset_ms; do
    v=$(echo " $DAMONP " | sed -n "s/.* $x=\([0-9][0-9]*\) .*/\1/p")
    [ -n "$v" ] || die "H2N_DS_DAMON lacks $x=<integer> ('$DAMONP')"
    DAMONARGS+=" $v"
  done
  [ "$(echo $DAMONP | wc -w)" = 9 ] || die "H2N_DS_DAMON: exactly the 9 keys sample_us aggr_us update_us min_regions max_regions min_acc quota_ms quota_bytes reset_ms ('$DAMONP')"
  read -r -a DA <<< "$DAMONARGS"
  [ "${DA[0]}" -ge 1000 ] && [ "${DA[1]}" -ge "${DA[0]}" ] && [ "${DA[5]}" -ge 0 ] && [ "${DA[5]}" -le $(( DA[1] / DA[0] )) ] \
    && [ "${DA[3]}" -ge 3 ] && [ "${DA[4]}" -ge "${DA[3]}" ] \
    || die "H2N_DS_DAMON out of range (sample_us >= 1000, aggr_us >= sample_us, 0 <= min_acc <= aggr/sample (0: action=stat only), 3 <= min_regions <= max_regions)"
  [ -f "$EV/ds-damon-guest.sh" ] || die "missing $EV/ds-damon-guest.sh"
fi
# damon-policy-exploration keys (DESIGN workspaces/destijl-v2/damon-replication/DESIGN.md; all optional, unset = run 1)
#   H2N_DS_DAMON_EXTRA "range=index|managed action=replicate|stat min_age=<aggr> w_sz=<permil> w_acc=<permil>
#                       w_age=<permil> nice=<-20..19>" (any subset): range index = [managed start, + swcc_used_end -
#                       swcc offset) from the server's layout line (needs H2N_DS_DAMON_AT=ready); the rest are
#                       ds-damon-guest.sh start keys (its header). action=stat allows min_acc=0 (hot-set picture)
#   H2N_DS_DAMON_AT    enable (default: kdamond right after the cxl_shm enable, before the server start, as run 1) |
#                       ready (damonx-hook.sh starts it in run.sh's PART_PRE_CMD of the lifetime's first part, i.e.
#                       after READY + port check, +5 s settle; the block's 10 s sampler runs from the enable on)
#   H2N_DS_DAMON_WARMUP "rate=<ops/s> learn_s=<s> part_s=<s> max_parts=<n> min_fill_s=<s> end_pps=<pages/s> end_n=<n>
#                       fill_ms=<ms> fill_bytes=<B>" (needs ready; SLO lifetimes): parts wa wb01..wb<max_parts> before
#                       slo at the fixed total rate <rate> (loadgen --mode fixed, no --slo; wb parts without the part
#                       gate), phase A action stat, phase B replicate with quota fill_ms / fill_bytes per 1 s, end at
#                       the DESIGN §5 condition or the cap, then the 9 H2N_DS_DAMON quotas (damonx-hook.sh header)
#   H2N_DS_DAMON_REGIONS=1  the sampler also stores the scheme's tried regions every 10 s
#                       (E/ds-damon-regions-<name>-vm<i>.txt: "DAMON REGIONS t=.." + "start end nr_accesses age" lines)
DXEXTRA=${H2N_DS_DAMON_EXTRA:-} DXAT=${H2N_DS_DAMON_AT:-enable} DXWARM=${H2N_DS_DAMON_WARMUP:-} DXREG=${H2N_DS_DAMON_REGIONS:-0}
DXRANGE=managed DXSTART= DXACT=replicate
[ -z "$DXEXTRA$DXWARM" ] && [ "$DXAT" = enable ] && [ "$DXREG" = 0 ] || [ "$REPL" = damon ] || die "H2N_DS_DAMON_EXTRA / _AT / _WARMUP / _REGIONS need H2N_DS_REPLICA_MODE=damon"
[[ $DXAT =~ ^(enable|ready)$ ]] && [[ $DXREG =~ ^[01]$ ]] || die "bad H2N_DS_DAMON_AT ($DXAT: enable | ready) / H2N_DS_DAMON_REGIONS ($DXREG)"
for t in $DXEXTRA; do
  [[ $t =~ ^(range=(index|managed)|action=(replicate|stat)|min_age=[0-9]+|w_(sz|acc|age)=[0-9]+|nice=-?[0-9]+)$ ]] || die "bad H2N_DS_DAMON_EXTRA token $t"
  case $t in range=*) DXRANGE=${t#range=};; action=*) DXACT=${t#action=}; DXSTART+="${DXSTART:+ }$t";; *) DXSTART+="${DXSTART:+ }$t";; esac
done
[ "$DXRANGE" = managed ] || [ "$DXAT" = ready ] || die "range=index needs H2N_DS_DAMON_AT=ready (the layout line exists only after the server start)"
[ "$REPL" != damon ] || [ "$DXACT" = stat ] || [ "${DA[5]}" -ge 1 ] || die "min_acc 0 only with action=stat"
DXWPARTS= DXWNOGATE=
if [ -n "$DXWARM" ]; then
  [ "$DXAT" = ready ] && [ -z "${H2N_FIXED:-}" ] && [ "$DXACT" = replicate ] || die "H2N_DS_DAMON_WARMUP needs H2N_DS_DAMON_AT=ready, SLO lifetimes and action=replicate"
  for x in rate learn_s part_s max_parts min_fill_s end_pps end_n fill_ms fill_bytes; do
    [[ " $DXWARM " =~ \ $x=[0-9]+\  ]] || die "H2N_DS_DAMON_WARMUP lacks $x=<integer> ('$DXWARM')"
  done
  [ "$(echo $DXWARM | wc -w)" = 9 ] || die "H2N_DS_DAMON_WARMUP: exactly the 9 keys ('$DXWARM')"
  dxw() { echo " $DXWARM " | sed -n "s/.* $1=\([0-9][0-9]*\) .*/\1/p"; }
  [ "$(dxw max_parts)" -ge 1 ] && [ "$(dxw max_parts)" -le 99 ] && [ "$(dxw part_s)" -ge 10 ] && [ "$(dxw learn_s)" -ge 1 ] && [ "$(dxw rate)" -ge 1 ] \
    && [ "$(dxw end_n)" -ge 1 ] || die "H2N_DS_DAMON_WARMUP out of range (1 <= max_parts <= 99, part_s >= 10, learn_s >= 1, rate >= 1, end_n >= 1)"
  for i in $(seq 1 "$(dxw max_parts)"); do DXWPARTS+=" wb$(printf %02d $i)"; done
  DXWNOGATE=${DXWPARTS# }; DXWPARTS="wa$DXWPARTS"
fi
[ "$DXAT" = enable ] || [ -f "$EV/damonx-hook.sh" ] || die "missing $EV/damonx-hook.sh"
[ "$REPL" = off ] || [ $HASDS = 1 ] || echo "BLOCK NOTE: H2N_DS_REPLICA_MODE=$REPL applies to ds lifetimes only (none in this block)"
DSRX=${H2N_DS_RECV_EXTRA:-}
[[ $DSRX =~ ^((idle_sleep_us|idle_spin_us)=[0-9]+( |$))*$ ]] \
  || die "bad H2N_DS_RECV_EXTRA ($DSRX: 'idle_sleep_us=<n> idle_spin_us=<n>', either or both)"
[ -z "$DSRX" ] || [ $HASDS = 1 ] || echo "BLOCK NOTE: H2N_DS_RECV_EXTRA applies to ds lifetimes only (none in this block)"
[ $HAST = 0 ] || [ -z "${H2N_FIXED:-}" ] || die "ds:<mix>:t<T> lifetimes are SLO lifetimes (not with H2N_FIXED)"
if [ $DSKER = 1 ]; then
  [ $HASPOP = 0 ] || die "pop and ds lifetimes need different guest kernels: run them in separate blocks"
  : "${DS_C:?}" "${DS_BUNDLE_SHA:?}" "${DS_K:?}" "${DS_GT:?}"
  [[ $DS_K == *-ds-destijl-* ]] || die "DS_K=$DS_K is not a De Stijl release (-ds-destijl-<n>)"
  [[ $RECV_MODE =~ ^(poll|sleep)$ ]] || die "RECV_MODE=$RECV_MODE: De Stijl (cxl_shm v13 protocol=destijl) refuses idle"
  DST=${H2N_DS_T_US:-0}
  if [ "$DST" = @MAIN_T@ ]; then  # eval3-b2.conf before the main T is decided (block A recall): never a real run
    pending "H2N_DS_T_US is the placeholder @MAIN_T@ (main T not decided yet; fill it from block A's recall rule)"; DST=0
  fi
  [[ $DST =~ ^(0|[1-9][0-9]*)$ ]] || die "bad H2N_DS_T_US ($DST: integer us, 0 = synchronous)"
  REGION=${DS_REGION:-$TREE/config/cxl_region-destijl.yaml}   # replaces REGION for the whole block (app offset)
  KEXP=$DS_K
fi
# eval3 L1 step (H2N_L1) and accuracy export (H2N_ACCURACY_EXPORT); header block above
L1ON=${H2N_L1:-0} L1FROM=${H2N_L1_FROM:-} L1W=${H2N_L1_WARMUP_S:-15} L1M=${H2N_L1_MEASURE_S:-90} L1D=${H2N_L1_DRAIN_S:-5} ACCX=${H2N_ACCURACY_EXPORT:-0}
[[ $L1ON =~ ^[01]$ ]] && [[ $ACCX =~ ^[01]$ ]] && [[ $L1W =~ ^[0-9]+$ ]] && [[ $L1M =~ ^[1-9][0-9]*$ ]] && [[ $L1D =~ ^[0-9]+$ ]] \
  || die "bad H2N_L1 / H2N_ACCURACY_EXPORT / H2N_L1_WARMUP_S / H2N_L1_MEASURE_S / H2N_L1_DRAIN_S"
[ $L1ON = 0 ] || [ -z "${H2N_FIXED:-}" ] || die "H2N_L1 appends to SLO lifetimes (not with H2N_FIXED)"
L1START=$(echo " $H2N_SLO_PART " | sed -n 's/.* --start \([0-9.]*\) .*/\1/p')
[ $L1ON = 0 ] || [[ $L1START =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "H2N_L1: no --start <rate> in H2N_SLO_PART"
l1_resolve() {  # <mix>: sets L1V (offered ops/s | none) L1A (1 = append the step) L1S (source); l1_decide.py
  local g f out FILES=()
  for g in $L1FROM; do
    g=${g//\{MIX\}/$1}; g=${g//\{N\}/$N}
    for f in $(ls -d $g 2>/dev/null | sort -V); do FILES+=("$f"); done
  done
  FILES+=("$E/h2n-results.tsv")
  out=$(python3 -I -B "$EV/l1_decide.py" --mix "$1" --nodes "$N" --start "$L1START" "${FILES[@]}")
  IFS=$'\t' read -r L1V L1A L1S <<< "$out"
}
: "${REGION:?}"
# Fixed-window lifetimes (optional; unset = every lifetime is one SLO search, as before): H2N_FIXED = tokens
#   <sys>/<part>/<detail>/<recv>/<rates>/<warmup s>/<measure s>/<drain s>
# A lifetime of system <sys> runs the parts of its tokens in the given order (run.sh PARTS, one server lifetime;
# loadgen --mode fixed --rates <rates> --warmup-s 0 --step-warmup-s .. --step-measure-s .. --drain-s .., WITHOUT --slo:
# no SLO early abort, the queue cap stays; --raw kept). <detail> 0|1 = /sys/kernel/swmc/instr/detail on every VM for
# that part (fixed-part-hook.sh, set before and back to 0 after the part; Popcorn only), - = untouched (stays 0);
# <recv> poll|idle|sleep = cxl_shm recv_mode for that part (back to RECV_MODE after it; Popcorn only), - = RECV_MODE.
# Used by experiments knee-sweep-pilot and popcorn-writer-lock-split (lock-split.conf, knee-sweep-pilot.conf).
# <sys> may be <sys>@<mix> (knee-sweep: one rate list per (system, mix) lifetime); a lifetime <sys>:<mix> takes the
# tokens of <sys>@<mix> if any, else those of <sys>.
#   H2N_NODE_ENV_EXTRA  ENV:K=V tokens added to every node's environment (e.g. ENV:VDB_LOCK_SPLIT=1)
#   H2N_ALLOW_DETAIL    1 = m4-precheck.sh does not require instr/detail = 0 (PRECHECK_ALLOW_DETAIL; this block sets
#                       detail itself per part and restores 0); only with a detail=1 part
FIXED=${H2N_FIXED:-} NENV_X=${H2N_NODE_ENV_EXTRA:-} ALLOWDET=${H2N_ALLOW_DETAIL:-0}
declare -A FPARTS=()   # sys -> "part ..."
FDET=0
for t in $FIXED; do
  IFS=/ read -r fs fp fd fr frt fw fm fdr <<< "$t"
  [[ $fs =~ ^(hw|pop|ds|mg|mgoff)(@u[0-9]+)?$ ]] && [[ $fp =~ ^[a-z0-9]+$ ]] && [[ $fd =~ ^(0|1|-)$ ]] && [[ $fr =~ ^(poll|idle|sleep|-)$ ]] \
    && [[ $frt =~ ^[0-9.]+(,[0-9.]+)*$ ]] && [[ $fw =~ ^[0-9]+$ ]] && [[ $fm =~ ^[1-9][0-9]*$ ]] && [[ $fdr =~ ^[0-9]+$ ]] \
    || die "bad H2N_FIXED token $t (<sys>/<part>/<0|1|->/<poll|idle|sleep|->/<rates>/<warmup>/<measure>/<drain>)"
  [ ${fs%%@*} = pop ] || [ "$fd:$fr" = "-:-" ] || die "H2N_FIXED $t: detail / recv_mode only for pop"
  [[ " ${FPARTS[$fs]:-} " == *" $fp "* ]] && die "H2N_FIXED: part $fp twice for $fs"
  [ "$fd" = 1 ] && FDET=1
  FPARTS[$fs]="${FPARTS[$fs]:-}${FPARTS[$fs]:+ }$fp"
done
fkey() {  # <sys> <mix>: the H2N_FIXED key of a lifetime (<sys>@<mix> if it has tokens, else <sys>)
  if [ -n "${FPARTS[$1@$2]:-}" ]; then echo "$1@$2"; else echo "$1"; fi
}
if [ -n "$FIXED" ]; then
  for l in "${LIVES[@]}"; do lm=${l#*:}; lm=${lm%%:*}; [ -n "${FPARTS[$(fkey ${l%%:*} $lm)]:-}" ] || die "H2N_FIXED has no part for lifetime $l"; done
  [ $FDET = 0 ] || [ "$ALLOWDET" = 1 ] || die "H2N_FIXED has a detail=1 part: H2N_ALLOW_DETAIL=1 needed (approved scope)"
fi
[[ $ALLOWDET =~ ^[01]$ ]] || die "bad H2N_ALLOW_DETAIL"
[ -z "$NENV_X" ] || [[ $NENV_X =~ ^(ENV:[A-Z_][A-Z0-9_]*=[^[:space:]]*( |$))+$ ]] || die "bad H2N_NODE_ENV_EXTRA ($NENV_X)"
if [ $DSKER = 1 ]; then  # the De Stijl bundle instead of the Popcorn one (no pop lifetime in a ds block)
  [ -f "$REGION" ] && [ -f "$DS_C/p-destijl-shm.sh" ] && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -c1-64)" = "$DS_BUNDLE_SHA" ] \
    && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) || die "REGION ($REGION) or the De Stijl bundle ($DS_C) does not verify"
else
[ -f "$REGION" ] && [ "$(sha256sum < "$C8/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] \
  && (cd "$C8" && sha256sum -c --quiet packet.sha256) || die "REGION or the Popcorn bundle ($C8) does not verify"
fi
IPS=() DOMS=()
for k in $(seq 0 $((N - 1))); do IPS+=(192.168.122.$((100 + k))); DOMS+=(cxl_vm$k); done
export NODES="${IPS[*]}" VM_DOMAINS="${DOMS[*]}" POP_IPS="${IPS[*]}" EXPECT_RUNNING="${DOMS[*]}"
export MEASURE_ENV_DIR MEASURE_PART_DIR H1_MEASURE_RUN=1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
# SQ8 overlay (h2n-sq8.conf; user decision 2026-10-21): H2N_VEC_FORMAT (fp32 | sq8; sq8 adds --vec-format sq8 to every
# system's server arguments), H2N_EF (query ef), H2N_INIT (guest init dir on vm0), H2N_HOST_IMAGE (Host copy of it,
# SHA256SUMS checked against the guest's). Unset = the fp32 values every h2n run before SQ8 used.
INIT=${H2N_INIT:-/home/comsys/vdb/init/seg32c32m-a27m} NA=${X_NA:-26990000} HOST_IMAGE=${H2N_HOST_IMAGE:-$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1}
VF=${H2N_VEC_FORMAT:-fp32} EF=${H2N_EF:-32} MGCAP=${MG_CAPACITY:-h1}
[[ $VF =~ ^(fp32|sq8)$ ]] && [[ $EF =~ ^[1-9][0-9]*$ ]] || die "bad H2N_VEC_FORMAT / H2N_EF ($VF, $EF)"
[[ $NA =~ ^[1-9][0-9]*$ ]] || die "bad X_NA ($NA)"
[[ $MGCAP =~ ^(h1|x)$ ]] || die "bad MG_CAPACITY ($MGCAP: h1 | x)"
# H2N_SEARCH_THREADS (ef-bandwidth, 2026-10-28): search threads per VM instead of vCPU - 1 (core scaling at the
# application level, the VM keeps its vCPUs); 1 .. vCPU - 1. Unset = vCPU - 1 as every run before.
ST=${H2N_SEARCH_THREADS:-$((VCPU - 1))}
[[ $ST =~ ^[1-9][0-9]*$ ]] && [ "$ST" -le $((VCPU - 1)) ] || die "bad H2N_SEARCH_THREADS ($ST: 1 .. vCPU - 1 = $((VCPU - 1)))"
[ -f "$HOST_IMAGE/SHA256SUMS" ] && [ -f "$HOST_IMAGE/manifest.txt" ] || die "Host init image $HOST_IMAGE has no SHA256SUMS / manifest.txt"
if [ $VF = sq8 ]; then grep -qx "vec_format sq8" "$HOST_IMAGE/manifest.txt" && [ -f "$HOST_IMAGE/sq8.bin" ] || die "$HOST_IMAGE is not an sq8 image"
else ! grep -qx "vec_format sq8" "$HOST_IMAGE/manifest.txt" || die "$HOST_IMAGE is an sq8 image (H2N_VEC_FORMAT=fp32)"; fi
VFSA=; [ $VF = fp32 ] || VFSA=" --vec-format $VF"
PAT='[/]bin/vdb-server( |$)'
COMMON_SA="--nodes $N --segments 32 --M 16 --efc 128 --ef $EF --search-threads $ST --wait-timeout-ms 60000 --start-timeout-ms 5400000$VFSA"
# plain backend (all-HWcc, Popcorn): 28m-x capacity, delete log per node X_MAXD (h2n_layout.py: total constant over N)
SA="$COMMON_SA --max-writes $X_MAXW --max-ids $X_MAXIDS --max-deletes $X_MAXD --init-capacity $X_INIT_CAP"
HOSTSRV=$PLAIN_BUILD/bin/vdb-server
[ -x "$HOSTSRV" ] || die "missing $HOSTSRV"
[ -x "$LOADGEN" ] || die "missing $LOADGEN"
# targets of the writes file must cover exactly the N VMs (one writer per VM receives updates)
python3 -I -B - "$X_WRITES" "$N" <<'PY' || die "writes file $X_WRITES does not target exactly $N VMs"
import sys, numpy as np
w = np.memmap(sys.argv[1], dtype=np.dtype([("op", "u1"), ("target", "u1"), ("p", "u1", 22)]), mode="r")
t = np.unique(w["target"])  # the whole file (verifier review v1 L8)
sys.exit(0 if list(t) == list(range(int(sys.argv[2]))) else 1)
PY
INSTALL="${VPLAIN#/home/comsys/}/bin/vdb-server $HOSTSRV
${VPLAIN#/home/comsys/}/bin/vdb-node.sh $TREE/scripts/guest/vdb-node.sh
${VPLAIN#/home/comsys/}/cfg/cxl_region.yaml $REGION"
# shellcheck disable=SC2086
APP=$("$HOSTSRV" $SA --print-app-bytes) || die "print-app-bytes ($HOSTSRV, --nodes $N)"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
[ $((APP + RING)) -lt 268435456 ] || die "app HWcc $APP B + ring $RING B exceed the 256 MiB HWcc budget at N = $N"
# SWcc fit of the plain layout at this N and X_MAXD (backend.h formulas; the server's own fits() check runs at start)
LAYOUT=$(python3 -I -B "$EV/h2n_layout.py" --vec-format $VF --max-ids "$X_MAXIDS" --check "$N" "$X_MAXD") || die "h2n_layout.py: $LAYOUT"
MGSA= MGINSTALL= MGAPP=-
if [ $HASMG = 1 ]; then
  : "${MEG_BUILD:?}" "${VMEG:?}" "${MEG_CFG:?}" "${MEG_LIB:?}" "${MG_MAXD:?}"
  # MG_CAPACITY (conf VDB_MG_CAPACITY): h1 (m4-run.sh X_MEGALON_H1CAP=1) = 28M capacity, no --init-capacity (the
  # fp32 28M image's own capacity: 28m-x did not fit Megalon's arena in fp32); x = the plain layout values (SQ8 54M
  # set: --max-ids X_MAXIDS --init-capacity X_INIT_CAP, the image's init capacity). Delete log per node MG_MAXD.
  case $MGCAP in
    h1) MGSA="--backend megalon $COMMON_SA --max-writes 2097152 --max-ids 28000000 --max-deletes $MG_MAXD";;
    x)  MGSA="--backend megalon $COMMON_SA --max-writes 2097152 --max-ids $X_MAXIDS --max-deletes $MG_MAXD --init-capacity $X_INIT_CAP";;
  esac
  MGOK=1
  for f in "$MEG_BUILD/bin/vdb-server" "$MEG_BUILD/manifest.txt" "$MEG_CFG" "$MEG_LIB/manifest.txt"; do
    [ -f "$f" ] || { MGOK=0; pending "Megalon input missing for N = $N: $f (megalon-n agent)"; }
  done
  [[ $VMEG == /home/comsys/* ]] || { MGOK=0; pending "Megalon guest dir for N = $N is not set (VMEG=$VMEG)"; }
  if [ $MGOK = 1 ]; then
    grep -qx "megalon_build=$MEG_LIB" "$MEG_BUILD/manifest.txt" || die "$MEG_BUILD is not on $MEG_LIB"
    grep -q "^shim_kind=shared$" "$MEG_BUILD/manifest.txt" || die "$MEG_BUILD has no shared (v3) shim"
    for c in constants_h_LOGICAL_NODE_NUM constants_rs_LOGICAL_NODE_NUM; do
      grep -qx "$c=$N" "$MEG_LIB/manifest.txt" || die "$MEG_LIB: $c != $N (Megalon must be built for N nodes)"
    done
    # shellcheck disable=SC2086
    MGAPP=$("$MEG_BUILD/bin/vdb-server" $MGSA --print-app-bytes) || die "print-app-bytes (Megalon, --nodes $N)"
    VM=${VMEG#/home/comsys/}
    MGINSTALL="$VM/bin/vdb-server $MEG_BUILD/bin/vdb-server
$VM/bin/vdb-node.sh $TREE/scripts/guest/vdb-node.sh
$VM/lib/libmegalon-objapi.so $MEG_BUILD/lib/libmegalon-objapi.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/lib/libtbb.so.12 $MEG_BUILD/lib/libtbb.so.12
$VM/lib/libtbbmalloc.so.2 $MEG_BUILD/lib/libtbbmalloc.so.2
$VM/lib/libhwloc.so.15 $MEG_BUILD/lib/libhwloc.so.15
$VM/lib/libatomic.so.1 $MEG_BUILD/lib/libatomic.so.1
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $REGION"
  fi
fi
SAMPLER=$EV/cxl-bw-sampler.sh   # copy of workspaces/cxl-bw/cxl-bw-sampler.sh (perf CXL CM PMU, 1 s, until unlock)
[ $CXLBW = 0 ] || [ -f "$SAMPLER" ] || die "H2N_CXLBW=1 needs $SAMPLER"
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
[ $CXLBW = 0 ] || [ "${PARANOID:-9}" -le 0 ] || echo "BLOCK NOTE: kernel.perf_event_paranoid=$PARANOID > 0: the CXL.mem sampler will refuse (recorded; the block runs without it)"
HCS=$EV/host-cpu-sampler.py   # Host CPU of each VM's QEMU emulator / vhost threads + loadgen, 1 s, until unlock (M4, L10)
[ $HOSTCPU = 0 ] || [ -f "$HCS" ] || die "H2N_HOSTCPU=1 needs $HCS"
LG_CPUS_H=56-63               # run.sh default LG_CPUS (loadgen CPUs), sampled as Host CPU busy
OWNER=eval-h2n-n$N-run$EVAL_RUN
echo "BLOCK PLAN: vec_format=$VF ef=$EF init=$INIT host_image=$HOST_IMAGE"
echo "BLOCK PLAN: h2n vdb N=$N vcpu/VM=$VCPU threads $ST+1 nodes=[${IPS[*]}] lifetimes=[${LIVES[*]}] app=$APP mg_app=$MGAPP ring=$RING cxlbw=$CXLBW hostcpu=$HOSTCPU opcoh_strict=$STRICT"
echo "BLOCK PLAN: server_args plain=[$SA]${MGSA:+ megalon=[$MGSA]}"
[ $DSKER = 0 ] || echo "BLOCK PLAN: destijl release=$DS_K bundle=$DS_C guest_tools=$DS_GT region=$REGION T=$DST us recv_mode=$RECV_MODE (node env CXL_SYSTEM=ds CXL_DESTIJL_T_US=<T>; ds:<mix>:t<T> overrides T) replica_mode=$REPL pool_bytes=${RPOOL:--}${DAMONP:+ damon=[$DAMONP] damon_guest_sha256=$(sha256sum < "$EV/ds-damon-guest.sh" | cut -c1-64)}"
[ "$REPL" != damon ] || echo "BLOCK PLAN: DAMON at=$DXAT range=$DXRANGE start_keys=[$DXSTART] regions_capture=$DXREG warmup=[${DXWARM:-none}]${DXWARM:+ warm_parts=[$DXWPARTS] nogate=[$DXWNOGATE]}$([ "$DXAT" = enable ] || echo " hook_sha256=$(sha256sum < "$EV/damonx-hook.sh" | cut -c1-64)")"
[ $L1ON = 0 ] || echo "BLOCK PLAN: L1 step on hw/pop/ds lifetimes: --mode fixed --rates <L1> ${L1W}s warm-up + ${L1M}s + ${L1D}s drain; L1 from mg-<mix>-n$N rows of [${L1FROM:-} + this block]; no mg max -> L1 = ramp start $L1START, no step"
[ $ACCX = 0 ] || echo "BLOCK PLAN: accuracy export per lifetime (<run>/accuracy-export.txt)"
echo "BLOCK PLAN: $LAYOUT"
[ -z "$FIXED" ] || echo "BLOCK PLAN: fixed windows (no SLO search) [$FIXED] node_env_extra=[$NENV_X] allow_detail=$ALLOWDET"
if [ "$DRYB" = 1 ]; then
  if [ $L1ON = 1 ]; then  # the L1 each lifetime would get from the results present now (mg lifetimes of this block not run yet)
    for l in "${LIVES[@]}"; do
      IFS=: read -r ls lm lr <<< "$l"; [[ $ls =~ ^(hw|pop|ds)$ ]] || continue
      l1_resolve "$lm"; echo "BLOCK PLAN: L1 $l: $L1V append=$L1A ($L1S)"
      [ "$L1A" != 1 ] || echo "BLOCK PLAN: L1 $l parts: PARTS='slo l1' PART_ARGS_slo='--slo search:99:100 <H2N_SLO_PART>' PART_ARGS_l1='--mode fixed --rates $L1V --warmup-s 0 --step-warmup-s $L1W --step-measure-s $L1M --drain-s $L1D'"
    done
  fi
  echo "BLOCK DRY STOP: evidence-dir check reached ($E; dry: no lock, no VM contact)"; exit 0
fi
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || die "$E missing or not empty"
# ---------------------------------------------------------------------------------------------------- real block
bash "$HG" lock "$OWNER" || die "lock"
DMESG_DONE=0 REPL_SET=0 DAMON_SET=0 DAMON_SAMPLER=
log() { echo "$(date -Is) $*" | tee -a "$E/block.log"; }
stop() { log "BLOCK STOP $*"; exit 1; }
if [ $CXLBW = 1 ]; then  # stops by itself within ~10 s of the unlock (UNTIL_UNLOCK=1); a refusal is recorded, not fatal
  setsid nohup bash "$SAMPLER" "$E/cxlbw" > "$E/cxlbw.log" 2>&1 < /dev/null &
  log "cxl-bw sampler pid $! -> $E/cxlbw (sampler sha256 $(sha256sum < "$SAMPLER" | cut -c1-16), paranoid=$PARANOID)"
fi
if [ $HOSTCPU = 1 ]; then  # read only (/proc, /run/libvirt/qemu/<dom>.pid); stops by itself ~10 s after the unlock
  setsid nohup nice -n 19 taskset -c 18-23 python3 -I -B "$HCS" "$E/hostcpu" --domains "${DOMS[*]}" --loadgen "$LOADGEN" \
    --cpus "$LG_CPUS_H" > "$E/hostcpu.log" 2>&1 < /dev/null &
  log "host-cpu sampler pid $! -> $E/hostcpu (sampler sha256 $(sha256sum < "$HCS" | cut -c1-16))"
fi
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip "pgrep -c -f -- '$PAT'" < /dev/null)" = 0 ] || return 1; done; }
dax_unused() {  # every VM: sudo -n fuser prints nothing and rc 1 (anything else = in use; fail closed)
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'f=$(sudo -n fuser /dev/dax0.0 2>&1); r=$?; echo "dax_users=[$f] rc=$r"' < /dev/null 2>&1)
    echo "$(date -Is) $1 $ip $out" >> "$E/dax-users.txt"
    [ "$out" = "dax_users=[] rc=1" ] || return 1
  done
}
dax_owner() {  # comsys | root, every VM, stat checked
  local ip out want
  for ip in "${IPS[@]}"; do
    if [ "$1" = comsys ]; then out=$($SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="comsys:root 600"
    else out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="root:root 600"; fi
    echo "$(date -Is) $ip dax0.0 -> $out" >> "$E/dax-owner.txt"
    [ "$out" = "$want" ] || return 1
  done
}
dmesg_count() { local c; c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1; [[ $c =~ ^[0-9]+$ ]] || return 1; echo "$c"; }
DMESG_BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
dmesg_check() {  # <tag>: 1 on a new bad line, an ssh failure or a wrap
  local i n c bad=0
  for i in "${!IPS[@]}"; do
    n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || { log "dmesg vm$i ($1): stored baseline '$n'"; bad=1; continue; }
    c=$(dmesg_count $i) || { log "dmesg vm$i ($1): ssh/count failed"; bad=1; continue; }
    [ "$c" -ge "$n" ] || { log "dmesg vm$i ($1): ring buffer wrapped ($n -> $c)"; bad=1; continue; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 || { bad=1; continue; }
    grep -qE "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" && { log "dmesg vm$i ($1): $(grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)"; bad=1; }
  done
  return $bad
}
shm_teardown_left() {  # every cxl_shm load of this block without "teardown PASS"
  local r
  for r in "$E"/shm-*/; do
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    dax_unused cleanup || { echo "CLEANUP FAILED: $r: /dev/dax0.0 in use, teardown not attempted (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"; continue; }
    env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
      || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
           && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
  done
  for r in "$E"/dsshm-*/; do  # De Stijl loads (ds lifetimes): same rule, p-destijl-shm.sh teardown
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    dax_unused cleanup || { echo "CLEANUP FAILED: $r: /dev/dax0.0 in use, teardown not attempted (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"; continue; }
    env K=$DS_K GT=$DS_GT C=$DS_C R=$r bash $DS_C/p-destijl-shm.sh teardown >> "$E/cleanup.out" 2>&1
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"
  done
}
finish() {
  trap '' INT TERM HUP
  set +eu
  pkill -TERM -P $$ 2>/dev/null; sleep 1
  local ip out
  for ip in "${IPS[@]}"; do  # our servers by command line (run.sh stops its own nodes in its traps)
    out=$($SSH comsys@$ip "pkill -u comsys -f -- '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f -- '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f -- '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f -- '$PAT')" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" || echo "ROLLBACK FAIL: $ip server process left (see rollback.out)" | tee -a "$E/rollback.out"
  done
  if [ $FDET = 1 ]; then  # H2N_FIXED detail=1 parts: instr/detail back to 0 on every VM (whatever state a stop left)
    for ip in "${IPS[@]}"; do
      out=$($SSH comsys@$ip "[ ! -e /sys/kernel/swmc/instr/detail ] || sudo -n sh -c 'echo 0 > /sys/kernel/swmc/instr/detail'; cat /sys/kernel/swmc/instr/detail 2>/dev/null || echo absent" < /dev/null 2>&1)
      echo "$(date -Is) $ip instr_detail=$out" >> "$E/rollback.out"
      [ "$out" = 0 ] || [ "$out" = absent ] || echo "ROLLBACK FAIL: $ip instr/detail not 0 ($out)" | tee -a "$E/rollback.out"
    done
  fi
  damon_sampler_stop
  local dmok=1
  if [ "$DAMON_SET" = 1 ]; then  # a stopped damon lifetime: kdamond off before the cxl_shm teardown
    damon_cmd rollback stop stop || { dmok=0
      echo "ROLLBACK FAIL: kdamond not stopped on a VM (see ds-damon-rollback.txt): cxl_shm teardown and replica_mode off SKIPPED (DAMON must stop before the unregister); cxl_shm stays loaded, the De Stijl rollback (VM reboot) clears it" | tee -a "$E/rollback.out"; }
  fi
  [ $dmok = 0 ] || shm_teardown_left
  if [ "$REPL_SET" = 1 ] && [ $dmok = 1 ]; then  # a stopped replicate-all / damon lifetime: replica_mode off + pool bound restored (after teardown)
    replica_set rollback off || echo "ROLLBACK FAIL: replica_mode not off / pool bound not restored on a VM (see ds-replica-rollback.txt)" | tee -a "$E/rollback.out"
  fi
  dax_unused rollback || echo "ROLLBACK FAIL: /dev/dax0.0 in use on a VM (see dax-users.txt)" | tee -a "$E/rollback.out"
  dax_owner root || echo "ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see dax-owner.txt)" | tee -a "$E/rollback.out"
  [ $DMESG_DONE = 0 ] || { dmesg_check final || echo "$(date -Is) final dmesg check: see block.log" >> "$E/rollback.out"; }
  bash "$HG" unlock "$OWNER"
}
trap finish EXIT
trap 'log "BLOCK STOP signal"; exit 130' INT TERM HUP
gate() { bash "$HG" check "$E/gate-$1.txt" > /dev/null || stop "h3 gate ($1; see gate-$1.txt)"; }
{ echo "# h2n block $OWNER: vdb N=$N vcpu/VM=$VCPU lifetimes [${LIVES[*]}] seed=$SEED recv_mode=$RECV_MODE"
  echo "nodes=${IPS[*]} domains=${DOMS[*]} server_args=[$SA] megalon_args=[$MGSA] app_hwcc=$APP mg_app_hwcc=$MGAPP ring=$RING region_sha256=$(sha256sum < "$REGION" | cut -c1-64)"
  echo "host_server=$HOSTSRV sha256=$(sha256sum < "$HOSTSRV" | cut -c1-64) loadgen=$LOADGEN sha256=$(sha256sum < "$LOADGEN" | cut -c1-64)"
  [ $HASMG = 1 ] && echo "megalon_build=$MEG_BUILD lib=$MEG_LIB cfg=$MEG_CFG sha256=$(sha256sum < "$MEG_CFG" | cut -c1-64) vmeg=$VMEG mg_max_deletes=$MG_MAXD"
  echo "writes=$X_WRITES sha256=$(sha256sum < "$X_WRITES" | cut -c1-64) max_deletes=$X_MAXD"
  echo "slo_part=[$H2N_SLO_PART]"
  [ $DSKER = 0 ] || echo "destijl: bundle=$DS_C bundle_sha=$DS_BUNDLE_SHA release=$DS_K guest_tools=$DS_GT region=$REGION t_us=$DST recv_mode=$RECV_MODE replica_mode=$REPL replica_pool_bytes=${RPOOL:--}${DAMONP:+ damon=[$DAMONP] damon_guest_sha256=$(sha256sum < "$EV/ds-damon-guest.sh" | cut -c1-64)}"
  [ "$REPL" != damon ] || echo "damon: at=$DXAT range=$DXRANGE start_keys=[$DXSTART] regions_capture=$DXREG warmup=[$DXWARM] warm_parts=[$DXWPARTS]$([ "$DXAT" = enable ] || echo " hook_sha256=$(sha256sum < "$EV/damonx-hook.sh" | cut -c1-64)")"
  [ $L1ON = 0 ] || echo "l1: from=[$L1FROM] warmup_s=$L1W measure_s=$L1M drain_s=$L1D ramp_start=$L1START"
  [ $ACCX = 0 ] || echo "accuracy_export=1"
  [ -z "$FIXED" ] || echo "fixed=[$FIXED] node_env_extra=[$NENV_X] allow_detail=$ALLOWDET (H2N_FIXED: the slo part is not run)"
  for d in "${DOMS[@]}"; do x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null); echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -c1-64) bytes=${#x}"; done
} > "$E/h2n-params.txt"
log "== PT pretouch check (start, $N VMs)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start)"
log "== H0 h3 gate"; gate H0
log "== guest prechecks (install sha256 = Host builds; guests 2..N-1 inherit vm0's files at the topology freeze)"
SUMS=$(sha256sum < "$HOST_IMAGE/SHA256SUMS" | cut -c1-64)
ALLINST=$INSTALL${MGINSTALL:+
$MGINSTALL}
for i in "${!IPS[@]}"; do
  $SSH comsys@${IPS[$i]} "PRECHECK_ALLOW_DETAIL=$ALLOWDET EXPECT_K=$KEXP EXPECT_DAX_UUID=$EXPECT_DAX_UUID INIT_DIR=$INIT INIT_SUMS=$SUMS INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) INSTALL_DIRS='$(echo "$ALLINST" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
    < $XV/m4-precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "^PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i: $(grep -m1 'PRECHECK FAIL' "$E/precheck-vm$i.txt")"
  while read -r g h; do
    grep -q "^$(sha256sum < "$h" | cut -c1-64)  /home/comsys/$g\$" "$E/precheck-vm$i.txt" || stop "vm$i /home/comsys/$g != $h (install needed on the guest)"
  done <<< "$ALLINST"
  [ "$($SSH comsys@${IPS[$i]} nproc < /dev/null)" = "$VCPU" ] || stop "vm$i nproc != $VCPU"
done
for i in "${!IPS[@]}"; do c=$(dmesg_count $i) || stop "dmesg baseline vm$i"; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
DMESG_DONE=1
printf '# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\topcoh_check\n' > "$E/h2n-results.tsv"
[ $L1ON = 0 ] || printf '# name\tsystem\tmix\tl1_offered\tappended\tl1_status\tl1_search_achieved/p99_ms\tsource\n' > "$E/l1.tsv"
echo "${LIVES[*]}" > "$E/order.txt"
OWNED=root
# ---- Popcorn cxl_shm cycle (P-popcorn-deploy §6a, init_state=shared) on the N guests -------------------------------
pop_up() {  # <name>
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$1 INIT_STATE=shared)
  [ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root before Popcorn"; OWNED=root; }
  servers_gone || stop "a server runs before the Popcorn load"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck >> "$E/block.log" 2>&1 || stop "shm precheck"
  dax_unused pre-load-$1 || stop "/dev/dax0.0 in use before the cxl_shm load"
  local ph ip m i t
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph >> "$E/block.log" 2>&1 || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "test -f $VPLAIN/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $VPLAIN/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)
  $SSH comsys@${IPS[0]} "mkdir -p $VPLAIN/runs && echo \$\$ > $VPLAIN/runs/preload-$1.pid && exec timeout -k 30 1200 env CXL_REGION_CONFIG=$VPLAIN/cfg/cxl_region.yaml $VPLAIN/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
    < /dev/null > "$E/preload-$1.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$1.log"
  { grep -q "PRELOAD DONE" "$E/preload-$1.log" && servers_gone; } || stop "preload ($1)"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable >> "$E/block.log" 2>&1 || stop "enable gate"
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled" < /dev/null)
    echo "$ip recv_mode=$m instr_enabled=$i" >> "$E/recv-mode-$1.txt"
    [ "$m" = "$RECV_MODE" ] && [ "$i" = 1 ] || stop "recv_mode / instr on $ip ($m, $i)"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1 || stop "status pre"
}
pop_down() {
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1
  servers_gone || stop "servers left (Popcorn teardown not attempted)"
  dax_unused pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm teardown"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/block.log" 2>&1 || stop "shm teardown"
}
# ---- De Stijl v2 cxl_shm cycle (protocol=destijl, init_state=shared; systems/destijl/system.yaml) on the N guests ------
# Same order and checks as pop_up: precheck, load (+ state running on every node), chown, region check, preload
# through a plain mapping (node 0), enable (syscall 470, protocol destijl), recv_mode, status.
ds_up() {  # <name>
  DSP=(K=$DS_K GT=$DS_GT C=$DS_C R=$E/dsshm-$1 INIT_STATE=shared "LOAD_EXTRA=recv_mode=$RECV_MODE${DSRX:+ ${DSRX% }}")
  [ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root before De Stijl"; OWNED=root; }
  servers_gone || stop "a server runs before the De Stijl load"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh precheck >> "$E/block.log" 2>&1 || stop "ds shm precheck"
  dax_unused pre-load-$1 || stop "/dev/dax0.0 in use before the cxl_shm (destijl) load"
  local ph ip m p i t
  for ph in load chown; do env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh $ph >> "$E/block.log" 2>&1 || stop "ds shm $ph"; done
  if [ "$REPL" != off ]; then  # before the preload / enable: no managed VMA may exist (EBUSY otherwise)
    REPL_SET=1; replica_set "$1" $REPL || stop "replica_mode $REPL / pool bound on a VM (see ds-replica-$1.txt)"
  else replica_off_check "$1" || stop "replica_mode is not off on a VM (see ds-replica-$1.txt)"; fi
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "test -f $VPLAIN/cfg/cxl_region.yaml && test -f $DS_GT/cxl_region.yaml && sha256sum $VPLAIN/cfg/cxl_region.yaml $DS_GT/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip (De Stijl tools)"
  done
  t=$(date +%s)
  $SSH comsys@${IPS[0]} "mkdir -p $VPLAIN/runs && echo \$\$ > $VPLAIN/runs/preload-$1.pid && exec timeout -k 30 1200 env CXL_REGION_CONFIG=$VPLAIN/cfg/cxl_region.yaml $VPLAIN/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
    < /dev/null > "$E/preload-$1.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$1.log"
  { grep -q "PRELOAD DONE" "$E/preload-$1.log" && servers_gone; } || stop "preload ($1)"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh enable >> "$E/block.log" 2>&1 || stop "ds enable gate"
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    p=$($SSH comsys@$ip "cat /sys/kernel/swmc/page_coherence/protocol" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled 2>/dev/null || echo absent" < /dev/null)
    t=$($SSH comsys@$ip "echo idle_sleep_us=\$(cat /sys/module/cxl_shm/parameters/idle_sleep_us 2>/dev/null || echo absent) idle_spin_us=\$(cat /sys/module/cxl_shm/parameters/idle_spin_us 2>/dev/null || echo absent)" < /dev/null)
    echo "$ip recv_mode=$m protocol=$p instr_enabled=$i $t" >> "$E/recv-mode-$1.txt"
    [ "$m" = "$RECV_MODE" ] && [ "$p" = destijl ] || stop "recv_mode / protocol on $ip ($m, $p)"
    for x in $DSRX; do [[ " $t " == *" $x "* ]] || stop "receiver parameter $x not applied on $ip ($t)"; done
  done
  env "${DSP[@]}" STATUS_TAG=pre bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1 || stop "ds status pre"
  if [ "$REPL" = damon ] && [ "$DXAT" = ready ]; then  # damonx-hook.sh starts the kdamond after READY; sampler from now
    DAMON_SET=1; damon_sampler_start "$1" 0
    log "$1: DAMON at READY (damonx-hook.sh, range $DXRANGE, keys [$DXSTART], warmup [${DXWARM:-none}]); sampler on (ds-damon-$1.txt)"
  elif [ "$REPL" = damon ]; then
    DAMON_SET=1; damon_start "$1" || stop "DAMON start on a VM (see ds-damon-$1.txt)"
  fi
}
ds_down() {  # <name>
  local ip out
  if [ "$REPL" = damon ]; then  # stats after the run, then the kdamond off before the teardown
    damon_sampler_stop
    damon_cmd "$1" post stats || log "$1 NOTE: DAMON post stats unreadable on a VM (see ds-damon-$1.txt)"
    damon_cmd "$1" stop stop || stop "DAMON stop on a VM (see ds-damon-$1.txt)"
    DAMON_SET=0
  fi
  env "${DSP[@]}" STATUS_TAG=post bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1
  if [ "$REPL" = all ]; then  # a full pool maps CXL directly (replicated and unreplicated pages mixed): recorded, NOTE
    for ip in "${IPS[@]}"; do
      out=$($SSH comsys@$ip "echo replica_pages=\$(cat /sys/kernel/swmc/destijl/replica_pages 2>/dev/null) replica_pool_full=\$(cat /sys/kernel/swmc/destijl/replica_pool_full 2>/dev/null)" < /dev/null 2>&1)
      echo "$(date -Is) $1 $ip post: $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"replica_pool_full=0"* ]] || log "$1 NOTE: $ip $out (replica pool full or unreadable: mixed replica / CXL mappings)"
    done
  fi
  servers_gone || stop "servers left (De Stijl teardown not attempted)"
  dax_unused pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm (destijl) teardown"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh teardown >> "$E/block.log" 2>&1 || stop "ds shm teardown"
  if [ "$REPL" != off ]; then replica_set "$1" off || stop "replica_mode back to off / pool bound restore (see ds-replica-$1.txt)"; REPL_SET=0; fi
}
# ---- DAMON (H2N_DS_REPLICA_MODE=damon): ds-damon-guest.sh streamed to every VM as root (sudo -n sh -s) ---------------
damon_cmd() {  # <name> <tag> <stats|stop>: on every VM; output lines in E/ds-damon-<name>.txt; 1 when a VM fails
  local ip out rc=0
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "sudo -n sh -s -- $3" < "$EV/ds-damon-guest.sh" 2>&1)
    echo "$(date -Is) $1 $2 $ip: $out" >> "$E/ds-damon-$1.txt"
    case $3 in stats) [[ $out == "DAMON STATS "* ]] || rc=1;; stop) [[ $out == "DAMON OFF"* ]] || rc=1;; esac
  done
  return $rc
}
damon_start() {  # <name>: kdamond on every VM over its managed CXL range (registered), stats sampler every 10 s
  local ip reg sp np s e out ma
  for ip in "${IPS[@]}"; do  # verifier M1: the pool bound against MemAvailable again, after the preload / enable
    out=$($SSH comsys@$ip "echo mem_available_kb=\$(awk '/^MemAvailable:/{print \$2}' /proc/meminfo)" < /dev/null 2>&1)
    ma=${out#mem_available_kb=}
    echo "$(date -Is) $1 $ip after enable: $out pool=$RPOOL" >> "$E/ds-damon-$1.txt"
    [[ $ma =~ ^[0-9]+$ ]] && [ $(( RPOOL + 4294967296 )) -le $(( ma * 1024 )) ] \
      || { echo "$(date -Is) $1 $ip STOP: pool $RPOOL + 4 GiB > MemAvailable after the enable ($out)" >> "$E/ds-damon-$1.txt"; return 1; }
  done
  for ip in "${IPS[@]}"; do
    reg=$($SSH comsys@$ip "cat /sys/kernel/swmc/destijl/registered" < /dev/null 2>&1)
    sp=$(echo "$reg" | sed -n 's/^managed_start_pfn \(0x[0-9a-f]*\)$/\1/p') np=$(echo "$reg" | sed -n 's/^managed_pages \([0-9]*\)$/\1/p')
    echo "$(date -Is) $1 $ip registered: $(echo $reg)" >> "$E/ds-damon-$1.txt"
    [ -n "$sp" ] && [ -n "$np" ] && [ "$np" -gt 0 ] || return 1
    s=$(( sp * 4096 )) e=$(( (sp + np) * 4096 ))
    out=$($SSH comsys@$ip "sudo -n sh -s -- start $s $e$DAMONARGS${DXSTART:+ $DXSTART}" < "$EV/ds-damon-guest.sh" 2>&1)
    echo "$(date -Is) $1 start $ip: $out" >> "$E/ds-damon-$1.txt"
    [[ $out == "DAMON ON "* ]] || return 1
  done
  damon_cmd "$1" pre stats || return 1
  damon_sampler_start "$1" $([ "$DXACT" = replicate ] && echo 1 || echo 0)
  log "$1: DAMON on (${#IPS[@]} VMs, params [$DAMONP], pool $RPOOL bytes; ds-damon-$1.txt)"
}
damon_sampler_start() {  # <name> <check 0|1>
  # sampler: every 10 s (< the 15 s step window: >= 1 sample per measurement step, joined to steps.csv by time;
  # verifier L2/L3); exits when the block process is gone (L6: survives no SIGKILL of the block); with check 1 one check
  # after the first 60 s (L8): a VM with sz_applied=0 and replica_pages=0 -> WARN in block.log + RUNLOG NOTE (cell ~
  # replica off); H2N_DS_DAMON_REGIONS=1: tried regions per VM appended to E/ds-damon-regions-<name>-vm<i>.txt
  local bp=$$ t0; t0=$(date +%s)
  ( trap - EXIT INT TERM HUP; chk=$((1 - $2))
    while sleep 10; do
      kill -0 $bp 2>/dev/null || exit 0
      damon_cmd "$1" run stats > /dev/null 2>&1
      if [ "$DXREG" = 1 ]; then
        for i in "${!IPS[@]}"; do
          $SSH comsys@${IPS[$i]} "sudo -n sh -s -- regions" < "$EV/ds-damon-guest.sh" >> "$E/ds-damon-regions-$1-vm$i.txt" 2>&1
        done
      fi
      if [ $chk = 0 ] && [ $(( $(date +%s) - t0 )) -ge 60 ]; then chk=1
        local ip l bad=
        for ip in "${IPS[@]}"; do
          l=$(grep " $1 run $ip: DAMON STATS " "$E/ds-damon-$1.txt" | tail -n 1)
          [[ $l == *" sz_applied=0 "* ]] && [[ $l == *" replica_pages=0"* ]] && bad+=" $ip"
          [ -n "$l" ] || bad+=" $ip(no-stats)"
        done
        if [ -n "$bad" ]; then
          log "$1 WARN: DAMON after 60 s: sz_applied=0 and replica_pages=0 on$bad (the cell measures ~replica off; ds-damon-$1.txt)"
          printf '%s | de-stijl-evaluation-run1 h2n NOTE: %s DAMON inactive after 60 s on%s (sz_applied=0, replica_pages=0; cell ~ replica off; %s)\n' \
            "$(date '+%Y-%m-%d %H:%M KST')" "$1" "$bad" "$E/ds-damon-$1.txt" >> $P/state/RUNLOG.md
        else log "$1: DAMON active after 60 s on every VM (ds-damon-$1.txt)"; fi
      fi
    done ) &
  DAMON_SAMPLER=$!
}
damon_sampler_stop() { [ -z "${DAMON_SAMPLER:-}" ] || { kill "$DAMON_SAMPLER" 2>/dev/null; wait "$DAMON_SAMPLER" 2>/dev/null; DAMON_SAMPLER=; }; }
sys_up() {  # <sys> <name>: dax owner (hw, mg, mgoff: comsys) + Popcorn / De Stijl cycle
  case $1 in
    hw|mg|mgoff) [ $OWNED = comsys ] || { dax_owner comsys || stop "dax0.0 -> comsys"; OWNED=comsys; };;
    pop) pop_up "$2";;
    ds) ds_up "$2";;
  esac
}
sys_down() {  # <sys> <name>: Popcorn / De Stijl teardown after the lifetime (nothing for the others)
  case $1 in pop) pop_down;; ds) ds_down "$2";; esac
}
ds_recv() {  # <name>: recv_check.py on this ds lifetime (needs its teardown files and stats-steps.csv); FAIL stops
  python3 -I -B $EV/recv_check.py "$E" --mode "$RECV_MODE" --name "$1" --out "$E/recv-check-$1.txt" > /dev/null 2>&1
  local r; r=$(tail -n 1 "$E/recv-check-$1.txt" 2>/dev/null)
  log "$1: recv check: ${r:-no recv-check-$1.txt}"
  [[ $r == "RECVCHECK PASS"* ]] || stop "$1: recv check FAIL (see recv-check-$1.txt)"
}
# ---- one lifetime: run.sh (N nodes, PARTS=slo) with the H1 SLO part arguments ---------------------------------------
replica_set() {  # <name> <off|all>: replica_mode (and with all the pool bound) on every VM; read back; 1 on a failure
  # the previous pool bound of each VM is kept on the Host (E/ds-replica-pool-prev-vm<i>) and restored by "off"
  local i ip out prev D=/sys/kernel/swmc/destijl
  for i in "${!IPS[@]}"; do
    ip=${IPS[$i]}
    if [ "$2" = damon ]; then  # p-destijl-guest.sh replica-mode takes off|all only: direct sysfs write + read back
      prev=$($SSH comsys@$ip "cat $D/replica_pool_max_bytes" < /dev/null 2>/dev/null)
      [[ $prev =~ ^[0-9]+$ ]] || { echo "$(date -Is) $1 $ip pool read failed ($prev)" >> "$E/ds-replica-$1.txt"; return 1; }
      [ -f "$E/ds-replica-pool-prev-vm$i" ] || echo "$prev" > "$E/ds-replica-pool-prev-vm$i"
      out=$($SSH comsys@$ip "echo mem_available_kb=\$(awk '/^MemAvailable:/{print \$2}' /proc/meminfo)" < /dev/null 2>&1)
      local ma=${out#mem_available_kb=}
      echo "$(date -Is) $1 $ip $out pool=$RPOOL" >> "$E/ds-replica-$1.txt"
      [[ $ma =~ ^[0-9]+$ ]] && [ $(( RPOOL + 4294967296 )) -le $(( ma * 1024 )) ] \
        || { echo "$(date -Is) $1 $ip STOP: pool $RPOOL + 4 GiB > MemAvailable ($out)" >> "$E/ds-replica-$1.txt"; return 1; }
      out=$($SSH comsys@$ip "sudo -n sh -c 'echo $RPOOL > $D/replica_pool_max_bytes && echo damon > $D/replica_mode' && echo pool=\$(cat $D/replica_pool_max_bytes) mode=\$(cat $D/replica_mode) replica_pages=\$(cat $D/replica_pages)" < /dev/null 2>&1)
      echo "$(date -Is) $1 $ip set damon (pool_prev=$prev): $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"pool=$RPOOL mode=damon replica_pages=0"* ]] || return 1
    elif [ "$2" = all ]; then
      prev=$($SSH comsys@$ip "cat $D/replica_pool_max_bytes" < /dev/null 2>/dev/null)
      [[ $prev =~ ^[0-9]+$ ]] || { echo "$(date -Is) $1 $ip pool read failed ($prev)" >> "$E/ds-replica-$1.txt"; return 1; }
      [ -f "$E/ds-replica-pool-prev-vm$i" ] || echo "$prev" > "$E/ds-replica-pool-prev-vm$i"
      out=$($SSH comsys@$ip "sudo -n sh -c 'echo $RPOOL > $D/replica_pool_max_bytes' && echo pool=\$(cat $D/replica_pool_max_bytes) && sudo -n $DS_GT/p-destijl-guest.sh replica-mode all" < /dev/null 2>&1)
      echo "$(date -Is) $1 $ip set all (pool_prev=$prev): $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"pool=$RPOOL"* ]] && [[ $out == *"replica_mode OK (all"* ]] || return 1
    else
      prev=$(cat "$E/ds-replica-pool-prev-vm$i" 2>/dev/null)
      out=$($SSH comsys@$ip "[ \"\$(cat $D/replica_mode)\" = off ] || sudo -n $DS_GT/p-destijl-guest.sh replica-mode off; ${prev:+sudo -n sh -c 'echo $prev > $D/replica_pool_max_bytes'; }echo mode=\$(cat $D/replica_mode) pool=\$(cat $D/replica_pool_max_bytes)" < /dev/null 2>&1)
      echo "$(date -Is) $1 $ip set off (pool restore ${prev:--}): $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"mode=off "* ]] && { [ -z "$prev" ] || [[ $out == *"pool=$prev"* ]]; } || return 1
    fi
  done
}
replica_off_check() {  # <name>: an off lifetime needs replica_mode off on every VM (a stopped all cell may have left it)
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "cat /sys/kernel/swmc/destijl/replica_mode 2>/dev/null || echo absent" < /dev/null 2>&1)
    echo "$(date -Is) $1 $ip replica_mode=$out" >> "$E/ds-replica-$1.txt"
    [[ $out == off* ]] || [ "$out" = absent ] || return 1
  done
}
acc_export() {  # <name> <run dir> <parts> <sys> <T us>: inputs of the offline recall@10 (H2N_ACCURACY_EXPORT)
  local p f ws nw
  { echo "# accuracy export (h2n-block.sh H2N_ACCURACY_EXPORT; offline recall@10: workloads/vectordb/tools/compute_gt.py"
    echo "# --data <data> --writes <writes> --searches <part>/e1.sample.bin (or loadgen/searches.bin) --out <prefix>; Host"
    echo "# only, never while MEASUREMENT.lock exists). ref_w in searches.bin = the server's E1 snapshot of each search."
    echo "name=$1 system=$4 t_us=$5 replica_mode=$([ "$4" = ds ] && echo "$REPL" || echo -) nodes=$N vcpu=$VCPU"
    echo "data=$X_DATA sums_sha256=$(sha256sum < "$X_DATA/../SHA256SUMS" 2>/dev/null | cut -c1-64)"
    echo "writes=$X_WRITES sha256=$(sha256sum < "$X_WRITES" | cut -c1-64) na=$NA nb=$X_NB"
    for p in $3; do
      f=$2/$p/loadgen/searches.bin
      ws=$(sed -n "s/^part_$p=start .* w_start=\([0-9]*\) .*/\1/p" "$2/manifest.txt" | tail -n 1)
      nw=$(sed -n 's/^next_w=//p' "$2/$p/loadgen/vectordb.txt" 2>/dev/null)
      echo "part=$p searches=$f bytes=$(stat -c %s "$f" 2>/dev/null || echo 0) sha256=$(sha256sum < "$f" 2>/dev/null | cut -c1-64) sample=$2/$p/e1.sample.bin w_start=${ws:--} next_w=${nw:--}"
    done
  } > "$2/accuracy-export.txt"
}
vdb_life() {  # <sys> <mix> [r<j> | t<T us>]
  local s=$1 mix=$2 U=${2#u} name=$1-$2-n$N${3:+-$3} R k L RP note rc mode oc=- OPS lt=$DST src l1rc l1st=- l1x=- l1p=- l1p99=- t
  [[ ${3:-} != t* ]] || lt=${3#t}
  R=$E/$name
  local L1V=- L1A=0 L1S=- PSLO="$H2N_SLO_PART" PARTSV=slo SLOARG=(--slo search:99:100) L1X=()
  if [ $L1ON = 1 ] && [[ $s =~ ^(hw|pop|ds)$ ]]; then
    l1_resolve $mix
    if [ "$L1A" = 1 ]; then  # --slo only in the slo part: the fixed step must not abort early on the SLO
      PSLO="--slo search:99:100 $H2N_SLO_PART" PARTSV="slo l1" SLOARG=()
      L1X=("PART_ARGS_l1=--mode fixed --rates $L1V --warmup-s 0 --step-warmup-s $L1W --step-measure-s $L1M --drain-s $L1D" PART_SEED_l1=$SEED)
    fi
    log "$name: L1 $L1V append=$L1A source $L1S"
  fi
  local DXE=()   # damon-policy-exploration: DAMON at READY (+ warmup parts) for ds lifetimes (header, H2N_DS_DAMON_AT)
  if [ $s = ds ] && [ "$REPL" = damon ] && [ "$DXAT" = ready ]; then
    DXE=("PART_PRE_CMD=bash $EV/damonx-hook.sh pre" DAMONX_E=$E DAMONX_NAME=$name "DAMONX_IPS=${IPS[*]}" DAMONX_GUEST=$EV/ds-damon-guest.sh
      "DAMONX_ARGS=${DAMONARGS# }" "DAMONX_START_EXTRA=$DXSTART" DAMONX_RANGE=$DXRANGE DAMONX_POOL=$RPOOL DAMONX_V=$VPLAIN "DAMONX_WARM=$DXWARM")
    if [ -n "$DXWARM" ]; then  # wa wb01.. at the fixed rate before slo; --slo only in the slo part (no SLO abort in warmup)
      local wr wl wp
      wr=$(dxw rate) wl=$(dxw learn_s) wp=$(dxw part_s)
      [[ " $PSLO " == *" --slo "* ]] || PSLO="--slo search:99:100 $PSLO"
      SLOARG=() PARTSV="$DXWPARTS $PARTSV"
      DXE+=("PART_SKIP_CMD=bash $EV/damonx-hook.sh skip" "PART_NOGATE=$DXWNOGATE"
        "PART_ARGS_wa=--mode fixed --rates $wr --warmup-s 0 --step-warmup-s 0 --step-measure-s $wl --drain-s 0" PART_SEED_wa=$SEED)
      for p in $DXWNOGATE; do DXE+=("PART_ARGS_$p=--mode fixed --rates $wr --warmup-s 0 --step-warmup-s 0 --step-measure-s $wp --drain-s 0" PART_SEED_$p=$SEED); done
    fi
    log "$name: DAMON at READY, parts [$PARTSV]"
  fi
  local LG=(--opt data=$X_DATA --opt writes=$X_WRITES --opt k=10 --mix "update=$U,search=$((100 - U))" "${SLOARG[@]}" --x-stream search --raw)
  local RE=(V=$VPLAIN HOST_SERVER=$HOSTSRV LOADGEN=$LOADGEN INIT=$INIT READY_TIMEOUT=5400 RUN_KIND=measurement TRACE=0 STATS_OP=10
    "PARTS=$PARTSV" H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR "PART_ARGS_slo=$PSLO" PART_SEED_slo=$SEED "${L1X[@]}"
    "PART_GATE_CMD=bash $HG check" "${DXE[@]}")   # between parts: the N-VM gate (run.sh part hook), never the 2-VM h1-gate.sh
  case $s in
    hw)  RE+=(SYSTEM=all-HWcc NODE_ENV= NODE0_ENV= "SERVER_ARGS=$SA"); mode=hwcc OPS=none;;
    pop) RE+=(SYSTEM=Popcorn-$RECV_MODE NODE_ENV= NODE0_ENV= "SERVER_ARGS=$SA --preloaded"); mode=popcorn OPS=swmc_acct;;
    ds)  RE+=(SYSTEM=DeStijl-$RECV_MODE-T$lt "NODE_ENV=ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=$lt" NODE0_ENV= "SERVER_ARGS=$SA --preloaded"); mode=destijl OPS=ds;;
    mg)  RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml"
              NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-vm OPS=cohsnap;;
    mgoff) RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA"
              "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0" NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-t0 OPS=cohsnap;;
  esac
  gate $name; sys_up $s $name
  servers_gone || stop "a vdb-server runs before $name"
  log "$name: run.sh part slo ($s, $mix, N=$N)"
  env "${RE[@]}" bash $XV/run.sh "$name" "$E" -- "${LG[@]}" > "$E/$name.out" 2>&1; rc=$?
  log "$name: run.sh rc $rc: $(tail -n 1 "$E/$name.out")"
  sys_down $s $name
  servers_gone || stop "servers left after $name"
  [ -d "$R" ] || stop "$name: no run dir"
  for k in "${!IPS[@]}"; do  # clean stop, no bad record, op coherence on and error-free (m4-run.sh rules, N nodes)
    L=$R/node$k.log
    { grep -q "vdb-server: stopping" $L && [ "$(grep -c '^bad_records=0$' $L)" = 1 ]; } || stop "$name node$k: no clean stop / bad_records"
    grep -q "^vdb-server: op coherence on," $L || stop "$name node$k: op coherence not on"
    case $OPS in
      swmc_acct) grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $L || stop "$name node$k: popcorn source != swmc_acct";;
      cohsnap) grep -qE "^vdb-server: op coherence on, .*megalon cohsnap on," $L || stop "$name node$k: megalon cohsnap not on";;
      ds) [ "$lt" = 0 ] || grep -q "^vdb-server: de stijl staleness T=$lt us on " $L || stop "$name node$k: staleness T=$lt not applied";;
    esac
    { grep -qx "opcoh.read_errors=0" $L && grep -qx "opcoh.register_errors=0" $L; } || stop "$name node$k: opcoh errors"
  done
  RP=$R/slo
  [ -s $RP/loadgen/summary.json ] || stop "$name: no loadgen output"
  grep -q '"reason":"stream [a-z]* exhausted' $RP/loadgen/steps.jsonl && stop "$name: writes file exhausted"
  { grep -qx "ok_without_coh=0" $RP/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $RP/loadgen/vectordb.txt &&
    grep -qx "bad_coh_version=0" $RP/loadgen/vectordb.txt; } || stop "$name: responses without an op coherence block"
  python3 $XV/opsplit.py $RP > $RP/opsplit.log 2>&1 || stop "$name: opsplit.py (see $RP/opsplit.log)"
  # opcoh_check on all N nodes (generalised; OPCOH_NODES = N): a FAIL stops only with H2N_OPCOH_STRICT=1; warmup parts
  # that ran (H2N_DS_DAMON_WARMUP) join OPCOH_PARTS: the server's stop totals cover them (closure checks)
  local WPD= wp; for wp in $DXWPARTS; do [ ! -d "$R/$wp/loadgen" ] || WPD+="$R/$wp "; done
  OPCOH_NODES=$N OPCOH_PARTS="$WPD$RP" MEGALON_LEAN=1 OPCOH_RECORD_BYTES=$([ $VF = sq8 ] && echo 832 || echo 3136) \
    python3 $OPC $RP $mode > $RP/opcoh-check.txt 2>&1
  oc=$(grep -m1 -oE '^OPCOH_CHECK (PASS|FAIL)' $RP/opcoh-check.txt | cut -d' ' -f2); oc=${oc:-ERROR}
  if [ "$oc" != PASS ]; then
    [ $STRICT = 1 ] && stop "$name: opcoh_check $mode $oc (see $RP/opcoh-check.txt)"
    log "$name NOTE: opcoh_check $mode $oc on $N nodes (H2N_OPCOH_STRICT=0: recorded; see $RP/opcoh-check.txt)"
  fi
  [ $s != ds ] || ds_recv $name
  python3 $XV/urate_check.py $RP --writers 1 > $RP/urate-check.txt 2>&1 || true
  python3 $XV/e1_check.py --writes $X_WRITES --na $NA --nb $X_NB --searches $RP/loadgen/searches.bin --out $RP/e1 --sample 500 > /dev/null \
    || stop "$name: E1 violation (see $RP/e1.e1.txt)"
  grep -q 'workload_finish":"ok' $RP/loadgen/summary.json || stop "$name: loadgen workload finish"
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $RP/loadgen/summary.json 2>/dev/null)
  if [ -n "$note" ]; then
    # main 2026-10-21 13:3x: "the start rate already violates the SLO" is a result (no rate under the SLO at or above
    # the ramp start: the row keeps empty max/confirm values) and the block goes on; before, it stopped the block and
    # skipped every later lifetime (SQ8 run 1 N=2: mg-u90 stop -> pop u5/u50/u90 not run)
    case "$note" in
      "confirm failed at three rates; the knee is noisy (longer --confirm-s?)"|"the start rate already violates the SLO; lower --start") ;;
      *) stop "$name: loadgen note: $note";;
    esac
    log "$name NOTE: $note"
  elif [ $rc != 0 ]; then
    # with the L1 step run.sh rc also carries the l1 part's rc: the slo part's own rc decides here, the l1 part below
    src=$(sed -n 's/^part_slo_loadgen_rc=\([0-9]*\) .*/\1/p' $R/manifest.txt | tail -n 1)
    l1rc=$(sed -n 's/^part_l1_loadgen_rc=\([0-9]*\) .*/\1/p' $R/manifest.txt | tail -n 1)
    [ "$L1A" = 1 ] && [ "$src" = 0 ] && [ -n "$l1rc" ] && [ "$l1rc" != 0 ] || stop "$name: run.sh rc $rc"
  fi
  if [ "$L1A" = 1 ]; then  # the appended L1 step: same response checks; a failure is a NOTE (the SLO row stands)
    t=$R/l1 l1st=ok
    l1rc=$(sed -n 's/^part_l1_loadgen_rc=\([0-9]*\) .*/\1/p' $R/manifest.txt | tail -n 1)
    if [ ! -s $t/loadgen/summary.json ]; then l1st="no-output"
    elif [ "${l1rc:-x}" != 0 ]; then l1st="rc${l1rc:-?}"
    elif grep -q '"reason":"stream [a-z]* exhausted' $t/loadgen/steps.jsonl; then l1st="writes-exhausted"
    elif ! { grep -qx "ok_without_coh=0" $t/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $t/loadgen/vectordb.txt &&
             grep -qx "bad_coh_version=0" $t/loadgen/vectordb.txt; }; then l1st="no-coh-block"
    elif ! grep -q 'workload_finish":"ok' $t/loadgen/summary.json; then l1st="workload-finish"
    fi
    if [ -s $t/loadgen/searches.bin ]; then
      python3 $XV/e1_check.py --writes $X_WRITES --na $NA --nb $X_NB --searches $t/loadgen/searches.bin --out $t/e1 --sample 500 > /dev/null \
        || stop "$name/l1: E1 violation (see $t/e1.e1.txt)"
    fi
    python3 $XV/opsplit.py $t > $t/opsplit.log 2>&1 || log "$name/l1 NOTE: opsplit.py failed (see $t/opsplit.log)"
    OPCOH_NODES=$N OPCOH_PARTS="$WPD$RP $t" MEGALON_LEAN=1 OPCOH_RECORD_BYTES=$([ $VF = sq8 ] && echo 832 || echo 3136) \
      python3 $OPC $t $mode > $t/opcoh-check.txt 2>&1
    l1p=$(grep -m1 -oE '^OPCOH_CHECK (PASS|FAIL)' $t/opcoh-check.txt | cut -d' ' -f2); [ -n "$l1p" ] || l1p=ERROR
    read -r l1x l1p99 <<< "$(python3 -I -c 'import json,sys
d=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; d=[x for x in d if x.get("phase")=="fixed"]
s=d[-1]["streams"]["search"] if d else {}
print(s.get("achieved","-"), s.get("p99_ms","-"))' $t/loadgen/steps.jsonl 2>/dev/null || echo "- -")"
    [ "$l1st" = ok ] || log "$name NOTE: L1 step $l1st (the SLO row is kept; see $t/)"
    l1st="$l1st opcoh:$l1p"
  fi
  [ $L1ON = 0 ] || [[ ! $s =~ ^(hw|pop|ds)$ ]] || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" $s $mix "$L1V" "$L1A" "$l1st" "${l1x:--}/${l1p99:--}" "$L1S" >> "$E/l1.tsv"
  [ $ACCX = 0 ] || acc_export "$name" "$R" "$PARTSV" "$s" "$lt"
  python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); f=lambda v: "" if v is None else str(v)
print("\t".join(sys.argv[2:8] + [f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")), s.get("note",""), sys.argv[8], sys.argv[9]]))' \
    $RP/loadgen/summary.json "$name" $s $mix $U $N $VCPU "$name/slo" "$oc" >> "$E/h2n-results.tsv"
  dmesg_check $name || stop "$name: dmesg check"
}
# ---- one fixed-window lifetime (H2N_FIXED): run.sh PARTS = the system's parts, no --slo -----------------------------
# Same server arguments, node environment (+ H2N_NODE_ENV_EXTRA), Popcorn cycle and checks as vdb_life; per part
# <run>/<part>/ (loadgen, stats-steps.csv, steps.csv, opsplit, e1); detail / recv_mode per part by fixed-part-hook.sh
# (PART_PRE_CMD / PART_POST_CMD; part-hooks.txt). Result row: empty max / confirm columns, note "fixed parts ...".
vdb_fixed_life() {  # <sys> <mix>
  local s=$1 mix=$2 U=${2#u} name=$1-$2-n$N R k L p t note rc mode oc=- OPS fk parts fs fp fd fr frt fw fm fdr
  fk=$(fkey $s $mix) parts=${FPARTS[$(fkey $s $mix)]}
  R=$E/$name
  local LG=(--opt data=$X_DATA --opt writes=$X_WRITES --opt k=10 --mix "update=$U,search=$((100 - U))" --x-stream search --raw)
  local RE=(V=$VPLAIN HOST_SERVER=$HOSTSRV LOADGEN=$LOADGEN INIT=$INIT READY_TIMEOUT=5400 RUN_KIND=measurement TRACE=0 STATS_OP=10
    "PARTS=$parts" H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR "PART_GATE_CMD=bash $HG check"
    "PART_PRE_CMD=bash $EV/fixed-part-hook.sh pre $fk" "PART_POST_CMD=bash $EV/fixed-part-hook.sh post $fk")
  for t in $FIXED; do
    IFS=/ read -r fs fp fd fr frt fw fm fdr <<< "$t"
    [ "$fs" = "$fk" ] || continue
    RE+=("PART_ARGS_$fp=--mode fixed --rates $frt --warmup-s 0 --step-warmup-s $fw --step-measure-s $fm --drain-s $fdr" "PART_SEED_$fp=$SEED")
  done
  if [ $s = ds ] && [ "$REPL" = damon ] && [ "$DXAT" = ready ]; then  # DAMON at READY (E0b): damonx-hook.sh wraps fixed-part-hook.sh
    RE+=("PART_PRE_CMD=bash $EV/damonx-hook.sh pre" "PART_POST_CMD=bash $EV/damonx-hook.sh post" DAMONX_FIXED_KEY=$fk DAMONX_E=$E DAMONX_NAME=$name
      "DAMONX_IPS=${IPS[*]}" DAMONX_GUEST=$EV/ds-damon-guest.sh "DAMONX_ARGS=${DAMONARGS# }" "DAMONX_START_EXTRA=$DXSTART" DAMONX_RANGE=$DXRANGE
      DAMONX_POOL=$RPOOL DAMONX_V=$VPLAIN DAMONX_WARM=)
    log "$name: DAMON at READY (fixed parts [$parts])"
  fi
  case $s in
    hw)  RE+=(SYSTEM=all-HWcc "NODE_ENV=$NENV_X" NODE0_ENV= "SERVER_ARGS=$SA"); mode=hwcc OPS=none;;
    pop) RE+=(SYSTEM=Popcorn-$RECV_MODE "NODE_ENV=$NENV_X" NODE0_ENV= "SERVER_ARGS=$SA --preloaded"); mode=popcorn OPS=swmc_acct;;
    ds)  RE+=(SYSTEM=DeStijl-$RECV_MODE-T$DST "NODE_ENV=ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=$DST${NENV_X:+ $NENV_X}" NODE0_ENV= "SERVER_ARGS=$SA --preloaded"); mode=destijl OPS=ds;;
    mg)  RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml${NENV_X:+ $NENV_X}"
              NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-vm OPS=cohsnap;;
    mgoff) RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA"
              "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0${NENV_X:+ $NENV_X}" NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-t0 OPS=cohsnap;;
  esac
  gate $name; sys_up $s $name
  servers_gone || stop "a vdb-server runs before $name"
  log "$name: run.sh fixed parts [$parts] ($s, $mix, N=$N)"
  env "${RE[@]}" FIXED_SPEC="$FIXED" RECV_MODE=$RECV_MODE bash $XV/run.sh "$name" "$E" -- "${LG[@]}" > "$E/$name.out" 2>&1; rc=$?
  log "$name: run.sh rc $rc: $(tail -n 1 "$E/$name.out")"
  env FIXED_SPEC="$FIXED" RECV_MODE=$RECV_MODE bash $EV/fixed-part-hook.sh check $s end >>"$E/$name-hook-end.txt" 2>&1 || log "$name NOTE: detail / recv_mode not at the defaults after the lifetime (see $name-hook-end.txt; the EXIT trap restores detail)"
  sys_down $s $name
  servers_gone || stop "servers left after $name"
  [ -d "$R" ] || stop "$name: no run dir"
  [ $rc = 0 ] || stop "$name: run.sh rc $rc (a part failed; see $E/$name.out, $R/part-hooks.txt)"
  for k in "${!IPS[@]}"; do
    L=$R/node$k.log
    { grep -q "vdb-server: stopping" $L && [ "$(grep -c '^bad_records=0$' $L)" = 1 ]; } || stop "$name node$k: no clean stop / bad_records"
    grep -q "^vdb-server: op coherence on," $L || stop "$name node$k: op coherence not on"
    case $OPS in
      swmc_acct) grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $L || stop "$name node$k: popcorn source != swmc_acct";;
      cohsnap) grep -qE "^vdb-server: op coherence on, .*megalon cohsnap on," $L || stop "$name node$k: megalon cohsnap not on";;
      ds) [ "$DST" = 0 ] || grep -q "^vdb-server: de stijl staleness T=$DST us on " $L || stop "$name node$k: staleness T=$DST not applied";;
    esac
    { grep -qx "opcoh.read_errors=0" $L && grep -qx "opcoh.register_errors=0" $L; } || stop "$name node$k: opcoh errors"
    [[ $NENV_X != *VDB_LOCK_SPLIT=1* ]] || grep -q "^vdb-server: lock split on" $L || stop "$name node$k: lock split not on"
  done
  local OPP=; for p in $parts; do OPP+="$R/$p "; done
  for p in $parts; do
    local RP=$R/$p
    [ -s $RP/loadgen/summary.json ] || stop "$name/$p: no loadgen output"
    grep -q '"reason":"stream [a-z]* exhausted' $RP/loadgen/steps.jsonl && stop "$name/$p: writes file exhausted"
    { grep -qx "ok_without_coh=0" $RP/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $RP/loadgen/vectordb.txt &&
      grep -qx "bad_coh_version=0" $RP/loadgen/vectordb.txt; } || stop "$name/$p: responses without an op coherence block"
    grep -q 'workload_finish":"ok' $RP/loadgen/summary.json || stop "$name/$p: loadgen workload finish"
    python3 $XV/opsplit.py $RP > $RP/opsplit.log 2>&1 || log "$name/$p NOTE: opsplit.py failed (see $RP/opsplit.log)"
    OPCOH_NODES=$N OPCOH_PARTS="${OPP% }" MEGALON_LEAN=1 OPCOH_RECORD_BYTES=$([ $VF = sq8 ] && echo 832 || echo 3136) \
      python3 $OPC $RP $mode > $RP/opcoh-check.txt 2>&1
    t=$(grep -m1 -oE '^OPCOH_CHECK (PASS|FAIL)' $RP/opcoh-check.txt | cut -d' ' -f2); t=${t:-ERROR}
    [ "$t" = PASS ] || { [ $STRICT = 1 ] && stop "$name/$p: opcoh_check $mode $t"; log "$name/$p NOTE: opcoh_check $mode $t (recorded)"; }
    oc="${oc#-}${oc:+ }$p:$t"
    python3 $XV/urate_check.py $RP --writers 1 > $RP/urate-check.txt 2>&1 || true
    python3 $XV/e1_check.py --writes $X_WRITES --na $NA --nb $X_NB --searches $RP/loadgen/searches.bin --out $RP/e1 --sample 500 > /dev/null \
      || stop "$name/$p: E1 violation (see $RP/e1.e1.txt)"
  done
  [ $s != ds ] || ds_recv $name
  note="fixed parts: $parts"
  # dmesg first (review M1): a result row means every check of this lifetime passed, so a resume never skips the next
  # cell for a failure of this one
  dmesg_check $name || stop "$name: dmesg check"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t\t\t\t%s\t%s\t%s\n' "$name" $s $mix $U $N $VCPU "$note" "$name" "${oc# }" >> "$E/h2n-results.tsv"
}
# ---- sequence ----------------------------------------------------------------------------------------------------
for l in "${LIVES[@]}"; do
  IFS=: read -r ls lm lr <<< "$l"
  if [ -n "$FIXED" ]; then
    log "== FIXED $ls $lm n$N parts [${FPARTS[$(fkey $ls $lm)]}]"
    vdb_fixed_life "$ls" "$lm"
  else
    log "== HSLO $ls $lm n$N${lr:+ $lr}"
    vdb_life "$ls" "$lm" ${lr:+"$lr"}
  fi
done
# hook point (popcorn-writer-lock-split chain): a later knee sweep reuses this block with another H2N_FIXED in the same
# VM8 lifetime (a separate runset-h2n.sh call with its own conf and evidence dir); nothing to do here
[ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root"; OWNED=root; }
log "== PT pretouch check (end)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end)"
log "BLOCK DONE $OWNER"

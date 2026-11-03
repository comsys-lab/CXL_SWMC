#!/bin/bash
# Run set "h2n-n<N>" (new H2 = vector DB VM-count scaling; RUN-H2N.md; user decisions 2026-10-20 22:3x): experiments/
# eval/h2n-block.sh on N VMs of the VM8 topology (cxl_vm0..N-1, 192.168.122.100.., EVERY VM 4 vCPU / 24 GB), one
# aggregate SLO search per (system, mix), lifetimes in the order systems H2N_SYSTEMS (outer) x mixes H2N_POINTS (inner).
# Config: EVAL_CONF=experiments/eval/h2n.conf (RUNSETS h2n-n2 h2n-n4 h2n-n8; eval.conf refuses: no H2N_* keys).
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/sequence.log, E/block/ (h2n-block.sh evidence: h2n-results.tsv,
# <sys>-<mix>-n<N>/, cxlbw/, block.log). Acceptance: review E/block/h2n-results.tsv + block.log (BLOCK DONE, no
# ROLLBACK FAIL), then EVAL_REGISTRY=<REGISTRY> registry.py accept h2n-n<N> <k> <E>.
# usage: runset-h2n.sh <N> <k> [--dry] [--v V] [--from <sys>:<mix>] [--only "<sys>:<mix> ..."]
#   --from  resume: start the lifetime list at this lifetime (a stopped block's finished lifetimes stay in its own,
#           immutable evidence dir; export_h2n.py takes several evidence dirs per N, later dirs win per lifetime)
#   --only  run exactly these lifetimes (in the given order), e.g. a single re-run; exclusive with --from
# Optional conf keys of the confirm-rule test (confirm-test.conf; absent in h2n.conf = the behaviour above):
#   H2N_TOPO=2          the 2-VM topology (cxl_vm0/cxl_vm1, 16 vCPU / 96 GB each; N = 2 only) instead of VM8 (H2N_TOPO=8);
#                       VCPUS_PER_VM=4 there = guest CPUs 4-15 set offline by the operator (sysfs; the block's nproc check
#                       then verifies 4 online CPUs; user 2026-11-01 ds-h1-4vcpu)
#   H2N_REPEATS=<r>     every (system, mix) lifetime r times, each a fresh server lifetime (systems outer, mixes, then
#                       repeats); lifetime ids <sys>:<mix>:r<j> (run dirs <sys>-<mix>-n<N>-r<j>), same loadgen seed in
#                       every repeat; r > 1 skips export_h2n.py (one row per (mix, system))
#   H2N_LOADGEN_EXTRA   loadgen arguments appended to H2N_SLO_PART (e.g. "--confirm-rule pooled --confirm-full")
#   EVIDENCE_TAG        (lib.sh key) evidence dir tag prefix: <prefix>-run<k>-<tag>-n<N>-v<V> (eval2-h1-slo / eval2-h2)
N=${1:-}; shift || true
[[ $N =~ ^[2-8]$ ]] || { echo "RUNSET STOP: usage runset-h2n.sh <N> <k> [--dry] [--v V] [--from sys:mix] [--only 'sys:mix ...']"; exit 2; }
K_ARG=${1:-}; shift || true
FROM= ONLY= REST=()
while [ $# -gt 0 ]; do
  case $1 in --from) FROM=${2:-}; shift 2;; --only) ONLY=${2:-}; shift 2;; *) REST+=("$1"); shift;; esac
done
set -- "$K_ARG" "${REST[@]}"
RUNSET=h2n-n$N WL=vdb CONF_WL=h2n
unset H2N_PINS H2N_VEC_FORMAT H2N_EF H2N_INIT H2N_HOST_IMAGE H2N_REPEATS H2N_LOADGEN_EXTRA H2N_SEARCH_THREADS \
  H2N_FIXED H2N_FIXED_N2 H2N_FIXED_N4 H2N_FIXED_N8 H2N_NODE_ENV_EXTRA H2N_ALLOW_DETAIL H2N_EVIDENCE_NAME VDB_X_NA \
  H2N_FIXED_RECVP H2N_FIXED_RECVP_BASE \
  H2N_DS_C H2N_DS_K H2N_DS_GT H2N_DS_BUNDLE_SHA H2N_DS_REGION H2N_DS_T_US \
  H2N_ORDER H2N_DS_T_SWEEP H2N_DS_KERNEL H2N_DS_REPLICA_MODE H2N_DS_REPLICA_POOL_BYTES H2N_L1 H2N_L1_FROM \
  H2N_ACCURACY_EXPORT H2N_DS_RECV_EXTRA H2N_DS_DAMON \
  H2N_DS_DAMON_EXTRA H2N_DS_DAMON_AT H2N_DS_DAMON_WARMUP H2N_DS_DAMON_REGIONS H2N_WARMUP \
  H2N_PMAX H2N_PMAX_FROM H2N_PMAX_WARMUP_S H2N_PMAX_MEASURE_S H2N_PMAX_DRAIN_S   # optional conf keys: never inherited from the environment
# run-2 keys: H2N_PMAX (1 = fault-breakdown step at Popcorn's max), H2N_PMAX_FROM (pop result globs, relative to the
# project root made absolute; {MIX} {N} {RUN} replaced by the block), H2N_PMAX_WARMUP_S / _MEASURE_S / _DRAIN_S
# (h2n-block.sh header); receiver keys POP_RECV_MODE / POP_ADAPT_KO / RECV_IPOLL (lib.sh)
# damon-policy-exploration keys H2N_DS_DAMON_EXTRA / _AT / _WARMUP / _REGIONS: passed to h2n-block.sh (its header)
# run-2 §6 key H2N_WARMUP (the DAMON warmup segment for lifetimes without DAMON): passed to h2n-block.sh (its header)
# eval3 keys (experiment de-stijl-evaluation-run1, 2026-11-02; absent = unchanged):
#   H2N_ORDER=mix        lifetime list mixes outer, systems inner (B1: per mix mg -> pop -> hw); default systems outer
#   H2N_DS_T_SWEEP="T1 T2 .."  the ds entry of H2N_SYSTEMS becomes one lifetime ds:<mix>:t<T> per value (us; block A)
#   H2N_DS_KERNEL=1      the block runs on the De Stijl kernel without a ds lifetime (hw reference cell of block A)
#   H2N_DS_REPLICA_MODE / H2N_DS_REPLICA_POOL_BYTES / H2N_L1 / H2N_L1_FROM / H2N_ACCURACY_EXPORT / H2N_DS_RECV_EXTRA /
#   H2N_DS_DAMON (with H2N_DS_REPLICA_MODE=damon, eval3-damon-dsd.conf):
#                        passed to h2n-block.sh
#                        (its header); H2N_L1_FROM tokens relative to the project root are made absolute
#   H2N_DS_T_US=@MAIN_T@ placeholder (eval3-b2.conf before block A's recall decides T): dry start NOTE, real run STOP
#   H2N_EVIDENCE_NAME may also hold {SYS} {MIX} {CELL} (one lifetime per call, --only; CELL = <sys>-<mix>[-t<T>]):
#                        one evidence dir per cell, e.g. eval3-b1-{SYS}-{MIX}-n{N} -> recovery/eval3-b1-mg-u10-n2-v1
# De Stijl v2 (H2N_SYSTEMS entry ds; systems/destijl/system.yaml): H2N_DS_C (bundle dir: p-destijl-shm.sh, packet.sha256),
# H2N_DS_BUNDLE_SHA, H2N_DS_K (guest release -ds-destijl-<n>), H2N_DS_GT (guest tools dir), optional H2N_DS_REGION
# (default config/cxl_region-destijl.yaml) and H2N_DS_T_US (staleness bound T, default 0); passed to h2n-block.sh as
# DS_C DS_BUNDLE_SHA DS_K DS_GT DS_REGION H2N_DS_T_US. pop and ds never share a block (different guest kernels).
# VDB_X_NA (2026-10-30, 54M pool A): pool A record count of the init image (h2n-block.sh X_NA, e1_check --na); absent =
# 26990000 (the 28M image) so every earlier conf behaves as before. VDB_MG_CAPACITY: h1 (Megalon --max-ids 28000000, no
# --init-capacity, the fp32 28M cap) | x (the plain layout values --max-ids VDB_X_MAXIDS --init-capacity VDB_X_INIT_CAP)
# H2N_SEARCH_THREADS (ef-bandwidth.conf, 2026-10-28): search threads per VM instead of VCPUS_PER_VM - 1 (passed to
# h2n-block.sh; the VMs keep their vCPUs)
# knee-sweep-h2.conf: H2N_FIXED_N<N> (per-N rates) replaces H2N_FIXED for N; H2N_EVIDENCE_NAME may contain {N}
# (replaced by N, e.g. knee-sweep-h2-n{N} -> recovery/knee-sweep-h2-n4-v<V>)
# Fixed-window keys (knee-sweep-pilot.conf, lock-split.conf; absent = SLO searches as above): H2N_FIXED,
# H2N_NODE_ENV_EXTRA, H2N_ALLOW_DETAIL (passed to h2n-block.sh; its header documents them), H2N_EVIDENCE_NAME =
# evidence dir <RESULTS_ROOT>/<name>-v<V> instead of <prefix>-run<k>-<tag>-n<N>-v<V>; with H2N_FIXED export_h2n.py
# is skipped (no SLO result; the experiment's own export reads the evidence dir)
. "$(dirname "$0")/lib.sh"
H=$TREE/experiments/h1
[ -n "${H2N_NODES:-}" ] || die "EVAL_CONF has no H2N_* keys (use EVAL_CONF=$EVD/h2n.conf)"
[[ " $H2N_NODES " == *" $N "* ]] || die "N=$N not in H2N_NODES ($H2N_NODES)"
case $H2N_TOPO in
  8) [ "$VCPUS_PER_VM" = 4 ] && [ "$H2N_RAM_GB" = 24 ] || die "h2n needs the VM8 topology with 4 vCPU / 24 GB per VM";;
  2) [ "$N" = 2 ] && [[ $VCPUS_PER_VM =~ ^(16|4)$ ]] && [ "$H2N_RAM_GB" = 96 ] || die "H2N_TOPO=2 = cxl_vm0/cxl_vm1 with 16 vCPU (or 4 online) / 96 GB, N = 2 only";;
  *) die "bad H2N_TOPO ($H2N_TOPO: 8 | 2)";;
esac
REPS=${H2N_REPEATS:-1}
[[ $REPS =~ ^[1-9]$ ]] || die "bad H2N_REPEATS ($REPS: 1..9)"
SLOPART=$H2N_SLO_PART${H2N_LOADGEN_EXTRA:+ $H2N_LOADGEN_EXTRA}
[ "$VDB_DATASET" = 28m-x ] || die "h2n uses the 28m-x dataset (VDB_DATASET)"
[ "$VDB_SLO_PCT:$VDB_SLO_MS" = 99:100 ] || die "VDB SLO is search p99 <= 100 ms (the SLO part arguments are fixed)"
[[ $VDB_MG_CAPACITY =~ ^(h1|x)$ ]] || die "bad VDB_MG_CAPACITY ($VDB_MG_CAPACITY: h1 | x)"
X_NA=${VDB_X_NA:-26990000}
[[ $X_NA =~ ^[1-9][0-9]*$ ]] || die "bad VDB_X_NA ($X_NA)"
[ -n "$FROM" ] && [ -n "$ONLY" ] && die "--from and --only are exclusive"
# lifetime list: systems outer, mixes inner (H2N_ORDER=mix: mixes outer, systems inner)
ORDER=${H2N_ORDER:-sys} TSW=${H2N_DS_T_SWEEP:-}
[[ $ORDER =~ ^(sys|mix)$ ]] || die "bad H2N_ORDER ($ORDER: sys | mix)"
[ -z "$TSW" ] || { [[ $TSW =~ ^(0|[1-9][0-9]*)( (0|[1-9][0-9]*))*$ ]] && [ "$REPS" = 1 ]; } || die "bad H2N_DS_T_SWEEP ($TSW: integer us list; not with H2N_REPEATS)"
for s in $H2N_SYSTEMS; do case $s in hw|pop|ds|mg|mgoff) ;; *) die "bad H2N_SYSTEMS entry $s";; esac; done
for m in $H2N_POINTS; do
  row=$(awk -F'\t' -v m="$m" '!/^#/ && $1 == "vdb" && $2 == m' "$H/h1-plan.tsv")
  [ "$(echo "$row" | cut -f3)" = "U=${m#u}" ] || die "mix $m: h1-plan.tsv has no vdb row with U=${m#u}"
done
cell() {  # <sys> <mix>: the lifetime ids of one (system, mix)
  if [ "$1" = ds ] && [ -n "$TSW" ]; then for t in $TSW; do ALL+=("$1:$2:t$t"); done
  elif [ "$REPS" = 1 ]; then ALL+=("$1:$2"); else for r in $(seq 1 "$REPS"); do ALL+=("$1:$2:r$r"); done; fi
}
ALL=()
if [ "$ORDER" = mix ]; then for m in $H2N_POINTS; do for s in $H2N_SYSTEMS; do cell $s $m; done; done
else for s in $H2N_SYSTEMS; do for m in $H2N_POINTS; do cell $s $m; done; done; fi
LIVES=("${ALL[@]}")
if [ -n "$FROM" ]; then
  i=-1; for j in "${!ALL[@]}"; do [ "${ALL[$j]}" = "$FROM" ] && i=$j; done
  [ $i -ge 0 ] || die "--from $FROM is not one of [${ALL[*]}]"
  LIVES=("${ALL[@]:$i}")
elif [ -n "$ONLY" ]; then
  LIVES=()
  for l in $ONLY; do [[ " ${ALL[*]} " == *" $l "* ]] || die "--only $l is not one of [${ALL[*]}]"; LIVES+=("$l"); done
fi
HASMG=0 HASDS=0; for l in "${LIVES[@]}"; do case ${l%%:*} in mg|mgoff) HASMG=1;; ds) HASDS=1;; esac; done
DSENV=()
ab() { case $1 in /*) echo "$1";; *) echo "$P/$1";; esac; }
[[ ${H2N_DS_KERNEL:-0} =~ ^[01]$ ]] || die "bad H2N_DS_KERNEL"
if [ $HASDS = 1 ] || [ "${H2N_DS_KERNEL:-0}" = 1 ]; then
  for x in H2N_DS_C H2N_DS_K H2N_DS_GT H2N_DS_BUNDLE_SHA; do [ -n "${!x:-}" ] || die "ds lifetimes need $x in $EVAL_CONF"; done
  DSC=$(ab "$H2N_DS_C") DSR=$(ab "${H2N_DS_REGION:-$TREE/config/cxl_region-destijl.yaml}")   # default: this tree's
  need_files "$DSC/p-destijl-shm.sh" "$DSC/packet.sha256" "$DSR"
  [ "$(sha256sum < "$DSC/packet.sha256" | cut -c1-64)" = "$H2N_DS_BUNDLE_SHA" ] || die "De Stijl bundle packet.sha256 != H2N_DS_BUNDLE_SHA"
  DST_C=${H2N_DS_T_US:-0}
  if [ "$DST_C" = @MAIN_T@ ]; then  # eval3-b2.conf before the main T is known
    NEEDT=0; for l in "${LIVES[@]}"; do [[ $l == ds:* ]] && [[ $l != *:t* ]] && NEEDT=1; done
    if [ $NEEDT = 1 ]; then [ $DRY = 1 ] || die "H2N_DS_T_US=@MAIN_T@: the main T is not filled in yet (block A recall rule)"
      plan "H2N_DS_T_US is the placeholder @MAIN_T@: fill it before a real run (a real run stops here)"; fi
  fi
  DSENV=(DS_C=$DSC DS_K=$H2N_DS_K DS_GT=$H2N_DS_GT DS_BUNDLE_SHA=$H2N_DS_BUNDLE_SHA DS_REGION=$DSR H2N_DS_T_US=$DST_C H2N_DS_KERNEL=1)
fi
L1FROM_A=; read -r -a L1G <<< "${H2N_L1_FROM:-}"   # read -a: no glob expansion here (the block expands them)
for g in "${L1G[@]}"; do L1FROM_A+="${L1FROM_A:+ }$(ab "$g")"; done
v() { local x=H2N_$1_N$N; echo "${!x:-}"; }
WRITES=$(v WRITES) MAXD=$(v MAXD)
[ -n "$WRITES" ] && [[ $MAXD =~ ^[1-9][0-9]*$ ]] || die "H2N_WRITES_N$N / H2N_MAXD_N$N missing"
MGB=$(v MG_BUILD) MGV=$(v VMEG) MGC=$(v MG_CFG) MGL=$(v MG_LIB) MGD=$(v MG_MAXD)
need_files "$VDB_PLAIN_BUILD/bin/vdb-server" "$VDB_LOADGEN_BUILD/loadgen" "$REGION" "$POP_C/p-popcorn-shm.sh" \
  "$VDB_X_DATA/pool_b.fbin" "$WRITES" "$EVD/h2n-block.sh" "$EVD/h2n_layout.py"
[ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
ring_check
# SQ8 overlay keys (h2n-sq8.conf; absent in h2n.conf = the fp32 behaviour): H2N_PINS (pins file instead of
# pins-vdb.sh), H2N_VEC_FORMAT, H2N_EF, H2N_INIT, H2N_HOST_IMAGE (passed to h2n-block.sh)
PINS=$EVD/${H2N_PINS:-pins-vdb.sh}
[[ ${H2N_PINS:-x} != */* ]] || die "H2N_PINS is a file name next to runset-h2n.sh"
VF=${H2N_VEC_FORMAT:-fp32}
( cd "$H" && . "$PINS" && echo "$PIN_SHA256" | sha256sum --quiet -c - ) || die "eval pins ($PINS: builds, data, region, Megalon) do not verify"
# run-2 guard (REQUIRE_ADAPTIVE=1, verifier M5): the vector DB server must sample the idle pollers per step (kthread
# prefix cxl_ipoll, workloads/vectordb/server/server.cc; builds/vdb/24 on); builds/vdb/23 lacks it
if [ "${REQUIRE_ADAPTIVE:-0}" = 1 ] && ! grep -qa cxl_ipoll "$VDB_PLAIN_BUILD/bin/vdb-server"; then
  [ $DRY = 1 ] && plan "run-2 guard: $VDB_PLAIN_BUILD/bin/vdb-server has no cxl_ipoll kthread prefix (needs builds/vdb/24; a real run stops here)" \
    || die "run-2 guard: $VDB_PLAIN_BUILD/bin/vdb-server has no cxl_ipoll kthread prefix (re-pin to builds/vdb/24)"
fi
if [ $HASMG = 1 ]; then
  MGPEND=
  for x in "$MGB" "$MGV" "$MGC" "$MGL"; do [[ $x == *PLACEHOLDER* ]] && MGPEND="$MGPEND $x"; done
  if [ -n "$MGPEND" ]; then
    [ $DRY = 1 ] || die "Megalon inputs for N = $N are placeholders ($MGPEND): fill H2N_MG_*_N$N in $EVAL_CONF (megalon-n agent) or run without mg (--only)"
    plan "Megalon N = $N inputs pending:$MGPEND (a real run stops here)"
  fi
  [[ $MGD =~ ^[1-9][0-9]*$ ]] || die "H2N_MG_MAXD_N$N missing"
fi
plan "vec_format $VF ef ${H2N_EF:-32 (h2n-block default)} pins $PINS${H2N_HOST_IMAGE:+ image $H2N_HOST_IMAGE guest ${H2N_INIT:-}}"
plan "N=$N topology $H2N_TOPO vCPU/VM=$VCPUS_PER_VM RAM/VM=${H2N_RAM_GB} GB; threads ${H2N_SEARCH_THREADS:-$VDB_SEARCH_THREADS} search + 1 writer; recv_mode $RECV_MODE; repeats $REPS (seed $((SEED_BASE + K)) in every repeat)"
plan "slo part: $SLOPART"
plan "lifetimes (${#LIVES[@]}): ${LIVES[*]}${FROM:+ (resume from $FROM)}${ONLY:+ (only)}"
plan "writes $WRITES; max_deletes/node $MAXD; pool A $X_NA ($([ -n "${VDB_X_NA:-}" ] && echo "conf VDB_X_NA" || echo "default: no VDB_X_NA")) max_ids $VDB_X_MAXIDS init_capacity $VDB_X_INIT_CAP$([ $HASMG = 1 ] && echo "; Megalon build $MGB lib $MGL cfg $MGC guest $MGV max_deletes/node $MGD capacity $VDB_MG_CAPACITY")"
need_env
lock_free
# approved scope: <RESULTS_ROOT>/vdb-vm-scaling-run<k>-n<N>-v<V> (EVIDENCE_PREFIX in h2n.conf); a conf EVIDENCE_TAG
# (eval2-h1-slo.conf h1, eval2-h2.conf h2; absent in h2n*.conf) prefixes it: <prefix>-run<k>-<tag>-n<N>-v<V>
EVIDENCE_TAG=${EVIDENCE_TAG:+$EVIDENCE_TAG-}n$N
x=H2N_FIXED_N$N; [ -z "${!x:-}" ] || H2N_FIXED=${!x}
if [ -n "${H2N_EVIDENCE_NAME:-}" ]; then
  H2N_EVIDENCE_NAME=${H2N_EVIDENCE_NAME//\{N\}/$N}; H2N_EVIDENCE_NAME=${H2N_EVIDENCE_NAME//\{RUN\}/$K}   # {RUN}: run 2
  if [[ $H2N_EVIDENCE_NAME == *\{* ]]; then  # {SYS} {MIX} {CELL}: one evidence dir per cell (eval3)
    [ ${#LIVES[@]} = 1 ] || die "H2N_EVIDENCE_NAME $H2N_EVIDENCE_NAME needs exactly one lifetime (--only <sys>:<mix>)"
    IFS=: read -r cs cm cx <<< "${LIVES[0]}"
    H2N_EVIDENCE_NAME=${H2N_EVIDENCE_NAME//\{SYS\}/$cs}; H2N_EVIDENCE_NAME=${H2N_EVIDENCE_NAME//\{MIX\}/$cm}
    H2N_EVIDENCE_NAME=${H2N_EVIDENCE_NAME//\{CELL\}/$cs-$cm${cx:+-$cx}}
  fi
  [[ $H2N_EVIDENCE_NAME =~ ^[a-z0-9-]+$ ]] || die "bad H2N_EVIDENCE_NAME"
  n=${VER:-1}; if [ -z "$VER" ]; then while [ -e "$RESULTS_ROOT/$H2N_EVIDENCE_NAME-v$n" ]; do n=$((n + 1)); done; fi
  E=$RESULTS_ROOT/$H2N_EVIDENCE_NAME-v$n
  [ ! -e "$E" ] || die "$E exists (evidence dirs are immutable; a failed attempt bumps v<N>)"
  plan "evidence dir $E (absent: OK; H2N_EVIDENCE_NAME)"
else evidence_dir; fi
[ -z "${H2N_FIXED:-}" ] || plan "fixed windows (no SLO search): $H2N_FIXED; node env extra [${H2N_NODE_ENV_EXTRA:-}] allow_detail ${H2N_ALLOW_DETAIL:-0}"
BENV=(H2N_N=$N H2N_VCPU=$VCPUS_PER_VM "H2N_LIFETIMES=${LIVES[*]}" EVAL_RUN=$K SEED=$((SEED_BASE + K)) REGION=$REGION
  C8=$POP_C K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  VPLAIN=$VDB_VPLAIN PLAIN_BUILD=$VDB_PLAIN_BUILD LOADGEN=$VDB_LOADGEN_BUILD/loadgen X_DATA=$VDB_X_DATA X_WRITES=$WRITES
  X_NB=$VDB_X_NB X_MAXIDS=$VDB_X_MAXIDS X_MAXW=$VDB_X_MAXW X_MAXD=$MAXD X_INIT_CAP=$VDB_X_INIT_CAP X_NA=$X_NA
  "H2N_SLO_PART=$SLOPART" H2N_OPCOH_STRICT=$H2N_OPCOH_STRICT H2N_CXLBW=$H2N_CXLBW H2N_HOSTCPU=${H2N_HOSTCPU:-0})
[ ${#DSENV[@]} = 0 ] || BENV+=("${DSENV[@]}")   # also H2N_DS_KERNEL=1 without a ds lifetime (block A --only hw:u90)
[ ${#RECVENV[@]} = 0 ] || BENV+=("${RECVENV[@]}")   # receiver keys (lib.sh; recv-mode.sh rules, checked in the block)
HASPOPL=0; for l in "${LIVES[@]}"; do [[ $l != pop:* ]] || HASPOPL=1; done
[ $HASPOPL = 0 ] || recv_pop_check "$N"
for x in H2N_PMAX H2N_PMAX_WARMUP_S H2N_PMAX_MEASURE_S H2N_PMAX_DRAIN_S; do [ -z "${!x:-}" ] || BENV+=("$x=${!x}"); done
PMFROM_A=; read -r -a PMG <<< "${H2N_PMAX_FROM:-}"
for g in "${PMG[@]}"; do PMFROM_A+="${PMFROM_A:+ }$(ab "$g")"; done
[ -z "$PMFROM_A" ] || BENV+=("H2N_PMAX_FROM=$PMFROM_A")
[ "${H2N_PMAX:-0}" = 0 ] || plan "pmax step: pop / ds lifetimes append loadgen --mode fixed --rates <Popcorn's max of the cell> (pop: its own slo part; ds: pop rows of [${PMFROM_A:-}])"
[ $HASMG = 0 ] || BENV+=(MEG_BUILD=$MGB VMEG=$MGV MEG_CFG=$MGC MEG_LIB=$MGL MG_MAXD=$MGD MG_CAPACITY=$VDB_MG_CAPACITY)
[ -z "${H2N_FIXED_RECVP:-}" ] || plan "receiver parameters per fixed part (run-2 receiver ablation): [$H2N_FIXED_RECVP] base [${H2N_FIXED_RECVP_BASE:-}]"
for x in H2N_VEC_FORMAT H2N_EF H2N_INIT H2N_HOST_IMAGE H2N_SEARCH_THREADS H2N_FIXED H2N_FIXED_RECVP H2N_FIXED_RECVP_BASE H2N_NODE_ENV_EXTRA H2N_ALLOW_DETAIL \
  H2N_DS_REPLICA_MODE H2N_DS_REPLICA_POOL_BYTES H2N_L1 H2N_ACCURACY_EXPORT H2N_DS_RECV_EXTRA H2N_DS_DAMON \
  H2N_DS_DAMON_EXTRA H2N_DS_DAMON_AT H2N_DS_DAMON_WARMUP H2N_DS_DAMON_REGIONS H2N_WARMUP; do [ -z "${!x:-}" ] || BENV+=("$x=${!x}"); done
[ -z "${H2N_WARMUP:-}" ] || plan "fixed warmup (H2N_WARMUP, run-2 §6 trio): [${H2N_WARMUP}] before the slo part of hw/pop/ds SLO lifetimes"
[ -z "${H2N_DS_DAMON:-}" ] || plan "De Stijl + DAMON: kdamond per VM with [${H2N_DS_DAMON}] (ds-damon-guest.sh, ds lifetimes only)"
[ -z "${H2N_DS_DAMON_EXTRA:-}${H2N_DS_DAMON_AT:-}${H2N_DS_DAMON_WARMUP:-}${H2N_DS_DAMON_REGIONS:-}" ] || plan "DAMON policy keys: extra [${H2N_DS_DAMON_EXTRA:-}] at ${H2N_DS_DAMON_AT:-enable} warmup [${H2N_DS_DAMON_WARMUP:-}] regions ${H2N_DS_DAMON_REGIONS:-0}"
[ -z "${H2N_DS_RECV_EXTRA:-}" ] || plan "De Stijl receiver parameters: ${H2N_DS_RECV_EXTRA} (cxl_shm load, ds lifetimes only; checked after the enable)"
[ -z "$L1FROM_A" ] || BENV+=("H2N_L1_FROM=$L1FROM_A")
[ "${H2N_L1:-0}" = 0 ] || plan "L1 step: hw/pop/ds lifetimes append loadgen --mode fixed --rates <L1> (L1 from mg rows of [${L1FROM_A:-} + the block's own results])"
[ -z "${H2N_DS_REPLICA_MODE:-}" ] || plan "De Stijl replica_mode ${H2N_DS_REPLICA_MODE} pool ${H2N_DS_REPLICA_POOL_BYTES:--} bytes (back to off after every ds lifetime)"
for x in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!x:-}" ] || BENV+=("$x=${!x}"); done
plan "block: env ${BENV[*]} bash $EVD/h2n-block.sh <E>/block"
if [ $DRY = 1 ]; then
  block_dry "evidence-dir check reached" env H2N_BLOCK_DRY=1 "${BENV[@]}" bash "$EVD/h2n-block.sh" @DIR@
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
# ---- real run ----
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add vdb $RUNSET $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$VDB_PLAIN_BUILD" "$VDB_LOADGEN_BUILD" $([ $HASMG = 1 ] && echo "$MGB")
{ echo "writes $(sha256sum "$WRITES")"; echo "lifetimes=${LIVES[*]} from=${FROM:-} only=${ONLY:-}"
  python3 -I -B "$EVD/h2n_layout.py" --vec-format "$VF" --max-ids "$VDB_X_MAXIDS" --check "$N" "$MAXD"; } >> "$E/eval-manifest.txt"
$REG add vdb $RUNSET $K "$E" $CSHA started "commit $COMMIT N=$N lifetimes ${#LIVES[@]}${FROM:+ from $FROM}"
log "block start (N=$N, ${#LIVES[@]} lifetimes)"
env "${BENV[@]}" bash "$EVD/h2n-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || stop "block did not finish (see $E/sequence.log, $E/block/block.log)"
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || stop "rollback / cleanup failure lines (manual check)"
[ "$(grep -vc '^#' "$E/block/h2n-results.tsv")" = "${#LIVES[@]}" ] || stop "h2n-results.tsv rows != lifetimes"
$REG add vdb $RUNSET $K "$E" $CSHA measured "$(grep -v '^#' "$E/block/h2n-results.tsv" | cut -f1,7,9 | tr '\t\n' ' ;' | cut -c1-200)"
out=$DERIVED_ROOT/vdb/$RUNSET/run$K
if [ -n "${H2N_FIXED:-}" ]; then log "RUNSET NOTE: export_h2n.py skipped (H2N_FIXED: fixed windows, no SLO result)"
elif [ "$REPS" != 1 ]; then log "RUNSET NOTE: export_h2n.py skipped (H2N_REPEATS=$REPS: it keeps one lifetime per (mix, system))"
else mkdir -p "$out" && python3 -I -B "$EVD/export_h2n.py" --run "$K" --nodes "$N" --config-sha256 "$CSHA" --out "$out" "$E/block" > "$out/export.log" 2>&1 \
  && log "export: $out" || log "RUNSET NOTE: export failed (see $out/export.log; the run itself is unaffected)"; fi
log "RUNSET DONE: review $E/block/h2n-results.tsv and block.log, then: EVAL_REGISTRY=${REGISTRY:-} python3 $EVD/registry.py accept $RUNSET $K $E"

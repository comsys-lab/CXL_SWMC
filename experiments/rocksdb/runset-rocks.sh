#!/bin/bash
# RocksDB SLO-search run set (eval3, experiment de-stijl-evaluation-run1, blocks D and E): one v1-block.sh block per
# (conf, N, kernel phase). Phase hwpop = the hw and pop cells on the Popcorn guest kernel (hw first: one dax0.0 chown
# switch), phase ds = the De Stijl cells (T = 0) on the De Stijl guest kernel; the kernel switch between the phases is
# the calling chain's job (scripts/deploy/p-destijl-*.sh). Every cell = one server lifetime with ONE aggregate SLO
# search (loadgen --mode slo: ramp, bisect, confirm, fill, overload points past the knee; the vector DB cell rule via
# ROCKS_SLO_EXTRA), result dir <E>/<sys>-<mix>-n<N>/ (manifest, steps.csv, stats-steps.csv, loadgen/), after the block
# <E>/rocks-results.tsv (slo_result.py: max requests/s under the SLO per cell, checks).
# usage: runset-rocks.sh <conf> <N> <hwpop|ds> [--dry-run] [--v V] [--only "<sys>-<mix> ..."]
#   conf     experiments/rocksdb/eval3-rocks-{d,e}.conf (keys below; relative paths are relative to the project root)
#   --dry-run  validate the conf and the chain environment, print the block plan and run v1-block.sh DRY=1 (bundle
#            hashes, region configs, builds, every run's arguments, the cxl_shm plan); no ssh, no lock, nothing written
#   --v V    evidence dir version (default: the next free one); --only: a subset of the phase's cells, in conf order
# exit: 0 all cells confirmed | 3 block done, some cell UNCONFIRMED (loadgen note "confirm failed at three rates"; the
#   other cells still ran; a WARN, not a failure) | 1 real failure (block stop or result ERROR row) | 2 usage / env stop
# Chain environment (required unless --dry-run): PRETOUCH_DIR (pretouch evidence of the VMs' current QEMU lifetimes),
#   MEASURE_ENV_DIR, MEASURE_PART_DIR (Host measurement evidence; h3-gate.sh). Real runs also require
#   state/EXPERIMENTS.md "### de-stijl-evaluation-run1" to read "- Status: approved" or "- Status: running".
# Evidence: <RESULTS_ROOT>/<EVIDENCE_PREFIX>-<block>-<phase>-n<N>-v<V> (block.out, tasks-check.txt, v1-block evidence).
# Conf keys: ROCKS_BLOCK (D | E), ROCKS_TOPO (2 = cxl_vm0/1 16 vCPU XML with CPUs 4-15 offline | 8 = VM8 4 vCPU),
#   ROCKS_NODES ("2" | "4 8"), ROCKS_MIXES ("u5 u50"), ROCKS_SYSTEMS (subset of "hw pop ds"), ROCKS_SLO_MS (1),
#   ROCKS_KEYS, ROCKS_THREADS, EXPECT_NPROC, MIN_MEM_G, ROCKS_BUILD, ROCKS_LOADGEN_BUILD, ROCKS_SLO_EXTRA, RECV_MODE,
#   EXPECT_DAX_UUID, RESULTS_ROOT, EVIDENCE_PREFIX, ROCKS_GUEST_PREFIX, POP_REGION POP_C POP_BUNDLE_SHA POP_K POP_GT,
#   DS_REGION DS_C DS_BUNDLE_SHA DS_K DS_GT.
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$HERE/../.." && pwd)
die() { echo "RUNSET STOP: $*"; exit 2; }
CONF=${1:-}; N=${2:-}; PHASE=${3:-}; shift 3 2>/dev/null || die "usage: runset-rocks.sh <conf> <N> <hwpop|ds> [--dry-run] [--v V] [--only '...']"
DRY=0 V= ONLY=
while [ $# -gt 0 ]; do
  case $1 in --dry-run) DRY=1; shift;; --v) V=${2:-}; shift 2;; --only) ONLY=${2:-}; shift 2;; *) die "unknown argument $1";; esac
done
[ -f "$CONF" ] || die "conf $CONF missing"
KEYS="ROCKS_BLOCK ROCKS_TOPO ROCKS_NODES ROCKS_MIXES ROCKS_SYSTEMS ROCKS_SLO_MS ROCKS_KEYS ROCKS_THREADS EXPECT_NPROC MIN_MEM_G
  ROCKS_BUILD ROCKS_LOADGEN_BUILD ROCKS_SLO_EXTRA RECV_MODE EXPECT_DAX_UUID RESULTS_ROOT EVIDENCE_PREFIX ROCKS_GUEST_PREFIX
  POP_REGION POP_C POP_BUNDLE_SHA POP_K POP_GT DS_REGION DS_C DS_BUNDLE_SHA DS_K DS_GT"
# shellcheck disable=SC2086
unset $KEYS
# the conf may set only these keys (a typo or a foreign key stops)
bad=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | grep -vE "^($(echo $KEYS | tr ' ' '|'))=" | head -3)
[ -z "$bad" ] || die "conf lines that are not KEY=value of a known key: $bad"
# shellcheck disable=SC1090
. "$CONF"
for k in $KEYS; do [ -n "${!k:-}" ] || die "conf key $k empty"; done
abs() { case $1 in /*) echo "$1";; *) echo "$P/$1";; esac; }
ROCKS_BUILD=$(abs "$ROCKS_BUILD") ROCKS_LOADGEN_BUILD=$(abs "$ROCKS_LOADGEN_BUILD") RESULTS_ROOT=$(abs "$RESULTS_ROOT")
POP_REGION=$(abs "$POP_REGION") POP_C=$(abs "$POP_C") DS_REGION=$(abs "$DS_REGION") DS_C=$(abs "$DS_C")
[[ $ROCKS_BLOCK =~ ^[DE]$ ]] || die "ROCKS_BLOCK D | E"
[[ " $ROCKS_NODES " == *" $N "* ]] || die "N=$N not in ROCKS_NODES ($ROCKS_NODES)"
[ "$ROCKS_SLO_MS" = 1 ] || die "ROCKS_SLO_MS must be 1 (user decision: RocksDB SLO p99 1 ms)"
[ "$EXPECT_NPROC" = 4 ] || die "EXPECT_NPROC must be 4 (4 vCPU rule, user 2026-11-01)"
case $ROCKS_TOPO in
  2) [ "$N" = 2 ] || die "ROCKS_TOPO=2 is N = 2 only"; IPS="192.168.122.100 192.168.122.101"; DOMS="cxl_vm0 cxl_vm1";;
  8) IPS=$(for ((k = 0; k < N; k++)); do printf '192.168.122.%d ' $((100 + k)); done); IPS=${IPS% }
     DOMS=$(for ((k = 0; k < N; k++)); do printf 'cxl_vm%d ' $k; done); DOMS=${DOMS% };;
  *) die "ROCKS_TOPO 2 | 8";;
esac
case $PHASE in
  hwpop) SYSS=""; for s in hw pop; do [[ " $ROCKS_SYSTEMS " == *" $s "* ]] && SYSS="$SYSS $s"; done
         EXPECT_K=$POP_K REGION=$POP_REGION;;
  ds) [[ " $ROCKS_SYSTEMS " == *" ds "* ]] || die "ds not in ROCKS_SYSTEMS"; SYSS=" ds"; EXPECT_K=$DS_K REGION=$DS_REGION;;
  *) die "phase hwpop | ds";;
esac
[ -n "$SYSS" ] || die "no system of phase $PHASE in ROCKS_SYSTEMS"
RUNS=""; NAMES=""
for s in $SYSS; do
  case $s in hw) SYS=all-HWcc;; pop) SYS=Popcorn;; ds) SYS=DeStijl;; esac
  for mix in $ROCKS_MIXES; do
    case $mix in u5) UR=0.05;; u50) UR=0.5;; *) die "mix $mix: u5 | u50 (pilot-run.sh UPDATE_RATIO 0.05 | 0.5)";; esac
    name=$s-$mix-n$N
    [ -z "$ONLY" ] || [[ " $ONLY " == *" $s-$mix "* ]] || continue
    RUNS+="$name SYS=$SYS KIND=slo KEYS=$ROCKS_KEYS THREADS=$ROCKS_THREADS UPDATE_RATIO=$UR"$'\n'; NAMES+=" $name"
  done
done
[ -n "$RUNS" ] || die "no cell selected (--only '$ONLY')"
BL=$(tr 'DE' 'de' <<< "$ROCKS_BLOCK")
if [ -z "$V" ]; then V=1; while [ -e "$RESULTS_ROOT/$EVIDENCE_PREFIX-$ROCKS_BLOCK-$PHASE-n$N-v$V" ]; do V=$((V + 1)); done; fi
[[ $V =~ ^[1-9][0-9]*$ ]] || die "bad --v"
E=$RESULTS_ROOT/$EVIDENCE_PREFIX-$ROCKS_BLOCK-$PHASE-n$N-v$V
OWNER=$(basename "$E") L=$ROCKS_GUEST_PREFIX-$BL-$PHASE-n$N-v$V
if [ $DRY = 1 ]; then
  : "${PRETOUCH_DIR:=<chain PRETOUCH_DIR>}" "${MEASURE_ENV_DIR:=<chain MEASURE_ENV_DIR>}" "${MEASURE_PART_DIR:=<chain MEASURE_PART_DIR>}"
else
  : "${PRETOUCH_DIR:?chain env PRETOUCH_DIR}" "${MEASURE_ENV_DIR:?chain env MEASURE_ENV_DIR}" "${MEASURE_PART_DIR:?chain env MEASURE_PART_DIR}"
  st=$(awk '/^### de-stijl-evaluation-run1/{f=1; next} /^### /{f=0} f && /^- Status:/' "$P/state/EXPERIMENTS.md" | head -1)
  [[ $st =~ ^-\ Status:\ (approved|running) ]] || die "experiment de-stijl-evaluation-run1 not approved/running ($st)"
  [ ! -e "$E" ] || die "$E exists (results are immutable; use the next --v)"
  [ -z "$(git -C "$TREE" status --porcelain --untracked-files=no)" ] || die "tree $TREE dirty"
fi
export OWNER EXPECT_K PRETOUCH_DIR L RUNS NODES="$IPS" VM_DOMAINS="$DOMS" EXPECT_RUNNING="$DOMS" BUILD=$ROCKS_BUILD \
  LOADGEN_BUILD=$ROCKS_LOADGEN_BUILD REGION EXPECT_DAX_UUID MIN_MEM_G EXPECT_NPROC RECV_MODE SLO_EXTRA="$ROCKS_SLO_EXTRA" \
  MEASURE=1 MEASURE_ENV_DIR MEASURE_PART_DIR GATE_SCRIPT=$TREE/scripts/host/h3-gate.sh
if [ $PHASE = hwpop ]; then export C8=$POP_C K8=$POP_K GT8=$POP_GT POP_BUNDLE_SHA
else export DS_C DS_K DS_GT DS_BUNDLE_SHA; fi
echo "RUNSET rocks conf=$CONF ($(sha256sum < "$CONF" | cut -c1-16)) block=$ROCKS_BLOCK N=$N phase=$PHASE topo=$ROCKS_TOPO E=$E"
echo "RUNSET cells:$NAMES"
if [ $DRY = 1 ]; then
  DRY=1 bash "$HERE/v1-block.sh" "$E"; rc=$?
  [ $rc = 0 ] && echo "RUNSET DRY PASS ($ROCKS_BLOCK n$N $PHASE)" || echo "RUNSET DRY FAIL ($ROCKS_BLOCK n$N $PHASE)"
  exit $rc
fi
mkdir -p "$E" || die "mkdir $E"
{ echo "# tasks-check $(date -Is) runset-rocks.sh $CONF $N $PHASE (caller pid $PPID)"; echo "experiment: $st"
  echo "lock: $(cat "$P/workspaces/MEASUREMENT.lock" 2>/dev/null || echo none)"
  echo "tree: $(git -C "$TREE" rev-parse HEAD) conf_sha256=$(sha256sum < "$CONF" | cut -c1-64)"; } > "$E/tasks-check.txt"
bash "$HERE/v1-block.sh" "$E" > "$E/block.out" 2>&1; rc=$?
tail -n 3 "$E/block.out"
RD=(); for n in $NAMES; do [ -d "$E/$n/loadgen" ] && RD+=("$E/$n"); done
RRC=0 UNC=
if [ ${#RD[@]} -gt 0 ]; then
  python3 -I -B "$HERE/slo_result.py" --slo-ms "$ROCKS_SLO_MS" --vcpus "$EXPECT_NPROC" --out "$E/rocks-results.tsv" "${RD[@]}" \
    > /dev/null 2> "$E/rocks-results.err"; RRC=$?
  case $RRC in
    0) ;;
    3) UNC=$(awk -F'\t' '!/^#/ && $21 == "UNCONFIRMED" {printf "%s%s", s, $1; s=" "}' "$E/rocks-results.tsv")
       echo "RUNSET NOTE: unconfirmed cells (a result, not a failure): $UNC (see $E/rocks-results.err)";;
    *) echo "RUNSET NOTE: rocks-results has ERROR rows (rc $RRC, see $E/rocks-results.err)";;
  esac
  cut -f1,7,8,11,12,19,20,21 "$E/rocks-results.tsv"   # name, offered max, confirm x, max req/s, src, past knee, lag, check
fi
# rc: 0 = every cell confirmed; 3 = block done, every cell has a result row, some unconfirmed (WARN: the calling chain
# continues and counts the part as done); 1 = a real failure (block stop: crash, verify, server / protocol / error
# counter checks, ... or a result ERROR row); 2 = usage / environment stop before the block.
if grep -q "BLOCK DONE" "$E/block.log" 2>/dev/null && [ $rc = 0 ]; then
  case $RRC in
    0) echo "RUNSET DONE $E"; exit 0;;
    3) echo "RUNSET DONE-UNCONFIRMED $E ($UNC)"; exit 3;;
    *) echo "RUNSET FAILED result ERROR rows $E ($(head -c 300 "$E/rocks-results.err" | tr '\n' ';'))"; exit 1;;
  esac
fi
echo "RUNSET FAILED rc=$rc $E (block.log: $(grep -m1 'BLOCK STOP' "$E/block.log" 2>/dev/null))"; exit 1

#!/bin/bash
# socialgraph-serving run set: ONE cell (system, mix, N) per call = one sg-block.sh lifetime with one aggregate SLO
# search of the feed query (reports/experiments/socialgraph-serving.md §3: 26 searches). Modelled on
# experiments/eval/runset-h2n.sh (evidence naming, dry start, real-run tree / lock rules), without the eval registry.
# usage: runset-sg.sh <N> <run> --only <sys>:<mix> [--dry] [--v V]
#   sys hw | pop | ds | mgc (Megalon 32 MiB chunks) | mgr (Megalon one object per record, N = 2 only); mix rw100 | rw470
# env: EVAL_CONF (default experiments/socialgraph/socialgraph.conf; chains pass a resolved copy for ds), PRETOUCH_DIR,
#   MEASURE_ENV_DIR, MEASURE_PART_DIR (current QEMU lifetime's pretouch evidence and Host measurement dirs).
# Evidence: <RESULTS_ROOT>/socialgraph-<sys>-<mix>-n<N>-r<run>-v<V> (next free V): eval-manifest.txt, eval-state.txt,
#   sequence.log, block/ (sg-block.sh). Derived: <DERIVED_ROOT>/steps-<sys>-<mix>-n<N>-r<run>.csv (copy of block/<cell>/steps.csv).
# --dry: every Host check up to the block's evidence-dir check (no lock, no VM contact, nothing written), "DRY START OK".
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
P=/home/comsys/sungsu/destijl-control
EX=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EX/../.." && pwd)
die() { echo "RUNSET STOP (socialgraph): $*"; exit 2; }
plan() { echo "PLAN (socialgraph): $*"; }
N=${1:-}; K=${2:-}; shift 2 2>/dev/null || die "usage: runset-sg.sh <N> <run> --only <sys>:<mix> [--dry] [--v V]"
ONLY= DRY=0 VER=
while [ $# -gt 0 ]; do case $1 in --only) ONLY=${2:-}; shift 2;; --dry) DRY=1; shift;; --v) VER=${2:-}; shift 2;; *) die "unknown argument $1";; esac; done
[[ $N =~ ^[248]$ ]] || die "N must be 2, 4 or 8"
[[ $ONLY =~ ^(hw|pop|ds|mgc|mgr):(rw100|rw470)$ ]] || die "--only <sys>:<mix> (sys hw|pop|ds|mgc|mgr, mix rw100|rw470), got '$ONLY'"
S=${ONLY%%:*} MIX=${ONLY#*:}
[ -z "$VER" ] || [[ $VER =~ ^[1-9][0-9]*$ ]] || die "bad --v"
CONF=${EVAL_CONF:-$EX/socialgraph.conf}
[ -f "$CONF" ] || die "conf $CONF missing"
# conf: KEY=value lines, values unquoted or in double quotes, '#' comments; parsed, never executed
CONFSH=$(python3 -I -B - "$CONF" <<'PY'
import re, shlex, sys
for n, line in enumerate(open(sys.argv[1]), 1):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    m = re.match(r'^([A-Z][A-Z0-9_]*)=("([^"]*)"|([^\s#]*))\s*(#.*)?$', s)
    if not m:
        sys.exit(f"line {n}: not KEY=value: {s}")
    print(f"{m.group(1)}={shlex.quote(m.group(3) if m.group(3) is not None else m.group(4))}")
PY
) || die "$CONF does not parse"
eval "$CONFSH"
ab() { case $1 in /*) echo "$1";; *) echo "$P/$1";; esac; }
[[ $K =~ ^[1-9]$ ]] && [ "$K" -le "$RUNS" ] || die "run must be 1..RUNS=$RUNS (got '$K')"
[[ " $SG_SYSTEMS " == *" $S "* ]] && [[ " $SG_MIXES " == *" $MIX "* ]] && [[ " $SG_NODES " == *" $N "* ]] || die "$S:$MIX at N=$N is not in the conf's systems / mixes / nodes"
[ $S != mgr ] || [ "$N" = 2 ] || die "mgr (Megalon record granularity) is N = 2 only (user 2026-11-11)"
if [ "$TREE" != "$P/CXL_SWMC" ]; then [ $DRY = 1 ] || die "real runs only from the live tree $P/CXL_SWMC (this is $TREE)"; plan "code tree $TREE (worktree)"; fi
COMMIT=$(git -C "$TREE" rev-parse HEAD) DIRTY=$(git -C "$TREE" status --porcelain --untracked-files=no | wc -l)
[ $DRY = 1 ] || [ "$DIRTY" = 0 ] || die "$TREE is dirty ($DIRTY files)"
. "$TREE/experiments/eval/recv-mode.sh"
POP_ADAPT_KO=$(ab "$POP_ADAPT_KO")
export RECV_IPOLL RECV_WATCH_US RECV_S_MAX_US REQUIRE_ADAPTIVE POP_ADAPT_KO
if why=$(recv_run2_guard); then plan "run-2 guard: adaptive receiver for pop and ds, POP_ADAPT_KO set: OK"
elif [ $DRY = 1 ]; then plan "run-2 guard: $why (a real run stops here)"; else die "run-2 guard: $why"; fi
for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do
  if [ -d "${!v:-}" ]; then plan "$v=${!v}"; elif [ $DRY = 1 ]; then plan "$v not set (required for the real run)"; else die "$v must name an existing dir"; fi
done
if [ -e "$P/workspaces/MEASUREMENT.lock" ]; then
  [ $DRY = 1 ] || die "workspaces/MEASUREMENT.lock exists ($(cat "$P/workspaces/MEASUREMENT.lock"))"
  plan "MEASUREMENT.lock is held now: the real run would stop here"
fi
POPC=$(ab "$POP_C") REG=$(ab "$REGION")
[ "$(grep -E '^msg_ring:' "$REG" | cut -d'#' -f1 | tr -d ' ')" = "$(grep -E '^msg_ring:' "$POPC/tools/cxl_region.yaml" | cut -d'#' -f1 | tr -d ' ')" ] \
  || die "REGION msg_ring differs from the Popcorn bundle's region"
BENV=(SG_N=$N SG_VCPU=$VCPUS_PER_VM SG_SYS=$S SG_MIX=$MIX EVAL_RUN=$K SEED=$((SEED_BASE + K)) REGION=$REG
  C8=$POPC K8=$POP_K GT8=$POP_GT RECV_MODE=$RECV_MODE POP_BUNDLE_SHA=$POP_BUNDLE_SHA EXPECT_DAX_UUID=$EXPECT_DAX_UUID
  VPLAIN=$SG_VPLAIN PLAIN_BUILD=$(ab "$SG_PLAIN_BUILD") LOADGEN_BUILD=$(ab "$SG_LOADGEN_BUILD") IMAGE_HOST=$(ab "$SG_IMAGE_HOST")
  GEN_HOST=$(ab "$SG_GEN_HOST") IMAGE_GUEST=$SG_IMAGE_GUEST "SG_SLO_PART=$SG_SLO_PART" SG_SLO=$SG_SLO SG_READY_TIMEOUT=$SG_READY_TIMEOUT
  SG_STALE_EVERY=$SG_STALE_EVERY SG_CXLBW=$SG_CXLBW SG_PMAX=$SG_PMAX
  SG_START_FALLBACK=${SG_START_FALLBACK:-0} SG_START_FALLBACK_RATE=${SG_START_FALLBACK_RATE:-100} SG_WRITE_ROUTE=${SG_WRITE_ROUTE:-mod}
  RECV_IPOLL=$RECV_IPOLL RECV_WATCH_US=$RECV_WATCH_US RECV_S_MAX_US=$RECV_S_MAX_US POP_ADAPT_KO=$POP_ADAPT_KO REQUIRE_ADAPTIVE=$REQUIRE_ADAPTIVE)
[ -z "${SG_FIXED_RATE:-}" ] || { BENV+=(SG_FIXED_RATE=$SG_FIXED_RATE SG_FIXED_S=${SG_FIXED_S:-60}); plan "fixed rate ${SG_FIXED_RATE} req/s (conf SG_FIXED_RATE: smoke, no SLO search)"; }
PMF=; for g in ${SG_PMAX_FROM:-}; do PMF+="${PMF:+ }$(ab "$g")"; done
[ -z "$PMF" ] || BENV+=("SG_PMAX_FROM=$PMF")
for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do BENV+=("$v=${!v:-$P/recovery}"); done
case $S in
  ds) BENV+=(VPLAIN=$SG_DS_VPLAIN DS_C=$(ab "$SG_DS_C") DS_BUNDLE_SHA=$SG_DS_BUNDLE_SHA DS_K=$SG_DS_K DS_GT=$SG_DS_GT
        DS_REGION=$(ab "$SG_DS_REGION") DS_T_US=$SG_DS_T_US "DS_RECV_EXTRA=$SG_DS_RECV_EXTRA")
      [ -f "$(ab "$SG_DS_C")/p-destijl-shm.sh" ] || die "De Stijl bundle $SG_DS_C missing"
      [ "$(sha256sum < "$(ab "$SG_DS_C")/packet.sha256" | cut -c1-64)" = "$SG_DS_BUNDLE_SHA" ] || die "De Stijl bundle packet.sha256 != SG_DS_BUNDLE_SHA"
      [[ $SG_DS_K == *-ds-destijl-7 ]] && plan "SG_DS_* are the build-7 placeholders (a chain resolves them to the build-10 bundle)";;
  mgc|mgr)
    x() { local v=SG_MG_$1_N$N; echo "${!v:-}"; }
    vv=SG_VMEG_N$N   # guest dir keys are SG_VMEG_N<N> in socialgraph.conf (not SG_MG_VMEG_N<N>)
    if [ $S = mgr ]; then CFG=$SG_MG_CFG_REC_N2 VM=$SG_VMEG_REC_N2 LAY=record; else CFG=$(x CFG) VM=${!vv:-} LAY=chunk; fi
    BENV+=(MEG_BUILD=$(ab "$(x BUILD)") MEG_LIB=$(ab "$(x LIB)") MEG_CFG=$(ab "$CFG") VMEG=$VM MEG_LAYOUT=$LAY MEG_CHUNK_BYTES=$SG_MG_CHUNK_BYTES);;
esac
n=${VER:-1}; NAMEB=$EVIDENCE_NAME; NAMEB=${NAMEB//\{SYS\}/$S}; NAMEB=${NAMEB//\{MIX\}/$MIX}; NAMEB=${NAMEB//\{N\}/$N}; NAMEB=${NAMEB//\{RUN\}/$K}
[[ $NAMEB =~ ^[a-z0-9-]+$ ]] || die "bad evidence name $NAMEB"
RR=$(ab "$RESULTS_ROOT")
if [ -z "$VER" ]; then while [ -e "$RR/$NAMEB-v$n" ]; do n=$((n + 1)); done; fi
E=$RR/$NAMEB-v$n
[ ! -e "$E" ] || die "$E exists (evidence dirs are immutable)"
plan "evidence dir $E (absent: OK)"
plan "cell $S:$MIX N=$N run $K conf $CONF (sha256 $(sha256sum < "$CONF" | cut -c1-16))"
plan "block: env ${BENV[*]} bash $EX/sg-block.sh <E>/block"
if [ $DRY = 1 ]; then
  t=$(mktemp -d /tmp/sg-dry-XXXXXX) && touch "$t/not-empty"
  out=$(env SG_BLOCK_DRY=1 "${BENV[@]}" bash "$EX/sg-block.sh" "$t" 2>&1); rc=$?
  rm -rf "$t"
  echo "$out" | grep -E '^BLOCK (PLAN|DRY NOTE|NOTE)' | while IFS= read -r l; do plan "block dry: $l"; done
  [ $rc = 0 ] && echo "$out" | grep -q "BLOCK DRY STOP: evidence-dir check reached" || die "block dry start failed: $(echo "$out" | tail -n 2 | tr '\n' ' ')"
  echo "DRY START OK (socialgraph $S:$MIX N=$N run $K): stops here, before the lock"; exit 0
fi
mkdir "$E" && mkdir "$E/block" || die "mkdir $E"
log() { echo "$(date -Is) [socialgraph $S:$MIX n$N run $K] $*" | tee -a "$E/eval-state.txt"; }
{ echo "# socialgraph run-set manifest (experiments/socialgraph/runset-sg.sh)"
  echo "cell=$S:$MIX nodes=$N run=$K evidence=$E start=$(date -Is) pid=$$"
  echo "code_tree=$TREE commit=$COMMIT dirty_files=$DIRTY dirty_diff_sha256=$(git -C "$TREE" diff HEAD | sha256sum | cut -c1-64)"
  echo "eval_conf=$CONF sha256=$(sha256sum < "$CONF" | cut -c1-64)"; echo "$CONFSH" | sed 's/^/conf: /'
  for b in "$(ab "$SG_PLAIN_BUILD")" "$(ab "$SG_LOADGEN_BUILD")" $( [[ $S == mg* ]] && echo "$(ab "$(x BUILD)")" ); do
    echo "build $b manifest_sha256=$(sha256sum < "$b/manifest.txt" | cut -c1-64) $(grep -m1 '^source_commit=' "$b/manifest.txt")"; done
  echo "image $(ab "$SG_IMAGE_HOST") $(cat "$(dirname "$(ab "$SG_IMAGE_HOST")")/image.sha256" 2>/dev/null | tr '\n' ' ')"
  echo "PRETOUCH_DIR=${PRETOUCH_DIR:-} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-} MEASURE_PART_DIR=${MEASURE_PART_DIR:-}"
} > "$E/eval-manifest.txt"
log "block start"
env "${BENV[@]}" bash "$EX/sg-block.sh" "$E/block" > "$E/sequence.log" 2>&1
log "block rc $?: $(tail -n 1 "$E/sequence.log")"
grep -q "BLOCK DONE" "$E/block/block.log" 2>/dev/null || { log "SEQUENCE STOP block did not finish"; exit 1; }
! grep -q "ROLLBACK FAIL\|CLEANUP FAILED" "$E/block/rollback.out" "$E/block/cleanup.out" 2>/dev/null || { log "SEQUENCE STOP rollback / cleanup failure lines"; exit 1; }
[ "$(grep -vc '^#' "$E/block/sg-results.tsv")" = 1 ] || { log "SEQUENCE STOP sg-results.tsv rows != 1"; exit 1; }
D=$(ab "$DERIVED_ROOT"); mkdir -p "$D"
cp "$E/block/$S-$MIX-n$N/steps.csv" "$D/steps-$S-$MIX-n$N-r$K-v$n.csv" 2>/dev/null && log "derived $D/steps-$S-$MIX-n$N-r$K-v$n.csv" || log "RUNSET NOTE: no steps.csv"
log "RUNSET DONE: $(grep -v '^#' "$E/block/sg-results.tsv" | cut -f1,6,7,8,11 | tr '\t' ' ')"

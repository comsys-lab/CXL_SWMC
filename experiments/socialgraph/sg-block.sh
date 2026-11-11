#!/bin/bash
# socialgraph-serving block: ONE server lifetime (system, mix) on N VMs with ONE aggregate SLO search of the feed query
# (reports/experiments/socialgraph-serving.md §2-3). Generalised from experiments/eval/h2n-block.sh (vector DB, run 2):
# same lock / pretouch / gate / guest precheck / dmesg / dax owner / Popcorn and De Stijl cxl_shm cycles / receiver
# apply + readback (experiments/eval/recv-mode.sh) / EXIT-trap rollback, with the vector DB parts replaced by the graph
# image copy (node 0, plain mapping, before the enable; = the vector DB --preload-only step) and dropped what socialgraph
# does not use (L1, DAMON, fixed windows, replica modes, directory variants, accuracy export).
# Called by experiments/socialgraph/runset-sg.sh (never by hand in a real run).
# usage: sg-block.sh <evidence dir (exists; empty except sequence*)>
# env (runset-sg.sh): SG_N (2..8), SG_VCPU (4), SG_SYS (hw | pop | ds | mgc | mgr), SG_MIX (rw100 | rw470), EVAL_RUN,
#   SEED, REGION, C8 K8 GT8 RECV_MODE POP_BUNDLE_SHA, PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR, EXPECT_DAX_UUID,
#   VPLAIN (guest install of the plain build), PLAIN_BUILD, LOADGEN_BUILD, IMAGE_HOST (graph.img on the Host, also read by
#   the loadgen), GEN_HOST (its gen.json), IMAGE_GUEST (graph.img on vm0's disk), SG_SLO_PART (loadgen SLO arguments,
#   without --slo), SG_SLO (feed:99:10), SG_READY_TIMEOUT (s), SG_STALE_EVERY, SG_CXLBW (0 | 1),
#   SG_START_FALLBACK (0 | 1) + SG_START_FALLBACK_RATE (100), SG_WRITE_ROUTE (mod | range);
#   pmax (pop / ds): SG_PMAX (0 | 1), SG_PMAX_FROM (ds: pop results files, globs), SG_PMAX_WARMUP_S/_MEASURE_S/_DRAIN_S;
#   De Stijl (ds): DS_C DS_BUNDLE_SHA DS_K DS_GT DS_REGION DS_T_US (T in us; the doc's T = 1000 ms -> 1000000), DS_RECV_EXTRA;
#   Megalon (mgc = 32 MiB chunks, mgr = one object per record): MEG_BUILD (builds/socialgraph-megalon/1-n<N>), MEG_LIB,
#   MEG_CFG (systems/megalon/socialgraph-<N>vm[-record].yaml), VMEG (guest install of the Megalon build), MEG_LAYOUT
#   (record | chunk), MEG_CHUNK_BYTES (33554432).
# Max RPS under SLO (doc §2) = sg-results.tsv confirm_x_mean (= max_feed_rps_under_slo when confirmed): completed feed
#   queries / s summed over the VMs (loadgen --x-stream feed), NOT max_offered_x_pass (total offered requests / s).
# Outputs: E/sg-results.tsv (one row), E/<sys>-<mix>-n<N>/ (sg-run.sh run dir: slo/, pmax/, stale/, clock-offset.tsv),
#   E/<name>/steps.csv (sg_steps.py: the doc's §2 columns), E/<name>/stale.json (whole-search join), E/block.log, ...
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control
EX=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EX/../.." && pwd)
EV=$TREE/experiments/eval XV=$TREE/experiments/vectordb XK=$TREE/experiments/rocksdb
HG=$TREE/scripts/host/h3-gate.sh
die() { echo "BLOCK STOP: $*"; exit 2; }
DRYB=${SG_BLOCK_DRY:-0}
pending() { if [ "$DRYB" = 1 ]; then echo "BLOCK DRY NOTE: $* (a real run stops here)"; else die "$*"; fi; }
: "${SG_N:?}" "${SG_VCPU:?}" "${SG_SYS:?}" "${SG_MIX:?}" "${EVAL_RUN:?}" "${SEED:?}" "${REGION:?}" "${C8:?}" "${K8:?}" "${GT8:?}"
: "${RECV_MODE:?}" "${POP_BUNDLE_SHA:?}" "${PRETOUCH_DIR:?}" "${MEASURE_ENV_DIR:?}" "${MEASURE_PART_DIR:?}" "${EXPECT_DAX_UUID:?}"
: "${VPLAIN:?}" "${PLAIN_BUILD:?}" "${LOADGEN_BUILD:?}" "${IMAGE_HOST:?}" "${GEN_HOST:?}" "${IMAGE_GUEST:?}" "${SG_SLO_PART:?}" "${SG_SLO:?}"
N=$SG_N VCPU=$SG_VCPU S=$SG_SYS MIX=$SG_MIX
[[ $N =~ ^[2-8]$ ]] || die "SG_N must be 2..8"
[[ $VCPU =~ ^[2-9]$ ]] || die "bad SG_VCPU"
[[ $EVAL_RUN =~ ^[1-9]$ ]] && [[ $SEED =~ ^[0-9]+$ ]] || die "bad EVAL_RUN / SEED"
case $S in hw|pop|ds|mgc|mgr) ;; *) die "bad SG_SYS $S (hw | pop | ds | mgc | mgr)";; esac
case $MIX in rw100|rw470) ;; *) die "bad SG_MIX $MIX (rw100 | rw470)";; esac
RW=${MIX#rw}
[ "$SG_SLO" = feed:99:10 ] || die "SG_SLO=$SG_SLO (the doc's SLO is feed:99:10)"
[ $S != mgr ] || [ "$N" = 2 ] || die "Megalon record granularity is N = 2 only (user 2026-11-11)"
. "$EV/recv-mode.sh"
[[ $RECV_MODE =~ ^(poll|idle|sleep|adaptive)$ ]] || die "bad RECV_MODE"
PRM=${POP_RECV_MODE:-$RECV_MODE} IPOLL=${RECV_IPOLL:-}
[[ $IPOLL =~ ^[01]?$ ]] || die "bad RECV_IPOLL"
why=$(recv_wsm_check); [ $? != 1 ] || die "$why"
PMON=${SG_PMAX:-0} PMFROM=${SG_PMAX_FROM:-} PMW=${SG_PMAX_WARMUP_S:-15} PMM=${SG_PMAX_MEASURE_S:-90} PMD=${SG_PMAX_DRAIN_S:-5}
[[ $PMON =~ ^[01]$ ]] && [[ $PMW =~ ^[0-9]+$ ]] && [[ $PMM =~ ^[1-9][0-9]*$ ]] && [[ $PMD =~ ^[0-9]+$ ]] || die "bad SG_PMAX*"
FIXR=${SG_FIXED_RATE:-}
[ -z "$FIXR" ] || { [[ $FIXR =~ ^[1-9][0-9]*$ ]] && [[ ${SG_FIXED_S:-60} =~ ^[1-9][0-9]*$ ]]; } || die "bad SG_FIXED_RATE / SG_FIXED_S"
# SG_START_FALLBACK (methodology pending the user; default 0 = off): slo ramp failing at --start -> rerun once from
# SG_START_FALLBACK_RATE (100). SG_WRITE_ROUTE (pending; default mod): loadgen write_route and sg-server --write-route
# (mod: owner = slot % N; range: contiguous slot ranges per VM, layout.h slot_owner); always the same value on both sides.
SFB=${SG_START_FALLBACK:-0} SFBR=${SG_START_FALLBACK_RATE:-100} WR=${SG_WRITE_ROUTE:-mod}
[[ $SFB =~ ^[01]$ ]] && [[ $SFBR =~ ^[1-9][0-9]*$ ]] || die "bad SG_START_FALLBACK / SG_START_FALLBACK_RATE"
[[ $WR =~ ^(mod|range)$ ]] || die "bad SG_WRITE_ROUTE $WR (mod | range)"
CXLBW=${SG_CXLBW:-0} RDYT=${SG_READY_TIMEOUT:-900} STE=${SG_STALE_EVERY:-1000}
[[ $CXLBW =~ ^[01]$ ]] && [[ $RDYT =~ ^[1-9][0-9]*$ ]] && [[ $STE =~ ^[1-9][0-9]*$ ]] || die "bad SG_CXLBW / SG_READY_TIMEOUT / SG_STALE_EVERY"
KEXP=$K8 DST=0 DSRX=${DS_RECV_EXTRA:-} DSFP=0
if [ $S = ds ]; then
  : "${DS_C:?}" "${DS_BUNDLE_SHA:?}" "${DS_K:?}" "${DS_GT:?}" "${DS_T_US:?}"
  [[ $DS_K == *-ds-destijl-* ]] || die "DS_K=$DS_K is not a De Stijl release"
  why=$(recv_rules ds "$RECV_MODE" "$DS_C" "$N") || die "De Stijl receiver: $why"
  [[ $DS_T_US =~ ^(0|[1-9][0-9]*)$ ]] || die "bad DS_T_US"
  DST=$DS_T_US KEXP=$DS_K REGION=${DS_REGION:-$TREE/config/cxl_region-destijl.yaml}
  [[ $DSRX =~ ^(((idle_sleep_us|idle_spin_us)=[0-9]+|fault_poll=[01])( |$))*$ ]] || die "bad DS_RECV_EXTRA"
  [[ " $DSRX " != *" fault_poll=1 "* ]] || DSFP=1
  [ -f "$REGION" ] && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -c1-64)" = "$DS_BUNDLE_SHA" ] \
    || die "De Stijl region ($REGION) or bundle ($DS_C) does not verify"
  [ "$(grep -E '^msg_ring:' "$REGION" | cut -d'#' -f1 | tr -d ' ')" = "$(grep -E '^msg_ring:' "$DS_C/tools/cxl_region.yaml" | cut -d'#' -f1 | tr -d ' ')" ] \
    || die "REGION msg_ring differs from the De Stijl bundle's region"
else
  [ -f "$REGION" ] && [ "$(sha256sum < "$C8/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] && (cd "$C8" && sha256sum -c --quiet packet.sha256) \
    || die "REGION or the Popcorn bundle ($C8) does not verify"
fi
POPSV=-
if [ $S = pop ]; then
  why=$(recv_rules pop "$PRM" "$C8" "$N") || die "Popcorn receiver: $why"
  [ "$PRM" != adaptive ] || POPSV=$(recv_pop_srcversion)
fi
RMODES=; [ $S != pop ] || RMODES=$PRM; [ $S != ds ] || RMODES=$RECV_MODE
if [ -n "${RECV_WATCH_US:-}${RECV_S_MAX_US:-}" ] && [ -n "$RMODES" ]; then why=$(recv_wsm_check $RMODES) || pending "$why"; fi
IPS=() DOMS=()
for k in $(seq 0 $((N - 1))); do IPS+=(192.168.122.$((100 + k))); DOMS+=(cxl_vm$k); done
export NODES="${IPS[*]}" VM_DOMAINS="${DOMS[*]}" POP_IPS="${IPS[*]}" EXPECT_RUNNING="${DOMS[*]}"
export MEASURE_ENV_DIR MEASURE_PART_DIR H1_MEASURE_RUN=1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
HOSTSRV=$PLAIN_BUILD/bin/sg-server LOADGEN=$LOADGEN_BUILD/loadgen MIXB=$LOADGEN_BUILD/bin/sg-loadgen-mix
for f in "$HOSTSRV" "$LOADGEN" "$MIXB" "$IMAGE_HOST" "$GEN_HOST" "$EX/sg-run.sh" "$EX/sg_steps.py" "$EX/clock_offset_log.py" \
  "$TREE/scripts/guest/sg-node.sh" "$TREE/workloads/socialgraph/tools/sg_stale_join.py"; do [ -e "$f" ] || die "missing $f"; done
LMIX=$("$MIXB" "$RW") || die "sg-loadgen-mix $RW"
# server arguments (plain: one per VM, 3 query threads + 1 writer at 4 vCPU = online CPUs - 1)
SA="--nodes $N --query-threads $((VCPU - 1)) --start-timeout-ms $((RDYT * 1000)) --write-route $WR"
APP=$("$HOSTSRV" $SA --print-app-bytes) || die "print-app-bytes ($HOSTSRV, --nodes $N)"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
[ $((APP + ${RING:-0})) -lt 268435456 ] || die "app HWcc $APP B + ring $RING B exceed the 256 MiB HWcc budget"
V=$VPLAIN SRV=$HOSTSRV
INSTALL="${VPLAIN#/home/comsys/}/bin/sg-server $HOSTSRV
${VPLAIN#/home/comsys/}/bin/sg-node.sh $TREE/scripts/guest/sg-node.sh
${VPLAIN#/home/comsys/}/cfg/cxl_region.yaml $REGION"
MGSA= NODE0_ARGS= NENV= N0ENV=
case $S in
  mgc|mgr)
    : "${MEG_BUILD:?}" "${MEG_LIB:?}" "${MEG_CFG:?}" "${VMEG:?}" "${MEG_LAYOUT:?}"
    [ "$MEG_LAYOUT" = "$([ $S = mgr ] && echo record || echo chunk)" ] || die "MEG_LAYOUT=$MEG_LAYOUT does not match $S"
    for f in "$MEG_BUILD/bin/sg-server" "$MEG_BUILD/manifest.txt" "$MEG_CFG" "$MEG_LIB/manifest.txt"; do [ -f "$f" ] || pending "Megalon input missing for N = $N: $f"; done
    if [ -f "$MEG_BUILD/manifest.txt" ] && [ -f "$MEG_LIB/manifest.txt" ]; then
      grep -q "^megalon_build=$MEG_LIB\$" "$MEG_BUILD/manifest.txt" || die "$MEG_BUILD is not on $MEG_LIB"
      for c in constants_h_LOGICAL_NODE_NUM constants_rs_LOGICAL_NODE_NUM; do grep -qx "$c=$N" "$MEG_LIB/manifest.txt" || die "$MEG_LIB: $c != $N"; done
    fi
    MGSA="--backend megalon --object-layout $MEG_LAYOUT --chunk-bytes ${MEG_CHUNK_BYTES:-33554432} $SA"
    SRV=$MEG_BUILD/bin/sg-server V=$VMEG
    [ ! -x "$SRV" ] || APP=$("$SRV" $MGSA --print-app-bytes) || die "print-app-bytes (Megalon)"
    NODE0_ARGS="--image $IMAGE_GUEST" NENV="ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml" N0ENV="ENV:MEGALON_REINIT=1"
    VM=${VMEG#/home/comsys/}
    INSTALL="$VM/bin/sg-server $MEG_BUILD/bin/sg-server
$VM/bin/sg-node.sh $TREE/scripts/guest/sg-node.sh
$VM/lib/libmegalon-objapi.so $MEG_BUILD/lib/libmegalon-objapi.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/lib/libtbb.so.12 $MEG_BUILD/lib/libtbb.so.12
$VM/lib/libtbbmalloc.so.2 $MEG_BUILD/lib/libtbbmalloc.so.2
$VM/lib/libhwloc.so.15 $MEG_BUILD/lib/libhwloc.so.15
$VM/lib/libatomic.so.1 $MEG_BUILD/lib/libatomic.so.1
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $REGION";;
  ds) NENV="ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=$DST";;
esac
NAME=$S-$MIX-n$N
SYSL=$(case $S in hw) echo all-HWcc;; pop) echo "Popcorn-$PRM";; ds) echo "DeStijl-$RECV_MODE-T$DST";; mgc) echo Megalon-chunk;; mgr) echo Megalon-record;; esac)
SAMPLER=$EV/cxl-bw-sampler.sh
[ $CXLBW = 0 ] || [ -f "$SAMPLER" ] || die "SG_CXLBW=1 needs $SAMPLER"
pm_from() {  # ds: --from arguments (SG_PMAX_FROM globs, {MIX} {N} {RUN} replaced; newest version last)
  local g f
  for g in $PMFROM; do g=${g//\{MIX\}/$MIX}; g=${g//\{N\}/$N}; g=${g//\{RUN\}/$EVAL_RUN}
    for f in $(ls -d $g 2>/dev/null | sort -V); do printf -- '--from %s ' "$f"; done; done; }
OWNER=sg-$NAME-run$EVAL_RUN
echo "BLOCK PLAN: socialgraph $NAME ($SYSL) N=$N vcpu/VM=$VCPU threads $((VCPU - 1))+1 nodes=[${IPS[*]}] rw=$RW mix=[$LMIX] app=$APP ring=${RING:-0} cxlbw=$CXLBW"
echo "BLOCK PLAN: server_args=[${MGSA:-$SA}] node0_args=[$NODE0_ARGS] node_env=[$NENV] node0_env=[$N0ENV] region=$REGION release=$KEXP"
echo "BLOCK PLAN: image host=$IMAGE_HOST guest(vm0)=$IMAGE_GUEST$(case $S in hw|pop|ds) echo " -> region by sg-node.sh copy-image + verify before the run";; *) echo " -> Megalon objects (node 0 --image)";; esac); slo [$SG_SLO $SG_SLO_PART]; stale 1 in $STE"
[ -z "$FIXR" ] || echo "BLOCK PLAN: fixed rate $FIXR req/s for ${SG_FIXED_S:-60} s (smoke; no SLO search, no pmax step)"
echo "BLOCK PLAN: receiver pop=$([ $S = pop ] && echo "$PRM${POP_ADAPT_KO:+ ko=$POP_ADAPT_KO srcversion=$POPSV}" || echo -) ds=$([ $S = ds ] && echo "$RECV_MODE extra=[$DSRX] fault_poll=$DSFP T=$DST us" || echo -) ipoll=${IPOLL:-default} $(recv_wsm_desc)"
[ $PMON = 0 ] || [[ ! $S =~ ^(pop|ds)$ ]] || echo "BLOCK PLAN: pmax step: --mode fixed --rates <Popcorn's max of this cell> ${PMW}s+${PMM}s+${PMD}s ($([ $S = pop ] && echo "own slo part" || echo "pop rows of [$PMFROM]: $(python3 -I -B "$EX/sg_steps.py" pmax-rate --name "pop-$MIX-n$N" $(pm_from) 2>&1)"))"
if [ "$DRYB" = 1 ]; then echo "BLOCK DRY STOP: evidence-dir check reached ($E; dry: no lock, no VM contact)"; exit 0; fi
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || die "$E missing or not empty"
# ------------------------------------------------------------------------------------------------- real block
bash "$HG" lock "$OWNER" || die "lock"
DMESG_DONE=0 OWNED=root
log() { echo "$(date -Is) $*" | tee -a "$E/block.log"; }
stop() { log "BLOCK STOP $*"; exit 1; }
RECV_STOP=stop
if [ $CXLBW = 1 ]; then setsid nohup bash "$SAMPLER" "$E/cxlbw" > "$E/cxlbw.log" 2>&1 < /dev/null & log "cxl-bw sampler pid $! -> $E/cxlbw"; fi
PAT='[/]bin/sg-server( |$)'
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip "pgrep -c -f -- '$PAT'" < /dev/null)" = 0 ] || return 1; done; }
dax_unused() {
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'f=$(sudo -n fuser /dev/dax0.0 2>&1); r=$?; echo "dax_users=[$f] rc=$r"' < /dev/null 2>&1)
    echo "$(date -Is) $1 $ip $out" >> "$E/dax-users.txt"
    [ "$out" = "dax_users=[] rc=1" ] || return 1
  done
}
dax_owner() {  # comsys | root, every VM, stat checked (h2n-block.sh)
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
dmesg_check() {
  local i n c bad=0
  for i in "${!IPS[@]}"; do
    n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null); c=$(dmesg_count $i) || { bad=1; continue; }
    [[ $n =~ ^[0-9]+$ ]] && [ "$c" -ge "$n" ] || { log "dmesg vm$i ($1): baseline '$n' -> $c"; bad=1; continue; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 || { bad=1; continue; }
    grep -qE "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" && { log "dmesg vm$i ($1): $(grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)"; bad=1; }
  done
  return $bad
}
shm_teardown_left() {  # a cxl_shm load of this block without "teardown PASS" (Popcorn or De Stijl)
  local r
  for r in "$E"/shm-*/ "$E"/dsshm-*/; do
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    dax_unused cleanup || { echo "CLEANUP FAILED: $r: /dev/dax0.0 in use, teardown not attempted" | tee -a "$E/cleanup.out"; continue; }
    if [[ $r == */dsshm-* ]]; then env K=$DS_K GT=$DS_GT C=$DS_C R=$r bash $DS_C/p-destijl-shm.sh teardown >> "$E/cleanup.out" 2>&1
    else env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; fi
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r" | tee -a "$E/cleanup.out"
  done
}
finish() {
  trap '' INT TERM HUP
  set +eu
  pkill -TERM -P $$ 2>/dev/null; sleep 1
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "pkill -u comsys -f -- '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f -- '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f -- '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f -- '$PAT')" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" || echo "ROLLBACK FAIL: $ip server process left (see rollback.out)" | tee -a "$E/rollback.out"
  done
  shm_teardown_left
  dax_unused rollback || echo "ROLLBACK FAIL: /dev/dax0.0 in use on a VM (see dax-users.txt)" | tee -a "$E/rollback.out"
  dax_owner root || echo "ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see dax-owner.txt)" | tee -a "$E/rollback.out"
  [ $DMESG_DONE = 0 ] || { dmesg_check final || echo "$(date -Is) final dmesg check: see block.log" >> "$E/rollback.out"; }
  bash "$HG" unlock "$OWNER"
}
trap finish EXIT
trap 'log "BLOCK STOP signal"; exit 130' INT TERM HUP
gate() { bash "$HG" check "$E/gate-$1.txt" > /dev/null || stop "h3 gate ($1; see gate-$1.txt)"; }
{ echo "# socialgraph block $OWNER: $NAME system=$SYSL N=$N vcpu/VM=$VCPU seed=$SEED rw=$RW"
  echo "nodes=${IPS[*]} server_args=[${MGSA:-$SA}] node0_args=[$NODE0_ARGS] node_env=[$NENV] node0_env=[$N0ENV] app_hwcc=$APP ring=${RING:-0} region_sha256=$(sha256sum < "$REGION" | cut -c1-64)"
  echo "host_server=$SRV sha256=$(sha256sum < "$SRV" | cut -c1-64) loadgen=$LOADGEN sha256=$(sha256sum < "$LOADGEN" | cut -c1-64)"
  echo "image_host=$IMAGE_HOST bytes=$(stat -c %s "$IMAGE_HOST") gen=$GEN_HOST sha256=$(sha256sum < "$GEN_HOST" | cut -c1-64) image_guest=$IMAGE_GUEST"
  [[ $S != mg* ]] || echo "megalon_build=$MEG_BUILD lib=$MEG_LIB cfg=$MEG_CFG sha256=$(sha256sum < "$MEG_CFG" | cut -c1-64) vmeg=$VMEG layout=$MEG_LAYOUT"
  echo "slo=$SG_SLO slo_part=[$SG_SLO_PART] mix=[$LMIX] stale_every=$STE pmax=$PMON from=[$PMFROM]"
  echo "start_fallback=$SFB start_fallback_rate=$SFBR write_route=$WR (loadgen --opt write_route + sg-server --write-route)"
  echo "receiver: pop_recv_mode=$PRM pop_adapt_ko=${POP_ADAPT_KO:--} pop_srcversion=$POPSV ds_recv_mode=$RECV_MODE ds_extra=[$DSRX] ipoll=${IPOLL:-default} $(recv_wsm_desc)"
  [ $S != ds ] || echo "destijl: bundle=$DS_C bundle_sha=$DS_BUNDLE_SHA release=$DS_K guest_tools=$DS_GT region=$REGION t_us=$DST"
  for d in "${DOMS[@]}"; do x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null); echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -c1-64)"; done
} > "$E/sg-params.txt"
log "== PT pretouch check (start, $N VMs)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start)"
log "== H0 h3 gate"; gate H0
log "== guest prechecks (install sha256 = Host builds; image on vm0)"
for i in "${!IPS[@]}"; do
  $SSH comsys@${IPS[$i]} "EXPECT_K=$KEXP EXPECT_DAX_UUID=$EXPECT_DAX_UUID INIT_DIR=/nonexistent INIT_CHECK=0 INSTALL_DIRS='$(echo "$INSTALL" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
    < $XV/m4-precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "^PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i: $(grep -m1 'PRECHECK FAIL' "$E/precheck-vm$i.txt")"
  while read -r g h; do
    grep -q "^$(sha256sum < "$h" | cut -c1-64)  /home/comsys/$g\$" "$E/precheck-vm$i.txt" || stop "vm$i /home/comsys/$g != $h (install needed)"
  done <<< "$INSTALL"
  [ "$($SSH comsys@${IPS[$i]} nproc < /dev/null)" = "$VCPU" ] || stop "vm$i nproc != $VCPU"
done
# image on vm0: the install wrote <img>.sha256 (sg-install.sh, full hash = the Host image's); size + recorded hash checked here
IMGSHA=$(sed -n 's/^sha256=//p' "$(dirname "$IMAGE_HOST")/image.sha256" 2>/dev/null)
[ -n "$IMGSHA" ] || IMGSHA=$(sha256sum < "$IMAGE_HOST" | cut -c1-64)
out=$($SSH comsys@${IPS[0]} "stat -c %s $IMAGE_GUEST; cat $IMAGE_GUEST.sha256" < /dev/null 2>&1 | tr '\n' ' ')
echo "$(date -Is) vm0 image $IMAGE_GUEST: $out (host sha256 $IMGSHA)" >> "$E/image-check.txt"
[ "$out" = "$(stat -c %s "$IMAGE_HOST") sha256=$IMGSHA " ] || stop "vm0 image $IMAGE_GUEST differs from $IMAGE_HOST ($out; run sg-install.sh image)"
for i in "${!IPS[@]}"; do c=$(dmesg_count $i) || stop "dmesg baseline vm$i"; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
DMESG_DONE=1
image_copy() {  # plain mapping on node 0, coherence not enabled yet; then a read-only verify (sg-node.sh)
  local t; t=$(date +%s)
  $SSH comsys@${IPS[0]} "mkdir -p $VPLAIN/runs; $VPLAIN/bin/sg-node.sh copy-image $VPLAIN $IMAGE_GUEST $VPLAIN/runs/copy-$NAME-$t.log > /dev/null; cat $VPLAIN/runs/copy-$NAME-$t.log" \
    < /dev/null > "$E/image-copy.log" 2>&1
  grep -q "sg-server: COPY DONE" "$E/image-copy.log" && grep -q "^copy-image rc=0 " "$E/image-copy.log" || stop "image copy ($E/image-copy.log)"
  $SSH comsys@${IPS[0]} "$VPLAIN/bin/sg-node.sh verify $VPLAIN $IMAGE_GUEST $VPLAIN/runs/verify-$NAME-$t.log > /dev/null; cat $VPLAIN/runs/verify-$NAME-$t.log" < /dev/null > "$E/image-verify.log" 2>&1
  grep -q "sg-server: VERIFY PASS" "$E/image-verify.log" || stop "image verify ($E/image-verify.log)"
  servers_gone || stop "a server left after the image copy"
  log "image copied + verified in $(( $(date +%s) - t )) s ($(grep -m1 'COPY DONE' "$E/image-copy.log" | cut -c1-120))"
}
region_same() {  # <guest tools dir>: guest install region == tools region on every VM
  local ip
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "test -f $VPLAIN/cfg/cxl_region.yaml && test -f $1/cxl_region.yaml && sha256sum $VPLAIN/cfg/cxl_region.yaml $1/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip ($1)"
  done
}
sys_up() {
  case $S in
    hw|mgc|mgr) dax_owner comsys || stop "dax0.0 -> comsys"; OWNED=comsys; [ $S != hw ] || image_copy;;
    pop)
      PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
      servers_gone || stop "a server runs before the Popcorn load"
      env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck >> "$E/block.log" 2>&1 || stop "shm precheck"
      dax_unused pre-load || stop "/dev/dax0.0 in use before the cxl_shm load"
      for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph >> "$E/block.log" 2>&1 || stop "shm $ph"; done
      region_same "$GT8"; image_copy
      env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable >> "$E/block.log" 2>&1 || stop "enable gate"
      recv_apply pop "$NAME" "$PRM"
      env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1 || stop "status pre";;
    ds)
      DSP=(K=$DS_K GT=$DS_GT C=$DS_C R=$E/dsshm-$NAME INIT_STATE=shared "LOAD_EXTRA=recv_mode=$RECV_MODE${DSRX:+ ${DSRX% }}")
      servers_gone || stop "a server runs before the De Stijl load"
      env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh precheck >> "$E/block.log" 2>&1 || stop "ds shm precheck"
      dax_unused pre-load || stop "/dev/dax0.0 in use before the cxl_shm (destijl) load"
      for ph in load chown; do env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh $ph >> "$E/block.log" 2>&1 || stop "ds shm $ph"; done
      region_same "$DS_GT"; image_copy
      env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh enable >> "$E/block.log" 2>&1 || stop "ds enable gate"
      recv_apply ds "$NAME" "$RECV_MODE"
      env "${DSP[@]}" STATUS_TAG=pre bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1 || stop "ds status pre";;
  esac
}
sys_down() {
  case $S in
    pop) recv_post "$NAME"; env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1
         servers_gone || stop "servers left (Popcorn teardown not attempted)"; dax_unused pre-teardown || stop "/dev/dax0.0 in use before the teardown"
         env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/block.log" 2>&1 || stop "shm teardown";;
    ds)  recv_post "$NAME"; env "${DSP[@]}" STATUS_TAG=post bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1
         servers_gone || stop "servers left (De Stijl teardown not attempted)"; dax_unused pre-teardown || stop "/dev/dax0.0 in use before the teardown"
         env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh teardown >> "$E/block.log" 2>&1 || stop "ds shm teardown";;
  esac
}
# ---- the lifetime
# --x-stream feed: the search's x (and summary confirm_x_mean = max RPS under SLO) is completed feed queries / s
LGA=(--mix "$LMIX" --opt rw=$RW --opt image=$IMAGE_HOST --opt gen=$GEN_HOST --opt seed=$SEED --opt write_route=$WR --seed $SEED --x-stream feed --raw)
PARTSV=slo PMX=() SLOARGS="--slo $SG_SLO $SG_SLO_PART"
if [ -n "$FIXR" ]; then  # smoke: one fixed rate instead of the SLO search (part name stays slo; no pmax step)
  SLOARGS="--slo $SG_SLO --mode fixed --rates $FIXR --warmup-s 10 --step-warmup-s 3 --step-measure-s ${SG_FIXED_S:-60} --drain-s 5"
  log "$NAME: fixed rate $FIXR (SG_FIXED_RATE, smoke), no SLO search"
elif [ $PMON = 1 ] && [[ $S =~ ^(pop|ds)$ ]]; then
  PARTSV="slo pmax"
  if [ $S = pop ]; then pmsrc="--summary $E/$NAME/slo/loadgen/summary.json"; else pmsrc="--name pop-$MIX-n$N $(pm_from)"; fi
  PMX=("PART_ARGS_pmax=--mode fixed --rates @RATE@ --warmup-s 0 --step-warmup-s $PMW --step-measure-s $PMM --drain-s $PMD"
    "PART_RATE_CMD=python3 -I -B $EX/sg_steps.py pmax-rate --emit rate --log $E/pmax-$NAME.txt $pmsrc")
  log "$NAME: pmax step appended (rate from $([ $S = pop ] && echo "its own slo part" || echo "pop rows: $pmsrc"))"
fi
RE=(SYSTEM=$SYSL V=$V HOST_SERVER=$SRV LOADGEN=$LOADGEN "SERVER_ARGS=${MGSA:-$SA}" "NODE0_ARGS=$NODE0_ARGS" "NODE_ENV=$NENV" "NODE0_ENV=$N0ENV"
  "NODES=${IPS[*]}" READY_TIMEOUT=$RDYT STATS_OP=20 STALE_EVERY=$STE "PARTS=$PARTSV" H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR
  "PART_ARGS_slo=$SLOARGS" "PART_GATE_CMD=bash $HG check" START_FALLBACK=$SFB START_FALLBACK_RATE=$SFBR "${PMX[@]}")
gate $NAME; sys_up
servers_gone || stop "an sg-server runs before $NAME"
log "$NAME: sg-run.sh parts [$PARTSV] ($SYSL, $MIX, N=$N)"
env "${RE[@]}" bash $EX/sg-run.sh "$NAME" "$E" -- "${LGA[@]}" > "$E/$NAME.out" 2>&1; rc=$?
log "$NAME: sg-run.sh rc $rc: $(tail -n 1 "$E/$NAME.out")"
sys_down
servers_gone || stop "servers left after $NAME"
R=$E/$NAME
[ -d "$R" ] || stop "$NAME: no run dir"
for k in "${!IPS[@]}"; do  # clean stop, no bad frame / protocol errors, staleness log written, op coherence state recorded
  L=$R/node$k.log
  grep -q "sg-server: stopping" $L || stop "$NAME node$k: no clean stop"
  grep -q "^sg-server: write route $WR " $L || stop "$NAME node$k: server write route != $WR (loadgen write_route=$WR)"
  grep -qx "bad_frames=0" $L && grep -qx "stale.write_errors=0" $L || stop "$NAME node$k: bad frames / staleness log errors"
  { grep -qx "opcoh.read_errors=0" $L && grep -qx "opcoh.register_errors=0" $L; } || stop "$NAME node$k: opcoh errors"
  [ $S != ds ] || [ "$DST" = 0 ] || grep -q "^sg-server: de stijl staleness T=$DST us on the image" $L || stop "$NAME node$k: staleness T=$DST not applied"
  [ -s "$R/stale/stale-reads-n$k.bin" ] && [ -s "$R/stale/stale-commits-n$k.bin" ] || stop "$NAME node$k: staleness logs missing"
done
RP=$R/slo
[ -s $RP/loadgen/summary.json ] || stop "$NAME: no loadgen output"
{ grep -qx "mix_ok=1" $RP/loadgen/sg.txt && grep -qx "bad_responses=0" $RP/loadgen/sg.txt && grep -qx "wseq_mismatch=0" $RP/loadgen/sg.txt; } \
  || stop "$NAME: loadgen sg.txt mix / protocol check (see $RP/loadgen/sg.txt)"
grep -q 'workload_finish":"ok' $RP/loadgen/summary.json || stop "$NAME: loadgen workload finish"
note=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $RP/loadgen/summary.json 2>/dev/null)
if [ -n "$note" ]; then
  case "$note" in
    "confirm failed at three rates; the knee is noisy (longer --confirm-s?)"|"the start rate already violates the SLO; lower --start") log "$NAME NOTE: $note";;
    *) stop "$NAME: loadgen note: $note";;
  esac
elif [ $rc != 0 ]; then
  src=$(sed -n 's/^part_slo_loadgen_rc=\([0-9]*\) .*/\1/p' $R/manifest.txt | tail -n 1)
  [ "$src" = 0 ] && [ "$PARTSV" != slo ] || stop "$NAME: sg-run.sh rc $rc"
  log "$NAME NOTE: pmax part rc != 0 (the SLO row stands; see $R/pmax)"
fi
# staleness over the whole search (stale.json: top level + pass = node-slot records; "list" = adjacency lists with the
# straddled-page caveat; "all"; --system flags hw / pop within-error ages as clock noise) and the per-step CSV (§2 columns)
TMS=$(python3 -I -c 'import sys; print(int(sys.argv[1]) / 1000.0)' "$DST")
python3 -I -B $TREE/workloads/socialgraph/tools/sg_stale_join.py --dir $R/stale --clock $R/clock-offset.tsv \
  $(for k in "${!IPS[@]}"; do printf -- '--vm %s=%s ' $k ${IPS[$k]}; done) --t-ms $TMS --system $S --json $R/stale.json > /dev/null 2> $R/stale.err \
  || log "$NAME NOTE: stale join failed (see $R/stale.err)"
python3 -I -B $EX/sg_steps.py steps --run-dir $R --system $S --nodes $N --mix $MIX --run $EVAL_RUN --t-ms $TMS $(for k in "${!IPS[@]}"; do printf -- '--vm %s=%s ' $k ${IPS[$k]}; done) \
  ${CXLBW:+$([ $CXLBW = 1 ] && echo "--cxlbw $E/cxlbw")} --out $R/steps.csv > $R/steps.log 2>&1 || log "$NAME NOTE: sg_steps.py failed (see $R/steps.log)"
# sg-results.tsv: MAX RPS UNDER SLO (doc §2) = confirm_x_mean = completed feed queries / s summed over the VMs at the
# confirmed knee (loadgen --x-stream feed), repeated as max_feed_rps_under_slo (empty unless confirmed);
# max_offered_x_pass = total offered requests / s (all streams) of that step. Columns 1-11 keep their order (pmax-rate reads 6, 8).
printf '# name\tsystem\tmix\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\tstale_pass\tmax_feed_rps_under_slo\tstart_rate\n' > "$E/sg-results.tsv"
python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); f=lambda v: "" if v is None else str(v)
try: st=json.load(open(sys.argv[7])).get("pass","")
except Exception: st=""
mx=c.get("x_mean") if s.get("confirmed") else None
print("\t".join(sys.argv[2:7] + [f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")), s.get("note",""), sys.argv[2] + "/slo", f(st), f(mx), sys.argv[8]]))' \
  $RP/loadgen/summary.json "$NAME" $S $MIX $N $VCPU $R/stale.json "$(sed -n 's/^slo_start_rate=//p' $R/manifest.txt | tail -n 1)" >> "$E/sg-results.tsv"
log "$NAME: max RPS under SLO (feed completions/s, confirm_x_mean) = $(grep -v '^#' "$E/sg-results.tsv" | cut -f12) (confirmed $(grep -v '^#' "$E/sg-results.tsv" | cut -f8))"
dmesg_check $NAME || stop "$NAME: dmesg check"
[ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root"; OWNED=root; }
log "== PT pretouch check (end)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end)"
log "BLOCK DONE $OWNER"

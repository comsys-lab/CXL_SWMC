#!/bin/bash
# One RocksDB run (reports/ROCKSDB-V1-packet.md; H2 all-HWcc vs Popcorn, H3 Popcorn on N = 2/4/8 VMs): Host gate,
# Popcorn cycle (as experiments/lmdb/pilot-run.sh), run.sh, post checks.
# YCSB keys (24 B), value 1,000 B (+ 8 B stamp stored), ScrambledZipfian 0.99; request = one get or one update
# (mixed stream: update with probability UPDATE_RATIO); SLO per request mixed p99 < 1 ms (as kv/lmdb).
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Popcorn | DeStijl | Megalon), UPDATE_RATIO (0.05 | 0.5 | 0.8), KIND:
#   functional  fixed RATES (total, default 200,1000), 30 s windows, LOG=1 recommended (check_log)
#   slo         SLO search with the KV/LMDB H1 loadgen arguments (precision 0.02, confirm 0.01, max 6 confirm probes,
#               step-down 0.05; fill 0.7,0.8,0.9; overload 1.05,1.1,1.2)
#   fix         PER_VM_RATES=r1[,r2..] (requests/s per VM; total = N x r): fixed 30 s windows after 10 s warm-up, no SLO
#               abort (judged after); H3: every N at the same per-VM rate (= the 2-VM Popcorn L2)
#   SYS=Popcorn: C8 (deploy bundle dir with p-popcorn-shm.sh), K8 (release), GT8 (guest tools dir), RECV_MODE
#   (poll | idle | sleep); cxl_shm loaded and coherence ENABLED (init_state=shared) before the servers start, so the
#   image build runs under coherence. LOCK_OWNER: the calling block's measurement lock.
#   SYS=DeStijl (De Stijl v2, as experiments/eval/h2n-block.sh ds): DS_C (bundle dir with p-destijl-shm.sh), DS_K
#   (release -ds-destijl-<n>), DS_GT (guest tools dir), RECV_MODE (poll | sleep); same cycle as Popcorn with
#   p-destijl-shm.sh (protocol destijl checked); T = 0 only: rocksdb-server has no region_apply_staleness call (no
#   CXL_DESTIJL_T_US hook), so a DS_T_US other than 0 is refused (unlike the vector DB / RecSys H2N_DS_T_US / RS_DS_T_US /
#   DS_T_US keys); error counters over the run: swmc.transaction_error_count, ds.protocol_error, ds.tx_timeout deltas = 0.
#   DS_RECV_EXTRA (optional, SYS=DeStijl; runset-rocks.sh ROCKS_DS_RECV_EXTRA): "idle_sleep_us=<n> idle_spin_us=<n>"
#   (either or both) appended to the cxl_shm load (De Stijl receiver sleep tier; user 2026-11-02 17:0x: 200 / 50 for
#   every ds cell from now on), read back from /sys/module/cxl_shm/parameters after the enable (recv-mode-<name>.txt),
#   mismatch = stop. Empty = module defaults (20 / 50).
# optional: NODES ("192.168.122.100 192.168.122.101"; N = count; p-popcorn-shm.sh must cover the same VMs), KEYS
#   (54000000), THREADS (server request workers per node, 4), PREPARE_THREADS (4), FILE_EXTENTS (0 = rest of share),
#   SEED (20261018), LOG (0), GATE (1), V (/home/comsys/rocksdb3), BUILD (builds/rocksdb/3), LOADGEN_BUILD
#   (builds/rocksdb-loadgen/1), STOP_EXTENTS_FREE / STOP_BLOCKS_FREE (run.sh), SERVER_CPUS, READY_TIMEOUT (7200).
#   SLO_EXTRA (KIND=slo only; eval3 2026-11-01): loadgen arguments appended after the slo arguments above (loadgen keeps
#   the last value of a repeated option), e.g. the vector DB cell rule "--confirm-rule pooled --confirm-full
#   --confirm-reps 1 --confirm-s 90 --confirm-warmup-s 15 --overload-base result --overload 0.9,...,2.0
#   --start-fail-steps 1.25,1.5,2,2.5,3.4"; every --option in it must exist in the loadgen binary (builds/rocksdb-
#   loadgen/2 or later). With SLO_EXTRA the loadgen note "the start rate already violates the SLO" is a NOTE (a result:
#   no rate under the SLO at or above the start; as experiments/eval/h2n-block.sh), not a STOP.
#   DRY=1: validate the arguments and print the plan (cxl_shm cycle, run.sh call, loadgen arguments); no ssh, no lock,
#   no evidence written; exit 0.
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/rocksdb
: "${SYS:?}" "${UPDATE_RATIO:?}" "${KIND:?}"
read -r -a IPS <<< "${NODES:-192.168.122.100 192.168.122.101}"
N=${#IPS[@]}
KEYS=${KEYS:-54000000} THREADS=${THREADS:-4} PREPARE_THREADS=${PREPARE_THREADS:-4} FILE_EXTENTS=${FILE_EXTENTS:-0}
SEED=${SEED:-20261018} LOG=${LOG:-0}
V=${V:-/home/comsys/rocksdb3} BUILD=${BUILD:-$P/builds/rocksdb/3} LOADGEN_BUILD=${LOADGEN_BUILD:-$P/builds/rocksdb-loadgen/1}
stop() { echo "PILOTRUN $NAME STOP $*"; exit 1; }
# receiver rules (run 2, experiments/eval/recv-mode.sh, next to this tree): POP_RECV_MODE / POP_ADAPT_KO / RECV_IPOLL
. "$(cd "$(dirname "$0")" && pwd)/../eval/recv-mode.sh"
IPOLL=${RECV_IPOLL:-} POPSV=- DSFP=0
[[ $IPOLL =~ ^[01]?$ ]] || stop "bad RECV_IPOLL"
DRY=${DRY:-0}
[[ $DRY =~ ^[01]$ ]] || stop "bad DRY"
if [ "$DRY" = 0 ]; then
  [ -d "$E" ] || stop "missing evidence dir $E"
  [ -e "$E/$NAME" ] && stop "$E/$NAME exists"
fi
[[ $UPDATE_RATIO =~ ^(0\.05|0\.5|0\.8)$ ]] || stop "bad UPDATE_RATIO"
[[ $KEYS =~ ^[1-9][0-9]*$ ]] && [[ $THREADS =~ ^[1-9][0-9]*$ ]] || stop "bad KEYS/THREADS"
[[ $LOG =~ ^[01]$ ]] && [[ ${GATE:-1} =~ ^[01]$ ]] || stop "bad LOG/GATE"
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed only with KIND=functional"
[ "$N" -ge 2 ] && [ "$N" -le 8 ] || stop "NODES must list 2..8 VMs"
SA="--nodes $N --keys $KEYS --threads $THREADS --prepare-threads $PREPARE_THREADS --start-timeout-ms 7200000"
[ "$FILE_EXTENTS" = 0 ] || SA="$SA --file-extents $FILE_EXTENTS"
export LOADGEN=$LOADGEN_BUILD/loadgen READY_TIMEOUT=${READY_TIMEOUT:-7200} STATS_OP=10 V NODES="${IPS[*]}"
export HOST_SERVER=$BUILD/bin/rocksdb-server SERVER_ARGS="$SA --backend plain"
RUN_KIND=${RUN_KIND:-measurement}; [ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc;;
  Popcorn)  : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
            RECV_MODE=${POP_RECV_MODE:-$RECV_MODE}   # run 2: the Popcorn receiver mode (recv-mode.sh)
            why=$(recv_rules pop "$RECV_MODE" "$C8" "$N") || stop "Popcorn receiver: $why"
            [ "$RECV_MODE" != adaptive ] || POPSV=$(recv_pop_srcversion)
            export SYSTEM=Popcorn-$RECV_MODE
            SHMS=$C8/p-popcorn-shm.sh GTX=$GT8 SHMR=$E/shm-$NAME
            PS=(POP_IPS="${IPS[*]}" K=$K8 GT=$GT8 C=$C8 R=$SHMR INIT_STATE=shared);;  # POP_IPS: N-node bundle (popcorn-n)
  DeStijl)  : "${DS_C:?}" "${DS_K:?}" "${DS_GT:?}" "${RECV_MODE:?}"
            why=$(recv_rules ds "$RECV_MODE" "$DS_C" "$N") || stop "De Stijl receiver: $why"
            [ "${DS_T_US:-0}" = 0 ] || stop "DS_T_US=${DS_T_US}: RocksDB runs De Stijl at T = 0 only (rocksdb-server has no staleness hook)"
            export SYSTEM=DeStijl-$RECV_MODE-T0
            DSRX=${DS_RECV_EXTRA:-}
            [[ $DSRX =~ ^(((idle_sleep_us|idle_spin_us)=[0-9]+|fault_poll=[01])( |$))*$ ]] || stop "bad DS_RECV_EXTRA ($DSRX: 'idle_sleep_us=<n> idle_spin_us=<n> fault_poll=<0|1>')"
            [[ " $DSRX " != *" fault_poll=1 "* ]] || DSFP=1
            DSRX=${DSRX% }
            SHMS=$DS_C/p-destijl-shm.sh GTX=$DS_GT SHMR=$E/dsshm-$NAME
            PS=(DS_IPS="${IPS[*]}" K=$DS_K GT=$DS_GT C=$DS_C R=$SHMR INIT_STATE=shared "LOAD_EXTRA=recv_mode=$RECV_MODE${DSRX:+ $DSRX}");;
  Megalon)  # Object SWcc, user level (eval run2; workloads/rocksdb DESIGN.md §7): no cxl_shm cycle; /dev/dax0.0 owned by
            # comsys (v1-block.sh, as all-HWcc); objects = 1 MiB arena blocks + 1 MiB file extents (explicit count)
            [ "$FILE_EXTENTS" != 0 ] || stop "SYS=Megalon needs FILE_EXTENTS (Megalon's object_arena_size >= N x (arena blocks + extents) MiB)"
            export SYSTEM=Megalon SERVER_ARGS="$SA --backend megalon" NODE_ENV="ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml" \
              NODE0_ENV="ENV:MEGALON_REINIT=1"
            [ -f "$BUILD/lib/libmegalon-objapi.so" ] || stop "BUILD $BUILD has no lib/libmegalon-objapi.so (build.sh with a Megalon build dir)"
            # MEG_CFG = the Host copy v1-block.sh installed as cfg/megalon.yaml: its object arena must hold every node's
            # pools (rocksdb-server default 512 arena blocks + FILE_EXTENTS, 1 MiB each; GB/MB = GiB/MiB in Megalon)
            [ -f "${MEG_CFG:-}" ] || stop "SYS=Megalon needs MEG_CFG (Host Megalon config)"
            oa=$(sed -n 's/^object_arena_size: *\([0-9]*\)\([GM]B\).*/\1 \2/p' "$MEG_CFG")
            case "$oa" in *GB) oam=$(( ${oa% GB} * 1024 ));; *MB) oam=${oa% MB};; *) stop "MEG_CFG object_arena_size unreadable ($oa)";; esac
            need=$(( N * (512 + FILE_EXTENTS) ))
            [ "$oam" -ge "$need" ] || stop "MEG_CFG object_arena_size ${oam} MiB < N x (512 + $FILE_EXTENTS) = $need MiB";;
  *) stop "bad SYS";;
esac
COH=0; case "$SYS" in Popcorn|DeStijl) COH=1;; esac   # a cxl_shm cycle around the run (PS / SHMS / GTX above)
LG=(--opt keys=$KEYS --opt update_ratio=$UPDATE_RATIO --opt seed=$SEED --seed "$SEED" --opt log=$LOG --mix mixed=1
    --x-stream mixed)
case "$KIND" in
  functional) unset PER_VM_RATES; LG+=(--slo mixed:99:600000 --mode fixed --rates "${RATES:-200,1000}" --warmup-s 10 --step-warmup-s 5
                   --step-measure-s 30 --drain-s 10);;
  slo) unset PER_VM_RATES; LG+=(--slo mixed:99:1 --raw --mode slo --start 500 --factor 1.5 --precision 0.02 --confirm-precision 0.01
            --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --drain-s 5 --confirm-s 30 --confirm-reps 3 --fill 0.7,0.8,0.9 --overload 1.05,1.1,1.2);;
  fix) [[ ${PER_VM_RATES:?fix needs PER_VM_RATES} =~ ^[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*$ ]] || stop "bad PER_VM_RATES"
       export PER_VM_RATES  # run.sh adds --mode fixed --rates N x r
       LG+=(--slo mixed:99:600000 --raw --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
if [ -n "${SLO_EXTRA:-}" ]; then
  [ "$KIND" = slo ] || stop "SLO_EXTRA is for KIND=slo only"
  [[ $SLO_EXTRA =~ ^[-a-z0-9.,\ ]+$ ]] || stop "SLO_EXTRA: only lower-case options, numbers, commas and spaces"
  [ -x "$LOADGEN" ] || stop "loadgen $LOADGEN missing"
  # shellcheck disable=SC2206
  XA=($SLO_EXTRA)
  for a in "${XA[@]}"; do
    case "$a" in --*) grep -a -q -E -e "(^| )$a( |$)" "$LOADGEN" || stop "loadgen $LOADGEN has no option $a (needs builds/rocksdb-loadgen/2+)";; esac
  done
  LG+=("${XA[@]}")
fi
# run-2 pmax step (user 2026-11-03 Q9; optional): PMAX=1 on a KIND=slo Popcorn / De Stijl run appends ONE fixed part
# "pmax" (run.sh PMAX_RATE_CMD / PMAX_ARGS, same server lifetime) at Popcorn's max under the SLO of the cell =
# experiments/eval/pmax_decide.py --workload rocksdb: Popcorn from its own slo summary.json, De Stijl from the pop-<mix>-n<N>
# rows of PMAX_FROM (space-separated rocks-results.tsv of the hwpop block of the same N and run). Windows as KIND=fix
# (10 s warm-up, 5 s step warm-up, PMAX_MEASURE_S (30) s, 10 s drain), no SLO abort. No confirmed Popcorn max = no step
# (NOTE). The pmax part's value check (rocksdb.txt) must hold; a non-zero pmax loadgen rc is a NOTE (the SLO result stands).
PMAX=${PMAX:-0} PMMS=${PMAX_MEASURE_S:-30}
[[ $PMAX =~ ^[01]$ && $PMMS =~ ^[1-9][0-9]*$ ]] || stop "bad PMAX / PMAX_MEASURE_S"
unset PMAX_RATE_CMD PMAX_ARGS
if [ "$PMAX" = 1 ]; then
  [ "$KIND" = slo ] || stop "PMAX=1 needs KIND=slo"
  case "$SYS" in Popcorn|DeStijl) ;; *) stop "PMAX=1 is for SYS=Popcorn | DeStijl (the step compares them at Popcorn's max)";; esac
  PMIX=u$(awk -v r="$UPDATE_RATIO" 'BEGIN{printf "%d", r * 100 + 0.5}')
  PMSRC=(--summary "$E/$NAME/loadgen/summary.json")
  if [ "$SYS" = DeStijl ]; then PMSRC=(); for f in ${PMAX_FROM:-}; do PMSRC+=(--from "$f"); done; fi
  export PMAX_RATE_CMD="python3 -I -B $(cd "$(dirname "$0")/../eval" && pwd)/pmax_decide.py --workload rocksdb --mix $PMIX --nodes $N ${PMSRC[*]} --emit rate --log $E/pmax-$NAME.txt"
  export PMAX_ARGS="--opt keys=$KEYS --opt update_ratio=$UPDATE_RATIO --opt seed=$SEED --seed $SEED --opt log=$LOG --mix mixed=1 --x-stream mixed --slo mixed:99:600000 --raw --mode fixed --rates @RATE@ --warmup-s 10 --step-warmup-s 5 --step-measure-s $PMMS --drain-s 10"
elif [ -n "${PMAX_FROM:-}" ]; then stop "PMAX_FROM without PMAX=1"; fi
if [ "$DRY" = 1 ]; then
  [ -x "$LOADGEN" ] && [ -x "$HOST_SERVER" ] || stop "loadgen $LOADGEN or server $HOST_SERVER missing"
  if [ "$PMAX" = 1 ]; then
    if [ "$SYS" = Popcorn ]; then echo "DRY $NAME pmax: rate = own slo summary.json (pmax_decide.py --workload rocksdb --mix $PMIX --nodes $N)"
    else echo "DRY $NAME pmax: $(${PMAX_RATE_CMD%% --emit*} | tr '\t' ' ')"; fi
    echo "DRY $NAME pmax part: loadgen ${PMAX_ARGS}"
  fi
  [ $COH = 0 ] || [ -f "$SHMS" ] || stop "$SHMS missing"
  echo "DRY $NAME SYS=$SYS SYSTEM=$SYSTEM N=$N KIND=$KIND UPDATE_RATIO=$UPDATE_RATIO KEYS=$KEYS THREADS=$THREADS V=$V"
  echo "DRY $NAME loadgen=$LOADGEN sha256=$(sha256sum < "$LOADGEN" | cut -c1-16) server=$HOST_SERVER sha256=$(sha256sum < "$HOST_SERVER" | cut -c1-16)"
  [ "$SYS" != Megalon ] || echo "DRY $NAME megalon node_env=[$NODE_ENV] node0_env=[$NODE0_ENV] shim=$BUILD/lib/libmegalon-objapi.so"
  echo "DRY $NAME server_args=[$SERVER_ARGS] gate=${GATE_SCRIPT:-host-gate or h1-gate} lock_owner=${LOCK_OWNER:-unset}"
  if [ $COH = 1 ]; then
    echo "DRY $NAME cxl_shm cycle: env ${PS[*]} bash $SHMS {precheck,load,chown,enable}; recv_mode=$RECV_MODE; status runpre/runpost; teardown"
    [ -z "${DSRX:-}" ] || echo "DRY $NAME De Stijl receiver parameters: $DSRX (cxl_shm load, read back after the enable)"
    plan=$(env "${PS[@]}" bash $SHMS plan precheck load chown enable status teardown 2>&1) || stop "$SHMS plan failed: $(tail -n 2 <<< "$plan")"
    echo "DRY $NAME $(head -n 1 <<< "$plan") -> $(grep -c '^ssh ' <<< "$plan") ssh commands planned"
  fi
  echo "DRY $NAME run.sh $NAME $E -- ${LG[*]}${PER_VM_RATES:+ (+ --mode fixed --rates N x $PER_VM_RATES)}"
  echo "PILOTRUN $NAME DRY OK"
  exit 0
fi
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
PAT='(^|[ /])bin/rocksdb-serve[r]( |$)'
servers_gone() {  # no rocksdb-server of ours and /dev/dax0.0 unused on every VM (fail-closed)
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "echo procs=\$(pgrep -c -u comsys -f '$PAT') fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    [ "$out" = "procs=0 fuser=[]" ] || { echo "$ip: $out" >&2; return 1; }
  done
}
echo "$(date -Is) $NAME: SYS=$SYS N=$N UPDATE_RATIO=$UPDATE_RATIO KIND=$KIND PER_VM_RATES=${PER_VM_RATES:-} KEYS=$KEYS LOG=$LOG SEED=$SEED"
servers_gone || stop "a rocksdb-server is running before the run"
LOCKF=$P/workspaces/MEASUREMENT.lock
grep -q "^owner=${LOCK_OWNER:?LOCK_OWNER = owner of the measurement lock held by the calling block} " "$LOCKF" 2>/dev/null \
  || stop "measurement lock not held by $LOCK_OWNER ($(cat "$LOCKF" 2>/dev/null))"
if [ "${GATE:-1}" = 1 ]; then
  if [ -n "${GATE_SCRIPT:-}" ]; then  # N-VM gate wrapper (v1-block.sh GATE_SCRIPT)
    bash "$GATE_SCRIPT" check "$E/gate-$NAME.txt" || stop "gate ($GATE_SCRIPT)"
  elif [ "${H1_MEASURE_RUN:-0}" = 1 ]; then
    : "${MEASURE_PART_DIR:?H1_MEASURE_RUN=1 needs MEASURE_PART_DIR}"
    bash $P/CXL_SWMC/experiments/h1/h1-gate.sh check "$E/gate-$NAME.txt" || stop "h1 gate"
  else
    bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"
  fi
fi
T0=$(date +%s)
if [ $COH = 1 ]; then  # as experiments/lmdb/pilot-run.sh: enable BEFORE the servers (De Stijl: same, p-destijl-shm.sh)
  servers_gone || stop "rocksdb process or /dev/dax0.0 user before the cxl_shm load"
  for ph in precheck load chown; do env "${PS[@]}" bash $SHMS $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "sha256sum $V/cfg/cxl_region.yaml $GTX/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || { env "${PS[@]}" bash $SHMS teardown; stop "region config differs on $ip"; }
  done
  env "${PS[@]}" bash $SHMS enable || { env "${PS[@]}" bash $SHMS teardown; stop "enable gate"; }
  # recv-mode.sh: mode (+ RECV_IPOLL), readback per VM -> recv-mode-<name>.txt, checks; a failure tears cxl_shm down first
  td_stop() { env "${PS[@]}" bash $SHMS teardown; stop "$@"; }
  RECV_STOP=td_stop recv_apply "$([ "$SYS" = DeStijl ] && echo ds || echo pop)" "$NAME" "$RECV_MODE"
  env "${PS[@]}" STATUS_TAG=runpre bash $SHMS status || { env "${PS[@]}" bash $SHMS teardown; stop "status pre"; }
fi
bash $X/run.sh "$NAME" "$E" -- "${LG[@]}"
RC=$?
if [ $COH = 1 ]; then
  recv_post "$NAME"   # receiver / idle-poller CPU after the run (recv-post-<name>.txt)
  env "${PS[@]}" STATUS_TAG=runpost bash $SHMS status
  # error counters over the run (verifier HIGH-1): Popcorn transaction_error / send_drop / late_response deltas = 0;
  # De Stijl transaction_error, ds.protocol_error, ds.tx_timeout deltas = 0
  python3 -I -B - "$SHMR" "$N" "$SYS" > "$E/$NAME.popcorn-errors.txt" 2>&1 <<'EOP'
import os, sys
d, n = sys.argv[1], int(sys.argv[2]); bad = []
cs = ['swmc.transaction_error_count', 'ds.protocol_error', 'ds.tx_timeout'] if sys.argv[3] == 'DeStijl' else \
     ['swmc.' + c for c in ('transaction_error_count', 'send_drop_count', 'late_response_count')]
def kv(p):
    out = {}
    for l in open(p):
        if '=' in l and not l.startswith('dmesg: '):
            k, v = l.rstrip('\n').split('=', 1); out[k] = v
    return out
for k in range(n):
    b, a = os.path.join(d, f'status-runpre-vm{k}.txt'), os.path.join(d, f'status-runpost-vm{k}.txt')
    if not (os.path.exists(b) and os.path.exists(a)): bad.append(f'vm{k}: status files missing'); continue
    b, a = kv(b), kv(a)
    for c in cs:
        try: dv = int(a[c]) - int(b[c])
        except (KeyError, ValueError): bad.append(f'vm{k}: {c} unreadable'); continue
        print(f'vm{k} {c.split(".", 1)[1]} delta={dv}')
        if dv: bad.append(f'vm{k}: {c.split(".", 1)[1]} delta {dv}')
print(('DESTIJL' if sys.argv[3] == 'DeStijl' else 'POPCORN') + ' ERRORS ' + ('OK' if not bad else 'FAIL ' + '; '.join(bad)))
sys.exit(1 if bad else 0)
EOP
  PERR=$?
  servers_gone || stop "servers left ($SYS teardown not attempted)"
  env "${PS[@]}" bash $SHMS teardown || stop "shm teardown"
fi
servers_gone || stop "servers left"
[ $COH = 0 ] || [ "$PERR" = 0 ] || stop "$SYS error counters ($(tail -n 1 "$E/$NAME.popcorn-errors.txt"))"
R=$E/$NAME
[ -d "$R" ] || stop "no run dir"
{ echo "# load times $NAME (s)"; echo "run_wall_s=$(( $(date +%s) - T0 ))"; grep -h "^node[0-9]* .*IMAGE" $R/manifest.txt
  grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
grep -q "^check: PASS$" $R/check.txt 2>/dev/null || stop "server checks (check.txt): $(grep '^FAIL' $R/check.txt 2>/dev/null | head -3 | tr '\n' ';')"
for kv in not_found=0 errors=0 bad_values=0 stale_reads=0; do grep -q "^$kv\$" $R/loadgen/rocksdb.txt || stop "value check: $kv violated"; done
grep -q "workload_finish\":\"ok" $R/loadgen/summary.json || stop "loadgen workload finish"
PMNOTE=
if [ "$PMAX" = 1 ]; then  # run-2 pmax part: value checks are correctness (stop), the rest a NOTE
  pmv=$(sed -n 's/^pmax_rate=\([^ ]*\) pmax_loadgen_rc=\(.*\)$/\1 \2/p' $R/manifest.txt | tail -n 1)
  pmr=${pmv% *} pmc=${pmv#* }
  if [ -d $R/pmax/loadgen ]; then
    for kv in not_found=0 errors=0 bad_values=0 stale_reads=0; do grep -q "^$kv\$" $R/pmax/loadgen/rocksdb.txt || stop "pmax value check: $kv violated"; done
    [ "$pmc" = 0 ] || PMNOTE="pmax loadgen rc $pmc at $pmr"
  else PMNOTE="no pmax step ($pmc: $(tail -n 1 "$E/pmax-$NAME.txt" 2>/dev/null | cut -f3))"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$SYS" "$pmr" "$pmc" "$(tail -n 1 "$E/pmax-$NAME.txt" 2>/dev/null | cut -f3)" >> "$E/pmax.tsv"
  [ -z "$PMNOTE" ] || echo "$NAME NOTE: $PMNOTE"
fi
if [ $RC != 0 ]; then
  note=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [ "$KIND" = slo ] && [[ "$note" == *"confirm failed at three rates"* ]] && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  [ "$KIND" = slo ] && [ -n "${SLO_EXTRA:-}" ] && [ "$note" = "the start rate already violates the SLO; lower --start" ] \
    && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$LOG" = 1 ] && { grep -q "^check_log rc=0$" $R/check-log.txt || stop "check_log"; }
[ -s $R/stats-steps.csv ] && [ "$(wc -l < $R/stats-steps.csv)" -ge 2 ] || stop "no stats-steps.csv rows"
if [[ $KIND =~ ^(fix|functional)$ ]]; then  # per-step table; an aborted fixed step is a NOTE
  python3 -B - $R/loadgen/steps.jsonl "$N" > $R/ladder-result.txt <<'EOP' || stop "fixed steps result"
import json, sys
n = int(sys.argv[2])
st = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
st = [s for s in st if s["phase"] == "fixed"]
print("step offered_x per_vm_x achieved p50_ms p90_ms p99_ms max_ms done aborted reason")
for s in st:
    m = s["streams"]["mixed"]
    print(s["step"], s["offered_x"], round(s["offered_x"] / n, 3), m["achieved"], m["p50_ms"], m.get("p90_ms"), m["p99_ms"],
          m["max_ms"], m.get("done"), str(s["aborted"]).lower(), (s["reason"] or "-").replace(" ", "_"))
EOP
  cat $R/ladder-result.txt
  awk 'NR>1 && $10=="true"' $R/ladder-result.txt | grep -q . && { echo "PILOTRUN $NAME NOTE $KIND step aborted"; exit 0; }
fi
echo "PILOTRUN $NAME OK"

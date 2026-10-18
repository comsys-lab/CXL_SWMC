#!/bin/bash
# H1 main, one STAGE per invocation (reports/H1-main-packet.md §3; user decision 2026-10-17, state/TASKS.md):
#   r1-kv, r1-lmdb, r1-vdb, r1-recsys   round 1 of one workload, in this order; the main session reviews each check
#                                       and records its acceptance (h1-accept.sh) before the next stage may start
#   r2, r3 [--workloads w1,w2]          repeats for all four or a user-chosen subset (plan change 2026-10-18), fixed
#                                       order, each followed by its check; a check FAIL stops the stage; r2 needs r1
#                                       accepted (not skipped) for each CHOSEN workload, r3 r1 and r2 accepted for each
#                                       chosen workload (H1 v0.6.5, user 2026-10-18: r2 = LMDB + vector DB while
#                                       RecSys r1 is on hold)
# Orchestration only: every VM action happens inside the workload blocks (their H1 hook, experiments/h1/README.md).
# Lifetimes (H1-HOOK v2, user decision 2026-10-18): no server lifetime only for the fixed phase except r1 hw/pop.
#   r1 (per mix): hw, pop SLO-only lifetimes (Latin order between them), then mg: SLO -> levels-cb.sh (L1/L2 of the
#      mix from hw, pop, mg maxima) -> settle -> L2 -> L1 in the same lifetime, then hw and pop separate fixed lifetimes
#      (settle -> L2 -> L1) = the "separate" sample.
#   mgoff (Megalon timers off, Fig 2 C_diff; user decision 2026-10-18: Megalon 77, no runtime switch): its own lifetime
#      settle -> L2 -> L1 (no SLO search) right after the mg lifetime of the mix, in every round.
#   r2, r3 (per mix): hw, pop, mg Latin square, each one lifetime SLO -> settle -> L2 -> L1 = the "continuous" sample.
#   check.py r2 compares hw/pop r1 separate vs r2 continuous against the run-to-run spread (mg, continuous in both
#   rounds); REPORT lines block the r2 acceptance (r3) until the user has seen them.
# Systems per workload (v0.6.7, h1sys.py; user decision 2026-10-18): recsys = hw, pop only (no mg / mgoff lifetimes;
#   r1 levels computed right after the hw/pop SLO-only lifetimes of the mix; Megalon RecSys numbers: RECSYS-V1 v1.4).
# Per workload W and round n (stage dir <E>/<W>/r<n>/run/, must not exist):
#   1. gate: pretouch gate (standing rule 2026-10-17) and h1-gate.sh (partition check, no build, node1 measurement CPU
#      sets quiet; VM/node0 load not judged, user 2026-10-18)
#   2. hook.sh W r1|cont <E>/<W>/r<n>/run (one block call per workload and round; r1 writes <E>/<W>/levels.tsv
#      through levels-cb.sh inside each mg lifetime; r2/r3 reuse it, dec Q3)
#   5. pretouch gate again; 6. collect.py -> r<n>/collect; 7. check.py -> r<n>/check.txt (H1CHECK PASS | FAIL)
# Every stage ends with collect.py over all rounds present of its workloads (<E>/<W>/collect-all-r<n>).
# Holds the measurement lock (owner H1-main) for the stage; hooks run with H1_PARENT_LOCK=H1-main. Stops at the
# first failing step ("SEQUENCE STOP"); every block rolls back in its own EXIT trap; this script releases the lock.
# usage: h1-main.sh <stage> <evidence root E>
#        h1-main.sh r1-<W> <E> --retry "<reason>"   (v0.6.8, user decision 2026-10-18 "응 그렇게 진행해")
#   E: for r1-kv it must exist and be empty except sequence* files; later stages use the same E.
# --retry (round 1 stages only): re-runs a STOPPED r1 stage of W in a new attempt dir <E>/<W>/r1-a<k> (attempts.py;
#   the stopped <E>/<W>/r1[-a<k-1>] stays untouched as evidence). Allowed only when the current attempt has no
#   acceptance record and no skip record, its check.txt (if any) is not PASS, no <E>/<W>/collect-all-r1 exists, and the
#   stage's last line in h1-state.txt is "SEQUENCE STOP" (nothing running: the measurement lock is taken as usual).
#   The new attempt gets attempt.txt (attempt number, predecessor dir, its last state line, check and file-list
#   sha256, the reason) and its own levels.tsv; gate / manifest-check files get the suffix -a<k>; check.py,
#   collect.py and h1-accept.sh read the current attempt (attempts.py), so the other workloads' acceptances stay valid.
# env: PRETOUCH_DIR, MEASURE_ENV_DIR, MEASURE_PART_DIR (required unless H1_DRY=1; exported with H1_MEASURE_RUN=1 so the
#   hooks gate with h1-gate.sh and start loadgen through scripts/host/measure-run.sh), H1_PLAN (default h1-plan.tsv next to this script),
#   settle_s per workload from the plan (column 8),
#   H1_MANIFEST + H1_MANIFEST_SHA (required unless H1_DRY=1: the frozen code manifest and its packet sha256),
#   H1_SEED_BASE (20261017: loadgen seed of round n = base + n), H1_NO_FIGS (set: no
#   figures), H1_DRY=1 (Host self-test: plugin "stub", gates skipped, LOCK must be a test lock under h1-main/).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
STAGE=${1:?usage: h1-main.sh <stage> <evidence root> [--workloads w1,w2 | --retry <reason>]} E=${2:?usage: h1-main.sh <stage> <evidence root>}
SUBSET= RETRY=
if [ -n "${3:-}" ]; then
  if [ "$3" = --retry ]; then
    [ -n "${4:-}" ] && [ -z "${5:-}" ] || { echo "SEQUENCE STOP: usage: h1-main.sh r1-<W> <E> --retry \"<reason>\""; exit 2; }
    case $STAGE in r1-*) ;; *) echo "SEQUENCE STOP: --retry is for r1-<W> stages only"; exit 2;; esac
    RETRY=$4
  else
    [ "$3" = --workloads ] && [ -n "${4:-}" ] || { echo "SEQUENCE STOP: usage: h1-main.sh r2|r3 <E> --workloads w1,w2"; exit 2; }
    SUBSET=${4//,/ }
  fi
fi
H=$(cd "$(dirname "$0")" && pwd)
G=$H/../vectordb/host-gate.sh PG=$H/../vectordb/pretouch-gate.sh
DRY=${H1_DRY:-0}
# D1 (verifier delta on v0.6): the plan is part of the frozen code; an override is for the Host self-test only
[ -z "${H1_PLAN:-}" ] || [ "$DRY" = 1 ] || { echo "SEQUENCE STOP: H1_PLAN override refused (H1_DRY=1 only)"; exit 2; }
PLAN=${H1_PLAN:-$H/h1-plan.tsv}
export H1_SEED_BASE=${H1_SEED_BASE:-20261017}
ORDER="kv lmdb vdb recsys"   # user decision 2026-10-17
OWNER=H1-main
case $STAGE in
  r1-kv|r1-lmdb|r1-vdb|r1-recsys) N=1 WL=${STAGE#r1-}
         [ -z "$SUBSET" ] || { echo "SEQUENCE STOP: --workloads is for r2/r3 only"; exit 2; };;
  r2|r3) N=${STAGE#r} WL=
         # subset (plan change 2026-10-18: r1 for all four now, the user picks workloads for r2; r3 later): kept in
         # the fixed order; default all four
         for w in $ORDER; do [ -z "$SUBSET" ] || [[ " $SUBSET " == *" $w "* ]] && WL="$WL $w"; done
         for w in $SUBSET; do [[ " $ORDER " == *" $w "* ]] || { echo "SEQUENCE STOP: unknown workload $w"; exit 2; }; done
         WL=${WL# };;
  *) echo "SEQUENCE STOP: bad stage $STAGE (r1-kv r1-lmdb r1-vdb r1-recsys r2 r3)"; exit 2;;
esac
[ -f "$PLAN" ] || { echo "SEQUENCE STOP: no plan $PLAN"; exit 2; }
for w in $ORDER; do grep -q "^$w	" "$PLAN" || { echo "SEQUENCE STOP: workload $w not in the plan"; exit 2; }; done
if [ "$STAGE" = r1-kv ] && [ -z "$RETRY" ]; then
  [ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
else
  [ -f "$E/h1-manifest.txt" ] || { echo "SEQUENCE STOP: $E has no h1-manifest.txt (start with r1-kv)"; exit 2; }
fi
# stage preconditions: acceptance records of the previous stage(s) (h1-accept.sh; the check.txt sha256 must still match)
rdir() {  # W n -> current attempt dir of round n (attempts.py; <E>/<W>/r<n> when none exists yet); rc 2 = bad layout
  local d rc
  d=$(python3 -I -B $H/attempts.py dir "$E" "$1" "$2" 2>/dev/null); rc=$?
  case $rc in 0) echo "$d";; 1) echo "$E/$1/r$2";; *) return 2;; esac
}
accepted() {  # W n -> 0 if r<n> of W (current attempt) has check PASS and an acceptance record matching the check file
  local d; d=$(rdir $1 $2) || return 1
  local c=$d/check.txt a=$E/accept/r$2-$1.txt
  [ -f "$c" ] && tail -n 1 "$c" | grep -q "^H1CHECK PASS" && [ -f "$a" ] \
    && grep -q "check_sha256=$(sha256sum < "$c" | cut -c1-64)" "$a"
}
# r1 chain (user decision 2026-10-18, overnight runs never sit idle): the previous r1 stage accepted, OR skipped by the
# main session (h1-accept.sh --skip: <E>/accept/r1-<W>-skip.txt, only without an acceptance record). r2/r3 stay strict
# for the chosen workloads (a skip record never counts; other workloads are not looked at, v0.6.5).
SKIPNOTE=
prev_r1() {  # W
  accepted $1 1 && return 0
  local s=$E/accept/r1-$1-skip.txt
  [ -f "$s" ] && [ ! -e "$E/accept/r1-$1.txt" ] || return 1
  SKIPNOTE="previous stage $1 SKIPPED (not accepted): $(sed -n 's/^reason=//p' "$s")"
}
case $STAGE in
  r1-lmdb) prev_r1 kv || { echo "SEQUENCE STOP: r1-kv not checked PASS + accepted (nor skipped)"; exit 2; };;
  r1-vdb) prev_r1 lmdb || { echo "SEQUENCE STOP: r1-lmdb not checked PASS + accepted (nor skipped)"; exit 2; };;
  r1-recsys) prev_r1 vdb || { echo "SEQUENCE STOP: r1-vdb not checked PASS + accepted (nor skipped)"; exit 2; };;
  r2|r3) for w in $WL; do accepted $w 1 || { echo "SEQUENCE STOP: r1 of $w not checked PASS + accepted$([ -f "$E/accept/r1-$w-skip.txt" ] && echo " (skipped)") (r2/r3 need r1 accepted for each chosen workload)"; exit 2; }; done
         if [ $N = 3 ]; then for w in $WL; do accepted $w 2 || { echo "SEQUENCE STOP: r2 of $w not checked PASS + accepted"; exit 2; }; done; fi;;
esac
# --retry preconditions (v0.6.8): the current r1 attempt of WL exists, was not accepted or skipped, did not pass its
# check, left no collect-all-r1, and its stage ended with SEQUENCE STOP; the new attempt is r1-a<k+1> (attempts.py)
AT= PREV= RETRYINFO=
if [ -n "$RETRY" ]; then
  rfail() { echo "SEQUENCE STOP: --retry refused for $STAGE: $*"; exit 2; }
  PREV=$(python3 -I -B $H/attempts.py dir "$E" "$WL" 1 2>&1) || rfail "no previous attempt of r1-$WL or bad attempt layout ($PREV)"
  NEXTA=$(python3 -I -B $H/attempts.py next "$E" "$WL" 1 2>&1) || rfail "attempts.py next: $NEXTA"
  [ ! -e "$E/accept/r1-$WL.txt" ] || rfail "r1 $WL is accepted ($E/accept/r1-$WL.txt)"
  [ ! -e "$E/accept/r1-$WL-skip.txt" ] || rfail "r1 $WL was skipped ($E/accept/r1-$WL-skip.txt; a skipped stage is not retried here)"
  ! { [ -f "$PREV/check.txt" ] && tail -n 1 "$PREV/check.txt" | grep -q "^H1CHECK PASS"; } || rfail "$PREV/check.txt is PASS (accept or skip it instead)"
  [ ! -e "$E/$WL/collect-all-r1" ] && [ ! -e "$E/$WL/collect-all-r1.log" ] || rfail "$E/$WL/collect-all-r1[.log] exists"
  LAST=$(grep -F "[$STAGE] " "$E/h1-state.txt" 2>/dev/null | tail -n 1)
  [[ "$LAST" == *"[$STAGE] SEQUENCE STOP"* ]] || rfail "the last $STAGE line in h1-state.txt is not a SEQUENCE STOP ('$LAST')"
  AT=-${NEXTA#r1-}
  RETRYINFO="attempt=${AT#-a} dir=$WL/$NEXTA predecessor=${PREV#$E/} reason=$RETRY"
fi
if [ "$DRY" = 1 ]; then
  case "${LOCK:-}" in */h1-main/*) ;; *) echo "SEQUENCE STOP: H1_DRY=1 needs LOCK=<test lock under workspaces/h1-main/>"; exit 2;; esac
else
  : "${PRETOUCH_DIR:?PRETOUCH_DIR = ENV-pretouch evidence dir of the current QEMU lifetime}" "${MEASURE_ENV_DIR:?}"
  : "${MEASURE_PART_DIR:?MEASURE_PART_DIR = measure-env-part.sh apply dir (option (ga), 2026-10-18)}"
  export PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR H1_MEASURE_RUN=1
fi
# code integrity (verifier MED-3; D2: at stage start, before each workload's collect/check and at stage end): the
# frozen manifest (freeze-manifest.sh, sha256 in the packet) must match the files byte for byte and list every file of
# experiments/h1. Required for real stages; optional in H1_DRY. The path is made absolute first (the check runs from
# the CXL_SWMC root). Untracked files outside experiments/h1 (e.g. a stray CXL_SWMC/recovery/) are not looked at.
MAN_ON=0
if [ "$DRY" != 1 ] || [ -n "${H1_MANIFEST:-}" ]; then
  : "${H1_MANIFEST:?H1_MANIFEST = frozen code manifest (recovery/H1-main-v<x>/manifest.sha256)}" "${H1_MANIFEST_SHA:?H1_MANIFEST_SHA = its sha256 from the packet}"
  H1_MANIFEST=$(readlink -f "$H1_MANIFEST") MAN_ON=1
fi
manifest_check() {  # <where>; prints the reason and returns 1 on a mismatch
  [ $MAN_ON = 1 ] || return 0
  [ -f "$H1_MANIFEST" ] && [ "$(sha256sum < "$H1_MANIFEST" | cut -c1-64)" = "$H1_MANIFEST_SHA" ] \
    || { echo "SEQUENCE STOP ($1): manifest $H1_MANIFEST missing or sha256 != H1_MANIFEST_SHA"; return 1; }
  local bad extra
  bad=$(cd "$H/../.." && sha256sum --quiet -c "$H1_MANIFEST" 2>&1 | head -3 | tr '\n' ' ')
  [ -z "$bad" ] || { echo "SEQUENCE STOP ($1): code differs from the frozen manifest: $bad"; return 1; }
  extra=$(cd "$H/../.." && find experiments/h1 -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | sort | while read -r f; do grep -q "  $f\$" "$H1_MANIFEST" || echo "$f"; done)
  [ -z "$extra" ] || { echo "SEQUENCE STOP ($1): files in experiments/h1 not in the manifest: $extra"; return 1; }
}
manifest_check start || exit 2
# D3: stages are launched with `setsid nohup` (packet §5), so this shell leads its own process group and the §8.3 stop
# (kill -TERM -- -<pgid>) reaches the whole stage; a real stage refuses otherwise
PGID=$(ps -o pgid= -p $$ | tr -d ' ')
[ "$DRY" = 1 ] || [ "$PGID" = "$$" ] || { echo "SEQUENCE STOP: pgid $PGID != pid $$ (launch with setsid nohup, packet §5)"; exit 2; }
log() { echo "$(date -Is) [$STAGE] $*" | tee -a "$E/h1-state.txt"; }
stop() { log "SEQUENCE STOP $*"; exit 1; }
bash $G lock $OWNER || { echo "SEQUENCE STOP: lock"; exit 2; }
trap 'bash $G unlock $OWNER' EXIT
{ echo "# H1 main stage $STAGE"; echo "start=$(date -Is)"; echo "cxl_swmc_commit=$(git -C $H rev-parse HEAD 2>/dev/null)"
  echo "cxl_swmc_dirty_h1=$(git -C $H status --porcelain -- . | wc -l)"; echo "plan=$PLAN sha256=$(sha256sum < "$PLAN" | cut -c1-64)"
  for f in h1-main.sh hook.sh h1-gate.sh levels.py levels-cb.sh collect.py check.py h1-accept.sh h1sys.py attempts.py; do echo "$f sha256=$(sha256sum < $H/$f | cut -c1-64)"; done
  for f in v6_fig2_split.py v6_common.py v6_fig1_curves.py; do echo "analysis/$f sha256=$(sha256sum < $H/../analysis/$f | cut -c1-64)"; done
  echo "stage=$STAGE round=$N workloads=$WL seed_base=$H1_SEED_BASE dry=$DRY"
  [ -z "$RETRY" ] || echo "retry: $RETRYINFO"
  echo "pretouch_dir=${PRETOUCH_DIR:-} measure_env_dir=${MEASURE_ENV_DIR:-} measure_part_dir=${MEASURE_PART_DIR:-}"
  echo "manifest=${H1_MANIFEST:-} manifest_sha256=${H1_MANIFEST_SHA:-}"
  for f in measure-env.sh measure-env-part.sh measure-run.sh; do echo "scripts/host/$f sha256=$(sha256sum < $H/../../scripts/host/$f | cut -c1-64)"; done
  for w in $WL; do f=$H/plugins/pins-$w.sh; [ "$DRY" = 1 ] && f=$H/plugins/pins-stub.sh
    echo "pins.$w=$f sha256=$(sha256sum < "$f" 2>/dev/null | cut -c1-64)"; done; } >> "$E/h1-manifest.txt"
gates() {  # tag
  if [ "$DRY" = 1 ]; then log "gate $1: DRY (pretouch and Host gates skipped)"; return 0; fi
  bash $PG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null || stop "pretouch gate ($1; see pretouch-gate.txt)"
  MEASURE_ENV_DIR=$MEASURE_ENV_DIR MEASURE_PART_DIR=$MEASURE_PART_DIR bash $H/h1-gate.sh check "$E/gate-$1.txt" || stop "h1 gate ($1)"
  log "gate $1: PASS"
}
log "stage start: round $N, workloads [$WL], pid $$ pgid $PGID, manifest $([ $MAN_ON = 1 ] && echo "$H1_MANIFEST ok" || echo "off (dry)")"
[ -z "$SKIPNOTE" ] || log "$SKIPNOTE"
[ -z "$RETRY" ] || log "RETRY $RETRYINFO"
for W in $WL; do
  T0=$(date +%s) S=$E/$W/r$N LV=$E/$W/levels.tsv
  if [ -n "$RETRY" ]; then S=$E/$W/$NEXTA LV=$S/levels.tsv   # round 1 retry: own levels.tsv (attempts.py)
  elif [ $N != 1 ]; then LV=$(python3 -I -B $H/attempts.py levels "$E" "$W" 2>&1) || stop "$W: attempts.py levels: $LV"; fi
  MIXES=$(awk -F'\t' -v w="$W" '!/^#/ && $1 == w { printf "%s=%s ", $2, $3 }' "$PLAN")
  [ ! -e "$S" ] || stop "$S exists (stage dirs are immutable; a stopped r1 stage is re-run with --retry)"
  SETTLE=$(awk -F'\t' -v w="$W" '!/^#/ && $1 == w { print $8; exit }' "$PLAN")
  [[ $SETTLE =~ ^[1-9][0-9]*$ ]] || stop "$W: no settle_s in the plan"
  mkdir -p "$E/$W" && mkdir "$S" || stop "mkdir $S"
  if [ -n "$RETRY" ]; then  # the new attempt's manifest: written first, before anything else lands in $S
    { echo "# H1 stage attempt (h1-main.sh --retry, packet v0.6.8 §3)"
      echo "workload=$W"; echo "round=$N"; echo "attempt=${AT#-a}"; echo "predecessor=${PREV##*/}"
      echo "predecessor_dir=$PREV"
      echo "predecessor_state_last=$LAST"
      echo "predecessor_check=$([ -f "$PREV/check.txt" ] && echo "$(sha256sum < "$PREV/check.txt" | cut -c1-64) $(tail -n 1 "$PREV/check.txt")" || echo none)"
      echo "predecessor_accept=none predecessor_skip=none"
      echo "predecessor_files=$(find "$PREV" -type f | wc -l) listing_sha256=$(cd "$PREV" && find . -type f -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64)"
      echo "predecessor_h1_runs_sha256=$(sha256sum < "$PREV/run/h1-runs.tsv" 2>/dev/null | cut -c1-64)"
      echo "reason=$RETRY"; echo "created=$(date -Is)"; echo "stage=$STAGE pid=$$"
      echo "manifest=${H1_MANIFEST:-} manifest_sha256=${H1_MANIFEST_SHA:-}"; } > "$S/attempt.txt" || stop "attempt.txt"
    CUR=$(python3 -I -B $H/attempts.py dir "$E" "$W" 1 2>&1)
    [ "$CUR" = "$S" ] || stop "attempts.py resolves $CUR, not the new attempt $S"
  fi
  mkdir "$S/run" || stop "mkdir $S/run"
  gates "$W-r$N$AT-start"
  if [ $N = 1 ]; then  # r1: per mix hw/pop SLO-only lifetimes, mg SLO -> levels (callback) -> settle -> L2 -> L1,
                       # then hw/pop separate fixed lifetimes (dec 2026-10-18)
    [ ! -e "$LV" ] || stop "$W: levels.tsv exists before r1 ($LV)"
    log "$W r1$AT: mixes [$MIXES], settle ${SETTLE}s"
    env H1_SETTLE_S=$SETTLE H1_LEVELS_CMD=$H/levels-cb.sh H1_PLAN="$PLAN" H1_W=$W H1_LEVELS_OUT="$LV"       bash $H/hook.sh "$W" r1 "$S/run" 1 "$MIXES" || stop "$W r1$AT"
    for m in $MIXES; do grep -q "^${m%%=*}	" "$LV" 2>/dev/null || stop "$W: levels.tsv has no row for ${m%%=*}"; done
    log "$W levels: $(($(grep -c . "$LV") - 1)) mixes ($LV, computed in r1 $(python3 -I -B $H/h1sys.py slo "$W" | grep -qw mg && echo "in the mg lifetimes" || echo "right after the hw/pop SLO-only lifetimes of each mix"))"
  else                 # r2/r3: every system one lifetime SLO -> settle -> L2 -> L1 at the r1 levels
    [ -f "$LV" ] || stop "$W: no levels.tsv ($LV)"
    log "$W r$N: mixes [$MIXES], settle ${SETTLE}s"
    env H1_SETTLE_S=$SETTLE bash $H/hook.sh "$W" cont "$S/run" "$N" "$MIXES" "$LV" || stop "$W r$N"
  fi
  gates "$W-r$N$AT-end"
  manifest_check "$W r$N$AT before collect" > "$E/manifest-$W-r$N$AT.txt" || stop "$(cat "$E/manifest-$W-r$N$AT.txt")"
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$LV" ${H1_NO_FIGS:+--no-figs} "$S" \
    > "$S/collect.log" 2>&1 || stop "$W r$N$AT collect: $(tail -n 1 "$S/collect.log")"
  python3 -B $H/check.py --plan "$PLAN" --workload "$W" --round "$N" $([ "$DRY" = 1 ] && echo --skip-fig2) "$E" > "$S/check.log" 2>&1
  CRC=$?
  log "$W r$N$AT ($(( ($(date +%s) - T0) / 60 )) min): $(tail -n 1 "$S/check.txt" 2>/dev/null || echo 'no check.txt')"
  [ $CRC = 0 ] || stop "$W r$N$AT check FAIL (see $S/check.txt)"
  grep -q "^REPORT" "$S/check.txt" && log "$W r$N: REPORT lines (separate vs continuous beyond the run-to-run spread): report to the user before r3; h1-accept.sh needs --user-ack"
done
# collect-all after every stage, per workload of the stage: every round present so far (r1 only = single round, no
# variance; r1 + r2 for a subset; ...) into <W>/collect-all-r<n> (immutable; one per round count)
for W in $WL; do
  LV=$(python3 -I -B $H/attempts.py levels "$E" "$W" 2>&1) || stop "$W: attempts.py levels: $LV"
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$LV" --out-name collect-all-r$N \
    ${H1_NO_FIGS:+--no-figs} "$E/$W" > "$E/$W/collect-all-r$N.log" 2>&1 || stop "$W collect-all-r$N: $(tail -n 1 "$E/$W/collect-all-r$N.log")"
done
log "collect-all-r$N done for [$WL] (rounds 1..$N; slo-summary.csv states single round / mean and sd)"
manifest_check "stage end" > "$E/manifest-end-$STAGE$AT.txt" || stop "$(cat "$E/manifest-end-$STAGE$AT.txt")"
if [ $N = 1 ]; then
  log "STAGE DONE $STAGE: main session reviews $S/check.txt, then: bash $H/h1-accept.sh $E 1 $WL"
else
  log "STAGE DONE $STAGE [$WL]: review each r$N/check.txt (REPORT lines -> user first), then h1-accept.sh $E $N <W> [--user-ack ...]"
fi

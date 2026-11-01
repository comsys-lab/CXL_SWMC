#!/bin/bash
# Run set "rs-h1" (evaluation-pipeline rev 3 §3.3, §6.2; Q2): Megalon RecSys (table objects, RS_MG_TABLE_N) at the
# RS_MG_POINTS streaming rates, same block, threads, region and seeds as rs-main (main-block.sh BLOCK=stream, EVAL_RUN).
#   run 1: MGPROBE = one Megalon fix-only lifetime per rate with one RS_MG_PROBE_Q (1) q/s window (block dir probe/);
#          decision per rate (mg-decision.tsv): "slo" if the probe window's query p95 <= RS_SLO_MS and the window is
#          valid (stream_check rule), else "fix" (no SLO search: Megalon cannot pass at the lowest rate).
#          RS_MG_SLO=always | never overrides the rule.
#   then per decision group one block (slo/ and fix/): "slo" rates: mg SLO lifetime, then fix-only lifetimes of mg and
#          mgoff (timers off, C_diff) at RS_MG_FIX_LEVELS; "fix" rates: mgoff fix-only lifetime (run 1: the probe
#          lifetime is the mg window when RS_MG_FIX_LEVELS = RS_MG_PROBE_Q) or mg + mgoff fix-only lifetimes.
#   runs k >= 2 (cut Q8): no probe; decisions from run LEVELS_FROM_RUN's mg-decision.tsv (accepted run).
# Layout: E/eval-manifest.txt, E/eval-state.txt, E/mg-decision.tsv, E/{probe,slo,fix}/ (block evidence dirs).
# Optional conf key RS_MG_MGOFF (default 1; eval3 block C: 0): 0 = no mgoff lifetime (no C_diff): the probe alone is the
#   Megalon floor at a "fix" rate; a "slo" rate gets the mg SLO lifetime only (no fixed windows).
# usage: runset-rs-h1.sh <k> [--dry] [--v N]   (lib.sh)
RUNSET=rs-h1 WL=recsys
unset RS_MG_MGOFF   # conf key only (never inherited from the environment)
. "$(dirname "$0")/lib.sh"
MGOFF=${RS_MG_MGOFF:-1}
[[ $MGOFF =~ ^[01]$ ]] || die "bad RS_MG_MGOFF ($MGOFF)"
rs_checks
for r in $RS_MG_POINTS; do [[ $r =~ ^[1-9][0-9]*$ ]] && [ $((r % 50)) = 0 ] || die "bad RS_MG_POINTS rate $r"; done
case $RS_MG_SLO in auto|always|never) ;; *) die "bad RS_MG_SLO";; esac
PROBE=0 DEC=
if [ "$K" = "$LEVELS_FROM_RUN" ]; then
  [ $RS_MG_SLO != auto ] || PROBE=1
else
  if E1=$(run_dir_of rs-h1 "$LEVELS_FROM_RUN"); then DEC=$E1/mg-decision.tsv; need_files "$DEC"
  elif [ $DRY = 1 ]; then plan "decisions: run $LEVELS_FROM_RUN of rs-h1 not accepted yet (a real run would stop here)"
  else die "run $LEVELS_FROM_RUN of rs-h1 is not accepted (registry.py accept)"; fi
fi
need_env
lock_free
evidence_dir
rs_env
BASEENV=("${RSENV[@]}")
block() {  # <dir name> <rates> <systems> <fix-only> <levels>: one main-block.sh call (real) or its dry start
  local d=$1 rates=$2 sys=$3 fo=$4 lv=$5
  local B=(env "${BASEENV[@]}" SYSTEMS="$sys" STREAM_RATES="$rates" STREAM_FIXONLY="$fo" STREAM_FIX_LEVELS="$lv"
           STREAM_FIX_SEP=1 bash $TREE/experiments/recsys/main-block.sh)
  plan "block $d: rates [$rates] systems [$sys] fix-only [$fo] levels [$lv]"
  if [ $DRY = 1 ]; then block_dry "missing or not empty" "${B[@]}" @DIR@; return 0; fi
  mkdir "$E/$d" || stop "mkdir $E/$d"
  log "block $d start: rates [$rates] systems [$sys] fix-only [$fo] levels [$lv]"
  "${B[@]}" "$E/$d" > "$E/$d/sequence.log" 2>&1
  log "block $d rc $?: $(tail -n 1 "$E/$d/sequence.log")"
  local slo=""; [[ " $fo " == *" mg "* ]] || [[ " $sys " != *" mg "* ]] || slo=mg
  python3 -I -B $EVD/rs_check.py "$E/$d" --rates "$rates" --slo-systems "$slo" --fix-systems "$sys" > /dev/null
  log "check $d: $(tail -n 1 "$E/$d/rs-check.txt")"
  tail -n 1 "$E/$d/rs-check.txt" | grep -q "^RSCHECK PASS" || stop "check $d FAIL (see $E/$d/rs-check.txt)"
}
groups() {  # from mg-decision.tsv (or RS_MG_SLO) -> SLO_RATES, FIX_RATES
  local r d
  SLO_RATES= FIX_RATES=
  for r in $RS_MG_POINTS; do
    case $RS_MG_SLO in always) d=slo;; never) d=fix;;
      auto) d=$(awk -v r="$r" '!/^#/ && $1 == r { print $2 }' "$1" 2>/dev/null | tail -1)
            [[ $d =~ ^(slo|fix)$ ]] || { [ $DRY = 1 ] && d=fix; } || stop "no decision for rate $r in $1";;
    esac
    [ $d = slo ] && SLO_RATES="$SLO_RATES $r" || FIX_RATES="$FIX_RATES $r"
  done
  SLO_RATES=${SLO_RATES# } FIX_RATES=${FIX_RATES# }
}
if [ $DRY = 1 ]; then
  [ $PROBE = 0 ] || block probe "$RS_MG_POINTS" mg mg "$RS_MG_PROBE_Q"
  groups "${DEC:-/dev/null}"
  plan "decisions (dry: unknown rates shown as fix): slo [$SLO_RATES] fix [$FIX_RATES] (RS_MG_MGOFF=$MGOFF)"
  if [ $MGOFF = 0 ]; then
    [ -z "$SLO_RATES" ] || block slo "$SLO_RATES" mg "" ""
    [ -z "$FIX_RATES" ] || [ $PROBE = 1 ] || block fix "$FIX_RATES" mg mg "$RS_MG_FIX_LEVELS"
  else
    [ -z "$SLO_RATES" ] || block slo "$SLO_RATES" "mg mgoff" mgoff "$RS_MG_FIX_LEVELS"
    [ -z "$FIX_RATES" ] || block fix "$FIX_RATES" "mg mgoff" "mg mgoff" "$RS_MG_FIX_LEVELS"
  fi
  echo "DRY START OK ($RUNSET run $K): stops here, before the lock"; exit 0
fi
mkdir "$E" || die "mkdir $E"
log() { echo "$(date -Is) [$RUNSET run $K] $*" | tee -a "$E/eval-state.txt"; }
stop() { log "SEQUENCE STOP $*"; $REG add recsys rs-h1 $K "$E" $CSHA stopped "$*"; exit 1; }
manifest "$RS_PLAIN_BUILD" "$RS_MEG_BUILD" "$(dirname "$RS_LOADGEN")"
$REG add recsys rs-h1 $K "$E" $CSHA started "commit $COMMIT"
printf '# rate_sps\tdecision\tprobe_p95_ms\tprobe_valid\tsource\n' > "$E/mg-decision.tsv"
if [ $PROBE = 1 ]; then
  block probe "$RS_MG_POINTS" mg mg "$RS_MG_PROBE_Q"
  python3 -I -B $EVD/mg_decide.py "$E/probe" "$RS_MG_POINTS" "$RS_SLO_MS" >> "$E/mg-decision.tsv" || stop "probe decision"
  log "probe decisions: $(grep -v '^#' "$E/mg-decision.tsv" | cut -f1,2 | tr '\t\n' '= ')"
elif [ -n "$DEC" ]; then
  awk -F'\t' -v f="$DEC" '!/^#/ { printf "%s\t%s\t%s\t%s\tfrom %s\n", $1, $2, $3, $4, f }' "$DEC" >> "$E/mg-decision.tsv"
else
  for r in $RS_MG_POINTS; do printf '%s\t%s\t\t\tRS_MG_SLO=%s\n' $r $([ $RS_MG_SLO = always ] && echo slo || echo fix) $RS_MG_SLO >> "$E/mg-decision.tsv"; done
fi
groups "$E/mg-decision.tsv"
if [ $MGOFF = 0 ]; then  # eval3: no mgoff; a probed "fix" rate is done (the probe window is the floor)
  [ -z "$SLO_RATES" ] || block slo "$SLO_RATES" mg "" ""
  [ -z "$FIX_RATES" ] || [ $PROBE = 1 ] || block fix "$FIX_RATES" mg mg "$RS_MG_FIX_LEVELS"
else
  [ -z "$SLO_RATES" ] || block slo "$SLO_RATES" "mg mgoff" mgoff "$RS_MG_FIX_LEVELS"
fi
if [ $MGOFF = 1 ] && [ -n "$FIX_RATES" ]; then
  if [ $PROBE = 1 ] && [ "$RS_MG_FIX_LEVELS" = "$RS_MG_PROBE_Q" ]; then block fix "$FIX_RATES" mgoff mgoff "$RS_MG_FIX_LEVELS"
  else block fix "$FIX_RATES" "mg mgoff" "mg mgoff" "$RS_MG_FIX_LEVELS"; fi
fi
$REG add recsys rs-h1 $K "$E" $CSHA measured "slo [$SLO_RATES] fix [$FIX_RATES]"
export_run "$TREE/experiments/recsys/export.py" "$E"
log "RUNSET DONE: review $E/*/rs-check.txt and mg-decision.tsv, then: python3 $EVD/registry.py accept rs-h1 $K $E"

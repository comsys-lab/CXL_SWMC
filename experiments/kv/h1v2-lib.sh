# H1-HOOK v2 orchestration shared by the KV block (experiments/kv/pilot-block.sh h1) and the LMDB block
# (experiments/lmdb/h1-block.sh); contract: experiments/h1/README.md "Hook contract H1-HOOK v2" (user decision
# 2026-10-18 "H1 lifetime 구성 변경"). Sourced, not executed. Marker: H1-HOOK v2
# The sourcing block defines: E (evidence dir), H1W (kv | lmdb), V1CHECK (path of experiments/kv/v1-check.py),
#   parent_lock_check, ptcheck <tag>, h1_dmesg <run>, and h1_pilot <lifetime> <sys> <env...> (one pilot-run.sh KIND=h1life
#   call of that system with the block's environment; it stops the block unless "PILOTRUN <lifetime> OK|NOTE").
# Env (hook.sh): H1MODE r1|cont, H1_N, H1_SEED, H1_MIXES "<mix>=<param> ...", H1_SETTLE_S, r1: H1_LEVELS_CMD (+ its env
#   H1_PLAN H1_W H1_LEVELS_OUT H1_STAGE_DIR, inherited), cont: H1_LEVELS.
# Layout (README §2-§6):
#   r1, per mix (mix order: shuffle seed H1-<W>-r1-mixes):
#     a. hw, pop SLO-only lifetimes <sys>-<mix>-slo-r1 (part slo; order seed H1-<W>-r1-<mix>), lifetime "sep";
#     b. mg lifetime mg-<mix>-r1: part slo; before part fix the callback <E>/mg-<mix>-r1.levels.sh appends the slo line
#        to h1-runs.tsv and runs "$H1_LEVELS_CMD" <mix> ("<L2> <L1>"; non-zero = LEVELS STOP, the run and the block stop);
#        part fix at those rates in the same lifetime; lifetime "cont";
#     c. mgoff lifetime mgoff-<mix>-fix-r1 right after mg (part fix, MEGALON_COH_TIMERS=0), "sep";
#     d. hw, pop fixed lifetimes <sys>-<mix>-fix-r1 (part fix; order seed H1-<W>-r1-<mix>-fix), "sep".
#   cont (rounds 2, 3), per mix (mix order: shuffle seed H1-<W>-r<N>-mixes; rates = H1_LEVELS L2_rate / L1_rate):
#     hw, pop, mg in the order of shuffle seed H1-<W>-latin rotated left by N (Latin square over rounds), each one
#     lifetime <sys>-<mix>-r<N> with parts slo then fix ("cont"); mgoff lifetime mgoff-<mix>-fix-r<N> right after mg ("sep").
#   Settle = H1_SETTLE_S s at the L2 rate as loadgen --warmup-s of the fix part (pilot-run.sh KIND=h1life).
# Per lifetime: <lifetime>/h1-runcheck.txt = PILOTRUN line + per part v1-check.py (--opsplit/--loadgen-steps of the
#   part; mgoff --timers off) + loadgen finish + pretouch + dmesg + kernel; last line RUNCHECK PASS[ (NOTE: ...)].
# <E>/h1-runs.tsv (8 columns): name system mix phase round run_dir steps lifetime, appended as parts finish.

h1shuf() { python3 -B -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$@"; }
h1_entry() {  # name sys mix phase run_dir steps lifetime
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$H1_N" "$5" "$6" "$7" >> "$E/h1-runs.tsv"
}
h1_life() {  # <lifetime> <sys> <mix> <parts> <env...>: one lifetime through h1_pilot, then its per-part checks
  local life=$1 s=$2 m=$3 parts=$4 st v1 tm=on sysv part nt="" pv; shift 4
  parent_lock_check
  ptcheck "$life"
  h1_pilot "$life" "$s" KIND=h1life H1_PARTS="$parts" H1_SETTLE_S=$H1_SETTLE_S SEED=$H1_SEED "$@"
  st=$(grep -h "^PILOTRUN $life " "$E/runs.log" | tail -n 1)
  [[ "$st" =~ ^PILOTRUN\ $life\ (OK|NOTE) ]] || { echo "$(date -Is) SEQUENCE STOP: $life no PILOTRUN OK/NOTE"; exit 1; }
  [[ "$st" =~ \ NOTE\  ]] && nt="${st#PILOTRUN $life NOTE }"
  case $s in hw) sysv=all-HWcc;; pop) sysv=Popcorn;; mg) sysv=Megalon;; mgoff) sysv=Megalon; tm=off;; esac
  { echo "# H1 per-run checks $life (system $s, mix $m, parts [$parts], round $H1_N, seed $H1_SEED, settle ${H1_SETTLE_S}s; H1-HOOK v2)"
    echo "$st"; } > "$E/$life/h1-runcheck.txt"
  for part in $parts; do
    v1=$(python3 -I -B $V1CHECK "$E/$life" --system $sysv --timers $tm --workload $H1W --opsplit "$E/$life/$part/opsplit.csv" \
         --loadgen-steps "$E/$life/$part/loadgen/steps.jsonl" --out "$E/$life/$part/v1-check.txt")
    echo "$life/$part $v1" >> "$E/v1-check.log"
    [[ "$v1" == "V1 CHECK PASS"* ]] || { echo "$(date -Is) SEQUENCE STOP: v1-check $life/$part: $v1"; exit 1; }
    [[ "$v1" == *"(notes:"* ]] && nt="${nt:+$nt; }$part v1-check${v1#V1 CHECK PASS}"
    pv=$(python3 -I -B -c 'import json,sys; s=json.load(open(sys.argv[1])); print("workload_finish", s.get("workload_finish"), "note", repr(s.get("note", "")))' "$E/$life/$part/loadgen/summary.json")
    { echo "$part v1-check: $v1"; grep -h "^NOTE \|^WARN " "$E/$life/$part/v1-check.txt" | sed "s/^/$part v1-check: /" | cut -c1-400
      echo "$part loadgen: $pv"; [ "$part" = fix ] && echo "fix rates (L2,L1): $(cat "$E/$life/fix/rates.txt") steps: $(cat "$E/$life/fix/fix-steps.txt")"
    } >> "$E/$life/h1-runcheck.txt"
    [[ "$pv" == "workload_finish ok"* ]] && [ -s "$E/$life/$part/opsplit.csv" ] || { echo "SEQUENCE STOP: $life/$part run checks incomplete"; exit 1; }
  done
  h1_dmesg "$life"
  { echo "pretouch: $(tail -n 1 "$E/pretouch-check-$life.txt")"
    echo "dmesg: no new error/warning lines on vm0/vm1 since the block start"
    echo "kernel: $(grep -h '^node0=' "$E/$life/manifest.txt")"
    if [ -n "$nt" ]; then echo "RUNCHECK PASS (NOTE: $nt)"; else echo "RUNCHECK PASS"; fi; } >> "$E/$life/h1-runcheck.txt"
}
h1_param() {  # <mix>: the mix parameter value from H1_MIXES (e.g. u5 -> 0.05 for PUT_RATIO=0.05)
  local spec; for spec in $H1_MIXES; do [ "${spec%%=*}" = "$1" ] && { echo "${spec#*=}"; return 0; }; done; return 1
}
h1_levels_cb() {  # <mix>: write the r1 mg callback script, print its path
  local cb=$E/mg-$1-r1.levels.sh
  { echo '#!/bin/bash'
    echo "# H1-HOOK v2 r1 levels callback of mg-$1-r1 (run before its fix part): slo line, then H1_LEVELS_CMD"
    echo 'set -uo pipefail'
    printf 'printf %q >> %q\n' "mg-$1-r1-slo"$'\t'"mg"$'\t'"$1"$'\t'"slo"$'\t'"$H1_N"$'\t'"mg-$1-r1/slo"$'\t'"-"$'\t'"cont"$'\n' "$E/h1-runs.tsv"
    printf 'o=$(%q %q) || { echo "LEVELS STOP %s (rc $?)" >&2; exit 1; }\n' "$H1_LEVELS_CMD" "$1" "$1"
    printf 'echo "$o" > %q\n' "$E/levels-$1.txt"
    echo 'echo "$o"'; } > "$cb"
  echo "$cb"
}
h1v2_main() {  # <param name> (PUT_RATIO | UPDATE_RATIO); the run kind and system env come from h1_pilot
  local pn=$1 mixes m s u base rot ord l1 l2 f life cb
  printf '# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n' > "$E/h1-runs.tsv"
  mixes=""; for spec in $H1_MIXES; do mixes="$mixes ${spec%%=*}"; done
  mixes=$(h1shuf H1-$H1W-r$H1_N-mixes $mixes)
  if [ "$H1MODE" = r1 ]; then
    { echo "# H1 $H1W round 1 (r1 layout; mixes: shuffle seed H1-$H1W-r1-mixes; loadgen seed $H1_SEED; settle ${H1_SETTLE_S}s)"
      echo "mixes: $mixes"
      for m in $mixes; do echo "$m: slo $(h1shuf H1-$H1W-r1-$m hw pop) mg(slo+fix) mgoff(fix) fix $(h1shuf H1-$H1W-r1-$m-fix hw pop)"; done
      echo "H1_MIXES: $H1_MIXES"; } | tee "$E/order.txt"
    for m in $mixes; do
      u=$(h1_param $m) || { echo "SEQUENCE STOP: mix $m"; exit 1; }
      for s in $(h1shuf H1-$H1W-r1-$m hw pop); do
        h1_life $s-$m-slo-r1 $s $m slo $pn=${u#*=}
        h1_entry $s-$m-slo-r1 $s $m slo $s-$m-slo-r1/slo - sep
      done
      cb=$(h1_levels_cb $m)
      h1_life mg-$m-r1 mg $m "slo fix" $pn=${u#*=} FIX_RATES_CMD="bash $cb"
      grep -q "^mg-$m-r1-slo	" "$E/h1-runs.tsv" || { echo "SEQUENCE STOP: mg-$m-r1: slo line missing (callback not run)"; exit 1; }
      h1_entry mg-$m-r1-fix mg $m fix mg-$m-r1/fix "$(cat "$E/mg-$m-r1/fix/fix-steps.txt")" cont
      read -r l2 l1 < "$E/levels-$m.txt"
      [[ $l2 =~ ^[1-9][0-9]*$ ]] && [[ $l1 =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: levels $m '$l2 $l1'"; exit 1; }
      h1_life mgoff-$m-fix-r1 mgoff $m fix $pn=${u#*=} RATES=$l2,$l1
      h1_entry mgoff-$m-fix-r1 mgoff $m fix mgoff-$m-fix-r1/fix "$(cat "$E/mgoff-$m-fix-r1/fix/fix-steps.txt")" sep
      for s in $(h1shuf H1-$H1W-r1-$m-fix hw pop); do
        h1_life $s-$m-fix-r1 $s $m fix $pn=${u#*=} RATES=$l2,$l1
        h1_entry $s-$m-fix-r1 $s $m fix $s-$m-fix-r1/fix "$(cat "$E/$s-$m-fix-r1/fix/fix-steps.txt")" sep
      done
    done
  else
    base=($(h1shuf H1-$H1W-latin hw pop mg)); rot=$(( H1_N % 3 ))
    ord=$(echo "${base[@]:$rot} ${base[@]:0:$rot}")
    { echo "# H1 $H1W round $H1_N (cont layout; mixes: shuffle seed H1-$H1W-r$H1_N-mixes; systems: base seed H1-$H1W-latin rotated left by $rot; mgoff after mg; loadgen seed $H1_SEED; settle ${H1_SETTLE_S}s; levels $H1_LEVELS)"
      echo "mixes: $mixes"; echo "systems: $ord"; echo "H1_MIXES: $H1_MIXES"; } | tee "$E/order.txt"
    for m in $mixes; do
      u=$(h1_param $m) || { echo "SEQUENCE STOP: mix $m"; exit 1; }
      f=$(awk -F'\t' -v m=$m 'NR > 1 && $1 == m { print $10, $9 }' "$H1_LEVELS")
      read -r l2 l1 <<< "$f"
      [[ ${l2:-} =~ ^[1-9][0-9]*$ ]] && [[ ${l1:-} =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: levels $m '$f' (integers expected)"; exit 1; }
      for s in $ord; do
        h1_life $s-$m-r$H1_N $s $m "slo fix" $pn=${u#*=} RATES=$l2,$l1
        h1_entry $s-$m-r$H1_N-slo $s $m slo $s-$m-r$H1_N/slo - cont
        h1_entry $s-$m-r$H1_N-fix $s $m fix $s-$m-r$H1_N/fix "$(cat "$E/$s-$m-r$H1_N/fix/fix-steps.txt")" cont
        if [ $s = mg ]; then
          h1_life mgoff-$m-fix-r$H1_N mgoff $m fix $pn=${u#*=} RATES=$l2,$l1
          h1_entry mgoff-$m-fix-r$H1_N mgoff $m fix mgoff-$m-fix-r$H1_N/fix "$(cat "$E/mgoff-$m-fix-r$H1_N/fix/fix-steps.txt")" sep
        fi
      done
    done
  fi
}

#!/bin/bash
# damonx-hook.sh: run.sh part hooks of h2n-block.sh ds lifetimes with H2N_DS_DAMON_AT=ready (experiment
# damon-policy-exploration; workspaces/destijl-v2/damon-replication/DESIGN.md §4-5, §9 points E0b / E1).
# DAMON starts after the servers are READY (run.sh calls PART_PRE_CMD of the first part after READY + port check), not
# before the server's sequential warm-up read as in run 1; with H2N_DS_DAMON_WARMUP the lifetime's parts are
#   wa (phase A, learn: scheme action stat, ages build up) -> wb01..wbNN (phase B, fill: action replicate with the
#   warmup quotas) -> slo [l1] (steady-state quotas = the 9 H2N_DS_DAMON values)
# at the fixed rate R_w; phase B ends at the DESIGN §5 end condition (every VM: replica_create rate < end_pps pages/s in
# end_n consecutive 10 s samples of the block's DAMON sampler AND phase B >= min_fill_s) checked before each wbNN part,
# or after max_parts x part_s (WARMUP_TIMEOUT, recorded; the run continues).
# usage (run.sh PART_PRE_CMD / PART_POST_CMD / PART_SKIP_CMD, word-split, part name appended):
#   damonx-hook.sh pre <part> | post <part> | skip <part>
# env (h2n-block.sh vdb_life / vdb_fixed_life): DAMONX_E (block evidence dir), DAMONX_NAME (lifetime name),
#   DAMONX_IPS, DAMONX_GUEST (ds-damon-guest.sh), DAMONX_ARGS (the 9 H2N_DS_DAMON integers in start order),
#   DAMONX_START_EXTRA (ds-damon-guest.sh start keys), DAMONX_RANGE (index | managed), DAMONX_POOL (bytes),
#   DAMONX_V (guest install dir: <V>/runs/<name>-<rid>/node<k>.log = the server's layout line), DAMONX_WARM (warmup
#   spec or empty), DAMONX_FIXED_KEY (fixed lifetimes: the H2N_FIXED key; fixed-part-hook.sh runs first / last)
# Files: E/ds-damon-<name>.txt (start / commit lines, same file as the block's 10 s sampler), E/damonx-<name>.state,
#   E/damonx-warmup-<name>.txt (phase times, end reason, per-VM end rates), E/damonx-warmup-<name>.csv (per 10 s sample
#   and VM: t_epoch, vm, phase, replica_pages, create_per_s, applied_pages_per_s, pool_fill_pct)
# Exit: pre/post 0 = OK (else run.sh stops the lifetime, rc 97 / 98); skip 0 = skip the part, 1 = run it, 2 = error.
# DAMONX_HOOK_DRY=1: print the guest commands instead of running them (Host test).
set -uo pipefail
PH=${1:?pre|post|skip} PART=${2:?part}
: "${DAMONX_E:?}" "${DAMONX_NAME:?}" "${DAMONX_IPS:?}" "${DAMONX_GUEST:?}" "${DAMONX_ARGS:?}" "${DAMONX_RANGE:?}" "${DAMONX_POOL:?}" "${DAMONX_V:?}"
E=$DAMONX_E NAME=$DAMONX_NAME WARM=${DAMONX_WARM:-} FK=${DAMONX_FIXED_KEY:-} DRY=${DAMONX_HOOK_DRY:-0}
EV=$(cd "$(dirname "$0")" && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
ST=$E/damonx-$NAME.state DF=$E/ds-damon-$NAME.txt
read -r -a IPS <<< "$DAMONX_IPS"; read -r -a DA <<< "$DAMONX_ARGS"
[ ${#DA[@]} = 9 ] || { echo "HOOK FAIL: DAMONX_ARGS needs 9 integers ($DAMONX_ARGS)"; exit 2; }
say() { echo "$(date -Is) damonx $PH $PART: $*"; }
sget() { sed -n "s/^$1 //p" "$ST" 2>/dev/null | tail -n 1; }
sput() { echo "$1 $2" >> "$ST"; }
wv() { echo " $WARM " | sed -n "s/.* $1=\([0-9][0-9]*\) .*/\1/p"; }
guest() {  # <ip> <args...>: ds-damon-guest.sh as root on the guest; output on stdout
  local ip=$1; shift
  if [ "$DRY" = 1 ]; then echo "DRY $ip: sudo -n sh -s -- $*"; case $1 in start) echo "DAMON ON (dry)";; commit) echo "DAMON COMMIT (dry)";; esac; return 0; fi
  $SSH comsys@$ip "sudo -n sh -s -- $*" < "$DAMONX_GUEST" 2>&1
}
commit_all() {  # <tag> <action> <ms> <bytes> <reset>
  local ip out rc=0
  for ip in "${IPS[@]}"; do
    out=$(guest $ip commit "$2" "$3" "$4" "$5")
    echo "$(date -Is) $NAME $1 $ip: $out" >> "$DF"
    [[ $out == "DAMON COMMIT "* ]] || { [ "$DRY" = 1 ] && [[ $out == *$'\n'"DAMON COMMIT "* ]]; } || rc=1
  done
  say "commit $1: action $2 quota ${3} ms ${4} B per ${5} ms (rc $rc)"; return $rc
}
start_all() {  # kdamond on every VM (first part of the lifetime, servers READY)
  local i ip out ma reg sp np s e lay off ue g k act=
  sleep "${DAMONX_SETTLE_S:-5}"   # DESIGN §5 step 1: +5 s settle after READY
  [ -z "$WARM" ] || act=" action=stat"   # warmup phase A: learn only (ages build up; stat does not reset them)
  for i in "${!IPS[@]}"; do
    ip=${IPS[$i]}
    if [ "$DRY" = 1 ]; then reg="managed_start_pfn 0x1890200
managed_pages 25095680"; ma=96000000
      lay="vdb-server: region device=/dev/dax0.0 swcc=[268435456,103060340736) reserved=0
backend=plain swcc_used_end=61975035904"
    else
      out=$($SSH comsys@$ip "echo mem_available_kb=\$(awk '/^MemAvailable:/{print \$2}' /proc/meminfo)" < /dev/null 2>&1); ma=${out#mem_available_kb=}
      reg=$($SSH comsys@$ip "cat /sys/kernel/swmc/destijl/registered" < /dev/null 2>&1)
      g=$($SSH comsys@$ip "ls -dt $DAMONX_V/runs/$NAME-*/ 2>/dev/null | head -n 1" < /dev/null 2>&1)
      lay=$($SSH comsys@$ip "grep -h -m 2 -E 'swcc=\[|swcc_used_end=' ${g%/}/node$i.log" < /dev/null 2>&1)
    fi
    echo "$(date -Is) $NAME hook-start $ip mem_available_kb=$ma pool=$DAMONX_POOL" >> "$DF"
    [[ $ma =~ ^[0-9]+$ ]] && [ $(( DAMONX_POOL + 4294967296 )) -le $(( ma * 1024 )) ] || { say "STOP: $ip pool $DAMONX_POOL + 4 GiB > MemAvailable ($ma kB)"; return 1; }
    sp=$(echo "$reg" | sed -n 's/^.*managed_start_pfn \(0x[0-9a-f]*\).*$/\1/p' | head -n 1) np=$(echo "$reg" | sed -n 's/^.*managed_pages \([0-9]*\).*$/\1/p' | head -n 1)
    echo "$(date -Is) $NAME registered $ip: $(echo $reg)" >> "$DF"
    [ -n "$sp" ] && [ -n "$np" ] && [ "$np" -gt 0 ] || { say "STOP: $ip registered unreadable"; return 1; }
    s=$(( sp * 4096 )) e=$(( (sp + np) * 4096 ))
    if [ "$DAMONX_RANGE" = index ]; then  # DESIGN §1: index extent = [managed_start, managed_start + swcc_used_end - swcc_offset)
      off=$(echo "$lay" | sed -n 's/.* swcc=\[\([0-9]*\),.*/\1/p' | head -n 1) ue=$(echo "$lay" | sed -n 's/.*swcc_used_end=\([0-9]*\).*/\1/p' | head -n 1)
      echo "$(date -Is) $NAME layout $ip node$i: swcc_offset=${off:-?} swcc_used_end=${ue:-?}" >> "$DF"
      [[ $off =~ ^[0-9]+$ ]] && [[ $ue =~ ^[0-9]+$ ]] && [ "$ue" -gt "$off" ] || { say "STOP: $ip node$i layout line unreadable (swcc / swcc_used_end)"; return 1; }
      k=$(( s + ue - off ))
      [ "$k" -le "$e" ] || { say "STOP: $ip index extent end $k > managed end $e"; return 1; }
      e=$k
    fi
    out=$(guest $ip start $s $e ${DAMONX_ARGS} ${DAMONX_START_EXTRA:-}$act)
    echo "$(date -Is) $NAME start $ip: $out" >> "$DF"
    [[ $out == "DAMON ON "* ]] || { [ "$DRY" = 1 ] && [[ $out == *$'\n'"DAMON ON "* ]]; } || { say "STOP: start on $ip: $out"; return 1; }
    say "kdamond on $ip range $s-$e ($(( (e - s) >> 20 )) MiB, $DAMONX_RANGE)"
  done
  sput started "$(date +%s)"; return 0
}
warm_rows() {  # per-VM samples of the block's sampler since <epoch>: "epoch create applied_pages pages pool"
  local ip=$1 since=$2 ts rest t
  grep " $NAME run $ip: DAMON STATS " "$DF" 2>/dev/null | while read -r ts rest; do
    t=$(date -d "$ts" +%s 2>/dev/null) || continue; [ "$t" -ge "$since" ] || continue
    echo "$t $(echo "$rest" | sed -n 's/.* replica_create=\([0-9]*\).*/\1/p') $(( $(echo "$rest" | sed -n 's/.* sz_applied=\([0-9]*\).*/\1/p' | grep . || echo 0) / 4096 )) $(echo "$rest" | sed -n 's/.* replica_pages=\([0-9]*\).*/\1/p') $(echo "$rest" | sed -n 's/.* replica_pool_max_bytes=\([0-9]*\).*/\1/p')"
  done
}
end_check() {  # 0 = DESIGN §5 end condition met on every VM (prints the per-VM last rates)
  local pb=$1 epps=$2 en=$3 ip rates ok=0
  for ip in "${IPS[@]}"; do
    rates=$(warm_rows "$ip" "$pb" | awk -v n="$en" '$2 != "" { if (pt != "" && $1 > pt) r[++k] = ($2 - pc) / ($1 - pt); pt = $1; pc = $2 }
      END { if (k < n) { print "-"; exit } s = ""; for (i = k - n + 1; i <= k; i++) s = s sprintf("%.0f,", r[i]); print s }')
    echo -n "$ip=[${rates%,}] "
    [ "$rates" != - ] || { ok=1; continue; }
    echo "${rates%,}" | tr ',' '\n' | awk -v m="$epps" '$1 >= m { bad = 1 } END { exit bad }' || ok=1
  done
  return $ok
}
warm_end() {  # <reason>: steady-state quotas, summary + csv
  local reason=$1 pa pb t ip
  [ -z "$(sget ended)" ] || return 0
  t=$(date +%s); pa=$(sget phaseA) pb=$(sget phaseB)
  commit_all steady replicate "${DA[6]}" "${DA[7]}" "${DA[8]}" || return 1
  sput ended "$t $reason"
  { echo "# damonx warmup of $NAME (DESIGN §5; exploratory, not a reported result)"
    echo "warm_spec=[$WARM] start_extra=[${DAMONX_START_EXTRA:-}] range=$DAMONX_RANGE steady_quota_ms=${DA[6]} steady_quota_bytes=${DA[7]} reset_ms=${DA[8]}"
    echo "started=$(sget started) phaseA=$pa phaseB=${pb:--} ended=$t phaseA_s=$(( ${pb:-$t} - ${pa:-$t} )) phaseB_s=$(( pb ? t - pb : 0 )) reason=$reason"
    echo "end_rates_last_${WEN}: $(end_check "${pb:-$t}" "$WEPPS" "$WEN")"
    [ "$reason" != timeout ] || echo "WARMUP_TIMEOUT: phase B reached max_parts x part_s without the end condition (cell flagged; run continues)"
  } > "$E/damonx-warmup-$NAME.txt"
  { echo "t_epoch,vm,phase,replica_pages,create_per_s,applied_pages_per_s,pool_fill_pct"
    for ip in "${IPS[@]}"; do
      warm_rows "$ip" "${pa:-0}" | awk -v ip="$ip" -v pb="${pb:-0}" -v te="$t" '$2 != "" { ph = (pb > 0 && $1 >= pb) ? "B" : "A"; if ($1 > te) ph = "steady"
        cr = (pt != "" && $1 > pt) ? sprintf("%.1f", ($2 - pc) / ($1 - pt)) : ""; ar = (pt != "" && $1 > pt) ? sprintf("%.1f", ($3 - pa) / ($1 - pt)) : ""
        fill = ($5 > 0) ? sprintf("%.2f", 100 * $4 * 4096 / $5) : ""
        print $1 "," ip "," ph "," $4 "," cr "," ar "," fill; pt = $1; pc = $2; pa = $3 }'
    done; } > "$E/damonx-warmup-$NAME.csv"
  say "warmup end ($reason): $(sed -n 3p "$E/damonx-warmup-$NAME.txt")"
}
if [ -n "$WARM" ]; then
  WR=$(wv rate) WLS=$(wv learn_s) WPS=$(wv part_s) WMP=$(wv max_parts) WMF=$(wv min_fill_s) WEPPS=$(wv end_pps) WEN=$(wv end_n) WFMS=$(wv fill_ms) WFB=$(wv fill_bytes)
  for x in "$WR" "$WLS" "$WPS" "$WMP" "$WMF" "$WEPPS" "$WEN" "$WFMS" "$WFB"; do [[ $x =~ ^[0-9]+$ ]] || { echo "HOOK FAIL: bad DAMONX_WARM [$WARM]"; exit 2; }; done
fi
case $PH in
  pre)
    if [ -n "$FK" ]; then bash "$EV/fixed-part-hook.sh" pre "$FK" "$PART" || exit 1; fi
    if [ -z "$(sget started)" ]; then start_all || exit 1; [ -z "$WARM" ] || sput phaseA "$(date +%s)"; fi
    if [ -n "$WARM" ]; then
      case $PART in
        wb01) commit_all fill replicate "$WFMS" "$WFB" 1000 || exit 1; sput phaseB "$(date +%s)";;
        slo) [ -n "$(sget ended)" ] || warm_end timeout || exit 1;;
      esac
    fi
    exit 0;;
  post)
    if [ -n "$FK" ]; then bash "$EV/fixed-part-hook.sh" post "$FK" "$PART" || exit 1; fi
    exit 0;;
  skip)
    [ -n "$WARM" ] && [[ $PART =~ ^wb[0-9][0-9]$ ]] || exit 1
    [ -z "$(sget ended)" ] || { say "skipped (warmup ended: $(sget ended))"; exit 0; }
    pb=$(sget phaseB); [ -n "$pb" ] || exit 1
    el=$(( $(date +%s) - pb ))
    [ "$el" -ge "$WMF" ] || { say "run (phase B ${el}s < min_fill_s $WMF)"; exit 1; }
    if r=$(end_check "$pb" "$WEPPS" "$WEN"); then
      say "end condition met after phase B ${el}s: $r"; warm_end condition || exit 2; exit 0
    fi
    say "run (phase B ${el}s; last rates $r)"; exit 1;;
  *) echo "HOOK FAIL: phase $PH"; exit 2;;
esac

#!/bin/bash
# T-specific Ekko calibration (H1 v0.6.10; generalises builds/recsys-calib/1, H1 v0.6.9): for every Ekko point,
#   1. the T = 60 s reference: recsys-rate --frac F60 --t-ms 60000 --windows 20 -> rate-frac<F60>.txt = the update
#      SAMPLE RATE R of the point (loadgen --fixed update=R; main-block.sh rate_for). avg/peak: must equal
#      builds/recsys-inputs/1/rate-frac<F60>.txt byte for byte (note lines excluded) and are not copied; the
#      v0.6.10 points (f087, f149, f253) are written to the output dir (main-block.sh EKKO_REF = RATE_T_DIR).
#   2. the T = TMS calibration: integer rows_per_round_target t at --t-ms TMS (1200 windows for TMS = 1000, the same
#      trace span as 20 x 60 s) whose recsys-rate rate_samples_per_s is closest to R (bisection; bisect-T<TMS>-<p>.log),
#      written as rate-T<TMS>-<p>.txt = recsys-rate output + the fields main-block.sh reads (ekko, publish_frac_arg =
#      t / total_rows, ref_*) in the calib/1 format. avg/peak must reproduce builds/recsys-calib/1 byte for byte.
#   The rate is the point's sample rate at T = 60 s, replayed unchanged at T; only the round length changes.
# Host compute only (no server, no CXL), node1-pinned, nice 19; refuses to start and stops (rc 3, "PAUSED") whenever
# workspaces/MEASUREMENT.lock exists, checked before every recsys-rate call; a rerun with the same work dir continues
# (finished points are kept).
# usage: calib-t.sh <work dir> <TMS> <point> [<point> ...]     points: avg peak f087 f149 f253 f330
#   env RATE (recsys-rate binary, default builds/recsys/12/bin/recsys-rate), D (builds/recsys-inputs/1),
#   CALIB_DIR (the dir the files will be published in, for ref_file; default builds/recsys-calib/2)
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
W=${1:?work dir} TMS=${2:?t_ms}; shift 2
[ $# -gt 0 ] || { echo "usage: calib-t.sh <work dir> <TMS> <point>..."; exit 2; }
RATE=${RATE:-$P/builds/recsys/12/bin/recsys-rate} D=${D:-$P/builds/recsys-inputs/1} CD=${CALIB_DIR:-builds/recsys-calib/2}
S=$D/updates-day23-0-2M.smp TOT=134184588 LOCK=$P/workspaces/MEASUREMENT.lock
WIN=$(( 20 * 60000 / TMS ))
mkdir -p "$W" || exit 2
W=$(readlink -f "$W"); cd $P || exit 2   # recsys-rate records --samples as given: relative to $P, as in calib/1
lockchk() { [ ! -e "$LOCK" ] || { echo "PAUSED: $LOCK exists ($(head -1 "$LOCK" 2>/dev/null))"; exit 3; }; }
frac60() { case $1 in avg) echo 0.000513333333;; peak) echo 0.0043;; f087) echo 0.000874;; f149) echo 0.00149;; f253) echo 0.00253;; f330) echo 0.0033;; *) return 1;; esac; }
rr() {  # <frac> <t_ms> <windows> <out>
  lockchk
  nice -n 19 numactl --cpunodebind=1 --membind=1 "$RATE" --samples "${S#$P/}" --frac "$1" --t-ms "$2" --windows "$3" > "$4" \
    || { echo "recsys-rate failed ($*)"; exit 1; }
}
kv() { sed -n "s/^$2=//p" "$1" | head -1; }
point() {
  local p=$1 F R ref t60 lo hi rl rh m rmid best t
  F=$(frac60 "$p") || { echo "$p: unknown point"; return 1; }
  # 1. T = 60 s reference
  t60=$W/rate-frac$F.txt
  if [ ! -s "$t60" ]; then rr "$F" 60000 20 "$t60.tmp" && mv "$t60.tmp" "$t60"; fi
  case $p in
    avg|peak) ref=$D/rate-frac$F.txt
      diff <(grep -v '^note' "$ref") "$t60" > /dev/null || { echo "$p: T = 60 s reference differs from $ref"; return 1; }
      ref=${ref#$P/};;
    *) ref=$CD/rate-frac$F.txt;;
  esac
  R=$(kv "$t60" rate_samples_per_s)
  out=$W/rate-T$TMS-$p.txt
  [ -s "$out" ] && { echo "$p: done ($out)"; return 0; }
  # 2. bisection at TMS (bracket from the T = 1 s / T = 60 s target ratio of avg/peak, 1.78-2.0x; checked, else wide)
  local log=$W/bisect-T$TMS-$p.log
  rate_t() { rr "$(python3 -c "print(repr($1/$TOT))")" "$TMS" "$WIN" "$W/$p.t$1"; kv "$W/$p.t$1" rate_samples_per_s; }
  t=$(kv "$t60" rows_per_round_target)
  lo=$(python3 -c "print(max(1, int($t * $TMS / 60000 * 1.5)))") hi=$(python3 -c "print(int($t * $TMS / 60000 * 2.3) + 1)")
  rl=$(rate_t $lo) rh=$(rate_t $hi)
  if ! awk -v a=$rl -v b=$rh -v r=$R 'BEGIN{exit !(a <= r && b > r)}'; then
    echo "narrow bracket [$lo,$hi] rates $rl $rh does not hold R=$R: wide bracket" >> "$log"
    lo=1 hi=$(python3 -c "print(int($R*$TMS/1000*214))"); rl=$(rate_t $lo) rh=$(rate_t $hi)
    awk -v a=$rl -v b=$rh -v r=$R 'BEGIN{exit !(a <= r && b > r)}' || { echo "$p: bracket fail $rl $rh"; return 1; }
  fi
  echo "bracket lo=$lo rate=$rl hi=$hi rate=$rh R=$R" >> "$log"
  while [ $((hi - lo)) -gt 1 ]; do
    m=$(( (lo + hi) / 2 )); rmid=$(rate_t $m)
    if awk -v a=$rmid -v r=$R 'BEGIN{exit !(a <= r)}'; then lo=$m rl=$rmid; else hi=$m rh=$rmid; fi
    echo "t=$m rate=$rmid" >> "$log"
  done
  best=$(awk -v l=$lo -v h=$hi -v a=$rl -v b=$rh -v r=$R 'BEGIN{print ((r-a) <= (b-r)) ? l : h}')
  echo "lo=$lo rate=$rl hi=$hi rate=$rh R=$R best=$best" >> "$log"
  local name rule
  case $p in
    avg) name="Ekko avg";; peak) name="Ekko peak";;
    f330) name="Ekko point f330 (geometric mean of f253 and peak, $F of rows per 60 s; user 2026-10-18)";;
    *) name="Ekko point $p (geometric between avg and peak, $F of rows per 60 s; user 2026-10-18)";;
  esac
  python3 -I - "$W/$p.t$best" "$t60" "$ref" "$P/$ref" "$p" "$name" "$TOT" > "$out.tmp" <<'EOF' || { echo "$p: compose failed"; return 1; }
import hashlib, sys
raw, t60, ref, refabs, p, name, tot = sys.argv[1:]
kv = lambda f: dict(l.rstrip("\n").split("=", 1) for l in open(f) if "=" in l)
a, r = kv(raw), kv(t60)
t, tms = int(a["rows_per_round_target"]), float(a["t_ms"])
rate, rref = float(a["rate_samples_per_s"]), float(r["rate_samples_per_s"])
src = refabs if p in ("avg", "peak") else t60
sys.stdout.write(open(raw).read())
print(f"ekko={p}")
print(f"publish_frac_arg={t / int(tot)!r}")
print(f"ref_t_ms={int(float(r['t_ms']))}")
print(f"ref_frac={r['frac']}")
print(f"ref_rows_per_round_target={r['rows_per_round_target']}")
print(f"ref_rate_samples_per_s={r['rate_samples_per_s']}")
print(f"ref_file={ref} sha256={hashlib.sha256(open(src, 'rb').read()).hexdigest()}")
print(f"rate_vs_ref_pct={(rate / rref - 1) * 100:.4f}")
per60 = int(round(t * 60000 / tms))
print(f"rows_per_60s_at_this_T={per60} vs_ref_round={per60 / int(r['rows_per_round_target']):.3f}x")
print(f"definition=H1 v0.6.9 (user 2026-10-18 T = 1 s): {name} = the update SAMPLE RATE calibrated at T = 60 s (ref_*), "
      f"replayed unchanged; this file = recsys-rate (builds/recsys/12, sha256 9ba94ba5...) at t_ms over {a['windows']} windows "
      f"(same trace span as the 20 x 60 s reference), rows_per_round_target = the integer target whose rate_samples_per_s is "
      f"closest to ref_rate_samples_per_s (bisection, bisect.log); publish_frac_arg = rows_per_round_target / total_rows "
      f"for recsys-server --publish-frac")
EOF
  mv "$out.tmp" "$out" && rm -f "$W/$p".t*
  echo "$p: t=$best rate=$(kv "$out" rate_samples_per_s) R=$R -> $out"
}
lockchk
rc=0
for p in "$@"; do ( point "$p" ) > "$W/run-$p.log" 2>&1 & done
for j in $(jobs -p); do wait $j || rc=$?; done
cat "$W"/run-*.log
grep -q '^PAUSED' "$W"/run-*.log && exit 3
exit $rc

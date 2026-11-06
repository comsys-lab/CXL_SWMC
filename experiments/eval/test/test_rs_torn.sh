#!/bin/bash
# Host test of the RecSys torn-row policy (user decision 2026-11-07, option a): experiments/recsys/torn_rows.py (allow /
# window / steps / lifetime / block), session.sh start (policy refusal) and stop (final check; SESSION_LOCAL=1 on a
# fake stopped session, no server, no VM), rs_check.py torn INFO / FAIL lines, main-block.sh policy hand-off (static).
# Allowed: De Stijl T > 0 with replica_mode on. Not allowed: hw, pop, mg (no token), ds T = 0, ds replica_mode off.
# usage: bash test_rs_torn.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
TR=$ROOT/experiments/recsys/torn_rows.py SES=$ROOT/experiments/recsys/session.sh RSC=$ROOT/experiments/eval/rs_check.py
TD=$(mktemp -d /tmp/rs-torn-test-XXXXXX)
[ -n "${KEEP:-}" ] && echo "KEEP: $TD" || trap 'rm -rf "$TD"' EXIT
fail() { echo "RS TORN TEST FAIL: $*"; exit 1; }
N=0
rc_is() {  # <want rc> <what> <command...>
  local want=$1 what=$2 rc; shift 2
  "$@" > "$TD/out" 2>&1; rc=$?
  [ "$rc" = "$want" ] || fail "$what: rc $rc (want $want): $(tail -2 "$TD/out" | tr '\n' ' ')"
  N=$((N + 1)); }
DSENV="ENV:XTIMEOUT=7200 ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=1000000"
allow() { python3 -I -B "$TR" allow --system "$1" --node-env "$2" --policy "$3"; }
# ---- 1. policy decision
rc_is 0 "ds T 1000 ms replica all" allow DeStijl-adaptive-T1000000 "$DSENV" "system=ds T_us=1000000 replica_mode=all"
grep -q "^TORN POLICY allowed (system=ds T_us=1000000 replica_mode=all)" "$TD/out" || fail "allowed text"
rc_is 1 "ds T 0 replica all" allow DeStijl-adaptive-T0 "ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=0" "system=ds T_us=0 replica_mode=all"
rc_is 1 "ds T 1000 ms replica off" allow DeStijl-adaptive-T1000000 "$DSENV" "system=ds T_us=1000000 replica_mode=off"
rc_is 1 "hw (no token)" allow all-HWcc "ENV:XTIMEOUT=7200" ""
rc_is 1 "pop (no token)" allow Popcorn-adaptive "ENV:XTIMEOUT=7200" ""
rc_is 2 "pop label with a ds token" allow Popcorn-adaptive "$DSENV" "system=ds T_us=1000000 replica_mode=all"
rc_is 2 "hw label with a ds token" allow all-HWcc "$DSENV" "system=ds T_us=1000000 replica_mode=all"
rc_is 2 "token T differs from the label" allow DeStijl-adaptive-T10000 "$DSENV" "system=ds T_us=1000000 replica_mode=all"
rc_is 2 "NODE_ENV without the T" allow DeStijl-adaptive-T1000000 "ENV:CXL_SYSTEM=ds" "system=ds T_us=1000000 replica_mode=all"
rc_is 2 "bad token" allow DeStijl-adaptive-T1000000 "$DSENV" "T_us=1000000"
python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import torn_rows as T
assert T.allowed('ds', 1000000, 'all') and T.allowed('ds', 100000, 'all')
assert not T.allowed('ds', 0, 'all') and not T.allowed('ds', 1000000, 'off')
assert not T.allowed('hw', 1000000, 'all') and not T.allowed('pop', 1000000, 'all') and not T.allowed('mg', 5, 'all')" \
  "$ROOT/experiments/recsys" || fail "allowed() rule"
# ---- 2. measurement window
snap() {  # <file> <torn> <lookups> [misses]
  printf '# when=x\nnode=1\nqueries=5\nlookups=%s\nmisses=%s\ntorn_rows=%s\nupdate_misses=0\nbad_requests=0\n' "$3" "${4:-0}" "$2" > "$1"; }
mkm() {  # <dir> <node1 torn delta> [node1 misses delta]
  mkdir -p "$1"; snap "$1/pre-t0.txt" 0 0; snap "$1/post-t0.txt" 0 0
  snap "$1/pre-t1.txt" 100 1000000; snap "$1/post-t1.txt" $((100 + $2)) 4124400 "${3:-0}"; }
TOK="system=ds T_us=1000000 replica_mode=all"
mkm "$TD/w1" 4552
rc_is 0 "window: torn allowed" python3 -I -B "$TR" window "$TD/w1" --nodes 2 --allow "$TOK"
grep -qx "node1 torn_rows_delta=4552 allowed" "$TD/w1/invariants.txt" || fail "allowed tag"
grep -qx "total torn_rows=4552 lookups=3124400 torn_frac=0.00145692" "$TD/w1/torn.txt" || fail "torn.txt total: $(cat "$TD/w1/torn.txt")"
grep -qx "policy=allowed ($TOK)" "$TD/w1/torn.txt" || fail "torn.txt policy"
mkm "$TD/w2" 4552
rc_is 4 "window: torn, zero policy" python3 -I -B "$TR" window "$TD/w2" --nodes 2 --allow ""
grep -qx "node1 torn_rows_delta=4552" "$TD/w2/invariants.txt" || fail "zero: untagged delta"
grep -q "INVARIANT VIOLATED" "$TD/out" || fail "zero: violation text"
mkm "$TD/w3" 10 3
rc_is 4 "window: torn allowed but misses" python3 -I -B "$TR" window "$TD/w3" --nodes 2 --allow "$TOK"
mkm "$TD/w4" 0
rc_is 0 "window: no torn, zero policy" python3 -I -B "$TR" window "$TD/w4" --nodes 2 --allow ""
mkm "$TD/w5" 0; grep -v '^bad_requests=' "$TD/w5/post-t1.txt" > "$TD/x" && mv "$TD/x" "$TD/w5/post-t1.txt"
rc_is 5 "window: missing key" python3 -I -B "$TR" window "$TD/w5" --nodes 2 --allow "$TOK"
grep -q "^STATS MISSING bad_requests in $TD/w5/post-t1.txt" "$TD/out" || fail "missing text"
# per step (stats-steps.csv as stats_delta.py writes it: one row per step and target)
printf 'step,phase,offered_x,target,addr,lookups,torn_rows\n0,warmup,1,1,a,500,1\n1,fixed,1,0,a,0,0\n1,fixed,1,1,b,2000000,3000\n2,fixed,1,1,b,1000000,0\n' > "$TD/w1/stats-steps.csv"
rc_is 0 "steps" python3 -I -B "$TR" steps "$TD/w1"
grep -qx "1,fixed,1,3000,2000000,0.0015" "$TD/w1/torn-steps.csv" || fail "torn-steps.csv: $(cat "$TD/w1/torn-steps.csv")"
python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import torn_rows as T
t, n, f = T.part_torn(sys.argv[2]); assert (t, n) == (3000, 3000000) and abs(f - 1e-3) < 1e-15, (t, n, f)" \
  "$ROOT/experiments/recsys" "$TD/w1" || fail "part_torn (measured steps, warm-up excluded)"
# ---- 3. session.sh start refuses an inconsistent token before creating the session dir
rc_is 2 "start: pop label with a ds token" env SESSION_LOCAL=1 SYSTEM=Popcorn-adaptive V=/nonexistent HOST_SERVER=/bin/false \
  SERVER_ARGS=--x T_MS=0 "NODE_ENV=$DSENV" "TORN_POLICY=$TOK" bash "$SES" start "$TD/s-bad"
[ ! -e "$TD/s-bad" ] || fail "start created the session dir before refusing"
# ---- 4. session.sh stop: final checks on a stopped fake session (SESSION_LOCAL=1, no pid file = no server)
mks() {  # <session dir> <TORN_ALLOW_S> <node1 torn_rows>
  local S=$1 G=$1.guest k
  mkdir -p "$S" "$G" "$S.v/bin"
  printf '#!/bin/bash\nexit 0\n' > "$S.v/bin/recsys-node.sh"; chmod +x "$S.v/bin/recsys-node.sh"   # fake guest stop
  touch "$G/node0.pid" "$G/node1.pid"
  { echo "SYSTEM='DeStijl-adaptive-T1000000'"; echo "V='$S.v'"; echo "GRUN='$G'"; echo "NODES_S='127.0.0.1 127.0.0.1'"
    echo "PORTS_S='1 2'"; echo "LOCAL='1'"; echo "TORN_ALLOW_S='$2'"; } > "$S/session.env"
  echo "system=x" > "$S/session-manifest.txt"
  for k in 0 1; do
    printf 'recsys-server: stopping\nnode=%s\nqueries=9\nlookups=%s\nmisses=0\ntorn_rows=%s\nbad_requests=0\nupdate_misses=0\n' \
      $k $((k * 5000000)) $([ $k = 1 ] && echo "$3" || echo 0) > "$G/node$k.log"
  done; }
mks "$TD/b/ds-u200-auc" "$TOK" 7000
rc_is 0 "stop: torn allowed" env SESSION_LOCAL=1 bash "$SES" stop "$TD/b/ds-u200-auc"
grep -qx "total torn_rows=7000 lookups=5000000 torn_frac=0.0014" "$TD/b/ds-u200-auc/torn-lifetime.txt" || fail "torn-lifetime.txt: $(cat "$TD/b/ds-u200-auc/torn-lifetime.txt")"
grep -q "^torn rows allowed ($TOK): total torn_rows=7000" "$TD/b/ds-u200-auc/final-check.txt" || fail "final-check allowed line"
mks "$TD/b/hw-u200-auc" "" 7000
rc_is 4 "stop: torn, zero policy" env SESSION_LOCAL=1 bash "$SES" stop "$TD/b/hw-u200-auc"
grep -q "node1: torn_rows=0 violated" "$TD/b/hw-u200-auc/final-check.txt" || fail "zero: final-check violation"
mks "$TD/c/ds-u200-auc" "$TOK" 0
rc_is 0 "stop: allowed, no torn" env SESSION_LOCAL=1 bash "$SES" stop "$TD/c/ds-u200-auc"
# ---- 5. rs_check.py: INFO for the allowed lifetime, FAIL for torn rows under the zero policy
mkdir -p "$TD/b/ds-u200-auc/auc"; cp "$TD/w1/stats-steps.csv" "$TD/b/ds-u200-auc/auc/"; echo name=auc > "$TD/b/ds-u200-auc/auc/manifest.txt"
echo "SEQUENCE DONE" > "$TD/b/sequence.log"; echo "SEQUENCE DONE" > "$TD/c/sequence.log"
rc_is 1 "rs_check: zero-policy lifetime with torn rows" python3 -I -B "$RSC" "$TD/b" --rates 200
grep -q "^INFO torn rows ds-u200-auc: policy allowed, torn_rows 7000 / serving lookups 5000000 = torn_frac 0.0014" "$TD/b/rs-check.txt" || fail "rs_check INFO line"
grep -q "^FAIL torn rows hw-u200-auc: policy zero, torn_rows 7000 .* zero-torn invariant" "$TD/b/rs-check.txt" || fail "rs_check FAIL line"
grep -q "^ds-u200-auc,allowed,auc,measured,,,3000,3000000,0.001$" "$TD/b/torn-rows.csv" || fail "torn-rows.csv measured row: $(cat "$TD/b/torn-rows.csv")"
grep -q "^ds-u200-auc,allowed,,lifetime,,,7000,5000000,0.0014$" "$TD/b/torn-rows.csv" || fail "torn-rows.csv lifetime row"
rc_is 0 "rs_check: allowed lifetime only" python3 -I -B "$RSC" "$TD/c" --rates 200
tail -1 "$TD/c/rs-check.txt" | grep -qx "RSCHECK PASS (0 failures, 0 warnings)" || fail "rs_check PASS line (INFO not counted)"
# ---- 6. main-block.sh: every ds lifetime hands its policy token to session.sh start (static)
grep -qF '"TORN_POLICY=system=ds T_us=$DST replica_mode=$REPL"' "$ROOT/experiments/recsys/main-block.sh" || fail "main-block TORN_POLICY"
[ "$(grep -c 'TORN_POLICY=' "$ROOT/experiments/recsys/main-block.sh")" = 1 ] || fail "TORN_POLICY outside the ds lifetime"
echo "RS TORN TEST PASS ($N cases: policy allowed for ds T > 0 replica on; zero for hw / pop / ds T 0 / ds replica off; window, steps, stop, rs_check)"

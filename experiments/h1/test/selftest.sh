#!/bin/bash
# Host self-test of the staged H1 orchestration (no VM, no SSH, no sudo, no shared memory). Writes only below <out dir>.
# Never run while a VM measurement holds workspaces/MEASUREMENT.lock (the coordinator says "Host free").
# usage: selftest.sh <out dir under workspaces/h1-main/ (must not exist)> [<real SLO run dirs root for case E>]
#   A  stages through the stub hook: r1-kv; r1-lmdb refused before acceptance; h1-accept.sh; r1-lmdb, r1-vdb,
#      r1-recsys (each accepted after its check PASS); r2 refused while an r1 is unaccepted (checked before the last
#      accept); r2 --workloads kv,vdb; r3 --workloads lmdb refused (no r2); r3 --workloads kv; collect-all-r<n> after
#      every stage (rounds_note single round / n rounds). Checks: every check.txt H1CHECK PASS; levels from r1 (weakest pop,
#      vdb u5 rate 42.105, kv integer 40/20); r2/r3 fixed windows at the r1 levels; collect-all slo-summary has 3
#      rounds per mix x system; fixed phase with 4 systems (mgoff = Megalon timers off); coherence CPU pop 0.4 /
#      mg, mgoff 0.2667 / hw 0; lock released after every stage
#   B  STUB_FAIL=note:mg:u50 in r1-kv: SEQUENCE STOP at levels ("note")
#   C  STUB_FAIL=rc in r1-kv: SEQUENCE STOP at the SLO hook
#   D  real plugin pins-vdb.sh with FILL_ tokens (not dry): HOOK STOP "unpinned" (skipped once fully pinned)
#   E  levels.py + collect.py on the real KV-main H1 v2 SLO runs (read-only; mix u5 only): weakest pop
#   F  h1-accept.sh refuses a check.txt with REPORT lines without --user-ack, accepts with it
#   G  check.compare(): synthetic Fig 2 CSVs r1 / r2: hw +3 % inside the threshold, pop +12 % -> REPORT, C_diff inside
#   H  stage-start integrity: a matching manifest passes; an altered hash, an unlisted experiments/h1 file or a wrong
#      H1_MANIFEST_SHA stop the stage before the lock
#   I  D1: H1_PLAN and gate threshold overrides refused without H1_DRY=1; D3: a real stage refuses pgid != pid and passes
#      the pgid check under setsid (it then stops at the real pretouch gate, which has a dummy dir; lock released)
#   J  r1 skip: r1-vdb refused after a stopped r1-lmdb, starts after h1-accept.sh --skip lmdb (logged); --skip refused
#      for an accepted stage, for r2 and twice; a skipped stage cannot be accepted; r2 / r3 with the skipped lmdb among
#      the chosen workloads refused (H1 v0.6.5)
#   L  r2 subset preconditions (H1 v0.6.5, user 2026-10-18: r2 = LMDB + vector DB while RecSys r1 is on hold): with
#      no recsys r1 at all, r2 --workloads vdb,lmdb runs (order lmdb, vdb); r2 (all four) and r2 --workloads
#      lmdb,recsys refused; an unaccepted chosen r1 (lmdb ran, not yet accepted) refused; r3 --workloads lmdb,vdb
#      refused with vdb r2 unaccepted, r3 --workloads kv refused (no r2), r3 --workloads lmdb runs
#   K  check.py W7 (knee bracket at the probe limit or rel_width > 5 %, weakest named; legacy runs without the field: no W7);
#      W4 names both rounds' confirm searches when one did not pass its first confirm (v0.6.5), legacy runs: no note
# Prints "SELFTEST PASS" or "SELFTEST FAIL <case>".
set -uo pipefail
O=${1:?out dir}
H=$(cd "$(dirname "$0")/.." && pwd)
case "$O" in */h1-main/*) ;; *) echo "SELFTEST FAIL out dir must be under workspaces/h1-main/"; exit 2;; esac
[ -e "$O" ] && { echo "SELFTEST FAIL $O exists"; exit 2; }
mkdir -p "$O"
export LOCK=$O/MEASUREMENT.lock H1_DRY=1 PYTHONDONTWRITEBYTECODE=1
fail() { echo "SELFTEST FAIL $*"; exit 1; }
nolock() { [ ! -e "$LOCK" ] || fail "$1: lock left behind"; }
stage() {  # case stage [args] -> rc of h1-main.sh
  local c=$1; shift
  bash $H/h1-main.sh "$1" "$O/$c" "${@:2}" >> "$O/$c.out" 2>&1; local rc=$?; nolock "$c $1"; return $rc
}
acc() { bash $H/h1-accept.sh "$O/A" "$1" "$2" selftest >> "$O/A.out" 2>&1 || fail "A accept r$1 $2"; }
# A
mkdir "$O/A"
stage A r1-kv || fail "A r1-kv (see $O/A.out)"
stage A r1-lmdb && fail "A r1-lmdb ran before r1-kv was accepted"
acc 1 kv
for w in lmdb vdb; do stage A r1-$w || fail "A r1-$w"; acc 1 $w; done
stage A r1-recsys || fail "A r1-recsys"
stage A r2 && fail "A r2 ran before r1-recsys was accepted"
acc 1 recsys
# r2 for a user-chosen subset (plan change 2026-10-18), r3 only where r2 is accepted
stage A r2 --workloads kv,vdb || fail "A r2 subset"
for w in kv vdb; do acc 2 $w; done
stage A r3 --workloads lmdb && fail "A r3 ran for lmdb without r2"
stage A r3 --workloads kv || fail "A r3 kv"
grep -q "STAGE DONE r3 \[kv\]" "$O/A/h1-state.txt" || fail "A no STAGE DONE r3 [kv]"
[ ! -e "$O/A/lmdb/r2" ] && [ ! -e "$O/A/recsys/r2" ] && [ ! -e "$O/A/vdb/r3" ] || fail "A ran rounds outside the subset"
python3 -I -B - "$O/A" <<'EOF' || fail "A content"
import csv, sys
o = sys.argv[1]
done = {"kv": (1, 2, 3), "lmdb": (1,), "vdb": (1, 2), "recsys": (1,)}
for w, rs in done.items():
    for n in rs:
        last = open(f"{o}/{w}/r{n}/check.txt").read().strip().splitlines()[-1]
        assert last.startswith("H1CHECK PASS"), (w, n, last)
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/vdb/levels.tsv"), delimiter="\t")}
assert lv["u5"]["weakest"] == "pop" and float(lv["u5"]["L1_x"]) == 40 and lv["u5"]["L1_rate"] == "42.105", lv["u5"]
kv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/kv/levels.tsv"), delimiter="\t")}
assert kv["u80"]["L1_rate"] == "40" and kv["u80"]["L2_rate"] == "20", kv["u80"]
for w, ncell in (("kv", 3), ("lmdb", 3), ("vdb", 3), ("recsys", 2)):
    for n in done[w]:
        fx = list(csv.DictReader(open(f"{o}/{w}/r{n}/collect/fix-steps.csv")))
        assert len(fx) == 8 * ncell, (w, n, len(fx))  # hw, pop, mg, mgoff x L1/L2
        want = {"hw": 0.0, "pop": 0.4, "mg": 0.2667, "mgoff": 0.2667}
        for r in fx:
            assert abs(float(r["coh_cpu_vcpus"]) - want[r["system"]]) < 1e-3, r
            lvr = {x["mix"]: x for x in csv.DictReader(open(f"{o}/{w}/levels.tsv"), delimiter="\t")}[r["mix"]]
            assert float(r["offered_x"]) == float(lvr[r["level"] + "_rate"]), (r, lvr)  # r1 levels reused
            want_life = "sep" if r["system"] == "mgoff" or (n == 1 and r["system"] in ("hw", "pop")) else "cont"
            assert r["lifetime"] == want_life, (r, want_life)
    for n in done[w]:  # collect-all after every stage: rounds 1..n
        ss = list(csv.DictReader(open(f"{o}/{w}/collect-all-r{n}/slo-summary.csv")))
        note = "single round (no variance)" if n == 1 else f"{n} rounds: mean and sample sd"
        assert len(ss) == 3 * ncell and all(r["rounds"] == str(n) and r["rounds_note"] == note for r in ss), ss[:1]
        sa = list(csv.DictReader(open(f"{o}/{w}/collect-all-r{n}/steps-all.csv")))
        assert len(sa) > 0 and sa[0]["label"].startswith(w + "/"), sa[:1]
print("A content OK")
EOF
# B
mkdir "$O/B"; STUB_FAIL=note:mg:u50 stage B r1-kv && fail "B rc 0"
grep -q "SEQUENCE STOP kv r1" "$O/B/h1-state.txt" && grep -q "LEVELS STOP .*note" "$O/B/kv/levels-u50.log" || fail "B stop reason"
[ ! -e "$O/B/kv/r1/run/mg-u50-r1/fix" ] || fail "B fixed windows ran after LEVELS STOP"
# C
mkdir "$O/C"; STUB_FAIL=rc stage C r1-kv && fail "C rc 0"
grep -q "SEQUENCE STOP kv r1" "$O/C/h1-state.txt" || fail "C stop reason"
# D
# D: a plugin that still has FILL_ tokens (pins-vdb.sh: loadgen 6 pins, 2026-10-18) is refused; skipped when none left
if grep -q FILL_ $H/plugins/pins-vdb.sh; then
  mkdir "$O/D"; H1_DRY=0 bash $H/hook.sh vdb r1 "$O/D" 1 "u5=U=5" > "$O/D.out" 2>&1 && fail "D rc 0"
  grep -q "HOOK STOP vdb r1 1: unpinned" "$O/D.out" || fail "D reason ($(cat "$O/D.out"))"
else echo "D skipped: no FILL_ left in pins-vdb.sh"; fi
# E (real data, read-only)
R=${2:-/home/comsys/sungsu/destijl-control/recovery/KV-main-h1-v2}
mkdir -p "$O/E/kv/slo-r1"
printf '# real KV-main H1 v2 runs (build 8, v5; read-only)\n' > "$O/E/kv/slo-r1/h1-runs.tsv"
for s in hw mg pop; do printf '%s\t%s\tu5\tslo\t1\t%s\n' "$s-u5-slo" "$s" "$R/$s-u5-slo" >> "$O/E/kv/slo-r1/h1-runs.tsv"; done
printf 'kv\tu5\tPUT_RATIO=0.05\t1\t0\tmixed:99:1\tYCSB B get 95 / put 5\n' > "$O/E/plan.tsv"
python3 -B $H/levels.py --plan "$O/E/plan.tsv" --workload kv --out "$O/E/kv/levels.tsv" "$O/E/kv/slo-r1" > "$O/E/levels.log" 2>&1 \
  || fail "E levels ($(tail -n 1 "$O/E/levels.log"))"
grep -q "^u5	pop	" "$O/E/kv/levels.tsv" || fail "E weakest"
nice -n 19 python3 -B $H/collect.py --plan "$O/E/plan.tsv" --workload kv "$O/E/kv" > "$O/E/collect.log" 2>&1 || fail "E collect"
grep -q "COLLECT OK" "$O/E/collect.log" || fail "E collect output"
echo "E: $(grep '^kv u5' "$O/E/levels.log")"
# F REPORT gating of h1-accept.sh
mkdir -p "$O/F/kv/r2"; printf 'REPORT C1 u5 L1/get hw T r1-sep vs r2-cont: test\nH1CHECK PASS kv r2: 0 FAIL, 0 WARN, 1 REPORT\n' > "$O/F/kv/r2/check.txt"
bash $H/h1-accept.sh "$O/F" 2 kv test > "$O/F.out" 2>&1 && fail "F accepted REPORT without --user-ack"
bash $H/h1-accept.sh "$O/F" 2 kv test --user-ack "TASKS.md test" >> "$O/F.out" 2>&1 || fail "F --user-ack refused"
grep -q "^user_ack=TASKS.md test" "$O/F/accept/r2-kv.txt" || fail "F record"
# G compare(): separate vs continuous thresholds on synthetic Fig 2 CSVs (hw +3 % = inside, pop +12 % = REPORT)
python3 -I -B - "$O/G" "$H" <<'PYEOF' || fail "G compare"
import os, sys
o, h = sys.argv[1], sys.argv[2]
sys.path.insert(0, h)
import check
hdr = "load,op,system,T_ns,C_ns,T_mg_on_ns,C_diff_ns\n"
def fig(n, hw, pop, mgon, cd):
    d = os.path.join(o, "kv", f"r{n}", "collect", "fig"); os.makedirs(d)
    open(os.path.join(d, "kv-u5-fig2.csv"), "w").write("# megalon_c: test\n" + hdr +
        f"L1,get,All HWcc,{hw},0,,\nL1,get,Popcorn,{pop},1,,\nL1,get,Megalon (timers off),{hw + cd},{cd},{mgon},{cd}\n")
fig(1, 1000, 2000, 1500, 300)
fig(2, 1030, 2240, 1515, 310)
check.compare("kv", 2, o, ["u5"], False)
rep = [l for l in check.lines if l.startswith("REPORT")]
assert len(rep) == 1 and " pop " in rep[0], check.lines
assert any(l.startswith("OK") and " hw " in l for l in check.lines), check.lines
assert any(l.startswith("OK") and "C_diff" in l for l in check.lines), check.lines
print("G OK")
PYEOF
# H stage-start code integrity (verifier MED-3): matching manifest passes; a changed hash or an unlisted file stops
R=$(cd "$H/../.." && pwd)
(cd "$R" && sha256sum $(bash $H/freeze-manifest.sh --list)) > "$O/H-good.sha256" || fail "H list"
sed '1s/^\(.\)/0\1/; 1s/^\(.\{64\}\)./\1/' "$O/H-good.sha256" > "$O/H-bad.sha256"   # first hash altered
grep -v "experiments/h1/levels.py$" "$O/H-good.sha256" > "$O/H-short.sha256"
for c in good bad short; do mkdir "$O/H-$c"; H1_MANIFEST="$O/H-$c.sha256" H1_MANIFEST_SHA=$(sha256sum < "$O/H-$c.sha256" | cut -c1-64) stage H-$c r1-kv; echo "rc=$?" >> "$O/H-$c.out"; done
grep -q "^rc=0" "$O/H-good.out" || fail "H good manifest refused ($(head -3 "$O/H-good.out"))"
grep -q "SEQUENCE STOP (start): code differs from the frozen manifest" "$O/H-bad.out" || fail "H bad hash not refused"
grep -q "SEQUENCE STOP (start): files in experiments/h1 not in the manifest: experiments/h1/levels.py" "$O/H-short.out" || fail "H unlisted file not refused"
mkdir "$O/H-sha"; H1_MANIFEST="$O/H-good.sha256" H1_MANIFEST_SHA=0000 stage H-sha r1-kv && fail "H wrong manifest sha accepted"
echo "H OK"
# I verifier D1/D3: overrides refused outside H1_DRY; a real stage needs pgid == pid (setsid)
mkdir "$O/I1" "$O/I2" "$O/I3"
H1_DRY=0 H1_PLAN=$H/h1-plan.tsv bash $H/h1-main.sh r1-kv "$O/I1" > "$O/I1.out" 2>&1 && fail "I1 rc 0"
grep -q "H1_PLAN override refused" "$O/I1.out" || fail "I1 reason ($(cat "$O/I1.out"))"
(unset H1_DRY; MEASURE_PART_DIR=x MEAS_AVG_MAX=50 bash $H/h1-gate.sh judge "$O/I-gate.log") > /dev/null 2>&1 && fail "I gate override accepted"
grep -q "override of MEAS_AVG_MAX refused" "$O/I-gate.log" || fail "I gate reason"
REAL=(H1_DRY=0 PRETOUCH_DIR=$O/none MEASURE_ENV_DIR=$O/none MEASURE_PART_DIR=$O/none H1_MANIFEST="$O/H-good.sha256"
      H1_MANIFEST_SHA=$(sha256sum < "$O/H-good.sha256" | cut -c1-64))
env "${REAL[@]}" bash $H/h1-main.sh r1-kv "$O/I2" > "$O/I2.out" 2>&1 && fail "I2 rc 0"
grep -q "SEQUENCE STOP: pgid .* != pid" "$O/I2.out" || fail "I2 reason ($(cat "$O/I2.out"))"
env "${REAL[@]}" setsid bash $H/h1-main.sh r1-kv "$O/I3" > "$O/I3.out" 2>&1 < /dev/null && fail "I3 rc 0"
grep -q "SEQUENCE STOP: pgid" "$O/I3.out" && fail "I3 setsid still refused on pgid"
grep -q "SEQUENCE STOP pretouch gate" "$O/I3/h1-state.txt" || fail "I3 did not reach the gates ($(cat "$O/I3.out"))"
nolock I3
echo "I OK"
# J r1 skip (user decision 2026-10-18: overnight runs never sit idle): r1-lmdb stops; r1-vdb is refused without a
#   record; h1-accept.sh --skip lmdb lets r1-vdb start (logged); --skip refused for an accepted stage, for r2 and twice;
#   a skipped stage cannot be accepted; r2 still refuses (strict: all four r1 accepted)
mkdir "$O/J"
stage J r1-kv || fail "J r1-kv"
bash $H/h1-accept.sh "$O/J" 1 kv selftest >> "$O/J.out" 2>&1 || fail "J accept kv"
STUB_FAIL=rc stage J r1-lmdb && fail "J r1-lmdb rc 0"
stage J r1-vdb && fail "J r1-vdb ran without lmdb accepted or skipped"
grep -q "r1-lmdb not checked PASS + accepted (nor skipped)" "$O/J.out" || fail "J refusal reason"
bash $H/h1-accept.sh "$O/J" 1 kv --skip "selftest" >> "$O/J.out" 2>&1 && fail "J skip of an accepted stage"
bash $H/h1-accept.sh "$O/J" 2 lmdb --skip "selftest" >> "$O/J.out" 2>&1 && fail "J skip of r2"
bash $H/h1-accept.sh "$O/J" 1 lmdb --skip "selftest: injected STOP" >> "$O/J.out" 2>&1 || fail "J skip lmdb"
S=$O/J/accept/r1-lmdb-skip.txt
[ -f "$S" ] && [ ! -e "$O/J/accept/r1-lmdb.txt" ] && grep -q "^reason=selftest: injected STOP$" "$S" \
  && grep -q "^check_sha256=none$" "$S" && grep -q "^stage_log=" "$S" || fail "J skip record ($(cat "$S" 2>/dev/null))"
bash $H/h1-accept.sh "$O/J" 1 lmdb --skip "again" >> "$O/J.out" 2>&1 && fail "J second skip"
bash $H/h1-accept.sh "$O/J" 1 lmdb selftest >> "$O/J.out" 2>&1 && fail "J accept after skip"
stage J r1-vdb || fail "J r1-vdb with lmdb skipped (see $O/J.out)"
grep -q "previous stage lmdb SKIPPED (not accepted): selftest: injected STOP" "$O/J/h1-state.txt" || fail "J skip not logged"
bash $H/h1-accept.sh "$O/J" 1 vdb selftest >> "$O/J.out" 2>&1 || fail "J accept vdb"
stage J r1-recsys || fail "J r1-recsys"
bash $H/h1-accept.sh "$O/J" 1 recsys selftest >> "$O/J.out" 2>&1 || fail "J accept recsys"
stage J r2 --workloads kv,lmdb && fail "J r2 ran with r1 lmdb skipped"
grep -q "SEQUENCE STOP: r1 of lmdb not checked PASS + accepted (skipped)" "$O/J.out" || fail "J r2 refusal reason"
stage J r3 --workloads lmdb && fail "J r3 ran with r1 lmdb skipped"
[ "$(grep -c "SEQUENCE STOP: r1 of lmdb not checked PASS + accepted (skipped)" "$O/J.out")" = 2 ] || fail "J r3 refusal reason"
[ ! -e "$O/J/kv/r2" ] && [ ! -e "$O/J/lmdb/r3" ] || fail "J refused stage left a round dir"
echo "J OK"
# K W7 (verifier MED-1 on v0.6.3): copy of A's kv r1 with knee-bracket fields added: pop u50 (weakest) at the probe
#   limit, mg u80 rel_width 0.06 -> two W7 WARNs (weakest named), hw u5 rel_width 0.01 -> OK; untouched legacy runs: no W7
mkdir -p "$O/K" && cp -r "$O/A/kv" "$O/K/kv" || fail "K copy"
python3 -I -B - "$O/K/kv/r1/run" <<'PY' || fail "K edit"
import json, os, sys
d = sys.argv[1]
for name, cs, rw in (("pop-u50-slo-r1", "probe limit (hi/lo 1.0954 > 1 + 0.01)", 0.0954),
                     ("mg-u80-r1", "bracket within confirm precision", 0.06), ("hw-u5-slo-r1", "first confirm passed", 0.01)):
    p = os.path.join(d, name, "slo", "loadgen", "summary.json")
    s = json.load(open(p))
    s.update(confirmed=True, confirm_search={"finish": cs}, bracket={"lo_offered": 1, "hi_offered": 1 + rw, "rel_width": rw})
    json.dump(s, open(p, "w"))
PY
python3 -B $H/check.py --plan $H/h1-plan.tsv --workload kv --round 1 --skip-fig2 "$O/K" > "$O/K.out" 2>&1
C=$O/K/kv/r1/check.txt
grep -q "^WARN W7 pop-u50-slo-r1 knee bracket: pop u50: rel_width 0.0954, finish 'probe limit .*WEAKEST of the mix" "$C" \
  && grep -q "^WARN W7 mg-u80-r1-slo knee bracket: mg u80: rel_width 0.06, .*not the weakest (pop)" "$C" \
  && grep -q "^OK   W7 hw-u5-slo-r1 knee bracket" "$C" && [ "$(grep -c "W7 " "$C")" = 3 ] \
  && tail -n 1 "$C" | grep -q "^H1CHECK PASS" || fail "K W7 ($(grep W7 "$C"; tail -n 1 "$C"))"
# K2 W4 search note (v0.6.5): r2 of kv with pop u50 confirm x +20 % vs r1, r1 at the probe limit (v0.6.3 summary),
#   r2 bisected (v0.6.5 summary with step_down) -> the W4 WARN names both searches; hw u5 +20 % with legacy summaries
#   (no confirm_search): W4 WARN without the note
python3 -I -B - "$O/K/kv" <<'PY' || fail "K2 edit"
import json, os, sys
d = sys.argv[1]
def ed(rnd, name, f):
    p = os.path.join(d, rnd, "run", name, "slo", "loadgen", "summary.json")
    s = json.load(open(p)); f(s); json.dump(s, open(p, "w"))
ed("r2", "pop-u50-r2", lambda s: (s["confirm"].update(x_mean=s["confirm"]["x_mean"] * 1.2),
   s.update(confirm_search={"finish": "bracket within confirm precision", "step_down": 0.05})))
ed("r2", "hw-u5-r2", lambda s: s["confirm"].update(x_mean=s["confirm"]["x_mean"] * 1.2))
PY
python3 -B $H/check.py --plan $H/h1-plan.tsv --workload kv --round 2 --skip-fig2 "$O/K" > "$O/K2.out" 2>&1
C=$O/K/kv/r2/check.txt
grep -q "^WARN W4 u50 pop x vs r1: .*confirm search r1 'probe limit (hi/lo 1.0954 > 1 + 0.01)' (v0.6.3), r2 'bracket within confirm precision' (v0.6.5)" "$C" \
  && grep "^WARN W4 u5 hw x vs r1" "$C" | grep -vq "confirm search" && grep -q "^OK   W4 u80 mg x vs r1" "$C" \
  || fail "K2 W4 note ($(grep W4 "$C" | head -4))"
echo "K OK"
# L r2 for a chosen subset (H1 v0.6.5): preconditions per chosen workload only
mkdir "$O/L"
la() { bash $H/h1-accept.sh "$O/L" "$1" "$2" selftest >> "$O/L.out" 2>&1 || fail "L accept r$1 $2"; }
stage L r1-kv || fail "L r1-kv"; la 1 kv
stage L r1-lmdb || fail "L r1-lmdb"
stage L r2 --workloads lmdb && fail "L r2 ran with r1 lmdb not accepted"
grep -q "SEQUENCE STOP: r1 of lmdb not checked PASS + accepted (r2/r3 need r1 accepted for each chosen workload)" "$O/L.out" \
  || fail "L unaccepted refusal reason"
la 1 lmdb
stage L r1-vdb || fail "L r1-vdb"; la 1 vdb
[ ! -e "$O/L/recsys" ] || fail "L recsys dir exists"
stage L r2 && fail "L r2 (all four) ran without recsys r1"
grep -q "SEQUENCE STOP: r1 of recsys not checked PASS + accepted" "$O/L.out" || fail "L r2 all reason"
stage L r2 --workloads lmdb,recsys && fail "L r2 lmdb,recsys ran without recsys r1"
[ ! -e "$O/L/lmdb/r2" ] || fail "L refused r2 left lmdb/r2"
stage L r2 --workloads vdb,lmdb || fail "L r2 lmdb,vdb with recsys r1 missing (see $O/L.out)"
grep -q "\[r2\] stage start: round 2, workloads \[lmdb vdb\]" "$O/L/h1-state.txt" || fail "L r2 order"
grep -q "STAGE DONE r2 \[lmdb vdb\]" "$O/L/h1-state.txt" || fail "L no STAGE DONE r2 [lmdb vdb]"
for w in lmdb vdb; do tail -n 1 "$O/L/$w/r2/check.txt" | grep -q "^H1CHECK PASS" || fail "L $w r2 check"
  [ -f "$O/L/$w/collect-all-r2/slo-summary.csv" ] || fail "L $w collect-all-r2"; done
[ ! -e "$O/L/kv/r2" ] && [ ! -e "$O/L/recsys" ] || fail "L r2 ran outside the subset"
la 2 lmdb
stage L r3 --workloads lmdb,vdb && fail "L r3 ran with vdb r2 not accepted"
grep -q "SEQUENCE STOP: r2 of vdb not checked PASS + accepted" "$O/L.out" || fail "L r3 vdb reason"
stage L r3 --workloads kv && fail "L r3 kv ran without r2"
grep -q "SEQUENCE STOP: r2 of kv not checked PASS + accepted" "$O/L.out" || fail "L r3 kv reason"
[ ! -e "$O/L/lmdb/r3" ] && [ ! -e "$O/L/kv/r3" ] || fail "L refused r3 left a round dir"
stage L r3 --workloads lmdb || fail "L r3 lmdb"
grep -q "STAGE DONE r3 \[lmdb\]" "$O/L/h1-state.txt" || fail "L no STAGE DONE r3 [lmdb]"
echo "L OK"
echo "SELFTEST PASS"

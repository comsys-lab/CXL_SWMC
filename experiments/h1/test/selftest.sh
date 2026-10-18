#!/bin/bash
# Host self-test of the staged H1 orchestration (no VM, no SSH, no sudo, no shared memory). Writes only below <out dir>.
# Never run while a VM measurement holds workspaces/MEASUREMENT.lock (the coordinator says "Host free").
# usage: selftest.sh <out dir under workspaces/h1-main/ (must not exist)> [<real SLO run dirs root for case E>]
#        [<RECSYS-V1 v1.4 evidence dir for case M (read-only)>] [<H1 r1-recsys SLO part dir for case N1 (read-only)>]
#   A  stages through the stub hook: r1-kv; r1-lmdb refused before acceptance; h1-accept.sh; r1-lmdb, r1-vdb,
#      r1-recsys (each accepted after its check PASS); r2 refused while an r1 is unaccepted (checked before the last
#      accept); r2 --workloads kv,vdb,recsys; r3 --workloads lmdb refused (no r2); r3 --workloads kv; collect-all-r<n> after
#      every stage (rounds_note single round / n rounds). Checks: every check.txt H1CHECK PASS; levels from r1 (weakest pop,
#      vdb u5 rate 42.105, kv integer 40/20); r2/r3 fixed windows at the r1 levels; collect-all slo-summary has 3
#      rounds per mix x system; fixed phase with 4 systems (mgoff = Megalon timers off); coherence CPU pop 0.4 /
#      mg, mgoff 0.2667 / hw 0; lock released after every stage. v0.6.7: recsys runs hw, pop only (h1sys.py): r1 and
#      r2 without any mg / mgoff run dir or entry, levels.tsv x_mg "-", 4 fixed windows per mix, 2 slo-summary rows per
#      mix, check.txt INFO line naming RECSYS-V1 v1.4; kv/lmdb/vdb unchanged (8 windows, 3 slo rows)
#   M  v0.6.7 recsys without Megalon: (1) a block that writes an mg SLO entry for recsys anyway -> LEVELS STOP
#      ("not measured") and HOOK STOP; (2) check.py F5 on a real hw/pop Fig 2 CSV (v6_fig2_split.py --megalon-c none
#      on recovery/RECSYS-V1-v1.4 hw/pop val windows, read-only) -> OK; the same CSV with a Megalon row -> F5 FAIL
#   B  STUB_FAIL=note:mg:u50 in r1-kv: SEQUENCE STOP at levels ("note")
#   C  STUB_FAIL=rc in r1-kv: SEQUENCE STOP at the SLO hook
#   D  real plugin pins-vdb.sh with FILL_ tokens (not dry): HOOK STOP "unpinned" (skipped once fully pinned)
#   E  levels.py + collect.py on the real KV-main H1 v2 SLO runs (read-only; mix u5 only): weakest pop
#   F  h1-accept.sh refuses a check.txt with REPORT lines without --user-ack, accepts with it
#   G  check.compare(): synthetic Fig 2 CSVs r1 / r2: hw +3 % inside the threshold, pop +12 % -> REPORT, C_diff inside;
#      v0.6.8: the same for recsys (no Megalon) -> the REPORT text says the threshold is uncalibrated
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
#   N  v0.6.8: (1) v1_check.py updater judgment on a copy of the stopped r1-recsys hw-peak SLO part (4th argument;
#      read-only): real data PASS (steps 7/10 completed = sent); low sent + full completions PASS; completions 96 % of
#      sent on a checked step FAIL, on an overload step NOTE; < 100 sent FAIL; (2) main-block.sh: --tol $H1_SLO_TOL
#      (0.02) only in h1_slo, not in h1_fix / h1_warmup, no --tol in the kv/lmdb/vectordb scripts; (3) r1 retry
#      (h1-main.sh --retry, attempts.py): stopped r1-recsys (levels row avg written) -> plain rerun, retry without
#      reason, retry for r2, retry of an accepted stage, retry while the stage's last state line is not a STOP: refused;
#      attempt 2 stops, attempt 3 passes (attempt.txt chain, stopped r1 unchanged, own levels.tsv, F8 on it, -a3
#      manifest files, accept record attempt=recsys/r1-a3, collect-all-r1 only r1-a3 runs); retry after acceptance
#      refused; r2 recsys uses r1-a3 levels; retry refused for a check-PASS attempt and after a skip; a broken layout
#      is refused by attempts.py and h1-accept.sh
#   O  v0.6.9 (user 2026-10-18: H1 RecSys T = 1 s): (1) v1_check.py short-T rules on a synthetic T = 1 s copy of the
#      RECSYS-V1 v1.4 hw val window (3rd argument dir, read-only): 130 rounds at +1 % PASS; a round-edge snapshot
#      (flushes off by 2 <= U) PASS with NOTE, the same at T = 60 s FAIL (unchanged); off by 5 > U FAIL (OPFAIL with
#      --oppoint-report); update_rate_sustained=0 from overruns before the window PASS with NOTE; an overrun in the
#      window FAIL; rows +20 % FAIL; (2) --h1 SLO copy of the stopped r1-recsys hw-peak part (4th argument) rewritten to
#      T = 1 s: rows +20 % over < 45 checked rounds NOTE, over >= 45 rounds FAIL, +0 % PASS; (3) main-block.sh ekko_set /
#      rate_for at RS_T_MS=1000 with builds/recsys-calib/2 (real recsys-rate runs, Host compute): peak / avg / f149 server
#      --publish-frac = the T = 1 s calibration, loadgen update rate = the T = 60 s Ekko rate, T check written once per
#      Ekko point; a calibration whose ref rate differs stops; RS_T_MS=60000 unchanged; static: BLOCK=h1 needs RS_T_MS,
#      pins-recsys.sh BLOCK_ENV has RS_T_MS=1000 and RATE_T_DIR
#   P  v0.6.9 new evidence root (h1-main.sh --from-root) and invalid rounds (h1-accept.sh --invalid): in E1 (all four
#      r1 accepted, r2 recsys run, not accepted): --invalid r2 recsys recorded, then accept r2 recsys refused, --invalid
#      of the accepted r1 recsys refused; r1-recsys --from-root E1 into E2: prev-root.txt with 4 records, E1 gets only
#      accept/r1-recsys-superseded.txt (E1 listing otherwise unchanged), r2 recsys in E1 refused, E2 r1 accepted, r2
#      --workloads recsys in E2 runs at E2's levels, r2 (all four) in E2 refused; refused: a second --from-root (already
#      superseded), --from-root for r2, non-empty E2, E1 with vdb not accepted; a --from-root stage that stops is retried
#      in E2 (previous stage found in E1 through prev-root.txt) and a tampered E1 acceptance record blocks that retry
#   Q  v0.6.10 --add-mixes: E1 = P2 (r1 recsys accepted there); refused: non-empty E2, a regular mix (avg), an unknown
#      mix, a mix listed twice, r2, E1 without an accepted r1 recsys; r1-recsys --add-mixes P2 f087,f149,f253 into Q1:
#      stage-plan.tsv = plan with the recsys rows replaced by the three extra rows, add-mixes.txt records, E1 listing
#      unchanged (no supersession record), Q1 check PASS with runs for the 3 mixes only, levels for f087/f149/f253,
#      accept works; r2 / r1-kv in Q1 refused; a stopped --add-mixes stage is retried in its root and a tampered E1
#      acceptance record blocks that retry
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
stage A r2 --workloads kv,vdb,recsys || fail "A r2 subset"
for w in kv vdb recsys; do acc 2 $w; done
stage A r3 --workloads lmdb && fail "A r3 ran for lmdb without r2"
stage A r3 --workloads kv || fail "A r3 kv"
grep -q "STAGE DONE r3 \[kv\]" "$O/A/h1-state.txt" || fail "A no STAGE DONE r3 [kv]"
[ ! -e "$O/A/lmdb/r2" ] && [ ! -e "$O/A/recsys/r3" ] && [ ! -e "$O/A/vdb/r3" ] || fail "A ran rounds outside the subset"
python3 -I -B - "$O/A" <<'EOF' || fail "A content"
import csv, glob, os, sys
o = sys.argv[1]
done = {"kv": (1, 2, 3), "lmdb": (1,), "vdb": (1, 2), "recsys": (1, 2)}
for w, rs in done.items():
    for n in rs:
        last = open(f"{o}/{w}/r{n}/check.txt").read().strip().splitlines()[-1]
        assert last.startswith("H1CHECK PASS"), (w, n, last)
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/vdb/levels.tsv"), delimiter="\t")}
assert lv["u5"]["weakest"] == "pop" and float(lv["u5"]["L1_x"]) == 40 and lv["u5"]["L1_rate"] == "42.105", lv["u5"]
kv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/kv/levels.tsv"), delimiter="\t")}
assert kv["u80"]["L1_rate"] == "40" and kv["u80"]["L2_rate"] == "20", kv["u80"]
rs = {r["mix"]: r for r in csv.DictReader(open(f"{o}/recsys/levels.tsv"), delimiter="\t")}
assert rs["avg"]["weakest"] == "pop" and rs["avg"]["x_mg"] == "-" and rs["avg"]["L1_rate"] == "40.0", rs["avg"]
for n in (1, 2):  # v0.6.7: no Megalon in H1 recsys
    ents = [l.split("\t")[1] for l in open(f"{o}/recsys/r{n}/run/h1-runs.tsv") if not l.startswith("#")]
    assert sorted(set(ents)) == ["hw", "pop"] and len(ents) == 8, (n, ents)
    assert not glob.glob(f"{o}/recsys/r{n}/run/mg*"), n
    ck = open(f"{o}/recsys/r{n}/check.txt").read()
    assert "INFO systems hw pop: Megalon not measured in H1 for recsys" in ck and "RECSYS-V1 v1.4" in ck, ck[:300]
    assert not [l for l in ck.splitlines() if l.split()[1:2] and l.split()[1] in ("F9", "W5", "W6", "C2")], n
    assert open(f"{o}/recsys/r{n}/collect/systems.txt").read().startswith("systems hw pop"), n
for w in ("kv", "lmdb", "vdb"):
    assert "INFO" not in open(f"{o}/{w}/r1/check.txt").read(), w
    assert not os.path.exists(f"{o}/{w}/r1/collect/systems.txt"), w
for w, ncell in (("kv", 3), ("lmdb", 3), ("vdb", 3), ("recsys", 2)):
    nsys = 2 if w == "recsys" else 4
    for n in done[w]:
        fx = list(csv.DictReader(open(f"{o}/{w}/r{n}/collect/fix-steps.csv")))
        assert len(fx) == 2 * nsys * ncell, (w, n, len(fx))  # hw, pop, mg, mgoff (recsys hw, pop) x L1/L2
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
        assert len(ss) == (nsys - 1 if nsys == 4 else 2) * ncell and all(r["rounds"] == str(n) and r["rounds_note"] == note for r in ss), ss[:1]
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
check.lines.clear()
# v0.6.8 (verifier LOW on v0.6.7): for a workload without Megalon (recsys) the C1 REPORT says the threshold is uncalibrated
def figr(n, hw, pop):
    d = os.path.join(o, "recsys", f"r{n}", "collect", "fig"); os.makedirs(d)
    open(os.path.join(d, "recsys-avg-fig2.csv"), "w").write("# megalon_c: none\n" + hdr +
        f"L1,query,All HWcc,{hw},0,,\nL1,query,Popcorn,{pop},1,,\n")
figr(1, 1000, 2000)
figr(2, 1030, 2240)
check.compare("recsys", 2, o, ["avg"], False)
rep = [l for l in check.lines if l.startswith("REPORT")]
assert len(rep) == 1 and " pop " in rep[0] and rep[0].endswith("threshold uncalibrated for this workload: no Megalon "
       "run-to-run spread term (v0.6.7 R3, fixed 5 % in r2)"), check.lines
assert not any("uncalibrated" in l for l in check.lines if " kv " in l or "u5" in l), check.lines
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
# M v0.6.7 recsys without Megalon
mkdir -p "$O/M/run"
printf 'owner=H1-main selftest\n' > "$O/M/lock"
LOCK=$O/M/lock STUB_FAIL=mgextra H1_SETTLE_S=60 H1_LEVELS_CMD=$H/levels-cb.sh H1_PLAN=$H/h1-plan.tsv H1_W=recsys \
  H1_LEVELS_OUT=$O/M/levels.tsv bash $H/hook.sh recsys r1 "$O/M/run" 1 "avg=EKKO=avg" > "$O/M.out" 2>&1 && fail "M1 rc 0"
grep -q "HOOK STOP recsys r1 1: block rc" "$O/M.out" && grep -q "LEVELS STOP .*not measured for recsys" "$O/M/levels-avg.log" \
  || fail "M1 reason ($(cat "$O/M.out"; cat "$O/M/levels-avg.log" 2>/dev/null))"
RV=${3:-/home/comsys/sungsu/destijl-control/recovery/RECSYS-V1-v1.4}
mkdir -p "$O/M2" && cp -r "$O/A/recsys" "$O/M2/recsys" && rm -rf "$O/M2/recsys/r2" || fail "M2 copy"
F=$O/M2/recsys/r1/collect/fig
nice -n 19 python3 -B $H/../analysis/v6_fig2_split.py --megalon-c none --megalon-note selftest --out "$O/M2/fig" --tag rs \
  L1:hw=$RV/hw/val:1 L1:pop=$RV/pop/val:1 L2:hw=$RV/hw/val:1 L2:pop=$RV/pop/val:1 > "$O/M2-fig2.out" 2>&1 || fail "M2 fig2 none"
cp "$O/M2/fig/rs-fig2.csv" "$F/recsys-avg-fig2.csv" && cp "$O/M2/fig/rs-fig2.csv" "$F/recsys-peak-fig2.csv"
python3 -B $H/check.py --plan $H/h1-plan.tsv --workload recsys --round 1 "$O/M2" > "$O/M2-check.out" 2>&1
C=$O/M2/recsys/r1/check.txt
grep -q "^OK   F5 avg Fig 2 C/T" "$C" && grep -q "^OK   F5 peak Fig 2 C/T" "$C" && ! grep -q "^[A-Z]* *\(F9\|W5\|W6\) " "$C" \
  || fail "M2 F5 hw/pop ($(grep 'F5\|F9' "$C"))"
sed 's/^\(L1,query,\)Popcorn,/\1Megalon (timers off),/' "$O/M2/fig/rs-fig2.csv" > "$F/recsys-avg-fig2.csv"
cat "$F/recsys-avg-fig2.csv" | grep -q "Megalon (timers off)" || fail "M2 edit"
python3 -B $H/check.py --plan $H/h1-plan.tsv --workload recsys --round 1 "$O/M2" > "$O/M2-check2.out" 2>&1
grep -q "^FAIL F5 avg Fig 2 C/T: .*Megalon row 'Megalon (timers off)' for recsys" "$C" || fail "M2 Megalon row not refused ($(grep F5 "$C"))"
echo "M OK"
# N v0.6.8 (user 2026-10-18 "응 그렇게 진행해")
# N1 v1_check.py updater judgment on a copy of the stopped r1-recsys hw-peak SLO part (read-only source): the real data
#    (steps 7 / 10 sent 2760 / 2759, all completed; old rule FAIL vs nominal 188.761/s) -> PASS; a checked step with
#    low sent and full completions (achieved/offered 0.95) -> PASS; a checked step with completions 96 % of sent -> FAIL
#    "updater behind"; the same lag on a non-checked (overload) step -> NOTE only
RS=${4:-/home/comsys/sungsu/destijl-control/recovery/H1-main-v1/recsys/r1/run/hw-peak-slo-r1/slo}
VC=$H/../recsys/v1_check.py
mkdir -p "$O/N1/real/loadgen" && cp -r "$RS/loadgen/stats" "$RS/loadgen/steps.jsonl" "$RS/loadgen/summary.json" "$O/N1/real/loadgen/" \
  && cp "$RS/manifest.txt" "$RS/breakdown.csv" "$O/N1/real/" || fail "N1 copy"
python3 -I -B $VC "$O/N1/real" hw --h1 > "$O/N1/real.out" 2>&1 || fail "N1 real data not PASS ($(cut -c1-300 "$O/N1/real.out"))"
grep -q "^V1CHECK PASS hw .*update_achieved_offered.step7=183.96/188.76 update_completed_sent.step7=2759/2760" "$O/N1/real.out" \
  || fail "N1 real values ($(cut -c1-300 "$O/N1/real.out"))"
nv() {  # <case> <python edit of the steps list d (list of dicts)>: copy of real with steps.jsonl edited
  cp -r "$O/N1/real" "$O/N1/$1" && python3 -I -B -c '
import json, sys
p = sys.argv[1] + "/loadgen/steps.jsonl"
d = [json.loads(l) for l in open(p) if l.strip()]
exec(sys.argv[2])
open(p, "w").write("".join(json.dumps(x) + "\n" for x in d))' "$O/N1/$1" "$2" || fail "N1 edit $1"
  python3 -I -B $VC "$O/N1/$1" hw --h1 > "$O/N1/$1.out" 2>&1; echo $? >> "$O/N1/$1.out"
}
nv lowsent 'u = d[5]["streams"]["update"]; u["sent"] = u["done"] = 2690; u["achieved"] = 2690 / 15'
grep -q "^V1CHECK PASS" "$O/N1/lowsent.out" && grep -q "update_achieved_offered.step5=179.33/188.76 update_completed_sent.step5=2690/2690" "$O/N1/lowsent.out" \
  || fail "N1 low sent, full completions ($(cut -c1-300 "$O/N1/lowsent.out"))"
nv lag 'u = d[5]["streams"]["update"]; u["achieved"] = 0.96 * u["sent"] / 15'
grep -q "^V1CHECK FAIL hw step 5 (ramp): updater behind (update completions 2684 < 0.98 x sent 2796" "$O/N1/lag.out" && tail -n 1 "$O/N1/lag.out" | grep -qx 1 \
  || fail "N1 real lag not FAIL ($(cut -c1-300 "$O/N1/lag.out"))"
nv lagnc 'u = d[25]["streams"]["update"]; u["achieved"] = 0.96 * u["sent"] / 15'
grep -q "^V1CHECK PASS .*NOTES: .*step 25 (overload): updater behind .*\[not a checked step\]" "$O/N1/lagnc.out" \
  || fail "N1 lag on a non-checked step ($(cut -c1-300 "$O/N1/lagnc.out"))"
nv fewsent 'u = d[5]["streams"]["update"]; u["sent"] = u["done"] = 90; u["achieved"] = 6'
grep -q "^V1CHECK FAIL hw step 5 (ramp): updater not judgeable" "$O/N1/fewsent.out" || fail "N1 < 100 sent ($(cut -c1-300 "$O/N1/fewsent.out"))"
# N2 recsys BLOCK=h1 loadgen args: the SLO search passes --tol 0.02 (H1_SLO_TOL), the fixed part and warm-up do not
MB=$H/../recsys/main-block.sh
fn() { sed -n "/^$1() {/,/^}/p" "$MB"; }
grep -qx "H1_SLO_TOL=0.02" "$MB" && fn h1_slo | grep -qF -- '--tol $H1_SLO_TOL' && ! fn h1_fix | grep -qF -- "--tol" \
  && ! fn h1_warmup | grep -qF -- "--tol" && [ "$(grep -v '^ *#' "$MB" | grep -cF -- '--tol')" = 1 ] || fail "N2 recsys h1 loadgen --tol"
for f in $H/../kv/*.sh $H/../lmdb/*.sh $H/../vectordb/*.sh; do [ -f "$f" ] || continue; grep -v '^ *#' "$f" | grep -qF -- "--tol" && fail "N2 --tol in $f"; done
# N3 r1 retry (attempts.py): r1-recsys stops after its avg mix (levels.tsv row avg written, peak hw/pop SLO entries)
mkdir "$O/N"
na() { bash $H/h1-accept.sh "$O/N" "$1" "$2" selftest >> "$O/N.out" 2>&1; }
for w in kv lmdb vdb; do stage N r1-$w || fail "N r1-$w"; na 1 $w || fail "N accept $w"; done
STUB_FAIL=note:hw:peak stage N r1-recsys && fail "N r1-recsys rc 0"
grep -q "\[r1-recsys\] SEQUENCE STOP" "$O/N/h1-state.txt" && grep -q "^avg	" "$O/N/recsys/levels.tsv" || fail "N stop setup"
L1SHA=$(cd "$O/N/recsys/r1" && find . -type f -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64)
na 1 recsys && fail "N accepted a stopped stage"
stage N r1-recsys && fail "N r1-recsys rerun without --retry"
grep -q "recsys/r1 exists (stage dirs are immutable; a stopped r1 stage is re-run with --retry; r2/r3 have no retry path yet)" "$O/N/h1-state.txt" || fail "N rerun reason"
stage N r1-recsys --retry && fail "N --retry without reason"
stage N r2 --retry "x" && fail "N --retry for r2"
grep -q "SEQUENCE STOP: --retry is for r1-<W> stages only" "$O/N.out" || fail "N r2 retry reason"
stage N r1-kv --retry "x" && fail "N --retry of an accepted stage"
grep -q "SEQUENCE STOP: --retry refused for r1-kv: r1 kv is accepted" "$O/N.out" || fail "N accepted retry reason"
# a stage that is still running (its last state line is not a STOP) is refused: copy with a later progress line
cp -r "$O/N" "$O/N-run" && echo "$(date -Is) [r1-recsys] gate recsys-r1-start: PASS" >> "$O/N-run/h1-state.txt"
stage N-run r1-recsys --retry "x" && fail "N retry of a running stage"
grep -q "refused for r1-recsys: the last r1-recsys line in h1-state.txt is not a SEQUENCE STOP" "$O/N-run.out" || fail "N running reason"
# attempt 2 stops at once (block rc), attempt 3 completes
STUB_FAIL=rc stage N r1-recsys --retry "selftest: attempt 2 injected rc" && fail "N attempt 2 rc 0"
[ -f "$O/N/recsys/r1-a2/attempt.txt" ] && [ ! -e "$O/N/recsys/r1-a2/levels.tsv" ] || fail "N attempt 2 layout"
stage N r1-recsys --retry "selftest: after injected STOPs" || fail "N attempt 3 (see $O/N.out)"
A3=$O/N/recsys/r1-a3
grep -qx "attempt=3" "$A3/attempt.txt" && grep -qx "predecessor=r1-a2" "$A3/attempt.txt" && grep -qx "round=1" "$A3/attempt.txt" \
  && grep -qx "reason=selftest: after injected STOPs" "$A3/attempt.txt" && grep -q "^predecessor_state_last=.*\[r1-recsys\] SEQUENCE STOP" "$A3/attempt.txt" \
  && grep -qx "predecessor=r1" "$O/N/recsys/r1-a2/attempt.txt" || fail "N attempt.txt ($(cat "$A3/attempt.txt"))"
[ "$(cd "$O/N/recsys/r1" && find . -type f -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64)" = "$L1SHA" ] || fail "N stopped attempt changed"
grep -q "RETRY attempt=3 dir=recsys/r1-a3 predecessor=recsys/r1-a2 reason=selftest: after injected STOPs" "$O/N/h1-state.txt" \
  && grep -q "^retry: attempt=3 " "$O/N/h1-manifest.txt" && [ -f "$O/N/manifest-recsys-r1-a3.txt" ] && [ -f "$O/N/manifest-end-r1-recsys-a3.txt" ] \
  && grep -q "STAGE DONE r1-recsys: main session reviews $A3/check.txt" "$O/N/h1-state.txt" || fail "N retry logs"
[ "$(python3 -I -B $H/attempts.py dir "$O/N" recsys 1)" = "$A3" ] && [ "$(python3 -I -B $H/attempts.py levels "$O/N" recsys)" = "$A3/levels.tsv" ] \
  && [ "$(python3 -I -B $H/attempts.py dir "$O/N" kv 1)" = "$O/N/kv/r1" ] && [ "$(python3 -I -B $H/attempts.py levels "$O/N" kv)" = "$O/N/kv/levels.tsv" ] \
  || fail "N attempts.py resolution"
tail -n 1 "$A3/check.txt" | grep -q "^H1CHECK PASS recsys r1" && grep -q "^avg	" "$A3/levels.tsv" && grep -q "^peak	" "$A3/levels.tsv" \
  && [ "$(grep -c . "$O/N/recsys/levels.tsv")" = 2 ] || fail "N attempt 3 check / levels"
grep -q "^OK   F8 peak levels weakest" "$A3/check.txt" || fail "N F8 reads the attempt's levels.tsv"
na 1 recsys || fail "N accept attempt 3"
grep -qx "attempt=recsys/r1-a3" "$O/N/accept/r1-recsys.txt" && grep -q "check_sha256=$(sha256sum < "$A3/check.txt" | cut -c1-64)" "$O/N/accept/r1-recsys.txt" \
  || fail "N accept record"
stage N r1-recsys --retry "x" && fail "N retry after acceptance"
grep -q "refused for r1-recsys: r1 recsys is accepted" "$O/N.out" || fail "N retry-after-accept reason"
# collect-all-r1 of recsys: runs of the current attempt only (the stopped r1 has 6 entries, r1-a2 none)
python3 -I -B - "$O/N" <<'PY' || fail "N collect-all"
import csv, sys
o = sys.argv[1]
ri = list(csv.DictReader(open(f"{o}/recsys/collect-all-r1/runs-index.csv")))
assert len(ri) == 8 and all("/r1-a3/" in r["run_dir"] for r in ri), [r["run_dir"] for r in ri]
old = [l for l in open(f"{o}/recsys/r1/run/h1-runs.tsv") if not l.startswith("#")]
assert len(old) == 6, old
PY
# r2 of recsys after the retry: levels from r1-a3, W4 against r1-a3
stage N r2 --workloads recsys || fail "N r2 recsys after retry (see $O/N.out)"
python3 -I -B - "$O/N" <<'PY' || fail "N r2 levels"
import csv, sys
o = sys.argv[1]
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/recsys/r1-a3/levels.tsv"), delimiter="\t")}
fx = list(csv.DictReader(open(f"{o}/recsys/r2/collect/fix-steps.csv")))
assert len(fx) == 8 and all(float(r["offered_x"]) == float(lv[r["mix"]][r["level"] + "_rate"]) for r in fx), fx[:1]
ck = open(f"{o}/recsys/r2/check.txt").read()
assert "OK   W4 avg hw x vs r1" in ck and ck.strip().splitlines()[-1].startswith("H1CHECK PASS"), ck[-400:]
PY
na 2 recsys || fail "N accept r2 recsys"
grep -qx "attempt=recsys/r2" "$O/N/accept/r2-recsys.txt" || fail "N r2 accept record"
# a retry is refused after a skip record and for a check-PASS (unaccepted) attempt
mkdir "$O/N2"; stage N2 r1-kv || fail "N2 r1-kv"
stage N2 r1-kv --retry "x" && fail "N2 retry of a PASS attempt"
grep -q "refused for r1-kv: .*check.txt is PASS" "$O/N2.out" || fail "N2 PASS reason"
mkdir "$O/N3"; stage N3 r1-kv || fail "N3 r1-kv"; bash $H/h1-accept.sh "$O/N3" 1 kv selftest >> "$O/N3.out" 2>&1 || fail "N3 accept"
STUB_FAIL=rc stage N3 r1-lmdb && fail "N3 lmdb rc 0"
bash $H/h1-accept.sh "$O/N3" 1 lmdb --skip "selftest" >> "$O/N3.out" 2>&1 || fail "N3 skip"
stage N3 r1-lmdb --retry "x" && fail "N3 retry of a skipped stage"
grep -q "refused for r1-lmdb: r1 lmdb was skipped" "$O/N3.out" || fail "N3 skip reason"
# a broken attempt layout (attempt dir without attempt.txt) is refused by the resolver and by h1-accept.sh
mkdir -p "$O/N4/recsys/r1/run" "$O/N4/recsys/r1-a2"
python3 -I -B $H/attempts.py dir "$O/N4" recsys 1 > /dev/null 2>&1; [ $? = 2 ] || fail "N4 resolver accepted a bad layout"
bash $H/h1-accept.sh "$O/N4" 1 recsys x > "$O/N4.out" 2>&1 && fail "N4 accept on a bad layout"
echo "N OK"
# O v0.6.9: short-T (T = 1 s) operating-point rules and the T = 1 s Ekko calibration path
VC=$H/../recsys/v1_check.py
RV=${3:-/home/comsys/sungsu/destijl-control/recovery/RECSYS-V1-v1.4}
mkdir -p "$O/O1/base/loadgen" && cp -r "$RV/hw/val/loadgen/stats" "$RV/hw/val/loadgen/steps.jsonl" "$RV/hw/val/loadgen/summary.json" "$O/O1/base/loadgen/" \
  && cp "$RV/hw/val/manifest.txt" "$RV/hw/val/breakdown.csv" "$O/O1/base/" || fail "O1 copy"
ov() {  # <case> <python: edits of b / e (dicts of the step001 begin / end t0 snapshot)> [v1_check flags]
  local c=$1 ed=$2; shift 2
  rm -rf "$O/O1/$c"; cp -r "$O/O1/base" "$O/O1/$c" && python3 -I -B -c '
import sys
d = sys.argv[1] + "/loadgen/stats/"
def rd(p): return [l.rstrip("\n") for l in open(p)]
def wr(p, lines, kv):
    seen = set(); out = []
    for l in lines:
        k = l.split("=", 1)[0]
        if k in kv: out.append(f"{k}={kv[k]}"); seen.add(k)
        else: out.append(l)
    out += [f"{k}={v}" for k, v in kv.items() if k not in seen]
    open(p, "w").write("\n".join(out) + "\n")
b = dict(publish_us=1000000, publish_rounds=500, flushes=2000, round_rows=9000000, published_seq=90000, flush_overruns=0,
         update_rate_sustained=1, rows_per_round_target=19192, publish_frac="0.00014302685789816636")
e = dict(b, publish_rounds=630, flushes=2520, round_rows=9000000 + 130 * 19400, published_seq=90000 + round(130 * 188.7608))
exec(sys.argv[2])
for n, kv in (("step001-begin-t0.txt", b), ("step001-end-t0.txt", e)):
    wr(d + n, rd(d + n), kv)' "$O/O1/$c" "$ed" || fail "O1 edit $c"
  python3 -I -B $VC "$O/O1/$c" hw "$@" > "$O/O1/$c.out" 2>&1; echo "rc=$?" >> "$O/O1/$c.out"
}
ok1() { grep -q "$2" "$O/O1/$1.out" && grep -qx "rc=$3" "$O/O1/$1.out" || fail "O1 $1 ($(cut -c1-400 "$O/O1/$1.out"))"; }
ov t1 ''
ok1 t1 "^V1CHECK PASS hw .*short_T_s=1.0 .*rows_per_round_target=19192 .*rows_per_full_round_vs_target_pct=1.1" 0
grep -q "NOTES" "$O/O1/t1.out" && fail "O1 t1 has notes"
ov edge 'e["flushes"] = 2518'
ok1 edge "^V1CHECK PASS hw .*round_edge_snapshots=1 .*NOTES: round edge at 1 snapshot(s) (short T; <= 1 round each): step 0 end 2518/630" 0
ov edge60 'e["flushes"] = 2518; b["publish_us"] = e["publish_us"] = 60000000'
ok1 edge60 "^V1CHECK FAIL hw .*round guard: step 0 end snapshot flushes 2518 != 4 x publish_rounds 630" 1
grep -q "short_T_s" "$O/O1/edge60.out" && fail "O1 edge60 treated as short T"
ov guard 'e["flushes"] = 2515'
ok1 guard "^V1CHECK FAIL hw round guard: step 0 end snapshot flushes 2515 != 4 x publish_rounds 630" 1
ov guardopr 'e["flushes"] = 2515' --oppoint-report
ok1 guardopr "^V1CHECK OPFAIL hw round guard" 3
ov sust 'b["update_rate_sustained"] = e["update_rate_sustained"] = 0; b["flush_overruns"] = e["flush_overruns"] = 3'
ok1 sust "^V1CHECK PASS hw .*NOTES: update_rate_sustained=0 from 3 flush overruns before the window (none in the window; short T)" 0
ov over 'e["update_rate_sustained"] = 0; e["flush_overruns"] = 1'
ok1 over "^V1CHECK FAIL hw update rate not sustained (flush overruns 1 in the checked span); update_rate_sustained=0" 1
ov rows20 'e["round_rows"] = 9000000 + 130 * 23100'
ok1 rows20 "^V1CHECK FAIL hw rows per full round 23100 vs target 19192 (> 15% off" 1
# O2 --h1 SLO part at T = 1 s: rows +20 % over < 45 checked rounds NOTE, >= 45 FAIL, +0 % PASS
RS=${4:-/home/comsys/sungsu/destijl-control/recovery/H1-main-v1/recsys/r1/run/hw-peak-slo-r1/slo}
mkdir -p "$O/O2/real/loadgen" && cp -r "$RS/loadgen/stats" "$RS/loadgen/steps.jsonl" "$RS/loadgen/summary.json" "$O/O2/real/loadgen/" \
  && cp "$RS/manifest.txt" "$RS/breakdown.csv" "$O/O2/real/" || fail "O2 copy"
o2() {  # <case> <rounds per measured step> <rows factor>
  rm -rf "$O/O2/$1"; cp -r "$O/O2/real" "$O/O2/$1" && python3 -I -B -c '
import glob, json, os, re, sys
d, k, fac = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
st = d + "/loadgen/stats/"
steps = sorted(int(re.search(r"step(\d+)-begin-t0", p).group(1)) for p in glob.glob(st + "step*-begin-t0.txt"))
pr, rr, ps = 100, 0, 0
def wr(p, kv):
    out, seen = [], set()
    for l in open(p):
        key = l.split("=", 1)[0]
        if key in kv: out.append(f"{key}={kv[key]}\n"); seen.add(key)
        else: out.append(l)
    out += [f"{a}={v}\n" for a, v in kv.items() if a not in seen]
    open(p, "w").write("".join(out))
def snap():
    return dict(publish_us=1000000, publish_rounds=pr, flushes=4 * pr, round_rows=rr, published_seq=ps, flush_overruns=0,
                update_rate_sustained=1, rows_per_round_target=19192)
for n in steps:
    pr += 3; rr += 3 * 19192; ps += round(3 * 188.7608)
    wr(st + f"step{n:03d}-begin-t0.txt", snap())
    pr += k; rr += round(k * 19192 * fac); ps += round(k * 188.7608)
    wr(st + f"step{n:03d}-end-t0.txt", snap())' "$O/O2/$1" "$2" "$3" || fail "O2 edit $1"
  python3 -I -B $VC "$O/O2/$1" hw --h1 > "$O/O2/$1.out" 2>&1; echo "rc=$?" >> "$O/O2/$1.out"
}
o2 short 2 1.2
NCK=$(grep -o "checked_steps=[0-9,]*" "$O/O2/short.out" | tr ',' '\n' | grep -c .)
[ "$NCK" -ge 3 ] && [ $((NCK * 2)) -lt 45 ] || fail "O2 checked steps $NCK (test needs >= 3 and 2 x n < 45)"
grep -q "^V1CHECK PASS hw .*NOTES: .*rows per full round 2[0-9]* vs target 19192 (> 15% off) over only $((NCK * 2)).0 full rounds (< 45; short T: not judged)" "$O/O2/short.out" \
  && grep -qx "rc=0" "$O/O2/short.out" || fail "O2 short ($(cut -c1-500 "$O/O2/short.out"))"
o2 long 15 1.2
grep -q "^V1CHECK FAIL hw rows per full round 230[0-9]* vs target 19192" "$O/O2/long.out" || fail "O2 long ($(cut -c1-400 "$O/O2/long.out"))"
o2 good 15 1.0
grep -q "^V1CHECK PASS hw .*rows_per_full_round_vs_target_pct=0.0" "$O/O2/good.out" || fail "O2 good ($(cut -c1-400 "$O/O2/good.out"))"
# O3 main-block.sh ekko_set / rate_for at RS_T_MS=1000 (functions extracted; real recsys-rate on the Host, niced on node 1)
PP=/home/comsys/sungsu/destijl-control MB=$H/../recsys/main-block.sh
mkdir -p "$O/O3"
{ echo 'stop() { echo "STOPPED: $*"; exit 1; }'
  sed -n '/^calv() {/p' "$MB"; sed -n '/^ekko_set() {/,/^}/p' "$MB"; sed -n '/^declare -A TCHK/p' "$MB"; sed -n '/^rate_for() {/,/^}/p' "$MB"
  echo 'rate_for "$1" "$E/r1.txt" && rate_for "$1" "$E/r2.txt" && echo "PF=$PUBLISH_FRAC UR=$UPD_RATE TCHK=${TCHK[$1]:-} SA=$SA LGC=${LGC[*]}"'; } > "$O/O3/fn.sh"
grep -q "^rate_for() {" "$O/O3/fn.sh" && grep -q "^ekko_set() {" "$O/O3/fn.sh" || fail "O3 extract"
o3() {  # <case> <ekko> <T_MS> <RATE_T_DIR> [BLOCK]
  mkdir -p "$O/O3/$1"
  env -i PATH="$PATH" E="$O/O3/$1" T_MS=$3 RATE_T_DIR=$4 BLOCK=${5:-h1} XT=7200 PLAIN_BUILD=$PP/builds/recsys/12 D=$PP/builds/recsys-inputs/1 \
    UPD_FILE=updates-day23-0-2M.smp QRY_FILE=queries-day23-89137318-1M.smp bash "$O/O3/fn.sh" "$2" > "$O/O3/$1.out" 2>&1; echo "rc=$?" >> "$O/O3/$1.out"
}
CAL=$PP/builds/recsys-calib/2   # v0.6.10 (avg/peak byte-identical to calib/1)
o3 peak peak 1000 $CAL
grep -q "^PF=0.00014302685789816636 UR=188.7608 TCHK=ok SA=.*--publish-frac 0.00014302685789816636 .*LGC=.*--fixed update=188.7608" "$O/O3/peak.out" \
  && grep -q "^EKKO=peak publish_frac=0.00014302685789816636 update_rate=188.7608 samples/s T_ms=1000 " "$O/O3/peak.out" \
  && [ "$(grep -c "^EKKO=peak" "$O/O3/peak.out")" = 2 ] && [ -f "$O/O3/peak/r1.txt.T1000" ] && [ -f "$O/O3/peak/r2.txt.T1000" ] \
  && grep -qx "rows_per_round_target=19192" "$O/O3/peak/update-rate-T1000-peak.txt" && grep -qx "rate_samples_per_s=188.7608" "$O/O3/peak/r1.txt" \
  || fail "O3 peak ($(cut -c1-400 "$O/O3/peak.out"))"
o3 avg avg 1000 $CAL
grep -q "^PF=1.523274789203064e-05 UR=14.7233 TCHK=ok .*--publish-frac 1.523274789203064e-05 .*--fixed update=14.7233" "$O/O3/avg.out" \
  && grep -qx "rows_per_round_target=2044" "$O/O3/avg/update-rate-T1000-avg.txt" || fail "O3 avg ($(cut -c1-400 "$O/O3/avg.out"))"
# v0.6.10 intermediate point: rate from its T = 60 s reference in RATE_T_DIR (EKKO_REF); without that file it stops
o3 f149 f149 1000 $CAL
grep -q "^PF=4.5713148517473555e-05 UR=51.8558 TCHK=ok .*--publish-frac 4.5713148517473555e-05 .*--fixed update=51.8558" "$O/O3/f149.out" \
  && grep -qx "rows_per_round_target=6134" "$O/O3/f149/update-rate-T1000-f149.txt" || fail "O3 f149 ($(cut -c1-400 "$O/O3/f149.out"))"
mkdir -p "$O/O3/calnoref" && cp $CAL/rate-T1000-*.txt "$O/O3/calnoref/"
o3 noref f253 1000 "$O/O3/calnoref"
grep -q "^STOPPED: no calibration file $O/O3/calnoref/rate-frac0.00253.txt" "$O/O3/noref.out" || fail "O3 noref ($(cut -c1-400 "$O/O3/noref.out"))"
mkdir -p "$O/O3/calbad" && cp $CAL/rate-T1000-*.txt "$O/O3/calbad/" && sed -i 's/^ref_rate_samples_per_s=.*/ref_rate_samples_per_s=188.7000/' "$O/O3/calbad/rate-T1000-peak.txt"
o3 bad peak 1000 "$O/O3/calbad"
grep -q "STOPPED: .*ref_rate_samples_per_s != the Ekko peak rate 188.7608" "$O/O3/bad.out" && grep -qx "rc=1" "$O/O3/bad.out" || fail "O3 bad calibration ($(cat "$O/O3/bad.out"))"
o3 t60 peak 60000 "" v1
grep -q "^PF=0.0043 UR=188.7608 TCHK= SA=.*--publish-frac 0.0043 " "$O/O3/t60.out" && [ ! -e "$O/O3/t60/r1.txt.T60000" ] \
  && [ -z "$(ls "$O/O3/t60" | grep -v '^r[12].txt$')" ] || fail "O3 T = 60 s path ($(cut -c1-300 "$O/O3/t60.out"))"
grep -q 'BLOCK=h1 needs RS_T_MS' "$MB" && grep -q "RS_T_MS=1000 RATE_T_DIR=\$P/builds/recsys-calib/2" $H/plugins/pins-recsys.sh || fail "O3 static RS_T_MS"
echo "O OK"
# P v0.6.9 --from-root / --invalid
mkdir "$O/P1"
pa() { bash $H/h1-accept.sh "$O/$1" "$2" "$3" selftest >> "$O/P.out" 2>&1; }
for w in kv lmdb vdb recsys; do stage P1 r1-$w || fail "P1 r1-$w"; pa P1 1 $w || fail "P1 accept $w"; done
stage P1 r2 --workloads recsys || fail "P1 r2 recsys"
cp -r "$O/P1" "$O/P1b"; cp -r "$O/P1" "$O/P1c"     # copies for the stop/retry and tamper cases
bash $H/h1-accept.sh "$O/P1" 2 recsys --invalid "selftest: T = 60 s round-phase artifact" >> "$O/P.out" 2>&1 || fail "P invalid r2"
grep -q "^INVALID r2 recsys" "$O/P1/accept/r2-recsys-invalid.txt" && grep -qx "reason=selftest: T = 60 s round-phase artifact" "$O/P1/accept/r2-recsys-invalid.txt" \
  && grep -q "^check_sha256=$(sha256sum < "$O/P1/recsys/r2/check.txt" | cut -c1-64)" "$O/P1/accept/r2-recsys-invalid.txt" || fail "P invalid record"
pa P1 2 recsys && fail "P accepted an invalid round"
bash $H/h1-accept.sh "$O/P1" 2 recsys --invalid "again" >> "$O/P.out" 2>&1 && fail "P second invalid"
bash $H/h1-accept.sh "$O/P1" 1 recsys --invalid "x" >> "$O/P.out" 2>&1 && fail "P invalid of an accepted r1"
grep -q "INVALID REFUSED: .*r1-recsys.txt exists" "$O/P.out" || fail "P invalid-accepted reason"
lst() { (cd "$1" && find . -type f -not -path ./accept/r1-recsys-superseded.txt -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64); }
E1SHA=$(lst "$O/P1")
mkdir "$O/P2"; echo x > "$O/P2/data"
stage P2 r1-recsys --from-root "$O/P1" "selftest" && fail "P --from-root into a non-empty root"
rm "$O/P2/data"
stage P2 r2 --from-root "$O/P1" "x" && fail "P --from-root for r2"
grep -q "SEQUENCE STOP: --from-root is for r1-<W> stages only" "$O/P2.out" || fail "P r2 reason"
stage P2 r1-recsys --from-root "$O/P1" "selftest: T = 1 s re-measurement" || fail "P --from-root (see $O/P2.out)"
F=$O/P2/prev-root.txt
grep -qx "from_root=$O/P1" "$F" && grep -qx "workload=recsys" "$F" && grep -qx "previous_stage=vdb" "$F" \
  && [ "$(grep -c '^record: accept_sha256 accept/r1-' "$F")" = 4 ] && grep -qx "superseded: $O/P1/accept/r1-recsys-superseded.txt" "$F" || fail "P prev-root.txt ($(cat "$F"))"
grep -q "^SUPERSEDED r1 recsys .* by the new evidence root $O/P2" "$O/P1/accept/r1-recsys-superseded.txt" \
  && grep -qx "attempt=recsys/r1" "$O/P1/accept/r1-recsys-superseded.txt" || fail "P superseded record"
[ "$(lst "$O/P1")" = "$E1SHA" ] || fail "P E1 changed beyond the supersession record"
grep -q "new evidence root from $O/P1 (previous stage vdb accepted there)" "$O/P2/h1-state.txt" && grep -q "^from_root: $O/P1 workload=recsys" "$O/P2/h1-manifest.txt" || fail "P logs"
stage P1 r2 --workloads recsys && fail "P r2 recsys in E1 after supersession"
pa P1 1 recsys && fail "P re-accept of a superseded r1"
pa P2 1 recsys || fail "P accept E2 r1"
stage P2 r2 --workloads recsys || fail "P r2 recsys in E2 (see $O/P2.out)"
python3 -I -B - "$O/P2" <<'PY' || fail "P E2 r2 levels"
import csv, sys
o = sys.argv[1]
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/recsys/levels.tsv"), delimiter="\t")}
fx = list(csv.DictReader(open(f"{o}/recsys/r2/collect/fix-steps.csv")))
assert len(fx) == 8 and all(float(r["offered_x"]) == float(lv[r["mix"]][r["level"] + "_rate"]) for r in fx), fx[:1]
PY
stage P2 r2 && fail "P r2 (all four) in E2"
mkdir "$O/P3"; stage P3 r1-recsys --from-root "$O/P1" "again" && fail "P second --from-root"
grep -q "already superseded" "$O/P3.out" || fail "P second reason"
# E1 whose vdb is not accepted
mkdir "$O/P4" "$O/P4e"; for w in kv lmdb vdb; do stage P4 r1-$w || fail "P4 r1-$w"; [ $w = vdb ] || pa P4 1 $w || fail "P4 accept $w"; done
stage P4e r1-recsys --from-root "$O/P4" "x" && fail "P from a root with vdb unaccepted"
grep -q "r1-vdb is not checked PASS + accepted in $O/P4" "$O/P4e.out" || fail "P4 reason"
# a --from-root stage that stops, then --retry in E2 (previous stage looked up in E1)
mkdir "$O/P5"; STUB_FAIL=rc stage P5 r1-recsys --from-root "$O/P1b" "selftest stop" && fail "P5 rc 0"
[ -f "$O/P5/prev-root.txt" ] && [ -f "$O/P1b/accept/r1-recsys-superseded.txt" ] || fail "P5 records"
stage P5 r1-recsys --retry "selftest retry" || fail "P5 retry in E2 (see $O/P5.out)"
grep -q "previous stage vdb accepted in the predecessor root $O/P1b (prev-root.txt sha256s verified)" "$O/P5/h1-state.txt" || fail "P5 retry note"
mkdir "$O/P6"; STUB_FAIL=rc stage P6 r1-recsys --from-root "$O/P1c" "selftest stop" && fail "P6 rc 0"
echo "tampered" >> "$O/P1c/accept/r1-vdb.txt"
stage P6 r1-recsys --retry "x" && fail "P6 retry after a tampered E1 record"
grep -q "SEQUENCE STOP: r1-vdb not checked PASS + accepted (nor skipped)" "$O/P6.out" || fail "P6 reason"
echo "P OK"
# Q v0.6.10 --add-mixes (E1 = P2: r1 recsys accepted, r2 recsys run)
lsq() { (cd "$1" && find . -type f -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64); }
Q1SHA=$(lsq "$O/P2")
mkdir "$O/Q0"; echo x > "$O/Q0/data"
stage Q0 r1-recsys --add-mixes "$O/P2" f087 "x" && fail "Q into a non-empty root"
rm "$O/Q0/data"
stage Q0 r1-recsys --add-mixes "$O/P2" avg "x" && fail "Q regular mix"
grep -q "mix avg is not a row of recsys in .*h1-plan-extra.tsv" "$O/Q0.out" || fail "Q regular-mix reason"
stage Q0 r1-recsys --add-mixes "$O/P2" f999 "x" && fail "Q unknown mix"
stage Q0 r1-recsys --add-mixes "$O/P2" f087,f087 "x" && fail "Q mix twice"
grep -q "mix f087 listed twice" "$O/Q0.out" || fail "Q twice reason"
stage Q0 r2 --add-mixes "$O/P2" f087 "x" && fail "Q r2"
grep -q "SEQUENCE STOP: --add-mixes is for r1-<W> stages only" "$O/Q0.out" || fail "Q r2 reason"
stage Q0 r1-recsys --add-mixes "$O/P1" f087 "x" && fail "Q from a root whose r1 recsys is superseded"
grep -q "r1-recsys is not checked PASS + accepted in $O/P1" "$O/Q0.out" || fail "Q superseded reason"
[ -z "$(ls -A "$O/Q0" | grep -v '^sequence')" ] || fail "Q0 refusals wrote files"
mkdir "$O/Q1"
stage Q1 r1-recsys --add-mixes "$O/P2" f087,f149,f253 "selftest: intermediate Ekko points" || fail "Q --add-mixes (see $O/Q1.out)"
[ "$(lsq "$O/P2")" = "$Q1SHA" ] && [ ! -e "$O/P2/accept/r1-recsys-superseded.txt" ] || fail "Q E1 changed"
F=$O/Q1/add-mixes.txt
grep -qx "from_root=$O/P2" "$F" && grep -qx "workload=recsys" "$F" && grep -qx "mixes=f087 f149 f253" "$F" \
  && [ "$(grep -c '^record: accept_sha256 accept/r1-recsys.txt ' "$F")" = 1 ] \
  && grep -qx "stage_plan_sha256=$(sha256sum < "$O/Q1/stage-plan.tsv" | cut -c1-64)" "$F" || fail "Q add-mixes.txt ($(cat "$F"))"
[ "$(awk -F'\t' '!/^#/ && $1 == "recsys" { print $2 }' "$O/Q1/stage-plan.tsv" | tr '\n' ' ')" = "f087 f149 f253 " ] \
  && diff <(grep -v "^recsys	" "$O/Q1/stage-plan.tsv") <(grep -v "^recsys	" "$H/h1-plan.tsv") > /dev/null || fail "Q stage plan"
grep -q "^add_mixes: $O/P2 workload=recsys mixes=f087 f149 f253" "$O/Q1/h1-manifest.txt" || fail "Q manifest line"
python3 -I -B - "$O/Q1" <<'PY' || fail "Q content"
import csv, sys
o = sys.argv[1]
ents = [l.split("\t") for l in open(f"{o}/recsys/r1/run/h1-runs.tsv") if not l.startswith("#")]
assert sorted({e[2] for e in ents}) == ["f087", "f149", "f253"] and len(ents) == 12, ents
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/recsys/levels.tsv"), delimiter="\t")}
assert sorted(lv) == ["f087", "f149", "f253"], lv
assert open(f"{o}/recsys/r1/check.txt").read().strip().splitlines()[-1].startswith("H1CHECK PASS")
PY
bash $H/h1-accept.sh "$O/Q1" 1 recsys selftest >> "$O/Q.out" 2>&1 || fail "Q accept"
stage Q1 r2 --workloads recsys && fail "Q r2 in an --add-mixes root"
stage Q1 r1-kv && fail "Q r1-kv in an --add-mixes root"
grep -q "was started with --add-mixes" "$O/Q1.out" || fail "Q refusal reason"
cp -r "$O/P2" "$O/P2q"
mkdir "$O/Q2"; STUB_FAIL=rc stage Q2 r1-recsys --add-mixes "$O/P2q" f149 "selftest stop" && fail "Q2 rc 0"
[ -f "$O/Q2/add-mixes.txt" ] || fail "Q2 records"
stage Q2 r1-recsys --retry "selftest retry" || fail "Q2 retry (see $O/Q2.out)"
grep -q -- "--add-mixes root (records verified): f149" "$O/Q2/h1-state.txt" || fail "Q2 retry note"
mkdir "$O/Q3"; STUB_FAIL=rc stage Q3 r1-recsys --add-mixes "$O/P2q" f253 "selftest stop" && fail "Q3 rc 0"
echo "tampered" >> "$O/P2q/accept/r1-recsys.txt"
stage Q3 r1-recsys --retry "x" && fail "Q3 retry after a tampered E1 record"
grep -q "add-mixes.txt or stage-plan.tsv does not verify" "$O/Q3.out" || fail "Q3 reason"
echo "Q OK"
echo "SELFTEST PASS"

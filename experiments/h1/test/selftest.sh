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
echo "SELFTEST PASS"

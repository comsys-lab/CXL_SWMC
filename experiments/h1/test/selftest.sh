#!/bin/bash
# Host self-test of the H1 orchestration (no VM, no SSH, no sudo, no shared memory). Writes only below <out dir>.
# usage: selftest.sh <out dir under workspaces/h1-main/ (must not exist)> [<real SLO run dirs root for case E>]
#   A  dry sequence vdb + kv + recsys (stub block): SEQUENCE DONE; levels (weakest pop, L1_x 40, L2_x 20; vdb u5 rate 42.105,
#      kv integer rates 40 / 20); collect CSVs (18 fixed windows per workload, coh_cpu_vcpus pop 0.4 / mg 0.2667 /
#      hw 0); lock released
#   B  STUB_FAIL=note:mg:u50: SEQUENCE STOP at levels ("note"), lock released
#   C  STUB_FAIL=rc: SEQUENCE STOP at the first hook, lock released
#   D  real plugin pins-kv.sh (not dry): HOOK STOP "unpinned"
#   E  levels.py + collect.py on the real KV-main H1 v2 SLO runs (read-only; mix u5 only): weakest pop
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
# A
mkdir "$O/A"; WORKLOADS="vdb kv recsys" bash $H/h1-main.sh "$O/A" > "$O/A.out" 2>&1 || fail "A rc (see $O/A.out)"
grep -q "SEQUENCE DONE H1-main" "$O/A/h1-state.txt" || fail "A no SEQUENCE DONE"
nolock A
python3 -I -B - "$O/A" <<'EOF' || fail "A content"
import csv, sys
o = sys.argv[1]
lv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/vdb/levels.tsv"), delimiter="\t")}
assert lv["u5"]["weakest"] == "pop" and float(lv["u5"]["L1_x"]) == 40 and float(lv["u5"]["L2_x"]) == 20, lv["u5"]
assert lv["u5"]["L1_rate"] == "42.105" and lv["u90"]["L1_rate"] == "400.0", (lv["u5"]["L1_rate"], lv["u90"]["L1_rate"])
kv = {r["mix"]: r for r in csv.DictReader(open(f"{o}/kv/levels.tsv"), delimiter="\t")}
assert kv["u80"]["L1_rate"] == "40" and kv["u80"]["L2_rate"] == "20", kv["u80"]
for w in ("vdb", "kv", "recsys"):
    fx = list(csv.DictReader(open(f"{o}/{w}/collect/fix-steps.csv")))
    assert len(fx) == (12 if w == "recsys" else 18), (w, len(fx))
    want = {"hw": 0.0, "pop": 0.4, "mg": 0.2667}
    for r in fx:
        assert abs(float(r["coh_cpu_vcpus"]) - want[r["system"]]) < 1e-3, r
    assert {r["level"] for r in fx} == {"L1", "L2"}
    ss = list(csv.DictReader(open(f"{o}/{w}/collect/slo-summary.csv")))
    assert len(ss) == (6 if w == "recsys" else 9) and all(r["overload_points_present"] == "True" for r in ss), ss
    assert len(list(csv.DictReader(open(f"{o}/{w}/collect/runs-index.csv")))) == (12 if w == "recsys" else 18)
    sa = list(csv.DictReader(open(f"{o}/{w}/collect/steps-all.csv")))
    assert len(sa) > 0 and sa[0]["label"].startswith(w + "/"), sa[:1]
print("A content OK")
EOF
# B
mkdir "$O/B"; STUB_FAIL=note:mg:u50 WORKLOADS=kv bash $H/h1-main.sh "$O/B" > "$O/B.out" 2>&1 && fail "B rc 0"
grep -q "SEQUENCE STOP kv levels: LEVELS STOP .*note" "$O/B/h1-state.txt" || fail "B stop reason"
nolock B
# C
mkdir "$O/C"; STUB_FAIL=rc WORKLOADS=lmdb bash $H/h1-main.sh "$O/C" > "$O/C.out" 2>&1 && fail "C rc 0"
grep -q "SEQUENCE STOP lmdb slo round 1" "$O/C/h1-state.txt" || fail "C stop reason"
nolock C
# D
mkdir "$O/D"; H1_DRY=0 bash $H/hook.sh kv slo "$O/D" 1 "u5=PUT_RATIO=0.05" > "$O/D.out" 2>&1 && fail "D rc 0"
grep -q "HOOK STOP kv slo 1: unpinned" "$O/D.out" || fail "D reason ($(cat "$O/D.out"))"
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
echo "SELFTEST PASS"

#!/bin/bash
# H1 main: run one round of one workload through its block's H1 hook (contract: experiments/h1/README.md "Hook
# contract H1-HOOK v2"; user decision 2026-10-18 "H1 lifetime 구성 변경"). The workload plugin is plugins/pins-<W>.sh: the
# pinned block command, its environment and the file that must carry the hook marker.
# usage: hook.sh <W> r1   <dir> 1   "<mix>=<param> ..."       (levels unknown: computed in mg's lifetime via H1_LEVELS_CMD)
#        hook.sh <W> cont <dir> <n> "<mix>=<param> ..." <levels.tsv>   (rounds 2, 3: levels from round 1)
# env passed on: H1_SETTLE_S (plan), H1_LEVELS_CMD + H1_PLAN/H1_W/H1_LEVELS_OUT (r1),
#   PRETOUCH_DIR, MEASURE_ENV_DIR, H1_SEED_BASE.
# Checks before the block: no FILL_ token in the pins, marker "H1-HOOK v2" in HOOK_FILE, PIN_SHA256 entries match, the
# dir exists and is empty. After the block: rc 0, "SEQUENCE DONE" in the last lines of sequence.log, and <dir>/h1-runs.tsv
# (8 columns: name system mix phase round run_dir steps lifetime) lists per mix exactly:
#   phase slo: hw, pop, mg (r1: hw/pop lifetime "sep" = SLO-only lifetime, mg "cont"; cont mode: all "cont"), steps "-"
#   phase fix: hw, pop (r1 "sep", cont mode "cont"), mg ("cont"), mgoff ("sep": its own lifetime settle -> L2 -> L1,
#              no SLO search, right after the mg lifetime of the mix; user decision 2026-10-18: Megalon 77, no runtime
#              timer switch); steps "<L2 step>,<L1 step>" (measured fixed steps of that run dir's loadgen)
#   every run dir holds loadgen/summary.json and loadgen/steps.jsonl.
set -uo pipefail
W=${1:?} MODE=${2:?} D=${3:?} N=${4:?} ARG=${5:?} LV=${6:-}
H=$(cd "$(dirname "$0")" && pwd)
F=$H/plugins/pins-$W.sh; [ "${H1_DRY:-0}" = 1 ] && F=$H/plugins/pins-stub.sh
stop() { echo "HOOK STOP $W $MODE $N: $*"; exit 1; }
[ -f "$F" ] || stop "no plugin $F"
grep -q "FILL_" "$F" && stop "unpinned ($F has FILL_ tokens; fill after the validation packets pass)"
BLOCK_CMD=() BLOCK_ENV=() HOOK_FILE= PIN_SHA256=
. "$F"
[ ${#BLOCK_CMD[@]} -gt 0 ] && [ -f "$HOOK_FILE" ] || stop "plugin $F: BLOCK_CMD / HOOK_FILE missing"
grep -q "H1-HOOK v2" "$HOOK_FILE" || stop "hook missing: $HOOK_FILE has no 'H1-HOOK v2' marker (workload owner adds the v2 modes)"
if [ -n "$PIN_SHA256" ]; then echo "$PIN_SHA256" | sha256sum --quiet -c - || stop "pinned file hash mismatch"; fi
[ -d "$D" ] && [ -z "$(ls -A "$D")" ] || stop "$D missing or not empty"
[[ "${H1_SETTLE_S:-}" =~ ^[1-9][0-9]*$ ]] || stop "bad H1_SETTLE_S"
XE=(H1_MIXES="$ARG" H1_SEED=$(( ${H1_SEED_BASE:-20261017} + N )) H1_SETTLE_S=$H1_SETTLE_S)
case $MODE in
  r1) [ "$N" = 1 ] || stop "r1 mode is round 1"; : "${H1_LEVELS_CMD:?}" "${H1_PLAN:?}" "${H1_W:?}" "${H1_LEVELS_OUT:?}"
      XE+=(H1_LEVELS_CMD="$H1_LEVELS_CMD" H1_PLAN="$H1_PLAN" H1_W="$H1_W" H1_LEVELS_OUT="$H1_LEVELS_OUT" H1_STAGE_DIR="$D");;
  cont) [[ $N =~ ^[23]$ ]] || stop "cont mode is round 2 or 3"; [ -f "$LV" ] || stop "no levels file"; XE+=(H1_LEVELS="$LV");;
  *) stop "bad mode";;
esac
MIXTAGS=$(for m in $ARG; do echo -n "${m%%=*} "; done)
echo "$(date -Is) hook $W $MODE $N: ${BLOCK_CMD[*]} $D" > "$D/sequence.cmd"
env "${BLOCK_ENV[@]}" H1MODE=$MODE H1_N=$N "${XE[@]}" H1_PARENT_LOCK=H1-main \
  PRETOUCH_DIR="${PRETOUCH_DIR:-}" MEASURE_ENV_DIR="${MEASURE_ENV_DIR:-}" MEASURE_PART_DIR="${MEASURE_PART_DIR:-}" \
  H1_MEASURE_RUN="${H1_MEASURE_RUN:-0}" \
  "${BLOCK_CMD[@]}" "$D" > "$D/sequence.log" 2>&1
RC=$?
[ $RC = 0 ] || stop "block rc $RC ($(grep -m1 'STOP' "$D/sequence.log" || tail -n 1 "$D/sequence.log"))"
tail -n 3 "$D/sequence.log" | grep -q "SEQUENCE DONE" || stop "no SEQUENCE DONE in sequence.log"
[ -f "$D/h1-runs.tsv" ] || stop "no h1-runs.tsv"
python3 -I -B - "$D" "$MODE" "$N" $MIXTAGS <<'EOF' || stop "h1-runs.tsv incomplete"
import json, os, sys
d, mode, n, mixes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
r1 = mode == "r1"
want = {}
for m in mixes:
    for s in ("hw", "pop", "mg"):
        want[(m, s, "slo")] = "sep" if r1 and s != "mg" else "cont"
    for s in ("hw", "pop"):
        want[(m, s, "fix")] = "sep" if r1 else "cont"
    want[(m, "mg", "fix")] = "cont"
    want[(m, "mgoff", "fix")] = "sep"
seen = {}
for line in open(os.path.join(d, "h1-runs.tsv")):
    if not line.strip() or line.startswith("#"):
        continue
    f = line.rstrip("\n").split("\t")
    assert len(f) == 8, f"bad line (v2 needs 8 columns) {line!r}"
    name, s, m, ph, r, rd, steps, life = f
    rd = rd if os.path.isabs(rd) else os.path.join(d, rd)
    assert r == n, f"{name}: round {r} != {n}"
    k = (m, s, ph)
    assert k in want, f"{name}: unexpected {k}"
    assert k not in seen, f"{name}: duplicate {k}"
    assert life == want[k], f"{name}: lifetime {life} != {want[k]}"
    for x in ("summary.json", "steps.jsonl"):
        assert os.path.isfile(os.path.join(rd, "loadgen", x)), f"{name}: no loadgen/{x}"
    if ph == "fix":
        st = steps.split(",")
        assert len(st) == 2 and all(x.isdigit() for x in st), f"{name}: steps '{steps}' (need <L2>,<L1>)"
        have = {j["step"]: j for j in map(json.loads, open(os.path.join(rd, "loadgen", "steps.jsonl")))}
        for x in st:
            assert int(x) in have and have[int(x)]["measure_s"] > 0, f"{name}: step {x} not measured"
    else:
        assert steps == "-", f"{name}: slo steps must be '-'"
    seen[k] = name
assert set(seen) == set(want), f"missing {sorted(set(want) - set(seen))}"
print(f"h1-runs.tsv: {len(seen)} entries OK")
EOF
echo "HOOK OK $W $MODE $N"

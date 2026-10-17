#!/bin/bash
# H1 main: run one phase of one workload through its block's H1 hook (contract: experiments/h1/README.md "Hook
# contract H1-HOOK v1"). The workload plugin is plugins/pins-<W>.sh: the pinned block command, its environment (build
# dirs, guest dirs, Popcorn bundle, Megalon build, harness snapshot) and the file that must carry the hook marker.
# usage: hook.sh <W> slo <dir> <round> "<mix>=<param> ..."
#        hook.sh <W> fix <dir> <rep> <levels.tsv>
# The dir must exist and be empty. Checks before the block: no FILL_ token left in the pins (unpinned = refuse), the
# hook marker "H1-HOOK v1" in HOOK_FILE, every PIN_SHA256 entry ("<sha256>  <file>") matches. After the block:
# rc 0, last "SEQUENCE DONE" line in sequence.log, and <dir>/h1-runs.tsv lists exactly one run per mix x system
# (hw, pop, mg) with this phase and round, each run dir holding loadgen/summary.json and loadgen/steps.jsonl.
set -uo pipefail
W=${1:?} MODE=${2:?} D=${3:?} N=${4:?} ARG=${5:?}
H=$(cd "$(dirname "$0")" && pwd)
F=$H/plugins/pins-$W.sh; [ "${H1_DRY:-0}" = 1 ] && F=$H/plugins/pins-stub.sh
stop() { echo "HOOK STOP $W $MODE $N: $*"; exit 1; }
[ -f "$F" ] || stop "no plugin $F"
grep -q "FILL_" "$F" && stop "unpinned ($F has FILL_ tokens; fill after the validation packets pass)"
BLOCK_CMD=() BLOCK_ENV=() HOOK_FILE= PIN_SHA256=
. "$F"
[ ${#BLOCK_CMD[@]} -gt 0 ] && [ -f "$HOOK_FILE" ] || stop "plugin $F: BLOCK_CMD / HOOK_FILE missing"
grep -q "H1-HOOK v1" "$HOOK_FILE" || stop "hook missing: $HOOK_FILE has no 'H1-HOOK v1' marker (workload owner adds the H1 mode)"
if [ -n "$PIN_SHA256" ]; then echo "$PIN_SHA256" | sha256sum --quiet -c - || stop "pinned file hash mismatch"; fi
[ -d "$D" ] && [ -z "$(ls -A "$D")" ] || stop "$D missing or not empty"
case $MODE in
  slo) [[ $N =~ ^[1-3]$ ]] || stop "bad round"; XE=(H1_MIXES="$ARG" H1_SEED=$(( ${H1_SEED_BASE:-20261017} + N )))
       MIXTAGS=$(for m in $ARG; do echo -n "${m%%=*} "; done);;
  fix) [ -f "$ARG" ] || stop "no levels file"; XE=(H1_LEVELS="$ARG" H1_SEED=$(( ${H1_SEED_BASE:-20261017} + 10 + N )))
       MIXTAGS=$(awk -F'\t' 'NR > 1 { printf "%s ", $1 }' "$ARG");;
  *) stop "bad mode";;
esac
echo "$(date -Is) hook $W $MODE $N: ${BLOCK_CMD[*]} $D" > "$D/sequence.cmd"
env "${BLOCK_ENV[@]}" H1MODE=$MODE H1_N=$N "${XE[@]}" H1_PARENT_LOCK=H1-main \
  PRETOUCH_DIR="${PRETOUCH_DIR:-}" MEASURE_ENV_DIR="${MEASURE_ENV_DIR:-}" \
  "${BLOCK_CMD[@]}" "$D" > "$D/sequence.log" 2>&1
RC=$?
[ $RC = 0 ] || stop "block rc $RC ($(grep -m1 'STOP' "$D/sequence.log" || tail -n 1 "$D/sequence.log"))"
tail -n 3 "$D/sequence.log" | grep -q "SEQUENCE DONE" || stop "no SEQUENCE DONE in sequence.log"
[ -f "$D/h1-runs.tsv" ] || stop "no h1-runs.tsv"
python3 -I -B - "$D" "$MODE" "$N" $MIXTAGS <<'EOF' || stop "h1-runs.tsv incomplete"
import os, sys
d, mode, n, mixes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
seen = {}
for line in open(os.path.join(d, "h1-runs.tsv")):
    if not line.strip() or line.startswith("#"):
        continue
    f = line.rstrip("\n").split("\t")
    assert len(f) == 6, f"bad line {line!r}"
    name, s, m, ph, r, rd = f
    rd = rd if os.path.isabs(rd) else os.path.join(d, rd)
    assert ph == mode and r == n, f"{name}: phase/round {ph}/{r} != {mode}/{n}"
    assert (m, s) not in seen, f"{name}: duplicate {m} {s}"
    for x in ("summary.json", "steps.jsonl"):
        assert os.path.isfile(os.path.join(rd, "loadgen", x)), f"{name}: no loadgen/{x}"
    seen[(m, s)] = name
want = {(m, s) for m in mixes for s in ("hw", "pop", "mg")}
assert set(seen) == want, f"runs {sorted(seen)} != {sorted(want)}"
print(f"h1-runs.tsv: {len(seen)} runs OK")
EOF
echo "HOOK OK $W $MODE $N"

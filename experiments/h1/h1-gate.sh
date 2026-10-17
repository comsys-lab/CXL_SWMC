#!/bin/bash
# H1 Host gate (user decisions 2026-10-18, state/TASKS.md: VM/node0 load must not block measurements, some other Host
# CPU use is acceptable, builds stay forbidden; option (가): node1 measurement CPUs partitioned). New file: the frozen
# validation packets keep experiments/vectordb/host-gate.sh (load-average gate) unchanged.
# usage: h1-gate.sh lock <owner> | unlock <owner>   same lock file and semantics as host-gate.sh (delegated)
#        h1-gate.sh check <log file>                wait until the gate passes (re-probe every 60 s, at most GATE_WAIT_S)
#        h1-gate.sh judge <log file>                one probe of builds + CPU sets only (no partition check; diagnostics/tests)
# env: MEASURE_ENV_DIR (base measure-env state dir), MEASURE_PART_DIR (measure-env-part.sh apply dir: sets.txt),
#   GATE_WAIT_S (1800), SAMPLE_S (5), MEAS_AVG_MAX (10), MEAS_CPU_MAX (50), EMU_AVG_MAX (25)
# One probe passes iff:
#   1. `measure-env-part.sh check MEASURE_ENV_DIR MEASURE_PART_DIR` = PART CHECK PASS (base settings + partition);
#      a failure fails the gate at once (it does not recover by itself);
#   2. no build process (exact command names as host-gate.sh: make cc1 cc1plus ld ld.gold lld cargo rustc ninja cmake conan);
#   3. CPU busy over SAMPLE_S from /proc/stat (1 - (idle+iowait)/total per CPU), sets from MEASURE_PART_DIR/sets.txt:
#        meas (loadgen CPUs, measure.slice): average <= MEAS_AVG_MAX % and every CPU <= MEAS_CPU_MAX %
#        emu  (emulator + vhost threads of both VMs): average <= EMU_AVG_MAX %
#      The gate runs before a loadgen part starts, so our own loadgen is not running during the sample.
#      node0 (VM vCPUs) and the Host housekeeping CPUs (sys) are logged, never judged; load1 is logged only.
# Thresholds (proposal, packet §env): observed idle 2026-10-18 00:40 (VMs up, no servers): meas 0.2 % avg / 0.8 % max,
#   emu 0.0 %. MEAS_AVG_MAX 10 % = 1.6 of 16 CPUs; MEAS_CPU_MAX 50 % catches one foreign single-thread job on one CPU
#   (6 % of the set average); EMU_AVG_MAX 25 % = one of the 4 emulator/vhost CPUs (the coordinator's example value).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
HG=$H/../vectordb/host-gate.sh PART=$H/../../scripts/host/measure-env-part.sh
case "${1:-}" in
  lock|unlock) exec bash "$HG" "$@";;
  check|judge) LOG=${2:?log file};;
  *) echo "usage: h1-gate.sh lock|unlock <owner> | check|judge <log file>"; exit 2;;
esac
GATE_WAIT_S=${GATE_WAIT_S:-1800} SAMPLE_S=${SAMPLE_S:-5}
MEAS_AVG_MAX=${MEAS_AVG_MAX:-10} MEAS_CPU_MAX=${MEAS_CPU_MAX:-50} EMU_AVG_MAX=${EMU_AVG_MAX:-25}
: "${MEASURE_PART_DIR:?MEASURE_PART_DIR = measure-env-part.sh apply dir (sets.txt)}"
SETS=$MEASURE_PART_DIR/sets.txt
MEAS=$(sed -n 's/^meas=//p' "$SETS" 2>/dev/null) EMU=$(sed -n 's/^emu=//p' "$SETS" 2>/dev/null) SYS=$(sed -n 's/^sys=//p' "$SETS" 2>/dev/null)
[ -n "$MEAS" ] && [ -n "$EMU" ] && [ -n "$SYS" ] || { echo "$(date -Is) gate ok=0 sets: $SETS missing meas/emu/sys" | tee -a "$LOG"; exit 1; }
probe() {  # -> prints one log line; rc 0 = pass
  local builds cpu
  builds=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' | tr '\n' ';')
  cpu=$(python3 -I - "$SAMPLE_S" "$MEAS" "$EMU" "$SYS" "$MEAS_AVG_MAX" "$MEAS_CPU_MAX" "$EMU_AVG_MAX" <<'EOF'
import sys, time
dt, meas, emu, sysset = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
mavg_max, mcpu_max, eavg_max = map(float, sys.argv[5:8])
def rng(x):
    o = []
    for p in x.split(","):
        a, _, b = p.partition("-"); o += range(int(a), int(b or a) + 1)
    return o
def rd():
    d = {}
    for l in open("/proc/stat"):
        if l.startswith("cpu") and l[3].isdigit():
            f = l.split(); v = list(map(int, f[1:])); d[int(f[0][3:])] = (sum(v), v[3] + v[4])
    return d
a = rd(); time.sleep(dt); b = rd()
def busy(c):
    t = b[c][0] - a[c][0]; i = b[c][1] - a[c][1]
    return 100.0 * (1 - i / t) if t > 0 else 0.0
node1 = set(rng(meas) + rng(emu) + rng(sysset))
node0 = [c for c in sorted(b) if c not in node1]
st = {}
for name, cs in (("meas", rng(meas)), ("emu", rng(emu)), ("sys", rng(sysset)), ("other", node0)):
    v = [busy(c) for c in cs] or [0.0]
    st[name] = (sum(v) / len(v), max(v), max(zip(v, cs))[1] if cs else -1)
ok = st["meas"][0] <= mavg_max and st["meas"][1] <= mcpu_max and st["emu"][0] <= eavg_max
print(f"{int(ok)} meas_avg={st['meas'][0]:.1f}% meas_max={st['meas'][1]:.1f}%@cpu{st['meas'][2]} "
      f"emu_avg={st['emu'][0]:.1f}% emu_max={st['emu'][1]:.1f}% sys_avg={st['sys'][0]:.1f}% (not judged) "
      f"other_avg={st['other'][0]:.1f}% (node0/VMs, not judged) limits meas<={mavg_max:g}%/cpu<={mcpu_max:g}% emu<={eavg_max:g}%")
EOF
)
  local cok=${cpu%% *} ok=0
  [ -z "$builds" ] && [ "$cok" = 1 ] && ok=1
  echo "$(date -Is) gate ok=$ok builds=[$builds] ${cpu#* } load1=$(cut -d' ' -f1 /proc/loadavg) (not judged) lock=[$(cat "${LOCK:-/home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock}" 2>/dev/null)]"
  [ $ok = 1 ]
}
if [ "$1" = judge ]; then line=$(probe); rc=$?; echo "$line" | tee -a "$LOG"; exit $rc; fi
: "${MEASURE_ENV_DIR:?MEASURE_ENV_DIR = base measure-env state dir}"
deadline=$(( $(date +%s) + GATE_WAIT_S ))
while :; do
  out=$(bash "$PART" check "$MEASURE_ENV_DIR" "$MEASURE_PART_DIR" 2>&1); prc=$?
  { echo "$(date -Is) measure-env-part: check $MEASURE_ENV_DIR $MEASURE_PART_DIR rc=$prc"; printf '%s\n' "$out" | sed 's/^/measure-env-part: /'; } >> "$LOG"
  if [ $prc != 0 ] || ! printf '%s\n' "$out" | tail -n 1 | grep -q '^PART CHECK PASS'; then
    echo "$(date -Is) gate ok=0 part=FAIL" >> "$LOG"; echo "h1 gate: measure-env-part check did not pass (see $LOG)"; exit 1
  fi
  line=$(probe); rc=$?; echo "$line part=PASS" >> "$LOG"
  [ $rc = 0 ] && exit 0
  [ $(date +%s) -lt $deadline ] || { echo "h1 gate: not quiet within ${GATE_WAIT_S}s (see $LOG)"; exit 1; }
  sleep 60
done

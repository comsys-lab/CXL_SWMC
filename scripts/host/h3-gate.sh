#!/bin/bash
# H3 measurement gate for N = 2..8 VMs (VM8 topology). Same calling convention and judgement as
# experiments/h1/h1-gate.sh, which is NOT changed (H1 pins its sha256):
#   h3-gate.sh check <out file>      rc 0 = pass, else STOP. Appends the full check log to <out file>.
#   h3-gate.sh lock|unlock <owner>   = experiments/vectordb/host-gate.sh lock|unlock (MEASUREMENT.lock)
# check, in a loop until it passes or 1800 s (h1-gate's GATE_WAIT_S) are over, one probe per minute:
#   1. EXPECT_RUNNING=... scripts/host/measure-env-n.sh check MEASURE_ENV_DIR MEASURE_PART_DIR must end in
#      "PART CHECK PASS" (measure-env-part.sh check = base settings + partition, plus emulator/vhost/vCPU pins of
#      every running cxl_vm0..7 and the running set = EXPECT_RUNNING); a FAIL stops at once;
#   2. `h1-gate.sh judge <out file>`: h1-gate's own probe (no Host build processes; measure CPUs avg <= 10 %,
#      any measure CPU <= 50 %, emulator CPUs avg <= 25 % over 5 s; thresholds frozen in h1-gate.sh).
# Required env: EXPECT_RUNNING ("cxl_vm0 ... cxl_vm<N-1>"), MEASURE_ENV_DIR (base measure-env state dir),
# MEASURE_PART_DIR (measure-env-part.sh apply dir with sets.txt). Host self-test only: H3_DRY=1 H3_WAIT_S=<s>.
# Limitation at N=8: the 4 emulator/vhost CPUs (16,48,17,49) serve 8 VMs; the gate probes before a run (VMs idle),
# so the 25 % emulator limit judges idle background, not the run itself.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
HG=$H/../../experiments/vectordb/host-gate.sh H1G=$H/../../experiments/h1/h1-gate.sh MEN=$H/measure-env-n.sh
case "${1:-}" in
  lock|unlock) exec bash "$HG" "$@";;
  check) LOG=${2:?out file};;
  *) echo "usage: h3-gate.sh check <out file> | lock|unlock <owner>"; exit 2;;
esac
: "${EXPECT_RUNNING:?EXPECT_RUNNING (cxl_vm0 ... cxl_vm<N-1>) required}"
: "${MEASURE_ENV_DIR:?MEASURE_ENV_DIR = base measure-env state dir}"
: "${MEASURE_PART_DIR:?MEASURE_PART_DIR = measure-env-part.sh apply dir (sets.txt)}"
WAIT=1800
if [ -n "${H3_WAIT_S:-}" ]; then
  [ "${H3_DRY:-0}" = 1 ] || { echo "$(date -Is) h3 gate ok=0 override of H3_WAIT_S refused (H3_DRY=1 only)" | tee -a "$LOG"; exit 1; }
  WAIT=$H3_WAIT_S
fi
echo "$(date -Is) h3 gate start: EXPECT_RUNNING=[$EXPECT_RUNNING] base=$MEASURE_ENV_DIR part=$MEASURE_PART_DIR h3-gate=$(sha256sum < "$0" | cut -c1-16) measure-env-n=$(sha256sum < "$MEN" | cut -c1-16) h1-gate=$(sha256sum < "$H1G" | cut -c1-16)" >> "$LOG"
deadline=$(( $(date +%s) + WAIT ))
while :; do
  out=$(EXPECT_RUNNING="$EXPECT_RUNNING" bash "$MEN" check "$MEASURE_ENV_DIR" "$MEASURE_PART_DIR" 2>&1); prc=$?
  { echo "$(date -Is) measure-env-n: check rc=$prc"; printf '%s\n' "$out" | sed 's/^/measure-env-n: /'; } >> "$LOG"
  if [ $prc != 0 ] || ! printf '%s\n' "$out" | tail -n 1 | grep -q '^PART CHECK PASS'; then
    echo "$(date -Is) h3 gate ok=0 part=FAIL" >> "$LOG"; echo "h3 gate: measure-env-n check did not pass (see $LOG)"; exit 1
  fi
  env -u GATE_WAIT_S -u SAMPLE_S -u MEAS_AVG_MAX -u MEAS_CPU_MAX -u EMU_AVG_MAX -u H1_DRY \
    MEASURE_PART_DIR="$MEASURE_PART_DIR" bash "$H1G" judge "$LOG" > /dev/null; jrc=$?
  if [ $jrc = 0 ]; then echo "$(date -Is) h3 gate ok=1 part=PASS" >> "$LOG"; echo "h3 gate PASS"; exit 0; fi
  [ "$(date +%s)" -lt $deadline ] || { echo "$(date -Is) h3 gate ok=0 not quiet within ${WAIT}s" >> "$LOG"; echo "h3 gate: not quiet within ${WAIT}s (see $LOG)"; exit 1; }
  sleep 60
done

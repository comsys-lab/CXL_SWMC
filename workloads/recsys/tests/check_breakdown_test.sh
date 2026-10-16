#!/bin/bash
# Host unit test of experiments/recsys/check_breakdown.py for the page MSI label (no Popcorn kernel needed): takes a
# measurement dir from session_host_test.sh (all-HWcc, plain), relabels a copy as Popcorn-poll and adds synthetic
# per-thread swmc and instr/serve counters to its stats snapshots, then runs breakdown.py + check_breakdown.py.
# Expect: PASS with the counters; FAIL when sys.swmc.instr.serve.* is absent (counters not readable), FAIL for an
# unknown label. usage: check_breakdown_test.sh <measurement dir (e.g. .../s/fixed)> <work dir (new)>
set -uo pipefail
SRC=$1 WD=$2
X=$(cd "$(dirname "$0")/../../../experiments/recsys" && pwd)
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"
FAIL=0
mk() {  # mk <dir> <with instr 0|1>
  cp -r "$SRC" "$1"; rm -f "$1/breakdown.csv"
  sed -i 's/^system=.*/system=Popcorn-poll/' "$1/manifest.txt"
  for f in "$1"/loadgen/stats/step*-t*.txt; do
    case $f in *-begin-*) m=1;; *) m=2;; esac
    { echo "thr.rs-serve.swmc.read_fault_ns=$((m * 9000000))"; echo "thr.rs-serve.swmc.read_msg_wait_ns=$((m * 5000000))"
      echo "thr.rs-serve.swmc.read_local_wait_ns=$((m * 1000000))"; echo "thr.rs-serve.swmc.write_fault_ns=0"
      echo "thr.rs-serve.swmc.read_faults=$((m * 100))"; echo "thr.rs-serve.swmc.read_transactions=$((m * 90))"
      echo "thr.rs-update.swmc.write_fault_ns=$((m * 7000000))"; echo "irq.TLB=$((m * 50))"; echo "kthr.cxl_recv/0.cpu_ticks=$((m * 10))"
      if [ "$2" = 1 ]; then echo "sys.swmc.instr.serve.unmap_ns=$((m * 400000))"; echo "sys.swmc.instr.serve.mkclean_ns=$((m * 100000))"; fi
    } >> "$f"
  done
  python3 "$X/breakdown.py" "$1" --out "$1/breakdown.csv"
}
mk "$WD/msi" 1; python3 "$X/check_breakdown.py" "$WD/msi" || { echo "CHECK FAIL: msi with counters"; FAIL=1; }
mk "$WD/msi-noinstr" 0; python3 "$X/check_breakdown.py" "$WD/msi-noinstr" && { echo "CHECK FAIL: msi without instr accepted"; FAIL=1; }
cp -r "$WD/msi" "$WD/bad-label"; sed -i 's/^system=.*/system=Other/' "$WD/bad-label/manifest.txt"
python3 "$X/check_breakdown.py" "$WD/bad-label" && { echo "CHECK FAIL: unknown label accepted"; FAIL=1; }
cut -d, -f1-12 "$WD/msi/breakdown.csv"
[ $FAIL = 0 ] && echo "CHECK_BREAKDOWN TEST PASS" || { echo "CHECK_BREAKDOWN TEST FAIL"; exit 1; }

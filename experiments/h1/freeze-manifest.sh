#!/bin/bash
# Freeze the H1 main code manifest (reports/H1-main-packet.md §5, verifier MED-3): sha256 of every file h1-main.sh
# runs or calls on the Host. h1-main.sh refuses a stage unless the manifest's own sha256 equals H1_MANIFEST_SHA (the
# value recorded in the packet) and every listed file matches (`sha256sum -c` from the CXL_SWMC root), and refuses
# files in experiments/h1 that the manifest does not list.
# usage: freeze-manifest.sh <out file (must not exist)>
#        freeze-manifest.sh --list        print the file list only (self-test)
# Lists (paths relative to CXL_SWMC): every file in experiments/h1 (incl. plugins/pins-*.sh and test/), the analysis
# scripts collect.py calls (experiments/analysis/{v6_common,v6_fig1_curves,v6_fig2_split,paper_style}.py,
# experiments/loadgen/{export_csv,stats_delta}.py), the gates it delegates to (experiments/vectordb/{host-gate,
# pretouch-gate}.sh) and scripts/host/{measure-env,measure-env-part,measure-run}.sh. The workload hook files are pinned
# by each pins-<w>.sh (PIN_SHA256, checked by hook.sh), so they are covered through the pins files.
# Refuses when a listed path has uncommitted changes (the manifest must describe a commit).
set -uo pipefail
OUT=${1:?out file}
[ "$OUT" = --list ] || [ ! -e "$OUT" ] || { echo "FREEZE REFUSED: $OUT exists"; exit 2; }
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R" || exit 2
LIST=$( { find experiments/h1 -type f -not -path '*/__pycache__/*' -not -name '*.pyc'
  printf '%s\n' experiments/analysis/v6_common.py experiments/analysis/v6_fig1_curves.py experiments/analysis/v6_fig2_split.py \
    experiments/analysis/paper_style.py experiments/loadgen/export_csv.py experiments/loadgen/stats_delta.py \
    experiments/vectordb/host-gate.sh experiments/vectordb/pretouch-gate.sh \
    scripts/host/measure-env.sh scripts/host/measure-env-part.sh scripts/host/measure-run.sh; } | sort -u)
for f in $LIST; do [ -f "$f" ] || { echo "FREEZE REFUSED: missing $f"; exit 2; }; done
[ "$OUT" = --list ] && { printf '%s\n' $LIST; exit 0; }
dirty=$(git status --porcelain -- $LIST)
[ -z "$dirty" ] || { echo "FREEZE REFUSED: uncommitted changes:"; echo "$dirty"; exit 2; }
mkdir -p "$(dirname "$OUT")"
sha256sum $LIST > "$OUT"
echo "FROZEN $(wc -l < "$OUT") files at CXL_SWMC $(git rev-parse --short HEAD) -> $OUT sha256 $(sha256sum < "$OUT" | cut -c1-64)"

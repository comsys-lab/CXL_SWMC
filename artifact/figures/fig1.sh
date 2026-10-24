#!/bin/bash
# Fig 1 (Hypothesis 1): normalized p99 search latency vs searches/s, one panel per mix (u10, u50, u90), All-HWcc,
#   Popcorn, Megalon on 2 VMs x 16 vCPU (fp32 vector DB). Also: the requests/s variant (x = search + update requests/s),
#   the band variant (mean of all runs, min-max band; secondary) and the max-under-SLO table (mean [min-max] over runs,
#   ratio to All-HWcc).
#   Curve: run 1's SLO-search points below 0.9 x base + knee-sweep fixed-rate points from 0.9 x base, drawn while
#   achieved search/s still rises (stop at the first > 5 % fall-back); y = p99 / All-HWcc's run-1 p99 at its lowest rate.
# Inputs: stage h1-slo-fixed (runs 1..N: slo_summary.csv + the run-1 loadgen steps behind it) and stage knee-sweep
#   (group knee-sweep-h1 + plan). Outputs: fig1-h1-latency{,-req,-band}.{pdf,png,csv}, fig1-h1-max-under-slo.csv,
#   numbers-fig1.json, fig1.manifest.txt.
# usage: fig1.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--knee DIR] [--plan CSV]
#                [--evidence-map OLD=NEW] [--out DIR] [--dry-run]          (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig1 AF_NEEDS="h1 knee-h1"
AF_STAGE_LIST="h1-slo-fixed:fig1,fig2,fig3 knee-sweep:fig1,fig4"
AF_TITLE="Fig 1: H1 latency-throughput (search/s and requests/s; band variant), max under SLO"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"

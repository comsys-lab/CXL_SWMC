#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lmdb_common.sh"

lmdb_init_base
echo OUT_DIR="${OUT_DIR}"

usage() {
	lmdb_usage_overwriteopen
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

lmdb_setup_existing_benchmark_run \
	"run_overwriteopen" \
	"overwriteopen" \
	"overwriteopen.log" \
	"[run] ARRIVAL_RATES=${ARRIVAL_RATES}, WARMUP_SEC=${WARMUP_SEC}"
lmdb_run_existing_benchmark \
	"Run overwriteopen ..." \
	"overwriteopen" \
	--arrival_rates="${ARRIVAL_RATES}" \
	--warmup_sec="${WARMUP_SEC}" \
	--generator_cpu=0 \
	--generator_rt_prio=80
lmdb_extract_and_log_one_line \
	"Extract overwriteopen summary ..." \
	'^[[:space:]]*overwriteopen[[:space:]]+:' \
	"overwriteopen"

echo "[run] Completed. Summary: ${summary_log}"

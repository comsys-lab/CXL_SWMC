#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lmdb_common.sh"

lmdb_init_base
echo OUT_DIR="${OUT_DIR}"

usage() {
	lmdb_usage_overwritebatch
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

lmdb_setup_existing_benchmark_run "run_overwritebatch" "overwritebatch_only" "overwritebatch.log"
lmdb_run_existing_benchmark "Run overwritebatch ..." "overwritebatch" --writes_per_second "${WRITES_PER_SECOND}" --batch "${BATCH_SIZE}"
lmdb_extract_and_log_one_line "Extract overwritebatch summary ..." '^overwritebatch\s+:' "overwritebatch"

echo "[run] Completed. Summary: ${summary_log}"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lmdb_common.sh"

lmdb_init_base
echo OUT_DIR="${OUT_DIR}"

usage() {
	lmdb_usage_overwrite
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

lmdb_setup_existing_benchmark_run "run_overwrite" "overwrite_only" "overwrite.log"
lmdb_run_existing_benchmark "Run overwrite ..." "overwrite" --writes_per_second "${WRITES_PER_SECOND}"
lmdb_extract_and_log_one_line "Extract overwrite summary ..." '^overwrite\s+:' "overwrite"

echo "[run] Completed. Summary: ${summary_log}"

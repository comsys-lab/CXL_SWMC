#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lmdb_common.sh"

OUT_DIR_WAS_SET=0
if [[ -n "${OUT_DIR+x}" ]]; then
	OUT_DIR_WAS_SET=1
fi

lmdb_init_base
if [[ "${OUT_DIR_WAS_SET}" == "0" ]]; then
	OUT_DIR="${ROOT_DIR}/results"
fi

usage() {
	lmdb_usage_build
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

lmdb_setup_build_run "run_build" "%Y%m%d_%H%M%S"
lmdb_run_build_fillseq_and_extract

echo "[run] Completed. Summary: ${summary_log}"

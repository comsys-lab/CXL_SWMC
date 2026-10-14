#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lmdb_common.sh"

lmdb_init_base
echo OUT_DIR="${OUT_DIR}"

WRITES_PER_SECOND="${WRITES_PER_SECOND:-0}"

usage() {
	lmdb_usage_readwhilewriting
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

lmdb_setup_existing_benchmark_run \
	"run_readwhilewriting" \
	"readwhilewriting" \
	"readwhilewriting.log" \
	"[run] WRITES_PER_SECOND=${WRITES_PER_SECOND}"
lmdb_run_existing_benchmark "Run readwhilewriting ..." "readwhilewriting" --writes_per_second "${WRITES_PER_SECOND}"

lmdb_log "${summary_log}" "[run] Step3. Extract readwhilewriting summary ..."
writer_line="$(lmdb_extract_last_match '^writer\s+:' "${bench_log}")"
rw_line="$(lmdb_extract_last_match '^readwhilewriting\s+:' "${bench_log}")"
if [[ -n "${writer_line}" ]]; then
	echo "${writer_line}" | tee -a "${summary_log}"
else
	echo "[warn] writer summary line not found in ${bench_log}" | tee -a "${summary_log}"
fi

if [[ -n "${rw_line}" ]]; then
	echo "${rw_line}" | tee -a "${summary_log}"
else
	echo "[warn] readwhilewriting summary line not found in ${bench_log}" | tee -a "${summary_log}"
fi

echo "[run] Completed. Summary: ${summary_log}"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBBENCH_DIR="${SCRIPT_DIR}/third_party/LMDB/dbbench"
DBBENCH_BIN="${DBBENCH_BIN:-${DBBENCH_DIR}/bin/t_lmdb}"

NUM="${NUM:-1000}"
VALUE_SIZE="${VALUE_SIZE:-128}"
KEY_SIZE="${KEY_SIZE:-16}"
THREADS="${THREADS:-2}"
READOPEN_RATES="${READOPEN_RATES:-100,200}"
WRITES_PER_SECOND="${WRITES_PER_SECOND:-10000}"
TMP_ROOT="${LMDB_SMOKE_ROOT:-}"

IFS=',' read -r READOPEN_RATE_1 READOPEN_RATE_2 _ <<< "${READOPEN_RATES}"
if [[ -z "${READOPEN_RATE_1:-}" || -z "${READOPEN_RATE_2:-}" ]]; then
	echo "[smoke][fail] READOPEN_RATES must contain at least two comma-separated rates" >&2
	exit 1
fi

created_tmp=0
if [[ -z "${TMP_ROOT}" ]]; then
	TMP_ROOT="$(mktemp -d -p /tmp lmdb-smoke.XXXXXX)"
	created_tmp=1
fi

cleanup() {
	if [[ "${LMDB_SMOKE_KEEP:-0}" == "1" ]]; then
		echo "[smoke] Keeping temporary directory: ${TMP_ROOT}"
	elif [[ "${created_tmp}" == "1" && -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
		rm -rf -- "${TMP_ROOT}"
	fi
}
trap cleanup EXIT

DB_PATH="${TMP_ROOT}/db"
BUILD_LOG="${TMP_ROOT}/fillseq.log"
READOPEN_LOG="${TMP_ROOT}/readopen.log"
OVERWRITE_LOG="${TMP_ROOT}/overwrite.log"
OVERWRITEOPEN_LOG="${TMP_ROOT}/overwriteopen.log"

assert_log() {
	local pattern="$1"
	local log_file="$2"
	local desc="$3"

	if ! grep -Eq "${pattern}" "${log_file}"; then
		echo "[smoke][fail] ${desc}" >&2
		echo "[smoke][fail] Missing pattern: ${pattern}" >&2
		echo "[smoke][fail] Log: ${log_file}" >&2
		sed -n '1,220p' "${log_file}" >&2
		exit 1
	fi
}

echo "[smoke] Building dbbench binary if needed ..."
make -C "${DBBENCH_DIR}" >/dev/null

if [[ ! -x "${DBBENCH_BIN}" ]]; then
	echo "[smoke][fail] dbbench binary not executable: ${DBBENCH_BIN}" >&2
	exit 1
fi

echo "[smoke] Temporary directory: ${TMP_ROOT}"
echo "[smoke] Step 1/4: build small LMDB with fillseq ..."
"${DBBENCH_BIN}" \
	--db="${DB_PATH}" \
	--num="${NUM}" \
	--threads=1 \
	--max_threads=8 \
	--value_size="${VALUE_SIZE}" \
	--key_size="${KEY_SIZE}" \
	--writemap=0 \
	--metasync=1 \
	--readahead=1 \
	--histogram=0 \
	--benchmarks=fillseq \
	> "${BUILD_LOG}" 2>&1
assert_log '^fillseq[[:space:]]+:' "${BUILD_LOG}" "fillseq summary should be present"
assert_log "Entries:[[:space:]]+${NUM}" "${BUILD_LOG}" "fillseq should use the small NUM setting"

echo "[smoke] Step 2/4: verify readopen multi-rate path ..."
"${DBBENCH_BIN}" \
	--db="${DB_PATH}" \
	--use_existing_db=1 \
	--num="${NUM}" \
	--threads="${THREADS}" \
	--max_threads=8 \
	--duration=1 \
	--value_size="${VALUE_SIZE}" \
	--key_size="${KEY_SIZE}" \
	--writemap=0 \
	--metasync=1 \
	--readahead=1 \
	--histogram=0 \
	--arrival_rates="${READOPEN_RATES}" \
	--warmup_sec=0 \
	--generator_cpu=-1 \
	--generator_rt_prio=0 \
	--benchmarks=readopen \
	> "${READOPEN_LOG}" 2>&1
assert_log "^\[phase 1\] arrival_rate=${READOPEN_RATE_1}[[:space:]]+workers=${THREADS}" "${READOPEN_LOG}" "readopen phase 1 should use first arrival rate"
assert_log "^\[phase 2\] arrival_rate=${READOPEN_RATE_2}[[:space:]]+workers=${THREADS}" "${READOPEN_LOG}" "readopen phase 2 should use second arrival rate"
assert_log 'processed=[1-9][0-9]*' "${READOPEN_LOG}" "readopen should process requests"
assert_log 'p50=.*p99=.*p99\.9=.*p99\.99=' "${READOPEN_LOG}" "readopen latency percentiles should be reported"

echo "[smoke] Step 3/4: verify overwrite write-rate path ..."
"${DBBENCH_BIN}" \
	--db="${DB_PATH}" \
	--use_existing_db=1 \
	--num="${NUM}" \
	--threads=1 \
	--max_threads=8 \
	--duration=1 \
	--value_size="${VALUE_SIZE}" \
	--key_size="${KEY_SIZE}" \
	--writemap=0 \
	--metasync=1 \
	--readahead=1 \
	--histogram=0 \
	--writes_per_second="${WRITES_PER_SECOND}" \
	--benchmarks=overwrite \
	> "${OVERWRITE_LOG}" 2>&1
assert_log '^overwrite[[:space:]]+:' "${OVERWRITE_LOG}" "overwrite summary should be present"
assert_log 'ops/sec' "${OVERWRITE_LOG}" "overwrite throughput should be reported"

echo "[smoke] Step 4/4: verify overwriteopen multi-rate path ..."
"${DBBENCH_BIN}" \
	--db="${DB_PATH}" \
	--use_existing_db=1 \
	--num="${NUM}" \
	--threads=1 \
	--max_threads=8 \
	--duration=1 \
	--value_size="${VALUE_SIZE}" \
	--key_size="${KEY_SIZE}" \
	--writemap=0 \
	--metasync=1 \
	--readahead=1 \
	--histogram=0 \
	--arrival_rates="${READOPEN_RATES}" \
	--warmup_sec=0 \
	--generator_cpu=-1 \
	--generator_rt_prio=0 \
	--benchmarks=overwriteopen \
	> "${OVERWRITEOPEN_LOG}" 2>&1
assert_log "^\[phase 1\] arrival_rate=${READOPEN_RATE_1}[[:space:]]+workers=1" "${OVERWRITEOPEN_LOG}" "overwriteopen phase 1 should use first arrival rate"
assert_log "^\[phase 2\] arrival_rate=${READOPEN_RATE_2}[[:space:]]+workers=1" "${OVERWRITEOPEN_LOG}" "overwriteopen phase 2 should use second arrival rate"
assert_log 'processed=[1-9][0-9]*' "${OVERWRITEOPEN_LOG}" "overwriteopen should process requests"
assert_log 'p50=.*p99=.*p99\.9=.*p99\.99=' "${OVERWRITEOPEN_LOG}" "overwriteopen latency percentiles should be reported"

echo "[smoke] PASS"
echo "[smoke] Logs:"
echo "  ${BUILD_LOG}"
echo "  ${READOPEN_LOG}"
echo "  ${OVERWRITE_LOG}"
echo "  ${OVERWRITEOPEN_LOG}"

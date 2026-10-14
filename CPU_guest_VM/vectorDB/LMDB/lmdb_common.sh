#!/usr/bin/env bash

lmdb_init_base() {
	ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	DBBENCH_BIN="${DBBENCH_BIN:-${ROOT_DIR}/third_party/LMDB/dbbench/bin/t_lmdb}"
	DB_PATH="${DB_PATH:-${ROOT_DIR}/Dataset/lmdb_7M_4KB}"

	VALUE_SIZE="${VALUE_SIZE:-4096}" # 왠만해선 fixed
	KEY_SIZE="${KEY_SIZE:-16}" # 왠만해선 fixed
	NUM="${NUM:-7000000}" # 왠만해선 fixed
	THREADS="${THREADS:-1}" # 바뀌는 parameter
	DURATION="${DURATION:-0}" # 바뀌는 parameter
	ARRIVAL_RATES="${ARRIVAL_RATES:-0}" # 바뀌는 parameter (open-loop 전용)
	WARMUP_SEC="${WARMUP_SEC:-10}" # open-loop benchmark 전용

	WRITEMAP="${WRITEMAP:-1}" # famfs에서는 WRITEMAP=0으로 해야됨
	METASYNC="${METASYNC:-1}" # 이건 1이 기본적으로 fixed
	READAHEAD="${READAHEAD:-1}" # 이것도 1이 기본적으로 fixed
	NOLOCK="${NOLOCK:-0}" # famfs에서는 NOLOCK=1으로 해야됨
	HISTOGRAM="${HISTOGRAM:-1}" # HISTOGRAM은 기본적으로 1

    day="$(date +%y%m%d)"
	SUFFIX="${SUFFIX:-default}"
	OUT_DIR="${OUT_DIR:-${ROOT_DIR}/results/${day}_${SUFFIX}}"
}

lmdb_require_dbbench() {
	if [[ ! -x "${DBBENCH_BIN}" ]]; then
		echo "dbbench binary not found or not executable: ${DBBENCH_BIN}" >&2
		echo "Run setup first: ${ROOT_DIR}/setup_winefs_dbbench.sh" >&2
		exit 1
	fi
}

lmdb_require_nonzero() {
	local var_name="$1"
	local var_value="$2"

	if [[ "${var_value}" == "0" ]]; then
		echo "${var_name} must be greater than 0." >&2
		exit 1
	fi
}

lmdb_prepare_out_dir() {
	mkdir -p "${OUT_DIR}"
}

lmdb_preflight() {
	lmdb_require_dbbench
	lmdb_prepare_out_dir
	lmdb_require_nonzero "NUM" "${NUM}"
}

lmdb_make_run_dir() {
	local prefix="$1"
	local ts_format="${2:-%H%M%S}"
	local ts
	ts="$(date +"${ts_format}")"

	run_dir="${OUT_DIR}/${prefix}/${ARRIVAL_RATES}/${ts}"
	mkdir -p "${run_dir}"
}

lmdb_build_common_flags() {
	common_flags=(
		--db "${DB_PATH}"
		--value_size "${VALUE_SIZE}"
		--key_size "${KEY_SIZE}"
		--writemap "${WRITEMAP}"
		--metasync "${METASYNC}"
		--readahead "${READAHEAD}"
		--nolock "${NOLOCK}"
		--histogram "${HISTOGRAM}"
	)
	if [[ "${DURATION}" != "0" ]]; then
		common_flags+=(--duration "${DURATION}")
	fi
}

lmdb_log() {
	local summary_log="$1"
	local msg="$2"
	echo "${msg}" | tee -a "${summary_log}"
}

lmdb_log_common_run_info() {
	local summary_log="$1"
	local mode="$2"
	local extra_line="${3:-}"

	lmdb_log "${summary_log}" "[run] MODE=${mode}"
	lmdb_log "${summary_log}" "[run] DB_PATH=${DB_PATH}"
	lmdb_log "${summary_log}" "[run] NUM=${NUM}, VALUE_SIZE=${VALUE_SIZE}, KEY_SIZE=${KEY_SIZE}"
	lmdb_log "${summary_log}" "[run] THREADS=${THREADS}, DURATION=${DURATION}"
	if [[ -n "${extra_line}" ]]; then
		lmdb_log "${summary_log}" "${extra_line}"
	fi
	lmdb_log "${summary_log}" "[run] WRITEMAP=${WRITEMAP}, METASYNC=${METASYNC}, READAHEAD=${READAHEAD}, NOLOCK=${NOLOCK}"
	lmdb_log "${summary_log}" "[run] Logs: ${run_dir}"
}

lmdb_setup_existing_benchmark_run() {
	local run_prefix="$1"
	local mode="$2"
	local log_name="$3"
	local extra_line="${4:-}"

	lmdb_preflight
	lmdb_make_run_dir "${run_prefix}"

	bench_log="${run_dir}/${log_name}"
	summary_log="${run_dir}/summary.txt"

	lmdb_build_common_flags
	lmdb_log_common_run_info "${summary_log}" "${mode}" "${extra_line}"
	lmdb_log "${summary_log}" "[run] Step1. Check existing DB ..."
	lmdb_ensure_existing_db "${summary_log}"
}

lmdb_setup_build_run() {
	local run_prefix="${1:-run_build}"
	local ts_format="${2:-%Y%m%d_%H%M%S}"

	lmdb_preflight
	lmdb_make_run_dir "${run_prefix}" "${ts_format}"

	bench_log="${run_dir}/build.log"
	summary_log="${run_dir}/summary.txt"

	common_flags=(
		--db "${DB_PATH}"
		--value_size "${VALUE_SIZE}"
		--key_size "${KEY_SIZE}"
		--writemap "${WRITEMAP}"
		--metasync "${METASYNC}"
		--readahead "${READAHEAD}"
	)

	lmdb_log "${summary_log}" "[run] MODE=build_only"
	lmdb_log "${summary_log}" "[run] DB_PATH=${DB_PATH}"
	lmdb_log "${summary_log}" "[run] NUM=${NUM}, VALUE_SIZE=${VALUE_SIZE}, KEY_SIZE=${KEY_SIZE}"
	lmdb_log "${summary_log}" "[run] THREADS=${THREADS}"
	lmdb_log "${summary_log}" "[run] Logs: ${run_dir}"
	lmdb_log "${summary_log}" "[run] Step0. Ensure DB path exists"
	mkdir -p "${DB_PATH}"
	lmdb_log "${summary_log}" "[run] Step1. Remove previous DB files"
	rm -f "${DB_PATH}/data.mdb" "${DB_PATH}/lock.mdb"
}

lmdb_run_build_fillseq_and_extract() {
	lmdb_log "${summary_log}" "[run] Step2. Build DB with fillseq (${NUM} ops) ..."
	"${DBBENCH_BIN}" "${common_flags[@]}" \
		--num "${NUM}" \
		--threads "${THREADS}" \
		--max_threads=510 \
		--benchmarks fillseq \
		> "${bench_log}" 2>&1

	lmdb_extract_and_log_one_line "Extract fillseq summary ..." '^fillseq\s+:' "fillseq"
}

lmdb_run_existing_benchmark() {
	local step_msg="$1"
	local benchmark="$2"
	shift 2

	lmdb_log "${summary_log}" "[run] Step2. ${step_msg}"
	"${DBBENCH_BIN}" "${common_flags[@]}" \
		--use_existing_db 1 \
		--num "${NUM}" \
		--threads "${THREADS}" \
		"$@" \
		--benchmarks "${benchmark}" \
		> "${bench_log}" 2>&1
}

lmdb_extract_and_log_one_line() {
	local step_msg="$1"
	local pattern="$2"
	local tag="$3"

	lmdb_log "${summary_log}" "[run] Step3. ${step_msg}"
	local line
	line="$(lmdb_extract_last_match "${pattern}" "${bench_log}")"
	if [[ -n "${line}" ]]; then
		echo "${line}" | tee -a "${summary_log}"
	else
		echo "[warn] ${tag} summary line not found in ${bench_log}" | tee -a "${summary_log}"
	fi
}

lmdb_ensure_existing_db() {
	local summary_log="$1"

	if [[ ! -f "${DB_PATH}/data.mdb" ]]; then
		lmdb_log "${summary_log}" "[run] Existing DB not found at ${DB_PATH}/data.mdb"
		lmdb_log "${summary_log}" "[run] Build DB first: ${ROOT_DIR}/run_build_lmdb.sh"
		exit 1
	fi
}

lmdb_extract_last_match() {
	local pattern="$1"
	local source_log="$2"
	grep -E "${pattern}" "${source_log}" | tail -n 1 || true
}

lmdb_usage_header() {
	local script_name="$1"
	cat <<EOF
Usage:
	./${script_name}
	DB_PATH=/mnt/famfs/lmdb OUT_DIR=./results ./${script_name}

Optional env:
	DBBENCH_BIN=<path to t_lmdb>
	DB_PATH=<lmdb path>
	OUT_DIR=<output directory>
	NUM=7000000 VALUE_SIZE=4096 KEY_SIZE=16
EOF
}

lmdb_usage_build() {
	lmdb_usage_header "run_build_lmdb.sh"
	cat <<'EOF'
	THREADS=1
	WRITEMAP=1 METASYNC=1 READAHEAD=1

Behavior:
	1) Remove existing DB files in DB_PATH
	2) Build LMDB with fillseq for NUM operations
	3) Extract fillseq summary line to summary.txt
EOF
}

lmdb_usage_overwrite() {
	lmdb_usage_header "run_overwrite_lmdb.sh"
	cat <<'EOF'
	THREADS=1
	DURATION=0 (seconds, 0 disables duration limit)
	WRITEMAP=1 METASYNC=1 READAHEAD=1 NOLOCK=0 HISTOGRAM=0

Behavior:
	1) Use existing DB (build separately with run_build_lmdb.sh)
	2) Run overwrite (bounded by NUM and optional DURATION)
	3) Extract overwrite summary line to summary.txt
EOF
}

lmdb_usage_overwriteopen() {
	lmdb_usage_header "run_overwriteopen_lmdb.sh"
	cat <<'EOF'
	THREADS=1 (recommended; LMDB has a single-writer model)
	DURATION=<seconds> (required by dbbench overwriteopen)
	ARRIVAL_RATES=100,1000,10000
	WARMUP_SEC=10
	WRITEMAP=1 METASYNC=1 READAHEAD=1 NOLOCK=0 HISTOGRAM=0

Behavior:
	1) Use existing DB (build separately with run_build_lmdb.sh)
	2) Run overwriteopen with open-loop Poisson arrivals
	3) Extract the last overwriteopen phase summary line to summary.txt
EOF
}

lmdb_usage_overwritebatch() {
	lmdb_usage_header "run_overwritebatch_lmdb.sh"
	cat <<'EOF'
	THREADS=1
	DURATION=0 (seconds, 0 disables duration limit)
	WRITEMAP=1 METASYNC=1 READAHEAD=1 NOLOCK=0 HISTOGRAM=0

Behavior:
	1) Use existing DB (build separately with run_build_lmdb.sh)
	2) Run overwritebatch (bounded by NUM and optional DURATION)
	3) Extract overwritebatch summary line to summary.txt
EOF
}

lmdb_usage_read() {
	lmdb_usage_header "run_read_lmdb.sh"
	cat <<'EOF'
	THREADS=1
	DURATION=0 (seconds, 0 disables duration limit)
	WRITEMAP=1 METASYNC=1 READAHEAD=1 NOLOCK=0 HISTOGRAM=0

Behavior:
	1) Use existing DB (build separately with run_build_lmdb.sh)
	2) Run readrandom (bounded by NUM and optional DURATION)
	3) Extract readrandom summary line to summary.txt
EOF
}

lmdb_usage_readwhilewriting() {
	lmdb_usage_header "run_readwhilewriting_lmdb.sh"
	cat <<'EOF'
	THREADS=1 (reader thread count; writer thread 1 is added internally)
	DURATION=0 (seconds, 0 disables duration limit)
	WRITES_PER_SECOND=0 (0 means no writer rate limit)
	WRITEMAP=1 METASYNC=1 READAHEAD=1 NOLOCK=0 HISTOGRAM=0

Behavior:
	1) Use existing DB (build separately with run_build_lmdb.sh)
	2) Run readwhilewriting (bounded by NUM and optional DURATION)
	3) Extract writer/readwhilewriting summary lines to summary.txt
EOF
}

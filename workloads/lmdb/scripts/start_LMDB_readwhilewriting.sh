#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="NO_MTRR"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=10
ITER_THREADS=(1 4 16 64 128)
################################

##### misc settings #####
WRITEMAP=0
NOLOCK=0
SCRIPT_DIR="/home/comsys/CXLSharedMemVM/LMDB"
#########################

cd "${SCRIPT_DIR}"

export SUFFIX DB_PATH WRITEMAP NOLOCK DURATION

for THREADS in "${ITER_THREADS[@]}"; do
    echo "Running with THREADS=${THREADS}..."
    export THREADS
    ./run_readwhilewriting_lmdb.sh
done


#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="NO_MTRR"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=20
ITER_THREADS=(16)
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
    ./run_read_lmdb.sh
done


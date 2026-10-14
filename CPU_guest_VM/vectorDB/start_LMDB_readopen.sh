#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="Popcorn_24GB_THREAD_1_test"
# DB_PATH="/home/comsys/CXLSharedMemVM/LMDB/Dataset/lmdb_7M_4KB"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=120
THREADS=1
ARRIVAL_RATES="10,100,200,400"
WARMUP_SEC=10
################################

##### misc settings #####
WRITEMAP=0
NOLOCK=1
SCRIPT_DIR="/home/comsys/CXLSharedMemVM/LMDB"
#########################

cd "${SCRIPT_DIR}"

export SUFFIX DB_PATH WRITEMAP NOLOCK DURATION THREADS ARRIVAL_RATES WARMUP_SEC

./run_readopen_lmdb.sh

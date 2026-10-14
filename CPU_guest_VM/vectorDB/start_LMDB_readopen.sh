#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="POPCORN_4KB_72GB"
# DB_PATH="/home/comsys/CXLSharedMemVM/LMDB/Dataset/lmdb_7M_4KB"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=120
THREADS=15
ARRIVAL_RATES="100,8800000,8900000,9000000,9100000,9200000,9300000"
WARMUP_SEC=30
################################

##### misc settings #####
WRITEMAP=0
NOLOCK=1
SCRIPT_DIR="/home/comsys/CXLSharedMemVM/LMDB"
#########################

cd "${SCRIPT_DIR}"

export SUFFIX DB_PATH WRITEMAP NOLOCK DURATION THREADS ARRIVAL_RATES WARMUP_SEC

./run_readopen_lmdb.sh

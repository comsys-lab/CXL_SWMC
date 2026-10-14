#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="test_batchwrite"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=10
WRITES_PER_SECOND=0
BATCH_SIZE=1000
################################

##### misc settings #####
WRITEMAP=1
LMDB_NO_FTRUNCATE=1
NOLOCK=1
SCRIPT_DIR="/home/comsys/CXLSharedMemVM/LMDB"
#########################

cd "${SCRIPT_DIR}"

export SUFFIX DB_PATH WRITEMAP NOLOCK DURATION LMDB_NO_FTRUNCATE WRITES_PER_SECOND BATCH_SIZE

./run_overwritebatch_lmdb.sh


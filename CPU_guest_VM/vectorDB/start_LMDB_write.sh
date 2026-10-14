#!/bin/bash
set -euo pipefail

##### Directory and file paths #####
SUFFIX="DE_STIJL_72GB"
DB_PATH="/mnt/famfs/lmdb_7M_4KB"
####################################

##### Benchmark parameters #####
DURATION=1800
WRITES_PER_SECOND=0
################################

##### misc settings #####
WRITEMAP=0
LMDB_NO_FTRUNCATE=1
NOLOCK=1
SCRIPT_DIR="/home/comsys/CXLSharedMemVM/LMDB"
#########################

cd "${SCRIPT_DIR}"

export SUFFIX DB_PATH WRITEMAP NOLOCK DURATION LMDB_NO_FTRUNCATE WRITES_PER_SECOND

./run_overwrite_lmdb.sh


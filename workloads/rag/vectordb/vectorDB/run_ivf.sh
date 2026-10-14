#!/bin/bash

HNSW_DIR="/mnt/famfs/vectorDB/indexbin"
# FLAT_INDEX_DIR="/mnt/famfs/vectorDB/flat_index.bin"
FLAT_INDEX_DIR="/mnt/famfs/vectorDB/flat_index_1M.bin"
PORT=8080
NPROBE=16
BATCHSIZE=32
KNOWHERE_THREADS=16
SEARCH_WORKER_THREADS=16

sudo VDB_KNOWHERE_THREAD_POOL_SIZE=${KNOWHERE_THREADS} \
    VDB_NPROBE=${NPROBE} \
    VDB_BATCH_SIZE=${BATCHSIZE} \
    VDB_BATCH_TIMEOUT_MS=1 \
    VDB_SEARCH_WORKER_THREADS=${SEARCH_WORKER_THREADS} \
    ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT} ivf
# gdb --args ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT}

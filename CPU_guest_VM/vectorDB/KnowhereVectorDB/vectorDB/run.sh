#!/bin/bash

HNSW_DIR="/mnt/famfs/vectorDB/indexbin"
# FLAT_INDEX_DIR="/mnt/famfs/vectorDB/flat_index.bin"
FLAT_INDEX_DIR="/mnt/famfs/vectorDB/flat_index_1M.bin"
PORT=8080

sudo ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT}
# gdb --args ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT}

#!/bin/bash

HNSW_DIR="./indexbin"
FLAT_INDEX_DIR="./flat_index_1M.bin"
PORT=8080

sudo ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT}
# gdb --args ./build/vector_db ${HNSW_DIR} ${FLAT_INDEX_DIR} ${PORT}

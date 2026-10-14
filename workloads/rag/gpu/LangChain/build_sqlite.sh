#!/bin/bash

DATASET_PATH="/home/comsys/CXL_SWMC/GPU/Dataset/PubMed_bge_28000000_sorted"  # Replace with your dataset path
SQLITE_DB_PATH="./Data/PubMed_28M.db"  # Replace with your desired SQLite DB path
NUM_RECORDS=28000000  # Adjust based on your dataset size

mkdir -p $(dirname ${SQLITE_DB_PATH})

# Build SQLite database from downloaded Dataset
python3 build_sqlite.py --dataset-path ${DATASET_PATH} \
                        --sqlite-db-path ${SQLITE_DB_PATH} \
                        --num-records ${NUM_RECORDS}
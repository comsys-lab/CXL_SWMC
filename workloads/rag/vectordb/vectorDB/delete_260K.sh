#!/bin/bash

# for test
# python3 /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/bulk_delete_insert.py \
#   --base-url http://127.0.0.1:8080 \
#   --dataset-dir /home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted \
#   --start-file data-00188-of-00198.arrow \
#   --delete-count 1000 \
#   --insert-count 1000 \
#   --delete-max-id 26020203 \
#   --delete-mode random \
#   --workers 32

# for 260K delete and insert
python3 /home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/bulk_delete_insert.py \
  --base-url http://127.0.0.1:8080 \
  --dataset-dir /home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted \
  --start-file data-00188-of-00198.arrow \
  --delete-count 260000 \
  --insert-count 0 \
  --delete-max-id 26020203 \
  --delete-mode random \
  --workers 32
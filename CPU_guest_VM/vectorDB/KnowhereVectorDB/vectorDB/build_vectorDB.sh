#!/bin/bash

# build 결과를 보고, 하나의 binary 파일에 몇 개의 vector를 넣을지 확인하고, arrow 파일의 index 개수를 다르게 해 가며 build 할 것.

./build/build_vectorDB --dim 768 --nb 6500000 --nq 1000 --k 10 --first-file-idx 143 \
                    --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_modified" \
                    --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/hnsw_index_6500k_3.bin"
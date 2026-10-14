#!/bin/bash

# build 결과를 보고, 하나의 binary 파일에 몇 개의 vector를 넣을지 확인하고, arrow 파일의 index 개수를 다르게 해 가며 build 할 것.

# ./build/build_vectorDB --dim 768 --nb 6500000 --nq 1000 --k 10 \
#                     --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
#                     --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/hnsw_index_6500k_0.bin"

./build/build_vectorDB --dim 768 --nb 6500000 --nq 1000 --k 10 --first-file-idx 46 \
                    --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
                    --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/hnsw_index_6500k_1.bin"

./build/build_vectorDB --dim 768 --nb 6500000 --nq 1000 --k 10 --first-file-idx 92 \
                    --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
                    --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/hnsw_index_6500k_2.bin"

./build/build_vectorDB --dim 768 --nb 6500000 --nq 1000 --k 10 --first-file-idx 136 \
                    --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
                    --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/hnsw_index_6500k_3.bin"

# the file to make 26M vectors is 0~187, so we need to use after 188 when isert more vectors to flat index
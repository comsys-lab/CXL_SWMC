#!/bin/bash

./build/build_vectorDB_ivf \
  --dim 768 \
  --nb 6500000 \
  --nlist 8192 \
  --nprobe 32 \
  --first-file-idx 0 \
  --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
  --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/ivf_index_6500k_0.bin"

./build/build_vectorDB_ivf \
  --dim 768 \
  --nb 6500000 \
  --nlist 8192 \
  --nprobe 32 \
  --first-file-idx 47 \
  --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
  --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/ivf_index_6500k_1.bin"

  ./build/build_vectorDB_ivf \
  --dim 768 \
  --nb 6500000 \
  --nlist 8192 \
  --nprobe 32 \
  --first-file-idx 94 \
  --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
  --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/ivf_index_6500k_2.bin"

  ./build/build_vectorDB_ivf \
  --dim 768 \
  --nb 6500000 \
  --nlist 8192 \
  --nprobe 32 \
  --first-file-idx 141 \
  --dataset-dir "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted" \
  --index-file "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/vectorDB/ivf_index_6500k_3.bin"
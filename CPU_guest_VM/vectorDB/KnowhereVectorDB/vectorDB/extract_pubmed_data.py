#!/usr/bin/env python3
"""
PubMed BGE 데이터셋에서 chunk_id와 embedding을 추출해서 C++에서 읽을 수 있는 바이너리 형태로 저장
"""

import numpy as np
from datasets import load_from_disk
import struct
import os

def extract_pubmed_data(dataset_path, output_dir, max_samples=None):
    """
    PubMed BGE 데이터셋에서 데이터를 추출해서 바이너리 파일로 저장
    
    Args:
        dataset_path: PubMed 데이터셋 경로
        output_dir: 출력 디렉토리
        max_samples: 최대 샘플 수 (None이면 전체)
    """
    print(f"Loading dataset from {dataset_path}...")
    
    # 데이터셋 로드
    dataset = load_from_disk(dataset_path)
    
    print(f"Dataset loaded. Total samples: {len(dataset)}")
    print(f"Features: {dataset.features}")
    
    # 첫 번째 샘플로 임베딩 차원 확인
    first_sample = dataset[0]
    embedding_dim = len(first_sample['embedding'])
    print(f"Embedding dimension: {embedding_dim}")
    
    # 샘플 수 결정
    total_samples = len(dataset)
    if max_samples and max_samples < total_samples:
        total_samples = max_samples
    
    print(f"Processing {total_samples} samples...")
    
    # 출력 디렉토리 생성
    os.makedirs(output_dir, exist_ok=True)
    
    # 메타데이터 저장
    meta_file = os.path.join(output_dir, "metadata.txt")
    with open(meta_file, 'w') as f:
        f.write(f"samples={total_samples}\n")
        f.write(f"dimension={embedding_dim}\n")
        f.write(f"dtype=float32\n")
    
    # 임베딩 데이터 저장 (바이너리)
    embeddings_file = os.path.join(output_dir, "embeddings.bin")
    chunk_ids_file = os.path.join(output_dir, "chunk_ids.bin")
    
    print("Extracting embeddings and chunk_ids...")
    
    with open(embeddings_file, 'wb') as emb_f, open(chunk_ids_file, 'wb') as id_f:
        for i in range(total_samples):
            sample = dataset[i]
            
            # chunk_id 저장 (int64)
            chunk_id = sample['chunk_id']
            id_f.write(struct.pack('<q', chunk_id))  # little-endian int64
            
            # embedding 저장 (float32 array)
            embedding = np.array(sample['embedding'], dtype=np.float32)
            emb_f.write(embedding.tobytes())
            
            if (i + 1) % 10000 == 0:
                print(f"Processed {i + 1}/{total_samples} samples...")
    
    print(f"Data extraction completed!")
    print(f"Files saved to {output_dir}:")
    print(f"  - metadata.txt: {os.path.getsize(meta_file)} bytes")
    print(f"  - embeddings.bin: {os.path.getsize(embeddings_file)} bytes")
    print(f"  - chunk_ids.bin: {os.path.getsize(chunk_ids_file)} bytes")
    
    # 몇 개 샘플 확인
    print("\nFirst 5 samples:")
    for i in range(min(5, total_samples)):
        sample = dataset[i]
        print(f"  Sample {i}: chunk_id={sample['chunk_id']}, embedding_shape={len(sample['embedding'])}")

if __name__ == "__main__":
    dataset_path = "/home/comsys/CXLSharedMemVM/Knowheretest/Dataset/PubMed_bge/PubMed_bge_100000"
    output_dir = "/home/comsys/CXLSharedMemVM/Knowheretest/vectorDB/data"
    
    # 100,000개 샘플 중 50,000개만 사용 (테스트용)
    max_samples = 50000
    
    extract_pubmed_data(dataset_path, output_dir, max_samples)

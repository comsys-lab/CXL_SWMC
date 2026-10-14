#pragma once

#include <iostream>
#include <vector>
#include <memory>
#include <string>
#include <atomic>
#include <algorithm>

// 분리된 인덱스 헤더들
#include "flat_index.h"
#include "hnsw_index.h"
#include "ivf_index.h"

// VectorDB 메인 클래스
class VectorDB {
private:
    static constexpr size_t VECTOR_DIM = 768;
    static constexpr int DEFAULT_K = 10;
    
    std::string hnsw_index_dir_;
    std::string flat_index_path_;
    std::string index_type_;
    bool use_hnsw_;
    
    // HNSW 인덱스 관리자
    std::unique_ptr<HNSWIndexManager> hnsw_manager_;
    
    // IVF 인덱스 관리자
    std::unique_ptr<IVFIndexManager> ivf_manager_;
    
    // Append-only flat 인덱스
    std::unique_ptr<AppendOnlyFlatIndex> flat_index_;
    
    // ID 생성기
    std::atomic<uint64_t> next_id_;

public:
    VectorDB(const std::string& index_dir,
             const std::string& flat_path,
             const std::string& index_type = "hnsw");
    ~VectorDB();
    
    bool initialize();
    
    // 벡터 삽입
    bool insertVector(const std::vector<float>& vector, uint64_t& assigned_id);
    
    // 벡터 검색
    std::vector<SearchResult> searchVectors(const std::vector<float>& query, int k = DEFAULT_K);
    
    // Exact Search (HNSW + Flat 모두 brute-force)
    std::vector<SearchResult> exactSearchVectors(const std::vector<float>& query, int k = DEFAULT_K);
    
    // 배치 벡터 검색 (버퍼 재사용)
    std::vector<std::vector<SearchResult>> searchVectorsBatch(
        const std::vector<std::vector<float>>& queries, 
        int k,
        std::vector<float>& reused_batch_buffer);
    
    // 배치 Exact Search
    std::vector<std::vector<SearchResult>> exactSearchVectorsBatch(
        const std::vector<std::vector<float>>& queries,
        int k = DEFAULT_K);

    // Soft delete (HNSW only)
    bool softDelete(uint64_t id);
    bool restoreDeleted(uint64_t id);
    bool isDeleted(uint64_t id) const;
    
    // 상태 확인
    size_t getFlatIndexCount() const;
    bool isFlatIndexFull() const;
    
    void shutdown();

private:
    std::vector<SearchResult> mergeSearchResults(
    const std::vector<SearchResult>& ann_results,
        const std::vector<SearchResult>& flat_results,
        int k) const;
};

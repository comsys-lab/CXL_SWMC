#pragma once

#include <iostream>
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <filesystem>
#include <future>
#include <cstdlib>

// Knowhere headers
#include <knowhere/index/index_factory.h>
#include <knowhere/dataset.h>
#include <knowhere/config.h>
#include <knowhere/comp/index_param.h>
#include <knowhere/version.h>

// 검색 결과 구조 (flat_index.h와 공유)
struct SearchResult;

// HNSW 인덱스 관리 클래스
class HNSWIndexManager {
private:
    static constexpr size_t DEFAULT_VECTOR_DIM = 768;
    static constexpr int DEFAULT_EF = 400;
    
    std::vector<knowhere::Index<knowhere::IndexNode>> indices_;
    std::vector<std::string> index_paths_;
    std::vector<int> index_beg_ids_;  // 각 인덱스의 시작 ID 오프셋
    size_t vector_dim_;
    std::string index_dir_;

public:
    HNSWIndexManager(const std::string& index_dir, size_t vector_dim = DEFAULT_VECTOR_DIM);
    ~HNSWIndexManager();
    
    // 초기화
    bool initialize();
    
    // 단일 쿼리 검색 (모든 인덱스 검색 후 병합)
    std::vector<SearchResult> search(const std::vector<float>& query, int k) const;
    
    // 단일 쿼리 Exact Search (BruteForce)
    std::vector<SearchResult> exactSearch(const std::vector<float>& query, int k) const;
    
    // 배치 쿼리 검색
    std::vector<std::vector<SearchResult>> searchBatch(
        const std::vector<std::vector<float>>& queries, 
        int k,
        std::vector<float>& reused_batch_buffer) const;
    
    // 배치 쿼리 Exact Search
    std::vector<std::vector<SearchResult>> exactSearchBatch(
        const std::vector<std::vector<float>>& queries,
        int k) const;
    
    // 상태 조회
    size_t getIndexCount() const { return indices_.size(); }
    size_t getTotalVectorCount() const;
    const std::vector<std::string>& getIndexPaths() const { return index_paths_; }
    
    // Raw 데이터 확인
    bool hasRawData() const;
    
private:
    bool loadIndices();
    std::vector<SearchResult> searchSingleIndex(size_t index_idx, 
                                                const std::vector<float>& query, 
                                                int k) const;
};

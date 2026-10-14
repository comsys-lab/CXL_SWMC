#pragma once

#include <iostream>
#include <vector>
#include <memory>
#include <string>
#include <mutex>
#include <shared_mutex>
#include <atomic>
#include <thread>
#include <future>
#include <fstream>
#include <filesystem>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// Knowhere headers
#include <knowhere/index/index_factory.h>
#include <knowhere/dataset.h>
#include <knowhere/config.h>
#include <knowhere/comp/index_param.h>
#include <knowhere/version.h>

// 벡터 데이터 구조
struct VectorData {
    std::vector<float> vector;
    uint64_t id;
    
    VectorData() : id(0) {}
    VectorData(const std::vector<float>& vec, uint64_t vector_id) 
        : vector(vec), id(vector_id) {}
};

// 검색 결과 구조
struct SearchResult {
    uint64_t id;
    float distance;
    
    SearchResult() : id(0), distance(0.0f) {}
    SearchResult(uint64_t vector_id, float dist) : id(vector_id), distance(dist) {}
};

// Append-only flat 인덱스 클래스
class AppendOnlyFlatIndex {
private:
    static constexpr size_t MAX_VECTORS = 100000;  // 최대 벡터 수
    static constexpr size_t VECTOR_DIM = 384;      // 벡터 차원
    
    std::string file_path_;
    int fd_;
    float* mapped_data_;  // mmap된 벡터 데이터
    uint64_t* mapped_ids_;  // mmap된 ID 데이터
    std::atomic<size_t> current_count_;
    size_t max_capacity_;
    std::mutex write_mutex_;

public:
    AppendOnlyFlatIndex(const std::string& file_path);
    ~AppendOnlyFlatIndex();
    
    bool initialize();
    bool insert(const VectorData& vector_data);
    std::vector<SearchResult> bruteForceSearch(const std::vector<float>& query, int k) const;
    size_t getCurrentCount() const { return current_count_.load(); }
    bool isFull() const { return current_count_.load() >= max_capacity_; }
    void cleanup();
};

// VectorDB 메인 클래스
class VectorDB {
private:
    static constexpr size_t VECTOR_DIM = 384;
    static constexpr int DEFAULT_K = 10;
    
    std::string hnsw_index_path_;
    std::string flat_index_path_;
    
    // HNSW 인덱스
    knowhere::Index<knowhere::IndexNode> hnsw_index_;
    
    // Append-only flat 인덱스
    std::unique_ptr<AppendOnlyFlatIndex> flat_index_;
    
    // 동시성 제어
    mutable std::shared_mutex hnsw_mutex_;  // HNSW 읽기/쓰기 제어
    
    // ID 생성기
    std::atomic<uint64_t> next_id_;

public:
    VectorDB(const std::string& hnsw_path, const std::string& flat_path);
    ~VectorDB();
    
    bool initialize();
    
    // 벡터 삽입
    bool insertVector(const std::vector<float>& vector, uint64_t& assigned_id);
    
    // 벡터 검색
    std::vector<SearchResult> searchVectors(const std::vector<float>& query, int k = DEFAULT_K);
    
    // 상태 확인
    size_t getFlatIndexCount() const;
    bool isFlatIndexFull() const;
    
    void shutdown();

private:
    bool loadHNSWIndex();
    std::vector<SearchResult> mergeSearchResults(
        const std::vector<SearchResult>& hnsw_results,
        const std::vector<SearchResult>& flat_results,
        int k) const;
};

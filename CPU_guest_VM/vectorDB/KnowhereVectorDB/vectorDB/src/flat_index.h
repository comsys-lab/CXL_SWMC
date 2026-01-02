#pragma once

#include <iostream>
#include <vector>
#include <string>
#include <mutex>
#include <atomic>
#include <cstring>
#include <cmath>
#include <filesystem>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// 검색 결과 구조 (vector_db.h와 공유)
struct SearchResult {
    uint64_t id;
    float distance;
    
    SearchResult() : id(0), distance(0.0f) {}
    SearchResult(uint64_t vector_id, float dist) : id(vector_id), distance(dist) {}
};

// 벡터 데이터 구조
struct VectorData {
    std::vector<float> vector;
    uint64_t id;
    
    VectorData() : id(0) {}
    VectorData(const std::vector<float>& vec, uint64_t vector_id) 
        : vector(vec), id(vector_id) {}
};

// mmap 파일 헤더 구조
struct FlatIndexHeader {
    uint64_t magic_number;    // 파일 포맷 식별자 (0x4649445800000000 = "FIDX")
    uint64_t version;         // 파일 포맷 버전 (현재 1)
    uint64_t vector_dim;      // 벡터 차원
    uint64_t max_vectors;     // 최대 벡터 개수
    uint64_t current_count;   // 현재 저장된 벡터 개수
    uint64_t reserved[3];     // 미래 확장용 (총 64바이트)
};

// Append-only flat 인덱스 클래스
class AppendOnlyFlatIndex {
private:
    static constexpr uint64_t MAGIC_NUMBER = 0x4649445800000000ULL;  // "FIDX"
    static constexpr uint64_t VERSION = 1;
    static constexpr size_t DEFAULT_MAX_VECTORS = 1000000;
    static constexpr size_t DEFAULT_VECTOR_DIM = 768;
    
    std::string file_path_;
    int fd_;
    FlatIndexHeader* mapped_header_;  // mmap된 헤더
    float* mapped_data_;              // mmap된 벡터 데이터
    uint64_t* mapped_ids_;            // mmap된 ID 데이터
    size_t vector_dim_;               // 벡터 차원 (런타임)
    size_t max_capacity_;             // 최대 용량 (런타임)
    std::mutex write_mutex_;

public:
    AppendOnlyFlatIndex(const std::string& file_path,
                        size_t vector_dim = DEFAULT_VECTOR_DIM,
                        size_t max_vectors = DEFAULT_MAX_VECTORS);
    ~AppendOnlyFlatIndex();
    
    bool initialize();
    bool insert(const VectorData& vector_data);
    std::vector<SearchResult> bruteForceSearch(const std::vector<float>& query, int k) const;
    
    // 상태 조회
    size_t getCurrentCount() const { 
        return mapped_header_ ? mapped_header_->current_count : 0; 
    }
    
    bool isFull() const { 
        return mapped_header_ && mapped_header_->current_count >= max_capacity_; 
    }
    
    size_t getVectorDim() const { return vector_dim_; }
    size_t getMaxCapacity() const { return max_capacity_; }
    
    void cleanup();
};

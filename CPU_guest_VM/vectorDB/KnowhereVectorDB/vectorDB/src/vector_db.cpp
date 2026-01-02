#include "vector_db.h"
#include <algorithm>
#include <future>

// VectorDB 구현
VectorDB::VectorDB(const std::string& hnsw_dir, const std::string& flat_path)
    : hnsw_index_dir_(hnsw_dir), flat_index_path_(flat_path), next_id_(100000000) {
}

VectorDB::~VectorDB() {
    shutdown();
}

bool VectorDB::initialize() {
    std::cout << "=== VectorDB 초기화 ===" << std::endl;
    
    // HNSW 인덱스 매니저 초기화
    hnsw_manager_ = std::make_unique<HNSWIndexManager>(hnsw_index_dir_, VECTOR_DIM);
    if (!hnsw_manager_->initialize()) {
        std::cerr << "Failed to initialize HNSW index manager" << std::endl;
        return false;
    }
    
    // Flat 인덱스 초기화
    flat_index_ = std::make_unique<AppendOnlyFlatIndex>(flat_index_path_, VECTOR_DIM, 1000000);
    if (!flat_index_->initialize()) {
        std::cerr << "Failed to initialize flat index" << std::endl;
        return false;
    }

    std::cout << "VectorDB 초기화 완료" << std::endl;
    std::cout << "- HNSW 인덱스 개수: " << hnsw_manager_->getIndexCount() << std::endl;
    for (size_t i = 0; i < hnsw_manager_->getIndexPaths().size(); ++i) {
        std::cout << "  " << i << ": " << hnsw_manager_->getIndexPaths()[i] << std::endl;
    }
    std::cout << "- HNSW 전체 벡터 수: " << hnsw_manager_->getTotalVectorCount() << std::endl;
    std::cout << "- Flat 인덱스: " << flat_index_path_ << " (" 
              << flat_index_->getCurrentCount() << " vectors)" << std::endl;
    
    return true;
}

bool VectorDB::insertVector(const std::vector<float>& vector, uint64_t& assigned_id) {
    if (vector.size() != VECTOR_DIM) {
        std::cerr << "Vector dimension mismatch: " << vector.size() 
                  << " != " << VECTOR_DIM << std::endl;
        return false;
    }
    
    if (flat_index_->isFull()) {
        std::cerr << "Flat index is full, cannot insert more vectors" << std::endl;
        return false;
    }
    
    // ID 할당
    assigned_id = next_id_.fetch_add(1);
    
    // Flat 인덱스에 삽입
    VectorData vector_data(vector, assigned_id);
    bool success = flat_index_->insert(vector_data);
    
    if (success) {
        std::cout << "Vector inserted with ID: " << assigned_id << std::endl;
    }
    
    return success;
}

std::vector<SearchResult> VectorDB::searchVectors(const std::vector<float>& query, int k) {
    if (query.size() != VECTOR_DIM) {
        std::cerr << "Query dimension mismatch..." << std::endl;
        return {};
    }

    // 1. HNSW 인덱스 검색 (비동기)
    auto hnsw_future = std::async(std::launch::async, [this, &query, k]() {
        return hnsw_manager_->search(query, k);
    });

    // 2. Flat 인덱스 검색 (비동기)
    auto flat_future = std::async(std::launch::async, [this, &query, k]() {
        return flat_index_->bruteForceSearch(query, k);
    });

    // 3. 결과 수집
    std::vector<SearchResult> hnsw_results = hnsw_future.get();
    std::vector<SearchResult> flat_results = flat_future.get();

    // 4. 결과 병합
    return mergeSearchResults(hnsw_results, flat_results, k);
}

std::vector<std::vector<SearchResult>> VectorDB::searchVectorsBatch(
    const std::vector<std::vector<float>>& queries, 
    int k,
    std::vector<float>& reused_batch_buffer) {
    
    if (queries.empty()) {
        return {};
    }
    
    size_t batch_size = queries.size();
    
    // 모든 쿼리의 차원 확인
    for (const auto& query : queries) {
        if (query.size() != VECTOR_DIM) {
            std::cerr << "Query dimension mismatch in batch..." << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }
    
    // 1. HNSW 배치 검색 (비동기)
    auto hnsw_future = std::async(std::launch::async, [this, &queries, k, &reused_batch_buffer]() {
        return hnsw_manager_->searchBatch(queries, k, reused_batch_buffer);
    });
    
    // 2. Flat 인덱스 배치 검색 (비동기)
    auto flat_future = std::async(std::launch::async, [this, &queries, k]() {
        std::vector<std::vector<SearchResult>> flat_results;
        flat_results.reserve(queries.size());
        
        for (const auto& query : queries) {
            flat_results.push_back(flat_index_->bruteForceSearch(query, k));
        }
        return flat_results;
    });
    
    // 3. 결과 수집
    std::vector<std::vector<SearchResult>> hnsw_results = hnsw_future.get();
    std::vector<std::vector<SearchResult>> flat_results = flat_future.get();
    
    // 4. 각 쿼리별로 결과 병합
    std::vector<std::vector<SearchResult>> results(batch_size);
    for (size_t query_idx = 0; query_idx < batch_size; ++query_idx) {
        results[query_idx] = mergeSearchResults(hnsw_results[query_idx], flat_results[query_idx], k);
    }
    
    return results;
}

std::vector<SearchResult> VectorDB::exactSearchVectors(const std::vector<float>& query, int k) {
    if (query.size() != VECTOR_DIM) {
        std::cerr << "Query dimension mismatch..." << std::endl;
        return {};
    }

    std::cout << "Performing exact search (brute-force)..." << std::endl;

    // 1. HNSW 인덱스 Exact Search (비동기)
    auto hnsw_future = std::async(std::launch::async, [this, &query, k]() {
        return hnsw_manager_->exactSearch(query, k);
    });

    // 2. Flat 인덱스 검색 (이미 brute-force) (비동기)
    auto flat_future = std::async(std::launch::async, [this, &query, k]() {
        return flat_index_->bruteForceSearch(query, k);
    });

    // 3. 결과 수집
    std::vector<SearchResult> hnsw_results = hnsw_future.get();
    std::vector<SearchResult> flat_results = flat_future.get();

    std::cout << "HNSW exact search: " << hnsw_results.size() << " results" << std::endl;
    std::cout << "Flat search: " << flat_results.size() << " results" << std::endl;

    // 4. 결과 병합
    return mergeSearchResults(hnsw_results, flat_results, k);
}

std::vector<std::vector<SearchResult>> VectorDB::exactSearchVectorsBatch(
    const std::vector<std::vector<float>>& queries, int k) {
    
    if (queries.empty()) {
        return {};
    }
    
    size_t batch_size = queries.size();
    
    // 모든 쿼리의 차원 확인
    for (const auto& query : queries) {
        if (query.size() != VECTOR_DIM) {
            std::cerr << "Query dimension mismatch in batch..." << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }
    
    std::cout << "Performing exact batch search (brute-force) on " << batch_size << " queries..." << std::endl;
    
    // 1. HNSW 인덱스 Exact Batch Search (비동기)
    auto hnsw_future = std::async(std::launch::async, [this, &queries, k]() {
        return hnsw_manager_->exactSearchBatch(queries, k);
    });
    
    // 2. Flat 인덱스 배치 검색 (비동기)
    auto flat_future = std::async(std::launch::async, [this, &queries, k]() {
        std::vector<std::vector<SearchResult>> flat_results;
        flat_results.reserve(queries.size());
        
        for (const auto& query : queries) {
            flat_results.push_back(flat_index_->bruteForceSearch(query, k));
        }
        return flat_results;
    });
    
    // 3. 결과 수집
    std::vector<std::vector<SearchResult>> hnsw_results = hnsw_future.get();
    std::vector<std::vector<SearchResult>> flat_results = flat_future.get();
    
    // 4. 각 쿼리별로 결과 병합
    std::vector<std::vector<SearchResult>> results(batch_size);
    for (size_t query_idx = 0; query_idx < batch_size; ++query_idx) {
        results[query_idx] = mergeSearchResults(hnsw_results[query_idx], flat_results[query_idx], k);
    }
    
    std::cout << "Exact batch search completed" << std::endl;
    
    return results;
}

std::vector<SearchResult> VectorDB::mergeSearchResults(
    const std::vector<SearchResult>& hnsw_results,
    const std::vector<SearchResult>& flat_results,
    int k) const {
    
    std::vector<SearchResult> merged_results;
    merged_results.reserve(hnsw_results.size() + flat_results.size());
    
    // 모든 결과를 합치기
    for (const auto& result : hnsw_results) {
        merged_results.push_back(result);
    }
    for (const auto& result : flat_results) {
        merged_results.push_back(result);
    }
    
    // 거리에 따라 정렬
    std::partial_sort(merged_results.begin(), 
                     merged_results.begin() + std::min(k, static_cast<int>(merged_results.size())),
                     merged_results.end(),
                     [](const SearchResult& a, const SearchResult& b) {
                         return a.distance < b.distance;
                     });

    // 상위 k개만 반환
    if (static_cast<int>(merged_results.size()) > k) {
        merged_results.resize(k);
    }
    
    return merged_results;
}

size_t VectorDB::getFlatIndexCount() const {
    return flat_index_->getCurrentCount();
}

bool VectorDB::isFlatIndexFull() const {
    return flat_index_->isFull();
}

void VectorDB::shutdown() {
    std::cout << "VectorDB 종료 중..." << std::endl;
    
    if (flat_index_) {
        flat_index_.reset();
    }
    
    std::cout << "VectorDB 종료 완료" << std::endl;
}

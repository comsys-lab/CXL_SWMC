#include "vector_db.h"
#include <algorithm>
#include <cstring>
#include <cmath>

// AppendOnlyFlatIndex 구현
AppendOnlyFlatIndex::AppendOnlyFlatIndex(const std::string& file_path)
    : file_path_(file_path), fd_(-1), mapped_data_(nullptr), mapped_ids_(nullptr), 
      current_count_(0), max_capacity_(MAX_VECTORS) {
}

AppendOnlyFlatIndex::~AppendOnlyFlatIndex() {
    cleanup();
}

bool AppendOnlyFlatIndex::initialize() {
    // 파일 크기 계산: 벡터 데이터 + ID 데이터
    size_t vector_data_size = MAX_VECTORS * VECTOR_DIM * sizeof(float);
    size_t id_data_size = MAX_VECTORS * sizeof(uint64_t);
    size_t total_size = vector_data_size + id_data_size;
    
    // 파일이 존재하지 않으면 생성
    bool file_exists = std::filesystem::exists(file_path_);
    
    // 파일 열기 (읽기/쓰기, 없으면 생성)
    fd_ = open(file_path_.c_str(), O_RDWR | O_CREAT, 0644);
    if (fd_ == -1) {
        std::cerr << "Failed to open flat index file: " << file_path_ << std::endl;
        return false;
    }
    
    // 새 파일인 경우 크기 설정
    if (!file_exists) {
        if (ftruncate(fd_, total_size) == -1) {
            std::cerr << "Failed to set file size" << std::endl;
            close(fd_);
            return false;
        }
        std::cout << "Created new flat index file: " << total_size / 1024 / 1024 << " MB" << std::endl;
    }
    
    // mmap으로 파일 매핑
    void* mapped_ptr = mmap(nullptr, total_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (mapped_ptr == MAP_FAILED) {
        std::cerr << "Failed to mmap flat index file" << std::endl;
        close(fd_);
        return false;
    }
    
    // 포인터 설정
    mapped_data_ = static_cast<float*>(mapped_ptr);
    mapped_ids_ = reinterpret_cast<uint64_t*>(
        static_cast<char*>(mapped_ptr) + vector_data_size);
    
    // 기존 파일인 경우 현재 카운트 복구
    if (file_exists) {
        size_t count = 0;
        for (size_t i = 0; i < MAX_VECTORS; ++i) {
            if (mapped_ids_[i] != 0) {
                count = i + 1;
            } else {
                break;
            }
        }
        current_count_.store(count);
        std::cout << "Loaded existing flat index with " << count << " vectors" << std::endl;
    }
    
    std::cout << "Flat index initialized successfully" << std::endl;
    return true;
}

bool AppendOnlyFlatIndex::insert(const VectorData& vector_data) {
    if (vector_data.vector.size() != VECTOR_DIM) {
        std::cerr << "Vector dimension mismatch: " << vector_data.vector.size() 
                  << " != " << VECTOR_DIM << std::endl;
        return false;
    }
    
    std::lock_guard<std::mutex> lock(write_mutex_);
    
    size_t current_idx = current_count_.load();
    if (current_idx >= max_capacity_) {
        std::cerr << "Flat index is full" << std::endl;
        return false;
    }
    
    // 벡터 데이터 복사
    std::memcpy(&mapped_data_[current_idx * VECTOR_DIM], 
                vector_data.vector.data(), 
                VECTOR_DIM * sizeof(float));
    
    // ID 저장
    mapped_ids_[current_idx] = vector_data.id;
    
    // 카운트 증가
    current_count_.store(current_idx + 1);
    
    // 메모리 동기화
    msync(&mapped_data_[current_idx * VECTOR_DIM], VECTOR_DIM * sizeof(float), MS_ASYNC);
    msync(&mapped_ids_[current_idx], sizeof(uint64_t), MS_ASYNC);
    
    return true;
}

std::vector<SearchResult> AppendOnlyFlatIndex::bruteForceSearch(
    const std::vector<float>& query, int k) const {
    
    if (query.size() != VECTOR_DIM) {
        std::cerr << "Query dimension mismatch" << std::endl;
        return {};
    }
    
    size_t count = current_count_.load();
    if (count == 0) {
        return {};
    }
    
    std::vector<SearchResult> results;
    results.reserve(count);
    
    // 모든 벡터와의 거리 계산 (L2 distance)
    for (size_t i = 0; i < count; ++i) {
        float distance = 0.0f;
        for (size_t j = 0; j < VECTOR_DIM; ++j) {
            float diff = query[j] - mapped_data_[i * VECTOR_DIM + j];
            distance += diff * diff;
        }
        distance = std::sqrt(distance);
        
        results.emplace_back(mapped_ids_[i], distance);
    }
    
    // 거리에 따라 정렬
    std::partial_sort(results.begin(), 
                     results.begin() + std::min(k, static_cast<int>(results.size())),
                     results.end(),
                     [](const SearchResult& a, const SearchResult& b) {
                         return a.distance < b.distance;
                     });
    
    // 상위 k개만 반환
    if (static_cast<int>(results.size()) > k) {
        results.resize(k);
    }
    
    return results;
}

void AppendOnlyFlatIndex::cleanup() {
    if (mapped_data_ != nullptr) {
        size_t vector_data_size = MAX_VECTORS * VECTOR_DIM * sizeof(float);
        size_t id_data_size = MAX_VECTORS * sizeof(uint64_t);
        size_t total_size = vector_data_size + id_data_size;
        
        munmap(mapped_data_, total_size);
        mapped_data_ = nullptr;
        mapped_ids_ = nullptr;
    }
    
    if (fd_ != -1) {
        close(fd_);
        fd_ = -1;
    }
}

// VectorDB 구현
VectorDB::VectorDB(const std::string& hnsw_path, const std::string& flat_path)
    : hnsw_index_path_(hnsw_path), flat_index_path_(flat_path), next_id_(1) {
}

VectorDB::~VectorDB() {
    shutdown();
}

bool VectorDB::initialize() {
    std::cout << "=== VectorDB 초기화 ===" << std::endl;
    
    // HNSW 인덱스 로드
    if (!loadHNSWIndex()) {
        std::cerr << "Failed to load HNSW index" << std::endl;
        return false;
    }
    
    // Flat 인덱스 초기화
    flat_index_ = std::make_unique<AppendOnlyFlatIndex>(flat_index_path_);
    if (!flat_index_->initialize()) {
        std::cerr << "Failed to initialize flat index" << std::endl;
        return false;
    }
    
    std::cout << "VectorDB 초기화 완료" << std::endl;
    std::cout << "- HNSW 인덱스: " << hnsw_index_path_ << std::endl;
    std::cout << "- Flat 인덱스: " << flat_index_path_ << " (" 
              << flat_index_->getCurrentCount() << " vectors)" << std::endl;
    
    return true;
}

bool VectorDB::loadHNSWIndex() {
    std::cout << "HNSW 인덱스 로드 중: " << hnsw_index_path_ << std::endl;
    
    if (!std::filesystem::exists(hnsw_index_path_)) {
        std::cerr << "HNSW index file not found: " << hnsw_index_path_ << std::endl;
        return false;
    }
    
    // 인덱스 생성
    auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
    auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>("HNSW", version);
    
    if (!index.has_value()) {
        std::cerr << "Failed to create HNSW index instance" << std::endl;
        return false;
    }
    
    // config 설정
    knowhere::Json config;
    config[knowhere::meta::DIM] = VECTOR_DIM;
    config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
    config["enable_mmap"] = true;
    
    // DeserializeFromFile로 로드
    std::cout << "Loading HNSW index with config:" << std::endl;
    std::cout << "  DIM: " << config[knowhere::meta::DIM] << std::endl;
    std::cout << "  METRIC_TYPE: " << config[knowhere::meta::METRIC_TYPE] << std::endl;
    std::cout << "  enable_mmap: " << config["enable_mmap"] << std::endl;
    
    auto status = index.value().DeserializeFromFile(hnsw_index_path_, config);
    if (status != knowhere::Status::success) {
        std::cerr << "Failed to deserialize HNSW index from file, status: " << static_cast<int>(status) << std::endl;
        return false;
    }
    
    std::cout << "Index deserialized successfully" << std::endl;
    std::cout << "Index count after deserialization: " << index.value().Count() << std::endl;
    
    // 더미 검색으로 내부 구조 초기화
    std::vector<float> dummy_query(VECTOR_DIM, 0.0f);
    auto dummy_dataset = knowhere::GenDataSet(1, VECTOR_DIM, dummy_query.data());
    
    knowhere::Json search_config;
    search_config[knowhere::meta::DIM] = VECTOR_DIM;
    search_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
    search_config[knowhere::indexparam::EF] = 100;
    search_config[knowhere::meta::TOPK] = DEFAULT_K;

    std::cout << "Performing dummy search with K = " << DEFAULT_K << std::endl;

    auto dummy_result = index.value().Search(dummy_dataset, search_config, knowhere::BitsetView());
    
    if (dummy_result.has_value()) {
        auto dummy_rows = dummy_result.value()->GetRows();
        auto ids = dummy_result.value()->GetIds();
        auto distances = dummy_result.value()->GetDistance();
        auto dimension = dummy_result.value()->GetDim();
        
        std::cout << "Dummy search successful, returned " << dummy_rows << " results" << std::endl;
        std::cout << "Dimension: " << dimension << std::endl;
        std::cout << "result IDs and distances:" << std::endl;
        for (int64_t i = 0; i < dimension; ++i) {
            std::cout << "ID: " << ids[i] << ", Distance: " << distances[i] << std::endl;
        }
    } else {
        std::cout << "Dummy search failed - this might indicate an issue with the index" << std::endl;
    }
    
    // 직접 할당
    hnsw_index_ = std::move(index.value());
    
    std::cout << "HNSW 인덱스 로드 완료" << std::endl;
    std::cout << "- 벡터 수: " << hnsw_index_.Count() << std::endl;

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
        std::cerr << "Query dimension mismatch: " << query.size() 
                  << " != " << VECTOR_DIM << std::endl;
        return {};
    }
    
    std::vector<SearchResult> hnsw_results;
    std::vector<SearchResult> flat_results;
    
    // HNSW 검색 (읽기 락)
    {
        std::shared_lock<std::shared_mutex> lock(hnsw_mutex_);

        // 디버깅: HNSW 인덱스 정보 출력
        std::cout << "=== HNSW Search Debug Info ===" << std::endl;
        std::cout << "HNSW Index total vectors: " << hnsw_index_.Count() << std::endl;
        std::cout << "Query vector dimension: " << query.size() << std::endl;
        std::cout << "Requested K: " << k << std::endl;
        
        auto query_dataset = knowhere::GenDataSet(1, VECTOR_DIM, query.data());
        std::cout << "Query dataset rows: " << query_dataset->GetRows() << std::endl;

        knowhere::Json config;
        config[knowhere::meta::DIM] = VECTOR_DIM;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
        config[knowhere::indexparam::EF] = std::max(200, k * 2);  // EF를 K의 2배 이상으로 설정
        config[knowhere::meta::TOPK] = static_cast<int64_t>(k);

        // 설정된 config 출력
        std::cout << "Search config:" << std::endl;
        std::cout << "  DIM: " << config[knowhere::meta::DIM] << std::endl;
        std::cout << "  METRIC_TYPE: " << config[knowhere::meta::METRIC_TYPE] << std::endl;
        std::cout << "  EF: " << config[knowhere::indexparam::EF] << std::endl;
        std::cout << "  TOPK: " << config[knowhere::meta::TOPK] << std::endl;

        auto result = hnsw_index_.Search(query_dataset, config, knowhere::BitsetView());
        
        if (result.has_value()) {
            auto ids = result.value()->GetIds();
            auto distances = result.value()->GetDistance();
            auto num_results = result.value()->GetRows();
            auto dimension = result.value()->GetDim();
            
            std::cout << "HNSW search completed:" << std::endl;

            if (num_results > 1) {
                std::cout << " Result should be smaller than 1" << std::endl;
                return {};
            }

            // show type of distance and ids
            std::cout << "Distance type: " << typeid(distances[0]).name() << std::endl;
            std::cout << "IDs type: " << typeid(ids[0]).name() << std::endl;

            for (int64_t i = 0; i < dimension; ++i) {
                std::cout << "  Result " << i << ": ID=" << ids[i] 
                            << ", Distance=" << distances[i] << std::endl;
                
                // 1. 타입 캐스팅 안전성 확인
                int64_t original_id = ids[i];
                float original_distance = distances[i];
                
                if (original_id < 0) {
                    std::cerr << "WARNING: Negative ID detected: " << original_id << std::endl;
                }
                
                uint64_t casted_id = static_cast<uint64_t>(original_id);
                std::cout << "    Before cast: " << original_id << " -> After cast: " << casted_id << std::endl;
                
                // 2. emplace_back 전 hnsw_results 크기 확인
                size_t size_before = hnsw_results.size();
                std::cout << "    Vector size before emplace_back: " << size_before << std::endl;
                
                // emplace_back 수행
                hnsw_results.emplace_back(casted_id, original_distance);
                
                // 3. emplace_back 후 확인
                size_t size_after = hnsw_results.size();
                std::cout << "    Vector size after emplace_back: " << size_after << std::endl;
                
                if (size_after > 0) {
                    const auto& last_result = hnsw_results.back();
                    std::cout << "    Stored result: ID=" << last_result.id 
                              << ", Distance=" << last_result.distance << std::endl;
                    
                    // 값이 변경되었는지 확인
                    if (last_result.id != casted_id || last_result.distance != original_distance) {
                        std::cerr << "ERROR: Values changed after emplace_back!" << std::endl;
                        std::cerr << "  Expected: ID=" << casted_id << ", Distance=" << original_distance << std::endl;
                        std::cerr << "  Got: ID=" << last_result.id << ", Distance=" << last_result.distance << std::endl;
                    }
                }
            }
        } else {
            std::cout << "HNSW search failed - no result returned" << std::endl;
        }
    }
    
    // Flat 인덱스에서 brute force 검색
    std::cout << "\n=== Flat Index Search Debug ===" << std::endl;
    std::cout << "Flat index vector count: " << flat_index_->getCurrentCount() << std::endl;
    
    flat_results = flat_index_->bruteForceSearch(query, k);
    
    std::cout << "Flat search returned " << flat_results.size() << " results:" << std::endl;
    for (size_t i = 0; i < flat_results.size() && i < 10; ++i) {
        std::cout << "  Flat Result " << i << ": ID=" << flat_results[i].id 
                  << ", Distance=" << flat_results[i].distance << std::endl;
    }
    
    std::cout << "\n=== Before Merge ===" << std::endl;
    std::cout << "HNSW results: " << hnsw_results.size() << std::endl;
    std::cout << "Flat results: " << flat_results.size() << std::endl;
    
    // 결과 병합
    return mergeSearchResults(hnsw_results, flat_results, k);
}

std::vector<SearchResult> VectorDB::mergeSearchResults(
    const std::vector<SearchResult>& hnsw_results,
    const std::vector<SearchResult>& flat_results,
    int k) const {
    
    std::cout << "\n=== Merge Process Debug ===" << std::endl;
    std::cout << "Input - HNSW results: " << hnsw_results.size() << std::endl;
    for (size_t i = 0; i < hnsw_results.size() && i < 5; ++i) {
        std::cout << "  HNSW[" << i << "]: ID=" << hnsw_results[i].id 
                  << ", Distance=" << hnsw_results[i].distance << std::endl;
    }
    
    std::cout << "Input - Flat results: " << flat_results.size() << std::endl;
    for (size_t i = 0; i < flat_results.size() && i < 5; ++i) {
        std::cout << "  Flat[" << i << "]: ID=" << flat_results[i].id 
                  << ", Distance=" << flat_results[i].distance << std::endl;
    }
    
    std::vector<SearchResult> merged_results;
    merged_results.reserve(hnsw_results.size() + flat_results.size());
    
    // 모든 결과를 합치기
    for (const auto& result : hnsw_results) {
        merged_results.push_back(result);
    }
    for (const auto& result : flat_results) {
        merged_results.push_back(result);
    }
    
    std::cout << "After combining - Total results: " << merged_results.size() << std::endl;
    
    // 거리에 따라 정렬
    std::partial_sort(merged_results.begin(), 
                     merged_results.begin() + std::min(k, static_cast<int>(merged_results.size())),
                     merged_results.end(),
                     [](const SearchResult& a, const SearchResult& b) {
                         return a.distance < b.distance;
                     });

    // sort된 거 상위 10개만 보기
    std::cout << "After sorting - Top results:" << std::endl;
    for (int i = 0; i < std::min(10, static_cast<int>(merged_results.size())); ++i) {
        std::cout << "  Result " << i + 1 << ": ID=" << merged_results[i].id 
                  << ", Distance=" << merged_results[i].distance << std::endl;
    }
    
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

#include "hnsw_index.h"
#include "flat_index.h"  // SearchResult 정의를 위해
#include "knowhere/comp/brute_force.h"  // BruteForce::Search를 위해

HNSWIndexManager::HNSWIndexManager(const std::string& index_dir, size_t vector_dim)
    : vector_dim_(vector_dim), index_dir_(index_dir) {
}

HNSWIndexManager::~HNSWIndexManager() {
    // Knowhere 인덱스들은 자동으로 소멸
}

bool HNSWIndexManager::initialize() {
    std::cout << "=== HNSW Index Manager 초기화 ===" << std::endl;
    
    // Knowhere 스레드 풀 크기 설정
    setenv("KNOWHERE_BUILD_THREAD_POOL_SIZE", "64", 1);
    setenv("KNOWHERE_SEARCH_THREAD_POOL_SIZE", "64", 1);
    std::cout << "Knowhere 스레드 풀 크기를 64로 설정했습니다." << std::endl;
    
    // 인덱스 로드
    if (!loadIndices()) {
        std::cerr << "Failed to load HNSW indices" << std::endl;
        return false;
    }
    
    std::cout << "HNSW Index Manager 초기화 완료" << std::endl;
    std::cout << "- 로드된 인덱스 개수: " << indices_.size() << std::endl;
    std::cout << "- 전체 벡터 개수: " << getTotalVectorCount() << std::endl;
    
    return true;
}

bool HNSWIndexManager::loadIndices() {
    std::cout << "HNSW 인덱스들 로드 중: " << index_dir_ << std::endl;
    
    if (!std::filesystem::exists(index_dir_)) {
        std::cerr << "HNSW index directory not found: " << index_dir_ << std::endl;
        return false;
    }
    
    // 디렉토리에서 hnsw_index_*.bin 패턴의 파일들 찾기
    std::vector<std::string> index_files;
    for (const auto& entry : std::filesystem::directory_iterator(index_dir_)) {
        if (entry.is_regular_file()) {
            std::string filename = entry.path().filename().string();
            if (filename.find("hnsw_index_") == 0 && filename.find(".bin") != std::string::npos) {
                index_files.push_back(entry.path().string());
            }
        }
    }
    
    if (index_files.empty()) {
        std::cerr << "No HNSW index files found matching pattern hnsw_index_*.bin" << std::endl;
        return false;
    }
    
    // 파일명으로 정렬
    std::sort(index_files.begin(), index_files.end());
    
    std::cout << "Found " << index_files.size() << " HNSW index files:" << std::endl;
    for (const auto& file : index_files) {
        std::cout << "  " << file << std::endl;
    }
    
    // 각 인덱스 파일을 로드
    indices_.clear();
    index_paths_.clear();
    index_beg_ids_.clear();
    
    int beg_id = 0;
    for (const auto& index_path : index_files) {
        std::cout << "\nLoading HNSW index: " << index_path << std::endl;
        
        // 인덱스 생성
        auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
        auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>("HNSW", version);
        
        if (!index.has_value()) {
            std::cerr << "Failed to create HNSW index instance for " << index_path << std::endl;
            return false;
        }
        
        // config 설정
        knowhere::Json config;
        config[knowhere::meta::DIM] = vector_dim_;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
        config["enable_mmap"] = true;
        
        // DeserializeFromFile로 로드
        auto status = index.value().DeserializeFromFile(index_path, config);
        if (status != knowhere::Status::success) {
            std::cerr << "Failed to deserialize HNSW index from file: " << index_path 
                      << ", status: " << static_cast<int>(status) << std::endl;
            return false;
        }
        
        int64_t count = index.value().Count();
        std::cout << "Index loaded successfully, vector count: " << count << std::endl;
        
        // 더미 검색으로 내부 구조 초기화
        std::vector<float> dummy_query(vector_dim_, 0.0f);
        auto dummy_dataset = knowhere::GenDataSet(1, vector_dim_, dummy_query.data());
        
        knowhere::Json search_config;
        search_config[knowhere::meta::DIM] = vector_dim_;
        search_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
        search_config[knowhere::indexparam::EF] = 200;
        search_config[knowhere::meta::TOPK] = 10;

        auto dummy_result = index.value().Search(dummy_dataset, search_config, knowhere::BitsetView());
        
        if (dummy_result.has_value()) {
            std::cout << "Dummy search successful for " << index_path << std::endl;
        } else {
            std::cout << "Dummy search failed for " << index_path << std::endl;
        }
        
        // 인덱스를 벡터에 추가
        indices_.push_back(std::move(index.value()));
        index_paths_.push_back(index_path);
        index_beg_ids_.push_back(beg_id);
        
        beg_id += count;
    }
    
    std::cout << "\nAll HNSW indices loaded successfully (" << indices_.size() << " indices)" << std::endl;
    return true;
}

size_t HNSWIndexManager::getTotalVectorCount() const {
    size_t total = 0;
    for (const auto& index : indices_) {
        total += index.Count();
    }
    return total;
}

std::vector<SearchResult> HNSWIndexManager::searchSingleIndex(
    size_t index_idx, 
    const std::vector<float>& query, 
    int k) const {
    
    std::vector<SearchResult> results;
    
    // 스레드별로 독립적인 데이터셋과 설정을 생성
    auto local_query_dataset = knowhere::GenDataSet(1, vector_dim_, query.data());
    knowhere::Json local_config;
    local_config[knowhere::meta::DIM] = vector_dim_;
    local_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
    local_config[knowhere::indexparam::EF] = std::max(DEFAULT_EF, k * 2);
    local_config[knowhere::meta::TOPK] = static_cast<int64_t>(k);

    auto result = indices_[index_idx].Search(local_query_dataset, local_config, knowhere::BitsetView());

    if (result.has_value()) {
        auto ids = result.value()->GetIds();
        auto distances = result.value()->GetDistance();
        int64_t num_results = result.value()->GetDim(); // GetDim()이 topk를 반환

        for (int64_t j = 0; j < num_results; ++j) {
            if (ids[j] >= 0) {
                results.emplace_back(
                    static_cast<uint64_t>(ids[j] + index_beg_ids_[index_idx]), 
                    distances[j]
                );
            }
        }
    }
    
    return results;
}

std::vector<SearchResult> HNSWIndexManager::search(
    const std::vector<float>& query, int k) const {
    
    if (query.size() != vector_dim_) {
        std::cerr << "Query dimension mismatch in HNSW search" << std::endl;
        return {};
    }
    
    // 각 HNSW 검색 작업을 비동기적으로 실행
    std::vector<std::future<std::vector<SearchResult>>> futures;
    
    for (size_t i = 0; i < indices_.size(); ++i) {
        futures.emplace_back(std::async(std::launch::async, 
            [this, i, &query, k]() {
                return searchSingleIndex(i, query, k);
            }
        ));
    }
    
    // 모든 결과 수집
    std::vector<SearchResult> all_results;
    for (auto& fut : futures) {
        auto single_results = fut.get();
        all_results.insert(all_results.end(), single_results.begin(), single_results.end());
    }
    
    // 거리에 따라 정렬
    std::partial_sort(all_results.begin(), 
                     all_results.begin() + std::min(k, static_cast<int>(all_results.size())),
                     all_results.end(),
                     [](const SearchResult& a, const SearchResult& b) {
                         return a.distance < b.distance;
                     });
    
    // 상위 k개만 반환
    if (static_cast<int>(all_results.size()) > k) {
        all_results.resize(k);
    }
    
    return all_results;
}

std::vector<std::vector<SearchResult>> HNSWIndexManager::searchBatch(
    const std::vector<std::vector<float>>& queries, 
    int k,
    std::vector<float>& reused_batch_buffer) const {
    
    if (queries.empty()) {
        return {};
    }
    
    size_t batch_size = queries.size();
    
    // 모든 쿼리의 차원 확인
    for (const auto& query : queries) {
        if (query.size() != vector_dim_) {
            std::cerr << "Query dimension mismatch in HNSW batch search" << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }
    
    // 배치 쿼리 데이터 준비 (버퍼 재사용)
    size_t required_size = batch_size * vector_dim_;
    reused_batch_buffer.clear();
    reused_batch_buffer.reserve(required_size);
    
    for (const auto& query : queries) {
        reused_batch_buffer.insert(reused_batch_buffer.end(), query.begin(), query.end());
    }
    
    // 각 인덱스를 병렬로 검색
    std::vector<std::future<std::vector<std::vector<SearchResult>>>> futures;
    
    for (size_t i = 0; i < indices_.size(); ++i) {
        futures.emplace_back(std::async(std::launch::async, 
            [this, i, &reused_batch_buffer, batch_size, k]() {
                std::vector<std::vector<SearchResult>> batch_results(batch_size);
                
                // 배치 데이터셋 생성
                auto batch_dataset = knowhere::GenDataSet(batch_size, vector_dim_, reused_batch_buffer.data());
                
                knowhere::Json batch_config;
                batch_config[knowhere::meta::DIM] = vector_dim_;
                batch_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
                batch_config[knowhere::indexparam::EF] = std::max(DEFAULT_EF, k * 2);
                batch_config[knowhere::meta::TOPK] = static_cast<int64_t>(k);
                
                auto result = indices_[i].Search(batch_dataset, batch_config, knowhere::BitsetView());
                
                if (result.has_value()) {
                    auto rows = result.value()->GetRows();
                    auto ids = result.value()->GetIds();
                    auto distances = result.value()->GetDistance();
                    auto dimension = result.value()->GetDim();
                    
                    for (int64_t row = 0; row < rows; ++row) {
                        for (int64_t j = 0; j < dimension; ++j) {
                            int64_t idx = row * dimension + j;
                            batch_results[row].emplace_back(
                                static_cast<uint64_t>(ids[idx] + index_beg_ids_[i]), 
                                distances[idx]
                            );
                        }
                    }
                }
                
                return batch_results;
            }
        ));
    }
    
    // 모든 인덱스 결과 수집
    std::vector<std::vector<std::vector<SearchResult>>> all_index_results;
    for (auto& fut : futures) {
        all_index_results.push_back(fut.get());
    }
    
    // 각 쿼리별로 결과 병합
    std::vector<std::vector<SearchResult>> final_results(batch_size);
    for (size_t query_idx = 0; query_idx < batch_size; ++query_idx) {
        std::vector<SearchResult> merged;
        
        // 모든 인덱스의 결과를 합침
        for (const auto& index_results : all_index_results) {
            merged.insert(merged.end(), 
                         index_results[query_idx].begin(), 
                         index_results[query_idx].end());
        }
        
        // 거리에 따라 정렬
        std::partial_sort(merged.begin(), 
                         merged.begin() + std::min(k, static_cast<int>(merged.size())),
                         merged.end(),
                         [](const SearchResult& a, const SearchResult& b) {
                             return a.distance < b.distance;
                         });
        
        // 상위 k개만 저장
        if (static_cast<int>(merged.size()) > k) {
            merged.resize(k);
        }
        
        final_results[query_idx] = std::move(merged);
    }
    
    return final_results;
}

bool HNSWIndexManager::hasRawData() const {
    if (indices_.empty()) {
        return false;
    }
    
    // 첫 번째 인덱스로 확인 (모든 인덱스가 같은 타입이라고 가정)
    return indices_[0].HasRawData(knowhere::metric::COSINE);
}

std::vector<SearchResult> HNSWIndexManager::exactSearch(
    const std::vector<float>& query, int k) const {
    
    if (query.size() != vector_dim_) {
        std::cerr << "Query dimension mismatch in exact search" << std::endl;
        return {};
    }
    
    // Raw data 확인
    if (!hasRawData()) {
        std::cerr << "HNSW indices do not contain raw data for exact search" << std::endl;
        return {};
    }
    
    std::cout << "Performing HNSW exact search using BruteForce::Search (CHUNK-BASED)..." << std::endl;
    
    // 청크 크기 설정 - 디버깅: 일단 1개만 시도
    const int64_t CHUNK_SIZE = 1;
    
    std::cout << "DEBUG: Testing with chunk size = " << CHUNK_SIZE << std::endl;
    
    std::vector<SearchResult> all_results;
    int global_id_offset = 0;
    
    // query_dataset 생성 (한 번만)
    auto query_dataset = knowhere::GenDataSet(1, vector_dim_, query.data());
    
    // 각 인덱스에서 청크 단위로 처리
    for (size_t idx = 0; idx < indices_.size(); ++idx) {
        std::cout << "Processing index " << idx << "..." << std::endl;
        int64_t count = indices_[idx].Count();
        std::cout << "  Total vectors: " << count << std::endl;
        
        // GetVectorByIds가 작동하는지 먼저 테스트
        std::cout << "  Testing GetVectorByIds with ID 0..." << std::endl;
        try {
            std::vector<int64_t> test_id = {0};
            auto test_id_dataset = knowhere::GenDataSet(1, 1, test_id.data());
            std::cout << "    Dataset created, calling GetVectorByIds..." << std::endl;
            
            // 실제 호출 - 여기서 크래시 나는지 확인
            auto test_result = indices_[idx].GetVectorByIds(test_id_dataset);
            
            std::cout << "    GetVectorByIds SUCCESS!" << std::endl;
            if (!test_result.has_value()) {
                std::cout << "    But returned empty result - raw data might not exist" << std::endl;
                global_id_offset += count;
                continue;
            }
        } catch (const std::exception& e) {
            std::cout << "    GetVectorByIds threw exception: " << e.what() << std::endl;
            global_id_offset += count;
            continue;
        } catch (...) {
            std::cout << "    GetVectorByIds threw unknown exception" << std::endl;
            global_id_offset += count;
            continue;
        }
        
        std::cout << "  GetVectorByIds verified working. Proceeding with exact search..." << std::endl;
        
        // 청크 개수 계산
        int64_t num_chunks = (count + CHUNK_SIZE - 1) / CHUNK_SIZE;
        std::cout << "  Processing in " << num_chunks << " chunks of ~" << CHUNK_SIZE << " vectors" << std::endl;
        
        // 각 청크 처리
        for (int64_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx) {
            int64_t chunk_start = chunk_idx * CHUNK_SIZE;
            int64_t chunk_end = std::min(chunk_start + CHUNK_SIZE, count);
            int64_t chunk_size = chunk_end - chunk_start;
            
            std::cout << "    Chunk " << (chunk_idx + 1) << "/" << num_chunks 
                      << ": vectors [" << chunk_start << ", " << chunk_end << ")" << std::endl;
            
            std::cout << "      Creating ID list..." << std::endl;
            
            // 현재 청크의 ID 생성
            std::vector<int64_t> chunk_ids(chunk_size);
            for (int64_t j = 0; j < chunk_size; ++j) {
                chunk_ids[j] = chunk_start + j;
            }
            
            std::cout << "      Creating ID dataset..." << std::endl;
            
            // ID 데이터셋 생성
            auto id_dataset = knowhere::GenDataSet(chunk_size, 1, chunk_ids.data());
            
            std::cout << "      Calling GetVectorByIds for " << chunk_size << " vectors..." << std::endl;
            
            // 벡터 추출
            auto result = indices_[idx].GetVectorByIds(id_dataset);
            
            std::cout << "      GetVectorByIds returned" << std::endl;
            
            if (!result.has_value()) {
                std::cerr << "    ERROR: Failed to extract chunk from index " << idx << std::endl;
                continue;
            }
            
            std::cout << "      Creating DataSet from extracted data..." << std::endl;
            
            // 추출된 데이터로 DataSet 생성
            auto extracted_dataset = result.value();
            const float* data_ptr = reinterpret_cast<const float*>(extracted_dataset->GetTensor());
            
            std::cout << "      Creating base_dataset..." << std::endl;
            auto base_dataset = knowhere::GenDataSet(chunk_size, vector_dim_, data_ptr);
            
            std::cout << "      Setting up BruteForce config..." << std::endl;
            
            // BruteForce 검색 설정
            knowhere::Json config;
            config["metric_type"] = "COSINE";
            config["k"] = k;
            
            std::cout << "      Calling BruteForce::Search..." << std::endl;
            
            // BruteForce::Search 호출
            auto search_result = knowhere::BruteForce::Search<knowhere::fp32>(
                base_dataset, query_dataset, config, knowhere::BitsetView());
            
            std::cout << "      BruteForce::Search returned" << std::endl;
            
            if (!search_result.has_value()) {
                std::cerr << "    ERROR: BruteForce search failed for chunk" << std::endl;
                continue;
            }
            
            // 결과 파싱 및 저장
            auto result_dataset = search_result.value();
            auto result_ids = result_dataset->GetIds();
            auto result_dists = result_dataset->GetDistance();
            int result_k = result_dataset->GetDim();
            
            for (int i = 0; i < result_k; ++i) {
                if (result_ids[i] != -1) {
                    // 청크 내 로컬 ID를 글로벌 ID로 변환
                    int64_t local_id = result_ids[i];
                    int64_t global_id = global_id_offset + chunk_start + local_id;
                    
                    all_results.emplace_back(
                        static_cast<uint64_t>(global_id),
                        result_dists[i]
                    );
                }
            }
            
            std::cout << "    Chunk completed, found " << result_k << " results" << std::endl;
        }
        
        global_id_offset += count;
        std::cout << "  Index " << idx << " completed" << std::endl;
    }
    
    std::cout << "Sorting " << all_results.size() << " total results..." << std::endl;
    
    // 거리에 따라 정렬
    std::partial_sort(all_results.begin(), 
                     all_results.begin() + std::min(k, static_cast<int>(all_results.size())),
                     all_results.end(),
                     [](const SearchResult& a, const SearchResult& b) {
                         return a.distance < b.distance;
                     });
    
    // 상위 k개만 반환
    if (static_cast<int>(all_results.size()) > k) {
        all_results.resize(k);
    }
    
    std::cout << "HNSW exact search completed, found " << all_results.size() << " results" << std::endl;
    
    return all_results;
}

std::vector<std::vector<SearchResult>> HNSWIndexManager::exactSearchBatch(
    const std::vector<std::vector<float>>& queries, int k) const {
    
    if (queries.empty()) {
        return {};
    }
    
    size_t batch_size = queries.size();
    
    // 모든 쿼리의 차원 확인
    for (const auto& query : queries) {
        if (query.size() != vector_dim_) {
            std::cerr << "Query dimension mismatch in exact batch search" << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }
    
    // Raw data 확인
    if (!hasRawData()) {
        std::cerr << "HNSW indices do not contain raw data for exact search" << std::endl;
        return std::vector<std::vector<SearchResult>>(batch_size);
    }
    
    std::cout << "Performing HNSW exact batch search on " << batch_size << " queries..." << std::endl;
    
    // 각 쿼리에 대해 개별적으로 exact search 수행 (병렬)
    std::vector<std::vector<SearchResult>> batch_results(batch_size);
    
    #pragma omp parallel for
    for (size_t i = 0; i < batch_size; ++i) {
        batch_results[i] = exactSearch(queries[i], k);
    }
    
    std::cout << "HNSW exact batch search completed" << std::endl;
    
    return batch_results;
}

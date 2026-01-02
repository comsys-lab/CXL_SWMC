/**
z* 향상된 HNSW 예제 - Faiss HNSW 백엔드 사용
 * 이 버전은 Knowhere의 실제 API를 사용하여 정확한 구현을 제공합니다.
 */

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <memory>
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

// Apache Arrow headers
#include <arrow/api.h>
#include <arrow/io/api.h>
#include <arrow/ipc/api.h>
#include <arrow/table.h>
#include <arrow/array.h>

class AdvancedHNSWMmapExample {
private:
    // 설정 변수들 (생성자에서 설정)
    int DIM;          // BGE embedding dimension
    int NB;           // Database size (extracted from PubMed)
    int NQ;           // Query size  
    int K;            // Top-K results
    int BEG_ID;       // 시작 ID
    std::string dataset_dir;  // Dataset directory path (PubMed_bge_100000)
    std::string index_file; // Index file path

public:
    // 생성자 - 파라미터 설정
    AdvancedHNSWMmapExample(int dim = 768, int nb = 50000, int nq = 100, int k = 10, int beg_id = 0,
                           const std::string& dataset_path = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_100000",
                           const std::string& index_path = "hnsw_index.bin")
        : DIM(dim), NB(nb), NQ(nq), K(k), BEG_ID(beg_id), dataset_dir(dataset_path), index_file(index_path) {
        
        // 데이터셋 디렉토리 경로가 '/'로 끝나지 않으면 추가
        if (!dataset_dir.empty() && dataset_dir.back() != '/') {
            dataset_dir += '/';
        }
        
        std::cout << "=== 설정 ===" << std::endl;
        std::cout << "DIM: " << DIM << std::endl;
        std::cout << "NB: " << NB << std::endl;
        std::cout << "NQ: " << NQ << std::endl;
        std::cout << "K: " << K << std::endl;
        std::cout << "BEG_ID: " << BEG_ID << std::endl;
        std::cout << "PubMed BGE 데이터셋 디렉토리: " << dataset_dir << std::endl;
        std::cout << "인덱스 파일: " << index_file << std::endl;
    }

    std::vector<float> loadQueryData() {
        std::cout << "\n=== 쿼리 데이터 로드 (" << NQ << "개) ===" << std::endl;
        std::vector<float> queries;
        queries.reserve(NQ * DIM);

        std::vector<std::string> arrow_files;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(dataset_dir)) {
            if (entry.path().extension() == ".arrow") {
                arrow_files.push_back(entry.path().string());
            }
        }
        if (arrow_files.empty()) {
            throw std::runtime_error("Arrow 파일을 찾을 수 없습니다.");
        }
        std::sort(arrow_files.begin(), arrow_files.end());

        // 첫 번째 파일에서 NQ개만 읽기
        processFileInBatches(arrow_files[0], NQ, NQ, 
            [&](const std::vector<float>& batch_vectors) {
                queries.insert(queries.end(), batch_vectors.begin(), batch_vectors.end());
            });

        if (queries.size() / DIM < NQ) {
            throw std::runtime_error("쿼리 데이터를 충분히 로드하지 못했습니다.");
        }
        // 정확히 NQ개만 사용
        queries.resize(NQ * DIM);
        std::cout << "쿼리 데이터 로드 완료." << std::endl;
        return queries;
    }
    
    // HNSW 인덱스 생성 (메모리 효율적 파라미터)
    void buildAndSaveIndexInBatches(int batch_size) {
        std::cout << "\n=== HNSW 인덱스 배치 빌드 시작 (Batch Size: " << batch_size << ") ===" << std::endl;
        auto start = std::chrono::high_resolution_clock::now();

        auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
        auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>("HNSW", version);
        if (!index.has_value()) {
            throw std::runtime_error("HNSW 인덱스 생성 실패");
        }
        
        // 메모리 효율적 HNSW 파라미터 (대용량 데이터용)
        knowhere::Json config;
        config[knowhere::meta::DIM] = DIM;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
        config[knowhere::indexparam::HNSW_M] = 64;           // 메모리 사용량 줄이기
        config[knowhere::indexparam::EFCONSTRUCTION] = 200;  // 적절한 품질 유지
        config[knowhere::indexparam::EF] = 100;              // 검색 품질
        config[knowhere::meta::TOPK] = K;
        
        // mmap 지원 활성화
        config["enable_mmap"] = true;
        
        std::vector<std::string> arrow_files;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(dataset_dir)) {
            if (entry.path().extension() == ".arrow") {
                arrow_files.push_back(entry.path().string());
            }
        }
        if (arrow_files.empty()) throw std::runtime_error("Arrow 파일을 찾을 수 없습니다.");
        std::sort(arrow_files.begin(), arrow_files.end());

        // 첫 번째 배치를 로드하여 Train에 사용
        std::cout << "인덱스 초기화를 위해 첫 번째 데이터 배치 로드 중..." << std::endl;
        std::vector<float> first_batch;
        processFileInBatches(arrow_files[0], batch_size, batch_size, 
            [&](const std::vector<float>& batch_vectors) {
                if (first_batch.empty()) { // 첫 번째 콜백만 사용
                    first_batch = batch_vectors;
                }
            });

        if (first_batch.empty()) {
            throw std::runtime_error("첫 번째 배치를 로드할 수 없습니다.");
        }

        std::cout << "인덱스 Train 단계... (전체 크기 " << NB << "로 용량 설정)" << std::endl;
        // 첫 번째 배치의 시작 ID로 BEG_ID 사용
        auto init_dataset = knowhere::GenDataSet(NB, DIM, first_batch.data(), BEG_ID);
        auto status = index.value().Train(init_dataset, config);
        if (status != knowhere::Status::success) {
            throw std::runtime_error("인덱스 Train 실패");
        }

        // 모든 데이터를 배치 단위로 Add
        std::cout << "데이터를 배치 단위로 인덱스에 추가하는 중..." << std::endl;
        int64_t total_added = 0;
        for (const auto& file_path : arrow_files) {
            if (total_added >= NB) break;

            std::cout << "  파일 처리 중: " << std::filesystem::path(file_path).filename() << std::endl;
            processFileInBatches(file_path, batch_size, NB - total_added,
                [&](const std::vector<float>& batch_vectors) {
                    if (batch_vectors.empty() || total_added >= NB) return;
                    
                    int current_batch_size = batch_vectors.size() / DIM;
                    
                    // 현재 배치의 시작 ID 계산
                    int64_t current_batch_start_id = BEG_ID + total_added;
                    
                    auto add_dataset = knowhere::GenDataSet(current_batch_size, DIM, batch_vectors.data(), current_batch_start_id);
                    
                    auto add_status = index.value().Add(add_dataset, config);
                    if (add_status != knowhere::Status::success) {
                        throw std::runtime_error("배치 데이터 추가 실패");
                    }
                    
                    total_added += current_batch_size;
                    std::cout << "    > 배치 추가 완료. (현재 배치: " << current_batch_size 
                              << ", 총 추가: " << total_added << "/" << NB 
                              << ", ID 범위: " << current_batch_start_id 
                              << "-" << current_batch_start_id + current_batch_size - 1 << ")" << std::endl;
                });
        }
        
        auto end_build = std::chrono::high_resolution_clock::now();
        auto duration_build = std::chrono::duration_cast<std::chrono::seconds>(end_build - start);
        std::cout << "인덱스 빌드 완료: " << duration_build.count() << "s" << std::endl;

        saveIndexWithMmapSupport(index.value(), index_file, config);
    }

// Arrow 파일을 배치 단위로 읽고 처리하기 위한 헬퍼 함수
    void processFileInBatches(const std::string& arrow_file, int batch_size, int64_t max_vectors,
                              const std::function<void(const std::vector<float>&)>& batch_callback) {
        
        try {
            // Arrow 파일 열기
            std::shared_ptr<arrow::io::ReadableFile> input;
            auto result = arrow::io::ReadableFile::Open(arrow_file);
            if (!result.ok()) throw std::runtime_error("파일 열기 실패: " + arrow_file);
            input = result.ValueOrDie();

            std::shared_ptr<arrow::Table> table;

            // +++ [수정] Arrow File 및 Stream 포맷 모두 지원하도록 로직 복원 +++
            // 1. File 포맷으로 먼저 시도
            auto file_reader_result = arrow::ipc::RecordBatchFileReader::Open(input);
            if (file_reader_result.ok()) {
                auto reader = file_reader_result.ValueOrDie();
                auto table_result = reader->ToTable();
                if (!table_result.ok()) {
                    throw std::runtime_error("Arrow 테이블 변환 실패 (File 포맷)");
                }
                table = table_result.ValueOrDie();
            } else {
                // 2. 실패 시 Stream 포맷으로 재시도
                // Arrow 리더는 파일 핸들을 소비하므로 파일을 다시 열어야 합니다.
                auto result_rerun = arrow::io::ReadableFile::Open(arrow_file);
                if (!result_rerun.ok()) throw std::runtime_error("파일 재열기 실패: " + arrow_file);
                input = result_rerun.ValueOrDie();
                
                auto stream_reader_result = arrow::ipc::RecordBatchStreamReader::Open(input);
                if (!stream_reader_result.ok()) {
                    // 두 방식 모두 실패한 경우
                    throw std::runtime_error("지원되지 않는 Arrow 파일 형식입니다. File 및 Stream 포맷 읽기에 모두 실패했습니다.");
                }

                auto stream_reader = stream_reader_result.ValueOrDie();
                auto table_result = stream_reader->ToTable();
                if (!table_result.ok()) {
                    throw std::runtime_error("Arrow 테이블 변환 실패 (Stream 포맷)");
                }
                table = table_result.ValueOrDie();
            }
            // +++ 수정 끝 +++

            if (!table) {
                throw std::runtime_error("Arrow 테이블을 로드할 수 없습니다.");
            }

            auto embedding_column = table->GetColumnByName("embedding");
            if (!embedding_column) throw std::runtime_error("'embedding' 컬럼을 찾을 수 없습니다.");
            
            int64_t file_total_vectors = std::min(max_vectors, table->num_rows());
            
            // 이하 로직은 동일
            for (int batch_start = 0; batch_start < file_total_vectors; batch_start += batch_size) {
                int64_t current_batch_end = std::min(static_cast<int64_t>(batch_start + batch_size), file_total_vectors);
                int64_t batch_count = current_batch_end - batch_start;
                
                std::vector<float> batch_database;
                batch_database.reserve(batch_count * DIM);

                for (int chunk_idx = 0; chunk_idx < embedding_column->num_chunks(); ++chunk_idx) {
                    auto chunk = embedding_column->chunk(chunk_idx);
                    int64_t chunk_offset = 0; // 각 청크의 시작 오프셋을 계산
                    for(int pre_chunk=0; pre_chunk < chunk_idx; ++pre_chunk){
                        chunk_offset += embedding_column->chunk(pre_chunk)->length();
                    }

                    auto list_array = std::static_pointer_cast<arrow::ListArray>(chunk);
                    auto values = std::static_pointer_cast<arrow::FloatArray>(list_array->values());
                    
                    for (int64_t i = 0; i < list_array->length(); ++i) {
                        int64_t global_idx = chunk_offset + i;
                        if (global_idx >= batch_start && global_idx < current_batch_end) {
                            int32_t start_offset = list_array->value_offset(i);
                            for (int32_t j = 0; j < DIM; ++j) {
                                batch_database.push_back(values->Value(start_offset + j));
                            }
                        }
                    }
                }
                
                if (!batch_database.empty()) {
                    batch_callback(batch_database);
                }
            }
        } catch (const std::exception& e) {
            std::cerr << "파일 배치 처리 중 오류: " << e.what() << std::endl;
        }
    }
    
    // HNSW 네이티브 형식으로 인덱스 저장
    void saveIndexWithMmapSupport(knowhere::Index<knowhere::IndexNode>& index,
                                 const std::string& filename,
                                 const knowhere::Json& config) {
        std::cout << "HNSW 네이티브 형식으로 인덱스 저장 중..." << std::endl;
        
        auto start = std::chrono::high_resolution_clock::now();
        
        // 1. BinarySet으로 직렬화 (표준 방식)
        knowhere::BinarySet binary_set;
        auto status = index.Serialize(binary_set);
        if (status != knowhere::Status::success) {
            throw std::runtime_error("Failed to serialize index");
        }
        
        // 2. HNSW 네이티브 바이너리 데이터 추출
        auto hnsw_binary = binary_set.GetByName("HNSW");
        if (!hnsw_binary) {
            throw std::runtime_error("Failed to get HNSW binary data");
        }
        
        // 3. 네이티브 HNSW 포맷으로 파일에 직접 저장 (mmap 호환)
        std::ofstream ofs(filename, std::ios::binary);
        if (!ofs) {
            throw std::runtime_error("Failed to open file for writing");
        }
        
        ofs.write(reinterpret_cast<const char*>(hnsw_binary->data.get()), hnsw_binary->size);
        ofs.close();
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
        std::cout << "HNSW 네이티브 저장 완료: " << duration.count() << "ms" << std::endl;
        std::cout << "네이티브 HNSW 데이터: " << hnsw_binary->size / 1024 << " KB" << std::endl;
        
        // 파일 크기 확인
        struct stat st;
        if (stat(filename.c_str(), &st) == 0) {
            std::cout << "파일 크기: " << st.st_size / 1024 / 1024 << " MB" << std::endl;
        }
    }
    
    // HNSW 네이티브 DeserializeFromFile을 사용한 인덱스 로드
    knowhere::Index<knowhere::IndexNode> loadIndexWithMmap(const std::string& index_file) {
        std::cout << "\n=== HNSW 네이티브 파일에서 인덱스 로드 ===" << std::endl;
        
        analyzeMemoryUsage("로드 시작 전");
        
        auto start = std::chrono::high_resolution_clock::now();
        
        // 파일 크기 확인
        struct stat st;
        if (stat(index_file.c_str(), &st) == 0) {
            std::cout << "인덱스 파일 크기: " << st.st_size / 1024 / 1024 << " MB" << std::endl;
        } else {
            throw std::runtime_error("Cannot stat index file");
        }
        
        // 인덱스 생성
        auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
        auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>("HNSW", version);
        
        if (!index.has_value()) {
            throw std::runtime_error("Failed to create index for loading");
        }
        std::cout << "인덱스 객체 생성 완료" << std::endl;
        analyzeMemoryUsage("인덱스 객체 생성 후");
        
        // config 설정 (DeserializeFromFile에 필요)
        knowhere::Json config;
        config[knowhere::meta::DIM] = DIM;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
        config["enable_mmap"] = true;  // mmap 활성화
        
        std::cout << "DeserializeFromFile로 네이티브 HNSW 로드 중..." << std::endl;
        
        // DeserializeFromFile 시도 (네이티브 HNSW 포맷)
        auto status = index.value().DeserializeFromFile(index_file, config);
        if (status == knowhere::Status::success) {
            auto end = std::chrono::high_resolution_clock::now();
            auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
            std::cout << "네이티브 HNSW DeserializeFromFile 로드 완료: " << duration.count() << "ms" << std::endl;
            analyzeMemoryUsage("DeserializeFromFile 완료 후");
            
            // 첫 번째 더미 검색 (내부 구조 초기화 트리거)
            std::cout << "\n--- 내부 구조 초기화를 위한 더미 검색 ---" << std::endl;
            std::vector<float> dummy_query(DIM, 0.0f);
            auto dummy_dataset = knowhere::GenDataSet(1, DIM, dummy_query.data());
            
            knowhere::Json search_config;
            search_config[knowhere::meta::DIM] = DIM;
            search_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
            search_config[knowhere::indexparam::EF] = 100;
            search_config[knowhere::meta::TOPK] = K;
            
            auto dummy_result = index.value().Search(dummy_dataset, search_config, knowhere::BitsetView());
            std::cout << "더미 검색 완료" << std::endl;
            analyzeMemoryUsage("첫 검색 후 (내부 구조 초기화 완료)");
            
            return index.value();
        }

        return index.value();
    }
    
    // 검색 성능 벤치마크
    void benchmarkSearch(knowhere::Index<knowhere::IndexNode>& index, 
                        const std::vector<float>& queries) {
        std::cout << "\n=== 검색 성능 벤치마크 ===" << std::endl;
        
        auto query_dataset = knowhere::GenDataSet(NQ, DIM, queries.data());
        
        // 다양한 ef 값으로 테스트
        std::vector<int> ef_values = {50, 100, 200, 400};
        
        for (int ef : ef_values) {
            knowhere::Json config;
            config[knowhere::meta::DIM] = DIM;
            config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
            config[knowhere::indexparam::EF] = ef;
            config[knowhere::meta::TOPK] = K;
            
            // 워밍업
            for (int i = 0; i < 3; ++i) {
                auto result = index.Search(query_dataset, config, knowhere::BitsetView());
            }
            
            // 실제 측정
            auto start = std::chrono::high_resolution_clock::now();
            
            auto result = index.Search(query_dataset, config, knowhere::BitsetView());
            
            auto end = std::chrono::high_resolution_clock::now();
            auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
            
            if (!result.has_value()) {
                std::cout << "Search failed for ef=" << ef << std::endl;
                continue;
            }

            if (result.has_value()) {
                auto rows = result.value()->GetRows();
                auto ids = result.value()->GetIds();
                auto distances = result.value()->GetDistance();
                auto dimension = result.value()->GetDim();

                std::cout << "Search successful, returned " << rows << " results" << std::endl;
                std::cout << "Dimension: " << dimension << std::endl;
                // for (int64_t i = 0; i < rows; ++i) {
                //     std::cout << "result IDs and distances for row " << i << ":" << std::endl;
                //     for (int64_t j = 0; j < dimension; ++j) {
                //         std::cout << "ID: " << ids[j] << ", Distance: " << distances[j] << std::endl;
                //     }
                // }
            } else {
                std::cout << "Search failed - this might indicate an issue with the index" << std::endl;
            }
            
            double avg_latency = static_cast<double>(duration.count()) / NQ;
            double qps = 1000000.0 / avg_latency;
            
            std::cout << "ef=" << ef 
                      << ": " << avg_latency << "μs/query"
                      << ", " << static_cast<int>(qps) << " QPS" << std::endl;
        }
    }
    
    // 메모리 사용량 분석 (상세 버전)
    void analyzeMemoryUsage(const std::string& step = "") {
        if (!step.empty()) {
            std::cout << "\n=== 메모리 사용량 분석: " << step << " ===" << std::endl;
        } else {
            std::cout << "\n=== 메모리 사용량 분석 ===" << std::endl;
        }
        
        // /proc/self/status 읽기
        std::ifstream status("/proc/self/status");
        std::string line;
        size_t vmsize = 0, vmrss = 0, vmdata = 0;
        
        while (std::getline(status, line)) {
            if (line.find("VmSize:") == 0) {
                std::cout << line << std::endl;
                sscanf(line.c_str(), "VmSize: %zu kB", &vmsize);
            } else if (line.find("VmRSS:") == 0) {
                std::cout << line << std::endl;
                sscanf(line.c_str(), "VmRSS: %zu kB", &vmrss);
            } else if (line.find("VmData:") == 0) {
                std::cout << line << std::endl;
                sscanf(line.c_str(), "VmData: %zu kB", &vmdata);
            }
        }
        
        // mmap 영역 분석
        std::cout << "\n--- Memory Mapping 분석 ---" << std::endl;
        std::ifstream maps("/proc/self/maps");
        std::string map_line;
        size_t total_file_mapped = 0;
        size_t total_anonymous = 0;
        
        while (std::getline(maps, map_line)) {
            // 인덱스 파일명으로 검색 (경로와 상관없이 파일명만)
            std::filesystem::path index_path(index_file);
            std::string index_filename = index_path.filename().string();
            if (map_line.find(index_filename) != std::string::npos) {
                std::cout << "INDEX FILE: " << map_line << std::endl;
                
                // 주소 범위에서 크기 계산
                size_t start, end;
                sscanf(map_line.c_str(), "%zx-%zx", &start, &end);
                total_file_mapped += (end - start);
            }
            // 큰 익명 메모리 영역 찾기 (100MB 이상)
            else if (map_line.find("rw-p") != std::string::npos && 
                     map_line.find("00:00 0") != std::string::npos) {
                size_t start, end;
                sscanf(map_line.c_str(), "%zx-%zx", &start, &end);
                size_t size = end - start;
                if (size > 100 * 1024 * 1024) {  // 100MB 이상
                    std::cout << "LARGE ANON: " << map_line << " (" << size / 1024 / 1024 << "MB)" << std::endl;
                    total_anonymous += size;
                }
            }
        }
        
        std::cout << "총 파일 매핑: " << total_file_mapped / 1024 / 1024 << " MB" << std::endl;
        std::cout << "총 익명 메모리: " << total_anonymous / 1024 / 1024 << " MB" << std::endl;
        std::cout << "물리 메모리 사용: " << vmrss / 1024 << " MB" << std::endl;
    }
    
// run 메소드 수정
    void run(int batch_size) { // batch_size 파라미터 추가
        try {
            std::cout << "Knowhere HNSW 예제 (PubMed BGE 데이터셋)" << std::endl;
            std::cout << "설정: DIM=" << DIM << ", NB=" << NB 
                      << ", NQ=" << NQ << ", K=" << K << std::endl;
            
            analyzeMemoryUsage("시작");
            
            // 1. [수정] 최적화된 함수로 쿼리 데이터만 로드
            std::vector<float> queries = loadQueryData();

            analyzeMemoryUsage("쿼리 로드 후");
            
            // 2. 인덱스 빌드 및 저장 (배치 방식 사용)
            if (!std::filesystem::exists(index_file)) {
                buildAndSaveIndexInBatches(batch_size);
            } else {
                std::cout << "\n기존 인덱스 파일(" << index_file << ")을 사용합니다. 빌드를 건너뜁니다." << std::endl;
            }

            analyzeMemoryUsage("인덱스 빌드/확인 후");
            
            // 3. HNSW 네이티브 파일에서 인덱스 로딩
            std::cout << "\n=== HNSW 네이티브 파일에서 인덱스 로딩 ===" << std::endl;
            
            auto index1 = loadIndexWithMmap(index_file);
            
            // --- 이하 기존 코드와 동일 ---
            bool stop = false;
            while (!stop) {
                std::cout << "벤치마크 전 메모리 사용량 분석 ===" << std::endl;
                analyzeMemoryUsage();
                benchmarkSearch(index1, queries);
                std::cout << "계속하려면 Enter, 종료하려면 q 입력: ";
                std::string input;
                std::getline(std::cin, input);
                if (input == "q") {
                    stop = true;
                }
            }            

            analyzeMemoryUsage("종료 전");
            
            std::cout << "\n=== HNSW PubMed BGE Apache Arrow 예제 완료 ===" << std::endl;
            
        } catch (const std::exception& e) {
            std::cerr << "오류: " << e.what() << std::endl;
        }
    }
};

void printUsage(const char* program_name) {
    std::cout << "사용법: " << program_name << " [옵션들]" << std::endl;
    std::cout << "옵션들:" << std::endl;
    std::cout << "  --dim <int>           임베딩 차원 (기본값: 768)" << std::endl;
    std::cout << "  --nb <int>            데이터베이스 크기 (기본값: 50000)" << std::endl;
    std::cout << "  --nq <int>            쿼리 개수 (기본값: 100)" << std::endl;
    std::cout << "  --k <int>             반환할 Top-K 결과 (기본값: 10)" << std::endl;
    std::cout << "  --beg-id <int>        시작 ID (기본값: 0)" << std::endl;
    std::cout << "  --batch-size <int>    배치 처리 크기 (기본값: 50000, 메모리 절약용)" << std::endl;
    std::cout << "  --dataset-dir <path>  PubMed BGE 데이터셋 디렉토리 경로" << std::endl;
    std::cout << "                        (기본값: /home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_100000)" << std::endl;
    std::cout << "  --index-file <path>   인덱스 파일 경로 (기본값: hnsw_index.bin)" << std::endl;
    std::cout << "  --help, -h            이 도움말 표시" << std::endl;
    std::cout << std::endl;
    std::cout << "예시:" << std::endl;
    std::cout << "  " << program_name << " --nb 28000000 --batch-size 100000" << std::endl;
    std::cout << "  " << program_name << " --dataset-dir /path/to/pubmed/dataset/ --index-file my_index.bin" << std::endl;
    std::cout << std::endl;
    std::cout << "대용량 데이터 처리:" << std::endl;
    std::cout << "  28M 벡터의 경우: --nb 28000000 --batch-size 50000 (메모리 절약)" << std::endl;
    std::cout << "  배치 크기를 줄이면 메모리 사용량이 감소하지만 처리 시간이 증가합니다." << std::endl;
    std::cout << std::endl;
    std::cout << "참고:" << std::endl;
    std::cout << "  이 프로그램은 Python의 save_to_disk으로 저장된 PubMed BGE 데이터셋을 직접 읽습니다." << std::endl;
    std::cout << "  Apache Arrow 형식(.arrow 파일)을 자동으로 찾아서 로드합니다." << std::endl;
}

int main(int argc, char* argv[]) {
    // 기본값 설정
    int dim = 768;
    int nb = 50000;
    int nq = 100;
    int k = 10;
    int beg_id = 0;          // 시작 ID 추가
    int batch_size = 50000;  // 배치 크기 추가
    std::string dataset_dir = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_100000";
    std::string index_file = "hnsw_index.bin";
    
    // Command line argument 파싱
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        
        if (arg == "--help" || arg == "-h") {
            printUsage(argv[0]);
            return 0;
        } else if (arg == "--dim" && i + 1 < argc) {
            dim = std::atoi(argv[++i]);
        } else if (arg == "--nb" && i + 1 < argc) {
            nb = std::atoi(argv[++i]);
        } else if (arg == "--nq" && i + 1 < argc) {
            nq = std::atoi(argv[++i]);
        } else if (arg == "--k" && i + 1 < argc) {
            k = std::atoi(argv[++i]);
        } else if (arg == "--beg-id" && i + 1 < argc) {
            beg_id = std::atoi(argv[++i]);
        } else if (arg == "--batch-size" && i + 1 < argc) {
            batch_size = std::atoi(argv[++i]);
        } else if (arg == "--dataset-dir" && i + 1 < argc) {
            dataset_dir = argv[++i];
        } else if (arg == "--index-file" && i + 1 < argc) {
            index_file = argv[++i];
        } else {
            std::cerr << "알 수 없는 옵션: " << arg << std::endl;
            printUsage(argv[0]);
            return 1;
        }
    }
    
    // 파라미터 유효성 검사
    if (dim <= 0 || nb <= 0 || nq <= 0 || k <= 0 || batch_size <= 0) {
        std::cerr << "오류: 모든 수치 파라미터는 양수여야 합니다." << std::endl;
        return 1;
    }
    
    
    try {
        AdvancedHNSWMmapExample example(dim, nb, nq, k, beg_id, dataset_dir, index_file);
        
        // 나머지는 기존과 동일
        example.run(batch_size);
        
    } catch (const std::exception& e) {
        std::cerr << "실행 오류: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}

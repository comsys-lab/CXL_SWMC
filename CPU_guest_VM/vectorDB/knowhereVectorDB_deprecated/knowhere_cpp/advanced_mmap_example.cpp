/**
 * 향상된 HNSW 예제 - Faiss HNSW 백엔드 사용
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

class AdvancedHNSWMmapExample {
private:
    static constexpr int DIM = 384;
    static constexpr int NB = 500000;  
    static constexpr int NQ = 100;    
    static constexpr int K = 10;      

public:
    // 테스트 데이터 생성 (정규분포 사용)
    std::pair<std::vector<float>, std::vector<float>> generateData() {
        std::cout << "=== 테스트 데이터 생성 ===" << std::endl;
        
        std::random_device rd;
        std::mt19937 gen(42);
        std::normal_distribution<float> dis(0.0f, 1.0f);
        
        std::vector<float> database(NB * DIM);
        std::vector<float> queries(NQ * DIM);
        
        // 클러스터된 데이터 생성 (더 현실적인 분포)
        for (int i = 0; i < NB; ++i) {
            int cluster = i % 10;  // 10개 클러스터
            float cluster_offset = cluster * 2.0f;
            
            for (int j = 0; j < DIM; ++j) {
                database[i * DIM + j] = dis(gen) + cluster_offset;
            }
        }
        
        for (int i = 0; i < NQ; ++i) {
            for (int j = 0; j < DIM; ++j) {
                queries[i * DIM + j] = dis(gen);
            }
        }
        
        std::cout << "데이터 생성 완료: DB=" << NB << "x" << DIM 
                  << ", Query=" << NQ << "x" << DIM << std::endl;
        
        return std::make_pair(std::move(database), std::move(queries));
    }
    
    // HNSW 인덱스 생성 (최적화된 파라미터)
    void buildAndSaveIndex(const std::vector<float>& database, 
                          const std::string& index_file) {
        std::cout << "\n=== HNSW 인덱스 빌드 (mmap 지원) ===" << std::endl;
        
        auto start = std::chrono::high_resolution_clock::now();
        
        auto dataset = knowhere::GenDataSet(NB, DIM, database.data());
        auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
        
        // HNSW 인덱스 생성 (Faiss 백엔드)
        auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>("HNSW", version);
        
        if (!index.has_value()) {
            throw std::runtime_error("Failed to create HNSW index");
        }
        
        // 최적화된 HNSW 파라미터
        knowhere::Json config;
        config[knowhere::meta::DIM] = DIM;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
        config[knowhere::indexparam::HNSW_M] = 32;           // 더 높은 연결성
        config[knowhere::indexparam::EFCONSTRUCTION] = 400;  // 더 정확한 빌드
        config[knowhere::indexparam::EF] = 200;              // 검색 품질
        config[knowhere::meta::TOPK] = K;
        
        // mmap 지원 활성화
        config["enable_mmap"] = true;
        
        std::cout << "HNSW 파라미터: M=" << config[knowhere::indexparam::HNSW_M] 
                  << ", efConstruction=" << config[knowhere::indexparam::EFCONSTRUCTION] << std::endl;
        
        auto status = index.value().Build(dataset, config);
        if (status != knowhere::Status::success) {
            throw std::runtime_error("Failed to build index");
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
        std::cout << "인덱스 빌드 완료: " << duration.count() << "ms" << std::endl;
        
        // Knowhere 네이티브 mmap 형식으로 저장
        saveIndexWithMmapSupport(index.value(), index_file, config);
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
        
        // DeserializeFromFile이 실패하면 수동 로드 (fallback)
        std::cout << "DeserializeFromFile 실패, 수동 로드로 fallback..." << std::endl;
        
        // 파일에서 직접 읽어서 BinarySet 구성
        std::ifstream ifs(index_file, std::ios::binary);
        if (!ifs) {
            throw std::runtime_error("Failed to open file for reading");
        }
        
        // 파일 전체를 메모리로 읽기
        ifs.seekg(0, std::ios::end);
        size_t file_size = ifs.tellg();
        ifs.seekg(0, std::ios::beg);
        
        auto data = std::make_shared<knowhere::Binary>();
        data->data.reset(new uint8_t[file_size]);
        data->size = file_size;
        ifs.read(reinterpret_cast<char*>(data->data.get()), file_size);
        ifs.close();
        
        // BinarySet 구성
        knowhere::BinarySet binary_set;
        binary_set.Append("HNSW", data);
        
        std::cout << "수동 로드된 HNSW 데이터: " << file_size / 1024 << " KB" << std::endl;
        
        // BinarySet에서 역직렬화
        knowhere::Json json_config;
        json_config[knowhere::meta::DIM] = DIM;
        json_config[knowhere::meta::METRIC_TYPE] = knowhere::metric::L2;
        
        status = index.value().Deserialize(binary_set, json_config);
        if (status != knowhere::Status::success) {
            throw std::runtime_error("Failed to deserialize from BinarySet");
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
        std::cout << "수동 BinarySet 로드 완료: " << duration.count() << "ms" << std::endl;
        
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
                for (int64_t i = 0; i < rows; ++i) {
                    std::cout << "result IDs and distances for row " << i << ":" << std::endl;
                    for (int64_t j = 0; j < dimension; ++j) {
                        std::cout << "ID: " << ids[j] << ", Distance: " << distances[j] << std::endl;
                    }
                }
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
            if (map_line.find("hnsw_index.bin") != std::string::npos) {
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
    
    // 메인 워크플로우
    void run() {
        try {
            std::cout << "Knowhere HNSW 예제 (mmap 지원)" << std::endl;
            std::cout << "설정: DIM=" << DIM << ", NB=" << NB 
                      << ", NQ=" << NQ << ", K=" << K << std::endl;
            
            analyzeMemoryUsage();
            
            // 1. 데이터 생성
            auto [database, queries] = generateData();
            
            // 2. 인덱스 빌드 및 저장
            const std::string index_file = "hnsw_index.bin";

            // 2.1 인덱스가 이미 존재하는 경우 build 하지 않음
            if (!std::filesystem::exists(index_file)) {
                buildAndSaveIndex(database, index_file);
            }

            analyzeMemoryUsage();
            
            // 3. HNSW 네이티브 파일에서 인덱스 로딩
            std::cout << "\n=== HNSW 네이티브 파일에서 인덱스 로딩 ===" << std::endl;
            
            auto index1 = loadIndexWithMmap(index_file);
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

            analyzeMemoryUsage();
            
            std::cout << "\n=== HNSW 네이티브 mmap 예제 완료 ===" << std::endl;
            std::cout << "핵심 장점:" << std::endl;
            std::cout << "1. 네이티브 HNSW 포맷으로 저장/로드" << std::endl;
            std::cout << "2. DeserializeFromFile로 효율적인 mmap 로드" << std::endl;
            std::cout << "3. FAISS 백엔드와 완전 호환" << std::endl;
            std::cout << "4. 진정한 zero-copy 메모리 매핑 지원" << std::endl;
            
        } catch (const std::exception& e) {
            std::cerr << "오류: " << e.what() << std::endl;
        }
    }
};

int main() {
    AdvancedHNSWMmapExample example;
    example.run();
    
    return 0;
}

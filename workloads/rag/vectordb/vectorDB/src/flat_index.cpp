#include "flat_index.h"
#include <algorithm>
#include <omp.h>

AppendOnlyFlatIndex::AppendOnlyFlatIndex(const std::string& file_path,
                                         size_t vector_dim,
                                         size_t max_vectors)
    : file_path_(file_path), fd_(-1), 
      mapped_header_(nullptr), mapped_data_(nullptr), mapped_ids_(nullptr),
      vector_dim_(vector_dim), max_capacity_(max_vectors) {
}

AppendOnlyFlatIndex::~AppendOnlyFlatIndex() {
    cleanup();
}

bool AppendOnlyFlatIndex::initialize() {
    // 파일 크기 계산: 헤더 + 벡터 데이터 + ID 데이터
    size_t header_size = sizeof(FlatIndexHeader);
    size_t vector_data_size = max_capacity_ * vector_dim_ * sizeof(float);
    size_t id_data_size = max_capacity_ * sizeof(uint64_t);
    size_t total_size = header_size + vector_data_size + id_data_size;
    
    // 파일이 존재하는지 확인
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
    mapped_header_ = static_cast<FlatIndexHeader*>(mapped_ptr);
    mapped_data_ = reinterpret_cast<float*>(
        static_cast<char*>(mapped_ptr) + header_size);
    mapped_ids_ = reinterpret_cast<uint64_t*>(
        static_cast<char*>(mapped_ptr) + header_size + vector_data_size);
    
    // 새 파일인 경우 헤더 초기화
    if (!file_exists) {
        mapped_header_->magic_number = MAGIC_NUMBER;
        mapped_header_->version = VERSION;
        mapped_header_->vector_dim = vector_dim_;
        mapped_header_->max_vectors = max_capacity_;
        mapped_header_->current_count = 0;
        for (int i = 0; i < 3; ++i) {
            mapped_header_->reserved[i] = 0;
        }
        
        // 헤더 동기화
        msync(mapped_header_, sizeof(FlatIndexHeader), MS_SYNC);
        
        std::cout << "Initialized new flat index:" << std::endl;
        std::cout << "  - Dimension: " << vector_dim_ << std::endl;
        std::cout << "  - Max vectors: " << max_capacity_ << std::endl;
    } else {
        // 기존 파일인 경우 헤더 검증
        if (mapped_header_->magic_number != MAGIC_NUMBER) {
            std::cerr << "Invalid flat index file: wrong magic number" << std::endl;
            munmap(mapped_ptr, total_size);
            close(fd_);
            return false;
        }
        
        if (mapped_header_->version != VERSION) {
            std::cerr << "Unsupported flat index version: " << mapped_header_->version << std::endl;
            munmap(mapped_ptr, total_size);
            close(fd_);
            return false;
        }
        
        if (mapped_header_->vector_dim != vector_dim_) {
            std::cerr << "Vector dimension mismatch: file has " << mapped_header_->vector_dim 
                      << ", expected " << vector_dim_ << std::endl;
            munmap(mapped_ptr, total_size);
            close(fd_);
            return false;
        }
        
        if (mapped_header_->max_vectors != max_capacity_) {
            std::cerr << "Max vectors mismatch: file has " << mapped_header_->max_vectors 
                      << ", expected " << max_capacity_ << std::endl;
            munmap(mapped_ptr, total_size);
            close(fd_);
            return false;
        }
        
        std::cout << "Loaded existing flat index:" << std::endl;
        std::cout << "  - Dimension: " << mapped_header_->vector_dim << std::endl;
        std::cout << "  - Max vectors: " << mapped_header_->max_vectors << std::endl;
        std::cout << "  - Current count: " << mapped_header_->current_count << std::endl;
    }
    
    std::cout << "Flat index initialized successfully" << std::endl;
    return true;
}

bool AppendOnlyFlatIndex::insert(const VectorData& vector_data) {
    if (vector_data.vector.size() != vector_dim_) {
        std::cerr << "Vector dimension mismatch: " << vector_data.vector.size() 
                  << " != " << vector_dim_ << std::endl;
        return false;
    }
    
    std::lock_guard<std::mutex> lock(write_mutex_);
    
    size_t current_idx = mapped_header_->current_count;
    if (current_idx >= max_capacity_) {
        std::cerr << "Flat index is full" << std::endl;
        return false;
    }
    
    // 벡터 데이터 복사
    std::memcpy(&mapped_data_[current_idx * vector_dim_], 
                vector_data.vector.data(), 
                vector_dim_ * sizeof(float));
    
    // ID 저장
    mapped_ids_[current_idx] = vector_data.id;
    
    // 카운트 증가
    mapped_header_->current_count = current_idx + 1;
    
    // 메모리 동기화
    msync(&mapped_data_[current_idx * vector_dim_], vector_dim_ * sizeof(float), MS_ASYNC);
    msync(&mapped_ids_[current_idx], sizeof(uint64_t), MS_ASYNC);
    msync(mapped_header_, sizeof(FlatIndexHeader), MS_ASYNC);
    
    return true;
}

std::vector<SearchResult> AppendOnlyFlatIndex::bruteForceSearch(
    const std::vector<float>& query, int k) const {
    
    if (query.size() != vector_dim_) {
        std::cerr << "Query dimension mismatch" << std::endl;
        return {};
    }
    
    size_t count = mapped_header_->current_count;
    if (count == 0) {
        return {};
    }
    
    std::vector<SearchResult> results(count);
    
    // 모든 벡터와의 거리 계산 (COSINE 거리)
    #pragma omp parallel for
    for (size_t i = 0; i < count; ++i) {
        float dot_product = 0.0f;
        float norm_query = 0.0f;
        float norm_data = 0.0f;
        
        const float* data_vector_ptr = &mapped_data_[i * vector_dim_];
        
        for (size_t j = 0; j < vector_dim_; ++j) {
            float query_val = query[j];
            float data_val = data_vector_ptr[j];
            
            dot_product += query_val * data_val;
            norm_query += query_val * query_val;
            norm_data += data_val * data_val;
        }
        
        float cosine_sim = dot_product / (std::sqrt(norm_query) * std::sqrt(norm_data) + 1e-10f);
        float distance = 1.0f - cosine_sim;
        
        results[i] = SearchResult(mapped_ids_[i], distance);
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
    if (mapped_header_ != nullptr) {
        size_t header_size = sizeof(FlatIndexHeader);
        size_t vector_data_size = max_capacity_ * vector_dim_ * sizeof(float);
        size_t id_data_size = max_capacity_ * sizeof(uint64_t);
        size_t total_size = header_size + vector_data_size + id_data_size;
        
        munmap(mapped_header_, total_size);
        mapped_header_ = nullptr;
        mapped_data_ = nullptr;
        mapped_ids_ = nullptr;
    }
    
    if (fd_ != -1) {
        close(fd_);
        fd_ = -1;
    }
}

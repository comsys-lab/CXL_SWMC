#include "ivf_index.h"

#include "flat_index.h"
#include "knowhere/comp/brute_force.h"
#include "knowhere/comp/knowhere_config.h"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <omp.h>

namespace {
bool
DebugEnabled() {
    static const bool enabled = []() {
        const char* v = std::getenv("VDB_DEBUG");
        return v != nullptr && std::string(v) == "1";
    }();
    return enabled;
}

size_t
GetKnowhereThreadPoolSize() {
    constexpr size_t kDefaultThreads = 64;
    const char* v = std::getenv("VDB_KNOWHERE_THREAD_POOL_SIZE");
    if (v == nullptr) {
        return kDefaultThreads;
    }
    int parsed = std::atoi(v);
    return parsed > 0 ? static_cast<size_t>(parsed) : kDefaultThreads;
}
}  // namespace

IVFIndexManager::IVFIndexManager(const std::string& index_dir, size_t vector_dim, int nprobe)
    : vector_dim_(vector_dim), index_dir_(index_dir), nprobe_(nprobe) {
    const char* env_nprobe = std::getenv("VDB_NPROBE");
    if (env_nprobe != nullptr) {
        int parsed = std::atoi(env_nprobe);
        if (parsed > 0) {
            nprobe_ = parsed;
        }
    }
}

IVFIndexManager::~IVFIndexManager() {
}

bool IVFIndexManager::initialize() {
    std::cout << "=== IVF Index Manager 초기화 ===" << std::endl;

    const size_t thread_pool_size = GetKnowhereThreadPoolSize();
    knowhere::KnowhereConfig::SetBuildThreadPoolSize(thread_pool_size);
    knowhere::KnowhereConfig::SetSearchThreadPoolSize(thread_pool_size);

    if (!loadIndices()) {
        std::cerr << "Failed to load IVF indices" << std::endl;
        return false;
    }

    std::cout << "IVF Index Manager 초기화 완료" << std::endl;
    std::cout << "- 로드된 인덱스 개수: " << indices_.size() << std::endl;
    std::cout << "- 전체 벡터 개수: " << getTotalVectorCount() << std::endl;
    std::cout << "- nprobe: " << nprobe_ << std::endl;
    std::cout << "- knowhere build/search thread pool: " << thread_pool_size << std::endl;

    return true;
}

bool IVFIndexManager::loadIndices() {
    std::cout << "IVF 인덱스들 로드 중: " << index_dir_ << std::endl;

    if (!std::filesystem::exists(index_dir_)) {
        std::cerr << "IVF index directory not found: " << index_dir_ << std::endl;
        return false;
    }

    std::vector<std::string> index_files;
    for (const auto& entry : std::filesystem::directory_iterator(index_dir_)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        std::string filename = entry.path().filename().string();
        if (filename.find("ivf_index_") == 0 && filename.find(".bin") != std::string::npos) {
            index_files.push_back(entry.path().string());
        }
    }

    if (index_files.empty()) {
        std::cerr << "No IVF index files found matching pattern ivf_index_*.bin" << std::endl;
        return false;
    }

    std::sort(index_files.begin(), index_files.end());

    indices_.clear();
    index_paths_.clear();
    index_beg_ids_.clear();

    int beg_id = 0;
    auto version = knowhere::Version::GetCurrentVersion().VersionNumber();

    for (const auto& index_path : index_files) {
        auto index = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(
            knowhere::IndexEnum::INDEX_FAISS_IVFFLAT,
            version);
        if (!index.has_value()) {
            std::cerr << "Failed to create IVF_FLAT index instance for " << index_path << std::endl;
            return false;
        }

        knowhere::Json config;
        config[knowhere::meta::DIM] = vector_dim_;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
        config["enable_mmap"] = true;

        auto status = index.value().DeserializeFromFile(index_path, config);
        if (status != knowhere::Status::success) {
            std::cerr << "Failed to deserialize IVF index from file: " << index_path
                      << ", status: " << static_cast<int>(status) << std::endl;
            return false;
        }

        int64_t count = index.value().Count();
        std::cout << "Loaded IVF index: " << index_path << " (" << count << " vectors)" << std::endl;

        indices_.push_back(std::move(index.value()));
        index_paths_.push_back(index_path);
        index_beg_ids_.push_back(beg_id);
        beg_id += static_cast<int>(count);
    }

    return true;
}

size_t IVFIndexManager::getTotalVectorCount() const {
    size_t total = 0;
    for (const auto& index : indices_) {
        total += index.Count();
    }
    return total;
}

std::vector<SearchResult> IVFIndexManager::searchSingleIndex(
    size_t index_idx,
    const std::vector<float>& query,
    int k) const {

    std::vector<SearchResult> results;

    auto query_dataset = knowhere::GenDataSet(1, vector_dim_, query.data());
    knowhere::Json config;
    config[knowhere::meta::DIM] = vector_dim_;
    config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
    config[knowhere::indexparam::NPROBE] = nprobe_;
    config[knowhere::meta::TOPK] = static_cast<int64_t>(k);

    auto result = indices_[index_idx].Search(query_dataset, config, knowhere::BitsetView());
    if (!result.has_value()) {
        return results;
    }

    auto ids = result.value()->GetIds();
    auto distances = result.value()->GetDistance();
    int64_t num_results = result.value()->GetDim();

    for (int64_t j = 0; j < num_results; ++j) {
        if (ids[j] >= 0) {
            results.emplace_back(
                static_cast<uint64_t>(ids[j] + index_beg_ids_[index_idx]),
                1.0f - distances[j]);  // cosine similarity → cosine distance
        }
    }

    return results;
}

std::vector<SearchResult> IVFIndexManager::search(const std::vector<float>& query, int k) const {
    if (query.size() != vector_dim_) {
        std::cerr << "Query dimension mismatch in IVF search" << std::endl;
        return {};
    }

    std::vector<std::future<std::vector<SearchResult>>> futures;
    for (size_t i = 0; i < indices_.size(); ++i) {
        futures.emplace_back(std::async(std::launch::async,
                                        [this, i, &query, k]() { return searchSingleIndex(i, query, k); }));
    }

    std::vector<SearchResult> all_results;
    for (auto& fut : futures) {
        auto part = fut.get();
        all_results.insert(all_results.end(), part.begin(), part.end());
    }

    if (all_results.empty()) {
        return all_results;
    }

    std::partial_sort(all_results.begin(),
                      all_results.begin() + std::min(k, static_cast<int>(all_results.size())),
                      all_results.end(),
                      [](const SearchResult& a, const SearchResult& b) { return a.distance < b.distance; });

    if (static_cast<int>(all_results.size()) > k) {
        all_results.resize(k);
    }

    return all_results;
}

std::vector<std::vector<SearchResult>> IVFIndexManager::searchBatch(
    const std::vector<std::vector<float>>& queries,
    int k,
    std::vector<float>& reused_batch_buffer) const {

    const auto batch_begin = std::chrono::steady_clock::now();

    if (queries.empty()) {
        return {};
    }

    const size_t batch_size = queries.size();
    for (const auto& query : queries) {
        if (query.size() != vector_dim_) {
            std::cerr << "Query dimension mismatch in IVF batch search" << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }

    const size_t required_size = batch_size * vector_dim_;
    reused_batch_buffer.clear();
    reused_batch_buffer.reserve(required_size);
    for (const auto& query : queries) {
        reused_batch_buffer.insert(reused_batch_buffer.end(), query.begin(), query.end());
    }

    if (DebugEnabled()) {
        std::cout << "[IVF][searchBatch] start batch_size=" << batch_size
                  << " k=" << k
                  << " shard_count=" << indices_.size() << std::endl;
    }

    std::vector<std::future<std::vector<std::vector<SearchResult>>>> futures;
    for (size_t i = 0; i < indices_.size(); ++i) {
        futures.emplace_back(std::async(std::launch::async,
                                        [this, i, &reused_batch_buffer, batch_size, k]() {
                                            const auto shard_begin = std::chrono::steady_clock::now();
                                            std::vector<std::vector<SearchResult>> batch_results(batch_size);

                                            auto batch_dataset = knowhere::GenDataSet(
                                                batch_size, vector_dim_, reused_batch_buffer.data());

                                            knowhere::Json config;
                                            config[knowhere::meta::DIM] = vector_dim_;
                                            config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
                                            config[knowhere::indexparam::NPROBE] = nprobe_;
                                            config[knowhere::meta::TOPK] = static_cast<int64_t>(k);

                                            auto result =
                                                indices_[i].Search(batch_dataset, config, knowhere::BitsetView());
                                            if (!result.has_value()) {
                                                if (DebugEnabled()) {
                                                    const auto shard_end = std::chrono::steady_clock::now();
                                                    std::cout << "[IVF][searchBatch] shard=" << i
                                                              << " no_result"
                                                              << " elapsed_ms="
                                                              << std::chrono::duration_cast<std::chrono::milliseconds>(
                                                                     shard_end - shard_begin)
                                                                     .count()
                                                              << std::endl;
                                                }
                                                return batch_results;
                                            }

                                            auto rows = result.value()->GetRows();
                                            auto ids = result.value()->GetIds();
                                            auto distances = result.value()->GetDistance();
                                            auto dim = result.value()->GetDim();

                                            for (int64_t row = 0; row < rows; ++row) {
                                                for (int64_t j = 0; j < dim; ++j) {
                                                    int64_t idx = row * dim + j;
                                                    if (ids[idx] >= 0) {
                                                        batch_results[row].emplace_back(
                                                            static_cast<uint64_t>(ids[idx] + index_beg_ids_[i]),
                                                            1.0f - distances[idx]);  // cosine similarity → cosine distance
                                                    }
                                                }
                                            }

                                            if (DebugEnabled()) {
                                                const auto shard_end = std::chrono::steady_clock::now();
                                                std::cout << "[IVF][searchBatch] shard=" << i
                                                          << " rows=" << rows
                                                          << " topk=" << dim
                                                          << " elapsed_ms="
                                                          << std::chrono::duration_cast<std::chrono::milliseconds>(
                                                                 shard_end - shard_begin)
                                                                 .count()
                                                          << std::endl;
                                            }

                                            return batch_results;
                                        }));
    }

    std::vector<std::vector<std::vector<SearchResult>>> all_index_results;
    for (auto& fut : futures) {
        all_index_results.push_back(fut.get());
    }

    std::vector<std::vector<SearchResult>> final_results(batch_size);
    for (size_t query_idx = 0; query_idx < batch_size; ++query_idx) {
        std::vector<SearchResult> merged;
        for (const auto& index_results : all_index_results) {
            merged.insert(
                merged.end(), index_results[query_idx].begin(), index_results[query_idx].end());
        }

        if (!merged.empty()) {
            std::partial_sort(merged.begin(),
                              merged.begin() + std::min(k, static_cast<int>(merged.size())),
                              merged.end(),
                              [](const SearchResult& a, const SearchResult& b) {
                                  return a.distance < b.distance;
                              });
        }

        if (static_cast<int>(merged.size()) > k) {
            merged.resize(k);
        }

        final_results[query_idx] = std::move(merged);
    }

    if (DebugEnabled()) {
        const auto batch_end = std::chrono::steady_clock::now();
        std::cout << "[IVF][searchBatch] done elapsed_ms="
                  << std::chrono::duration_cast<std::chrono::milliseconds>(batch_end - batch_begin).count()
                  << std::endl;
    }

    return final_results;
}

bool IVFIndexManager::hasRawData() const {
    if (indices_.empty()) {
        return false;
    }
    return indices_[0].HasRawData(knowhere::metric::COSINE);
}

std::vector<SearchResult> IVFIndexManager::exactSearch(const std::vector<float>& query, int k) const {
    if (query.size() != vector_dim_) {
        std::cerr << "Query dimension mismatch in IVF exact search" << std::endl;
        return {};
    }

    if (!hasRawData()) {
        std::cerr << "IVF indices do not contain raw data for exact search" << std::endl;
        return {};
    }

    auto query_dataset = knowhere::GenDataSet(1, vector_dim_, query.data());
    std::vector<SearchResult> all_results;
    int global_id_offset = 0;

    for (size_t idx = 0; idx < indices_.size(); ++idx) {
        int64_t count = indices_[idx].Count();
        std::vector<int64_t> ids(count);
        for (int64_t i = 0; i < count; ++i) {
            ids[i] = i;
        }

        auto id_dataset = knowhere::GenDataSet(count, 1, ids.data());
        auto vectors = indices_[idx].GetVectorByIds(id_dataset);
        if (!vectors.has_value()) {
            global_id_offset += static_cast<int>(count);
            continue;
        }

        auto extracted = vectors.value();
        const float* data_ptr = reinterpret_cast<const float*>(extracted->GetTensor());
        auto base_dataset = knowhere::GenDataSet(count, vector_dim_, data_ptr);

        knowhere::Json config;
        config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
        config[knowhere::meta::TOPK] = k;

        auto search_result = knowhere::BruteForce::Search<knowhere::fp32>(
            base_dataset, query_dataset, config, knowhere::BitsetView());
        if (!search_result.has_value()) {
            global_id_offset += static_cast<int>(count);
            continue;
        }

        auto result_dataset = search_result.value();
        auto result_ids = result_dataset->GetIds();
        auto result_dists = result_dataset->GetDistance();
        int result_k = result_dataset->GetDim();

        for (int i = 0; i < result_k; ++i) {
            if (result_ids[i] >= 0) {
                all_results.emplace_back(
                    static_cast<uint64_t>(global_id_offset + result_ids[i]),
                    1.0f - result_dists[i]);  // cosine similarity → cosine distance
            }
        }

        global_id_offset += static_cast<int>(count);
    }

    if (!all_results.empty()) {
        std::partial_sort(all_results.begin(),
                          all_results.begin() + std::min(k, static_cast<int>(all_results.size())),
                          all_results.end(),
                          [](const SearchResult& a, const SearchResult& b) {
                              return a.distance < b.distance;
                          });
    }

    if (static_cast<int>(all_results.size()) > k) {
        all_results.resize(k);
    }

    return all_results;
}

std::vector<std::vector<SearchResult>> IVFIndexManager::exactSearchBatch(
    const std::vector<std::vector<float>>& queries,
    int k) const {

    if (queries.empty()) {
        return {};
    }

    const size_t batch_size = queries.size();
    for (const auto& query : queries) {
        if (query.size() != vector_dim_) {
            std::cerr << "Query dimension mismatch in IVF exact batch search" << std::endl;
            return std::vector<std::vector<SearchResult>>(batch_size);
        }
    }

    if (!hasRawData()) {
        std::cerr << "IVF indices do not contain raw data for exact search" << std::endl;
        return std::vector<std::vector<SearchResult>>(batch_size);
    }

    std::vector<std::vector<SearchResult>> batch_results(batch_size);
#pragma omp parallel for
    for (size_t i = 0; i < batch_size; ++i) {
        batch_results[i] = exactSearch(queries[i], k);
    }

    return batch_results;
}

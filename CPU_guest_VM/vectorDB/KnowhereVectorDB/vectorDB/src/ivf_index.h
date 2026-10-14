#pragma once

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <memory>
#include <string>
#include <vector>

// Knowhere headers
#include <knowhere/comp/index_param.h>
#include <knowhere/config.h>
#include <knowhere/dataset.h>
#include <knowhere/index/index_factory.h>
#include <knowhere/version.h>

struct SearchResult;

class IVFIndexManager {
private:
    static constexpr size_t DEFAULT_VECTOR_DIM = 768;
    static constexpr int DEFAULT_NPROBE = 32;

    std::vector<knowhere::Index<knowhere::IndexNode>> indices_;
    std::vector<std::string> index_paths_;
    std::vector<int> index_beg_ids_;
    size_t vector_dim_;
    std::string index_dir_;
    int nprobe_;

public:
    IVFIndexManager(const std::string& index_dir,
                    size_t vector_dim = DEFAULT_VECTOR_DIM,
                    int nprobe = DEFAULT_NPROBE);
    ~IVFIndexManager();

    bool initialize();

    std::vector<SearchResult> search(const std::vector<float>& query, int k) const;

    std::vector<SearchResult> exactSearch(const std::vector<float>& query, int k) const;

    std::vector<std::vector<SearchResult>> searchBatch(
        const std::vector<std::vector<float>>& queries,
        int k,
        std::vector<float>& reused_batch_buffer) const;

    std::vector<std::vector<SearchResult>> exactSearchBatch(
        const std::vector<std::vector<float>>& queries,
        int k) const;

    size_t getIndexCount() const { return indices_.size(); }
    size_t getTotalVectorCount() const;
    const std::vector<std::string>& getIndexPaths() const { return index_paths_; }
    bool hasRawData() const;

private:
    bool loadIndices();
    std::vector<SearchResult> searchSingleIndex(size_t index_idx,
                                                const std::vector<float>& query,
                                                int k) const;
};

#include <arrow/api.h>
#include <arrow/array.h>
#include <arrow/io/api.h>
#include <arrow/ipc/api.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <knowhere/comp/index_param.h>
#include <knowhere/config.h>
#include <knowhere/dataset.h>
#include <knowhere/index/index_factory.h>
#include <knowhere/version.h>

namespace {

std::vector<std::string>
CollectArrowFiles(const std::string& dataset_dir) {
    std::vector<std::string> files;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(dataset_dir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".arrow") {
            files.push_back(entry.path().string());
        }
    }
    std::sort(files.begin(), files.end());
    return files;
}

bool
LoadEmbeddingsFromArrow(const std::string& file_path,
                        int dim,
                        int64_t max_vectors,
                        std::vector<float>& out_vectors) {
    auto file_result = arrow::io::ReadableFile::Open(file_path);
    if (!file_result.ok()) {
        std::cerr << "Failed to open arrow file: " << file_path << std::endl;
        return false;
    }

    auto stream_reader_result = arrow::ipc::RecordBatchStreamReader::Open(file_result.ValueOrDie());
    if (!stream_reader_result.ok()) {
        std::cerr << "Failed to create stream reader: " << file_path << std::endl;
        return false;
    }

    auto table_result = stream_reader_result.ValueOrDie()->ToTable();
    if (!table_result.ok()) {
        std::cerr << "Failed to parse arrow table: " << file_path << std::endl;
        return false;
    }

    auto table = table_result.ValueOrDie();
    auto embedding_column = table->GetColumnByName("embedding");
    if (!embedding_column) {
        std::cerr << "No embedding column in: " << file_path << std::endl;
        return false;
    }

    int64_t appended = 0;
    for (int chunk_idx = 0; chunk_idx < embedding_column->num_chunks(); ++chunk_idx) {
        if (max_vectors > 0 && appended >= max_vectors) {
            break;
        }

        auto chunk = embedding_column->chunk(chunk_idx);
        if (auto fixed_list = std::dynamic_pointer_cast<arrow::FixedSizeListArray>(chunk)) {
            auto values = std::dynamic_pointer_cast<arrow::FloatArray>(fixed_list->values());
            if (!values) {
                std::cerr << "Embedding values must be FloatArray" << std::endl;
                return false;
            }

            const int64_t rows = fixed_list->length();
            const float* raw = values->raw_values();
            int64_t rows_to_copy = rows;

            if (max_vectors > 0) {
                rows_to_copy = std::min(rows_to_copy, max_vectors - appended);
            }

            out_vectors.insert(out_vectors.end(), raw, raw + rows_to_copy * dim);
            appended += rows_to_copy;
            continue;
        }

        if (auto list = std::dynamic_pointer_cast<arrow::ListArray>(chunk)) {
            auto values = std::dynamic_pointer_cast<arrow::FloatArray>(list->values());
            if (!values) {
                std::cerr << "Embedding values must be FloatArray" << std::endl;
                return false;
            }

            const int64_t rows = list->length();
            int64_t rows_to_copy = rows;
            if (max_vectors > 0) {
                rows_to_copy = std::min(rows_to_copy, max_vectors - appended);
            }

            for (int64_t row = 0; row < rows_to_copy; ++row) {
                const int32_t begin = list->value_offset(row);
                const int32_t end = list->value_offset(row + 1);
                if (end - begin != dim) {
                    std::cerr << "Embedding dimension mismatch in ListArray: "
                              << (end - begin) << " != " << dim << std::endl;
                    return false;
                }
                for (int32_t i = begin; i < end; ++i) {
                    out_vectors.push_back(values->Value(i));
                }
            }

            appended += rows_to_copy;
            continue;
        }

        if (auto large_list = std::dynamic_pointer_cast<arrow::LargeListArray>(chunk)) {
            auto values = std::dynamic_pointer_cast<arrow::FloatArray>(large_list->values());
            if (!values) {
                std::cerr << "Embedding values must be FloatArray" << std::endl;
                return false;
            }

            const int64_t rows = large_list->length();
            int64_t rows_to_copy = rows;
            if (max_vectors > 0) {
                rows_to_copy = std::min(rows_to_copy, max_vectors - appended);
            }

            for (int64_t row = 0; row < rows_to_copy; ++row) {
                const int64_t begin = large_list->value_offset(row);
                const int64_t end = large_list->value_offset(row + 1);
                if (end - begin != dim) {
                    std::cerr << "Embedding dimension mismatch in LargeListArray: "
                              << (end - begin) << " != " << dim << std::endl;
                    return false;
                }
                for (int64_t i = begin; i < end; ++i) {
                    out_vectors.push_back(values->Value(i));
                }
            }

            appended += rows_to_copy;
            continue;
        }

        std::cerr << "Unsupported embedding chunk type: "
                  << chunk->type()->ToString() << std::endl;
        return false;
    }

    return true;
}

void
PrintUsage(const char* program_name) {
    std::cout << "Usage: " << program_name << " [options]\n";
    std::cout << "  --dim <int>            embedding dim (default: 768)\n";
    std::cout << "  --nb <int>             vectors to add (default: 1000000)\n";
    std::cout << "  --first-file-idx <int> first arrow file index to start from (default: 0)\n";
    std::cout << "  --nlist <int>          IVF nlist (default: 4096)\n";
    std::cout << "  --nprobe <int>         IVF nprobe (default: 32)\n";
    std::cout << "  --dataset-dir <path>   dataset directory containing .arrow files\n";
    std::cout << "  --index-file <path>    output IVF index file (default: ivf_index.bin)\n";
}

}  // namespace

int
main(int argc, char* argv[]) {
    int dim = 768;
    int64_t nb = 1000000;
    int first_file_idx = 0;
    int nlist = 4096;
    int nprobe = 32;
    std::string dataset_dir =
        "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_100000";
    std::string index_file = "ivf_index.bin";

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            PrintUsage(argv[0]);
            return 0;
        }
        if (arg == "--dim" && i + 1 < argc) {
            dim = std::atoi(argv[++i]);
        } else if (arg == "--nb" && i + 1 < argc) {
            nb = std::atoll(argv[++i]);
        } else if (arg == "--first-file-idx" && i + 1 < argc) {
            first_file_idx = std::atoi(argv[++i]);
        } else if (arg == "--nlist" && i + 1 < argc) {
            nlist = std::atoi(argv[++i]);
        } else if (arg == "--nprobe" && i + 1 < argc) {
            nprobe = std::atoi(argv[++i]);
        } else if (arg == "--dataset-dir" && i + 1 < argc) {
            dataset_dir = argv[++i];
        } else if (arg == "--index-file" && i + 1 < argc) {
            index_file = argv[++i];
        } else {
            std::cerr << "Unknown option: " << arg << std::endl;
            PrintUsage(argv[0]);
            return 1;
        }
    }

    if (dim <= 0 || nb <= 0 || nlist <= 0 || nprobe <= 0 || first_file_idx < 0) {
        std::cerr << "Invalid numeric options" << std::endl;
        return 1;
    }

    auto arrow_files = CollectArrowFiles(dataset_dir);
    if (arrow_files.empty()) {
        std::cerr << "No .arrow files found in dataset directory: " << dataset_dir << std::endl;
        return 1;
    }
    if (first_file_idx >= static_cast<int>(arrow_files.size())) {
        std::cerr << "first-file-idx is out of range: " << first_file_idx
                  << " (arrow files: " << arrow_files.size() << ")" << std::endl;
        return 1;
    }

    std::cout << "Found " << arrow_files.size() << " arrow files" << std::endl;
    std::cout << "Starting from arrow file index: " << first_file_idx << std::endl;

    auto version = knowhere::Version::GetCurrentVersion().VersionNumber();
    auto index_opt = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(
        knowhere::IndexEnum::INDEX_FAISS_IVFFLAT,
        version);
    if (!index_opt.has_value()) {
        std::cerr << "Failed to create IVF_FLAT index" << std::endl;
        return 1;
    }

    auto index = index_opt.value();

    knowhere::Json config;
    config[knowhere::meta::DIM] = dim;
    config[knowhere::meta::METRIC_TYPE] = knowhere::metric::COSINE;
    config[knowhere::indexparam::NLIST] = nlist;
    config[knowhere::indexparam::NPROBE] = nprobe;
    config[knowhere::indexparam::WITH_RAW_DATA] = true;
    config[knowhere::meta::TOPK] = 10;
    config["enable_mmap"] = true;

    const int64_t train_target = std::min<int64_t>(nb, std::max<int64_t>(50000, static_cast<int64_t>(nlist) * 40));

    std::vector<float> train_vectors;
    if (!LoadEmbeddingsFromArrow(arrow_files[first_file_idx], dim, train_target, train_vectors)) {
        return 1;
    }

    int64_t train_count = static_cast<int64_t>(train_vectors.size() / dim);
    if (train_count < nlist) {
        std::cerr << "Not enough vectors for IVF training: train_count=" << train_count
                  << ", nlist=" << nlist << std::endl;
        return 1;
    }

    std::cout << "Training IVF_FLAT with " << train_count << " vectors" << std::endl;
    auto train_dataset = knowhere::GenDataSet(train_count, dim, train_vectors.data());
    auto train_status = index.Train(train_dataset, config);
    if (train_status != knowhere::Status::success) {
        std::cerr << "IVF train failed: status=" << static_cast<int>(train_status) << std::endl;
        return 1;
    }

    int64_t total_added = 0;
    for (size_t file_idx = static_cast<size_t>(first_file_idx + 1); file_idx < arrow_files.size(); ++file_idx) {
        if (total_added >= nb) {
            break;
        }

        const auto& file = arrow_files[file_idx];

        std::vector<float> add_vectors;
        // Keep file-level ingestion behavior aligned with build_vectorDB.cpp:
        // once a file starts loading, ingest the whole file even if it exceeds nb.
        if (!LoadEmbeddingsFromArrow(file, dim, -1, add_vectors)) {
            return 1;
        }
        if (add_vectors.empty()) {
            continue;
        }

        int64_t rows = static_cast<int64_t>(add_vectors.size() / dim);
        auto add_dataset = knowhere::GenDataSet(rows, dim, add_vectors.data());
        auto add_status = index.Add(add_dataset, config);
        if (add_status != knowhere::Status::success) {
            std::cerr << "IVF add failed on file: " << file
                      << ", status=" << static_cast<int>(add_status) << std::endl;
            return 1;
        }

        total_added += rows;
        std::cout << "Added " << rows << " vectors from " << file
                  << " (total=" << total_added << "/" << nb << ")" << std::endl;
    }

    knowhere::BinarySet binary_set;
    auto ser_status = index.Serialize(binary_set);
    if (ser_status != knowhere::Status::success) {
        std::cerr << "Serialize failed: status=" << static_cast<int>(ser_status) << std::endl;
        return 1;
    }

    auto bin = binary_set.GetByName(index.Type());
    if (!bin && !binary_set.binary_map_.empty()) {
        bin = binary_set.binary_map_.begin()->second;
    }
    if (!bin) {
        std::cerr << "Serialize output is empty" << std::endl;
        return 1;
    }

    std::ofstream ofs(index_file, std::ios::binary);
    if (!ofs.is_open()) {
        std::cerr << "Failed to open output file: " << index_file << std::endl;
        return 1;
    }
    ofs.write(reinterpret_cast<const char*>(bin->data.get()), bin->size);
    ofs.close();

    std::cout << "Saved IVF index: " << index_file << std::endl;
    std::cout << "Index type: " << index.Type() << ", vectors: " << total_added << std::endl;

    return 0;
}

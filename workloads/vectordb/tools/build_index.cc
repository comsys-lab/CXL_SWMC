// Offline (Host): HNSW blobs for the initial pool-A segments, identical input for every system (DESIGN.md §6).
// Segment g = pool A rows [g*C, min((g+1)*C, N)), owner node g % nodes; record id = pool A row.
// Output dir: segments.txt ("<g> <owner> <row_start> <rows>"), seg-<g>.index (Knowhere HNSW binary), manifest.txt.
// usage: vdb-build-index <pool_a.fbin> <out dir> <seg_cap> <nodes> [M 16] [efConstruction 128] [rows N|0] [threads 32]
#include <sys/stat.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "knowhere/comp/index_param.h"
#include "knowhere/comp/knowhere_config.h"
#include "knowhere/dataset.h"
#include "knowhere/index/index_factory.h"
#include "knowhere/version.h"

int main(int argc, char **argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s <pool_a.fbin> <out dir> <seg_cap> <nodes> [M] [efc] [rows] [threads]\n", argv[0]);
    return 2;
  }
  const std::string in = argv[1], out = argv[2];
  const uint64_t C = std::strtoull(argv[3], nullptr, 10), nodes = std::strtoull(argv[4], nullptr, 10);
  const int M = argc > 5 ? std::atoi(argv[5]) : 16, efc = argc > 6 ? std::atoi(argv[6]) : 128;
  uint64_t rows = argc > 7 ? std::strtoull(argv[7], nullptr, 10) : 0;
  const int threads = argc > 8 ? std::atoi(argv[8]) : 32;
  if (mkdir(out.c_str(), 0755) != 0) return std::fprintf(stderr, "out dir must not exist: %s\n", out.c_str()), 1;
  FILE *f = std::fopen(in.c_str(), "rb");
  int32_t hdr[2];
  if (!f || std::fread(hdr, 4, 2, f) != 2) return std::fprintf(stderr, "cannot read %s\n", in.c_str()), 1;
  const uint64_t N = uint64_t(hdr[0]), dim = uint64_t(hdr[1]);
  if (rows == 0 || rows > N) rows = N;
  knowhere::KnowhereConfig::SetBuildThreadPoolSize(threads);
  std::ofstream segs(out + "/segments.txt");
  std::vector<float> v;
  const auto t0 = std::chrono::steady_clock::now();
  for (uint64_t g = 0; g * C < rows; g++) {
    const uint64_t start = g * C, n = std::min(C, rows - start);
    v.resize(n * dim);
    if (fseeko(f, off_t(8 + start * dim * 4), SEEK_SET) || std::fread(v.data(), 4, v.size(), f) != v.size())
      return std::fprintf(stderr, "short read\n"), 1;
    auto idx = knowhere::IndexFactory::Instance()
                   .Create<knowhere::fp32>(knowhere::IndexEnum::INDEX_HNSW,
                                           knowhere::Version::GetCurrentVersion().VersionNumber())
                   .value();
    knowhere::Json c;
    c[knowhere::meta::METRIC_TYPE] = knowhere::metric::IP;
    c[knowhere::meta::DIM] = dim;
    c[knowhere::indexparam::HNSW_M] = M;
    c[knowhere::indexparam::EFCONSTRUCTION] = efc;
    if (idx.Build(knowhere::GenDataSet(int64_t(n), int64_t(dim), v.data()), c) != knowhere::Status::success)
      return std::fprintf(stderr, "build failed (segment %lu)\n", (unsigned long)g), 1;
    knowhere::BinarySet bs;
    if (idx.Serialize(bs) != knowhere::Status::success) return std::fprintf(stderr, "serialize failed\n"), 1;
    auto bin = bs.GetByName(idx.Type());
    std::ofstream o(out + "/seg-" + std::to_string(g) + ".index", std::ios::binary);
    o.write(reinterpret_cast<const char *>(bin->data.get()), bin->size);
    segs << g << " " << g % nodes << " " << start << " " << n << "\n";
    std::fprintf(stderr, "segment %lu: rows [%lu, %lu) owner %lu, %ld B (%.0f s)\n", (unsigned long)g,
                 (unsigned long)start, (unsigned long)(start + n), (unsigned long)(g % nodes), (long)bin->size,
                 std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  }
  std::ofstream m(out + "/manifest.txt");
  m << "# vdb initial segments (CXL_SWMC/workloads/vectordb/tools/build_index.cc)\ninput=" << in << "\nrows=" << rows
    << "\ndim=" << dim << "\nseg_cap=" << C << "\nnodes=" << nodes << "\nhnsw_m=" << M << "\nhnsw_efc=" << efc
    << "\nmetric=IP\nknowhere_version=" << knowhere::Version::GetCurrentVersion().VersionNumber() << "\n";
  return 0;
}

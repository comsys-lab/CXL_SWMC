// Offline (Host): initial segments for pool A with the server's own HNSW (server/shm_hnsw.h), identical input for
// every system. Segment s holds pool A rows with row % segments == s (record id = row), inserted in row order by one
// thread per segment with seed (seed + s): deterministic graphs.
// Input is mmap'ed read-only (2026-10-16, 28M set: pool A no longer fits a node's memory twice); each insert reads its
// row from the page cache, so results are identical to the earlier read-into-memory version.
// Output dir: segments.txt ("<s> <count> <ep_level> <upper_cur>"), per group g: seg-<s>-v<g>.bin (vector chunk,
// used bytes) and seg-<s>-l<g>.bin (whole link chunk) = byte images the server copies into the chunk objects,
// manifest.txt (incl. "graph <segments> <dim> <M> <efc> <capacity> <chunk_bytes>").
// usage: vdb-build-index <pool_a.fbin> <out dir> <segments> <max_ids> [M 16] [efc 128] [rows 0=all] [threads 16]
//        [seed 20261015] [chunk_bytes 33554432] [vec_format fp32|sq8]
// sq8 (user decision 2026-10-21): quantizer = per-dimension min / max over ALL indexed pool A rows [0, rows)
// (deterministic, no sampling; pool B values outside the range clamp at run time), written as sq8.bin (float32
// min[dim], scale[dim], scale = (max - min) / 255) + manifest lines "vec_format sq8" and "sq8 ..."; the graph is built
// with SQ8-decoded vectors (shm_hnsw.h insert). fp32 output is byte-identical to earlier builds.
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../server/layout.h"

int main(int argc, char **argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s <pool_a.fbin> <out dir> <segments> <max_ids> [M] [efc] [rows] [threads] [seed] [chunk_bytes]\n",
                 argv[0]);
    return 2;
  }
  const std::string in = argv[1], out = argv[2];
  vdb::Params p;
  p.segments = uint32_t(std::strtoul(argv[3], nullptr, 10));
  p.max_ids = std::strtoull(argv[4], nullptr, 10);
  p.g.M = argc > 5 ? uint32_t(std::atoi(argv[5])) : 16;
  p.g.ef_construction = argc > 6 ? uint32_t(std::atoi(argv[6])) : 128;
  uint64_t rows = argc > 7 ? std::strtoull(argv[7], nullptr, 10) : 0;
  const unsigned threads = argc > 8 ? unsigned(std::atoi(argv[8])) : 16;
  const uint64_t seed = argc > 9 ? std::strtoull(argv[9], nullptr, 10) : 20261015;
  if (argc > 10) p.g.chunk_bytes = std::strtoull(argv[10], nullptr, 10);
  if (argc > 11) {
    const std::string vf = argv[11];
    if (vf != "fp32" && vf != "sq8") return std::fprintf(stderr, "vec_format must be fp32 or sq8\n"), 2;
    p.g.vec_format = vf == "sq8" ? vdb::kVecSQ8 : vdb::kVecF32;
  }
  const int fd = open(in.c_str(), O_RDONLY);
  int32_t hdr[2];
  if (fd < 0 || pread(fd, hdr, 8, 0) != 8) return std::fprintf(stderr, "cannot read %s\n", in.c_str()), 1;
  const uint64_t N = uint64_t(hdr[0]);
  p.g.dim = uint32_t(hdr[1]);
  if (rows == 0 || rows > N) rows = N;
  p.derive();
  if (rows > p.max_ids) return std::fprintf(stderr, "rows > max_ids\n"), 1;
  if (mkdir(out.c_str(), 0755) != 0) return std::fprintf(stderr, "out dir must not exist: %s\n", out.c_str()), 1;
  struct stat st;
  const uint64_t need = 8 + rows * p.g.dim * 4;
  if (fstat(fd, &st) != 0 || uint64_t(st.st_size) < need) return std::fprintf(stderr, "short read\n"), 1;
  void *map = mmap(nullptr, need, PROT_READ, MAP_PRIVATE, fd, 0);
  if (map == MAP_FAILED) return std::perror("mmap"), 1;
  close(fd);
  const float *all = reinterpret_cast<const float *>(static_cast<const uint8_t *>(map) + 8);

  std::vector<float> sq8;  // [min[dim], scale[dim]]
  double sq8_train_s = 0;
  if (p.g.is_sq8()) {  // per-dimension min / max over rows [0, rows), one stripe of rows per thread, then merged
    const auto ts = std::chrono::steady_clock::now();
    const uint32_t d = p.g.dim;
    std::vector<std::vector<float>> mn(threads, std::vector<float>(d, std::numeric_limits<float>::infinity())),
        mx(threads, std::vector<float>(d, -std::numeric_limits<float>::infinity()));
    std::vector<std::thread> tt;
    for (unsigned t = 0; t < threads; t++)
      tt.emplace_back([&, t] {
        const uint64_t a = rows * t / threads, b = rows * (t + 1) / threads;
        for (uint64_t r = a; r < b; r++)
          for (uint32_t i = 0; i < d; i++) {
            const float x = all[r * d + i];
            mn[t][i] = std::min(mn[t][i], x), mx[t][i] = std::max(mx[t][i], x);
          }
      });
    for (auto &t : tt) t.join();
    for (unsigned t = 1; t < threads; t++)
      for (uint32_t i = 0; i < d; i++) mn[0][i] = std::min(mn[0][i], mn[t][i]), mx[0][i] = std::max(mx[0][i], mx[t][i]);
    sq8.resize(2 * size_t(d));
    vdb::sq8_params(mn[0].data(), mx[0].data(), sq8.data(), d);
    p.g.sq8 = sq8.data();
    sq8_train_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - ts).count();
    std::fprintf(stderr, "sq8 quantizer: min/max over %lu rows in %.0f s\n", (unsigned long)rows, sq8_train_s);
  }

  struct Res { uint64_t count, epl, ucur; };
  std::vector<Res> res(p.segments);
  std::atomic<uint32_t> next{0};
  std::mutex mu;
  const auto t0 = std::chrono::steady_clock::now();
  auto work = [&] {
    for (uint32_t s; (s = next++) < p.segments;) {
      const uint64_t n = (rows > s) ? (rows - s + p.segments - 1) / p.segments : 0;
      vdb::GraphMeta meta{};
      const uint64_t N = p.g.per_chunk(), groups = (n + N - 1) / N;
      std::vector<std::vector<uint8_t>> vc(p.g.groups()), lc(p.g.groups());
      vdb::ShmHnsw::Mem mem{&meta, {}, {}};
      for (uint64_t gi = 0; gi < p.g.groups(); gi++) {
        if (gi < groups) vc[gi].assign(p.g.vchunk_bytes(), 0), lc[gi].assign(p.g.lchunk_bytes(), 0);
        mem.vec.push_back(vc[gi].data());
        mem.link.push_back(lc[gi].data());
      }
      vdb::ShmHnsw g(p.g, std::move(mem));
      vdb::ShmHnsw::init_empty(&meta);
      std::mt19937_64 rng(seed + s);
      for (uint64_t r = s; r < rows; r += p.segments) g.insert(r, 0, &all[r * p.g.dim], rng);
      for (uint64_t gi = 0; gi < groups; gi++) {
        const std::string b = out + "/seg-" + std::to_string(s);
        std::ofstream(b + "-v" + std::to_string(gi) + ".bin", std::ios::binary)
            .write(reinterpret_cast<const char *>(vc[gi].data()),
                   std::streamsize(std::min(N, n - gi * N) * p.g.vrec_bytes()));
        std::ofstream(b + "-l" + std::to_string(gi) + ".bin", std::ios::binary)
            .write(reinterpret_cast<const char *>(lc[gi].data()), std::streamsize(p.g.lchunk_bytes()));
      }
      res[s] = {meta.count, meta.ep_level, meta.upper_cur};
      std::lock_guard<std::mutex> g2(mu);
      std::fprintf(stderr, "segment %u: %lu elements, max level %lu (%.0f s)\n", s, (unsigned long)meta.count,
                   (unsigned long)(meta.ep_level >> 32),
                   std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
    }
  };
  std::vector<std::thread> th;
  for (unsigned i = 0; i < threads; i++) th.emplace_back(work);
  for (auto &t : th) t.join();
  std::ofstream segs(out + "/segments.txt");
  for (uint32_t s = 0; s < p.segments; s++)
    segs << s << " " << res[s].count << " " << res[s].epl << " " << res[s].ucur << "\n";
  std::ofstream m(out + "/manifest.txt");
  m << "# vdb initial segments (CXL_SWMC/workloads/vectordb/tools/build_index.cc, server/shm_hnsw.h)\ninput=" << in
    << "\nrows=" << rows << "\nseed=" << seed << "\nparams=" << p.describe() << "\ngraph " << p.segments << " "
    << p.g.dim << " " << p.g.M << " " << p.g.ef_construction << " " << p.g.capacity << " " << p.g.chunk_bytes
    << "\nper_chunk=" << p.g.per_chunk() << " groups=" << p.g.groups() << " vchunk_bytes=" << p.g.vchunk_bytes()
    << " lchunk_bytes=" << p.g.lchunk_bytes() << "\n";
  if (p.g.is_sq8()) {
    std::ofstream(out + "/sq8.bin", std::ios::binary)
        .write(reinterpret_cast<const char *>(sq8.data()), std::streamsize(sq8.size() * sizeof(float)));
    double rmin = 1e30, rmax = 0, rsum = 0;
    for (uint32_t i = 0; i < p.g.dim; i++) {
      const double r = double(sq8[p.g.dim + i]) * 255;
      rmin = std::min(rmin, r), rmax = std::max(rmax, r), rsum += r;
    }
    char fnv[32];
    std::snprintf(fnv, sizeof(fnv), "%016lx", (unsigned long)vdb::sq8_fnv(sq8.data(), p.g.dim));
    m << "vec_format sq8\nsq8 train=pool_a rows [0," << rows << ") min/max per dimension (no sampling) file=sq8.bin fnv="
      << fnv << " vrec_bytes=" << p.g.vrec_bytes() << " range_min=" << rmin << " range_mean=" << rsum / p.g.dim
      << " range_max=" << rmax << " train_s=" << sq8_train_s << "\n";
  }
  rusage ru{};
  getrusage(RUSAGE_SELF, &ru);
  std::fprintf(stderr, "build done: %.0f s, maxrss %ld KiB (includes mapped input pages)\n",
               std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(), ru.ru_maxrss);
  return 0;
}

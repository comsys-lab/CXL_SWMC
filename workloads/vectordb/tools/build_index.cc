// Offline (Host): initial segments for pool A with the server's own HNSW (server/shm_hnsw.h), identical input for
// every system. Segment s holds pool A rows with row % segments == s (record id = row), inserted in row order by one
// thread per segment with seed (seed + s): deterministic graphs.
// Output dir: segments.txt ("<s> <count> <ep_level> <upper_cur>"), per group g: seg-<s>-v<g>.bin (vector chunk,
// used bytes) and seg-<s>-l<g>.bin (whole link chunk) = byte images the server copies into the chunk objects,
// manifest.txt (incl. "graph <segments> <dim> <M> <efc> <capacity> <chunk_bytes>").
// usage: vdb-build-index <pool_a.fbin> <out dir> <segments> <max_ids> [M 16] [efc 128] [rows 0=all] [threads 16]
//        [seed 20261015] [chunk_bytes 33554432]
#include <sys/stat.h>

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
  FILE *f = std::fopen(in.c_str(), "rb");
  int32_t hdr[2];
  if (!f || std::fread(hdr, 4, 2, f) != 2) return std::fprintf(stderr, "cannot read %s\n", in.c_str()), 1;
  const uint64_t N = uint64_t(hdr[0]);
  p.g.dim = uint32_t(hdr[1]);
  if (rows == 0 || rows > N) rows = N;
  p.derive();
  if (rows > p.max_ids) return std::fprintf(stderr, "rows > max_ids\n"), 1;
  if (mkdir(out.c_str(), 0755) != 0) return std::fprintf(stderr, "out dir must not exist: %s\n", out.c_str()), 1;
  std::vector<float> all(rows * p.g.dim);
  if (std::fread(all.data(), 4, all.size(), f) != all.size()) return std::fprintf(stderr, "short read\n"), 1;
  std::fclose(f);

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
  return 0;
}

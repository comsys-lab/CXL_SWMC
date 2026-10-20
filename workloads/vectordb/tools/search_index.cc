// Host check (no shared memory, no server): load an init dir (tools/build_index.cc output, fp32 or sq8) into private
// memory and run static searches over all segments with the server's own HNSW search (server/shm_hnsw.h, PlainAcc
// semantics), as the server does per query: every segment searched with (k, ef), results merged by distance, top k.
// Reports per ef: recall@k against an exact ground truth file (tools/static_gt.py: exact top-k inner product over the
// indexed pool A rows; record id = row), distance computations per query, level-0 link blocks read per query, and the
// shared-memory bytes a query reads = dists x vrec_bytes (header + vector record) + level-0 link blocks x links0_bytes
// + upper-level link blocks x links_bytes (each counted once per access, i.e. no cache reuse).
// usage: vdb-search-index <init dir> <queries.fbin> <gt.bin> <nq> <ef list, e.g. 64,96,128> [threads 16] [k 10]
//        [nseg: load and search only segments 0..nseg-1 (records with id % segments < nseg); the GT must be built for
//        the same subset (static_gt.py --subset-mod segments --subset-lt nseg); default all]
#include <algorithm>
#include <array>
#include <atomic>
#include <memory>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "../server/layout.h"

namespace {

thread_local uint64_t t_l0 = 0, t_up = 0;  // link blocks read by this thread

// PlainAcc + counters (search path only); HnswT calls the derived accessor's methods directly
class CountAcc : public vdb::PlainAcc {
 public:
  using vdb::PlainAcc::PlainAcc;
  const uint32_t *links(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const {
    (level ? t_up : t_l0)++;
    return vdb::PlainAcc::links(i, level, uo, tmp);
  }
};

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "vdb-search-index: %s\n", m.c_str());
  std::exit(1);
}

void read_file(const std::string &path, uint8_t *dst, uint64_t n) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f || uint64_t(f.tellg()) != n) die(path + ": missing or size != " + std::to_string(n));
  f.seekg(0);
  f.read(reinterpret_cast<char *>(dst), std::streamsize(n));
  if (!f) die("short read " + path);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 6) die("usage: vdb-search-index <init dir> <queries.fbin> <gt.bin> <nq> <ef list> [threads 16] [k 10]");
  const std::string dir = argv[1];
  uint64_t nq = std::strtoull(argv[4], nullptr, 10);
  std::vector<uint32_t> efs;
  {
    std::stringstream ss(argv[5]);
    for (std::string x; std::getline(ss, x, ',');) efs.push_back(uint32_t(std::stoul(x)));
  }
  const unsigned threads = argc > 6 ? unsigned(std::atoi(argv[6])) : 16;
  const uint32_t k = argc > 7 ? uint32_t(std::atoi(argv[7])) : 10;
  uint32_t nseg = argc > 8 ? uint32_t(std::atoi(argv[8])) : 0;

  vdb::GraphParams g;
  uint32_t segments = 0;
  {
    std::ifstream man(dir + "/manifest.txt");
    bool ok = false;
    for (std::string line; std::getline(man, line);) {
      if (line.rfind("graph ", 0) == 0) {
        std::istringstream is(line.substr(6));
        is >> segments >> g.dim >> g.M >> g.ef_construction >> g.capacity >> g.chunk_bytes;
        ok = bool(is);
      }
      if (line == "vec_format sq8") g.vec_format = vdb::kVecSQ8;
    }
    if (!ok) die("no graph line in " + dir + "/manifest.txt");
  }
  if (nseg == 0 || nseg > segments) nseg = segments;
  std::vector<float> sq8;
  if (g.is_sq8()) {
    sq8.resize(2 * size_t(g.dim));
    read_file(dir + "/sq8.bin", reinterpret_cast<uint8_t *>(sq8.data()), sq8.size() * 4);
    g.sq8 = sq8.data();
  }
  // queries
  std::vector<float> Q;
  {
    std::ifstream f(argv[2], std::ios::binary);
    int32_t h[2];
    if (!f.read(reinterpret_cast<char *>(h), 8) || uint32_t(h[1]) != g.dim) die("queries: bad header / dim");
    nq = std::min<uint64_t>(nq, uint64_t(h[0]));
    Q.resize(nq * g.dim);
    if (!f.read(reinterpret_cast<char *>(Q.data()), std::streamsize(Q.size() * 4))) die("queries: short read");
  }
  // ground truth: int32 nq, int32 k, uint64 ids[nq][k]
  std::vector<uint64_t> gt;
  uint32_t gk = 0;
  {
    std::ifstream f(argv[3], std::ios::binary);
    int32_t h[2];
    if (!f.read(reinterpret_cast<char *>(h), 8) || uint64_t(h[0]) < nq || uint32_t(h[1]) < k) die("gt: bad header");
    gk = uint32_t(h[1]);
    gt.resize(nq * gk);
    if (!f.read(reinterpret_cast<char *>(gt.data()), std::streamsize(gt.size() * 8))) die("gt: short read");
  }
  // segments
  const auto t0 = std::chrono::steady_clock::now();
  std::vector<vdb::GraphMeta> metas(segments);
  std::vector<std::unique_ptr<vdb::HnswT<CountAcc>>> graphs;
  std::vector<std::unique_ptr<uint8_t[]>> keep;
  uint64_t total = 0, bytes = 0;
  {
    std::ifstream f(dir + "/segments.txt");
    uint64_t s, count, epl, ucur;
    const uint64_t N = g.per_chunk();
    std::vector<std::pair<uint64_t, std::array<uint64_t, 3>>> rows;
    while (f >> s >> count >> epl >> ucur) rows.push_back({s, {count, epl, ucur}});
    if (rows.size() != segments) die("segments.txt rows != segments");
    graphs.resize(segments);
    for (auto &r : rows) {
      s = r.first;
      count = r.second[0];
      if (s >= segments) die("bad segments.txt");
      if (s >= nseg) continue;
      vdb::GraphMeta &m = metas[s];
      m.count = count, m.ep_level = r.second[1], m.upper_cur = r.second[2];
      CountAcc::Mem mem{&m, {}, {}};
      for (uint64_t gi = 0; gi < g.groups(); gi++) {
        if (gi * N >= count) {
          mem.vec.push_back(nullptr), mem.link.push_back(nullptr);
          continue;
        }
        const uint64_t vb = std::min(N, count - gi * N) * g.vrec_bytes(), lb = g.lchunk_bytes();
        keep.emplace_back(new uint8_t[vb]);
        read_file(dir + "/seg-" + std::to_string(s) + "-v" + std::to_string(gi) + ".bin", keep.back().get(), vb);
        mem.vec.push_back(keep.back().get());
        keep.emplace_back(new uint8_t[lb]);
        read_file(dir + "/seg-" + std::to_string(s) + "-l" + std::to_string(gi) + ".bin", keep.back().get(), lb);
        mem.link.push_back(keep.back().get());
        bytes += vb + lb;
      }
      graphs[s] = std::make_unique<vdb::HnswT<CountAcc>>(g, std::move(mem));
      total += count;
    }
  }
  std::printf("index %s: %s, segments 0..%u of %u, %lu records, vrec_bytes %lu, links0_bytes %lu, loaded %.1f GiB in %.0f s\n",
              dir.c_str(), g.is_sq8() ? "sq8" : "fp32", nseg - 1, segments, (unsigned long)total, (unsigned long)g.vrec_bytes(),
              (unsigned long)g.links0_bytes(), bytes / double(1ull << 30),
              std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
  std::printf("ef\tk\tqueries\trecall_at_k\tdists_per_q\tl0_links_per_q\tupper_links_per_q\tbytes_per_q\tbytes_per_visited\tus_per_q_thread\n");
  for (uint32_t ef : efs) {
    std::atomic<uint64_t> next{0}, hits{0}, dists{0}, l0{0}, up{0}, ns{0};
    auto work = [&] {
      std::vector<uint16_t> visited(g.capacity, 0);
      uint16_t tag = 0;
      std::vector<std::pair<float, uint32_t>> part;
      std::vector<std::pair<float, uint64_t>> all;
      uint64_t my_h = 0, my_d = 0, my_ns = 0;
      t_l0 = t_up = 0;
      for (uint64_t q; (q = next++) < nq;) {
        const auto a = std::chrono::steady_clock::now();
        all.clear();
        for (uint32_t s = 0; s < nseg; s++) {
          graphs[s]->search(&Q[q * g.dim], k, ef, [](uint32_t) { return true; }, &part, visited, tag, &my_d);
          vdb::ElemHeader tmp;
          for (auto &pr : part) all.emplace_back(pr.first, graphs[s]->header(pr.second, tmp).ext_id);
        }
        std::sort(all.begin(), all.end());
        if (all.size() > k) all.resize(k);
        my_ns += uint64_t(std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - a).count());
        for (auto &x : all)
          for (uint32_t j = 0; j < k; j++)
            if (gt[q * gk + j] == x.second) { my_h++; break; }
      }
      hits += my_h, dists += my_d, l0 += t_l0, up += t_up, ns += my_ns;
    };
    std::vector<std::thread> th;
    for (unsigned i = 0; i < threads; i++) th.emplace_back(work);
    for (auto &t : th) t.join();
    const double dq = double(dists) / nq, lq = double(l0) / nq, uq = double(up) / nq;
    const double bq = dq * g.vrec_bytes() + lq * g.links0_bytes() + uq * g.links_bytes();
    std::printf("%u\t%u\t%lu\t%.4f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n", ef, k, (unsigned long)nq,
                double(hits) / (double(nq) * k), dq, lq, uq, bq, bq / dq, double(ns) / nq / 1000);
    std::fflush(stdout);
  }
  return 0;
}

// loadgen plugin "vectordb" (workloads/vectordb/DESIGN.md, experiments/loadgen/README.md).
// Streams: "write" (ordered; the writes file in w_seq order, each to its target VM) and "search" (query row and
// target drawn with the seed; E1 snapshot ref_w = last write made before it, i.e. scheduled before it).
// Options: data=DIR (pool_b.fbin, queries.fbin), writes=FILE (tools/gen_writes.py), k=10, seed=N,
//          max_searches=N (default 100M; result slots are allocated in chunks as used).
// Output: <out>/searches.bin, one record per search response (header struct below + ids[k] u64 + scores[k] f32),
//         for offline recall (tools/compute_gt.py), and <out>/vectordb.txt (counts).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

#include "frame.h"
#include "../proto.h"
#include "workload.h"

namespace {

struct __attribute__((packed)) WriteRec {
  uint8_t op, target;
  uint16_t pad0;
  uint32_t w_seq;
  uint64_t id;
  uint32_t vec_ref, pad1;
};
static_assert(sizeof(WriteRec) == 24, "gen_writes.py record");

struct __attribute__((packed)) SearchLog {  // one per search response, followed by ids[k] (u64) and scores[k] (f32)
  uint64_t seq;
  uint32_t qrow, ref_w, s_used;
  uint8_t measured, pad;
  uint16_t status, n, k;
  uint32_t wait_us, replay_us, search_us, mask_us, raw_scanned;
  uint16_t indexed_segs, sealed_backlog;
};

struct Fbin {
  const float *rows = nullptr;
  uint64_t n = 0, dim = 0;
  bool open(const std::string &path, std::string *err) {
    int fd = ::open(path.c_str(), O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) return *err = "cannot open " + path, false;
    void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED) return *err = "cannot map " + path, false;
    const int32_t *h = static_cast<const int32_t *>(m);
    n = uint64_t(h[0]), dim = uint64_t(h[1]);
    if (uint64_t(st.st_size) != 8 + n * dim * 4) return *err = path + ": size does not match header", false;
    rows = reinterpret_cast<const float *>(static_cast<const uint8_t *>(m) + 8);
    return true;
  }
};

class VectorDb : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    targets_ = targets;
    const std::string data = get("data", ""), writes = get("writes", "");
    if (data.empty() || writes.empty()) return *err = "need --opt data=DIR --opt writes=FILE", false;
    k_ = uint16_t(std::stoul(get("k", "10")));
    seed_ = std::stoull(get("seed", "20261015"));
    max_searches_ = std::stoull(get("max_searches", "100000000"));
    rng_.seed(seed_);
    if (!pool_b_.open(data + "/pool_b.fbin", err) || !queries_.open(data + "/queries.fbin", err)) return false;
    if (pool_b_.dim != queries_.dim) return *err = "pool B / queries dim differ", false;
    dim_ = uint32_t(pool_b_.dim);
    FILE *f = std::fopen(writes.c_str(), "rb");
    if (!f) return *err = "cannot open " + writes, false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz % long(sizeof(WriteRec))) return std::fclose(f), *err = writes + ": bad size", false;
    writes_.resize(size_t(sz) / sizeof(WriteRec));
    bool ok = std::fread(writes_.data(), sizeof(WriteRec), writes_.size(), f) == writes_.size();
    std::fclose(f);
    if (!ok) return *err = "short read " + writes, false;
    for (size_t i = 0; i < writes_.size(); i++) {
      const WriteRec &w = writes_[i];
      if (w.w_seq != i + 1 || w.target >= targets || (w.op == vdb::kOpInsert && w.vec_ref >= pool_b_.n) ||
          (w.op != vdb::kOpInsert && w.op != vdb::kOpDelete))
        return *err = "writes file record " + std::to_string(i) + " invalid for " + std::to_string(targets) +
                      " targets", false;
    }
    chunks_.reset(new std::atomic<Slot *>[kMaxChunks]);
    for (uint64_t i = 0; i < kMaxChunks; i++) chunks_[i].store(nullptr);
    writes_path_ = writes, data_ = data;
    return true;
  }

  std::vector<loadgen::StreamSpec> streams() const override { return {{"write", true}, {"search", false}}; }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    if (stream == 0) {
      if (next_w_ >= writes_.size()) return false;
      const WriteRec &w = writes_[next_w_];
      r->target = w.target;
      r->op = w.op;
      r->seq = next_w_++;
      if (w.op == vdb::kOpInsert) {
        vdb::InsertReq q{w.w_seq, 0, w.id};
        p->resize(sizeof(q) + dim_ * 4);
        std::memcpy(p->data(), &q, sizeof(q));
        std::memcpy(p->data() + sizeof(q), pool_b_.rows + uint64_t(w.vec_ref) * dim_, dim_ * 4);
      } else {
        vdb::DeleteReq q{w.w_seq, 0, w.id};
        p->resize(sizeof(q));
        std::memcpy(p->data(), &q, sizeof(q));
      }
      last_w_ = w.w_seq;
      return true;
    }
    if (next_s_ >= max_searches_) return false;
    const uint32_t qrow = uint32_t(std::uniform_int_distribution<uint64_t>(0, queries_.n - 1)(rng_));
    r->target = uint32_t(std::uniform_int_distribution<uint32_t>(0, targets_ - 1)(rng_));
    r->op = vdb::kOpSearch;
    r->seq = next_s_;
    Slot *s = slot(next_s_++, true);
    s->qrow = qrow;
    s->ref_w = last_w_;
    vdb::SearchReq q{last_w_, k_, 0};
    p->resize(sizeof(q) + dim_ * 4);
    std::memcpy(p->data(), &q, sizeof(q));
    std::memcpy(p->data() + sizeof(q), queries_.rows + uint64_t(qrow) * dim_, dim_ * 4);
    return true;
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t status, const uint8_t *p,
                   uint32_t len) override {
    if (r.op != vdb::kOpSearch) {
      if (status != frame::kStatusOk) write_errors_.fetch_add(1);
      return;
    }
    Slot *s = slot(r.seq, false);
    std::vector<uint8_t> rec(sizeof(SearchLog) + size_t(k_) * 12, 0);
    SearchLog lg{};
    lg.seq = r.seq;
    lg.qrow = s->qrow;
    lg.ref_w = s->ref_w;
    lg.measured = measured;
    lg.status = status;
    lg.k = k_;
    if (status == frame::kStatusOk && len >= sizeof(vdb::SearchResp)) {
      vdb::SearchResp sr;
      std::memcpy(&sr, p, sizeof(sr));
      const uint16_t n = std::min<uint16_t>(sr.n, k_);
      if (len >= sizeof(sr) + size_t(sr.n) * 12) {
        lg.n = n;
        std::memcpy(rec.data() + sizeof(lg), p + sizeof(sr), size_t(n) * 8);
        std::memcpy(rec.data() + sizeof(lg) + size_t(k_) * 8, p + sizeof(sr) + size_t(sr.n) * 8, size_t(n) * 4);
      } else {
        bad_responses_.fetch_add(1);
      }
      lg.s_used = sr.s_used, lg.wait_us = sr.wait_us, lg.replay_us = sr.replay_us, lg.search_us = sr.search_us;
      lg.mask_us = sr.mask_us, lg.raw_scanned = sr.raw_scanned, lg.indexed_segs = sr.indexed_segs;
      lg.sealed_backlog = sr.sealed_backlog;
    }
    std::memcpy(rec.data(), &lg, sizeof(lg));
    std::lock_guard<std::mutex> g(out_mu_);
    out_.insert(out_.end(), rec.begin(), rec.end());
  }

  bool finish(const std::string &dir, std::string *err) override {
    FILE *f = std::fopen((dir + "/searches.bin").c_str(), "wb");
    if (!f) return *err = "cannot write searches.bin", false;
    {
      std::lock_guard<std::mutex> g(out_mu_);
      std::fwrite(out_.data(), 1, out_.size(), f);
    }
    std::fclose(f);
    FILE *t = std::fopen((dir + "/vectordb.txt").c_str(), "w");
    std::fprintf(t, "writes_made=%lu\nlast_w=%u\nsearches_made=%lu\nwrite_errors=%lu\nbad_search_responses=%lu\n"
                 "search_record_bytes=%zu\nk=%u\n",
                 (unsigned long)next_w_, last_w_, (unsigned long)next_s_, (unsigned long)write_errors_.load(),
                 (unsigned long)bad_responses_.load(), sizeof(SearchLog) + size_t(k_) * 12, k_);
    std::fclose(t);
    if (write_errors_.load()) *err = "write errors " + std::to_string(write_errors_.load());
    return write_errors_.load() == 0;
  }

  std::string describe() const override {
    return "vectordb data=" + data_ + " writes=" + writes_path_ + " (" + std::to_string(writes_.size()) +
           ") k=" + std::to_string(k_) + " seed=" + std::to_string(seed_) + " dim=" + std::to_string(dim_);
  }

 private:
  struct Slot {
    uint32_t qrow, ref_w;
  };
  static constexpr uint64_t kChunk = 1u << 16, kMaxChunks = 1u << 13;
  Slot *slot(uint64_t i, bool create) {
    const uint64_t c = i / kChunk;
    if (c >= kMaxChunks) throw std::runtime_error("max_searches beyond slot table");
    Slot *p = chunks_[c].load(std::memory_order_acquire);
    if (!p && create) {
      p = new Slot[kChunk];
      chunks_[c].store(p, std::memory_order_release);
    }
    return &p[i % kChunk];
  }

  uint32_t targets_ = 1, dim_ = 0, last_w_ = 0;
  uint16_t k_ = 10;
  uint64_t seed_ = 0, max_searches_ = 0, next_w_ = 0, next_s_ = 0;
  std::mt19937_64 rng_;
  Fbin pool_b_, queries_;
  std::vector<WriteRec> writes_;
  std::string writes_path_, data_;
  std::unique_ptr<std::atomic<Slot *>[]> chunks_;
  std::mutex out_mu_;
  std::vector<uint8_t> out_;
  std::atomic<uint64_t> write_errors_{0}, bad_responses_{0};
};
LOADGEN_REGISTER("vectordb", VectorDb);

}  // namespace

// Staleness sampling logs (experiment socialgraph-serving §2 "Observed staleness"; joined offline by
// tools/sg_stale_join.py). Per VM two files under the run's result dir (--stale-dir):
//   stale-reads-n<node>.bin    one entry per sampled record read: 1 in `every` records read (node slots and adjacency
//                              lists, every read operation; Bernoulli per record with a per-thread xorshift)
//   stale-commits-n<node>.bin  one entry per committed record write of this VM's writer (every write)
// File = 32 B header {char magic[8] "SGSTLR01" / "SGSTLC01", u32 node, u32 entry_bytes (24), u64 every, u64 t_open_ns}
// then entries {u64 rid (backend.h rid()), u64 version, u64 t_ns}. t_ns = CLOCK_REALTIME of this VM: reads take it
// right after the record's seqlock read completed (local read time), commits right after the release store of the
// new version (the version is visible from then on). Host clock offsets are logged separately (Host side,
// clock-offset logger as in the RecSys T-sweep) and applied by the join.
// Threads append to their own buffer (no shared lock on the hot path except a per-buffer mutex taken by the flusher);
// a flusher thread writes the buffers every flush_ms and at stop. Off (no files, no sampling cost beyond one branch)
// when the dir is empty.
#pragma once

#include <time.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace sg {

inline uint64_t realtime_ns() {
  timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

struct StaleEntry {
  uint64_t rid, version, t_ns;
};
static_assert(sizeof(StaleEntry) == 24, "stale entry 24 B");

struct StaleFileHeader {
  char magic[8];
  uint32_t node, entry_bytes;
  uint64_t every, t_open_ns;
};
static_assert(sizeof(StaleFileHeader) == 32, "stale header 32 B");

class StaleLog {
 public:
  struct Buf {
    std::mutex mu;
    std::vector<StaleEntry> v;
    uint64_t rng = 0;
  };
  bool open(const std::string &dir, uint32_t node, uint64_t every, std::string *err) {
    every_ = every ? every : 1;
    thresh_ = every_ <= 1 ? ~0ull : ~0ull / every_;
    for (int i = 0; i < 2; i++) {
      const std::string p = dir + (i ? "/stale-commits-n" : "/stale-reads-n") + std::to_string(node) + ".bin";
      f_[i] = std::fopen(p.c_str(), "wb");
      if (!f_[i]) { *err = "cannot create " + p; return false; }
      StaleFileHeader h{};
      std::memcpy(h.magic, i ? "SGSTLC01" : "SGSTLR01", 8);
      h.node = node, h.entry_bytes = sizeof(StaleEntry), h.every = i ? 1 : every_, h.t_open_ns = realtime_ns();
      if (std::fwrite(&h, sizeof h, 1, f_[i]) != 1) { *err = "write " + p; return false; }
    }
    on_ = true;
    return true;
  }
  bool on() const { return on_; }
  // thread buffers: reader / writer threads register once (tid distinct per thread)
  Buf *reg(bool commit, uint64_t seed) {
    std::lock_guard<std::mutex> g(mu_);
    bufs_[commit].push_back(std::make_unique<Buf>());
    Buf *b = bufs_[commit].back().get();
    b->rng = seed * 0x9e3779b97f4a7c15ull + 0x2545f4914f6cdd1dull;
    if (!b->rng) b->rng = 1;
    return b;
  }
  // sampled read: call once per record read (cheap when not sampled)
  void read(Buf *b, uint64_t r, uint64_t version) {
    if (!on_ || !b) return;
    uint64_t x = b->rng;  // xorshift64
    x ^= x << 13, x ^= x >> 7, x ^= x << 17;
    b->rng = x;
    if (x > thresh_) return;
    const uint64_t t = realtime_ns();
    std::lock_guard<std::mutex> g(b->mu);
    b->v.push_back({r, version, t});
    sampled_++;
  }
  void commit(Buf *b, uint64_t r, uint64_t version, uint64_t t) {
    if (!on_ || !b) return;
    std::lock_guard<std::mutex> g(b->mu);
    b->v.push_back({r, version, t});
    commits_++;
  }
  void flush() {
    if (!on_) return;
    std::lock_guard<std::mutex> g(fmu_);
    std::vector<StaleEntry> tmp;
    for (int i = 0; i < 2; i++) {
      std::vector<Buf *> bs;
      {
        std::lock_guard<std::mutex> l(mu_);
        for (auto &b : bufs_[i]) bs.push_back(b.get());
      }
      for (Buf *b : bs) {
        tmp.clear();
        {
          std::lock_guard<std::mutex> l(b->mu);
          tmp.swap(b->v);
        }
        if (!tmp.empty() && std::fwrite(tmp.data(), sizeof(StaleEntry), tmp.size(), f_[i]) != tmp.size()) errors_++;
      }
      std::fflush(f_[i]);
    }
  }
  void start_flusher(uint64_t flush_ms) {
    if (!on_) return;
    std::thread([this, flush_ms] {
      for (;;) {
        std::this_thread::sleep_for(std::chrono::milliseconds(flush_ms));
        flush();
      }
    }).detach();
  }
  void close() {
    if (!on_) return;
    flush();
    std::lock_guard<std::mutex> g(fmu_);
    for (auto &f : f_) std::fclose(f), f = nullptr;
    on_ = false;
  }
  uint64_t every() const { return every_; }
  uint64_t sampled() const { return sampled_; }
  uint64_t commits() const { return commits_; }
  uint64_t errors() const { return errors_; }

 private:
  std::atomic<bool> on_{false};
  uint64_t every_ = 1000, thresh_ = 0;
  FILE *f_[2] = {nullptr, nullptr};
  std::mutex mu_, fmu_;
  std::vector<std::unique_ptr<Buf>> bufs_[2];
  std::atomic<uint64_t> sampled_{0}, commits_{0}, errors_{0};
};

}  // namespace sg

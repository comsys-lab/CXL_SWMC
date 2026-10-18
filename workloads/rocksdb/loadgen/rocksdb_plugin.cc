// loadgen plugin "rocksdb" (workloads/rocksdb/DESIGN.md §8, experiments/loadgen/README.md). Same request model as
// the lmdb plugin: streams "get", "update" and "mixed" (each request an update with probability update_ratio, else a
// get; --mix mixed=1 --slo mixed:99:1). Key: YCSB ScrambledZipfian(0.99) over keys; target node uniform; update value
// = 1,000 B (key, version = loadgen update sequence, writer = target node), overwriting.
// Checks (always on): every returned value is complete and belongs to its key; per-key freshness: a get's returned
// stamp >= the highest stamp of an update of that key acknowledged before the get was made (cross-node read-after-ack);
// not-found and errors are counted. With log=1 every response is logged (LogRec) for an offline check.
// Options: keys=N (required, = server --keys), seed=N, log=0|1, max_requests=N (log slots, default 200M),
//          update_ratio=R (mixed stream, 0..1, default 0.05).
// Output: <out>/rocksdb.txt (counts); with log=1 <out>/gets.bin and <out>/updates.bin.
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

#include "../proto.h"
#include "frame.h"
#include "workload.h"

namespace {

using namespace rdbw;

struct __attribute__((packed)) LogRec {  // gets.bin / updates.bin
  uint64_t seq, key, stamp, version;     // get: stamp and version read; update: stamp assigned, version written
  uint32_t writer;
  uint16_t status;
  uint8_t measured, target;
  uint64_t min_stamp;                    // get: highest acked stamp of the key when the get was made
};
static_assert(sizeof(LogRec) == 48, "log record");

class RocksPlugin : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    targets_ = targets;
    keys_ = std::stoull(get("keys", "0"));
    if (!keys_) return *err = "need --opt keys=N (the server's --keys)", false;
    seed_ = std::stoull(get("seed", "20261018"));
    log_ = get("log", "0") == "1";
    for (auto &kv : o)
      if (kv.first != "keys" && kv.first != "seed" && kv.first != "log" && kv.first != "max_requests" &&
          kv.first != "update_ratio")
        return *err = "rocksdb: unknown option " + kv.first, false;
    update_ratio_ = std::stod(get("update_ratio", "0.05"));
    if (!(update_ratio_ >= 0.0 && update_ratio_ <= 1.0)) return *err = "rocksdb: update_ratio 0..1", false;
    kind_rng_.seed(seed_ ^ 0x6a09e667f3bcc909ull);
    max_requests_ = std::stoull(get("max_requests", "200000000"));
    rng_.seed(seed_);
    zipf_ = std::make_unique<ScrambledZipfian>(keys_);
    chunks_.reset(new std::atomic<Slot *>[kMaxChunks]);
    for (uint64_t i = 0; i < kMaxChunks; i++) chunks_[i].store(nullptr);
    kchunks_.reset(new std::atomic<std::atomic<uint64_t> *>[(keys_ + kKeyChunk - 1) / kKeyChunk]);
    for (uint64_t i = 0; i < (keys_ + kKeyChunk - 1) / kKeyChunk; i++) kchunks_[i].store(nullptr);
    return true;
  }

  // 0 "get", 1 "update", 2 "mixed" (update with probability update_ratio)
  std::vector<loadgen::StreamSpec> streams() const override { return {{"get", false}, {"update", false}, {"mixed", false}}; }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    if (next_ >= max_requests_) return false;
    const uint64_t key = zipf_->next(rng_);
    r->target = uint32_t(std::uniform_int_distribution<uint32_t>(0, targets_ - 1)(rng_));
    r->seq = next_++;
    Slot *s = slot(r->seq, true);
    s->key = key;
    char k[kKeyBytes];
    make_key(key, k);
    const bool update = stream == 1 || (stream == 2 && kind_uni_(kind_rng_) < update_ratio_);
    if (!update) {
      r->op = kOpGet;
      s->min_stamp = acked(key)->load(std::memory_order_acquire);
      s->version = 0;
      GetReq q{uint16_t(kKeyBytes), 0, 0};
      p->resize(sizeof(q) + kKeyBytes);
      std::memcpy(p->data(), &q, sizeof(q));
      std::memcpy(p->data() + sizeof(q), k, kKeyBytes);
    } else {
      r->op = kOpUpdate;
      s->version = ++version_;
      s->min_stamp = 0;
      UpdateReq q{uint16_t(kKeyBytes), 0, kValueBytes};
      p->resize(sizeof(q) + kKeyBytes + kValueBytes);
      std::memcpy(p->data(), &q, sizeof(q));
      std::memcpy(p->data() + sizeof(q), k, kKeyBytes);
      fill_value(key, s->version, r->target, p->data() + sizeof(q) + kKeyBytes);
    }
    return true;
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t status, const uint8_t *p, uint32_t len) override {
    const Slot *s = slot(r.seq, false);
    LogRec lg{r.seq, s->key, 0, s->version, 0, status, uint8_t(measured), uint8_t(r.target), s->min_stamp};
    if (r.op == kOpGet) {
      if (status == frame::kStatusOk && len >= sizeof(GetResp)) {
        GetResp g;
        std::memcpy(&g, p, sizeof(g));
        ValHdr h{};
        lg.stamp = g.stamp;
        if (len != sizeof(g) + g.vlen || !lmdbw::check_value(s->key, p + sizeof(g), g.vlen, &h)) bad_values_++;
        else lg.version = h.version, lg.writer = h.writer;
        if (g.stamp < s->min_stamp) stale_++;
        gets_ok_++;
      } else if (status == kStatusNotFound) {
        not_found_++;
      } else {
        errors_++;
      }
    } else {
      if (status == frame::kStatusOk && len >= sizeof(UpdateResp)) {
        UpdateResp u;
        std::memcpy(&u, p, sizeof(u));
        lg.stamp = u.stamp;
        lg.writer = r.target;
        std::atomic<uint64_t> *a = acked(s->key);
        uint64_t cur = a->load(std::memory_order_relaxed);
        while (u.stamp > cur && !a->compare_exchange_weak(cur, u.stamp, std::memory_order_acq_rel)) {
        }
        updates_ok_++;
      } else {
        errors_++;
      }
    }
    if (log_) {
      std::lock_guard<std::mutex> g(mu_);
      (r.op == kOpGet ? glog_ : ulog_).push_back(lg);
    }
  }

  bool finish(const std::string &dir, std::string *err) override {
    if (log_) {
      for (auto [name, v] : {std::make_pair("gets.bin", &glog_), std::make_pair("updates.bin", &ulog_)}) {
        FILE *f = std::fopen((dir + "/" + name).c_str(), "wb");
        if (!f) return *err = std::string("cannot write ") + name, false;
        std::fwrite(v->data(), sizeof(LogRec), v->size(), f);
        std::fclose(f);
      }
    }
    FILE *t = std::fopen((dir + "/rocksdb.txt").c_str(), "w");
    if (!t) return *err = "cannot write rocksdb.txt", false;
    std::fprintf(t, "requests_made=%lu\nupdates_made=%lu\ngets_ok=%lu\nupdates_ok=%lu\nnot_found=%lu\nerrors=%lu\n"
                 "bad_values=%lu\nstale_reads=%lu\nkeys=%lu\nseed=%lu\nlog=%d\n",
                 (unsigned long)next_, (unsigned long)version_, (unsigned long)gets_ok_.load(),
                 (unsigned long)updates_ok_.load(), (unsigned long)not_found_.load(), (unsigned long)errors_.load(),
                 (unsigned long)bad_values_.load(), (unsigned long)stale_.load(), (unsigned long)keys_,
                 (unsigned long)seed_, int(log_));
    std::fclose(t);
    const uint64_t bad = not_found_ + errors_ + bad_values_ + stale_;
    if (bad)
      *err = "rocksdb checks failed: not_found " + std::to_string(not_found_.load()) + " errors " +
             std::to_string(errors_.load()) + " bad_values " + std::to_string(bad_values_.load()) + " stale " +
             std::to_string(stale_.load());
    return bad == 0;
  }

  std::string describe() const override {
    return "rocksdb keys=" + std::to_string(keys_) + " key=" + std::to_string(kKeyBytes) + "B value=" +
           std::to_string(kValueBytes) + "B dist=scrambled_zipfian(0.99) seed=" + std::to_string(seed_) +
           " log=" + std::to_string(int(log_)) + " update_ratio=" + std::to_string(update_ratio_);
  }

 private:
  struct Slot {
    uint64_t key, version, min_stamp;
  };
  static constexpr uint64_t kChunk = 1u << 16, kMaxChunks = 1u << 14, kKeyChunk = 1u << 16;
  Slot *slot(uint64_t i, bool create) {
    const uint64_t c = i / kChunk;
    if (c >= kMaxChunks) throw std::runtime_error("max_requests beyond slot table");
    Slot *p = chunks_[c].load(std::memory_order_acquire);
    if (!p && create) {
      p = new Slot[kChunk];
      chunks_[c].store(p, std::memory_order_release);
    }
    return &p[i % kChunk];
  }
  // highest acknowledged update stamp per key (chunks allocated on first use; make() and on_response() may race)
  std::atomic<uint64_t> *acked(uint64_t key) {
    std::atomic<std::atomic<uint64_t> *> &c = kchunks_[key / kKeyChunk];
    std::atomic<uint64_t> *p = c.load(std::memory_order_acquire);
    if (!p) {
      auto *n = new std::atomic<uint64_t>[kKeyChunk];
      for (uint64_t i = 0; i < kKeyChunk; i++) n[i].store(0, std::memory_order_relaxed);
      if (c.compare_exchange_strong(p, n, std::memory_order_acq_rel)) p = n;
      else delete[] n;
    }
    return &p[key % kKeyChunk];
  }

  uint32_t targets_ = 1;
  uint64_t keys_ = 0, seed_ = 0, max_requests_ = 0, next_ = 0, version_ = 0;
  bool log_ = false;
  double update_ratio_ = 0.05;
  std::mt19937_64 rng_, kind_rng_;
  std::uniform_real_distribution<double> kind_uni_{0.0, 1.0};
  std::unique_ptr<ScrambledZipfian> zipf_;
  std::unique_ptr<std::atomic<Slot *>[]> chunks_;
  std::unique_ptr<std::atomic<std::atomic<uint64_t> *>[]> kchunks_;
  std::atomic<uint64_t> gets_ok_{0}, updates_ok_{0}, not_found_{0}, errors_{0}, bad_values_{0}, stale_{0};
  std::mutex mu_;
  std::vector<LogRec> glog_, ulog_;
};
LOADGEN_REGISTER("rocksdb", RocksPlugin);

}  // namespace

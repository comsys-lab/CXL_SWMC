// loadgen plugin "kv" (workloads/kv, experiments/loadgen/README.md): requests of `batch` operations over keys
// 0..keys-1 of kv-server. Streams: "mixed" (main runs: --mix mixed=1 --slo mixed:99:1; each op of a request is a put
// with probability put_ratio, else a get; SLO per request), "get" / "put" (requests of one op kind; --mix get=..,put=..).
// Ops per second = request rate x batch; get/s = the servers' `gets` deltas (stats op) or x * batch * (1 - put_ratio).
// Keys: YCSB scrambled Zipfian (the artifact's ScrambledZipfianGenerator: Zipfian over 1e10 items with its zeta
// constant, theta 0.99, FNV-1a 64 of the rank mod keys) or uniform; seeded (the artifact draws from random_device).
// Targets: round-robin per stream over --target (target order = node order; the put's writer = target index).
// Puts carry full self-checking values (proto.h): stamp = writer << 56 | version, version = per-key put count made here.
// Get check, per key: (1) complete value of that key (no torn/misplaced bytes), writer < targets or initial load;
//   (2) version <= puts made so far for the key ("future" otherwise); (3) version >= floor_at_make, where floor[key] is
//   the version of the last put to the key that was the only put to it in flight from its make to its ack and was
//   followed by no other put before its ack (so it was the last one applied); a get made after that ack must see it or
//   a later put ("stale" otherwise). Concurrent puts to one key are applied in an order this generator cannot know, so
//   the floor only advances on such quiet puts.
// Options: keys=N (required, = kv-server --keys), dist=zipf|uniform (zipf), theta=0.99 (only 0.99: the artifact's
//          constants), batch=1 (1..64), put_ratio=0.05 (mixed stream), seed=N (20261016), check=1 (0: no value
//          check), inflight=N (ring slots for outstanding requests per stream, default 4M / batch).
// Output: <out>/kv.txt (counts). finish() fails the run on any check error or miss.
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "../proto.h"
#include "frame.h"
#include "workload.h"

namespace {

// The artifact's ScrambledZipfianGenerator(num_items, 0.99) (benchmarks/zipf_implementation.h), with a seeded uniform.
class ScrambledZipf {
 public:
  ScrambledZipf(uint64_t n, uint64_t seed) : n_(n), rng_(seed) {
    zeta2_ = 1.0 + std::pow(0.5, kTheta);
    alpha_ = 1.0 / (1.0 - kTheta);
    eta_ = (1.0 - std::pow(2.0 / double(kItems), 1.0 - kTheta)) / (1.0 - zeta2_ / kZetan);
  }
  uint64_t next() {
    const double u = uni_(rng_), uz = u * kZetan;
    uint64_t r;
    if (uz < 1.0) r = 0;
    else if (uz < 1.0 + std::pow(0.5, kTheta)) r = 1;
    else r = uint64_t(double(kItems) * std::pow(eta_ * u - eta_ + 1.0, alpha_));
    if (r > kItems - 1) r = kItems - 1;
    return fnv64(r) % n_;
  }
  static constexpr double kTheta = 0.99;

 private:
  static uint64_t fnv64(uint64_t v) {
    uint64_t h = 0xCBF29CE484222325ull;
    for (int i = 0; i < 8; i++) {
      h ^= v & 0xff;
      h *= 1099511628211ull;
      v >>= 8;
    }
    return h;
  }
  static constexpr double kZetan = 26.46902820178302;  // zeta(1e10, 0.99), artifact constant
  static constexpr uint64_t kItems = 10000000000ull;
  uint64_t n_;
  std::mt19937_64 rng_;
  std::uniform_real_distribution<double> uni_{0.0, 1.0};
  double zeta2_, alpha_, eta_;
};

struct Slot {             // one outstanding request (ring indexed by seq)
  uint64_t seq = ~0ull;
  uint32_t target = 0;
  uint32_t n = 0;
};

class Kv : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    for (auto &kvp : o)
      if (kvp.first != "keys" && kvp.first != "dist" && kvp.first != "theta" && kvp.first != "batch" &&
          kvp.first != "seed" && kvp.first != "check" && kvp.first != "inflight" && kvp.first != "put_ratio")
        return *err = "kv: unknown option " + kvp.first, false;
    keys_ = std::stoull(get("keys", "0"));
    dist_ = get("dist", "zipf");
    theta_ = std::stod(get("theta", "0.99"));
    batch_ = std::stoul(get("batch", "1"));
    seed_ = std::stoull(get("seed", "20261016"));
    check_ = get("check", "1") != "0";
    inflight_ = std::stoull(get("inflight", std::to_string((4u << 20) / std::max(1u, batch_))));
    put_ratio_ = std::stod(get("put_ratio", "0.05"));
    if (!(put_ratio_ >= 0.0 && put_ratio_ <= 1.0)) return *err = "kv: put_ratio 0..1", false;
    if (keys_ < 2) return *err = "kv: keys=N (>= 2) required", false;
    if (dist_ != "zipf" && dist_ != "uniform") return *err = "kv: dist=zipf|uniform", false;
    if (dist_ == "zipf" && std::fabs(theta_ - ScrambledZipf::kTheta) > 1e-12)
      return *err = "kv: theta must be 0.99 (the artifact's zeta constant)", false;
    if (batch_ < 1 || batch_ > kv::kMaxBatch) return *err = "kv: batch 1..64", false;
    if (targets == 0 || targets >= kv::kPreloadWriter) return *err = "kv: bad target count", false;
    if (inflight_ < 1024) return *err = "kv: inflight >= 1024", false;
    targets_ = targets;
    for (int s = 0; s < 3; s++) gen_[s] = std::make_unique<ScrambledZipf>(keys_, seed_ * 1000003 + uint64_t(s));
    uni_rng_.seed(seed_ ^ 0x9e3779b97f4a7c15ull);
    kind_rng_.seed(seed_ ^ 0x6a09e667f3bcc909ull);
    made_.reset(new uint32_t[keys_]());
    acked_.reset(new uint32_t[keys_]());
    floor_.reset(new uint32_t[keys_]());
    for (int s = 0; s < 3; s++) {
      rkind_[s].reset(new uint8_t[inflight_ * batch_]());  // 1 = put
      ring_[s].reset(new Slot[inflight_]);
      rkeys_[s].reset(new uint64_t[inflight_ * batch_]);
      rinfo_[s].reset(new uint32_t[inflight_ * batch_]);  // get: floor at make; put: version | quiet << 31
    }
    return true;
  }

  // streams: 0 "get" (all ops gets), 1 "put" (all puts), 2 "mixed" (each op a put with probability put_ratio)
  std::vector<loadgen::StreamSpec> streams() const override { return {{"get", false}, {"put", false}, {"mixed", false}}; }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    const uint64_t seq = next_[stream]++;
    r->stream = stream;
    r->seq = seq;
    r->target = uint32_t(seq % targets_);
    Slot &sl = ring_[stream][seq % inflight_];
    if (__atomic_load_n(&sl.seq, __ATOMIC_ACQUIRE) != ~0ull) overwritten_++;  // older request still unanswered
    sl.target = r->target;
    sl.n = batch_;
    const size_t base = (seq % inflight_) * batch_;
    uint64_t *ks = &rkeys_[stream][base];
    uint32_t *in = &rinfo_[stream][base];
    uint8_t *kind = &rkind_[stream][base];
    uint32_t np = 0;
    for (uint32_t x = 0; x < batch_; x++) {
      ks[x] = next_key(stream);
      kind[x] = stream == 1 || (stream == 2 && kind_uni_(kind_rng_) < put_ratio_);
      np += kind[x];
    }
    const uint64_t vb = kv::kValueBytes;
    uint8_t *vals;  // where the put values go
    if (stream == 2) {
      r->op = kv::kOpMixed;
      p->resize(sizeof(kv::MixedReq) + 8ull * batch_ + vb * np);
      kv::MixedReq rq{uint16_t(batch_), 0, 0};
      std::memcpy(p->data(), &rq, sizeof(rq));
      for (uint32_t x = 0; x < batch_; x++) {
        const uint64_t d = ks[x] | (kind[x] ? kv::kPutBit : 0);
        std::memcpy(p->data() + sizeof(rq) + 8ull * x, &d, 8);
      }
      vals = p->data() + sizeof(rq) + 8ull * batch_;
    } else if (stream == 0) {
      r->op = kv::kOpGet;
      p->resize(sizeof(kv::GetReq) + 8ull * batch_);
      kv::GetReq rq{uint16_t(batch_), 0, 0};
      std::memcpy(p->data(), &rq, sizeof(rq));
      for (uint32_t x = 0; x < batch_; x++) std::memcpy(p->data() + sizeof(rq) + 8ull * x, &ks[x], 8);
      vals = nullptr;
    } else {
      r->op = kv::kOpPut;
      p->resize(sizeof(kv::PutReq) + (8 + vb) * batch_);
      kv::PutReq rq{uint16_t(batch_), 0, 0};
      std::memcpy(p->data(), &rq, sizeof(rq));
      vals = p->data() + sizeof(rq);
    }
    for (uint32_t x = 0; x < batch_; x++) {
      const uint64_t k = ks[x];
      if (!kind[x]) {
        in[x] = __atomic_load_n(&floor_[k], __ATOMIC_ACQUIRE);
        continue;
      }
      const uint32_t v = __atomic_add_fetch(&made_[k], 1u, __ATOMIC_ACQ_REL);
      if (v >= 0x7fffffffu) {
        overflow_++;
        return false;
      }
      const bool quiet = __atomic_load_n(&acked_[k], __ATOMIC_ACQUIRE) == v - 1;
      in[x] = v | (quiet ? 0x80000000u : 0);
      if (stream == 1) {  // PutReq record: key + value
        std::memcpy(vals, &k, 8);
        vals += 8;
      }
      kv::fill_value(vals, k, kv::stamp(r->target, v));
      vals += vb;
    }
    __atomic_store_n(&sl.seq, seq, __ATOMIC_RELEASE);  // the request is sent after make() returns
    return true;
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t status, const uint8_t *p, uint32_t len) override {
    (void)measured;
    Slot &sl = ring_[r.stream][r.seq % inflight_];
    if (__atomic_load_n(&sl.seq, __ATOMIC_ACQUIRE) != r.seq) {
      unchecked_++;
      return;
    }
    struct Done {  // the slot is free for reuse once this response is handled
      Slot &s;
      ~Done() { __atomic_store_n(&s.seq, ~0ull, __ATOMIC_RELEASE); }
    } done{sl};
    const size_t base = (r.seq % inflight_) * batch_;
    const uint64_t *ks = &rkeys_[r.stream][base];
    const uint32_t *in = &rinfo_[r.stream][base];
    const uint8_t *kind = &rkind_[r.stream][base];
    uint32_t np = 0;
    for (uint32_t x = 0; x < sl.n; x++) np += kind[x];
    const uint32_t ng = sl.n - np;
    size_t hdr = 0;
    bool ok = status == frame::kStatusOk;
    uint32_t misses = 0;
    if (ok && r.stream == 0) {
      kv::GetResp rs{};
      ok = len == sizeof(rs) + size_t(ng) * kv::kValueBytes;
      if (ok) std::memcpy(&rs, p, sizeof(rs)), misses = rs.misses;
      hdr = sizeof(rs);
    } else if (ok && r.stream == 1) {
      ok = len == sizeof(kv::PutResp);
    } else if (ok) {
      kv::MixedResp rs{};
      ok = len == sizeof(rs) + size_t(ng) * kv::kValueBytes;
      if (ok) std::memcpy(&rs, p, sizeof(rs)), misses = rs.misses, ok = rs.gets == ng && rs.puts == np;
      hdr = sizeof(rs);
    }
    // puts: acknowledged (also on errors, so the quiet test stays consistent); floor advances on quiet last puts
    for (uint32_t x = 0; x < sl.n; x++) {
      if (!kind[x]) continue;
      const uint64_t k = ks[x];
      const uint32_t v = in[x] & 0x7fffffffu;
      __atomic_add_fetch(&acked_[k], 1u, __ATOMIC_ACQ_REL);
      if (ok && (in[x] & 0x80000000u) && __atomic_load_n(&made_[k], __ATOMIC_ACQUIRE) == v) {
        uint32_t f = __atomic_load_n(&floor_[k], __ATOMIC_RELAXED);
        while (f < v && !__atomic_compare_exchange_n(&floor_[k], &f, v, true, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        }
      }
    }
    if (!ok) {
      (r.stream == 1 ? put_err_ : get_err_)++;
      return;
    }
    puts_ += np;
    gets_ += ng;
    misses_ += misses;
    if (!check_) return;
    const uint8_t *v = p + hdr;
    for (uint32_t x = 0; x < sl.n; x++) {
      if (kind[x]) continue;
      check_get(r, sl, ks[x], in[x], v);
      v += kv::kValueBytes;
    }
  }

  void check_get(const loadgen::Request &r, const Slot &sl, uint64_t k, uint32_t floor_at_make, const uint8_t *v) {
    uint64_t st;
    if (!kv::check_value(v, k, &st)) {
      uint64_t w0;
      std::memcpy(&w0, v, 8);
      if (w0 == 0 && st == 0) return;  // a miss (counted by the server's misses)
      (w0 == k ? torn_ : wrong_key_)++;
      report(r, k, v, "torn or misplaced value");
      return;
    }
    const uint64_t w = kv::stamp_writer(st), ver = kv::stamp_version(st);
    if (w == kv::kPreloadWriter ? ver != 0 : w >= targets_) {
      bad_writer_++;
      report(r, k, v, "bad writer/version");
      return;
    }
    if (ver > __atomic_load_n(&made_[k], __ATOMIC_ACQUIRE)) {
      future_++;
      report(r, k, v, "version newer than any put made");
      return;
    }
    if (ver < floor_at_make) {
      stale_++;
      report(r, k, v, "stale: older than the last quiet put acknowledged before this get was made");
      return;
    }
    checked_++;
    if (ver > 0 && ver == floor_at_make) floor_hits_++;
    if (w != kv::kPreloadWriter) {
      if (w != sl.target) remote_++;
      else local_++;
    } else initial_++;
  }

  bool finish(const std::string &out_dir, std::string *err) override {
    std::string t = counts();
    if (FILE *f = std::fopen((out_dir + "/kv.txt").c_str(), "w")) {
      std::fputs(t.c_str(), f);
      std::fclose(f);
    }
    std::fputs(t.c_str(), stderr);
    const uint64_t errors = torn_ + wrong_key_ + bad_writer_ + future_ + stale_ + misses_ + get_err_ + put_err_ + overflow_;
    if (errors) {
      *err = "kv value check: " + std::to_string(errors) + " errors (see kv.txt)";
      return false;
    }
    return true;
  }

  std::string describe() const override {
    return "kv keys=" + std::to_string(keys_) + " dist=" + dist_ + (dist_ == "zipf" ? " theta=0.99" : "") +
           " batch=" + std::to_string(batch_) + " put_ratio=" + std::to_string(put_ratio_) + " seed=" + std::to_string(seed_) + " check=" + std::to_string(check_) +
           " value_bytes=" + std::to_string(kv::kValueBytes) + " targets=" + std::to_string(targets_);
  }

 private:
  uint64_t next_key(uint32_t stream) {
    if (dist_ == "zipf") return gen_[stream]->next();
    return std::uniform_int_distribution<uint64_t>(0, keys_ - 1)(uni_rng_);
  }

  void report(const loadgen::Request &r, uint64_t k, const uint8_t *v, const char *what) {
    if (reported_.fetch_add(1) >= 10) return;
    uint64_t w[2];
    std::memcpy(w, v, 16);
    std::fprintf(stderr, "kv: CHECK FAIL %s: get seq %lu target %u key %lu -> word0 %lu stamp %#lx (made %u floor %u)\n",
                 what, (unsigned long)r.seq, r.target, (unsigned long)k, (unsigned long)w[0], (unsigned long)w[1],
                 __atomic_load_n(&made_[k], __ATOMIC_RELAXED), __atomic_load_n(&floor_[k], __ATOMIC_RELAXED));
  }

  std::string counts() const {
    std::string s;
    auto add = [&](const char *k, uint64_t v) { s += std::string(k) + "=" + std::to_string(v) + "\n"; };
    add("gets", gets_), add("puts", puts_), add("checked", checked_), add("remote_values", remote_);
    add("local_values", local_), add("initial_values", initial_), add("misses", misses_), add("torn", torn_);
    add("wrong_key", wrong_key_), add("bad_writer", bad_writer_), add("future", future_), add("stale", stale_), add("floor_hits", floor_hits_);
    add("get_errors", get_err_), add("put_errors", put_err_), add("unchecked", unchecked_);
    add("ring_overwritten", overwritten_), add("version_overflow", overflow_);
    return s;
  }

  uint64_t keys_ = 0, seed_ = 0, inflight_ = 0;
  std::string dist_;
  double theta_ = 0.99;
  uint32_t batch_ = 1, targets_ = 1;
  bool check_ = true;
  std::unique_ptr<ScrambledZipf> gen_[3];
  double put_ratio_ = 0.05;
  std::mt19937_64 kind_rng_;
  std::uniform_real_distribution<double> kind_uni_{0.0, 1.0};
  std::mt19937_64 uni_rng_;
  uint64_t next_[3] = {0, 0, 0};
  std::unique_ptr<uint32_t[]> made_, acked_, floor_;
  std::unique_ptr<Slot[]> ring_[3];
  std::unique_ptr<uint64_t[]> rkeys_[3];
  std::unique_ptr<uint32_t[]> rinfo_[3];
  std::unique_ptr<uint8_t[]> rkind_[3];
  std::atomic<uint64_t> gets_{0}, puts_{0}, checked_{0}, remote_{0}, local_{0}, initial_{0}, misses_{0}, torn_{0},
      wrong_key_{0}, bad_writer_{0}, future_{0}, stale_{0}, floor_hits_{0}, get_err_{0}, put_err_{0}, unchecked_{0}, reported_{0};
  uint64_t overwritten_ = 0, overflow_ = 0;
};
LOADGEN_REGISTER("kv", Kv);

}  // namespace

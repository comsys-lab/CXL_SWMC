// socialgraph loadgen: key, op-mix and payload generators (experiment doc reports/experiments/socialgraph-serving.md
// §2; LinkBench parameters tools/linkbench_params.h). Header-only so the unit test (keys_test.cc) checks exactly the
// code the plugin runs.
//
// Keys (user 2026-11-11 "TAO trace 처럼"): a Zipf rank r (exact pmf p_r ~ r^-s over the n original nodes, as the image
// generator's expected-rows calculation) is mapped to a node slot through a Fisher-Yates permutation driven by a
// splitmix64 stream. Reads (feed, countlink, getlink: s = 0.8; getnode: s = 0.625) use the READ permutation, whose
// seed and algorithm are those of tools/sg_image_gen.cc (default --perm-seed 0x5347524541444b31 =
// 6000855485895691057, recorded as gen.json feed_rows_expected.fisher_yates_perm_seed); writes (link writes s = 0.741,
// updatenode s = 0.606; deletenode uniform) use an independent WRITE permutation (another seed). No degree-correlated
// blend (the Orkut graph has no LinkBench degree shuffler).
// Op mix: LinkBench request proportions, reads renormalized over reads, writes over writes; read:write by request.
#pragma once

#include <cmath>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

#include "../tools/linkbench_params.h"

namespace sgl {

namespace lb = ::socialgraph::linkbench;

constexpr uint64_t kReadPermSeed = 0x5347524541444b31ull;   // sg_image_gen.cc --perm-seed default (image build 1)
constexpr uint64_t kWritePermSeed = 0x53475752495445b1ull;  // independent write permutation (ours)

inline uint64_t splitmix64(uint64_t x) {  // identical to tools/image_builder.h
  x += 0x9e3779b97f4a7c15ull;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}

// Fisher-Yates over [0, n), splitmix64 stream; the exact loop of tools/sg_image_gen.cc (perm[rank] = node slot).
inline std::vector<uint32_t> fisher_yates_perm(uint64_t n, uint64_t seed) {
  std::vector<uint32_t> perm(n);
  for (uint64_t i = 0; i < n; i++) perm[i] = uint32_t(i);
  uint64_t rs = seed;
  for (uint64_t i = n - 1; n > 1 && i > 0; i--) {
    rs = splitmix64(rs);
    uint64_t j = uint64_t((unsigned __int128)rs * (i + 1) >> 64);
    std::swap(perm[i], perm[j]);
  }
  return perm;
}

// Exact Zipf pmf over ranks 0..n-1 (p_r ~ (r+1)^-s), sampled with a Vose alias table (O(1) per draw).
class Zipf {
 public:
  void build(uint64_t n, double s) {
    n_ = n, s_ = s;
    std::vector<double> w(n);
    double H = 0;
    for (uint64_t r = 0; r < n; r++) H += (w[r] = std::pow(double(r + 1), -s));
    H_ = H;
    prob_.assign(n, 0);
    alias_.assign(n, 0);
    std::vector<uint32_t> small, large;
    small.reserve(n), large.reserve(n);
    for (uint64_t r = 0; r < n; r++) {
      w[r] = w[r] * double(n) / H;
      (w[r] < 1.0 ? small : large).push_back(uint32_t(r));
    }
    while (!small.empty() && !large.empty()) {
      uint32_t a = small.back(), b = large.back();
      small.pop_back();
      prob_[a] = w[a], alias_[a] = b;
      w[b] = (w[b] + w[a]) - 1.0;
      if (w[b] < 1.0) large.pop_back(), small.push_back(b);
    }
    for (uint32_t r : large) prob_[r] = 1.0, alias_[r] = r;
    for (uint32_t r : small) prob_[r] = 1.0, alias_[r] = r;  // rounding leftovers
  }
  template <class R> uint32_t draw(R &rng) const {
    const uint64_t x = rng();
    const uint32_t col = uint32_t((unsigned __int128)x * n_ >> 64);
    const double u = double(rng() >> 11) * (1.0 / 9007199254740992.0);
    return u < prob_[col] ? col : alias_[col];
  }
  double pmf(uint64_t r) const { return std::pow(double(r + 1), -s_) / H_; }
  uint64_t n() const { return n_; }
  double shape() const { return s_; }

 private:
  uint64_t n_ = 0;
  double s_ = 0, H_ = 0;
  std::vector<double> prob_;
  std::vector<uint32_t> alias_;
};

// ---- op mix ----
enum Stream : uint32_t { kFeed = 0, kGetNode = 1, kCountLink = 2, kGetLink = 3, kWrite = 4, kStreams = 5 };
inline const char *stream_name(uint32_t s) {
  static const char *n[] = {"feed", "getnode", "countlink", "getlink", "write"};
  return s < kStreams ? n[s] : "?";
}
enum WriteOp : uint32_t { kAddLink, kUpdateLink, kDeleteLink, kAddNode, kUpdateNode, kDeleteNode, kWriteOps };
inline const char *write_name(uint32_t w) {
  static const char *n[] = {"addlink", "updatelink", "deletelink", "addnode", "updatenode", "deletenode"};
  return w < kWriteOps ? n[w] : "?";
}

inline double lb_pct(lb::Op op) {
  for (const auto &m : lb::kOpMix)
    if (m.op == op) return m.pct;
  return 0;
}

// Fractions of all requests for read:write = rw:1 (by request). Read ops: LinkBench getlinklist (= feed), getnode,
// countlink, getlink renormalized over reads (getlinklist_history dropped); writes: one stream, op by write_frac().
struct Mix {
  double rw = 100;
  double stream[kStreams] = {};
  double write_op[kWriteOps] = {};  // within writes, sums to 1
  explicit Mix(double rw_ = 100) : rw(rw_) {
    const double rd[4] = {lb_pct(lb::Op::kGetLinkList), lb_pct(lb::Op::kGetNode), lb_pct(lb::Op::kCountLink),
                          lb_pct(lb::Op::kGetLink)};
    const double rsum = rd[0] + rd[1] + rd[2] + rd[3];
    const double read_share = rw / (rw + 1.0);
    for (int i = 0; i < 4; i++) stream[i] = read_share * rd[i] / rsum;
    stream[kWrite] = 1.0 / (rw + 1.0);
    const double wr[kWriteOps] = {lb_pct(lb::Op::kAddLink),  lb_pct(lb::Op::kUpdateLink), lb_pct(lb::Op::kDeleteLink),
                                  lb_pct(lb::Op::kAddNode),  lb_pct(lb::Op::kUpdateNode), lb_pct(lb::Op::kDeleteNode)};
    double wsum = 0;
    for (double v : wr) wsum += v;
    for (uint32_t i = 0; i < kWriteOps; i++) write_op[i] = wr[i] / wsum;
  }
  // loadgen --mix value (weights = percent of all requests)
  std::string loadgen_mix() const {
    std::string s;
    char b[64];
    for (uint32_t i = 0; i < kStreams; i++) {
      std::snprintf(b, sizeof(b), "%s%s=%.6f", i ? "," : "", stream_name(i), 100.0 * stream[i]);
      s += b;
    }
    return s;
  }
};

// Write op of one write request (LinkBench write proportions).
class WriteOpSampler {
 public:
  explicit WriteOpSampler(const Mix &m) {
    double c = 0;
    for (uint32_t i = 0; i < kWriteOps; i++) cum_[i] = (c += m.write_op[i]);
    cum_[kWriteOps - 1] = 1.0;
  }
  template <class R> uint32_t draw(R &rng) const {
    const double u = double(rng() >> 11) * (1.0 / 9007199254740992.0);
    for (uint32_t i = 0; i < kWriteOps; i++)
      if (u < cum_[i]) return i;
    return kWriteOps - 1;
  }

 private:
  double cum_[kWriteOps];
};

// ---- small LinkBench samplers ----
template <class R> inline double u01(R &rng) { return double(rng() >> 11) * (1.0 / 9007199254740992.0); }
// getlink multiget size: GeometricDistribution (min 1, max 128 exclusive, p 0.382); u == 0 -> min.
template <class R> inline uint32_t multiget_size(R &rng) {
  const double u = u01(rng);
  if (u == 0) return lb::kMultigetMin;
  double k = lb::kMultigetMin + std::ceil(std::log(1 - u) / std::log(1 - lb::kMultigetProb));
  if (k > lb::kMultigetMax - 1) k = lb::kMultigetMax - 1;
  return uint32_t(k);
}
// payload size: LogNormal(median, sigma) clamped to [min, max-1] (LinkBench), then capped at the slot data field.
template <class R> inline uint32_t payload_size(R &rng, const lb::LogNormalSpec &ln, uint32_t cap) {
  std::normal_distribution<double> nd(0.0, 1.0);
  double v = std::round(std::exp(ln.sigma * nd(rng) + std::log(ln.median)));
  if (v < double(ln.min)) v = double(ln.min);
  if (v > double(ln.max_excl - 1)) v = double(ln.max_excl - 1);
  return v > double(cap) ? cap : uint32_t(v);
}

// ---- keys ----
struct KeyParams {
  uint64_t n = 3072626;  // original nodes (image build 1 gen.json "nodes")
  uint64_t read_perm_seed = kReadPermSeed, write_perm_seed = kWritePermSeed;
  double read_zipf = 0.8, getnode_zipf = 0.625, wlink_zipf = 0.741, wnode_zipf = 0.606;
};

class KeyGen {
 public:
  void build(const KeyParams &p) {
    p_ = p;
    read_perm_ = fisher_yates_perm(p.n, p.read_perm_seed);
    write_perm_ = fisher_yates_perm(p.n, p.write_perm_seed);
    z_read_.build(p.n, p.read_zipf);
    z_getnode_.build(p.n, p.getnode_zipf);
    z_wlink_.build(p.n, p.wlink_zipf);
    z_wnode_.build(p.n, p.wnode_zipf);
  }
  // node slots (id = slot + id_base)
  template <class R> uint32_t link_read(R &rng) const { return read_perm_[z_read_.draw(rng)]; }
  template <class R> uint32_t node_read(R &rng) const { return read_perm_[z_getnode_.draw(rng)]; }
  template <class R> uint32_t link_write(R &rng) const { return write_perm_[z_wlink_.draw(rng)]; }
  template <class R> uint32_t node_update(R &rng) const { return write_perm_[z_wnode_.draw(rng)]; }
  template <class R> uint32_t node_delete(R &rng) const { return uint32_t((unsigned __int128)rng() * p_.n >> 64); }
  template <class R> uint32_t uniform(R &rng) const { return uint32_t((unsigned __int128)rng() * p_.n >> 64); }
  const std::vector<uint32_t> &read_perm() const { return read_perm_; }
  const std::vector<uint32_t> &write_perm() const { return write_perm_; }
  const Zipf &z_read() const { return z_read_; }
  const Zipf &z_getnode() const { return z_getnode_; }
  const Zipf &z_wlink() const { return z_wlink_; }
  const Zipf &z_wnode() const { return z_wnode_; }
  const KeyParams &params() const { return p_; }

 private:
  KeyParams p_;
  std::vector<uint32_t> read_perm_, write_perm_;
  Zipf z_read_, z_getnode_, z_wlink_, z_wnode_;
};

}  // namespace sgl

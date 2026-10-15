// DLRMv2 dense part on the CPU (DESIGN.md §6): bottom MLP, DCNv2 low-rank cross network, top MLP, fp32.
// Same structure as torchrec DLRM_DCN (MLPerf DLRMv2): DenseArch 13-512-256-128 (ReLU), interaction input
// x0 = [dense_out, pooled emb of 26 features] (27 x 128 = 3456), LowRankCrossNet 3 layers rank 512
// (x_{l+1} = x0 * (W_l (V_l x_l) + b_l) + x_l), OverArch 1024-1024-512-256 (ReLU) + linear to 1, sigmoid.
// Weights are process-local (each node's DRAM), deterministic from the seed (random; trained weights: §9 D4).
// GEMM: weights packed in 32-column panels, AVX-512 8x32 micro-kernel (scalar fallback without AVX-512F).
#pragma once

#include <immintrin.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace rsys {

constexpr uint32_t kPanel = 32;

struct Linear {
  uint32_t in = 0, out = 0;  // out % 32 == 0 (packed) or out == 1 (dot)
  std::vector<float> w;      // packed: [out/32][in][32]; out == 1: [in]
  std::vector<float> b;      // [out] (empty: no bias)

  void init(uint32_t i, uint32_t o, bool bias, uint64_t seed) {
    in = i, out = o;
    w.assign(size_t(i) * o, 0.f);
    if (bias) b.assign(o, 0.f);
    uint64_t x = seed * 0x9e3779b97f4a7c15ull + 0x632be59bd9b4e019ull;
    const float a = std::sqrt(6.f / float(i + o));
    auto rnd = [&] {
      x ^= x << 13, x ^= x >> 7, x ^= x << 17;
      return (float(x >> 40) / float(1ull << 24) * 2.f - 1.f) * a;
    };
    std::vector<float> dense(size_t(i) * o);  // row-major [in][out]
    for (auto &v : dense) v = rnd();
    for (auto &v : b) v = rnd() * 0.1f;
    pack(dense.data());
  }
  void pack(const float *dense) {  // dense [in][out]
    if (out == 1) {
      std::memcpy(w.data(), dense, size_t(in) * 4);
      return;
    }
    for (uint32_t p = 0; p < out / kPanel; p++)
      for (uint32_t k = 0; k < in; k++)
        std::memcpy(&w[(size_t(p) * in + k) * kPanel], dense + size_t(k) * out + p * kPanel, kPanel * 4);
  }
  uint64_t flops_per_row() const { return 2ull * in * out; }
};

// Y[m][out] (ldy) = X[m][in] (ldx) * W + b, optional ReLU.
template <int R>
inline void gemm_block(const Linear &L, const float *X, size_t ldx, float *Y, size_t ldy, bool relu) {
#ifdef __AVX512F__
  for (uint32_t p = 0; p < L.out / kPanel; p++) {
    __m512 acc[R][2];
    for (int r = 0; r < R; r++) acc[r][0] = acc[r][1] = _mm512_setzero_ps();
    const float *wp = &L.w[size_t(p) * L.in * kPanel];
    for (uint32_t k = 0; k < L.in; k++) {
      const __m512 w0 = _mm512_loadu_ps(wp + size_t(k) * kPanel), w1 = _mm512_loadu_ps(wp + size_t(k) * kPanel + 16);
      for (int r = 0; r < R; r++) {
        const __m512 a = _mm512_set1_ps(X[r * ldx + k]);
        acc[r][0] = _mm512_fmadd_ps(a, w0, acc[r][0]);
        acc[r][1] = _mm512_fmadd_ps(a, w1, acc[r][1]);
      }
    }
    const __m512 b0 = L.b.empty() ? _mm512_setzero_ps() : _mm512_loadu_ps(&L.b[p * kPanel]);
    const __m512 b1 = L.b.empty() ? _mm512_setzero_ps() : _mm512_loadu_ps(&L.b[p * kPanel + 16]);
    for (int r = 0; r < R; r++) {
      __m512 y0 = _mm512_add_ps(acc[r][0], b0), y1 = _mm512_add_ps(acc[r][1], b1);
      if (relu) y0 = _mm512_max_ps(y0, _mm512_setzero_ps()), y1 = _mm512_max_ps(y1, _mm512_setzero_ps());
      _mm512_storeu_ps(Y + r * ldy + p * kPanel, y0);
      _mm512_storeu_ps(Y + r * ldy + p * kPanel + 16, y1);
    }
  }
#else
  for (int r = 0; r < R; r++)
    for (uint32_t p = 0; p < L.out / kPanel; p++) {
      float acc[kPanel] = {0};
      const float *wp = &L.w[size_t(p) * L.in * kPanel];
      for (uint32_t k = 0; k < L.in; k++) {
        const float a = X[r * ldx + k];
        for (uint32_t c = 0; c < kPanel; c++) acc[c] += a * wp[size_t(k) * kPanel + c];
      }
      for (uint32_t c = 0; c < kPanel; c++) {
        float y = acc[c] + (L.b.empty() ? 0.f : L.b[p * kPanel + c]);
        Y[r * ldy + p * kPanel + c] = relu && y < 0 ? 0.f : y;
      }
    }
#endif
}

inline void gemm(const Linear &L, const float *X, size_t ldx, uint32_t m, float *Y, size_t ldy, bool relu) {
  if (L.out == 1) {
    for (uint32_t r = 0; r < m; r++) {
      float s = L.b.empty() ? 0.f : L.b[0];
      for (uint32_t k = 0; k < L.in; k++) s += X[r * ldx + k] * L.w[k];
      Y[r * ldy] = relu && s < 0 ? 0.f : s;
    }
    return;
  }
  uint32_t r = 0;
  for (; r + 8 <= m; r += 8) gemm_block<8>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu);
  switch (m - r) {
    case 7: gemm_block<7>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 6: gemm_block<6>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 5: gemm_block<5>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 4: gemm_block<4>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 3: gemm_block<3>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 2: gemm_block<2>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    case 1: gemm_block<1>(L, X + r * ldx, ldx, Y + r * ldy, ldy, relu); break;
    default: break;
  }
}

struct ModelSpec {
  uint32_t dense_in = 13, dim = 128, sparse = 26, rank = 512, cross_layers = 3;
  std::vector<uint32_t> bottom{512, 256};  // + dim
  std::vector<uint32_t> top{1024, 1024, 512, 256};  // + 1
  uint32_t inter() const { return (sparse + 1) * dim; }
};

class Model {
 public:
  void init(const ModelSpec &s, uint64_t seed) {
    s_ = s;
    uint64_t li = 0;
    uint32_t prev = s.dense_in;
    for (uint32_t o : s.bottom) bottom_.emplace_back(), bottom_.back().init(prev, o, true, seed + ++li), prev = o;
    bottom_.emplace_back(), bottom_.back().init(prev, s.dim, true, seed + ++li);
    for (uint32_t l = 0; l < s.cross_layers; l++) {
      V_.emplace_back(), V_.back().init(s.inter(), s.rank, false, seed + ++li);
      W_.emplace_back(), W_.back().init(s.rank, s.inter(), true, seed + ++li);
    }
    prev = s.inter();
    for (uint32_t o : s.top) top_.emplace_back(), top_.back().init(prev, o, true, seed + ++li), prev = o;
    top_.emplace_back(), top_.back().init(prev, 1, true, seed + ++li);
  }
  const ModelSpec &spec() const { return s_; }
  uint64_t flops_per_pair() const {
    uint64_t f = 0;
    for (auto &l : bottom_) f += l.flops_per_row();
    for (uint32_t l = 0; l < s_.cross_layers; l++) f += V_[l].flops_per_row() + W_[l].flops_per_row() + 2ull * s_.inter();
    for (auto &l : top_) f += l.flops_per_row();
    return f;
  }
  uint64_t weight_bytes() const {
    uint64_t b = 0;
    auto add = [&](const Linear &l) { b += (l.w.size() + l.b.size()) * 4; };
    for (auto &l : bottom_) add(l);
    for (auto &l : V_) add(l);
    for (auto &l : W_) add(l);
    for (auto &l : top_) add(l);
    return b;
  }
  // Scratch per thread for m <= max_m rows.
  struct Scratch {
    uint32_t max_m = 0;
    std::vector<float> a, b, x0, xl, v, w;
  };
  void scratch(Scratch *s, uint32_t m) const {
    if (s->max_m >= m) return;
    s->max_m = m;
    uint32_t widest = std::max<uint32_t>(s_.inter(), 1024);
    for (uint32_t o : s_.bottom) widest = std::max(widest, o);
    s->a.assign(size_t(m) * widest, 0), s->b.assign(size_t(m) * widest, 0);
    s->x0.assign(size_t(m) * s_.inter(), 0), s->xl.assign(size_t(m) * s_.inter(), 0);
    s->v.assign(size_t(m) * s_.rank, 0), s->w.assign(size_t(m) * s_.inter(), 0);
  }
  // Bottom MLP: dense [m][dense_in] -> x0[:, 0:dim] (x0 row stride inter()).
  void bottom(const float *dense, uint32_t m, Scratch *s) const {
    const float *in = dense;
    size_t ld = s_.dense_in;
    for (size_t l = 0; l < bottom_.size(); l++) {
      const bool last = l + 1 == bottom_.size();
      float *out = last ? s->x0.data() : (l % 2 ? s->b.data() : s->a.data());
      const size_t ldo = last ? s_.inter() : bottom_[l].out;
      gemm(bottom_[l], in, ld, m, out, ldo, true);
      in = out, ld = ldo;
    }
  }
  // x0 complete (dense_out + pooled embeddings) -> score[m] (sigmoid).
  void top(uint32_t m, Scratch *s, float *score) const {
    const uint32_t D = s_.inter();
    std::memcpy(s->xl.data(), s->x0.data(), size_t(m) * D * 4);
    for (uint32_t l = 0; l < s_.cross_layers; l++) {
      gemm(V_[l], s->xl.data(), D, m, s->v.data(), s_.rank, false);
      gemm(W_[l], s->v.data(), s_.rank, m, s->w.data(), D, false);
      for (size_t i = 0; i < size_t(m) * D; i++) s->xl[i] += s->x0[i] * s->w[i];
    }
    const float *in = s->xl.data();
    size_t ld = D;
    for (size_t l = 0; l + 1 < top_.size(); l++) {
      float *out = l % 2 ? s->b.data() : s->a.data();
      gemm(top_[l], in, ld, m, out, top_[l].out, true);
      in = out, ld = top_[l].out;
    }
    gemm(top_.back(), in, ld, m, score, 1, false);
    for (uint32_t r = 0; r < m; r++) score[r] = 1.f / (1.f + std::exp(-score[r]));
  }

 private:
  ModelSpec s_;
  std::vector<Linear> bottom_, V_, W_, top_;
};

}  // namespace rsys

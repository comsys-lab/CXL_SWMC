// DLRMv2 dense part on the CPU (DESIGN.md §6): bottom MLP, DCNv2 low-rank cross network, top MLP, fp32.
// Same structure as torchrec DLRM_DCN (MLPerf DLRMv2): DenseArch 13-512-256-128 (ReLU), interaction input
// x0 = [dense_out, pooled emb of 26 features] (27 x 128 = 3456), LowRankCrossNet 3 layers rank 512
// (x_{l+1} = x0 * (W_l (V_l x_l) + b_l) + x_l), OverArch 1024-1024-512-256 (ReLU) + linear to 1, sigmoid.
// Weights are process-local (each node's DRAM), deterministic from the seed (random; trained weights: §9 D4).
// GEMM: weights packed in 32-column panels, AVX-512 8x32 micro-kernel (scalar fallback without AVX-512F).
// Serving forward with `--mlp amx`: bf16 AMX tiles, fp32 accumulation (amx.h; bottom()/top() Mlp argument).
#pragma once

#include <immintrin.h>

#include "amx.h"

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
  // v7: from a torch nn.Linear weight [o][i] (row-major) and bias [o] (nullptr: none).
  void load_torch(const float *wt, const float *bias, uint32_t i, uint32_t o) {
    in = i, out = o;
    w.assign(size_t(i) * o, 0.f);
    b.clear();
    if (bias) b.assign(bias, bias + o);
    if (o == 1) {
      std::memcpy(w.data(), wt, size_t(i) * 4);
      return;
    }
    std::vector<float> dense(size_t(i) * o);  // [in][out]
    for (uint32_t r = 0; r < o; r++)
      for (uint32_t k = 0; k < i; k++) dense[size_t(k) * o + r] = wt[size_t(r) * i + k];
    pack(dense.data());
  }
  // v7 backward: the transpose (in' = o, out' = i, no bias) of the torch weight [o][i]: Y = X W^T^T, i.e. g_in = g_out W.
  void load_torch_transposed(const float *wt, uint32_t i, uint32_t o) {
    in = o, out = i;
    w.assign(size_t(i) * o, 0.f);
    b.clear();
    pack(wt);  // [o][i] is the row-major [in'][out'] of the transpose
  }
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
  // Serving forward kind (`--mlp`): Mlp::avx512 = the fp32 packed GEMM above (default; the training path
  // top_train/backward always uses it); Mlp::amx = bf16 AMX tiles with fp32 accumulation (server/amx.h) for every
  // layer with out % 32 == 0 (needs prepare_amx() and amx_enable()); the final 256 -> 1 dot, bias, ReLU, the cross
  // update x_{l+1} = x0 * u + x_l and the sigmoid stay fp32 in both.
  // Trace (tests only): copy of each layer output [m][out], in order bottom 0..2 | per cross layer V x_l, u_l, x_{l+1}
  // | top 0..3, logit.
  using Trace = std::vector<std::vector<float>>;
  static void trace_push(Trace *t, const float *y, uint32_t m, size_t ld, uint32_t cols) {
    if (!t) return;
    t->emplace_back(size_t(m) * cols);
    for (uint32_t r = 0; r < m; r++) std::memcpy(&t->back()[size_t(r) * cols], y + r * ld, size_t(cols) * 4);
  }
  // bf16 AMX tile copies of the forward layers (load time, after init / load_dense).
  void prepare_amx() {
    auto pk = [](const std::vector<Linear> &src, std::vector<AmxLinear> *dst) {
      dst->assign(src.size(), {});
      for (size_t i = 0; i < src.size(); i++)
        if (src[i].out % kPanel == 0) (*dst)[i].pack(src[i].in, src[i].out, src[i].w, src[i].b);
    };
    pk(bottom_, &abottom_), pk(V_, &aV_), pk(W_, &aW_), pk(top_, &atop_);
  }
  bool amx_ready() const { return !atop_.empty() && atop_.size() == top_.size(); }
  uint64_t amx_weight_bytes() const {
    uint64_t b = 0;
    for (auto *v : {&abottom_, &aV_, &aW_, &atop_})
      for (auto &l : *v) b += l.wb.size() * 2 + l.b.size() * 4;
    return b;
  }
  // Bottom MLP: dense [m][dense_in] -> x0[:, 0:dim] (x0 row stride inter()).
  void bottom(const float *dense, uint32_t m, Scratch *s, Mlp k = Mlp::avx512, Trace *tr = nullptr) const {
    if (k == Mlp::amx) need_amx();
    const float *in = dense;
    size_t ld = s_.dense_in;
    for (size_t l = 0; l < bottom_.size(); l++) {
      const bool last = l + 1 == bottom_.size();
      float *out = last ? s->x0.data() : (l % 2 ? s->b.data() : s->a.data());
      const size_t ldo = last ? s_.inter() : bottom_[l].out;
      if (k == Mlp::amx && bottom_[l].out % kPanel == 0) amx_gemm(abottom_[l], in, ld, m, out, ldo, true);
      else gemm(bottom_[l], in, ld, m, out, ldo, true);
      trace_push(tr, out, m, ldo, bottom_[l].out);
      in = out, ld = ldo;
    }
  }
  // x0 complete (dense_out + pooled embeddings) -> score[m] (sigmoid).
  void top(uint32_t m, Scratch *s, float *score, Mlp k = Mlp::avx512, Trace *tr = nullptr) const {
    if (k == Mlp::amx) need_amx();
    const uint32_t D = s_.inter();
    std::memcpy(s->xl.data(), s->x0.data(), size_t(m) * D * 4);
    for (uint32_t l = 0; l < s_.cross_layers; l++) {
      if (k == Mlp::amx) {
        amx_gemm(aV_[l], s->xl.data(), D, m, s->v.data(), s_.rank, false);
        amx_gemm(aW_[l], s->v.data(), s_.rank, m, s->w.data(), D, false);
      } else {
        gemm(V_[l], s->xl.data(), D, m, s->v.data(), s_.rank, false);
        gemm(W_[l], s->v.data(), s_.rank, m, s->w.data(), D, false);
      }
      for (size_t i = 0; i < size_t(m) * D; i++) s->xl[i] += s->x0[i] * s->w[i];
      trace_push(tr, s->v.data(), m, s_.rank, s_.rank), trace_push(tr, s->w.data(), m, D, D);
      trace_push(tr, s->xl.data(), m, D, D);
    }
    const float *in = s->xl.data();
    size_t ld = D;
    for (size_t l = 0; l + 1 < top_.size(); l++) {
      float *out = l % 2 ? s->b.data() : s->a.data();
      if (k == Mlp::amx && top_[l].out % kPanel == 0) amx_gemm(atop_[l], in, ld, m, out, top_[l].out, true);
      else gemm(top_[l], in, ld, m, out, top_[l].out, true);
      trace_push(tr, out, m, top_[l].out, top_[l].out);
      in = out, ld = top_[l].out;
    }
    gemm(top_.back(), in, ld, m, score, 1, false);
    trace_push(tr, score, m, 1, 1);
    for (uint32_t r = 0; r < m; r++) score[r] = 1.f / (1.f + std::exp(-score[r]));
  }

  // ---- v7: trained weights (tools/ckpt_convert.py dense.bin: torch layout, names of torchrec DLRM_DCN)
  bool load_dense(const std::string &path, std::string *err) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return *err = path + ": cannot open", false;
    char magic[8];
    uint32_t ver = 0, n = 0;
    if (std::fread(magic, 1, 8, f) != 8 || std::memcmp(magic, "RSYSDNS1", 8) || std::fread(&ver, 4, 1, f) != 1 ||
        std::fread(&n, 4, 1, f) != 1 || ver != 1)
      return std::fclose(f), *err = path + ": not a RSYSDNS1 v1 file", false;
    struct T { uint32_t ndim, d0, d1; std::vector<float> v; };
    std::vector<std::pair<std::string, T>> ts;
    for (uint32_t i = 0; i < n; i++) {
      char name[96];
      uint32_t hd[3];
      if (std::fread(name, 1, 96, f) != 96 || std::fread(hd, 4, 3, f) != 3)
        return std::fclose(f), *err = path + ": truncated", false;
      T t{hd[0], hd[1], hd[2], std::vector<float>(size_t(hd[1]) * hd[2])};
      if (std::fread(t.v.data(), 4, t.v.size(), f) != t.v.size())
        return std::fclose(f), *err = path + ": truncated data", false;
      ts.emplace_back(std::string(name, strnlen(name, 96)), std::move(t));
    }
    std::fclose(f);
    auto get = [&](const std::string &nm, uint32_t d0, uint32_t d1) -> const float * {
      for (auto &p : ts)
        if (p.first == nm) {
          if (p.second.d0 != d0 || p.second.d1 != d1) return nullptr;
          return p.second.v.data();
        }
      return nullptr;
    };
    s_ = ModelSpec{};
    bottom_.assign(3, {}), V_.assign(3, {}), W_.assign(3, {}), top_.assign(5, {});
    Vt_.assign(3, {}), Wt_.assign(3, {}), topt_.assign(4, {});
    const uint32_t bdims[4] = {s_.dense_in, s_.bottom[0], s_.bottom[1], s_.dim};
    for (int l = 0; l < 3; l++) {
      const std::string p = "model.dense_arch.model._mlp." + std::to_string(l) + "._linear.";
      const float *w = get(p + "weight", bdims[l + 1], bdims[l]), *b = get(p + "bias", bdims[l + 1], 1);
      if (!w || !b) return *err = "dense.bin: missing/shape " + p, false;
      bottom_[l].load_torch(w, b, bdims[l], bdims[l + 1]);
    }
    const uint32_t D = s_.inter(), R = s_.rank;
    for (int l = 0; l < 3; l++) {
      const std::string L = std::to_string(l);
      const float *v = get("model.inter_arch.crossnet.V_kernels." + L, R, D);
      const float *w = get("model.inter_arch.crossnet.W_kernels." + L, D, R);
      const float *b = get("model.inter_arch.crossnet.bias." + L, D, 1);
      if (!v || !w || !b) return *err = "dense.bin: missing/shape crossnet " + L, false;
      V_[l].load_torch(v, nullptr, D, R), W_[l].load_torch(w, b, R, D);
      Vt_[l].load_torch_transposed(v, D, R), Wt_[l].load_torch_transposed(w, R, D);
    }
    const uint32_t tdims[6] = {D, s_.top[0], s_.top[1], s_.top[2], s_.top[3], 1};
    for (int l = 0; l < 4; l++) {
      const std::string p = "model.over_arch.model.0._mlp." + std::to_string(l) + "._linear.";
      const float *w = get(p + "weight", tdims[l + 1], tdims[l]), *b = get(p + "bias", tdims[l + 1], 1);
      if (!w || !b) return *err = "dense.bin: missing/shape " + p, false;
      top_[l].load_torch(w, b, tdims[l], tdims[l + 1]);
      topt_[l].load_torch_transposed(w, tdims[l], tdims[l + 1]);
    }
    const float *w = get("model.over_arch.model.1.weight", 1, tdims[4]), *b = get("model.over_arch.model.1.bias", 1, 1);
    if (!w || !b) return *err = "dense.bin: missing over_arch.model.1", false;
    top_[4].load_torch(w, b, tdims[4], 1);
    return true;
  }

  // ---- v7: training activations and the backward pass of the frozen dense part (gradient w.r.t. x0 only;
  // the updater uses the embedding columns x0[:, dim:]). FLOPs ~ forward of cross + top (DESIGN.md §10.3).
  struct Train {
    uint32_t max_m = 0;
    std::vector<float> xs[4], us[3], h[4];  // x_0..x_3 (xs[0] = x0 copy), u_l = W_l V_l x_l + b_l, top outputs
    std::vector<float> v, g, gx, t, s, ga, gb;
  };
  void train_scratch(Train *t, uint32_t m) const {
    if (t->max_m >= m) return;
    t->max_m = m;
    const size_t D = s_.inter();
    for (auto &x : t->xs) x.assign(m * D, 0);
    for (auto &u : t->us) u.assign(m * D, 0);
    for (int l = 0; l < 4; l++) t->h[l].assign(size_t(m) * s_.top[l], 0);
    t->v.assign(size_t(m) * s_.rank, 0), t->s.assign(size_t(m) * s_.rank, 0);
    t->g.assign(m * D, 0), t->gx.assign(m * D, 0), t->t.assign(m * D, 0);
    t->ga.assign(m * std::max<size_t>(D, 1024), 0), t->gb.assign(m * std::max<size_t>(D, 1024), 0);
  }
  // Same result as top(); keeps the activations. logit[m] optional.
  void top_train(uint32_t m, const Scratch *s, Train *t, float *score, float *logit = nullptr) const {
    const size_t D = s_.inter();
    std::memcpy(t->xs[0].data(), s->x0.data(), m * D * 4);
    const float *x0 = t->xs[0].data();
    for (uint32_t l = 0; l < s_.cross_layers; l++) {
      gemm(V_[l], t->xs[l].data(), D, m, t->v.data(), s_.rank, false);
      gemm(W_[l], t->v.data(), s_.rank, m, t->us[l].data(), D, false);
      const float *xl = t->xs[l].data(), *u = t->us[l].data();
      float *xn = t->xs[l + 1].data();
      for (size_t i = 0; i < m * D; i++) xn[i] = x0[i] * u[i] + xl[i];
    }
    const float *in = t->xs[3].data();
    size_t ld = D;
    for (int l = 0; l < 4; l++) {
      gemm(top_[l], in, ld, m, t->h[l].data(), top_[l].out, true);
      in = t->h[l].data(), ld = top_[l].out;
    }
    float tmp[1024];
    float *z = logit ? logit : (m <= 1024 ? tmp : nullptr);
    std::vector<float> big;
    if (!z) big.resize(m), z = big.data();
    gemm(top_[4], in, ld, m, z, 1, false);
    for (uint32_t r = 0; r < m; r++) score[r] = 1.f / (1.f + std::exp(-z[r]));
  }
  // dz[m] = dLoss/dlogit (BCE: (p - y) * scale). Output gx0 = t->gx [m][inter] (dLoss/dx0).
  const float *backward(uint32_t m, Train *t, const float *dz) const {
    const size_t D = s_.inter();
    // top MLP: last linear (out = 1), then 4 ReLU layers
    const uint32_t n3 = s_.top[3];
    float *ga = t->ga.data(), *gb = t->gb.data();
    for (uint32_t r = 0; r < m; r++)
      for (uint32_t k = 0; k < n3; k++) {
        const float hv = t->h[3][size_t(r) * n3 + k];
        ga[size_t(r) * n3 + k] = hv > 0 ? top_[4].w[k] * dz[r] : 0.f;
      }
    for (int l = 3; l >= 0; l--) {
      const uint32_t o = top_[l].out, i = top_[l].in;
      float *gin = l ? gb : t->g.data();
      gemm(topt_[l], ga, o, m, gin, i, false);
      if (l) {
        const float *hp = t->h[l - 1].data();
        for (size_t q = 0; q < size_t(m) * i; q++)
          if (hp[q] <= 0) gin[q] = 0.f;
        std::swap(ga, gb);
      }
    }
    // cross: g = dL/dx_{l+1}; dL/dx_l = g + V^T W^T (g * x0); dL/dx0 += g * u_l
    float *g = t->g.data(), *gx = t->gx.data(), *tt = t->t.data();
    const float *x0 = t->xs[0].data();
    std::memset(gx, 0, m * D * 4);
    for (int l = int(s_.cross_layers) - 1; l >= 0; l--) {
      const float *u = t->us[l].data();
      for (size_t q = 0; q < m * D; q++) gx[q] += g[q] * u[q], tt[q] = g[q] * x0[q];
      gemm(Wt_[l], tt, D, m, t->s.data(), s_.rank, false);
      gemm(Vt_[l], t->s.data(), s_.rank, m, tt, D, false);
      for (size_t q = 0; q < m * D; q++) g[q] += tt[q];
    }
    for (size_t q = 0; q < m * D; q++) gx[q] += g[q];
    return gx;
  }
  uint64_t backward_flops_per_pair() const {
    uint64_t f = 0;
    for (int l = 0; l < 4; l++) f += topt_[l].flops_per_row();
    for (uint32_t l = 0; l < s_.cross_layers; l++) f += Vt_[l].flops_per_row() + Wt_[l].flops_per_row() + 4ull * s_.inter();
    return f;
  }
  // Raw access for tests (torch layout is not kept; the packed layout is).
  const std::vector<Linear> &bottom_layers() const { return bottom_; }

 private:
  void need_amx() const {
    if (!amx_ready()) {
      std::fprintf(stderr, "model: --mlp amx forward without prepare_amx()\n");
      std::abort();
    }
  }
  ModelSpec s_;
  std::vector<Linear> bottom_, V_, W_, top_;
  std::vector<AmxLinear> abottom_, aV_, aW_, atop_;  // --mlp amx: bf16 tile copies of the forward layers
  std::vector<Linear> Vt_, Wt_, topt_;  // v7 backward (transposes, no bias); empty for random-init models
};

}  // namespace rsys

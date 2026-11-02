// recsys v7 embedding records and the row-wise Adagrad update (DESIGN.md §10).
// Table image (tools/ckpt_convert.py): ImageHeader (4096 B) + one record per row, tables contiguous in table order.
// Record (whole cache lines): key u64 | seq u64 | csum u32 | acc f32 | pad 40 | emb[dim] (fp16: 320 B, fp32: 576 B).
// csum = row_csum over (key, seq, emb as u32 words) -- the same function the converter uses.
// Row-wise Adagrad = FBGEMM EXACT_ROWWISE_ADAGRAD (the MLPerf DLRMv2 reference optimizer for the embeddings):
//   acc += mean_j g_j^2;  w_j -= lr * g_j / (sqrt(acc) + eps)    (weight decay 0)
#pragma once

#include <immintrin.h>

#include <cmath>
#include <cstdint>
#include <cstring>

namespace rsys {

constexpr uint64_t kImageMagic = 0x31474d4953595352ull;  // "RSYSIMG1"
constexpr uint32_t kImageVersion = 1, kImageHeaderBytes = 4096, kRecHdr = 64;

struct __attribute__((packed)) ImageHeader {
  uint64_t magic;
  uint32_t version, record_bytes;
  uint64_t rows;
  uint32_t dim, elt_bytes;  // 2 = fp16, 4 = fp32
  uint64_t data_off;        // = kImageHeaderBytes
  uint64_t table_rows[26], row_base[26];
  uint8_t ckpt_metadata_sha256[32];
};

struct RecOff {
  static constexpr uint32_t key = 0, seq = 8, csum = 16, acc = 20, emb = kRecHdr;
};

inline uint32_t rec_bytes(uint32_t dim, uint32_t elt) { return (kRecHdr + dim * elt + 63) / 64 * 64; }

inline uint32_t row_csum_words(uint64_t key, uint64_t seq, const void *emb, uint32_t nwords) {
  uint32_t h = 0x811c9dc5u ^ uint32_t(key) ^ uint32_t(key >> 32) ^ uint32_t(seq) * 0x9e3779b1u;
  const uint8_t *p = static_cast<const uint8_t *>(emb);
  for (uint32_t j = 0; j < nwords; j++) {
    uint32_t w;
    std::memcpy(&w, p + 4 * j, 4);
    h = (h ^ w) * 0x01000193u;
  }
  return h | 1;
}

// emb (elt 2: fp16, 4: fp32) -> out[dim] fp32; add: out += emb
inline void emb_to_f32(const void *emb, uint32_t elt, uint32_t dim, float *out, bool add) {
  if (elt == 4) {
    const float *e = static_cast<const float *>(emb);
    if (add)
      for (uint32_t j = 0; j < dim; j++) out[j] += e[j];
    else
      std::memcpy(out, e, dim * 4);
    return;
  }
  const uint16_t *h = static_cast<const uint16_t *>(emb);
  uint32_t j = 0;
#ifdef __AVX512F__
  for (; j + 16 <= dim; j += 16) {
    __m512 v = _mm512_cvtph_ps(_mm256_loadu_si256(reinterpret_cast<const __m256i *>(h + j)));
    if (add) v = _mm512_add_ps(v, _mm512_loadu_ps(out + j));
    _mm512_storeu_ps(out + j, v);
  }
#endif
  for (; j < dim; j++) {
    const float v = _cvtsh_ss(h[j]);
    out[j] = add ? out[j] + v : v;
  }
}
inline void f32_to_emb(const float *in, uint32_t elt, uint32_t dim, void *emb) {
  if (elt == 4) return (void)std::memcpy(emb, in, dim * 4);
  uint16_t *h = static_cast<uint16_t *>(emb);
  uint32_t j = 0;
#ifdef __AVX512F__
  for (; j + 16 <= dim; j += 16)
    _mm256_storeu_si256(reinterpret_cast<__m256i *>(h + j),
                        _mm512_cvtps_ph(_mm512_loadu_ps(in + j), _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC));
#endif
  for (; j < dim; j++) h[j] = _cvtss_sh(in[j], _MM_FROUND_TO_NEAREST_INT);
}

struct AdagradCfg {
  float lr = 0.004f;  // MLPerf DLRMv2 training reference (DESIGN.md §10.4; user to confirm)
  float eps = 1e-8f;  // FBGEMM / reference default
};

// One row: w (fp32 copy of the row), acc (row state), g (summed gradient of this row in the batch).
inline void rowwise_adagrad(float *w, float *acc, const float *g, uint32_t dim, const AdagradCfg &c) {
  double s = 0;
  for (uint32_t j = 0; j < dim; j++) s += double(g[j]) * g[j];
  *acc += float(s / dim);
  const float mul = c.lr / (std::sqrt(*acc) + c.eps);
  for (uint32_t j = 0; j < dim; j++) w[j] -= mul * g[j];
}

}  // namespace rsys

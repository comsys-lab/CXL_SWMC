// AMX forward GEMM for the DLRMv2 dense part (server/model.h; DESIGN.md §6.2): `--mlp amx`.
//   Weights: bf16 (round to nearest even), pre-packed at load into AMX B tiles (VNNI pairs): per 16-column block and
//            32-k block one 16 x 64 B tile, [out/16][kpad/32][16 k pairs][16 cols][2]; kpad = in rounded up to 32
//            (zero rows).
//   Activations: converted to bf16 per layer ([m rounded up to 16][kpad], zero padding), fp32 accumulation in the
//            tiles (TDPBF16PS); bias and ReLU in fp32 on the stored C tiles, as in the fp32 path.
//   Blocking: 32 rows x 32 columns per step (4 C tiles tmm0-3, A tmm4-5, B tmm6-7); columns outer, rows inner, so
//            one 32-column weight panel (kpad x 64 B) stays in L2 across the row blocks.
// The tile instructions are emitted by inline asm (with memory clobbers; GCC 11's _tile_* macros have none), so the
// default build needs no -mamx-* flag and runs on CPUs without AMX; the tile code executes only after amx_enable()
// succeeded (Linux: arch_prctl(ARCH_REQ_XCOMP_PERM, XFEATURE_XTILEDATA), once per process, before any tile use).
// Every call of amx_gemm loads the tile configuration (LDTILECFG) on the calling thread.
#pragma once

#include <immintrin.h>
#include <sys/syscall.h>
#include <unistd.h>
#if defined(__x86_64__)
#include <cpuid.h>
#endif

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace rsys {

enum class Mlp : uint8_t { avx512 = 0, amx = 1 };
inline const char *mlp_name(Mlp k) { return k == Mlp::amx ? "amx" : "avx512"; }
inline bool parse_mlp(const std::string &s, Mlp *k) {
  if (s == "avx512") return *k = Mlp::avx512, true;
  if (s == "amx") return *k = Mlp::amx, true;
  return false;
}

inline std::atomic<bool> &amx_permitted_flag() {
  static std::atomic<bool> f{false};
  return f;
}

// CPUID AMX-TILE + AMX-BF16, OS support (OSXSAVE, XCR0 bits 17/18) and the Linux permission for XTILEDATA.
// Process-wide; call once before any thread uses tiles. false + *err on any refusal.
inline bool amx_enable(std::string *err) {
#if defined(__x86_64__) && defined(__AVX512F__) && defined(__AVX512BW__)
  if (amx_permitted_flag().load()) return true;
  unsigned a = 0, b = 0, c = 0, d = 0;
  if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) return *err = "AMX: CPUID leaf 7 not available", false;
  const bool tile = d & (1u << 24), bf16 = d & (1u << 22);
  if (!tile || !bf16)
    return *err = std::string("AMX: CPU does not report ") + (!tile ? "amx_tile " : "") + (!bf16 ? "amx_bf16" : "") +
                  " (CPUID.7.0:EDX bits 24/22; a VM needs the amx-tile/amx-bf16 CPU flags)",
           false;
  unsigned a1 = 0, b1 = 0, c1 = 0, d1 = 0;
  if (!__get_cpuid(1, &a1, &b1, &c1, &d1) || !(c1 & (1u << 27))) return *err = "AMX: OSXSAVE not enabled", false;
  uint32_t lo = 0, hi = 0;
  __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
  if ((lo & (3u << 17)) != (3u << 17))
    return *err = "AMX: XCR0 lacks XTILECFG/XTILEDATA (bits 17/18): the kernel did not enable AMX state "
                  "(x86-64 Linux >= 5.16; in a VM the hypervisor must expose the AMX xstate components)",
           false;
  constexpr long kArchGetXcompPerm = 0x1022, kArchReqXcompPerm = 0x1023, kXfeatureXtiledata = 18;
  if (syscall(SYS_arch_prctl, kArchReqXcompPerm, kXfeatureXtiledata) != 0)
    return *err = std::string("AMX: arch_prctl(ARCH_REQ_XCOMP_PERM, XFEATURE_XTILEDATA) refused: ") +
                  std::strerror(errno),
           false;
  unsigned long mask = 0;
  if (syscall(SYS_arch_prctl, kArchGetXcompPerm, &mask) != 0 || !(mask & (1ul << kXfeatureXtiledata)))
    return *err = "AMX: XTILEDATA permission not granted after ARCH_REQ_XCOMP_PERM", false;
  amx_permitted_flag().store(true);
  return true;
#else
  return *err = "AMX: this binary was built without x86-64 AVX-512F/BW", false;
#endif
}

inline uint16_t f32_to_bf16(float f) {  // round to nearest even (no NaN inputs)
  uint32_t u;
  std::memcpy(&u, &f, 4);
  u += 0x7fffu + ((u >> 16) & 1u);
  return uint16_t(u >> 16);
}
inline float bf16_to_f32(uint16_t h) {
  const uint32_t u = uint32_t(h) << 16;
  float f;
  std::memcpy(&f, &u, 4);
  return f;
}

struct AmxLinear {
  uint32_t in = 0, out = 0, kpad = 0;  // out % 32 == 0
  std::vector<uint16_t> wb;            // B tiles, see the header comment (512 bf16 = 1 KiB per tile)
  std::vector<float> b;                // bias [out] (empty: none)
  // From model.h Linear: w packed fp32 [out/32][in][32] (kPanel = 32), bias [out] or empty.
  void pack(uint32_t i, uint32_t o, const std::vector<float> &w32, const std::vector<float> &bias) {
    in = i, out = o, kpad = (i + 31) / 32 * 32;
    b = bias;
    const uint32_t KB = kpad / 32;
    wb.assign(size_t(o / 16) * KB * 512, 0);
    for (uint32_t nb = 0; nb < o / 16; nb++)
      for (uint32_t kb = 0; kb < KB; kb++) {
        uint16_t *t = &wb[(size_t(nb) * KB + kb) * 512];
        for (uint32_t kk = 0; kk < 16; kk++)
          for (uint32_t n = 0; n < 16; n++)
            for (uint32_t j = 0; j < 2; j++) {
              const uint32_t k = kb * 32 + 2 * kk + j, c = nb * 16 + n;
              t[(kk * 16 + n) * 2 + j] = k < i ? f32_to_bf16(w32[(size_t(c / 32) * i + k) * 32 + c % 32]) : 0;
            }
      }
  }
};

#if defined(__x86_64__) && defined(__AVX512F__) && defined(__AVX512BW__)
#define RS_TILE_LOAD(t, base, stride) \
  __asm__ volatile("tileloadd (%0,%1,1), %%tmm" #t ::"r"((const void *)(base)), "r"((long)(stride)) : "memory")
#define RS_TILE_STORE(t, base, stride) \
  __asm__ volatile("tilestored %%tmm" #t ", (%0,%1,1)" ::"r"((void *)(base)), "r"((long)(stride)) : "memory")
#define RS_TILE_ZERO(t) __asm__ volatile("tilezero %%tmm" #t ::)
#define RS_TDPBF16PS(d, a, b) __asm__ volatile("tdpbf16ps %%tmm" #b ", %%tmm" #a ", %%tmm" #d ::)

struct alignas(64) AmxTileCfg {
  uint8_t palette = 1, start_row = 0, reserved[14] = {0};
  uint16_t colsb[16] = {0};
  uint8_t rows[16] = {0};
};

inline void amx_tile_config() {  // 8 tiles of 16 rows x 64 B (A: 16 x 32 bf16, B: 16 pairs x 16 cols, C: 16 x 16 fp32)
  AmxTileCfg c;
  for (int t = 0; t < 8; t++) c.colsb[t] = 64, c.rows[t] = 16;
  __asm__ volatile("ldtilecfg %0" ::"m"(c) : "memory");
}

// fp32 row [n] -> bf16 [kpad] (zero beyond n), round to nearest even, AVX-512F/BW.
inline void amx_row_to_bf16(const float *x, uint32_t n, uint32_t kpad, uint16_t *y) {
  const __m512i one = _mm512_set1_epi32(1), bias = _mm512_set1_epi32(0x7fff);
  for (uint32_t c = 0; c < kpad; c += 16) {
    const __mmask16 mk = c + 16 <= n ? __mmask16(0xffff) : c >= n ? __mmask16(0) : __mmask16((1u << (n - c)) - 1);
    const __m512i u = _mm512_castps_si512(_mm512_maskz_loadu_ps(mk, x + c));
    const __m512i r = _mm512_srli_epi32(_mm512_add_epi32(u, _mm512_add_epi32(bias, _mm512_and_si512(_mm512_srli_epi32(u, 16), one))), 16);
    _mm256_storeu_si256(reinterpret_cast<__m256i *>(y + c), _mm512_cvtepi32_epi16(r));
  }
}

// Y[m][out] (ldy) = bf16(X[m][in] (ldx)) * bf16(W) + b (fp32 accumulate), optional ReLU. Same contract as gemm().
inline void amx_gemm(const AmxLinear &L, const float *X, size_t ldx, uint32_t m, float *Y, size_t ldy, bool relu) {
  if (!amx_permitted_flag().load(std::memory_order_relaxed)) {
    std::fprintf(stderr, "amx_gemm: AMX not enabled (amx_enable() not called or refused)\n");
    std::abort();
  }
  if (!m) return;
  thread_local std::vector<uint16_t> xb;
  alignas(64) float ct[4][256];
  const uint32_t Mp = (m + 15) / 16 * 16, kpad = L.kpad, KB = kpad / 32;
  if (xb.size() < size_t(Mp) * kpad) xb.resize(size_t(Mp) * kpad);
  for (uint32_t r = 0; r < m; r++) amx_row_to_bf16(X + r * ldx, L.in, kpad, &xb[size_t(r) * kpad]);
  if (Mp > m) std::memset(&xb[size_t(m) * kpad], 0, size_t(Mp - m) * kpad * 2);
  amx_tile_config();
  const long lda = long(kpad) * 2;
  const __m512 zero = _mm512_setzero_ps();
  for (uint32_t nb = 0; nb < L.out / 16; nb += 2) {
    const uint16_t *b0 = &L.wb[size_t(nb) * KB * 512], *b1 = b0 + size_t(KB) * 512;
    const __m512 bias0 = L.b.empty() ? zero : _mm512_loadu_ps(&L.b[nb * 16]);
    const __m512 bias1 = L.b.empty() ? zero : _mm512_loadu_ps(&L.b[nb * 16 + 16]);
    for (uint32_t mb = 0; mb < Mp; mb += 32) {
      const uint16_t *a0 = &xb[size_t(mb) * kpad];
      const bool two = mb + 16 < Mp;
      RS_TILE_ZERO(0);
      RS_TILE_ZERO(1);
      if (two) {
        const uint16_t *a1 = a0 + size_t(16) * kpad;
        RS_TILE_ZERO(2);
        RS_TILE_ZERO(3);
        for (uint32_t kb = 0; kb < KB; kb++) {
          RS_TILE_LOAD(4, a0 + kb * 32, lda);
          RS_TILE_LOAD(6, b0 + size_t(kb) * 512, 64);
          RS_TILE_LOAD(7, b1 + size_t(kb) * 512, 64);
          RS_TDPBF16PS(0, 4, 6);
          RS_TDPBF16PS(1, 4, 7);
          RS_TILE_LOAD(5, a1 + kb * 32, lda);
          RS_TDPBF16PS(2, 5, 6);
          RS_TDPBF16PS(3, 5, 7);
        }
        RS_TILE_STORE(2, ct[2], 64);
        RS_TILE_STORE(3, ct[3], 64);
      } else {
        for (uint32_t kb = 0; kb < KB; kb++) {
          RS_TILE_LOAD(4, a0 + kb * 32, lda);
          RS_TILE_LOAD(6, b0 + size_t(kb) * 512, 64);
          RS_TILE_LOAD(7, b1 + size_t(kb) * 512, 64);
          RS_TDPBF16PS(0, 4, 6);
          RS_TDPBF16PS(1, 4, 7);
        }
      }
      RS_TILE_STORE(0, ct[0], 64);
      RS_TILE_STORE(1, ct[1], 64);
      const uint32_t rend = std::min<uint32_t>(m, mb + 32);
      for (uint32_t r = mb; r < rend; r++) {
        const uint32_t t = (r - mb) / 16 * 2, row = (r - mb) % 16;
        __m512 y0 = _mm512_add_ps(_mm512_load_ps(&ct[t][row * 16]), bias0);
        __m512 y1 = _mm512_add_ps(_mm512_load_ps(&ct[t + 1][row * 16]), bias1);
        if (relu) y0 = _mm512_max_ps(y0, zero), y1 = _mm512_max_ps(y1, zero);
        _mm512_storeu_ps(Y + r * ldy + nb * 16, y0);
        _mm512_storeu_ps(Y + r * ldy + nb * 16 + 16, y1);
      }
    }
  }
}
#undef RS_TILE_LOAD
#undef RS_TILE_STORE
#undef RS_TILE_ZERO
#undef RS_TDPBF16PS
#else
inline void amx_gemm(const AmxLinear &, const float *, size_t, uint32_t, float *, size_t, bool) {
  std::fprintf(stderr, "amx_gemm: built without AVX-512F/BW (no AMX path)\n");
  std::abort();
}
#endif

}  // namespace rsys

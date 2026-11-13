// Host unit test for server/emb_v7.h f32_to_fp16_sr (stochastic rounding to fp16): for values w + d with |d| below
// half an fp16 ulp, round-to-nearest returns w (the update is lost) while the mean of stochastic rounding over many
// draws equals w + d within sampling error; exactly representable values are returned unchanged.
#include <cmath>
#include <cstdio>
#include <vector>

#include "../server/emb_v7.h"

using namespace rsys;

int main() {
  int fails = 0;
  uint64_t rng = 0x243f6a8885a308d3ull;
  const float base[] = {0.1f, -0.1f, 0.003f, -0.4f, 0.65f};
  for (float w0 : base) {
    uint16_t h;
    f32_to_emb(&w0, 2, 1, &h);
    const float w = _cvtsh_ss(h);  // fp16-representable start value
    const float ulp = std::ldexp(1.f, std::ilogb(w) - 10);
    for (float frac : {0.03f, -0.2f, 0.4f}) {
      const float x = w + frac * ulp;
      uint16_t rn;
      f32_to_emb(&x, 2, 1, &rn);
      const int N = 1 << 20;
      std::vector<float> in(128, x);
      std::vector<uint16_t> out(128);
      double sum = 0;
      for (int i = 0; i < N / 128; i++) {
        f32_to_fp16_sr(in.data(), 128, out.data(), &rng);
        for (uint16_t o : out) sum += _cvtsh_ss(o);
      }
      const double mean = sum / N, err = (mean - x) / ulp, tol = 4.0 / std::sqrt(double(N));  // in ulps
      const bool ok = std::fabs(err) < tol && _cvtsh_ss(rn) == w;
      if (!ok) fails++;
      std::printf("%s w=%.6f d=%+.2f ulp: rn=%.6f sr_mean-x=%+.4f ulp (tol %.4f)\n", ok ? "ok  " : "FAIL", w, frac,
                  _cvtsh_ss(rn), err, tol);
    }
    uint16_t o;
    f32_to_fp16_sr(&w, 1, &o, &rng);
    if (_cvtsh_ss(o) != w) fails++, std::printf("FAIL representable %.6f changed\n", w);
  }
  std::printf("%s\n", fails ? "FP16 SR TEST FAIL" : "FP16 SR TEST PASS");
  return fails != 0;
}

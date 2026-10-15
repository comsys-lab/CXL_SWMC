// Host unit test + microbenchmark for the DLRMv2 dense part (server/model.h): packed AVX-512 GEMM vs a naive
// reference, then forward throughput per thread. No shared memory.
// usage: recsys-model-test [pairs (256)] [threads (1)] [seconds (3)]
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <thread>
#include <vector>

#include "../server/model.h"

using namespace rsys;

static bool check_gemm(uint32_t m, uint32_t in, uint32_t out, bool relu) {
  std::mt19937 g(m * 131 + in * 7 + out);
  std::uniform_real_distribution<float> U(-1, 1);
  std::vector<float> dense(size_t(in) * out), X(size_t(m) * in), Y(size_t(m) * out), Z(size_t(m) * out);
  for (auto &v : dense) v = U(g);
  for (auto &v : X) v = U(g);
  Linear L;
  L.in = in, L.out = out;
  L.w.assign(dense.size(), 0);
  L.b.assign(out, 0);
  for (auto &v : L.b) v = U(g);
  L.pack(dense.data());
  gemm(L, X.data(), in, m, Y.data(), out, relu);
  double maxerr = 0;
  for (uint32_t r = 0; r < m; r++)
    for (uint32_t c = 0; c < out; c++) {
      double s = L.b[c];
      for (uint32_t k = 0; k < in; k++) s += double(X[size_t(r) * in + k]) * dense[size_t(k) * out + c];
      if (relu && s < 0) s = 0;
      maxerr = std::max(maxerr, std::fabs(s - Y[size_t(r) * out + c]) / (1 + std::fabs(s)));
    }
  const bool ok = maxerr < 1e-4;
  std::printf("gemm m=%u in=%u out=%u relu=%d max_rel_err=%.2e %s\n", m, in, out, relu, maxerr, ok ? "OK" : "FAIL");
  return ok;
}

int main(int argc, char **argv) {
  const uint32_t pairs = argc > 1 ? std::atoi(argv[1]) : 256, threads = argc > 2 ? std::atoi(argv[2]) : 1;
  const double secs = argc > 3 ? std::atof(argv[3]) : 3;
  bool ok = true;
  for (uint32_t m : {1u, 3u, 8u, 13u, 64u}) ok &= check_gemm(m, 13, 512, true), ok &= check_gemm(m, 200, 64, false);
  ok &= check_gemm(17, 3456, 32, false);
#ifdef __AVX512F__
  std::printf("avx512: yes\n");
#else
  std::printf("avx512: no (scalar fallback)\n");
#endif
  Model M;
  M.init(ModelSpec{}, 1);
  std::printf("model: %.2f MFLOP/pair, weights %.1f MiB\n", M.flops_per_pair() / 1e6, M.weight_bytes() / 1048576.0);
  // determinism: same input -> same scores
  {
    Model::Scratch s;
    M.scratch(&s, 4);
    std::vector<float> dense(4 * 13, 0.5f), sc1(4), sc2(4);
    M.bottom(dense.data(), 4, &s);
    for (size_t i = 0; i < 4; i++)
      for (uint32_t j = 128; j < M.spec().inter(); j++) s.x0[i * M.spec().inter() + j] = 0.01f * float(j % 7);
    auto x0 = s.x0;
    M.top(4, &s, sc1.data());
    s.x0 = x0;
    M.top(4, &s, sc2.data());
    const bool same = sc1 == sc2 && sc1[0] > 0 && sc1[0] < 1;
    std::printf("forward determinism %s (score %.6f)\n", same ? "OK" : "FAIL", sc1[0]);
    ok &= same;
  }
  std::atomic<uint64_t> total{0};
  std::vector<std::thread> t;
  for (uint32_t i = 0; i < threads; i++)
    t.emplace_back([&] {
      Model::Scratch s;
      M.scratch(&s, pairs);
      std::vector<float> dense(size_t(pairs) * 13, 0.3f), score(pairs);
      uint64_t n = 0;
      auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(secs);
      while (std::chrono::steady_clock::now() < end) {
        M.bottom(dense.data(), pairs, &s);
        M.top(pairs, &s, score.data());
        n += pairs;
      }
      total += n;
    });
  for (auto &x : t) x.join();
  const double pps = total / secs;
  std::printf("forward: chunk=%u threads=%u %.0f pairs/s (%.1f GFLOP/s total, %.1f per thread)\n", pairs, threads, pps,
              pps * M.flops_per_pair() / 1e9, pps * M.flops_per_pair() / 1e9 / threads);
  std::printf("%s\n", ok ? "MODEL TEST PASS" : "MODEL TEST FAIL");
  return ok ? 0 : 1;
}

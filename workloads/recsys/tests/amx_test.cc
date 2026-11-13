// Host unit test + micro-benchmark of the AMX serving forward (server/amx.h, model.h `Mlp::amx`) against the fp32
// AVX-512 path. No shared memory.
//   1. amx_gemm vs a double reference on the bf16-rounded operands (kernel / packing exactness, rel err < 1e-4),
//      and vs the fp32 gemm (bf16 effect), several shapes incl. row / k tails.
//   2. whole model, random weights (seed 1) and, with --dense, the trained weights: per layer (propagated through the
//      network) max abs error, max |ref|, rel = max abs / max |ref|, rms rel = rms(err) / rms(ref); logit max abs and
//      score max abs. Inputs: --samples gives real dense features (first rows), else U(0, 4); the embedding part of x0
//      is U(-0.2, 0.2) (synthetic; the AUC run with recsys-score --mlp covers real pooled embeddings).
//   3. throughput: bottom + top MLP per chunk size (default the 2-way serving chunks max(100, ceil(P/2)) for
//      P = 100..700: 100 150 200 250 300 350) x threads (1 4) x {avx512, amx}; pairs/s and GFLOP/s.
// usage: recsys-amx-test [--dense F] [--samples F] [--rows M (350)] [--secs S (2)] [--sizes a,b,..] [--threads a,b]
//                        [--no-bench]
#include <fcntl.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <sstream>
#include <thread>
#include <vector>

#include "../samples.h"
#include "../server/model.h"

using namespace rsys;

static std::vector<uint32_t> parse_list(const std::string &s) {
  std::vector<uint32_t> v;
  std::stringstream ss(s);
  std::string x;
  while (std::getline(ss, x, ',')) v.push_back(std::stoul(x));
  return v;
}

struct Err {
  double max_abs = 0, max_ref = 0, se = 0, sr = 0;
  void add(double ref, double got) {
    const double d = std::fabs(got - ref);
    max_abs = std::max(max_abs, d), max_ref = std::max(max_ref, std::fabs(ref)), se += d * d, sr += ref * ref;
  }
  double rel() const { return max_ref > 0 ? max_abs / max_ref : 0; }
  double rms_rel() const { return sr > 0 ? std::sqrt(se / sr) : 0; }
};

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
  AmxLinear A;
  A.pack(in, out, L.w, L.b);
  gemm(L, X.data(), in, m, Y.data(), out, relu);
  amx_gemm(A, X.data(), in, m, Z.data(), out, relu);
  double kerr = 0;
  Err vs32;
  for (uint32_t r = 0; r < m; r++)
    for (uint32_t c = 0; c < out; c++) {
      double s = L.b[c];
      for (uint32_t k = 0; k < in; k++)
        s += double(bf16_to_f32(f32_to_bf16(X[size_t(r) * in + k]))) * bf16_to_f32(f32_to_bf16(dense[size_t(k) * out + c]));
      if (relu && s < 0) s = 0;
      kerr = std::max(kerr, std::fabs(s - Z[size_t(r) * out + c]) / (1 + std::fabs(s)));
      vs32.add(Y[size_t(r) * out + c], Z[size_t(r) * out + c]);
    }
  const bool ok = kerr < 1e-4;
  std::printf("amx_gemm m=%u in=%u out=%u relu=%d kernel_rel_err(bf16 operands)=%.2e vs_fp32: max_abs=%.3e rel=%.3e "
              "rms_rel=%.3e %s\n",
              m, in, out, relu, kerr, vs32.max_abs, vs32.rel(), vs32.rms_rel(), ok ? "OK" : "FAIL");
  return ok;
}

static const char *kLayerNames[] = {"bottom0", "bottom1", "bottom2", "cross0.V", "cross0.u", "cross0.x", "cross1.V",
                                    "cross1.u", "cross1.x", "cross2.V", "cross2.u", "cross2.x", "top0", "top1",
                                    "top2", "top3", "logit"};

static bool compare_model(const char *tag, const Model &M, const std::vector<float> &dense, uint32_t m) {
  const uint32_t D = M.spec().inter(), dim = M.spec().dim;
  std::mt19937 g(7);
  std::uniform_real_distribution<float> U(-0.2f, 0.2f);
  std::vector<float> emb(size_t(m) * (D - dim));
  for (auto &v : emb) v = U(g);
  Model::Trace t32, tam;
  std::vector<float> s32(m), sam(m);
  for (int pass = 0; pass < 2; pass++) {
    const Mlp k = pass ? Mlp::amx : Mlp::avx512;
    Model::Trace *tr = pass ? &tam : &t32;
    Model::Scratch sc;
    M.scratch(&sc, m);
    M.bottom(dense.data(), m, &sc, k, tr);
    for (uint32_t r = 0; r < m; r++) std::memcpy(&sc.x0[size_t(r) * D + dim], &emb[size_t(r) * (D - dim)], (D - dim) * 4);
    M.top(m, &sc, pass ? sam.data() : s32.data(), k, tr);
  }
  bool ok = t32.size() == 17 && tam.size() == 17;
  for (size_t l = 0; ok && l < t32.size(); l++) {
    Err e;
    for (size_t i = 0; i < t32[l].size(); i++) e.add(t32[l][i], tam[l][i]);
    std::printf("%s layer %-9s max_abs=%.3e max_ref=%.3e rel=%.3e rms_rel=%.3e\n", tag, kLayerNames[l], e.max_abs,
                e.max_ref, e.rel(), e.rms_rel());
    if (l == 16) ok &= e.rms_rel() < 5e-2;  // sanity: a packing / layout bug gives O(1)
  }
  Err es;
  double max_logit_relative = 0;
  for (uint32_t r = 0; r < m; r++) {
    es.add(s32[r], sam[r]);
    max_logit_relative = std::max(max_logit_relative, std::fabs(double(tam[16][r]) - t32[16][r]) / (1e-3 + std::fabs(t32[16][r])));
  }
  std::printf("%s final: rows=%u score max_abs=%.3e logit max_abs/(1e-3+|logit|)=%.3e %s\n", tag, m, es.max_abs,
              max_logit_relative, ok ? "OK" : "FAIL");
  return ok;
}

static void bench(const Model &M, uint32_t pairs, uint32_t threads, double secs, Mlp k) {
  std::atomic<uint64_t> total{0};
  std::atomic<uint32_t> ready{0};
  std::vector<std::thread> t;
  for (uint32_t i = 0; i < threads; i++)
    t.emplace_back([&] {
      Model::Scratch s;
      M.scratch(&s, pairs);
      std::vector<float> dense(size_t(pairs) * 13, 0.3f), score(pairs);
      for (size_t q = 0; q < s.x0.size(); q++) s.x0[q] = 0.01f * float(q % 13);
      M.bottom(dense.data(), pairs, &s, k);  // warm-up (weights, tile config, scratch)
      M.top(pairs, &s, score.data(), k);
      ready++;
      while (ready.load() < threads) {
      }
      uint64_t n = 0;
      const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(secs);
      while (std::chrono::steady_clock::now() < end) {
        M.bottom(dense.data(), pairs, &s, k);
        M.top(pairs, &s, score.data(), k);
        n += pairs;
      }
      total += n;
    });
  for (auto &x : t) x.join();
  const double pps = total / secs;
  std::printf("bench mlp=%s chunk=%u threads=%u pairs_per_s=%.0f gflops_total=%.1f gflops_per_thread=%.1f "
              "ms_per_chunk=%.3f\n",
              mlp_name(k), pairs, threads, pps, pps * M.flops_per_pair() / 1e9, pps * M.flops_per_pair() / 1e9 / threads,
              1e3 * pairs * threads / pps);
}

int main(int argc, char **argv) {
  std::string dense_path, samples_path;
  uint32_t rows = 350;
  double secs = 2;
  bool do_bench = true;
  std::vector<uint32_t> sizes{100, 150, 200, 250, 300, 350}, threads{1, 4};
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) std::fprintf(stderr, "missing value for %s\n", a.c_str()), std::exit(2);
      return argv[++i];
    };
    if (a == "--dense") dense_path = v();
    else if (a == "--samples") samples_path = v();
    else if (a == "--rows") rows = std::stoul(v());
    else if (a == "--secs") secs = std::stod(v());
    else if (a == "--sizes") sizes = parse_list(v());
    else if (a == "--threads") threads = parse_list(v());
    else if (a == "--no-bench") do_bench = false;
    else std::fprintf(stderr, "unknown option %s\n", a.c_str()), std::exit(2);
  }
  std::string err;
  if (!amx_enable(&err)) {
    std::fprintf(stderr, "recsys-amx-test: %s\n", err.c_str());
    return 1;
  }
  bool ok = true;
  for (uint32_t m : {1u, 3u, 16u, 17u, 33u, 100u}) ok &= check_gemm(m, 13, 512, true), ok &= check_gemm(m, 200, 64, false);
  ok &= check_gemm(17, 3456, 32, false);
  ok &= check_gemm(100, 3456, 512, false);
  ok &= check_gemm(37, 512, 3456, false);
  // inputs
  std::vector<float> dense(size_t(rows) * 13);
  if (!samples_path.empty()) {
    int fd = ::open(samples_path.c_str(), O_RDONLY);
    SamplesHeader h{};
    if (fd < 0 || pread(fd, &h, sizeof h, 0) != ssize_t(sizeof h) || h.magic != kSamplesMagic || h.count < rows)
      return std::fprintf(stderr, "%s: bad samples file\n", samples_path.c_str()), 1;
    std::vector<Sample> s(rows);
    if (pread(fd, s.data(), rows * sizeof(Sample), sizeof h) != ssize_t(rows * sizeof(Sample)))
      return std::fprintf(stderr, "samples: short read\n"), 1;
    for (uint32_t r = 0; r < rows; r++) std::memcpy(&dense[size_t(r) * 13], s[r].dense, 52);
    close(fd);
  } else {
    std::mt19937 g(3);
    std::uniform_real_distribution<float> U(0, 4);
    for (auto &v : dense) v = U(g);
  }
  Model R;
  R.init(ModelSpec{}, 1);
  R.prepare_amx();
  ok &= compare_model("random", R, dense, rows);
  Model T;
  const Model *B = &R;
  if (!dense_path.empty()) {
    if (!T.load_dense(dense_path, &err)) return std::fprintf(stderr, "%s\n", err.c_str()), 1;
    T.prepare_amx();
    ok &= compare_model("trained", T, dense, rows);
    B = &T;
  }
  std::printf("model: %.2f MFLOP/pair, weights fp32 %.1f MiB, amx bf16 copy %.1f MiB\n", B->flops_per_pair() / 1e6,
              B->weight_bytes() / 1048576.0, B->amx_weight_bytes() / 1048576.0);
  if (do_bench)
    for (uint32_t th : threads)
      for (uint32_t m : sizes)
        for (Mlp k : {Mlp::avx512, Mlp::amx}) bench(*B, m, th, secs, k);
  std::printf("%s\n", ok ? "AMX TEST PASS" : "AMX TEST FAIL");
  return ok ? 0 : 1;
}

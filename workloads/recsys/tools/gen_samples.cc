// Synthetic sample trace for bring-up and Host tests (NOT Criteo; DESIGN.md §3 options). Raw one-hot ids per table
// over the MLPerf (uncapped) row counts; the server applies its row cap and the multi-hot expansion.
// usage: recsys-gen-samples --out FILE --n N [--seed S] [--dist uniform|zipf] [--alpha A (1.05)]
//   zipf: rank drawn from a bounded power law with exponent alpha, then scattered over the id space by a hash
//   (hot ids are not low numbers, as in Criteo's hashed ids). dense: log(1 + Exp(mean 2)) per feature.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "../samples.h"
#include "../server/layout.h"

using namespace rsys;

int main(int argc, char **argv) {
  std::string out, dist = "zipf";
  uint64_t n = 0, seed = 20261016;
  double alpha = 1.05;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&] { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--out") out = v();
    else if (a == "--n") n = std::stoull(v());
    else if (a == "--seed") seed = std::stoull(v());
    else if (a == "--dist") dist = v();
    else if (a == "--alpha") alpha = std::stod(v());
    else { std::fprintf(stderr, "unknown %s\n", a.c_str()); return 2; }
  }
  if (out.empty() || n == 0 || (dist != "zipf" && dist != "uniform")) {
    std::fprintf(stderr, "usage: recsys-gen-samples --out FILE --n N [--seed S] [--dist uniform|zipf] [--alpha A]\n");
    return 2;
  }
  FILE *f = std::fopen(out.c_str(), "wb");
  if (!f) return std::perror(out.c_str()), 1;
  SamplesHeader h{};
  h.magic = kSamplesMagic, h.version = 1, h.record_bytes = sizeof(Sample), h.count = n, h.seed = seed;
  std::snprintf(h.source, sizeof(h.source), "synthetic %s alpha=%.3f (not Criteo)", dist.c_str(), dist == "zipf" ? alpha : 0.0);
  std::fwrite(&h, sizeof(h), 1, f);
  std::mt19937_64 rng(seed);
  std::uniform_real_distribution<double> U(0.0, 1.0);
  const auto &R = mlperf_rows();
  std::vector<Sample> buf(65536);
  for (uint64_t done = 0; done < n;) {
    const uint64_t m = std::min<uint64_t>(buf.size(), n - done);
    for (uint64_t i = 0; i < m; i++) {
      Sample &s = buf[i];
      for (uint32_t d = 0; d < kDense; d++) s.dense[d] = float(std::log1p(-2.0 * std::log(1.0 - U(rng))));
      for (uint32_t k = 0; k < kSparse; k++) {
        const double N = double(R[k]);
        uint64_t rank;
        if (dist == "uniform") rank = uint64_t(U(rng) * N);
        else if (std::fabs(alpha - 1.0) < 1e-9) rank = uint64_t(std::pow(N, U(rng))) - 1;
        else rank = uint64_t(std::pow((std::pow(N, 1 - alpha) - 1) * U(rng) + 1, 1 / (1 - alpha))) - 1;
        if (rank >= R[k]) rank = R[k] - 1;
        s.sparse[k] = uint32_t(dist == "uniform" ? rank : mix64(rank * 0x9e3779b97f4a7c15ull ^ (uint64_t(k) << 52) ^ seed) % R[k]);
      }
    }
    std::fwrite(buf.data(), sizeof(Sample), m, f);
    done += m;
  }
  std::fclose(f);
  std::printf("wrote %lu samples to %s (%s)\n", (unsigned long)n, out.c_str(), h.source);
  return 0;
}

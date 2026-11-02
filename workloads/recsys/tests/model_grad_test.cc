// Host unit test for the v7 dense part (server/model.h load_dense, top_train, backward): random torch-layout weights
// written as a dense.bin, then
//   1. fp32 top_train logit vs a double-precision reference forward (naive loops over the torch layout),
//   2. backward (dlogit/dx0, dz = 1) vs central finite differences of the double reference at random coordinates,
//   3. Adagrad step (emb_v7.h) against its formula; fp16 round trip.
// usage: recsys-model-grad-test <scratch dense.bin path (created/overwritten)>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "../server/emb_v7.h"
#include "../server/model.h"

using namespace rsys;

struct Ref {  // torch layout
  std::vector<std::vector<double>> V, W, cb, tw, tb;
  uint32_t D = 3456, R = 512;
  std::vector<uint32_t> td{3456, 1024, 1024, 512, 256, 1};
  double logit(const std::vector<double> &x0) const {
    std::vector<double> x = x0, v(R), u(D);
    for (int l = 0; l < 3; l++) {
      for (uint32_t r = 0; r < R; r++) {
        double s = 0;
        for (uint32_t d = 0; d < D; d++) s += V[l][size_t(r) * D + d] * x[d];
        v[r] = s;
      }
      for (uint32_t d = 0; d < D; d++) {
        double s = cb[l][d];
        for (uint32_t r = 0; r < R; r++) s += W[l][size_t(d) * R + r] * v[r];
        u[d] = s;
      }
      for (uint32_t d = 0; d < D; d++) x[d] = x0[d] * u[d] + x[d];
    }
    for (int l = 0; l < 5; l++) {
      std::vector<double> y(td[l + 1]);
      for (uint32_t o = 0; o < td[l + 1]; o++) {
        double s = tb[l][o];
        for (uint32_t i = 0; i < td[l]; i++) s += tw[l][size_t(o) * td[l] + i] * x[i];
        y[o] = (l < 4 && s < 0) ? 0 : s;
      }
      x.swap(y);
    }
    return x[0];
  }
};

int main(int argc, char **argv) {
  if (argc < 2) return std::fprintf(stderr, "usage: %s <dense.bin path>\n", argv[0]), 2;
  std::mt19937_64 g(7);
  std::normal_distribution<float> N(0, 1);
  struct T { std::string name; uint32_t d0, d1; std::vector<float> v; };
  std::vector<T> ts;
  auto add = [&](const std::string &n, uint32_t o, uint32_t i, float scale) {
    T t{n, o, i, std::vector<float>(size_t(o) * i)};
    for (auto &x : t.v) x = N(g) * scale;
    ts.push_back(t);
    return &ts.back().v;
  };
  const uint32_t bd[4] = {13, 512, 256, 128}, td[6] = {3456, 1024, 1024, 512, 256, 1};
  for (int l = 0; l < 3; l++) {
    add("model.dense_arch.model._mlp." + std::to_string(l) + "._linear.weight", bd[l + 1], bd[l], 1.f / std::sqrt(bd[l]));
    add("model.dense_arch.model._mlp." + std::to_string(l) + "._linear.bias", bd[l + 1], 1, 0.1f);
  }
  for (int l = 0; l < 3; l++) {  // small cross weights keep x_l bounded
    add("model.inter_arch.crossnet.V_kernels." + std::to_string(l), 512, 3456, 1.f / std::sqrt(3456.f));
    add("model.inter_arch.crossnet.W_kernels." + std::to_string(l), 3456, 512, 0.3f / std::sqrt(512.f));
    add("model.inter_arch.crossnet.bias." + std::to_string(l), 3456, 1, 0.1f);
  }
  for (int l = 0; l < 4; l++) {
    add("model.over_arch.model.0._mlp." + std::to_string(l) + "._linear.weight", td[l + 1], td[l], 1.4f / std::sqrt(td[l]));
    add("model.over_arch.model.0._mlp." + std::to_string(l) + "._linear.bias", td[l + 1], 1, 0.05f);
  }
  add("model.over_arch.model.1.weight", 1, 256, 1.f / 16);
  add("model.over_arch.model.1.bias", 1, 1, 0.1f);
  {
    FILE *f = std::fopen(argv[1], "wb");
    if (!f) return std::perror(argv[1]), 2;
    uint32_t hdr[2] = {1, uint32_t(ts.size())};
    std::fwrite("RSYSDNS1", 1, 8, f), std::fwrite(hdr, 4, 2, f);
    for (auto &t : ts) {
      char name[96] = {0};
      std::strncpy(name, t.name.c_str(), 95);
      uint32_t h[3] = {t.d1 == 1 && t.name.find("bias") != std::string::npos ? 1u : 2u, t.d0, t.d1};
      std::fwrite(name, 1, 96, f), std::fwrite(h, 4, 3, f), std::fwrite(t.v.data(), 4, t.v.size(), f);
    }
    std::fclose(f);
  }
  Model M;
  std::string err;
  if (!M.load_dense(argv[1], &err)) return std::fprintf(stderr, "load: %s\n", err.c_str()), 1;
  auto find = [&](const std::string &n) -> const std::vector<float> & {
    for (auto &t : ts)
      if (t.name == n) return t.v;
    std::fprintf(stderr, "missing %s\n", n.c_str());
    std::exit(1);
  };
  Ref ref;
  auto dv = [](const std::vector<float> &v) { return std::vector<double>(v.begin(), v.end()); };
  for (int l = 0; l < 3; l++) {
    ref.V.push_back(dv(find("model.inter_arch.crossnet.V_kernels." + std::to_string(l))));
    ref.W.push_back(dv(find("model.inter_arch.crossnet.W_kernels." + std::to_string(l))));
    ref.cb.push_back(dv(find("model.inter_arch.crossnet.bias." + std::to_string(l))));
  }
  for (int l = 0; l < 4; l++) {
    ref.tw.push_back(dv(find("model.over_arch.model.0._mlp." + std::to_string(l) + "._linear.weight")));
    ref.tb.push_back(dv(find("model.over_arch.model.0._mlp." + std::to_string(l) + "._linear.bias")));
  }
  ref.tw.push_back(dv(find("model.over_arch.model.1.weight"))), ref.tb.push_back(dv(find("model.over_arch.model.1.bias")));

  const uint32_t m = 3, D = M.spec().inter();
  Model::Scratch sc;
  Model::Train tr;
  M.scratch(&sc, m), M.train_scratch(&tr, m);
  std::uniform_real_distribution<float> U(-0.3f, 0.3f);
  std::vector<float> dense(m * 13);
  for (auto &x : dense) x = U(g) * 5 + 1.5f;
  M.bottom(dense.data(), m, &sc);
  for (uint32_t r = 0; r < m; r++)
    for (uint32_t d = 128; d < D; d++) sc.x0[size_t(r) * D + d] = U(g);
  float score[m], logit[m], dz[m] = {1, 1, 1};
  M.top_train(m, &sc, &tr, score, logit);
  int fails = 0;
  double max_rel_fwd = 0;
  for (uint32_t r = 0; r < m; r++) {
    std::vector<double> x0(sc.x0.begin() + size_t(r) * D, sc.x0.begin() + size_t(r + 1) * D);
    const double z = ref.logit(x0);
    max_rel_fwd = std::max(max_rel_fwd, std::fabs(z - logit[r]) / std::max(1e-3, std::fabs(z)));
    std::printf("row %u: logit fp32 %.6f ref %.6f\n", r, logit[r], z);
  }
  if (max_rel_fwd > 1e-3) fails++, std::printf("FAIL forward rel err %.3g\n", max_rel_fwd);
  // top() (serving path) must equal top_train()
  float s2[m];
  M.top(m, &sc, s2);
  for (uint32_t r = 0; r < m; r++)
    if (std::fabs(s2[r] - score[r]) > 1e-6f) fails++, std::printf("FAIL top() %g vs top_train() %g\n", s2[r], score[r]);
  const float *gx = M.backward(m, &tr, dz);
  double max_err = 0;
  int checked = 0;
  std::uniform_int_distribution<uint32_t> C(0, D - 1);
  for (uint32_t r = 0; r < m; r++) {
    std::vector<double> x0(sc.x0.begin() + size_t(r) * D, sc.x0.begin() + size_t(r + 1) * D);
    for (int q = 0; q < 24; q++) {
      const uint32_t c = q < 4 ? q * 37 % 128 : C(g);  // a few dense_out columns, the rest mostly embedding columns
      const double h = 1e-4, o = x0[c];
      x0[c] = o + h;
      const double zp = ref.logit(x0);
      x0[c] = o - h;
      const double zm = ref.logit(x0);
      x0[c] = o;
      const double fd = (zp - zm) / (2 * h), an = gx[size_t(r) * D + c];
      const double e = std::fabs(fd - an) / std::max(1e-2, std::fabs(fd));
      max_err = std::max(max_err, e);
      checked++;
      if (e > 2e-3) fails++, std::printf("FAIL grad row %u col %u: analytic %.6g fd %.6g\n", r, c, an, fd);
    }
  }
  std::printf("forward max rel err %.3g; backward vs finite differences: %d coords, max rel err %.3g\n", max_rel_fwd,
              checked, max_err);
  // Adagrad step and fp16 round trip
  float w[128], acc = 0.5f, gg[128];
  for (int j = 0; j < 128; j++) w[j] = 0.01f * j, gg[j] = 0.001f * (j - 64);
  double ms = 0;
  for (int j = 0; j < 128; j++) ms += double(gg[j]) * gg[j];
  const double acc1 = 0.5 + ms / 128, mul = 0.004 / (std::sqrt(acc1) + 1e-8);
  AdagradCfg cfg;
  rowwise_adagrad(w, &acc, gg, 128, cfg);
  for (int j = 0; j < 128; j++)
    if (std::fabs(w[j] - (0.01 * j - mul * gg[j])) > 1e-6) fails++, std::printf("FAIL adagrad j %d\n", j);
  if (std::fabs(acc - acc1) > 1e-7) fails++, std::printf("FAIL adagrad acc\n");
  uint16_t h16[128];
  float back[128];
  f32_to_emb(w, 2, 128, h16), emb_to_f32(h16, 2, 128, back, false);
  for (int j = 0; j < 128; j++)
    if (std::fabs(back[j] - w[j]) > std::fabs(w[j]) * 1e-3 + 1e-7) fails++, std::printf("FAIL fp16 j %d\n", j);
  std::printf("flops/pair forward %.1f M, backward %.1f M\n", M.flops_per_pair() / 1e6, M.backward_flops_per_pair() / 1e6);
  std::printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}

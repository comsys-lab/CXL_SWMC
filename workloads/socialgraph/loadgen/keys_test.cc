// Unit test of the socialgraph loadgen generators (sg_gen.h): op mix, Zipf shapes, read/write permutation
// independence, the read permutation = the image generator's (expected feed rows recomputed from the image), small
// LinkBench samplers, owner routing balance.
// usage: sg-loadgen-keys-test [--image graph.img --gen gen.json]   (without --image the permutation-vs-image check is
// skipped and reported as such). Exit 0 = every check passed. Prints one line per check.
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

#include "../server/layout.h"
#include "sg_gen.h"

static int fails = 0;
static void check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void check(bool ok, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::printf("%s ", ok ? "PASS" : "FAIL");
  std::vprintf(fmt, ap);
  std::printf("\n");
  va_end(ap);
  fails += !ok;
}

static const uint64_t N = 1000000;  // draws per check

static void test_mix(double rw) {
  sgl::Mix m(rw);
  // target weights: LinkBench read proportions renormalized over reads
  const double reads = 1.0 - m.stream[sgl::kWrite];
  check(std::fabs(m.stream[sgl::kFeed] / reads - 0.73435) < 5e-5 && std::fabs(m.stream[sgl::kGetNode] / reads - 0.18727) < 5e-5 &&
            std::fabs(m.stream[sgl::kCountLink] / reads - 0.07076) < 5e-5 &&
            std::fabs(m.stream[sgl::kGetLink] / reads - 0.00762) < 5e-5 && std::fabs(reads / m.stream[sgl::kWrite] - rw) < 1e-9,
        "mix %g:1 weights: feed %.4f%% getnode %.4f%% countlink %.4f%% getlink %.4f%% of reads, write %.5f%% of requests "
        "(--mix %s)", rw, 100 * m.stream[0] / reads, 100 * m.stream[1] / reads, 100 * m.stream[2] / reads,
        100 * m.stream[3] / reads, 100 * m.stream[4], m.loadgen_mix().c_str());
  // 10^6 draws: stream by weight (= the engine's superposed Poisson streams), write op by WriteOpSampler
  std::mt19937_64 rng(7 + uint64_t(rw));
  sgl::WriteOpSampler ws(m);
  double cum[sgl::kStreams], c = 0;
  for (uint32_t s = 0; s < sgl::kStreams; s++) cum[s] = (c += m.stream[s]);
  uint64_t cnt[sgl::kStreams - 1 + sgl::kWriteOps] = {};
  for (uint64_t i = 0; i < N; i++) {
    const double u = sgl::u01(rng);
    uint32_t s = 0;
    while (s < sgl::kStreams - 1 && u >= cum[s]) s++;
    if (s == sgl::kWrite) cnt[sgl::kWrite + ws.draw(rng)]++;
    else cnt[s]++;
  }
  double maxpp = 0, maxz = 0;
  uint64_t writes = 0;
  for (uint32_t i = 0; i < sgl::kStreams - 1 + sgl::kWriteOps; i++) {
    const double t = i < sgl::kWrite ? m.stream[i] : m.stream[sgl::kWrite] * m.write_op[i - sgl::kWrite];
    const double e = double(cnt[i]) / N;
    if (i >= sgl::kWrite) writes += cnt[i];
    maxpp = std::max(maxpp, 100 * std::fabs(e - t));
    maxz = std::max(maxz, std::fabs(e - t) / std::sqrt(t * (1 - t) / N));
  }
  const double emp_rw = double(N - writes) / double(writes);
  check(maxpp <= 0.5 && maxz <= 5, "mix %g:1 over 10^6 draws: 10 ops, max |emp - target| = %.4f pp (<= 0.5), max z = %.2f "
        "(<= 5); realized read:write %.1f:1, feed %.4f%%", rw, maxpp, maxz, emp_rw, 100.0 * cnt[0] / N);
}

// top-k rank masses of the exact pmf for ascending ks (one pass)
static std::vector<double> topk_exact(uint64_t n, double s, const std::vector<uint64_t> &ks) {
  std::vector<double> T(ks.size(), 0);
  double H = 0;
  size_t j = 0;
  for (uint64_t r = 0; r < n; r++) {
    while (j < ks.size() && r == ks[j]) T[j++] = H;
    H += std::pow(double(r + 1), -s);
  }
  for (; j < ks.size(); j++) T[j] = H;
  for (double &t : T) t /= H;
  return T;
}

static void test_zipf(const sgl::Zipf &z, const char *name) {
  std::mt19937_64 rng(11 + uint64_t(z.shape() * 1000));
  std::vector<uint32_t> cnt(z.n(), 0);
  for (uint64_t i = 0; i < N; i++) cnt[z.draw(rng)]++;
  const std::vector<uint64_t> ks = {1, 10, 100, 1000, 10000, 100000, 1000000};
  const std::vector<double> exact = topk_exact(z.n(), z.shape(), ks);
  double maxz = 0;
  std::string detail;
  std::vector<double> emp;
  uint64_t acc = 0, r = 0;
  for (size_t i = 0; i < ks.size(); i++) {
    const uint64_t k = ks[i];
    for (; r < k; r++) acc += cnt[r];
    const double e = double(acc) / N, t = exact[i];
    emp.push_back(e);
    maxz = std::max(maxz, std::fabs(e - t) / std::sqrt(t * (1 - t) / N));
    char b[64];
    std::snprintf(b, sizeof(b), " top%lu %.4f/%.4f", (unsigned long)k, e, t);
    detail += b;
  }
  // fitted shape: least squares of the top-k masses over a grid of s (n ranks, exact pmf)
  double best_s = 0, best_err = 1e9;
  for (double s = z.shape() - 0.05; s <= z.shape() + 0.0501; s += 0.002) {
    const std::vector<double> t = topk_exact(z.n(), s, ks);
    double err = 0;
    for (size_t i = 0; i < 6; i++) err += std::pow(t[i] - emp[i], 2);
    if (err < best_err) best_err = err, best_s = s;
  }
  check(maxz <= 5 && std::fabs(best_s - z.shape()) <= 0.006,
        "zipf %s s=%.3f n=%lu, 10^6 draws: max z of top-k mass %.2f (<= 5), fitted s %.3f (|ds| <= 0.006);%s", name,
        z.shape(), (unsigned long)z.n(), maxz, best_s, detail.c_str());
}

static double overlap(const std::vector<uint32_t> &a, const std::vector<uint32_t> &b, uint64_t k, uint64_t n) {
  std::vector<uint8_t> in(n, 0);
  for (uint64_t i = 0; i < k; i++) in[a[i]] = 1;
  uint64_t o = 0;
  for (uint64_t i = 0; i < k; i++) o += in[b[i]];
  return double(o) / double(k);
}

// top-k keys by draw count (ties: lower key first)
template <class F> static std::vector<uint32_t> top_drawn(uint64_t n, uint64_t k, F &&draw) {
  std::vector<uint32_t> cnt(n, 0);
  for (uint64_t i = 0; i < N; i++) cnt[draw()]++;
  std::vector<uint32_t> idx(n);
  for (uint64_t i = 0; i < n; i++) idx[i] = uint32_t(i);
  std::partial_sort(idx.begin(), idx.begin() + long(k), idx.end(),
                    [&](uint32_t x, uint32_t y) { return cnt[x] != cnt[y] ? cnt[x] > cnt[y] : x < y; });
  idx.resize(k);
  return idx;
}

static void test_perm(const sgl::KeyGen &g, const sgl::KeyGen &same) {
  const uint64_t n = g.params().n, k = n / 100;
  // bijection
  std::vector<uint8_t> seen(n, 0);
  bool bij = true;
  for (uint32_t v : g.read_perm()) bij &= v < n && !seen[v]++;
  std::fill(seen.begin(), seen.end(), 0);
  for (uint32_t v : g.write_perm()) bij &= v < n && !seen[v]++;
  check(bij, "read and write permutations are bijections over %lu node slots", (unsigned long)n);
  const double ov = overlap(g.read_perm(), g.write_perm(), k, n);
  check(ov >= 0.008 && ov <= 0.012, "hot sets by rank: |top-1%% read keys & top-1%% write keys| / %lu = %.4f%% (expect ~1%%)",
        (unsigned long)k, 100 * ov);
  std::mt19937_64 r1(101), r2(202);
  const auto tr = top_drawn(n, k, [&] { return g.link_read(r1); });
  const auto tw = top_drawn(n, k, [&] { return g.link_write(r2); });
  const double ove = overlap(tr, tw, k, n);
  // write draws landing on the read hot set (by rank)
  std::vector<uint8_t> hot(n, 0);
  for (uint64_t i = 0; i < k; i++) hot[g.read_perm()[i]] = 1;
  std::mt19937_64 r3(303), r4(404);
  uint64_t hit = 0, hit_same = 0;
  for (uint64_t i = 0; i < N; i++) hit += hot[g.link_write(r3)], hit_same += hot[same.link_write(r4)];
  check(ove <= 0.025 && double(hit) / N >= 0.005 && double(hit) / N <= 0.02 && double(hit_same) / N > 0.2,
        "hot sets by 10^6 draws: top-1%% drawn read & write keys overlap %.4f%% (<= 2.5%%); write draws on the read "
        "top-1%% %.3f%% (0.5-2%%) vs %.2f%% with one shared permutation (control, > 20%%)", 100 * ove,
        100.0 * hit / N, 100.0 * hit_same / N);
  // getnode uses the read permutation (Zipf 0.625): its hottest key = the read rank-1 key
  std::mt19937_64 r5(505);
  const auto tg = top_drawn(n, 1, [&] { return g.node_read(r5); });
  check(tg[0] == g.read_perm()[0], "getnode hottest drawn key = read permutation rank 1 (slot %u)", g.read_perm()[0]);
}

static bool json_num(const std::string &txt, const std::string &key, double *out) {
  const std::string k = "\"" + key + "\":";
  size_t p = txt.find(k);
  if (p == std::string::npos) return false;
  *out = std::strtod(txt.c_str() + p + k.size(), nullptr);
  return true;
}

// Recompute gen.json feed_rows_expected (fisher_yates_perm, uniform_random_perm) from the image's build-time degrees
// with the plugin's read permutation.
static void test_image(const sgl::KeyGen &g, const char *image, const char *gen) {
  int fd = open(image, O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st)) return check(false, "open %s", image);
  void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
  close(fd);
  if (m == MAP_FAILED) return check(false, "mmap %s", image);
  sg::View v(m);
  const std::string bad = sg::check_header(*v.h, uint64_t(st.st_size));
  check(bad.empty() && v.h->n_orig == g.params().n, "image header ok (%s), n_orig %lu = plugin nodes %lu",
        bad.empty() ? "consistent" : bad.c_str(), (unsigned long)v.h->n_orig, (unsigned long)g.params().n);
  const uint64_t n = g.params().n;
  std::vector<double> rows(n, 0);
  for (uint64_t i = 0; i < n; i++) rows[i] = v.has_adj(i) ? std::min<double>(50, v.adj(i)->count) : 0;
  munmap(m, size_t(st.st_size));
  double H = 0, efy = 0, eun = 0;
  for (uint64_t r = 0; r < n; r++) {
    const double w = std::pow(double(r + 1), -g.params().read_zipf);
    H += w;
    efy += w * rows[g.read_perm()[r]];
    eun += rows[r];
  }
  efy /= H, eun /= double(n);
  std::ifstream in(gen);
  std::stringstream ss;
  ss << in.rdbuf();
  double want_fy = 0, want_un = 0, want_seed = 0;
  const bool have = json_num(ss.str(), "fisher_yates_perm", &want_fy) && json_num(ss.str(), "uniform_random_perm", &want_un) &&
                    json_num(ss.str(), "fisher_yates_perm_seed", &want_seed);
  check(have && std::fabs(efy - want_fy) < 6e-5 && std::fabs(eun - want_un) < 6e-5 &&
            std::fabs(want_seed - double(g.params().read_perm_seed)) < 1e4,
        "read permutation = image manifest's: expected feed rows %.4f (gen.json fisher_yates_perm %.4f), uniform %.4f "
        "(gen.json %.4f), seed %lu", efy, want_fy, eun, want_un, (unsigned long)g.params().read_perm_seed);
}

static void test_small(const sgl::KeyGen &g) {
  namespace lb = socialgraph::linkbench;
  std::mt19937_64 rng(909);
  double sum = 0;
  uint32_t mn = 1000, mx = 0;
  for (uint64_t i = 0; i < N; i++) {
    const uint32_t k = sgl::multiget_size(rng);
    sum += k, mn = std::min(mn, k), mx = std::max(mx, k);
  }
  check(std::fabs(sum / N - (1 + 1 / lb::kMultigetProb)) < 0.02 && mn >= 1 && mx <= 127,
        "getlink multiget size: mean %.3f (1 + 1/p = %.3f), range [%u, %u]", sum / N, 1 + 1 / lb::kMultigetProb, mn, mx);
  std::vector<uint32_t> ls, ns;
  uint64_t lcap = 0, ncap = 0;
  for (uint64_t i = 0; i < 200000; i++) {
    ls.push_back(sgl::payload_size(rng, lb::kLinkDataSize, 1u << 30));
    ns.push_back(sgl::payload_size(rng, lb::kNodeDataSize, 1u << 30));
    lcap += sgl::payload_size(rng, lb::kLinkDataSize, sg::kEdgeDataCap) == sg::kEdgeDataCap;
    ncap += sgl::payload_size(rng, lb::kNodeDataSize, sg::kNodeDataCap) == sg::kNodeDataCap;
  }
  std::nth_element(ls.begin(), ls.begin() + 100000, ls.end());
  std::nth_element(ns.begin(), ns.begin() + 100000, ns.end());
  check(std::abs(int(ls[100000]) - 8) <= 1 && std::abs(int(ns[100000]) - 128) <= 2,
        "payload LogNormal medians: link %u (8), node %u (128); at cap: link %.1f%% (12 B), node %.1f%% (88 B)", ls[100000],
        ns[100000], 100.0 * lcap / 200000, 100.0 * ncap / 200000);
  for (uint32_t nt : {2u, 4u, 8u}) {
    std::vector<uint64_t> c(nt, 0);
    std::mt19937_64 r(nt);
    for (uint64_t i = 0; i < N; i++) c[g.link_write(r) % nt]++;
    double worst = 0;
    for (uint64_t x : c) worst = std::max(worst, std::fabs(double(x) / N - 1.0 / nt));
    check(worst <= 0.01, "owner routing over %u VMs (link writes): max |share - 1/N| = %.4f (<= 0.01)", nt, worst);
  }
}

int main(int argc, char **argv) {
  const char *image = nullptr, *gen = nullptr;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!std::strcmp(argv[i], "--image")) image = argv[i + 1];
    else if (!std::strcmp(argv[i], "--gen")) gen = argv[i + 1];
  }
  test_mix(100);
  test_mix(470);
  sgl::KeyParams kp;  // defaults = plugin defaults (image build 1)
  sgl::KeyGen g;
  g.build(kp);
  sgl::KeyParams kp_same = kp;
  kp_same.write_perm_seed = kp.read_perm_seed;  // control: one shared permutation
  sgl::KeyGen same;
  same.build(kp_same);
  test_zipf(g.z_read(), "read (feed/countlink/getlink)");
  test_zipf(g.z_getnode(), "getnode");
  test_zipf(g.z_wlink(), "link writes");
  test_zipf(g.z_wnode(), "updatenode");
  test_perm(g, same);
  test_small(g);
  if (image && gen) test_image(g, image, gen);
  else std::printf("SKIP read permutation vs image (no --image/--gen)\n");
  std::printf("%s: %d failed\n", fails ? "FAILED" : "ALL PASS", fails);
  return fails ? 1 : 0;
}

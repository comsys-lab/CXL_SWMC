// recsys v7 Host tool (DESIGN.md §10): scores day-23 samples with the converted MLPerf DLRMv2 checkpoint, no shared
// memory, no VM.
//   frozen: score [start, start + count) with the checkpoint as is (baseline AUC, frozen AUC of every run). Streams
//           the table image once per chunk of samples: lookups sorted by row, pooled sums accumulated while the image
//           is read in large sequential blocks (page cache dropped behind), then the dense part in parallel.
//   train:  prequential online training (test-then-train) over a short range: per batch of B samples, score (logged),
//           BCE gradient through the frozen dense part (model.h backward), row-wise Adagrad (emb_v7.h) on the rows,
//           which are held in DRAM (loaded once; the image file is never written). Measures the updater's CPU per
//           sample (forward + backward + row update) at T threads; --no-update scores only (same rows).
// Output: scores file (64 B header "RSYSSCR1" + {u64 sample, f32 score, u8 label, u8[3]} per scored sample);
//         tools/auc.py computes AUC / logloss.
// usage: recsys-score --mode frozen|train --image F --dense F --samples F --start S --count N --out F
//                     [--threads T] [--chunk C] [--batch B] [--lr X] [--eps X] [--no-update]
//                     [--mlp avx512|amx]   frozen only: dense forward fp32 AVX-512 (default) | bf16 AMX tiles
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <thread>
#include <vector>

#include "../samples.h"
#include "../server/emb_v7.h"
#include "../server/model.h"

using namespace rsys;

static const uint32_t kHot[26] = {3, 2, 1, 2, 6, 1, 1, 1, 1, 7, 3, 8, 1, 6, 9, 5, 1, 1, 1, 12, 100, 27, 10, 3, 1, 1};

struct ScoreRec {
  uint64_t sample;
  float score;
  uint8_t label, pad[3];
};
static_assert(sizeof(ScoreRec) == 16, "score record");

static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static double cpu_s() {
  rusage u{};
  getrusage(RUSAGE_SELF, &u);
  return u.ru_utime.tv_sec + u.ru_stime.tv_sec + 1e-6 * (u.ru_utime.tv_usec + u.ru_stime.tv_usec);
}
static double thread_cpu_s() {
  timespec t{};
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
  return t.tv_sec + 1e-9 * t.tv_nsec;
}
[[noreturn]] static void die(const std::string &m) {
  std::fprintf(stderr, "recsys-score: %s\n", m.c_str());
  std::exit(1);
}

struct Image {
  int fd = -1;
  ImageHeader h{};
  uint32_t elt = 2, rb = 320, dim = 128;
  void open_(const std::string &p) {
    fd = ::open(p.c_str(), O_RDONLY);
    if (fd < 0) die(p + ": open");
    if (pread(fd, &h, sizeof h, 0) != ssize_t(sizeof h) || h.magic != kImageMagic || h.version != kImageVersion)
      die(p + ": not a RSYSIMG1 v1 image");
    elt = h.elt_bytes, rb = h.record_bytes, dim = h.dim;
    struct stat st{};
    fstat(fd, &st);
    if (uint64_t(st.st_size) != h.data_off + h.rows * rb || rb != rec_bytes(dim, elt)) die(p + ": size/record mismatch");
  }
  // Visit the records of sorted unique global rows `rows` in file order with large sequential reads.
  template <class F>
  void scan(const std::vector<uint64_t> &rows, F &&visit, uint64_t block = 16ull << 20) const {
    std::vector<uint8_t> buf(block + rb);
    size_t i = 0;
    while (i < rows.size()) {
      const uint64_t off0 = h.data_off + rows[i] * rb;
      size_t j = i;
      while (j < rows.size() && h.data_off + (rows[j] + 1) * rb - off0 <= block) j++;
      const uint64_t len = h.data_off + (rows[j - 1] + 1) * rb - off0;
      uint64_t got = 0;
      while (got < len) {
        ssize_t r = pread(fd, buf.data() + got, len - got, off0 + got);
        if (r <= 0) die("image read");
        got += r;
      }
      for (size_t q = i; q < j; q++) visit(q, buf.data() + (h.data_off + rows[q] * rb - off0));
      posix_fadvise(fd, off0, len, POSIX_FADV_DONTNEED);
      i = j;
    }
  }
};

struct Samples {
  const Sample *s = nullptr;
  uint64_t n = 0;
  void open_(const std::string &p) {
    int fd = ::open(p.c_str(), O_RDONLY);
    if (fd < 0) die(p + ": open");
    SamplesHeader h{};
    struct stat st{};
    fstat(fd, &st);
    if (pread(fd, &h, sizeof h, 0) != ssize_t(sizeof h) || h.magic != kSamplesMagic || h.version != kSamplesVersion ||
        h.record_bytes != sizeof(Sample) || uint64_t(st.st_size) != sizeof h + h.count * sizeof(Sample))
      die(p + ": not a v3 samples file");
    void *m = mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) die("mmap samples");
    s = reinterpret_cast<const Sample *>(static_cast<uint8_t *>(m) + sizeof h);
    n = h.count;
  }
};

struct Args {
  std::string mode, image, dense, samples, out;
  uint64_t start = 0, count = 0, chunk = 250000;
  uint32_t threads = 1, batch = 8;
  bool update = true;
  Mlp mlp = Mlp::avx512;  // frozen only: dense-part forward kind (model.h; amx = bf16 tiles, fp32 accumulate)
  AdagradCfg ada;
};

static FILE *open_out(const std::string &p, uint64_t n) {
  FILE *f = std::fopen(p.c_str(), "wbx");
  if (!f) die(p + ": cannot create (exists?)");
  char h[64] = "RSYSSCR1";
  std::memcpy(h + 8, &n, 8);
  std::fwrite(h, 1, 64, f);
  return f;
}

// Fill x0[:, dim:] of row r from pooled sums (frozen) -- done by the caller; dense part over m rows.
static void dense_part(const Model &M, const Sample *const *sp, const float *pooled, uint32_t m, Model::Scratch *sc,
                       float *score, Mlp k) {
  const uint32_t D = M.spec().inter(), dim = M.spec().dim;
  float dense[64 * 13];
  for (uint32_t r = 0; r < m; r++) std::memcpy(dense + r * 13, sp[r]->dense, 13 * 4);
  M.bottom(dense, m, sc, k);
  for (uint32_t r = 0; r < m; r++) std::memcpy(&sc->x0[size_t(r) * D + dim], pooled + size_t(r) * 26 * dim, 26 * dim * 4);
  M.top(m, sc, score, k);
}

static void run_frozen(const Args &a, const Model &M, const Image &img, const Samples &S) {
  const uint32_t dim = img.dim;
  FILE *fo = open_out(a.out, a.count);
  double t0 = now_s(), io_s = 0, mlp_s = 0;
  for (uint64_t c0 = a.start; c0 < a.start + a.count; c0 += a.chunk) {
    const uint64_t c1 = std::min(a.start + a.count, c0 + a.chunk), n = c1 - c0;
    double ta = now_s();
    std::vector<uint64_t> ent;  // row << 26 | slot index (sample_local * 26 + table): row < 2^28, slot < 2^26 -> 54 bits
    if (n * 26 >= (1ull << 26)) die("--chunk too large");
    ent.reserve(n * kMultiHot);
    for (uint64_t s = 0; s < n; s++) {
      const Sample &x = S.s[c0 + s];
      uint32_t off = 0;
      for (uint32_t k = 0; k < 26; k++) {
        for (uint32_t j = 0; j < kHot[k]; j++) {
          const uint64_t id = x.ids[off + j];
          if (id >= img.h.table_rows[k]) die("id out of range");
          ent.push_back((img.h.row_base[k] + id) << 26 | (s * 26 + k));
        }
        off += kHot[k];
      }
    }
    std::sort(ent.begin(), ent.end());
    std::vector<uint64_t> rows;
    rows.reserve(ent.size());
    for (uint64_t e : ent)
      if (rows.empty() || rows.back() != (e >> 26)) rows.push_back(e >> 26);
    std::vector<float> pooled(n * 26 * dim, 0.f);
    size_t e = 0;
    img.scan(rows, [&](size_t q, const uint8_t *rec) {
      const uint64_t row = rows[q];
      for (; e < ent.size() && (ent[e] >> 26) == row; e++)
        emb_to_f32(rec + RecOff::emb, img.elt, dim, &pooled[(ent[e] & ((1ull << 26) - 1)) * dim], true);
    });
    if (e != ent.size()) die("scan incomplete");
    double tb = now_s();
    io_s += tb - ta;
    std::vector<ScoreRec> out(n);
    std::atomic<uint64_t> next{0};
    std::vector<std::thread> th;
    for (uint32_t t = 0; t < a.threads; t++)
      th.emplace_back([&] {
        Model::Scratch sc;
        M.scratch(&sc, 64);
        const Sample *sp[64];
        float score[64];
        for (;;) {
          const uint64_t b = next.fetch_add(64);
          if (b >= n) break;
          const uint32_t m = uint32_t(std::min<uint64_t>(64, n - b));
          for (uint32_t r = 0; r < m; r++) sp[r] = &S.s[c0 + b + r];
          dense_part(M, sp, &pooled[b * 26 * dim], m, &sc, score, a.mlp);
          for (uint32_t r = 0; r < m; r++) out[b + r] = ScoreRec{c0 + b + r, score[r], sp[r]->label, {0, 0, 0}};
        }
      });
    for (auto &x : th) x.join();
    mlp_s += now_s() - tb;
    std::fwrite(out.data(), sizeof(ScoreRec), n, fo);
    std::fprintf(stderr, "chunk [%lu,%lu): %zu lookups, %zu unique rows, read+pool %.1f s, dense %.1f s\n", c0, c1,
                 ent.size(), rows.size(), tb - ta, now_s() - tb);
  }
  std::fclose(fo);
  std::printf("mode=frozen samples=%lu wall_s=%.1f io_pool_s=%.1f dense_s=%.1f threads=%u mlp=%s\n", a.count,
              now_s() - t0, io_s, mlp_s, a.threads, mlp_name(a.mlp));
}

// ---- train: rows of the range in DRAM (compact), prequential batches, Hogwild across threads
static void run_train(const Args &a, const Model &M, const Image &img, const Samples &S) {
  const uint32_t dim = img.dim, D = M.spec().inter();
  const uint64_t n = a.count;
  std::vector<uint64_t> look(n * kMultiHot);  // global rows, then compact index
  for (uint64_t s = 0; s < n; s++) {
    const Sample &x = S.s[a.start + s];
    uint32_t off = 0;
    for (uint32_t k = 0; k < 26; k++) {
      for (uint32_t j = 0; j < kHot[k]; j++) look[s * kMultiHot + off + j] = img.h.row_base[k] + x.ids[off + j];
      off += kHot[k];
    }
  }
  std::vector<uint64_t> rows(look);
  std::sort(rows.begin(), rows.end());
  rows.erase(std::unique(rows.begin(), rows.end()), rows.end());
  std::vector<uint32_t> idx(look.size());
  for (size_t i = 0; i < look.size(); i++)
    idx[i] = uint32_t(std::lower_bound(rows.begin(), rows.end(), look[i]) - rows.begin());
  std::vector<float> W(rows.size() * dim), acc(rows.size());  // fp32 working copy; stored back as fp16 each update
  std::vector<uint16_t> W16(img.elt == 2 ? rows.size() * dim : 0);
  double tl = now_s();
  img.scan(rows, [&](size_t q, const uint8_t *rec) {
    emb_to_f32(rec + RecOff::emb, img.elt, dim, &W[q * dim], false);
    std::memcpy(&acc[q], rec + RecOff::acc, 4);
  });
  std::fprintf(stderr, "train: %lu samples, %zu unique rows loaded in %.1f s\n", n, rows.size(), now_s() - tl);
  // rows are kept in fp32 here but rounded through the record's element type after every update (as the server does)
  std::vector<ScoreRec> out(n);
  std::atomic<uint64_t> next{0};
  std::vector<double> tcpu(a.threads * 4, 0.0);  // per thread: fwd, bwd, rows, total
  const double w0 = now_s(), c0 = cpu_s();
  std::vector<std::thread> th;
  for (uint32_t t = 0; t < a.threads; t++)
    th.emplace_back([&, t] {
      const uint32_t B = a.batch;
      Model::Scratch sc;
      Model::Train tr;
      M.scratch(&sc, B);
      M.train_scratch(&tr, B);
      std::vector<float> dense(B * 13), score(B), dz(B), gsum, wtmp(dim);
      std::vector<std::pair<uint32_t, uint32_t>> touch;  // (compact row, batch row * 26 + table)
      double f = 0, bw = 0, rw = 0;
      const double tt0 = thread_cpu_s();
      for (;;) {
        const uint64_t b = next.fetch_add(B);
        if (b >= n) break;
        const uint32_t m = uint32_t(std::min<uint64_t>(B, n - b));
        double q0 = thread_cpu_s();
        for (uint32_t r = 0; r < m; r++) std::memcpy(&dense[r * 13], S.s[a.start + b + r].dense, 52);
        M.bottom(dense.data(), m, &sc);
        for (uint32_t r = 0; r < m; r++) {
          const uint32_t *ix = &idx[(b + r) * kMultiHot];
          uint32_t off = 0;
          for (uint32_t k = 0; k < 26; k++) {
            float *dst = &sc.x0[size_t(r) * D + dim * (k + 1)];
            std::memset(dst, 0, dim * 4);
            for (uint32_t j = 0; j < kHot[k]; j++) {
              const float *src = &W[size_t(ix[off + j]) * dim];
              for (uint32_t c = 0; c < dim; c++) dst[c] += src[c];
            }
            off += kHot[k];
          }
        }
        M.top_train(m, &sc, &tr, score.data());
        for (uint32_t r = 0; r < m; r++) {
          const Sample &x = S.s[a.start + b + r];
          out[b + r] = ScoreRec{a.start + b + r, score[r], x.label, {0, 0, 0}};
          dz[r] = (score[r] - float(x.label)) / float(m);  // BCE, mean over the batch
        }
        double q1 = thread_cpu_s();
        f += q1 - q0;
        if (!a.update) continue;
        const float *gx = M.backward(m, &tr, dz.data());
        double q2 = thread_cpu_s();
        bw += q2 - q1;
        // rows: sum gradients of the same row inside the batch, then one Adagrad step per row
        touch.clear();
        for (uint32_t r = 0; r < m; r++) {
          const uint32_t *ix = &idx[(b + r) * kMultiHot];
          uint32_t off = 0;
          for (uint32_t k = 0; k < 26; k++) {
            for (uint32_t j = 0; j < kHot[k]; j++) touch.emplace_back(ix[off + j], r * 26 + k);
            off += kHot[k];
          }
        }
        std::sort(touch.begin(), touch.end());
        gsum.assign(dim, 0.f);
        for (size_t i = 0; i < touch.size();) {
          const uint32_t row = touch[i].first;
          std::fill(gsum.begin(), gsum.end(), 0.f);
          for (; i < touch.size() && touch[i].first == row; i++) {
            const uint32_t r = touch[i].second / 26, k = touch[i].second % 26;
            const float *g = gx + size_t(r) * D + dim * (k + 1);
            for (uint32_t c = 0; c < dim; c++) gsum[c] += g[c];
          }
          float *w = &W[size_t(row) * dim];
          rowwise_adagrad(w, &acc[row], gsum.data(), dim, a.ada);
          if (img.elt == 2) {  // storage precision of the record
            f32_to_emb(w, 2, dim, &W16[size_t(row) * dim]);
            emb_to_f32(&W16[size_t(row) * dim], 2, dim, w, false);
          }
        }
        rw += thread_cpu_s() - q2;
      }
      tcpu[t * 4 + 0] = f, tcpu[t * 4 + 1] = bw, tcpu[t * 4 + 2] = rw, tcpu[t * 4 + 3] = thread_cpu_s() - tt0;
    });
  for (auto &x : th) x.join();
  const double wall = now_s() - w0, cpu = cpu_s() - c0;
  double f = 0, bw = 0, rw = 0;
  for (uint32_t t = 0; t < a.threads; t++) f += tcpu[t * 4], bw += tcpu[t * 4 + 1], rw += tcpu[t * 4 + 2];
  FILE *fo = open_out(a.out, n);
  std::fwrite(out.data(), sizeof(ScoreRec), n, fo);
  std::fclose(fo);
  std::printf("mode=train update=%d samples=%lu threads=%u batch=%u lr=%g eps=%g wall_s=%.3f samples_per_s=%.1f "
              "cpu_s=%.3f cpu_ms_per_sample=%.3f fwd_ms=%.3f bwd_ms=%.3f rows_ms=%.3f fwd_mflop=%.1f bwd_mflop=%.1f\n",
              a.update, n, a.threads, a.batch, a.ada.lr, a.ada.eps, wall, n / wall, cpu, 1e3 * cpu / n, 1e3 * f / n,
              1e3 * bw / n, 1e3 * rw / n, M.flops_per_pair() / 1e6, M.backward_flops_per_pair() / 1e6);
}

int main(int argc, char **argv) {
  Args a;
  for (int i = 1; i < argc; i++) {
    std::string k = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) die("missing value for " + k);
      return argv[++i];
    };
    if (k == "--mode") a.mode = v();
    else if (k == "--image") a.image = v();
    else if (k == "--dense") a.dense = v();
    else if (k == "--samples") a.samples = v();
    else if (k == "--out") a.out = v();
    else if (k == "--start") a.start = std::stoull(v());
    else if (k == "--count") a.count = std::stoull(v());
    else if (k == "--chunk") a.chunk = std::stoull(v());
    else if (k == "--threads") a.threads = std::stoul(v());
    else if (k == "--batch") a.batch = std::stoul(v());
    else if (k == "--lr") a.ada.lr = std::stof(v());
    else if (k == "--eps") a.ada.eps = std::stof(v());
    else if (k == "--no-update") a.update = false;
    else if (k == "--mlp") {
      if (!parse_mlp(v(), &a.mlp)) die("--mlp avx512|amx");
    } else die("unknown option " + k);
  }
  if (a.mlp == Mlp::amx && a.mode != "frozen") die("--mlp amx is for --mode frozen (the training path stays fp32)");
  if ((a.mode != "frozen" && a.mode != "train") || a.image.empty() || a.dense.empty() || a.samples.empty() ||
      a.out.empty() || !a.count || !a.threads || !a.batch || a.batch > 64)
    die("usage: --mode frozen|train --image F --dense F --samples F --start S --count N --out F [--threads T] "
        "[--chunk C] [--batch B<=64] [--lr X] [--eps X] [--no-update]");
  Model M;
  std::string err;
  if (!M.load_dense(a.dense, &err)) die(err);
  if (a.mlp == Mlp::amx) {
    if (!amx_enable(&err)) die("--mlp amx: " + err);
    M.prepare_amx();
  }
  Image img;
  img.open_(a.image);
  Samples S;
  S.open_(a.samples);
  if (a.start + a.count > S.n) die("range beyond the samples file");
  if (img.dim != M.spec().dim) die("image dim != model dim");
  if (a.mode == "frozen") run_frozen(a, M, img, S);
  else run_train(a, M, img, S);
  return 0;
}

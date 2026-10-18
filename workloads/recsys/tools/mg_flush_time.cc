// Megalon whole-object flush timing (Host, file region, 2 processes = 2 nodes; tests/mg_flush_time.sh). Measures what
// one publication round costs with one Megalon object per embedding table (DESIGN.md §7):
//   node 0: ObjectCreate(one object of B bytes), initial fill in one write section (timed: fill, write_end), then R
//           rounds, each: write_start, write K random 576 B rows (address order), write_end (= whole-object flush +
//           unlock), timed per call; P ms pause between rounds.
//   node 1: after the object exists, a reader loop of one-row read sections (read_start, copy 576 B, read_end, redo on
//           failure), timed per accepted row read; reports count, mean, max and the reads slower than 1 ms (the stall
//           a serving thread sees: writer holding the object + its own whole-object flush on a changed counter).
// node 0 creates a 64 B "done" object after the last round; node 1 stops when it exists.
// usage: mg-flush-time <libmegalon-objapi.so> <object bytes> <rounds R> <rows per round K> <pause ms P>
#include <dlfcn.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "megalon_objapi.h"

static double now_s() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return double(ts.tv_sec) + double(ts.tv_nsec) * 1e-9;
}

int main(int argc, char **argv) {
  if (argc != 6) {
    std::fprintf(stderr, "usage: %s <shim.so> <object bytes> <rounds> <rows per round> <pause ms>\n", argv[0]);
    return 2;
  }
  const uint64_t row = 576;
  const uint64_t bytes = std::strtoull(argv[2], nullptr, 0) / row * row;
  const int rounds = std::atoi(argv[3]);
  const uint64_t K = std::strtoull(argv[4], nullptr, 0);
  const int pause_ms = std::atoi(argv[5]);
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) return std::printf("dlopen: %s\n", dlerror()), 1;
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  const mshim::Api *a = fn();
  const size_t node = a->node_id();
  std::printf("node %zu shim '%s' object %lu B (%.3f GB, %lu rows) rounds %d rows/round %lu pause %d ms\n", node,
              a->info, (unsigned long)bytes, bytes / 1e9, (unsigned long)(bytes / row), rounds, (unsigned long)K,
              pause_ms);
  std::fflush(stdout);
  a->reg(1);
  const uint64_t id = 0x464c5553ull << 32, done = id + 1;  // "FLUS"
  const uint64_t nrows = bytes / row;
  std::mt19937_64 rng(12345 + node);
  mshim::Obj o;
  if (node == 0) {
    double t0 = now_s();
    int rc = a->create(id, bytes);
    if (rc) return std::printf("create = %d\n", rc), 3;
    std::printf("node 0 create %.3f s\n", now_s() - t0);
    t0 = now_s();
    if (a->write_start(id, &o)) return 4;
    const double t1 = now_s();
    for (uint64_t r = 0; r < nrows; r++) {
      uint64_t *p = reinterpret_cast<uint64_t *>(o.ptr + r * row);
      for (uint64_t j = 0; j < row / 8; j++) p[j] = r * 131 + j;
    }
    const double t2 = now_s();
    a->write_end(&o);
    const double t3 = now_s();
    std::printf("node 0 initial: write_start %.6f s fill %.3f s write_end %.3f s (%.2f GB/s flush)\n", t1 - t0, t2 - t1,
                t3 - t2, bytes / 1e9 / (t3 - t2));
    std::fflush(stdout);
    usleep(useconds_t(pause_ms) * 1000);
    std::vector<uint64_t> rows(K);
    double sum_we = 0, max_we = 0;
    for (int i = 0; i < rounds; i++) {
      for (auto &r : rows) r = rng() % nrows;
      std::sort(rows.begin(), rows.end());
      const double s0 = now_s();
      if (a->write_start(id, &o)) return 5;
      const double s1 = now_s();
      for (uint64_t r : rows) {
        uint64_t *p = reinterpret_cast<uint64_t *>(o.ptr + r * row);
        for (uint64_t j = 0; j < row / 8; j++) p[j] = r * 131 + j + uint64_t(i + 1) * 1000003;
      }
      const double s2 = now_s();
      a->write_end(&o);
      const double s3 = now_s();
      sum_we += s3 - s2, max_we = std::max(max_we, s3 - s2);
      std::printf("node 0 round %d: write_start %.6f s rows %.6f s write_end %.3f s\n", i, s1 - s0, s2 - s1, s3 - s2);
      std::fflush(stdout);
      usleep(useconds_t(pause_ms) * 1000);
    }
    if (rounds) std::printf("node 0 rounds %d write_end mean %.3f s max %.3f s\n", rounds, sum_we / rounds, max_we);
    if (a->create(done, 64)) return 6;
  } else {
    size_t sz = 0;
    while (a->lookup(id, &sz) != 0) usleep(100000);
    if (sz != bytes) return std::printf("size %zu\n", sz), 7;
    // the first reads may wait for the initial fill (node 0 holds the write section): reported as slow read 1
    uint64_t n = 0, slow = 0, retries = 0;
    double sum = 0, mx = 0, slow_sum = 0;
    alignas(64) uint8_t buf[576];
    for (;;) {
      if ((n & 1023) == 0 && a->lookup(done, &sz) == 0) break;
      const uint64_t r = rng() % nrows;
      const double t0 = now_s();
      for (;;) {
        if (a->read_start(id, &o)) return 8;
        std::memcpy(buf, o.ptr + r * row, row);
        if (a->read_end(&o)) break;
        retries++;
      }
      const double d = now_s() - t0;
      n++, sum += d, mx = std::max(mx, d);
      if (d > 1e-3) {
        slow++, slow_sum += d;
        std::printf("node 1 slow read %lu: %.3f s\n", (unsigned long)slow, d);
        std::fflush(stdout);
      }
    }
    std::printf("node 1 reads %lu mean %.3f us max %.3f s retries %lu slow(>1ms) %lu total %.3f s\n", (unsigned long)n,
                n ? sum / n * 1e6 : 0, mx, (unsigned long)retries, (unsigned long)slow, slow_sum);
  }
  mshim::Stats s{};
  a->stats(&s);
  std::printf("node %zu stats: read_sections %lu read_retry_notify %lu read_retry_incoherent %lu write_sections %lu "
              "switch_rw %lu flushes %lu flush_bytes %lu replay_flushes %lu replay_flush_bytes %lu\n",
              node, (unsigned long)s.read_sections, (unsigned long)s.read_retry_notify,
              (unsigned long)s.read_retry_incoherent, (unsigned long)s.write_sections, (unsigned long)s.switch_rw,
              (unsigned long)s.flushes, (unsigned long)s.flush_bytes, (unsigned long)s.replay_flushes,
              (unsigned long)s.replay_flush_bytes);
  std::fflush(stdout);
  std::_Exit(0);
}

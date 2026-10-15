// faultlat: per-fault latency of a coherence-managed device-DAX mapping.
//
// Measures the time of single user accesses that each take one page fault
// on pages of the software-coherent (swcc) range of the shared CXL device,
// end to end as the application sees it: exception entry, coherence
// protocol (including the inter-VM message round trip), PTE install, retry
// of the access.  Region offsets come only from the region config
// (config/cxl_region.yaml via systems/common/cxl_region.h).
//
// Subcommands (see README.md):
//   faultlat params [--nodes N] [--device-size B] [--init-state invalid|shared]
//   faultlat access --op read|write|rw [--pages N] [--page-offset P] [--stride S]
//                   [--passes K] [--shuffle] [--cpu C] [--out F] [--raw F]
//                   [--pattern X] [--expect X]
//   faultlat pingpong --role R --nonce X [--nodes N] [--iters N] [--page-offset P]
//                   [--cpu C] [--out F] [--raw F]
//   faultlat contend --node K --nodes N --run-id X --threads T --pages H --page-offset P --read-pct R
//                   --duration-s D [--dist uniform|zipf] [--zipf-theta Z] [--salt S] [--skip-init]
//                   [--watchdog-s W] [--interval-ms I] [--barrier-timeout-s B] [--think-ns N] [--cpu-list L]
//                   [--dist partition --max-ops M] [--churn-us U] [--no-abort] [--no-swmr-probe] [--seed X]
//                   [--out F] [--raw F]
//   faultlat contend --init-only --pages H --page-offset P --salt S      (plain mapping, e.g. shared preload)
//   faultlat contend --app-bytes --nodes N --threads T --pages H         (HWcc app bytes for the layout)
//
// Nothing here needs root, but opening the DAX device needs permission on it.

#include <dirent.h>
#include <pthread.h>
#include <signal.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <cerrno>
#include <cstdarg>
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "../../systems/common/cxl_region.h"
#include "../../systems/common/hwcc_app.h"
#include "contend.h"

namespace {

constexpr uint64_t kPage = 4096;
constexpr const char *kSysfs = "/sys/kernel/swmc/page_coherence";
constexpr const char *kVersion = "faultlat-3";

[[noreturn]] void die(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "faultlat: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  exit(1);
}

inline uint64_t now_ns() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

struct Args {
  std::string cmd;
  std::string op = "read";
  uint64_t pages = 4096;
  uint64_t page_offset = 0;   // first page, relative to swcc start
  uint64_t stride = 1;        // in pages
  int passes = 1;
  bool shuffle = false;
  int cpu = -1;
  int role = -1;
  int nodes = 2;
  uint64_t nonce = 0;
  uint64_t iters = 10000;
  uint64_t device_size = 0;   // params only: override /sys/bus/dax/.../size (Host dry run)
  std::string init_state = "invalid";  // params only: cxl_shm init_state
  bool has_pattern = false, has_expect = false;
  uint64_t pattern = 0, expect = 0;  // access: written / expected value X ^ page index (data check)
  std::string out, raw, config;
  // contend
  int node = -1;
  uint32_t threads = 1;
  int read_pct = 50;
  double duration_s = 10;
  std::string dist = "uniform";
  double zipf_theta = 0.99;
  uint64_t run_id = 0;
  bool has_salt = false;
  uint64_t salt = 0;
  bool skip_init = false, init_only = false, app_bytes = false;
  double watchdog_s = 10;
  uint64_t interval_ms = 100;
  double barrier_timeout_s = 120;
  uint64_t think_ns = 0;
  std::string cpu_list;
  bool abort_on_violation = true, swmr_probe = true;
  uint64_t seed = 0;
  uint64_t max_ops = 0;   // contend: per-thread op limit (0 = duration only)
  uint64_t churn_us = 0;  // contend: churn thread period (0 = off)
  std::string inject;  // test only: stale|corrupt|lost|stall|sigbus:N (node 0, thread 0, N-th write)
};

uint64_t parse_num(const char *s, const char *what) {
  char *end = nullptr;
  errno = 0;
  unsigned long long v = strtoull(s, &end, 0);
  if (errno || !end || *end) die("bad value for %s: %s", what, s);
  return v;
}

Args parse_args(int argc, char **argv) {
  if (argc < 2) die("usage: faultlat params|access|pingpong|contend [options] (see README.md)");
  Args a;
  a.cmd = argv[1];
  for (int i = 2; i < argc; i++) {
    std::string k = argv[i];
    auto val = [&](const char *what) -> const char * {
      if (i + 1 >= argc) die("missing value for %s", what);
      return argv[++i];
    };
    if (k == "--op") a.op = val("--op");
    else if (k == "--pages") a.pages = parse_num(val("--pages"), "--pages");
    else if (k == "--page-offset") a.page_offset = parse_num(val("--page-offset"), "--page-offset");
    else if (k == "--stride") a.stride = parse_num(val("--stride"), "--stride");
    else if (k == "--passes") a.passes = int(parse_num(val("--passes"), "--passes"));
    else if (k == "--shuffle") a.shuffle = true;
    else if (k == "--cpu") a.cpu = int(parse_num(val("--cpu"), "--cpu"));
    else if (k == "--role") a.role = int(parse_num(val("--role"), "--role"));
    else if (k == "--nodes") a.nodes = int(parse_num(val("--nodes"), "--nodes"));
    else if (k == "--nonce") a.nonce = parse_num(val("--nonce"), "--nonce");
    else if (k == "--iters") a.iters = parse_num(val("--iters"), "--iters");
    else if (k == "--out") a.out = val("--out");
    else if (k == "--raw") a.raw = val("--raw");
    else if (k == "--config") a.config = val("--config");
    else if (k == "--init-state") a.init_state = val("--init-state");
    else if (k == "--device-size") a.device_size = parse_num(val("--device-size"), "--device-size");
    else if (k == "--pattern") { a.pattern = parse_num(val("--pattern"), "--pattern"); a.has_pattern = true; }
    else if (k == "--expect") { a.expect = parse_num(val("--expect"), "--expect"); a.has_expect = true; }
    else if (k == "--node") a.node = int(parse_num(val("--node"), "--node"));
    else if (k == "--threads") a.threads = uint32_t(parse_num(val("--threads"), "--threads"));
    else if (k == "--read-pct") a.read_pct = int(parse_num(val("--read-pct"), "--read-pct"));
    else if (k == "--duration-s") a.duration_s = atof(val("--duration-s"));
    else if (k == "--dist") a.dist = val("--dist");
    else if (k == "--zipf-theta") a.zipf_theta = atof(val("--zipf-theta"));
    else if (k == "--run-id") a.run_id = parse_num(val("--run-id"), "--run-id");
    else if (k == "--salt") { a.salt = parse_num(val("--salt"), "--salt"); a.has_salt = true; }
    else if (k == "--skip-init") a.skip_init = true;
    else if (k == "--init-only") a.init_only = true;
    else if (k == "--app-bytes") a.app_bytes = true;
    else if (k == "--watchdog-s") a.watchdog_s = atof(val("--watchdog-s"));
    else if (k == "--interval-ms") a.interval_ms = parse_num(val("--interval-ms"), "--interval-ms");
    else if (k == "--barrier-timeout-s") a.barrier_timeout_s = atof(val("--barrier-timeout-s"));
    else if (k == "--think-ns") a.think_ns = parse_num(val("--think-ns"), "--think-ns");
    else if (k == "--cpu-list") a.cpu_list = val("--cpu-list");
    else if (k == "--no-abort") a.abort_on_violation = false;
    else if (k == "--no-swmr-probe") a.swmr_probe = false;
    else if (k == "--seed") a.seed = parse_num(val("--seed"), "--seed");
    else if (k == "--inject") a.inject = val("--inject");
    else if (k == "--max-ops") a.max_ops = parse_num(val("--max-ops"), "--max-ops");
    else if (k == "--churn-us") a.churn_us = parse_num(val("--churn-us"), "--churn-us");
    else die("unknown option %s", k.c_str());
  }
  if (a.stride == 0 || a.pages == 0 || a.passes < 1) die("--pages, --stride, --passes must be > 0");
  return a;
}

cxl::region load_region(const Args &a) {
  cxl::region r;
  std::string err;
  if (!cxl::region_load(a.config.empty() ? nullptr : a.config.c_str(), &r, &err, a.device_size))
    die("region config: %s", err.c_str());
  return r;
}

// ---------------------------------------------------------------------------
// Kernel counters (read-only sysfs)

std::map<std::string, std::string> read_sysfs() {
  std::map<std::string, std::string> m;
  DIR *d = opendir(kSysfs);
  if (!d) return m;
  while (struct dirent *e = readdir(d)) {
    if (e->d_name[0] == '.' || !strcmp(e->d_name, "reset_counters")) continue;
    std::ifstream f(std::string(kSysfs) + "/" + e->d_name);
    std::string v;
    if (f && std::getline(f, v)) m[e->d_name] = v;
  }
  closedir(d);
  return m;
}

bool is_number(const std::string &s) {
  return !s.empty() && std::all_of(s.begin(), s.end(), ::isdigit);
}

// ---------------------------------------------------------------------------
// Statistics

struct Summary {
  uint64_t n = 0, min = 0, max = 0;
  double mean = 0, stdev = 0;
  uint64_t p50 = 0, p90 = 0, p99 = 0, p999 = 0;
};

Summary summarize(std::vector<uint64_t> v) {
  Summary s;
  if (v.empty()) return s;
  std::sort(v.begin(), v.end());
  s.n = v.size();
  s.min = v.front();
  s.max = v.back();
  long double sum = 0, sq = 0;
  for (uint64_t x : v) sum += x;
  s.mean = double(sum / v.size());
  for (uint64_t x : v) sq += (x - s.mean) * (x - s.mean);
  s.stdev = v.size() > 1 ? std::sqrt(double(sq / (v.size() - 1))) : 0;
  auto pct = [&](double p) { return v[std::min<size_t>(v.size() - 1, size_t(p * v.size()))]; };
  s.p50 = pct(0.50);
  s.p90 = pct(0.90);
  s.p99 = pct(0.99);
  s.p999 = pct(0.999);
  return s;
}

// Log-linear histogram: 8 buckets per power of two, keyed by lower bound (ns).
std::map<uint64_t, uint64_t> histogram(const std::vector<uint64_t> &v) {
  std::map<uint64_t, uint64_t> h;
  for (uint64_t x : v) {
    if (x < 16) { h[x]++; continue; }
    int e = 63 - __builtin_clzll(x);
    uint64_t sub = (x >> (e - 3)) & 7;
    h[(8 + sub) << (e - 3)]++;
  }
  return h;
}

void json_summary(FILE *f, const char *name, const std::vector<uint64_t> &v) {
  Summary s = summarize(v);
  fprintf(f, "    \"%s\": {\"count\": %" PRIu64 ", \"min_ns\": %" PRIu64 ", \"p50_ns\": %" PRIu64
             ", \"p90_ns\": %" PRIu64 ", \"p99_ns\": %" PRIu64 ", \"p999_ns\": %" PRIu64
             ", \"max_ns\": %" PRIu64 ", \"mean_ns\": %.1f, \"stdev_ns\": %.1f, \"hist\": [",
          name, s.n, s.min, s.p50, s.p90, s.p99, s.p999, s.max, s.mean, s.stdev);
  bool first = true;
  for (auto &kv : histogram(v)) {
    fprintf(f, "%s[%" PRIu64 ", %" PRIu64 "]", first ? "" : ", ", kv.first, kv.second);
    first = false;
  }
  fprintf(f, "]}");
}

// ---------------------------------------------------------------------------
// Mapping

struct Mapping {
  int fd = -1;
  uint8_t *base = nullptr;
  uint64_t len = 0;
  uint64_t dev_offset = 0;
};

Mapping map_window(const cxl::region &r, uint64_t first_page, uint64_t npages) {
  Mapping m;
  uint64_t off = r.swcc.offset + first_page * kPage;
  m.len = npages * kPage;
  if (first_page + npages > r.swcc.size / kPage)
    die("window [page %" PRIu64 ", +%" PRIu64 ") exceeds swcc (%" PRIu64 " pages)",
        first_page, npages, r.swcc.size / kPage);
  m.fd = open(r.device.c_str(), O_RDWR);
  if (m.fd < 0) die("open %s: %s", r.device.c_str(), strerror(errno));
  void *p = mmap(nullptr, m.len, PROT_READ | PROT_WRITE, MAP_SHARED, m.fd, off_t(off));
  if (p == MAP_FAILED) die("mmap %s offset %#" PRIx64 " len %#" PRIx64 ": %s",
                           r.device.c_str(), off, m.len, strerror(errno));
  m.base = static_cast<uint8_t *>(p);
  m.dev_offset = off;
  return m;
}

void pin_cpu(int cpu) {
  if (cpu < 0) return;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  if (sched_setaffinity(0, sizeof(set), &set)) die("sched_setaffinity(%d): %s", cpu, strerror(errno));
}

long minflt() {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return ru.ru_minflt;
}

void write_raw(const std::string &path, const std::vector<std::vector<uint64_t>> &passes) {
  if (path.empty()) return;
  FILE *f = fopen(path.c_str(), "w");
  if (!f) die("open %s: %s", path.c_str(), strerror(errno));
  fprintf(f, "pass,index,ns\n");
  for (size_t p = 0; p < passes.size(); p++)
    for (size_t i = 0; i < passes[p].size(); i++)
      fprintf(f, "%zu,%zu,%" PRIu64 "\n", p, i, passes[p][i]);
  fclose(f);
}

FILE *open_out(const std::string &path) {
  if (path.empty()) return stdout;
  FILE *f = fopen(path.c_str(), "w");
  if (!f) die("open %s: %s", path.c_str(), strerror(errno));
  return f;
}

void json_header(FILE *f, const Args &a, const cxl::region &r, const Mapping &m) {
  char host[256] = {};
  gethostname(host, sizeof(host) - 1);
  fprintf(f, "{\n  \"tool\": \"%s\",\n  \"cmd\": \"%s\",\n  \"host\": \"%s\",\n", kVersion,
          a.cmd.c_str(), host);
  fprintf(f, "  \"region\": \"%s\",\n", cxl::region_describe(r).c_str());
  fprintf(f, "  \"params\": {\"op\": \"%s\", \"pages\": %" PRIu64 ", \"page_offset\": %" PRIu64
             ", \"stride\": %" PRIu64 ", \"passes\": %d, \"shuffle\": %s, \"cpu\": %d, \"role\": %d, \"nodes\": %d"
             ", \"nonce\": %" PRIu64 ", \"iters\": %" PRIu64 ", \"dev_offset\": %" PRIu64 "},\n",
          a.op.c_str(), a.pages, a.page_offset, a.stride, a.passes, a.shuffle ? "true" : "false",
          a.cpu, a.role, a.nodes, a.nonce, a.iters, m.dev_offset);
}

void json_sysfs(FILE *f, const std::map<std::string, std::string> &before,
                const std::map<std::string, std::string> &after) {
  fprintf(f, "  \"kernel\": {");
  bool first = true;
  for (auto &kv : after) {
    auto it = before.find(kv.first);
    bool counter = kv.first.find("count") != std::string::npos ||
                   kv.first.find("time") != std::string::npos;
    if (counter && is_number(kv.second) && it != before.end() && is_number(it->second)) {
      long long d = std::stoll(kv.second) - std::stoll(it->second);
      fprintf(f, "%s\"%s_delta\": %lld", first ? "" : ", ", kv.first.c_str(), d);
    } else {
      fprintf(f, "%s\"%s\": \"%s\"", first ? "" : ", ", kv.first.c_str(), kv.second.c_str());
    }
    first = false;
  }
  fprintf(f, "}");
}

// ---------------------------------------------------------------------------
// Subcommands

// The message ring is `msg_ring: [offset, size]` in the region config: cxl_region.h requires it at the end of
// the HWcc range (hardware-coherent, so cxl_shm runs with ring_coherent=1).
int cmd_params(const Args &a) {
  cxl::region r = load_region(a);
  const cxl::range ring = r.msg_ring;
  if (ring.size == 0) die("region config has no msg_ring: [offset, size] key");
  // The ring must lie inside HWcc (hardware-coherent: ring_coherent=1).
  if (ring.size == 0 || ring.offset % 4096 || ring.size % 4096 || ring.offset < r.hwcc.offset ||
      ring.end() > r.hwcc.end())
    die("msg_ring [%" PRIu64 ", +%" PRIu64 ") must be 4 KiB aligned and inside hwcc [%" PRIu64 ", %" PRIu64 ")",
        ring.offset, ring.size, r.hwcc.offset, r.hwcc.end());
  // Same sizing rule as cxl_shm v7: a page-aligned header (2 lines per window + 3 lines per node), then
  // N*(N-1) directions x {request, response} windows of at least 256 64-byte slots.
  const uint64_t n = uint64_t(a.nodes), windows = n * (n - 1) * 2;
  if (a.nodes < 2 || a.nodes > 8) die("--nodes must be 2..8 (cxl_shm nr_nodes)");
  const uint64_t hdr = (windows * 2 * 64 + 3 * n * 64 + 4095) / 4096 * 4096;
  if (a.init_state != "invalid" && a.init_state != "shared") die("--init-state must be invalid or shared");
  const uint64_t need = hdr + windows * 256 * 64;
  if (ring.size < need)
    die("msg_ring size %" PRIu64 " too small for %d nodes: need >= %" PRIu64, ring.size, a.nodes, need);
  // Managed (MSI) range = exactly swcc; it must not touch hwcc (app + msg_ring + system part).
  if (r.swcc.offset < r.hwcc.end() && r.hwcc.offset < r.swcc.end()) die("swcc overlaps hwcc");
  std::string dev = r.device.substr(r.device.rfind('/') + 1);
  printf("dax_name=%s nr_nodes=%d ring_offset=%" PRIu64 " ring_size=%" PRIu64 " ring_coherent=1 managed_offset=%" PRIu64
         " managed_size=%" PRIu64 " init_state=%s\n",
         dev.c_str(), a.nodes, ring.offset, ring.size, r.swcc.offset, r.swcc.size, a.init_state.c_str());
  return 0;
}

// One access per page (one fault per page if the page is not mapped with
// the needed permission).  Pass 0 normally faults; later passes show the
// no-fault access cost unless a peer revoked the pages in between.
int cmd_access(const Args &a) {
  // "rw": read every page, then write every page, in the same process, so
  // the writes take the write-protect (pfn_mkwrite) fault on S pages.
  std::vector<bool> ops;
  if (a.op == "read") ops = {false};
  else if (a.op == "write") ops = {true};
  else if (a.op == "rw") ops = {false, true};
  else die("--op must be read, write or rw");
  cxl::region r = load_region(a);
  uint64_t span = (a.pages - 1) * a.stride + 1;
  pin_cpu(a.cpu);
  auto sys_before = read_sysfs();
  Mapping m = map_window(r, a.page_offset, span);

  std::vector<uint64_t> order(a.pages);
  for (uint64_t i = 0; i < a.pages; i++) order[i] = i * a.stride;
  if (a.shuffle) std::shuffle(order.begin(), order.end(), std::mt19937_64(a.nonce ? a.nonce : 42));

  size_t nsteps = size_t(a.passes) * ops.size();
  std::vector<std::vector<uint64_t>> lat(nsteps, std::vector<uint64_t>(a.pages));
  std::vector<long> faults(nsteps);
  std::vector<std::string> names(nsteps);
  volatile uint64_t sink = 0;
  // Data check (--pattern / --expect): writes store X ^ page index in the first and last word of the page;
  // reads compare both words with the expected value.
  uint64_t checked = 0, mismatches = 0;
  std::string first_bad;
  for (size_t st = 0; st < nsteps; st++) {
    int pass = int(st / ops.size());
    bool write = ops[st % ops.size()];
    names[st] = "pass" + std::to_string(pass) + (write ? "_write" : "_read");
    long f0 = minflt();
    for (uint64_t i = 0; i < a.pages; i++) {
      volatile uint64_t *w = reinterpret_cast<volatile uint64_t *>(m.base + order[i] * kPage);
      volatile uint64_t *wl = w + kPage / sizeof(uint64_t) - 1;
      const uint64_t page = a.page_offset + order[i];
      uint64_t t0 = now_ns(), v = 0, vl = 0;
      if (write) {
        if (a.has_pattern) {
          *w = a.pattern ^ page;
          *wl = a.pattern ^ page;
        } else {
          *w = (uint64_t(pass) << 32) | i;
        }
      } else {
        v = *w;
        if (a.has_expect) vl = *wl;
        sink = sink + v;
      }
      lat[st][i] = now_ns() - t0;
      if (!write && a.has_expect) {
        checked++;
        if (v != (a.expect ^ page) || vl != (a.expect ^ page)) {
          if (!mismatches++) {
            char buf[160];
            snprintf(buf, sizeof(buf), "page %" PRIu64 ": first %#" PRIx64 " last %#" PRIx64 " expected %#" PRIx64,
                     page, v, vl, a.expect ^ page);
            first_bad = buf;
          }
        }
      }
    }
    faults[st] = minflt() - f0;
  }
  (void)sink;
  auto sys_after = read_sysfs();

  FILE *f = open_out(a.out);
  json_header(f, a, r, m);
  fprintf(f, "  \"passes\": {\n");
  for (size_t st = 0; st < nsteps; st++) {
    json_summary(f, names[st].c_str(), lat[st]);
    fprintf(f, ",\n    \"%s_minflt\": %ld%s\n", names[st].c_str(), faults[st],
            st + 1 < nsteps ? "," : "");
  }
  fprintf(f, "  },\n");
  if (a.has_pattern || a.has_expect)
    fprintf(f, "  \"verify\": {\"pattern\": %s, \"expect\": %s, \"checked\": %" PRIu64 ", \"mismatches\": %" PRIu64
               ", \"first_mismatch\": \"%s\"},\n",
            a.has_pattern ? std::to_string(a.pattern).c_str() : "null",
            a.has_expect ? std::to_string(a.expect).c_str() : "null", checked, mismatches, first_bad.c_str());
  json_sysfs(f, sys_before, sys_after);
  fprintf(f, "\n}\n");
  if (f != stdout) fclose(f);
  write_raw(a.raw, lat);
  munmap(m.base, m.len);
  close(m.fd);
  if (mismatches) {
    fprintf(stderr, "faultlat: DATA MISMATCH in %" PRIu64 " of %" PRIu64 " pages (%s)\n", mismatches, checked,
            first_bad.c_str());
    return 2;
  }
  return 0;
}

// Token ring on one managed page between N nodes (N=2: ping-pong).  Role r
// waits for turn == r, then hands the turn to (r+1) % N.  Each hand-off is a
// write on a page other nodes hold (write-on-I/S: invalidates all N-1 peers)
// and the next role's read faults on I (read-on-I: the writer downgrades).
// Role 0 records the time for the token to go once around the ring
// (N hand-offs).
struct PingPage {
  volatile uint64_t nonce;
  volatile uint64_t turn;     // role whose turn it is
  volatile uint64_t seq;      // hand-offs so far
};

int cmd_pingpong(const Args &a) {
  if (a.nodes < 2 || a.nodes > 64) die("--nodes must be 2..64");
  if (a.role < 0 || a.role >= a.nodes) die("--role 0..nodes-1 is required");
  if (!a.nonce) die("--nonce (non-zero, same on both nodes, new per run) is required");
  cxl::region r = load_region(a);
  pin_cpu(a.cpu);
  auto sys_before = read_sysfs();
  Mapping m = map_window(r, a.page_offset, 1);
  PingPage *pg = reinterpret_cast<PingPage *>(m.base);
  uint64_t me = uint64_t(a.role), other = (me + 1) % uint64_t(a.nodes);
  const uint64_t timeout_ns = 60ull * 1000000000ull;

  // Start: role 0 publishes the nonce and hands the turn to role 1.
  if (me == 0) {
    pg->turn = uint64_t(a.nodes);  // nobody's turn while (re)initializing
    pg->seq = 0;
    pg->nonce = a.nonce;
    pg->turn = 1;
  }
  uint64_t t_start = now_ns();
  while (pg->nonce != a.nonce)
    if (now_ns() - t_start > timeout_ns) die("peer did not start within 60 s");

  std::vector<uint64_t> rtt;
  rtt.reserve(a.iters);
  // Coherence check: role 1 moves first, so at role r's i-th turn seq must be i*N + (r-1 mod N) (every earlier
  // hand-off's increment is visible).
  const uint64_t N = uint64_t(a.nodes), first = (me + N - 1) % N;
  uint64_t seq_errors = 0;
  std::string first_bad;
  long f0 = minflt();
  uint64_t t_handoff = now_ns();
  for (uint64_t i = 0; i < a.iters; i++) {
    uint64_t t_wait = now_ns();
    while (pg->turn != me)
      if (now_ns() - t_wait > timeout_ns) die("timeout waiting for turn at iteration %" PRIu64, i);
    uint64_t t = now_ns();
    if (me == 0 && i > 0) rtt.push_back(t - t_handoff);
    const uint64_t seq = pg->seq;
    if (seq != i * N + first && !seq_errors++) {
      char buf[128];
      snprintf(buf, sizeof(buf), "iteration %" PRIu64 ": seq %" PRIu64 " expected %" PRIu64, i, seq, i * N + first);
      first_bad = buf;
    }
    pg->seq = seq + 1;
    t_handoff = now_ns();
    pg->turn = other;
  }
  long faults = minflt() - f0;
  auto sys_after = read_sysfs();

  FILE *f = open_out(a.out);
  json_header(f, a, r, m);
  fprintf(f, "  \"passes\": {\n");
  json_summary(f, "round_trip", rtt);
  fprintf(f, ",\n    \"minflt\": %ld, \"final_seq\": %" PRIu64 ", \"seq_errors\": %" PRIu64
             ", \"first_seq_error\": \"%s\"\n  },\n",
          faults, uint64_t(pg->seq), seq_errors, first_bad.c_str());
  json_sysfs(f, sys_before, sys_after);
  fprintf(f, "\n}\n");
  if (f != stdout) fclose(f);
  write_raw(a.raw, {rtt});
  munmap(m.base, m.len);
  close(m.fd);
  if (seq_errors) {
    fprintf(stderr, "faultlat: SEQUENCE ERROR in %" PRIu64 " of %" PRIu64 " turns (%s)\n", seq_errors, a.iters,
            first_bad.c_str());
    return 2;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// contend: high-contention MSI correctness / liveness stress (README.md "contend", contend.h for the data
// invariant).  T threads per node pick pages of an H-page hot set (uniform or zipf) and read (descending scan
// + check) or write (ascending stamp) whole pages.  Cross-node coordination lives in the HWcc app range
// (hwcc_app.h: header + run_id handshake, phases, abort word, per-thread progress lines, final last-seq table);
// the hot set is the only managed (SWcc) memory touched.

namespace ct = contend;

struct alignas(64) CtlLine {
  uint64_t abort;  // 0, or reason << 8 | (node + 1); first setter wins (cas)
  uint64_t pad[7];
};
struct alignas(64) NodeLine {
  uint64_t phase;  // written by its node only (release)
  uint64_t pad[7];
};
struct alignas(64) ThreadLine {  // written by its thread only
  uint64_t ops;   // completed ops (release)
  uint64_t cur;   // in-flight op: 0 idle, else (page + 1) << 1 | write
  uint64_t seq;   // writer's last seq
  uint64_t pad[5];
};
static_assert(sizeof(CtlLine) == 64 && sizeof(NodeLine) == 64 && sizeof(ThreadLine) == 64, "one line each");

enum : uint64_t { kAbViolation = 1, kAbWatchdog = 2, kAbSigbus = 3, kAbCoord = 4 };
const char *abort_name(uint64_t w) {
  switch (w >> 8) {
    case kAbViolation: return "violation";
    case kAbWatchdog: return "watchdog";
    case kAbSigbus: return "sigbus";
    case kAbCoord: return "coordination";
    default: return w ? "unknown" : "none";
  }
}

struct ContendLayout {
  cxl::hwcc::layout L;
  uint64_t ctl = 0, nodes = 0, threads = 0, last = 0;
};
ContendLayout contend_layout(const Args &a) {
  ContendLayout c;
  const uint64_t N = uint64_t(a.nodes), T = a.threads, H = a.pages;
  c.ctl = c.L.add("contend.ctl", 64);
  c.nodes = c.L.add("contend.node_lines", N * 64);
  c.threads = c.L.add("contend.thread_lines", N * T * 64);
  c.last = c.L.add("contend.last_seq", N * T * H * 8);
  // Parameters that must be identical on every node (the read ratio may differ per node).
  char p[256];
  snprintf(p, sizeof(p), "contend.params T=%" PRIu64 " H=%" PRIu64 " P=%" PRIu64 " D=%.3f salt=%" PRIu64 " skip=%d",
           T, H, a.page_offset, a.duration_s, a.salt, int(a.skip_init));
  c.L.add(p, 64);
  return c;
}

std::vector<int> parse_cpu_list(const std::string &s) {
  std::vector<int> v;
  size_t i = 0;
  while (i < s.size()) {
    size_t j = s.find(',', i);
    if (j == std::string::npos) j = s.size();
    std::string tok = s.substr(i, j - i);
    size_t dash = tok.find('-');
    if (dash == std::string::npos) {
      v.push_back(int(parse_num(tok.c_str(), "--cpu-list")));
    } else {
      int lo = int(parse_num(tok.substr(0, dash).c_str(), "--cpu-list"));
      int hi = int(parse_num(tok.substr(dash + 1).c_str(), "--cpu-list"));
      for (int c = lo; c <= hi; c++) v.push_back(c);
    }
    i = j + 1;
  }
  return v;
}

// SIGBUS: async-signal-safe report, abort word for the peer, exit 4 (no JSON).
CtlLine *g_ctl = nullptr;
int g_node = 0;
void put_hex(char *&p, uint64_t x) {
  *p++ = '0';
  *p++ = 'x';
  for (int sh = 60; sh >= 0; sh -= 4) *p++ = "0123456789abcdef"[(x >> sh) & 15];
}
void on_sigbus(int, siginfo_t *si, void *) {
  char b[128], *p = b;
  const char *m = "faultlat contend: SIGBUS at ";
  while (*m) *p++ = *m++;
  put_hex(p, uint64_t(uintptr_t(si->si_addr)));
  const char *m2 = " tid ";
  while (*m2) *p++ = *m2++;
  put_hex(p, uint64_t(gettid()));
  *p++ = '\n';
  ssize_t r = write(2, b, size_t(p - b));
  (void)r;
  if (g_ctl) {
    uint64_t z = 0;
    __atomic_compare_exchange_n(&g_ctl->abort, &z, (kAbSigbus << 8) | uint64_t(g_node + 1), false, __ATOMIC_ACQ_REL,
                                __ATOMIC_ACQUIRE);
  }
  _exit(4);
}

struct Worker {
  uint32_t t = 0, wid = 0;
  pid_t tid = 0;
  ct::Hist hr, hw;
  uint64_t reads = 0, writes = 0, seq = 0;
  uint64_t cur_t0 = 0;  // in-flight op start (local clock; 0 idle), relaxed
  ct::Violations viol;
  std::vector<uint64_t> last;  // last seq written per hot-set page
  uint64_t probe_checks = 0, probe_faulted = 0;
  long faults = 0;  // RUSAGE_THREAD minflt of this worker (set when it exits its loop)
  bool exited = false;
  // monitor-owned
  uint64_t prev_ops = 0, starve = 0, zero_streak = 0, max_zero_streak = 0;
};

void json_hist(FILE *f, const char *name, const ct::Hist &h) {
  fprintf(f, "\"%s\": {\"count\": %" PRIu64 ", \"p50_ns\": %" PRIu64 ", \"p99_ns\": %" PRIu64 ", \"p999_ns\": %" PRIu64
             ", \"max_ns\": %" PRIu64 ", \"mean_ns\": %.1f, \"hist\": [",
          name, h.n, h.quantile(0.5), h.quantile(0.99), h.quantile(0.999), h.max, h.n ? double(h.sum) / h.n : 0.0);
  bool first = true;
  for (int i = 0; i < ct::Hist::kBuckets; i++)
    if (h.b[i]) {
      fprintf(f, "%s[%" PRIu64 ", %" PRIu64 "]", first ? "" : ", ", ct::Hist::upper(i), h.b[i]);
      first = false;
    }
  fprintf(f, "]}");
}

std::string proc_task(pid_t tid, const char *what) {
  std::ifstream f("/proc/self/task/" + std::to_string(tid) + "/" + what);
  std::string s, line;
  while (f && std::getline(f, line)) s += line + "\\n";
  for (auto &c : s)
    if (c == '"') c = '\'';
  return s;
}

struct ContendRun {
  const Args *a = nullptr;
  cxl::region r;
  Mapping win, app;
  ContendLayout lay;
  CtlLine *ctl = nullptr;
  NodeLine *nodes = nullptr;
  ThreadLine *tl = nullptr;   // [node * T + t]
  uint64_t *lastseq = nullptr;  // [(node * T + t) * H + page]
  std::vector<Worker> w;
  std::atomic<bool> stop{false};
  std::atomic<bool> go{false};  // in-process start gate: all workers start together
  std::atomic<uint64_t> guard_deadline{0};  // post-run guard (0 = off)
  std::atomic<const char *> guard_phase{""};
  std::atomic<uint32_t> ready{0};
  // churn thread (--churn-us): madvise(MADV_DONTNEED) + fresh-VMA map/read/check/unmap on hot-set pages
  uint64_t churn_dontneed = 0, churn_remaps = 0, churn_errors = 0;
  ct::Violations churn_viol;
  std::string churn_first_error;
  std::map<std::string, std::string> sys_before;
  uint64_t t_start = 0, t_end = 0;
  long minflt0 = 0;
  // monitor
  std::vector<std::pair<uint64_t, uint64_t>> timeline;  // per interval: local ops, peer ops
  uint64_t intervals = 0, node_stall = 0, global_stall = 0, peer_zero = 0, peer_max_zero = 0, peer_ops = 0;
  uint64_t abort_seen = 0;
  bool final_done = false;
  uint64_t final_ns = 0;
  ct::Violations final_viol;
  std::string status = "ok", watchdog_dump;
  int exit_code = 0;

  uint32_t N() const { return uint32_t(a->nodes); }
  uint32_t T() const { return a->threads; }
  uint64_t H() const { return a->pages; }
  ThreadLine &line(uint32_t node, uint32_t t) { return tl[node * T() + t]; }

  void set_abort(uint64_t reason) {
    uint64_t z = 0;
    cxl::hwcc::cas(&ctl->abort, &z, (reason << 8) | uint64_t(a->node + 1));
  }
  uint64_t abort_word() const { return cxl::hwcc::load_acquire(&ctl->abort); }

  // All nodes reach phase ph (or abort / timeout).  Returns false on abort or timeout.
  bool barrier(uint64_t ph) {
    cxl::hwcc::store_release(&nodes[a->node].phase, ph);
    bool ok = cxl::hwcc::poll_until(
        [&] {
          if (abort_word()) return true;
          for (uint32_t k = 0; k < N(); k++)
            if (cxl::hwcc::load_acquire(&nodes[k].phase) < ph) return false;
          return true;
        },
        uint64_t(a->barrier_timeout_s * 1000));
    if (!ok) {
      fprintf(stderr, "faultlat contend: node %d: barrier %" PRIu64 " timed out after %.0f s\n", a->node, ph,
              a->barrier_timeout_s);
      return false;
    }
    return !abort_word();
  }

  void write_json(const char *path_out);
};

void ContendRun::write_json(const char *path_out) {
  FILE *f = open_out(path_out ? path_out : "");
  char host[256] = {};
  gethostname(host, sizeof(host) - 1);
  const Args &A = *a;
  fprintf(f, "{\n  \"tool\": \"%s\",\n  \"cmd\": \"contend\",\n  \"host\": \"%s\",\n", kVersion, host);
  fprintf(f, "  \"region\": \"%s\",\n", cxl::region_describe(r).c_str());
  fprintf(f, "  \"params\": {\"node\": %d, \"nodes\": %d, \"threads\": %u, \"pages\": %" PRIu64 ", \"page_offset\": %" PRIu64
             ", \"dev_offset\": %" PRIu64 ", \"read_pct\": %d, \"dist\": \"%s\", \"zipf_theta\": %.3f, \"duration_s\": %.3f"
             ", \"run_id\": %" PRIu64 ", \"salt\": %" PRIu64 ", \"skip_init\": %s, \"watchdog_s\": %.1f, \"interval_ms\": %" PRIu64
             ", \"think_ns\": %" PRIu64 ", \"cpu_list\": \"%s\", \"abort_on_violation\": %s, \"swmr_probe\": %s"
             ", \"inject\": \"%s\", \"app_offset\": %" PRIu64 ", \"app_layout_bytes\": %" PRIu64 ", \"app_layout_hash\": %" PRIu64
             ", \"seed\": %" PRIu64 ", \"max_ops\": %" PRIu64 ", \"churn_us\": %" PRIu64 "},\n",
          A.node, A.nodes, A.threads, A.pages, A.page_offset, win.dev_offset, A.read_pct, A.dist.c_str(), A.zipf_theta,
          A.duration_s, A.run_id, A.salt, A.skip_init ? "true" : "false", A.watchdog_s, A.interval_ms, A.think_ns,
          A.cpu_list.c_str(), A.abort_on_violation ? "true" : "false",
          (A.swmr_probe && T() == 1 && N() > 1) ? "true" : "false", A.inject.c_str(), r.app.offset, lay.L.bytes(),
          lay.L.hash(), A.seed, A.max_ops, A.churn_us);
  ct::Hist all, rd, wr;
  ct::Violations v;
  uint64_t reads = 0, writes = 0, starve = 0, max_zero = 0, probe_checks = 0, probe_faulted = 0;
  uint64_t ops_min = UINT64_MAX, ops_max = 0;
  double s1 = 0, s2 = 0;
  long faults = 0;
  for (auto &x : w) {
    const uint64_t o = __atomic_load_n(&x.reads, __ATOMIC_RELAXED) + __atomic_load_n(&x.writes, __ATOMIC_RELAXED);
    ops_min = std::min(ops_min, o);
    ops_max = std::max(ops_max, o);
    s1 += double(o);
    s2 += double(o) * double(o);
    faults += x.faults;
    rd.merge(x.hr);
    wr.merge(x.hw);
    reads += __atomic_load_n(&x.reads, __ATOMIC_RELAXED);
    writes += __atomic_load_n(&x.writes, __ATOMIC_RELAXED);
    starve += x.starve;
    max_zero = std::max(max_zero, x.max_zero_streak);
    for (int k = 0; k < ct::kNumKinds; k++) v.count[k] += x.viol.count[k];
    for (auto &e : x.viol.first)
      if (v.first.size() < 16) v.first.push_back(e);
    probe_checks += x.probe_checks;
    probe_faulted += x.probe_faulted;
  }
  for (const ct::Violations *o : {&final_viol, &churn_viol}) {
    for (int k = 0; k < ct::kNumKinds; k++) v.count[k] += o->count[k];
    for (auto &e : o->first)
      if (v.first.size() < 16) v.first.push_back(e);
  }
  const double jain = s2 > 0 ? s1 * s1 / (double(w.size()) * s2) : 0;
  if (w.empty()) ops_min = 0;
  all.merge(rd);
  all.merge(wr);
  const uint64_t end = t_end ? t_end : now_ns();
  const double run_s = t_start ? double(end - t_start) / 1e9 : 0;
  fprintf(f, "  \"result\": {\"status\": \"%s\", \"exit_code\": %d, \"abort_word\": %" PRIu64 ", \"abort_reason\": \"%s\""
             ", \"abort_node\": %d, \"run_s\": %.3f, \"ops\": %" PRIu64 ", \"reads\": %" PRIu64 ", \"writes\": %" PRIu64
             ", \"ops_per_s\": %.1f, \"peer_ops\": %" PRIu64 ", \"minflt\": %ld,\n    ",
          status.c_str(), exit_code, abort_seen, abort_name(abort_seen), abort_seen ? int(abort_seen & 0xff) - 1 : -1,
          run_s, reads + writes, reads, writes, run_s > 0 ? double(reads + writes) / run_s : 0.0, peer_ops,
          minflt() - minflt0);
  json_hist(f, "lat_all", all);
  fprintf(f, ",\n    ");
  json_hist(f, "lat_read", rd);
  fprintf(f, ",\n    ");
  json_hist(f, "lat_write", wr);
  fprintf(f, ",\n    \"thread_ops_min\": %" PRIu64 ", \"thread_ops_max\": %" PRIu64 ", \"jain_fairness\": %.4f"
             ", \"worker_faults\": %ld, \"faults_per_op\": %.3f,\n",
          ops_min, ops_max, jain, faults, reads + writes ? double(faults) / double(reads + writes) : 0.0);
  fprintf(f, "    \"churn\": {\"dontneed\": %" PRIu64 ", \"remaps\": %" PRIu64 ", \"errors\": %" PRIu64 ", \"first_error\": \"%s\"},\n",
          churn_dontneed, churn_remaps, churn_errors, churn_first_error.c_str());
  fprintf(f, "    \"intervals\": %" PRIu64 ", \"starvation_samples\": %" PRIu64 ", \"node_stall_samples\": %" PRIu64
             ", \"global_stall_samples\": %" PRIu64 ", \"max_thread_zero_ms\": %" PRIu64 ", \"peer_zero_samples\": %" PRIu64
             ", \"peer_max_zero_ms\": %" PRIu64 ",\n",
          intervals, starve, node_stall, global_stall, max_zero * A.interval_ms, peer_zero,
          peer_max_zero * A.interval_ms);
  fprintf(f, "    \"violations\": {\"total\": %" PRIu64, v.total());
  for (int k = 0; k < ct::kNumKinds; k++) fprintf(f, ", \"%s\": %" PRIu64, ct::kind_name(k), v.count[k]);
  fprintf(f, ", \"first\": [");
  for (size_t i = 0; i < v.first.size(); i++) fprintf(f, "%s\"%s\"", i ? ", " : "", v.first[i].str().c_str());
  fprintf(f, "]},\n    \"final_check\": {\"done\": %s, \"pages\": %" PRIu64 ", \"violations\": %" PRIu64 "},\n",
          final_done ? "true" : "false", H(), final_viol.total());
  fprintf(f, "    \"swmr_probe\": {\"enabled\": %s, \"checks\": %" PRIu64 ", \"faulted_scans\": %" PRIu64 "}\n  },\n",
          (A.swmr_probe && T() == 1 && N() > 1) ? "true" : "false", probe_checks, probe_faulted);
  fprintf(f, "  \"threads\": [");
  for (size_t i = 0; i < w.size(); i++) {
    const Worker &x = w[i];
    fprintf(f, "%s\n    {\"t\": %u, \"writer\": %u, \"tid\": %d, \"reads\": %" PRIu64 ", \"writes\": %" PRIu64
               ", \"starvation_samples\": %" PRIu64 ", \"max_zero_ms\": %" PRIu64 ", \"read_p99_ns\": %" PRIu64
               ", \"read_max_ns\": %" PRIu64 ", \"write_p99_ns\": %" PRIu64 ", \"write_max_ns\": %" PRIu64
               ", \"faults\": %ld, \"violations\": %" PRIu64 "}",
            i ? "," : "", x.t, x.wid, int(x.tid), __atomic_load_n(&x.reads, __ATOMIC_RELAXED),
            __atomic_load_n(&x.writes, __ATOMIC_RELAXED), x.starve, x.max_zero_streak * A.interval_ms,
            x.hr.quantile(0.99), x.hr.max, x.hw.quantile(0.99), x.hw.max, x.faults, x.viol.total());
  }
  fprintf(f, "\n  ],\n  \"watchdog\": %s%s%s,\n", watchdog_dump.empty() ? "null" : "\"",
          watchdog_dump.c_str(), watchdog_dump.empty() ? "" : "\"");
  if (sys_before.empty() && read_sysfs().empty()) {
    fprintf(f, "  \"kernel\": {}\n}\n");
  } else {
    json_sysfs(f, sys_before, read_sysfs());
    fprintf(f, "\n}\n");
  }
  if (f != stdout) fclose(f);
  if (!a->raw.empty()) {
    FILE *g = fopen(a->raw.c_str(), "w");
    if (g) {
      fprintf(g, "interval,t_ms,local_ops,peer_ops\n");
      for (size_t i = 0; i < timeline.size(); i++)
        fprintf(g, "%zu,%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", i, uint64_t(i + 1) * A.interval_ms, timeline[i].first,
                timeline[i].second);
      fclose(g);
    }
  }
}

uint64_t contend_seed(uint64_t a, uint64_t b) { return contend::splitmix(a ^ contend::splitmix(b)); }

// Test-only fault injection (--inject kind:N): node 0, thread 0, at its N-th write.
struct Inject {
  std::string kind;
  uint64_t n = 0;
};
Inject parse_inject(const std::string &s) {
  Inject j;
  if (s.empty()) return j;
  size_t c = s.find(':');
  if (c == std::string::npos) die("--inject kind:N");
  j.kind = s.substr(0, c);
  j.n = parse_num(s.substr(c + 1).c_str(), "--inject");
  if (j.kind != "stale" && j.kind != "corrupt" && j.kind != "lost" && j.kind != "stall" && j.kind != "sigbus")
    die("--inject kind must be stale, corrupt, lost, stall or sigbus");
  return j;
}

void contend_worker(ContendRun *R, uint32_t t, const std::vector<int> *cpus, Inject inj) {
  const Args &A = *R->a;
  Worker &W = R->w[t];
  W.tid = gettid();
  if (!cpus->empty()) pin_cpu((*cpus)[t % cpus->size()]);
  const uint64_t H = R->H();
  const bool partition = A.dist == "partition";
  ct::Picker pick(H, A.dist == "zipf", A.zipf_theta);
  // partition: writer w owns pages [w*K, (w+1)*K), K = H / (nodes*threads), walked in order (fresh pages first)
  const uint64_t K = partition ? H / (uint64_t(R->N()) * R->T()) : 0, pbase = uint64_t(W.wid) * K;
  // Checker floors (pages x writers) only when this node reads; partition: only the thread's own K pages.
  const uint64_t CH = partition ? K : H, cbase = partition ? pbase : 0;
  std::unique_ptr<ct::Checker> chk(A.read_pct > 0 ? new ct::Checker(CH, R->N() * R->T()) : nullptr);
  const bool probe_on = A.swmr_probe && R->T() == 1 && R->N() > 1 && A.read_pct > 0;
  std::unique_ptr<ct::SwmrProbe> probe(probe_on ? new ct::SwmrProbe(CH, R->T(), uint32_t(A.node)) : nullptr);
  std::mt19937_64 rng(contend_seed(A.seed ? A.seed : A.run_id, uint64_t(A.node) * 100000 + t));
  ThreadLine &L = R->line(uint32_t(A.node), t);
  const bool inject_here = !inj.kind.empty() && A.node == 0 && t == 0;
  uint64_t buf[ct::kWords];
  uint64_t ops = 0;
  int64_t forced_read = -1;  // test injection: re-read the injected page next (deterministic detection)
  struct rusage ruw0;
  R->ready.fetch_add(1);
  while (!R->go.load(std::memory_order_acquire)) _mm_pause();
  getrusage(RUSAGE_THREAD, &ruw0);
  while (!R->stop.load(std::memory_order_relaxed) && (!A.max_ops || ops < A.max_ops)) {
    uint64_t page = partition ? pbase + ops % K : pick.pick(rng());
    bool write = int(rng() % 100) >= A.read_pct;
    if (forced_read >= 0) {
      page = uint64_t(forced_read);
      write = false;
      forced_read = -1;
    }
    const uint64_t page_abs = A.page_offset + page;
    volatile uint64_t *pg = reinterpret_cast<volatile uint64_t *>(R->win.base + page * kPage);
    cxl::hwcc::store_relaxed(&L.cur, ((page + 1) << 1) | uint64_t(write));
    if (write) {
      const uint64_t s = ++W.seq;
      cxl::hwcc::store_relaxed(&L.seq, s);
      const bool inj_now = inject_here && W.writes + 1 == inj.n;
      const uint64_t t0 = now_ns();
      __atomic_store_n(&W.cur_t0, t0, __ATOMIC_RELAXED);
      if (inj_now && inj.kind == "stall") {
        for (;;) sleep(3600);  // simulates an op stuck in a fault
      }
      if (inj_now && inj.kind == "sigbus") raise(SIGBUS);
      if (!(inj_now && inj.kind == "lost")) ct::write_page(pg, A.salt, page_abs, W.wid, s);
      if (inj_now && inj.kind == "stale")
        pg[0] = ct::make_stamp(W.wid, s - 1) ^ ct::word_mask(ct::page_mask(A.salt, page_abs), 0);
      if (inj_now && inj.kind == "corrupt") pg[7] = 0xdeadbeefdeadbeefull;
      if (inj_now && (inj.kind == "stale" || inj.kind == "corrupt") && chk) forced_read = int64_t(page);
      const uint64_t dt = now_ns() - t0;
      W.hw.add(dt);
      W.last[page] = s;
      if (chk) chk->own_write(page - cbase, W.wid, s);
      if (probe) probe->own_write(page - cbase);
      __atomic_store_n(&W.writes, W.writes + 1, __ATOMIC_RELAXED);
      if (inj_now && inj.kind == "lost") {  // stop writing so the lost write stays the last one (deterministic test)
        __atomic_store_n(&W.cur_t0, uint64_t(0), __ATOMIC_RELAXED);
        cxl::hwcc::store_relaxed(&L.cur, uint64_t(0));
        cxl::hwcc::store_release(&L.ops, ++ops);
        while (!R->stop.load(std::memory_order_relaxed)) usleep(1000);
        break;
      }
    } else {
      struct rusage ru0, ru1;
      if (probe) getrusage(RUSAGE_THREAD, &ru0);
      const uint64_t t0 = now_ns();
      __atomic_store_n(&W.cur_t0, t0, __ATOMIC_RELAXED);
      ct::read_page(pg, buf);
      const uint64_t dt = now_ns() - t0;
      if (probe) getrusage(RUSAGE_THREAD, &ru1);
      W.hr.add(dt);
      uint64_t bad = chk->check_scan(buf, page - cbase, page_abs, A.salt, &W.viol);
      if (probe) {
        bad += probe->scan(buf, page - cbase, page_abs, A.salt, ru1.ru_minflt != ru0.ru_minflt, &W.viol);
        W.probe_checks = probe->checks;
        W.probe_faulted = probe->faulted_scans;
      }
      __atomic_store_n(&W.reads, W.reads + 1, __ATOMIC_RELAXED);
      if (bad && A.abort_on_violation) {
        R->set_abort(kAbViolation);
        R->stop.store(true);
      }
    }
    __atomic_store_n(&W.cur_t0, uint64_t(0), __ATOMIC_RELAXED);
    cxl::hwcc::store_relaxed(&L.cur, uint64_t(0));
    cxl::hwcc::store_release(&L.ops, ++ops);
    if (A.think_ns) {
      const uint64_t until = now_ns() + A.think_ns;
      while (now_ns() < until) _mm_pause();
    }
  }
  struct rusage ruw1;
  getrusage(RUSAGE_THREAD, &ruw1);
  W.faults = ruw1.ru_minflt - ruw0.ru_minflt;
  __atomic_store_n(&W.exited, true, __ATOMIC_RELEASE);
}

// Churn (--churn-us P): every P us, zap one random hot-set page from the main mapping (MADV_DONTNEED; the next
// access refaults), and every 8th time map that page through a fresh VMA, check it as a scan and unmap it.
// Exercises remote revocation against VMAs that come and go while the peer writes.
void contend_churn(ContendRun *R) {
  const Args &A = *R->a;
  const uint64_t H = R->H();
  std::mt19937_64 rng(contend_seed(A.seed ? A.seed : A.run_id, uint64_t(A.node) * 100000 + 99999));
  ct::Checker chk(H, R->N() * R->T());
  uint64_t buf[ct::kWords];
  while (!R->go.load(std::memory_order_acquire)) _mm_pause();
  for (uint64_t i = 0; !R->stop.load(std::memory_order_relaxed); i++) {
    const uint64_t page = rng() % H;
    if (madvise(R->win.base + page * kPage, kPage, MADV_DONTNEED)) {
      if (!R->churn_errors++) R->churn_first_error = std::string("madvise: ") + strerror(errno);
    } else {
      R->churn_dontneed++;
    }
    if (i % 8 == 7) {
      void *p = mmap(nullptr, kPage, PROT_READ | PROT_WRITE, MAP_SHARED, R->win.fd,
                     off_t(R->win.dev_offset + page * kPage));
      if (p == MAP_FAILED) {
        if (!R->churn_errors++) R->churn_first_error = std::string("mmap: ") + strerror(errno);
      } else {
        ct::read_page(static_cast<volatile uint64_t *>(p), buf);
        if (chk.check_scan(buf, page, A.page_offset + page, A.salt, &R->churn_viol) && A.abort_on_violation) {
          R->set_abort(kAbViolation);
          R->stop.store(true);
        }
        munmap(p, kPage);
        R->churn_remaps++;
      }
    }
    usleep(useconds_t(A.churn_us));
  }
}

// Watchdog: dump per-thread state (and the peers' in-flight ops), JSON, exit 3 (stuck threads cannot be joined).
[[noreturn]] void watchdog_fire(ContendRun *R, const std::string &why, uint64_t now) {
  const Args &A = *R->a;
  const uint32_t me = uint32_t(A.node);
  R->set_abort(kAbWatchdog);
  R->stop.store(true);
  if (!R->t_end) R->t_end = now;
  R->abort_seen = R->abort_word();
  std::string s = "reason=" + why + "\\n";
  for (uint32_t t = 0; t < R->T(); t++) {
    Worker &W = R->w[t];
    uint64_t t0 = __atomic_load_n(&W.cur_t0, __ATOMIC_RELAXED), cur = R->line(me, t).cur;
    char b[256];
    snprintf(b, sizeof(b), "t%u tid %d ops %" PRIu64 " inflight page %" PRId64 " %s age_ms %" PRIu64 " state ", t,
             int(W.tid), R->line(me, t).ops, cur ? int64_t(cur >> 1) - 1 : -1, cur ? (cur & 1 ? "write" : "read") : "-",
             t0 && now > t0 ? (now - t0) / 1000000 : 0);
    std::string st = proc_task(W.tid, "stat");
    size_t rp = st.rfind(')');
    s += b + (rp != std::string::npos && rp + 2 < st.size() ? st.substr(rp + 2, 1) : std::string("?")) +
         " wchan " + proc_task(W.tid, "wchan") + " stack " + proc_task(W.tid, "stack") + "\\n";
  }
  for (uint32_t k = 0; k < R->N(); k++) {
    if (k == me) continue;
    for (uint32_t t = 0; t < R->T(); t++) {
      char b[160];
      uint64_t cur = R->line(k, t).cur;
      snprintf(b, sizeof(b), "peer%u t%u ops %" PRIu64 " inflight page %" PRId64 " %s\\n", k, t, R->line(k, t).ops,
               cur ? int64_t(cur >> 1) - 1 : -1, cur ? (cur & 1 ? "write" : "read") : "-");
      s += b;
    }
  }
  R->watchdog_dump = s;
  R->status = "watchdog";
  R->exit_code = 3;
  fprintf(stderr, "faultlat contend: node %d: WATCHDOG (%s, %.1f s)\n%s", A.node, why.c_str(), A.watchdog_s,
          [&] {
            std::string o = s;
            for (size_t p; (p = o.find("\\n")) != std::string::npos;) o.replace(p, 2, "\n");
            return o;
          }()
              .c_str());
  R->write_json(A.out.c_str());
  fflush(nullptr);
  _exit(3);  // stuck threads cannot be joined
}

// Monitor (main thread): progress sampling, starvation/stall samples, watchdog, duration, abort.
void contend_monitor(ContendRun *R) {
  const Args &A = *R->a;
  const uint64_t iv = A.interval_ms * 1000000ull, wd = uint64_t(A.watchdog_s * 1e9);
  const uint32_t me = uint32_t(A.node);
  std::vector<uint64_t> peer_prev(R->N() * R->T(), 0);
  uint64_t local_zero = 0, next = R->t_start + iv, peer_streak = 0;
  for (;;) {
    struct timespec ts = {time_t(next / 1000000000ull), long(next % 1000000000ull)};
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr);
    const uint64_t now = now_ns();
    uint64_t local = 0, peer = 0;
    std::vector<uint64_t> d(R->T());
    for (uint32_t t = 0; t < R->T(); t++) {
      uint64_t o = cxl::hwcc::load_acquire(&R->line(me, t).ops);
      d[t] = o - R->w[t].prev_ops;
      R->w[t].prev_ops = o;
      local += d[t];
    }
    for (uint32_t k = 0; k < R->N(); k++) {
      if (k == me) continue;
      for (uint32_t t = 0; t < R->T(); t++) {
        uint64_t o = cxl::hwcc::load_acquire(&R->line(k, t).ops), &p = peer_prev[k * R->T() + t];
        peer += o - p;
        p = o;
      }
    }
    R->peer_ops += peer;
    R->intervals++;
    R->timeline.push_back({local, peer});
    for (uint32_t t = 0; t < R->T(); t++) {
      Worker &W = R->w[t];
      if (d[t] == 0 && !__atomic_load_n(&W.exited, __ATOMIC_ACQUIRE)) {
        if (local - d[t] > 0 || peer > 0) W.starve++;
        W.max_zero_streak = std::max(W.max_zero_streak, ++W.zero_streak);
      } else {
        W.zero_streak = 0;
      }
    }
    if (local == 0 && peer > 0) R->node_stall++;
    if (local == 0 && peer == 0 && (me == 0 || R->N() == 1)) R->global_stall++;
    if (R->N() > 1) {
      if (peer == 0) {
        R->peer_zero++;
        R->peer_max_zero = std::max(R->peer_max_zero, ++peer_streak);
      } else {
        peer_streak = 0;
      }
    }
    // Watchdog: this node made no progress for W s, or one op has been in flight for W s.
    bool running = false;
    for (auto &x : R->w) running |= !__atomic_load_n(&x.exited, __ATOMIC_ACQUIRE);
    local_zero = (local || !running) ? 0 : local_zero + iv;
    std::string why;
    if (local_zero >= wd) why = "node_stall";
    for (uint32_t t = 0; t < R->T() && why.empty(); t++) {
      uint64_t t0 = __atomic_load_n(&R->w[t].cur_t0, __ATOMIC_RELAXED);
      if (t0 && now > t0 && now - t0 >= wd) why = "op_stuck";
    }
    if (!why.empty() && !R->stop.load()) watchdog_fire(R, why, now);
    if (uint64_t ab = R->abort_word()) {
      R->abort_seen = ab;
      R->stop.store(true);
    }
    if (now - R->t_start >= uint64_t(A.duration_s * 1e9)) R->stop.store(true);
    if (A.max_ops) {  // every worker finished its ops
      bool all = true;
      for (auto &x : R->w) all &= __atomic_load_n(&x.exited, __ATOMIC_ACQUIRE);
      if (all) R->stop.store(true);
    }
    if (R->stop.load()) {
      R->t_end = now;
      return;
    }
    next += iv;
  }
}

int cmd_contend(const Args &a) {
  if (a.app_bytes) {
    if (a.nodes < 1 || a.nodes > 8 || a.threads < 1 || a.threads > 1024) die("--nodes 1..8, --threads 1..1024");
    printf("%" PRIu64 "\n", contend_layout(a).L.bytes());
    return 0;
  }
  if (!a.has_salt && !a.init_only) const_cast<Args &>(a).salt = a.run_id;
  if (a.init_only) {
    if (!a.has_salt) die("--init-only needs --salt");
    cxl::region r = load_region(a);
    Mapping m = map_window(r, a.page_offset, a.pages);
    for (uint64_t p = 0; p < a.pages; p++)
      ct::write_page(reinterpret_cast<volatile uint64_t *>(m.base + p * kPage), a.salt, a.page_offset + p,
                     ct::kInitWriter, 0);
    FILE *f = open_out(a.out);
    fprintf(f, "{\"tool\": \"%s\", \"cmd\": \"contend\", \"init_only\": true, \"pages\": %" PRIu64 ", \"page_offset\": %" PRIu64
               ", \"dev_offset\": %" PRIu64 ", \"salt\": %" PRIu64 "}\n",
            kVersion, a.pages, a.page_offset, m.dev_offset, a.salt);
    if (f != stdout) fclose(f);
    munmap(m.base, m.len);
    close(m.fd);
    return 0;
  }
  if (a.nodes < 1 || a.nodes > 8) die("--nodes must be 1..8");
  if (a.node < 0 || a.node >= a.nodes) die("--node 0..nodes-1 is required");
  if (a.threads < 1 || a.threads > 1024 || uint64_t(a.nodes) * a.threads > contend::kMaxWriters - 1)
    die("--threads must be 1..1024 and nodes*threads < %u", contend::kMaxWriters);
  if (a.read_pct < 0 || a.read_pct > 100) die("--read-pct must be 0..100");
  if (a.dist != "uniform" && a.dist != "zipf" && a.dist != "partition") die("--dist must be uniform, zipf or partition");
  if (a.dist == "partition" && a.pages % (uint64_t(a.nodes) * a.threads))
    die("--dist partition needs --pages a multiple of nodes*threads (each writer owns pages/(nodes*threads))");
  const uint64_t cpages = a.dist == "partition" ? a.pages / (uint64_t(a.nodes) * a.threads) : a.pages;
  if (a.read_pct > 0 && cpages * (uint64_t(a.nodes) * a.threads + 1) * 16 * a.threads > (8ull << 30))
    die("checker state pages*writers*16*threads exceeds 8 GiB: use fewer pages/threads or --read-pct 0");
  if (!a.run_id) die("--run-id (non-zero, same on all nodes, new per run) is required");
  if (a.duration_s <= 0 || a.watchdog_s <= 0 || a.interval_ms == 0) die("bad duration/watchdog/interval");
  if (a.stride != 1) die("contend uses --pages/--page-offset only");
  const Inject inj = parse_inject(a.inject);
  const std::vector<int> cpus = parse_cpu_list(a.cpu_list);

  static ContendRun R;  // static: the watchdog exits without unwinding
  R.a = &a;
  R.r = load_region(a);
  R.lay = contend_layout(a);
  if (R.r.app.size < R.lay.L.bytes())
    die("HWcc app range %" PRIu64 " B < contend layout %" PRIu64 " B: set CXL_APP_HWCC_BYTES=%" PRIu64 " on every node",
        R.r.app.size, R.lay.L.bytes(), R.lay.L.bytes());
  R.sys_before = read_sysfs();
  R.minflt0 = minflt();
  // HWcc app range (unmanaged; hardware-coherent) and the SWcc hot set.
  R.app.fd = open(R.r.device.c_str(), O_RDWR);
  if (R.app.fd < 0) die("open %s: %s", R.r.device.c_str(), strerror(errno));
  R.app.len = R.r.app.size;
  void *ap = mmap(nullptr, R.app.len, PROT_READ | PROT_WRITE, MAP_SHARED, R.app.fd, off_t(R.r.app.offset));
  if (ap == MAP_FAILED) die("mmap app range at %" PRIu64 ": %s", R.r.app.offset, strerror(errno));
  R.app.base = static_cast<uint8_t *>(ap);
  R.app.dev_offset = R.r.app.offset;
  R.win = map_window(R.r, a.page_offset, a.pages);
  uint8_t *fake_map = reinterpret_cast<uint8_t *>(uintptr_t(R.app.base) - R.r.app.offset);  // app_base() = map + app.offset
  std::string err;
  if (!cxl::hwcc::app_init(R.r, fake_map, R.lay.L, a.run_id, uint32_t(a.nodes), uint32_t(a.node),
                           uint64_t(a.barrier_timeout_s * 1000), &err))
    die("node %d: %s", a.node, err.c_str());
  uint8_t *base = R.app.base;
  R.ctl = reinterpret_cast<CtlLine *>(base + R.lay.ctl);
  R.nodes = reinterpret_cast<NodeLine *>(base + R.lay.nodes);
  R.tl = reinterpret_cast<ThreadLine *>(base + R.lay.threads);
  R.lastseq = reinterpret_cast<uint64_t *>(base + R.lay.last);
  g_ctl = R.ctl;
  g_node = a.node;
  struct sigaction sa = {};
  sa.sa_sigaction = on_sigbus;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGBUS, &sa, nullptr);

  const uint64_t H = a.pages;
  if (a.node == 0 && !a.skip_init)
    for (uint64_t p = 0; p < H; p++)
      ct::write_page(reinterpret_cast<volatile uint64_t *>(R.win.base + p * kPage), a.salt, a.page_offset + p,
                     ct::kInitWriter, 0);
  R.w.resize(a.threads);
  for (uint32_t t = 0; t < a.threads; t++) {
    R.w[t].t = t;
    R.w[t].wid = uint32_t(a.node) * a.threads + t;
    R.w[t].last.assign(H, 0);
  }
  auto finish = [&](const char *status, int code) {
    R.status = status;
    R.exit_code = code;
    R.write_json(a.out.c_str());
    fprintf(stderr, "faultlat contend: node %d: %s (exit %d)\n", a.node, status, code);
    fflush(nullptr);
    _exit(code);  // workers may still be blocked in a fault
  };
  if (!R.barrier(1)) {
    R.abort_seen = R.abort_word();
    if (!R.abort_seen) R.set_abort(kAbCoord);
    finish(R.abort_seen ? "peer_abort" : "coordination", R.abort_seen ? 6 : 5);
  }
  std::vector<std::thread> th;
  for (uint32_t t = 0; t < a.threads; t++) th.emplace_back(contend_worker, &R, t, &cpus, inj);
  std::thread churn;
  if (a.churn_us) churn = std::thread(contend_churn, &R);
  while (R.ready.load() < a.threads) usleep(100);
  // Cross-node start: every node has all its threads created and waiting, then all are released together.
  if (!R.barrier(2)) {
    R.abort_seen = R.abort_word();
    if (!R.abort_seen) R.set_abort(kAbCoord);
    finish(R.abort_seen && (R.abort_seen >> 8) != kAbCoord ? "peer_abort" : "coordination",
           R.abort_seen && (R.abort_seen >> 8) != kAbCoord ? 6 : 5);
  }
  R.t_start = now_ns();
  R.go.store(true, std::memory_order_release);
  contend_monitor(&R);
  // Post-run guard: every later step (worker drain, barriers, final scan) has a deadline; past it the watchdog
  // dumps and exits 3 instead of hanging (e.g. a worker or the final scan stuck in a fault).
  const uint64_t wd_ns = uint64_t(a.watchdog_s * 1e9), bt_ns = uint64_t(a.barrier_timeout_s * 1e9);
  std::thread([] {
    for (;;) {
      usleep(100000);
      const uint64_t d = R.guard_deadline.load(), now = now_ns();
      if (d && now > d) watchdog_fire(&R, std::string("post_run_") + R.guard_phase.load(), now);
    }
  }).detach();
  auto guard = [&](const char *phase, uint64_t budget_ns) {
    R.guard_phase.store(phase);
    R.guard_deadline.store(now_ns() + budget_ns);
  };
  guard("drain", wd_ns);  // workers finish their current op and exit
  for (;;) {
    bool all = true;
    for (auto &x : R.w) all &= __atomic_load_n(&x.exited, __ATOMIC_ACQUIRE);
    if (all) break;
    usleep(1000);
  }
  for (auto &x : th) x.join();
  if (churn.joinable()) churn.join();

  uint64_t own = 0;
  for (auto &x : R.w) own += x.viol.total();
  if (own) {
    R.abort_seen = R.abort_word();
    finish("violation", 2);
  }
  if (R.abort_seen) finish("peer_abort", 6);
  // Publish this node's last seqs, then every node checks the final page contents against all writers.
  for (uint32_t t = 0; t < a.threads; t++)
    for (uint64_t p = 0; p < H; p++) R.lastseq[(uint64_t(R.w[t].wid)) * H + p] = R.w[t].last[p];
  guard("barrier3", bt_ns + wd_ns);
  if (!R.barrier(3)) {
    R.abort_seen = R.abort_word();
    if (!R.abort_seen) R.set_abort(kAbCoord);
    finish(R.abort_seen && (R.abort_seen >> 8) != kAbCoord ? "peer_abort" : "coordination",
           R.abort_seen && (R.abort_seen >> 8) != kAbCoord ? 6 : 5);
  }
  guard("final_scan", wd_ns + H * 1000000ull);
  const uint32_t nw = uint32_t(a.nodes) * a.threads;
  uint64_t buf[ct::kWords];
  for (uint64_t p = 0; p < H; p++) {
    ct::read_page(reinterpret_cast<volatile uint64_t *>(R.win.base + p * kPage), buf);
    ct::final_check(buf, a.page_offset + p, a.salt, nw,
                    [&](uint32_t wi) { return cxl::hwcc::load_acquire(&R.lastseq[uint64_t(wi) * H + p]); },
                    &R.final_viol);
  }
  R.final_done = true;
  if (R.final_viol.total()) {
    R.set_abort(kAbViolation);
    finish("violation", 2);
  }
  guard("barrier4", bt_ns + wd_ns);
  if (!R.barrier(4)) {
    R.abort_seen = R.abort_word();
    finish(R.abort_seen ? "peer_abort" : "coordination", R.abort_seen ? 6 : 5);
  }
  R.guard_deadline.store(0);
  R.write_json(a.out.c_str());
  munmap(R.win.base, R.win.len);
  close(R.win.fd);
  munmap(R.app.base, R.app.len);
  close(R.app.fd);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Args a = parse_args(argc, argv);
  if (a.cmd == "params") return cmd_params(a);
  if (a.cmd == "access") return cmd_access(a);
  if (a.cmd == "pingpong") return cmd_pingpong(a);
  if (a.cmd == "contend") return cmd_contend(a);
  die("unknown subcommand %s", a.cmd.c_str());
}

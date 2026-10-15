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
//
// Nothing here needs root, but opening the DAX device needs permission on it.

#include <dirent.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
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
#include <vector>

#include "../../systems/common/cxl_region.h"

namespace {

constexpr uint64_t kPage = 4096;
constexpr const char *kSysfs = "/sys/kernel/swmc/page_coherence";
constexpr const char *kVersion = "faultlat-2";

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
};

uint64_t parse_num(const char *s, const char *what) {
  char *end = nullptr;
  errno = 0;
  unsigned long long v = strtoull(s, &end, 0);
  if (errno || !end || *end) die("bad value for %s: %s", what, s);
  return v;
}

Args parse_args(int argc, char **argv) {
  if (argc < 2) die("usage: faultlat params|access|pingpong [options] (see README.md)");
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

}  // namespace

int main(int argc, char **argv) {
  Args a = parse_args(argc, argv);
  if (a.cmd == "params") return cmd_params(a);
  if (a.cmd == "access") return cmd_access(a);
  if (a.cmd == "pingpong") return cmd_pingpong(a);
  die("unknown subcommand %s", a.cmd.c_str());
}

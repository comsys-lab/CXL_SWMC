// De Stijl v2 user library: de_stijl_alloc() over the whole-device mapping (see de_stijl.h).
// C++ only because the region layout comes from systems/common/cxl_region.h.
#include "de_stijl.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>

#include "cxl_region.h"

namespace {

struct state {
  cxl::region r;
  uint64_t align = DE_STIJL_ALLOC_ALIGN;
  int init_errno = 0;                 // non-zero: every de_stijl_alloc() fails with it
  std::atomic<uint64_t> cursor{0};    // next free device offset inside r.swcc
};

state g;
std::once_flag g_once;

// [va, va + len) is mapped from `path` with file offset va - base in every VMA.
// Returns 1 = fully mapped, 0 = nothing mapped there, -1 = something else (or a partial map) is there.
int mapping_status(uint64_t base, uint64_t len, const std::string &path) {
  std::ifstream f("/proc/self/maps");
  std::string line;
  uint64_t cur = base, end = base + len;
  bool any = false;
  while (std::getline(f, line)) {
    std::istringstream is(line);
    std::string range, perms, off, dev, ino, file;
    is >> range >> perms >> off >> dev >> ino >> file;
    const size_t dash = range.find('-');
    if (dash == std::string::npos) continue;
    const uint64_t lo = std::stoull(range.substr(0, dash), nullptr, 16);
    const uint64_t hi = std::stoull(range.substr(dash + 1), nullptr, 16);
    if (hi <= base || lo >= end) continue;
    any = true;
    if (lo > cur || file != path || std::stoull(off, nullptr, 16) != lo - base) return -1;
    cur = hi;
  }
  if (!any) return 0;
  return cur >= end ? 1 : -1;
}

void init() {
  std::string err;
  if (!cxl::region_load(nullptr, &g.r, &err)) {
    fprintf(stderr, "libdestijl: region config: %s\n", err.c_str());
    g.init_errno = EINVAL;
    return;
  }
  if (g.r.align > g.align) g.align = g.r.align;
  if (g.r.swcc.offset % g.align) {
    fprintf(stderr, "libdestijl: swcc_offset %#llx not %#llx aligned\n",
            (unsigned long long)g.r.swcc.offset, (unsigned long long)g.align);
    g.init_errno = EINVAL;
    return;
  }
  const int st = mapping_status(g.r.map_va, g.r.device_size, g.r.device);
  if (st < 0) {
    fprintf(stderr, "libdestijl: map_va %#llx is occupied by a mapping other than the whole %s\n",
            (unsigned long long)g.r.map_va, g.r.device.c_str());
    g.init_errno = EEXIST;
    return;
  }
  if (st == 0) {  // map it the way the workloads do (whole device at map_va)
    const int fd = open(g.r.device.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      g.init_errno = errno;
      return;
    }
    void *want = reinterpret_cast<void *>(g.r.map_va);
    void *m = mmap(want, g.r.device_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    const int e = errno;
    close(fd);
    if (m == MAP_FAILED || m != want) {
      if (m != MAP_FAILED) munmap(m, g.r.device_size);  // old kernels ignore MAP_FIXED_NOREPLACE
      g.init_errno = m == MAP_FAILED ? e : EEXIST;
      return;
    }
  }
  g.cursor.store(g.r.swcc.offset, std::memory_order_relaxed);
}

}  // namespace

extern "C" void *de_stijl_alloc(size_t size, uint64_t staleness_us) {
  std::call_once(g_once, init);
  if (g.init_errno) {
    errno = g.init_errno;
    return nullptr;
  }
  if (size == 0) {
    errno = EINVAL;
    return nullptr;
  }
  const uint64_t a = g.align;
  if (size > g.r.swcc.size) {
    errno = ENOMEM;
    return nullptr;
  }
  const uint64_t len = (uint64_t(size) + a - 1) / a * a;
  uint64_t off = g.cursor.load(std::memory_order_relaxed);
  do {
    if (len > g.r.swcc.end() - off) {
      errno = ENOMEM;
      return nullptr;
    }
  } while (!g.cursor.compare_exchange_weak(off, off + len, std::memory_order_relaxed));

  void *p = reinterpret_cast<void *>(g.r.map_va + off);
  if (de_stijl_set_staleness(p, len, staleness_us) != 0) return nullptr;  // errno from the syscall
  return p;
}

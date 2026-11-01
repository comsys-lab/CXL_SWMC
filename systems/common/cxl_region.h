// Shared CXL region layout (config/cxl_region.yaml). Header-only, no deps.
// Every system and workload takes HWcc/SWcc boundaries from cxl_region_load();
// no other code may hard-code offsets or sizes.
#pragma once

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#ifdef CXL_REGION_DESTIJL
#include "de_stijl.h"  // systems/destijl/lib (libdestijl): region_apply_staleness below
#endif

namespace cxl {

struct range {
  uint64_t offset = 0;
  uint64_t size = 0;
  uint64_t end() const { return offset + size; }
};

struct region {
  std::string device = "/dev/dax0.0";
  uint64_t device_size = 0;
  uint64_t map_va = 0x600000000000ull;  // fixed mapping address, same on every node
  uint64_t align = 2ull << 20;
  range hwcc;
  range msg_ring;    // optional kernel message ring (Popcorn cxl_shm) at the END of hwcc; size 0 = none
  range app;         // workload control state (docs/hwcc-contract.md), directly before msg_ring; size from
                     // $CXL_APP_HWCC_BYTES (the workload's computed need, rounded up to 4 KiB); 0 = none
  range hwcc_alloc;  // hwcc minus app minus msg_ring: what systems (e.g. Megalon's SCR) may allocate
  range swcc;
  std::vector<range> reserved;
  std::string source;  // config path actually used
};

namespace detail {

inline std::string trim(const std::string &s) {
  size_t b = s.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return "";
  size_t e = s.find_last_not_of(" \t\r\n");
  return s.substr(b, e - b + 1);
}

inline bool parse_u64(const std::string &v, uint64_t *out) {
  if (v.empty()) return false;
  errno = 0;
  char *end = nullptr;
  unsigned long long x = strtoull(v.c_str(), &end, 0);
  if (errno || *end) return false;
  *out = x;
  return true;
}

// "[[off, size], [off, size]]" or "[]"
inline bool parse_ranges(const std::string &v, std::vector<range> *out) {
  std::string s;
  for (char c : v)
    if (c != ' ' && c != '\t') s += c;
  if (s.size() < 2 || s.front() != '[' || s.back() != ']') return false;
  s = s.substr(1, s.size() - 2);
  size_t i = 0;
  while (i < s.size()) {
    if (s[i] == ',') { i++; continue; }
    if (s[i] != '[') return false;
    size_t j = s.find(']', i);
    if (j == std::string::npos) return false;
    std::string pair = s.substr(i + 1, j - i - 1);
    size_t comma = pair.find(',');
    range r;
    if (comma == std::string::npos || !parse_u64(pair.substr(0, comma), &r.offset) ||
        !parse_u64(pair.substr(comma + 1), &r.size))
      return false;
    out->push_back(r);
    i = j + 1;
  }
  return true;
}

inline uint64_t align_up(uint64_t x, uint64_t a) { return (x + a - 1) / a * a; }

inline bool overlaps(const range &a, const range &b) {
  return a.offset < b.end() && b.offset < a.end();
}

inline bool read_sysfs_size(const std::string &device, uint64_t *out) {
  std::string name = device.substr(device.rfind('/') + 1);
  std::ifstream f("/sys/bus/dax/devices/" + name + "/size");
  std::string line;
  return f && std::getline(f, line) && parse_u64(trim(line), out);
}

}  // namespace detail

// Load and validate. path == nullptr: $CXL_REGION_CONFIG. device_size_override
// (non-zero) replaces "auto" for hosts without the device (build/test).
// Returns false and fills *err on any error; callers must refuse to run.
inline bool region_load(const char *path, region *r, std::string *err,
                        uint64_t device_size_override = 0) {
  using namespace detail;
  if (!path) path = getenv("CXL_REGION_CONFIG");
  if (!path) { *err = "no region config (set CXL_REGION_CONFIG)"; return false; }
  std::ifstream f(path);
  if (!f) { *err = std::string("cannot open ") + path; return false; }
  r->source = path;

  std::string dev_size = "auto", sw_off = "auto", sw_size = "auto";
  bool have_hw_size = false, have_hw_off = false;
  std::string line;
  int lineno = 0;
  while (std::getline(f, line)) {
    lineno++;
    size_t hash = line.find('#');
    if (hash != std::string::npos) line = line.substr(0, hash);
    line = trim(line);
    if (line.empty()) continue;
    size_t colon = line.find(':');
    if (colon == std::string::npos) {
      *err = "line " + std::to_string(lineno) + ": expected key: value";
      return false;
    }
    std::string k = trim(line.substr(0, colon)), v = trim(line.substr(colon + 1));
    bool ok = true;
    if (k == "device") r->device = v;
    else if (k == "device_size") dev_size = v;
    else if (k == "map_va") ok = parse_u64(v, &r->map_va);
    else if (k == "align") ok = parse_u64(v, &r->align);
    else if (k == "hwcc_offset") ok = have_hw_off = parse_u64(v, &r->hwcc.offset);
    else if (k == "hwcc_size") ok = have_hw_size = parse_u64(v, &r->hwcc.size);
    else if (k == "swcc_offset") sw_off = v;
    else if (k == "swcc_size") sw_size = v;
    else if (k == "reserved") ok = parse_ranges(v, &r->reserved);
    else if (k == "msg_ring") {
      std::vector<range> rr;
      ok = parse_ranges("[" + v + "]", &rr) && rr.size() == 1;
      if (ok) r->msg_ring = rr[0];
    }
    else { *err = "line " + std::to_string(lineno) + ": unknown key " + k; return false; }
    if (!ok) { *err = "line " + std::to_string(lineno) + ": bad value for " + k; return false; }
  }
  if (!have_hw_off || !have_hw_size) { *err = "hwcc_offset and hwcc_size are required"; return false; }

  if (device_size_override) r->device_size = device_size_override;
  else if (dev_size == "auto") {
    if (!read_sysfs_size(r->device, &r->device_size)) {
      *err = "cannot read size of " + r->device + " from sysfs";
      return false;
    }
  } else if (!parse_u64(dev_size, &r->device_size)) { *err = "bad device_size"; return false; }

  if (r->align < 4096 || r->align % 4096) { *err = "align must be a multiple of 4096"; return false; }
  if (r->map_va == 0 || r->map_va % r->align) { *err = "map_va must be non-zero and aligned"; return false; }
  if (r->hwcc.size == 0) { *err = "hwcc_size must be > 0"; return false; }
  if (r->hwcc.offset % r->align || r->hwcc.size % 4096) {
    *err = "hwcc_offset must be aligned, hwcc_size a multiple of 4096";
    return false;
  }

  // The message ring is carved from the tail of hwcc (hardware-coherent, so its lines need no flushes);
  // everything else in hwcc stays one contiguous allocatable range.
  r->hwcc_alloc = r->hwcc;
  if (r->msg_ring.size) {
    const range &m = r->msg_ring;
    if (m.offset % 4096 || m.size % 4096 || m.offset < r->hwcc.offset || m.end() != r->hwcc.end() ||
        m.size >= r->hwcc.size) {
      *err = "msg_ring must be 4 KiB aligned, non-empty, end exactly at the end of hwcc and leave room before it";
      return false;
    }
    r->hwcc_alloc.size = m.offset - r->hwcc.offset;
  }
  // Workload control state is carved directly below the ring (or the end of hwcc); systems keep the front of
  // hwcc (Megalon's control block sits at hwcc_offset). Its size is computed by the workload for this run
  // (docs/hwcc-contract.md), never a tuned constant; both nodes must see the same value (layout hashes check it).
  r->app = range{r->hwcc_alloc.end(), 0};
  if (const char *app = getenv("CXL_APP_HWCC_BYTES"); app && *app) {
    uint64_t want = 0;
    if (!parse_u64(app, &want)) { *err = "bad CXL_APP_HWCC_BYTES"; return false; }
    want = align_up(want, 4096);
    if (want >= r->hwcc_alloc.size) {
      *err = "CXL_APP_HWCC_BYTES " + std::to_string(want) + " leaves no hwcc for the system (hwcc minus msg_ring " +
             std::to_string(r->hwcc_alloc.size) + ")";
      return false;
    }
    r->hwcc_alloc.size -= want;
    r->app = range{r->hwcc_alloc.end(), want};
  }

  if (sw_off == "auto") r->swcc.offset = align_up(r->hwcc.end(), r->align);
  else if (!parse_u64(sw_off, &r->swcc.offset)) { *err = "bad swcc_offset"; return false; }
  if (sw_size == "auto") {
    uint64_t end = r->device_size;
    for (const range &x : r->reserved)
      if (x.offset >= r->swcc.offset && x.offset < end) end = x.offset;
    end = end / r->align * r->align;
    r->swcc.size = end > r->swcc.offset ? end - r->swcc.offset : 0;
  } else if (!parse_u64(sw_size, &r->swcc.size)) { *err = "bad swcc_size"; return false; }

  if (r->swcc.offset % r->align || r->swcc.size == 0 || r->swcc.size % r->align) {
    *err = "swcc must be aligned and non-empty";
    return false;
  }
  if (r->hwcc.end() > r->device_size || r->swcc.end() > r->device_size) {
    *err = "region exceeds device size";
    return false;
  }
  if (overlaps(r->hwcc, r->swcc)) { *err = "hwcc and swcc overlap"; return false; }
  for (const range &x : r->reserved) {
    if (x.size == 0 || x.end() > r->device_size) { *err = "bad reserved range"; return false; }
    if (overlaps(x, r->hwcc) || overlaps(x, r->swcc)) {
      *err = "reserved range overlaps hwcc/swcc";
      return false;
    }
  }
  return true;
}

// De Stijl v2 staleness bound T (reports/design/DS2-protocol-spec.md §6) of an SWcc range of the whole-device
// mapping at map_va. T comes from $CXL_DESTIJL_T_US (microseconds); it applies only when $CXL_SYSTEM is "ds" (set by
// the harness for De Stijl lifetimes, experiments/eval/h2n-block.sh). Unset/empty/0 T or another system: no-op,
// returns 0 without a syscall (behaviour of every other system unchanged). Otherwise [addr, addr + len), widened to
// whole 4 KiB pages, must lie inside swcc; then de_stijl_set_staleness (libdestijl, syscall 472). The call is
// compiled in only with -DCXL_REGION_DESTIJL (the build includes systems/destijl/lib and links libdestijl); without
// it a T > 0 request fails with ENOSYS (fail closed: a ds run never silently runs synchronous).
// Returns 0 (applied or no-op; *t_us = the T applied, 0 for a no-op) or -1 with errno (EINVAL: bad T value or range
// outside swcc; ENOSYS; or the syscall's errno).
inline int region_apply_staleness(const region &r, void *addr, size_t len, uint64_t *t_us = nullptr) {
  if (t_us) *t_us = 0;
  const char *t = getenv("CXL_DESTIJL_T_US");
  const char *sys = getenv("CXL_SYSTEM");
  if (!t || !*t || !sys || std::strcmp(sys, "ds") != 0) return 0;
  uint64_t v = 0;
  if (!detail::parse_u64(t, &v)) { errno = EINVAL; return -1; }
  if (v == 0) return 0;
  const uint64_t a = reinterpret_cast<uint64_t>(addr), lo = a & ~4095ull, hi = (a + len + 4095) & ~4095ull;
  const uint64_t s0 = r.map_va + r.swcc.offset, s1 = r.map_va + r.swcc.end();
  if (len == 0 || lo < s0 || hi > s1) { errno = EINVAL; return -1; }
#ifdef CXL_REGION_DESTIJL
  if (de_stijl_set_staleness(reinterpret_cast<void *>(lo), size_t(hi - lo), v) != 0) return -1;
  if (t_us) *t_us = v;
  return 0;
#else
  errno = ENOSYS;
  return -1;
#endif
}

// One-line summary for logs and run manifests.
inline std::string region_describe(const region &r) {
  std::ostringstream o;
  o << "device=" << r.device << " device_size=" << r.device_size << " map_va=0x" << std::hex << r.map_va
    << std::dec << " align=" << r.align
    << " hwcc=[" << r.hwcc.offset << "," << r.hwcc.end() << ")"
    << " hwcc_alloc=[" << r.hwcc_alloc.offset << "," << r.hwcc_alloc.end() << ")"
    << " app=[" << r.app.offset << "," << r.app.end() << ")"
    << " msg_ring=[" << r.msg_ring.offset << "," << r.msg_ring.end() << ")"
    << " swcc=[" << r.swcc.offset << "," << r.swcc.end() << ")"
    << " reserved=" << r.reserved.size() << " config=" << r.source;
  return o.str();
}

}  // namespace cxl

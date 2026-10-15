// recsys backends (DESIGN.md §7): where the slots live and which coherence actions wrap each slot access.
//   plain   all-HWcc and Popcorn: tables at fixed SWcc offsets, direct loads/stores.
//   megalon one Megalon object per slot (paper §4 objects), every slot access in one read/write section.
// Interface used by server.cc (Server<Backend>): fits, name, usage, stats, thread_init(tid), create_objects (node 0),
// check_objects (every node), read_slot(k, s, f) (f(const uint8_t *slot) may run more than once and must only
// produce its result), write_slot(k, s, fill) (fill(uint8_t *slot) writes the whole slot, whole lines, reads nothing).
// The HWcc version words (seqlock per 64 slots) wrap these calls in server.cc identically for every backend.
#pragma once

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>
#include <fstream>
#include <sstream>
#include <string>
#include <type_traits>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_objapi.h"  // systems/megalon/shim (shared object-API shim; DESIGN.md §7)

namespace rsys {

class PlainBackend {
 public:
  static constexpr const char *kLayoutTag = "";
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p) : map_(map), p_(p) {
    base_ = r.swcc.offset;
    end_ = base_ + p.swcc_bytes();
    swcc_end_ = r.swcc.end();
  }
  bool fits(std::string *err) const {
    if (end_ > swcc_end_) {
      *err = "SWcc too small: tables need " + std::to_string(p_.swcc_bytes()) + " B, SWcc ends at " +
             std::to_string(swcc_end_) + " (need end " + std::to_string(end_) + ")";
      return false;
    }
    return true;
  }
  std::string name() const { return "plain"; }
  uint8_t *slot(uint32_t k, uint64_t s) const { return map_ + base_ + (p_.slot_base[k] + s) * p_.slot_bytes; }
  void thread_init(int) const {}
  template <class Par> bool create_objects(std::string *, Par &&) const { return true; }
  bool check_objects(std::string *, uint64_t) const { return true; }
  template <class F> auto read_slot(uint32_t k, uint64_t s, F f) const { return f(static_cast<const uint8_t *>(slot(k, s))); }
  template <class F> void write_slot(uint32_t k, uint64_t s, F fill) const { fill(slot(k, s)); }
  std::string usage() const {
    return "plain swcc_offset=" + std::to_string(base_) + " swcc_used_end=" + std::to_string(end_);
  }
  std::string stats() const { return ""; }

 private:
  uint8_t *map_;
  Params p_;
  uint64_t base_, end_, swcc_end_;
};

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "recsys-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device, joins the run, start barrier).
inline const mshim::Api *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  if (!fn) return *err = path + ": no megalon_object_api", nullptr;
  const mshim::Api *api = fn();
  if (!api || api->version != mshim::kApiVersion) return *err = path + ": API version mismatch", nullptr;
  return api;
}

// [va, va + len) must be covered by mappings of `path` (Megalon's mapping of the device at map_va).
inline bool mapped_by(uint64_t va, uint64_t len, const std::string &path, std::string *err) {
  std::ifstream f("/proc/self/maps");
  std::string line;
  uint64_t cur = va;
  while (cur < va + len && std::getline(f, line)) {
    std::istringstream is(line);
    std::string range, perms, off, dev, ino, file;
    is >> range >> perms >> off >> dev >> ino >> file;
    const size_t dash = range.find('-');
    const uint64_t lo = std::stoull(range.substr(0, dash), nullptr, 16), hi = std::stoull(range.substr(dash + 1), nullptr, 16);
    if (lo <= cur && cur < hi) {
      if (file != path) break;
      cur = hi;
    }
  }
  if (cur >= va + len) return true;
  *err = "region is not mapped from " + path + " (Megalon must map the same region config)";
  return false;
}

class MegalonBackend {
 public:
  static constexpr const char *kLayoutTag = " backend=megalon";
  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const mshim::Api *api) : p_(p), api_(api) {}
  bool fits(std::string *err) const {
    if (p_.slot_bytes % 64) return *err = "megalon: slot must be whole lines", false;
    for (uint32_t k = 0; k < kSparse; k++)
      if (p_.slots[k] >= (1ull << 40)) return *err = "megalon: slot index overflows the object id", false;
    return true;
  }
  std::string name() const { return "megalon"; }
  static constexpr uint64_t kBase = 0x5253ull << 48;  // "RS"
  static uint64_t id(uint32_t k, uint64_t s) { return kBase | uint64_t(k) << 40 | s; }
  void thread_init(int tid) const { api_->reg(tid); }

  // Node 0 at prepare: one object per slot (all slots, empty ones too: a probe that reaches an empty slot reads it).
  // par(f) runs f(i) on every thread of the server's registered prep pool (NR registrations are never freed, so
  // threads are registered once and reused) and returns when all are done; threads create disjoint slot ranges.
  template <class Par> bool create_objects(std::string *err, Par &&par) const {
    std::atomic<bool> ok{true};
    std::atomic<uint64_t> next{0};
    std::string e;
    std::mutex mu;
    par([&](int) {
      for (;;) {
        const uint64_t c = next.fetch_add(1 << 14);
        if (c >= p_.total_slots || !ok.load(std::memory_order_relaxed)) return;
        const uint64_t end = std::min(p_.total_slots, c + (1 << 14));
        uint32_t k = 0;
        for (uint64_t g = c; g < end; g++) {
          while (k + 1 < kSparse && p_.slot_base[k + 1] <= g) k++;
          const int rc = api_->create(id(k, g - p_.slot_base[k]), p_.slot_bytes);
          if (rc != 0) {
            std::lock_guard<std::mutex> l(mu);
            if (ok.exchange(false))
              e = "ObjectCreate(table " + std::to_string(k) + ", slot " + std::to_string(g - p_.slot_base[k]) + ") = " +
                  std::to_string(rc) + " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, MEGALON_REINIT=1)";
            return;
          }
        }
      }
    });
    if (!ok) *err = e;
    return ok;
  }
  // Every node: ObjectLookup of every `stride`-th slot plus the last slot of each table (size check).
  bool check_objects(std::string *err, uint64_t stride) const {
    auto one = [&](uint32_t k, uint64_t s) {
      size_t got = 0;
      const int rc = api_->lookup(id(k, s), &got);
      if (rc == 0 && got == p_.slot_bytes) return true;
      *err = "ObjectLookup(table " + std::to_string(k) + ", slot " + std::to_string(s) + ") = " + std::to_string(rc) +
             " size " + std::to_string(got);
      return false;
    };
    for (uint32_t k = 0; k < kSparse; k++) {
      for (uint64_t s = 0; s < p_.slots[k]; s += std::max<uint64_t>(stride, 1))
        if (!one(k, s)) return false;
      if (!one(k, p_.slots[k] - 1)) return false;
    }
    return true;
  }
  template <class F> auto read_slot(uint32_t k, uint64_t s, F f) const {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    const uint64_t oid = id(k, s);
    for (;;) {
      mshim::Obj h;
      const int rc = api_->read_start(oid, &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(" + std::to_string(oid) + ") = " + std::to_string(rc));
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(h.ptr));
        if (api_->read_end(&h)) return;
      } else {
        R r = f(static_cast<const uint8_t *>(h.ptr));
        if (api_->read_end(&h)) return r;
      }
    }
  }
  template <class F> void write_slot(uint32_t k, uint64_t s, F fill) const {
    mshim::Obj h;
    const int rc = api_->write_start(id(k, s), &h);
    if (rc != 0) megalon_fatal("ObjectWriteStart = " + std::to_string(rc));
    if (h.size != p_.slot_bytes) megalon_fatal("object size " + std::to_string(h.size));
    fill(h.ptr);  // whole slot = whole lines (D3)
    api_->write_end(&h);
  }
  std::string usage() const {
    return "megalon objects=" + std::to_string(p_.total_slots) + " object_bytes=" +
           std::to_string(p_.total_slots * p_.slot_bytes) + " shim=" + api_->info;
  }
  std::string stats() const {
    mshim::Stats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.arena_bytes=" << s.arena_bytes << "\nmegalon.used_bytes=" << s.used_bytes
      << "\nmegalon.created=" << s.created << "\nmegalon.creates=" << s.creates
      << "\nmegalon.read_sections=" << s.read_sections << "\nmegalon.read_retry_notify=" << s.read_retry_notify
      << "\nmegalon.read_retry_incoherent=" << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections
      << "\nmegalon.write_retry=" << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw
      << "\nmegalon.flushes=" << s.flushes << "\nmegalon.flush_bytes=" << s.flush_bytes
      << "\nmegalon.replay_flushes=" << s.replay_flushes << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes
      << "\n";
    return o.str();
  }

 private:
  Params p_;
  const mshim::Api *api_;
};

}  // namespace rsys

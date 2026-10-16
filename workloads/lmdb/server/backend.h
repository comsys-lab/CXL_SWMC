// lmdb backends (DESIGN.md §3): where B+tree pages live and how LMDB reaches them (MDB_cxl_conf page access).
//   plain   all-HWcc and Popcorn: page p at swcc.offset + p * 4096 of the device mapping, read in place by LMDB.
//   megalon one Megalon object (4 KiB) per LMDB page (paper §4 variable-size objects, id kBase | pgno). LMDB never
//           holds a pointer into an object: mdb_page_get copies the page out in one read section (retry until
//           ObjectReadEnd accepts) into the txn's private copy; commit writes each dirty page whole in one write
//           section (Megalon flushes the whole object at write end). Sections never nest and end before LMDB uses the
//           data, so none is held across LMDB calls.
// Both: create_pages / check_pages, write_page (prepare), warm_page, thread_init, usage, stats.
#pragma once

#include <dlfcn.h>

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_api.h"  // workloads/vectordb/server (generic dlopen shim, reused unchanged)

namespace lmdbw {

class PlainBackend {
 public:
  static constexpr const char *kLayoutTag = "";
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p) : p_(p), base_(map + r.swcc.offset),
                                                                      swcc_(r.swcc.size) {}
  bool fits(std::string *err) const {
    if (p_.max_pages * MDB_CXL_PSIZE > swcc_) {
      *err = "SWcc too small: max_pages " + std::to_string(p_.max_pages) + " x 4096 > " + std::to_string(swcc_);
      return false;
    }
    return true;
  }
  std::string name() const { return "plain"; }
  void conf(MDB_cxl_conf *c) const {
    c->page_base = reinterpret_cast<char *>(base_);
    c->page_read = nullptr;
    c->page_write = nullptr;
  }
  void thread_init(int) const {}
  bool create_pages(std::string *) const { return true; }
  bool create_range(uint64_t, uint64_t, std::string *) const { return true; }
  void thread_exit() const {}
  bool check_pages(std::string *) const { return true; }
  bool check_placement(uint64_t, std::string *) const { return true; }  // fixed placement
  void write_page(uint64_t pgno, const void *src) const { std::memcpy(base_ + pgno * MDB_CXL_PSIZE, src, MDB_CXL_PSIZE); }
  uint8_t *page_ptr(uint64_t pgno) const { return base_ + pgno * MDB_CXL_PSIZE; }
  uint64_t warm_page(uint64_t pgno) const {  // read every line once
    const uint8_t *c = base_ + pgno * MDB_CXL_PSIZE;
    uint64_t x = 0;
    for (uint32_t o = 0; o < MDB_CXL_PSIZE; o += 64) x += c[o];
    return x;
  }
  std::string usage() const {
    return "plain page_base_off=swcc+0 bytes=" + std::to_string(p_.max_pages * MDB_CXL_PSIZE);
  }
  std::string stats() const { return ""; }

 private:
  Params p_;
  uint8_t *base_;
  uint64_t swcc_;
};

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "lmdb-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

inline const vdb::MegalonApi *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<vdb_megalon_api_fn>(dlsym(h, "vdb_megalon_api"));
  if (!fn) return *err = path + ": no vdb_megalon_api", nullptr;
  const vdb::MegalonApi *api = fn();
  if (!api || api->version != vdb::kMegalonApiVersion) return *err = path + ": API version mismatch", nullptr;
  return api;
}

// [va, va + len) must be covered by mappings of `path` (Megalon maps the whole device at map_va).
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
  *err = "region at map_va is not mapped from " + path + " (Megalon must map the same region config)";
  return false;
}

class MegalonBackend {
 public:
  static constexpr const char *kLayoutTag = " backend=megalon";
  static constexpr uint64_t kBase = 0x4c4dull << 48;  // "LM"; id = kBase | pgno (< 2^63)

  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const vdb::MegalonApi *api) : p_(p), api_(api) {}
  bool fits(std::string *err) const {
    if (p_.max_pages >= (1ull << 48)) return *err = "megalon: max_pages overflows the object id", false;
    return true;
  }
  std::string name() const { return "megalon"; }
  static uint64_t id(uint64_t pgno) { return kBase | pgno; }
  void conf(MDB_cxl_conf *c) const {
    c->page_base = nullptr;
    c->ctx = const_cast<MegalonBackend *>(this);
    c->page_read = [](void *ctx, size_t pgno, void *dst) { return static_cast<MegalonBackend *>(ctx)->read(pgno, dst); };
    c->page_write = [](void *ctx, size_t pgno, const void *src) {
      static_cast<MegalonBackend *>(ctx)->write_page(pgno, src);
      return 0;
    };
  }
  void thread_init(int tid) const { api_->reg(tid); }
  // pages 2 .. max_pages-1 (LMDB's meta pages 0/1 live in HWcc); node 0 at prepare
  bool create_range(uint64_t p0, uint64_t k, std::string *err) const {
    for (uint64_t p = p0; p < p0 + k; p++) {
      const int rc = api_->create(id(p), MDB_CXL_PSIZE);
      if (rc != 0) {
        *err = "ObjectCreate(page " + std::to_string(p) + ") = " + std::to_string(rc) +
               " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, MEGALON_REINIT=1)";
        return false;
      }
    }
    return true;
  }
  // pgno order on the calling thread (deterministic arena placement)
  bool create_pages(std::string *err) const { return create_range(2, p_.max_pages > 2 ? p_.max_pages - 2 : 0, err); }
  void thread_exit() const { api_->unreg(); }
  bool check_pages(std::string *err) const {
    for (uint64_t p = 2; p < p_.max_pages; p++) {
      size_t got = 0;
      const int rc = api_->lookup(id(p), &got);
      if (rc != 0 || got != MDB_CXL_PSIZE) {
        *err = "ObjectLookup(page " + std::to_string(p) + ") = " + std::to_string(rc) + " size " + std::to_string(got);
        return false;
      }
    }
    return true;
  }
  // Restore support (DESIGN.md §9): pages 2..last_pg must sit at arena positions ptr(2) + (p - 2) * 4096, which is what
  // a single-threaded create in pgno order produces with Megalon's bump allocator; a restored device image then already
  // holds every page's bytes at its object (no write sections needed).
  bool check_placement(uint64_t last_pg, std::string *err) const {
    uint8_t *base = nullptr;
    for (uint64_t p = 2; p <= last_pg; p++) {
      vdb::MegObj h;
      if (api_->read_start(id(p), &h) != 0) return *err = "ObjectReadStart(page " + std::to_string(p) + ")", false;
      api_->read_end(&h);
      if (p == 2) base = h.ptr;
      else if (h.ptr != base + (p - 2) * MDB_CXL_PSIZE)
        return *err = "page " + std::to_string(p) + " is not at the deterministic arena position (created in another order?)", false;
    }
    return true;
  }
  // one read section: copy the whole page; re-run until ObjectReadEnd accepts
  int read(uint64_t pgno, void *dst) const {
    for (uint32_t a = 0;; a++) {
      vdb::MegObj h;
      const int rc = api_->read_start(id(pgno), &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(page " + std::to_string(pgno) + ") = " + std::to_string(rc));
      std::memcpy(dst, h.ptr, MDB_CXL_PSIZE);
      if (api_->read_end(&h)) {
        if (a) retries_.fetch_add(a, std::memory_order_relaxed);
        return 0;
      }
    }
  }
  // one write section: the whole page (whole lines, never reads prior contents: D3); write end flushes the object
  void write_page(uint64_t pgno, const void *src) const {
    vdb::MegObj h;
    const int rc = api_->write_start(id(pgno), &h);
    if (rc != 0 || h.size != MDB_CXL_PSIZE) megalon_fatal("ObjectWriteStart(page " + std::to_string(pgno) + ") = " + std::to_string(rc));
    std::memcpy(h.ptr, src, MDB_CXL_PSIZE);
    api_->write_end(&h);
  }
  uint64_t warm_page(uint64_t pgno) const {
    alignas(64) static thread_local uint8_t buf[MDB_CXL_PSIZE];
    read(pgno, buf);
    return buf[0];
  }
  std::string usage() const {
    return "megalon page_objects=" + std::to_string(p_.max_pages > 2 ? p_.max_pages - 2 : 0) + " object_bytes=" +
           std::to_string((p_.max_pages > 2 ? p_.max_pages - 2 : 0) * MDB_CXL_PSIZE) + " shim=" + api_->info;
  }
  std::string stats() const {
    vdb::MegStats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.arena_bytes=" << s.arena_bytes << "\nmegalon.used_bytes=" << s.used_bytes
      << "\nmegalon.created=" << s.created << "\nmegalon.creates=" << s.creates
      << "\nmegalon.read_sections=" << s.read_sections << "\nmegalon.read_retry_notify=" << s.read_retry_notify
      << "\nmegalon.read_retry_incoherent=" << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections
      << "\nmegalon.write_retry=" << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw
      << "\nmegalon.flushes=" << s.flushes << "\nmegalon.flush_bytes=" << s.flush_bytes
      << "\nmegalon.replay_flushes=" << s.replay_flushes << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes
      << "\nlmdb.page_read_retries=" << retries_.load() << "\n";
    return o.str();
  }

 private:
  Params p_;
  const vdb::MegalonApi *api_;
  mutable std::atomic<uint64_t> retries_{0};
};

}  // namespace lmdbw

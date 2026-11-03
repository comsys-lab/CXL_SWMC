// Access to SWcc data per system (DESIGN.md §7). Address tables of every node's arena blocks and file extents,
// file data copies, remote memtable lookups and the memtable write sections (rocksdb/cxl.h Sections).
//  plain (all-HWcc, Popcorn): block i / extent j of node v at fixed offsets of the device mapping (SwccPlan);
//          ordinary loads and stores; no sections.
//  megalon: one Megalon object per 1 MiB arena block and per 1 MiB file extent (user decision 2026-10-18), created
//          by node 0 at prepare (id kBase | kind << 44 | node << 36 | index). User decision 2026-10-18 (section
//          placement): every write is a write section on its object (memtable entry, its links, a predecessor's
//          link, SST/MANIFEST extent fills; write_end flushes the whole object, paper semantics); reads of ANOTHER
//          node's memtable or files are read sections (copy, retry until read_end accepts); the owner node reads its
//          own memtables and files directly (single writer, HW coherent within a node; recorded deviation, as is
//          the owner reading prior contents inside a write section, D3 contract, DESIGN.md §7).
#pragma once

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_objapi.h"  // systems/megalon/shim (lib/libmegalon-objapi.so)
#include "rocksdb/cxl.h"

namespace rdbw {

[[noreturn]] inline void backend_fatal(const std::string &m) {
  std::fprintf(stderr, "rocksdb-server: FATAL backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

class Backend {
 public:
  virtual ~Backend() = default;
  virtual const char *name() const = 0;
  virtual const char *layout_tag() const = 0;
  // Address tables of every node's pools (after the objects exist).
  virtual bool setup(const cxl::region &r, uint8_t *map, const Params &p, const SwccPlan &plan, uint32_t me,
                     std::string *err) = 0;
  // file data: [off, off + n) inside one 1 MiB extent j of node `node`
  virtual void file_write(uint32_t node, uint32_t j, size_t off, const void *src, size_t n) = 0;
  virtual void file_read(uint32_t node, uint32_t j, size_t off, void *dst, size_t n) = 0;
  // newest entry of key in a memtable skiplist of another node (rocksdb/cxl.h RemoteMemtableGet)
  virtual ROCKSDB_NAMESPACE::cxl::RemoteResult remote_get(uint32_t node, const void *head, int height,
                                                          const std::string &key, std::string *stored,
                                                          uint64_t *seq) = 0;
  virtual void thread_init() {}
  virtual std::string stats() const { return ""; }
  virtual const mshim::Api *api() const { return nullptr; }

  uint8_t *block(uint32_t node, uint64_t i) const { return blocks_[node][i]; }
  uint8_t *extent(uint32_t node, uint32_t j) const { return exts_[node][j]; }
  // index of this node's block starting at p
  bool block_index(uint32_t node, const void *p, uint64_t *i) const {
    const auto &v = bsorted_[node];
    auto it = std::upper_bound(v.begin(), v.end(), std::make_pair(reinterpret_cast<uintptr_t>(p), UINT64_MAX));
    if (it == v.begin()) return false;
    --it;
    if (it->first != reinterpret_cast<uintptr_t>(p)) return false;
    *i = it->second;
    return true;
  }
  // block of node `node` that contains p (any address inside it)
  bool block_containing(uint32_t node, const void *p, uint64_t *i) const {
    const auto &v = bsorted_[node];
    const uintptr_t a = reinterpret_cast<uintptr_t>(p);
    auto it = std::upper_bound(v.begin(), v.end(), std::make_pair(a, UINT64_MAX));
    if (it == v.begin()) return false;
    --it;
    if (a - it->first >= kUnit) return false;
    *i = it->second;
    return true;
  }

 protected:
  void index_blocks(uint32_t nodes) {
    bsorted_.assign(nodes, {});
    for (uint32_t v = 0; v < nodes; v++) {
      for (uint64_t i = 0; i < blocks_[v].size(); i++)
        bsorted_[v].emplace_back(reinterpret_cast<uintptr_t>(blocks_[v][i]), i);
      std::sort(bsorted_[v].begin(), bsorted_[v].end());
    }
  }
  std::vector<std::vector<uint8_t *>> blocks_, exts_;
  std::vector<std::vector<std::pair<uintptr_t, uint64_t>>> bsorted_;
};

class PlainBackend final : public Backend {
 public:
  const char *name() const override { return "plain"; }
  const char *layout_tag() const override { return ""; }
  bool setup(const cxl::region &, uint8_t *map, const Params &p, const SwccPlan &plan, uint32_t,
             std::string *) override {
    blocks_.assign(p.nr_nodes, {});
    exts_.assign(p.nr_nodes, {});
    for (uint32_t v = 0; v < p.nr_nodes; v++) {
      for (uint64_t i = 0; i < plan.arena_blocks; i++) blocks_[v].push_back(map + plan.block_off(v, i));
      for (uint64_t j = 0; j < plan.file_extents; j++) exts_[v].push_back(map + plan.extent_off(v, j));
    }
    index_blocks(p.nr_nodes);
    return true;
  }
  void file_write(uint32_t node, uint32_t j, size_t off, const void *src, size_t n) override {
    std::memcpy(extent(node, j) + off, src, n);
  }
  void file_read(uint32_t node, uint32_t j, size_t off, void *dst, size_t n) override {
    std::memcpy(dst, extent(node, j) + off, n);
  }
  ROCKSDB_NAMESPACE::cxl::RemoteResult remote_get(uint32_t, const void *head, int height, const std::string &key,
                                                  std::string *stored, uint64_t *seq) override {
    return ROCKSDB_NAMESPACE::cxl::RemoteMemtableGet(head, height, key, stored, seq);
  }
};

// ---- Megalon (shim loading as workloads/lmdb/server/backend.h) ----
inline const mshim::Api *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  if (!fn) return *err = path + ": no megalon_object_api", nullptr;
  const mshim::Api *api = fn();
  if (!api || api->version < 1) return *err = path + ": API version mismatch", nullptr;
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

class MegalonBackend final : public Backend {
 public:
  static constexpr uint64_t kBase = 0x524bull << 48;  // "RK"
  static uint64_t id(uint32_t kind, uint32_t node, uint64_t idx) {  // kind 0 = arena block, 1 = file extent
    return kBase | uint64_t(kind) << 44 | uint64_t(node) << 36 | idx;
  }
  explicit MegalonBackend(const mshim::Api *api) : api_(api) { self_ = this; }
  const char *name() const override { return "megalon"; }
  const char *layout_tag() const override { return " backend=megalon"; }

  // Megalon allows a fixed number of thread registrations per process; every thread that opens a section
  // registers once (lazily: RocksDB's background threads too).
  void thread_init() override {
    thread_local bool done = false;
    if (done) return;
    const int tid = next_tid_.fetch_add(1);
    if (tid >= kMaxThreads) backend_fatal("megalon: more than 32 threads open sections (NR registration limit)");
    api_->reg(tid);
    done = true;
  }

  // node 0 creates every object of every node (index order, kind blocks then extents); the others only look up
  bool create(const Params &p, const SwccPlan &plan, std::string *err) {
    thread_init();
    for (uint32_t v = 0; v < p.nr_nodes; v++)
      for (uint32_t kind = 0; kind < 2; kind++)
        for (uint64_t i = 0; i < (kind ? plan.file_extents : plan.arena_blocks); i++) {
          const int rc = api_->create(id(kind, v, i), kUnit);
          if (rc != 0)
            return *err = "ObjectCreate(" + std::string(kind ? "extent " : "block ") + std::to_string(v) + "/" +
                          std::to_string(i) + ") = " + std::to_string(rc) +
                          " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: MEGALON_REINIT=1)", false;
        }
    return true;
  }
  bool setup(const cxl::region &, uint8_t *, const Params &p, const SwccPlan &plan, uint32_t me,
             std::string *err) override {
    thread_init();
    me_ = me;
    blocks_.assign(p.nr_nodes, {});
    exts_.assign(p.nr_nodes, {});
    for (uint32_t v = 0; v < p.nr_nodes; v++)
      for (uint32_t kind = 0; kind < 2; kind++)
        for (uint64_t i = 0; i < (kind ? plan.file_extents : plan.arena_blocks); i++) {
          size_t got = 0;
          if (api_->lookup(id(kind, v, i), &got) != 0 || got != kUnit)
            return *err = "ObjectLookup(" + std::to_string(kind) + "/" + std::to_string(v) + "/" + std::to_string(i) +
                          ") failed or size " + std::to_string(got), false;
          mshim::Obj h;
          if (api_->read_start(id(kind, v, i), &h) != 0) return *err = "ObjectReadStart for the address", false;
          api_->read_end(&h);
          (kind ? exts_ : blocks_)[v].push_back(h.ptr);
        }
    index_blocks(p.nr_nodes);
    nodes_ = p.nr_nodes;
    // memtable write sections (rocksdb/cxl.h): own blocks only; other memory (secondaries' private memtables,
    // the SstFileWriter's) has no object and gets no section
    auto &s = ROCKSDB_NAMESPACE::cxl::GetSections();
    s.write_begin = [](const void *addr) -> void * { return self_->mem_write_begin(addr); };
    s.write_end = [](void *tok) { self_->mem_write_end(tok); };
    return true;
  }

  void file_write(uint32_t node, uint32_t j, size_t off, const void *src, size_t n) override {
    thread_init();
    mshim::Obj h;
    if (api_->write_start(id(1, node, j), &h) != 0 || h.ptr != extent(node, j))
      backend_fatal("ObjectWriteStart(extent " + std::to_string(j) + ")");
    std::memcpy(h.ptr + off, src, n);
    api_->write_end(&h);
    file_writes_.fetch_add(1, std::memory_order_relaxed);
  }
  void file_read(uint32_t node, uint32_t j, size_t off, void *dst, size_t n) override {
    if (node == me_) {  // owner: direct (decision above)
      std::memcpy(dst, extent(node, j) + off, n);
      return;
    }
    thread_init();
    read_section(id(1, node, j), extent(node, j), extent(node, j) + off, dst, n);
    file_reads_.fetch_add(1, std::memory_order_relaxed);
  }
  ROCKSDB_NAMESPACE::cxl::RemoteResult remote_get(uint32_t node, const void *head, int height, const std::string &key,
                                                  std::string *stored, uint64_t *seq) override {
    thread_init();
    struct Acc {
      MegalonBackend *b;
      uint32_t v;
      const void *next(const void *x, int n) const {
        const void *r = nullptr;
        b->mem_read(v, static_cast<const char *>(x) - n * sizeof(void *), &r, sizeof(r));
        return r;
      }
      void read(const void *p, void *out, size_t n) const { b->mem_read(v, p, out, n); }
    };
    return ROCKSDB_NAMESPACE::cxl::RemoteMemtableGet(head, height, key, stored, seq, Acc{this, node});
  }

  const mshim::Api *api() const override { return api_; }
  std::string stats() const override {
    mshim::Stats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.arena_bytes=" << s.arena_bytes << "\nmegalon.used_bytes=" << s.used_bytes
      << "\nmegalon.created=" << s.created << "\nmegalon.read_sections=" << s.read_sections
      << "\nmegalon.read_retry_notify=" << s.read_retry_notify << "\nmegalon.read_retry_incoherent="
      << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections << "\nmegalon.write_retry="
      << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw << "\nmegalon.flushes=" << s.flushes
      << "\nmegalon.flush_bytes=" << s.flush_bytes << "\nmegalon.replay_flushes=" << s.replay_flushes
      << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes << "\nrdb.mem_write_sections=" << mem_writes_.load()
      << "\nrdb.mem_read_sections=" << mem_reads_.load() << "\nrdb.file_write_sections=" << file_writes_.load()
      << "\nrdb.file_read_sections=" << file_reads_.load() << "\nrdb.read_retries=" << retries_.load()
      << "\nrdb.mem_read_tail_clamps=" << tail_clamps_.load()
      << "\nrdb.megalon_threads=" << next_tid_.load() << "\nshim=" << api_->info << "\n";
    return o.str();
  }

 private:
  static constexpr int kMaxThreads = 32;
  // one read section on object `oid` (base `base`): copy [p, p + n), retry until read_end accepts
  void read_section(uint64_t oid, const uint8_t *base, const void *p, void *dst, size_t n) {
    for (uint32_t a = 0;; a++) {
      mshim::Obj h;
      if (api_->read_start(oid, &h) != 0 || h.ptr != base) backend_fatal("ObjectReadStart");
      std::memcpy(dst, p, n);
      if (api_->read_end(&h)) {
        if (a) retries_.fetch_add(a, std::memory_order_relaxed);
        return;
      }
    }
  }
  void mem_read(uint32_t v, const void *p, void *out, size_t n) {
    uint64_t i;
    if (!block_containing(v, p, &i)) backend_fatal("remote memtable read outside node's arena blocks");
    // verifier LOW-1 (2026-11-03): a fixed-size read (the 5-byte varint probe of patch 0001) of an entry at the tail
    // of a block may extend past the 1 MiB object; copy only the bytes inside this object (inside its section) and
    // zero the rest. An arena allocation never spans blocks, so a varint ends inside the block and a zero byte (high
    // bit clear) can only follow its last byte; a read whose real data crossed the end would be a corrupt entry.
    const size_t in = std::min(n, size_t(kUnit - (static_cast<const uint8_t *>(p) - block(v, i))));
    read_section(id(0, v, i), block(v, i), p, out, in);
    if (in < n) {
      std::memset(static_cast<uint8_t *>(out) + in, 0, n - in);
      tail_clamps_.fetch_add(1, std::memory_order_relaxed);
    }
    mem_reads_.fetch_add(1, std::memory_order_relaxed);
  }
  void *mem_write_begin(const void *addr) {
    uint64_t i;
    if (!block_containing(me_, addr, &i)) return nullptr;
    thread_init();
    thread_local mshim::Obj tok;  // sections never nest (rocksdb/cxl.h), so one per thread
    if (api_->write_start(id(0, me_, i), &tok) != 0 || tok.ptr != block(me_, i))
      backend_fatal("ObjectWriteStart(block " + std::to_string(i) + ")");
    mem_writes_.fetch_add(1, std::memory_order_relaxed);
    return &tok;
  }
  void mem_write_end(void *tok) { api_->write_end(static_cast<mshim::Obj *>(tok)); }

  static inline MegalonBackend *self_ = nullptr;
  const mshim::Api *api_;
  uint32_t me_ = 0, nodes_ = 0;
  std::atomic<int> next_tid_{0};
  std::atomic<uint64_t> mem_writes_{0}, mem_reads_{0}, file_writes_{0}, file_reads_{0}, retries_{0}, tail_clamps_{0};
};

}  // namespace rdbw

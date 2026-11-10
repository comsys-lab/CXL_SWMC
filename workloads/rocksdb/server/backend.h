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
//  megalon-record (--mg-mem-object-bytes / --mg-file-object-bytes, reports/experiments/rocksdb-megalon-record.md): the
//          same blocks and extents, but one object per memtable slot (kind 2) and per file slice (kind 3), index =
//          unit * per_unit + slot. Node 0 creates them in index order, so the objects of one block / extent are
//          contiguous (Megalon's arena is a bump allocator, no inline header); setup verifies that and keeps one base
//          per unit, every object address is base + slot * size. A file span crossing slices takes one section per slice.
//          Both flags at their default (1 MiB) = the block objects above, unchanged.
#pragma once

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
    if (a - it->first >= block_len_) return false;
    *i = it->second;
    return true;
  }

 protected:
  uint64_t block_len_ = kUnit;  // bytes of a block covered by objects (record mode: slots x slot size)
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
  // kind 0 = arena block, 1 = file extent (1 MiB objects); 2 = memtable slot, 3 = file slice (record objects)
  static uint64_t id(uint32_t kind, uint32_t node, uint64_t idx) {
    return kBase | uint64_t(kind) << 44 | uint64_t(node) << 36 | idx;
  }
  // Object sizes: multiples of the object alignment (64 B), at most one unit; a file slice must divide the unit, so
  // an extent is tiled exactly. A memtable slot need not (1,152 B: 910 per block, the 576 B tail is not an object).
  static bool valid_sizes(uint64_t mem_obj, uint64_t file_obj, std::string *err) {
    if (mem_obj == 0 || mem_obj > kUnit || mem_obj % 64 || file_obj == 0 || file_obj > kUnit || file_obj % 64 ||
        kUnit % file_obj)
      return *err = "bad --mg-mem-object-bytes / --mg-file-object-bytes (multiples of 64 B up to 1 MiB; the file object "
                    "must divide 1 MiB)", false;
    return true;
  }
  explicit MegalonBackend(const mshim::Api *api, uint64_t mem_obj = kUnit, uint64_t file_obj = kUnit)
      : api_(api),
        mem_obj_(mem_obj),
        file_obj_(file_obj),
        mem_per_(kUnit / mem_obj),
        file_per_(kUnit / file_obj),
        record_(mem_obj != kUnit || file_obj != kUnit),
        tag_(record_ ? " backend=megalon record=" + std::to_string(mem_obj) + "/" + std::to_string(file_obj)
                     : " backend=megalon") {
    self_ = this;
    block_len_ = mem_per_ * mem_obj_;
  }
  const char *name() const override { return "megalon"; }
  const char *layout_tag() const override { return tag_.c_str(); }
  // arena slot mode of the memtable arenas (0 = off); the block objects keep ordinary arena allocation
  uint64_t arena_slot_bytes() const { return mem_obj_ != kUnit ? mem_obj_ : 0; }
  uint64_t arena_slots_per_block() const { return mem_obj_ != kUnit ? mem_per_ : 0; }

  // Megalon allows a fixed number of thread registrations per process; every thread that opens a section
  // registers once (lazily: RocksDB's background threads too).
  void thread_init() override {
    int &my = my_tid();
    if (my >= 0) return;
    const int tid = next_tid_.fetch_add(1);
    if (tid >= kMaxThreads) backend_fatal("megalon: more than 32 threads open sections (NR registration limit)");
    api_->reg(tid);
    my = tid;
  }

  // node 0 creates every object of every node (index order, kind blocks then extents); the others only look up
  bool create(const Params &p, const SwccPlan &plan, std::string *err) {
    thread_init();
    uint64_t made = 0;
    for (uint32_t v = 0; v < p.nr_nodes; v++)
      for (uint32_t kind = 0; kind < 2; kind++)
        for (uint64_t i = 0; i < (kind ? plan.file_extents : plan.arena_blocks); i++)
          for (uint64_t s = 0; s < per_unit(kind); s++) {
            const int rc = api_->create(obj_id(kind, v, i, s), obj_bytes(kind));
            if (rc != 0)
              return *err = "ObjectCreate(" + std::string(kind ? "extent " : "block ") + std::to_string(v) + "/" +
                            std::to_string(i) + (per_unit(kind) > 1 ? "/" + std::to_string(s) : std::string()) +
                            ") = " + std::to_string(rc) +
                            " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: MEGALON_REINIT=1)", false;
            if (record_ && (++made & 0x3fffff) == 0)
              std::fprintf(stderr, "rocksdb-server: megalon objects created: %lu\n", (unsigned long)made);
          }
    return true;
  }
  bool setup(const cxl::region &r, uint8_t *, const Params &p, const SwccPlan &plan, uint32_t me,
             std::string *err) override {
    thread_init();
    me_ = me;
    blocks_.assign(p.nr_nodes, {});
    exts_.assign(p.nr_nodes, {});
    // one base per block / extent; the other objects of the unit by arithmetic, checked here: the first and last object
    // and every kContigStride-th one must sit at base + slot * size (no per-object walk over ~24M objects)
    for (uint32_t v = 0; v < p.nr_nodes; v++)
      for (uint32_t kind = 0; kind < 2; kind++)
        for (uint64_t i = 0; i < (kind ? plan.file_extents : plan.arena_blocks); i++) {
          const uint64_t per = per_unit(kind), sz = obj_bytes(kind);
          size_t got = 0;
          if (api_->lookup(obj_id(kind, v, i, 0), &got) != 0 || got != sz)
            return *err = "ObjectLookup(" + std::to_string(kind) + "/" + std::to_string(v) + "/" + std::to_string(i) +
                          ") failed or size " + std::to_string(got), false;
          uint8_t *base = nullptr;
          if (!obj_addr(obj_id(kind, v, i, 0), &base)) return *err = "ObjectReadStart for the address", false;
          for (uint64_t s = kContigStride; per > 1; s += kContigStride) {
            const uint64_t at = std::min(s, per - 1);
            uint8_t *a = nullptr;
            if (!obj_addr(obj_id(kind, v, i, at), &a)) return *err = "ObjectReadStart for the address", false;
            if (a != base + at * sz)
              return *err = "object contiguity violation: kind " + std::to_string(kind) + " node " + std::to_string(v) +
                            " unit " + std::to_string(i) + " slot " + std::to_string(at) + " (object index " +
                            std::to_string(i * per + at) + "): offset " + std::to_string(a - base) + ", expected " +
                            std::to_string(at * sz), false;
            if (at == per - 1) break;
          }
          (kind ? exts_ : blocks_)[v].push_back(base);
        }
    index_blocks(p.nr_nodes);
    nodes_ = p.nr_nodes;
    objects_ = p.nr_nodes * (plan.arena_blocks * mem_per_ + plan.file_extents * file_per_);
    if (record_) open_record_counters(r);
    // memtable write sections (rocksdb/cxl.h): own blocks only; other memory (secondaries' private memtables,
    // the SstFileWriter's) has no object and gets no section
    auto &s = ROCKSDB_NAMESPACE::cxl::GetSections();
    s.write_begin = [](const void *addr) -> void * { return self_->mem_write_begin(addr); };
    s.write_end = [](void *tok) { self_->mem_write_end(tok); };
    return true;
  }

  void file_write(uint32_t node, uint32_t j, size_t off, const void *src, size_t n) override {
    thread_init();
    const uint8_t *in = static_cast<const uint8_t *>(src);
    while (n) {  // one write section per object slice (block objects: exactly one)
      const uint64_t s = off / file_obj_;
      const size_t at = off - s * file_obj_, take = std::min<size_t>(n, file_obj_ - at);
      uint8_t *obj = extent(node, j) + s * file_obj_;
      mshim::Obj h;
      SecDiag &sd = sd_[my_tid()];
      const uint64_t t0 = diag_now();
      if (api_->write_start(obj_id(1, node, j, s), &h) != 0 || h.ptr != obj)
        backend_fatal("ObjectWriteStart(extent " + std::to_string(j) + ")");
      sd.start(sd.file_ws, sd.file_ws_100us, sd.file_ws_1ms, diag_now() - t0);
      std::memcpy(h.ptr + at, in, take);
      const uint64_t t1 = diag_now();
      api_->write_end(&h);
      sd.file_we.Add(diag_now() - t1);
      file_writes_.fetch_add(1, std::memory_order_relaxed);
      in += take, off += take, n -= take;
    }
  }
  void file_read(uint32_t node, uint32_t j, size_t off, void *dst, size_t n) override {
    if (node == me_) {  // owner: direct (decision above); an extent's objects are contiguous
      std::memcpy(dst, extent(node, j) + off, n);
      return;
    }
    thread_init();
    uint8_t *out = static_cast<uint8_t *>(dst);
    while (n) {  // one read section per object slice (block objects: exactly one)
      const uint64_t s = off / file_obj_;
      const size_t at = off - s * file_obj_, take = std::min<size_t>(n, file_obj_ - at);
      const uint8_t *obj = extent(node, j) + s * file_obj_;
      read_section(obj_id(1, node, j, s), obj, obj + at, out, take);
      file_reads_.fetch_add(1, std::memory_order_relaxed);
      out += take, off += take, n -= take;
    }
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
    if (record_) record_stats(o);
    diag_stats(o);
    return o.str();
  }

 private:
  static constexpr int kMaxThreads = 32;
  static constexpr uint64_t kContigStride = 64;  // interior objects checked per unit at setup
  uint64_t per_unit(uint32_t kind) const { return kind ? file_per_ : mem_per_; }
  uint64_t obj_bytes(uint32_t kind) const { return kind ? file_obj_ : mem_obj_; }
  // kind here = 0 memtable, 1 file; the id's kind is 2 / 3 when that side uses record objects
  uint64_t obj_id(uint32_t kind, uint32_t node, uint64_t unit, uint64_t s) const {
    return id(obj_bytes(kind) == kUnit ? kind : kind + 2, node, unit * per_unit(kind) + s);
  }
  bool obj_addr(uint64_t oid, uint8_t **p) {
    mshim::Obj h;
    if (api_->read_start(oid, &h) != 0) return false;
    api_->read_end(&h);
    *p = h.ptr;
    return true;
  }
  // Coherence-record counters: API v5 when the shim has it; builds/megalon/78 (API v3, no getter) keeps them in
  // SharedCounters, the first allocation of its SCR at hwcc + 4 KiB (src/shared_memory/cxl_port.h, commit 18ba703107f5):
  // wmeta_allocated +0, wmeta_reclaim +64, wmeta_allocate +128. Read-only; any other build reports "na".
  void open_record_counters(const cxl::region &r) {
    if (api_->version < 5 && std::strstr(api_->info, "megalon=18ba703107f5"))
      scr_counters_ = reinterpret_cast<const uint64_t *>(r.map_va + r.hwcc.offset + 4096);
    if (const char *cfg = std::getenv("RACKOBJ_CONFIG")) {  // record pool = logical_scr_size / 4 B (packed4, objects on)
      std::ifstream f(cfg);
      for (std::string line; std::getline(f, line);) {
        uint64_t v = 0;
        char unit = 0;
        if (std::sscanf(line.c_str(), "logical_scr_size: %lu%c", &v, &unit) >= 1)
          record_slots_ = (unit == 'G' ? v << 30 : unit == 'M' ? v << 20 : unit == 'K' ? v << 10 : v) / 4;
      }
    }
  }
  void record_stats(std::ostringstream &o) const {
    const auto &c = ROCKSDB_NAMESPACE::cxl::GetArenaSlotCounters();
    o << "rdb.objects=" << objects_ << "\nrdb.mem_object_bytes=" << mem_obj_ << "\nrdb.file_object_bytes=" << file_obj_
      << "\nrdb.arena_slot_allocs=" << c.allocs.load() << "\nrdb.arena_slot_cross=" << c.cross.load()
      << "\nrdb.arena_slot_max_bytes=" << c.max_bytes.load() << "\nrdb.mem_read_cross_slot=" << read_cross_.load()
      << "\nmegalon.record_slots=" << record_slots_ << "\n";
    if (api_->version >= 5 && api_->wmeta_counts) {
      mshim::WmetaCounts w{};
      api_->wmeta_counts(&w);
      o << "megalon.reclaim_count=" << w.reclaim_count << "\nmegalon.allocate_count=" << w.allocate_count
        << "\nmegalon.records_in_use=" << w.records_in_use << "\n";
    } else if (scr_counters_) {
      o << "megalon.reclaim_count=" << __atomic_load_n(scr_counters_ + 8, __ATOMIC_RELAXED)
        << "\nmegalon.allocate_count=" << __atomic_load_n(scr_counters_ + 16, __ATOMIC_RELAXED)
        << "\nmegalon.records_in_use=" << __atomic_load_n(scr_counters_, __ATOMIC_RELAXED) << "\n";
    } else {
      o << "megalon.reclaim_count=na\nmegalon.allocate_count=na\nmegalon.records_in_use=na\n";
    }
  }
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
    // Record objects: the same at the end of the slot (an entry never crosses one, patches/0003).
    const uint64_t off = uint64_t(static_cast<const uint8_t *>(p) - block(v, i)), s = off / mem_obj_;
    const uint8_t *obj = block(v, i) + s * mem_obj_;
    const size_t in = std::min(n, size_t(mem_obj_ - (off - s * mem_obj_)));
    read_section(obj_id(0, v, i, s), obj, p, out, in);
    if (in < n) {
      std::memset(static_cast<uint8_t *>(out) + in, 0, n - in);
      tail_clamps_.fetch_add(1, std::memory_order_relaxed);
      if (record_ && n > 5) read_cross_.fetch_add(1, std::memory_order_relaxed);  // not the 5-byte varint probe
    }
    mem_reads_.fetch_add(1, std::memory_order_relaxed);
  }
  void *mem_write_begin(const void *addr) {
    uint64_t i;
    if (!block_containing(me_, addr, &i)) return nullptr;
    thread_init();
    thread_local mshim::Obj tok;  // sections never nest (rocksdb/cxl.h), so one per thread
    const uint64_t s = uint64_t(static_cast<const uint8_t *>(addr) - block(me_, i)) / mem_obj_;
    const uint64_t t0 = diag_now();
    if (api_->write_start(obj_id(0, me_, i, s), &tok) != 0 || tok.ptr != block(me_, i) + s * mem_obj_)
      backend_fatal("ObjectWriteStart(block " + std::to_string(i) + ")");
    const uint64_t d = diag_now() - t0;
    SecDiag &sd = sd_[my_tid()];
    sd.start(sd.mem_ws, sd.mem_ws_100us, sd.mem_ws_1ms, d);
    ROCKSDB_NAMESPACE::cxl::DiagSectionNs() += d;  // patches/0005: excluded from memtable_add_rdb / skiplist_insert_rdb
    mem_writes_.fetch_add(1, std::memory_order_relaxed);
    return &tok;
  }
  void mem_write_end(void *tok) {
    const uint64_t t0 = diag_now();
    api_->write_end(static_cast<mshim::Obj *>(tok));
    const uint64_t d = diag_now() - t0;
    sd_[my_tid()].mem_we.Add(d);
    ROCKSDB_NAMESPACE::cxl::DiagSectionNs() += d;
  }

  // Diagnostic section timers (builds/rocksdb/11; DESIGN.md section 12): every write_start / write_end of a memtable
  // (mem_*) or file (file_*) write section, unsampled; one slot per registered Megalon thread (written by that thread
  // only, the stats reader sums and resets the maxima). ws = write_start (object acquire), we = write_end (flush +
  // unlock); ws_100us / ws_1ms = write_starts longer than 100 us / 1 ms.
  struct alignas(64) SecDiag {
    using T = ROCKSDB_NAMESPACE::cxl::DiagTimer;
    T mem_ws, mem_we, file_ws, file_we;
    std::atomic<uint64_t> mem_ws_100us{0}, mem_ws_1ms{0}, file_ws_100us{0}, file_ws_1ms{0};
    static void start(T &t, std::atomic<uint64_t> &c100, std::atomic<uint64_t> &c1m, uint64_t d) {
      t.Add(d);
      if (d > 100000) c100.fetch_add(1, std::memory_order_relaxed);
      if (d > 1000000) c1m.fetch_add(1, std::memory_order_relaxed);
    }
  };
  static uint64_t diag_now() { return ROCKSDB_NAMESPACE::cxl::DiagNowNs(); }
  static int &my_tid() {
    thread_local int tid = -1;
    return tid;
  }
  void diag_stats(std::ostringstream &o) const {
    auto timer = [&](const char *name, SecDiag::T SecDiag::*m) {
      uint64_t c = 0, ns = 0, mx = 0;
      for (auto &s : sd_) {
        SecDiag::T &t = s.*m;
        c += t.count.load(std::memory_order_relaxed), ns += t.ns.load(std::memory_order_relaxed);
        mx = std::max(mx, t.TakeMax());
      }
      o << "diag." << name << "_count=" << c << "\ndiag." << name << "_ns=" << ns << "\ndiag." << name << "_max_ns=" << mx
        << "\n";
    };
    auto count = [&](const char *name, std::atomic<uint64_t> SecDiag::*m) {
      uint64_t c = 0;
      for (auto &s : sd_) c += (s.*m).load(std::memory_order_relaxed);
      o << "diag." << name << "_count=" << c << "\n";
    };
    timer("mg_mem_wstart", &SecDiag::mem_ws);
    timer("mg_mem_wend", &SecDiag::mem_we);
    count("mg_mem_wstart_gt100us", &SecDiag::mem_ws_100us);
    count("mg_mem_wstart_gt1ms", &SecDiag::mem_ws_1ms);
    timer("mg_file_wstart", &SecDiag::file_ws);
    timer("mg_file_wend", &SecDiag::file_we);
    count("mg_file_wstart_gt100us", &SecDiag::file_ws_100us);
    count("mg_file_wstart_gt1ms", &SecDiag::file_ws_1ms);
  }

  static inline MegalonBackend *self_ = nullptr;
  const mshim::Api *api_;
  uint32_t me_ = 0, nodes_ = 0;
  const uint64_t mem_obj_, file_obj_;   // object sizes (1 MiB = block objects)
  const uint64_t mem_per_, file_per_;   // objects per block / extent
  const bool record_;                   // at least one side uses record objects
  const std::string tag_;               // layout hash tag: both nodes must use the same object sizes
  uint64_t objects_ = 0, record_slots_ = 0;
  const uint64_t *scr_counters_ = nullptr;
  std::atomic<int> next_tid_{0};
  std::atomic<uint64_t> mem_writes_{0}, mem_reads_{0}, file_writes_{0}, file_reads_{0}, retries_{0}, tail_clamps_{0};
  std::atomic<uint64_t> read_cross_{0};
  mutable SecDiag sd_[kMaxThreads];  // diagnostic section timers (stats() resets their maxima)
};

}  // namespace rdbw

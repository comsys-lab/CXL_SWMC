// Megalon backend (DESIGN.md §12): the SWcc data are Megalon objects (paper §4; systems/megalon/src/include/rackobj.h)
// at deterministic ids, one object per indexing unit: per segment s and group g a vector chunk and a link chunk, per
// node u the delete log in chunks of dlog_chunk entries. Every access is one object section, as the paper prescribes:
//   read:  do { ObjectReadStart; read the bytes in place into per-attempt local state } while (!ObjectReadEnd)
//   write: ObjectWriteStart; write whole cache lines (never read prior contents, D3); ObjectWriteEnd (Megalon
//          flushes the whole object)
// An update of part of an object (an HNSW link block) reads it in a read section, then writes the whole block (whole
// lines) in a write section. Sections never nest; no create inside a section. Node 0 creates every object at prepare;
// every node checks every object's size by lookup. The device is mapped by Megalon (whole device at region.map_va);
// the server uses that mapping for the HWcc app range and never maps the device itself.
#pragma once

#include <dlfcn.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_api.h"
#include "shm_hnsw.h"

namespace vdb {

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "vdb-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device, joins the run, start barrier).
inline const MegalonApi *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    *err = std::string("dlopen ") + path + ": " + dlerror();
    return nullptr;
  }
  auto fn = reinterpret_cast<vdb_megalon_api_fn>(dlsym(h, "vdb_megalon_api"));
  if (!fn) {
    *err = path + ": no vdb_megalon_api";
    return nullptr;
  }
  const MegalonApi *api = fn();
  if (!api || api->version != kMegalonApiVersion) {
    *err = path + ": API version mismatch";
    return nullptr;
  }
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
  std::ostringstream o;
  o << "region [0x" << std::hex << va << ", 0x" << va + len << ") is not mapped from " << path << " (stops at 0x" << cur
    << "); Megalon must map the same region config";
  *err = o.str();
  return false;
}

class MegalonBackend;
class MegalonAcc;

struct MegalonMem {
  GraphMeta *meta;  // HWcc
  const MegalonBackend *be;
  uint32_t seg;
};

class MegalonBackend {
 public:
  using Acc = MegalonAcc;
  static constexpr const char *kLayoutTag = " backend=megalon";

  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const MegalonApi *api) : p_(p), api_(api) {
    dlog_chunks_ = (p.max_deletes + p.dlog_chunk - 1) / p.dlog_chunk;
  }
  bool fits(std::string *err) const {
    if (p_.g.vrec_bytes() % 64 || p_.g.links0_bytes() % 64 || p_.g.links_bytes() % 64) {
      *err = "megalon: records and link blocks must be whole cache lines (dim % 16 == 0)";
      return false;
    }
    if (p_.segments >= (1u << 20) || p_.g.groups() >= (1u << 24) || p_.nr_nodes >= (1u << 20) ||
        dlog_chunks_ >= (1u << 24)) {
      *err = "megalon: object id fields overflow";
      return false;
    }
    return true;
  }
  std::string name() const { return "megalon"; }

  // ---- object ids (deterministic; < 2^63 as ObjectCreate requires)
  static constexpr uint64_t kBase = 0x5644ull << 48;  // "VD"
  static uint64_t id(uint64_t kind, uint64_t a, uint64_t b) { return kBase | kind << 44 | a << 24 | b; }
  static uint64_t vec_id(uint32_t s, uint64_t g) { return id(1, s, g); }
  static uint64_t link_id(uint32_t s, uint64_t g) { return id(2, s, g); }
  static uint64_t dlog_id(uint32_t node, uint64_t c) { return id(3, node, c); }
  uint64_t chunk_id(Chunk k, uint32_t s, uint64_t g) const { return k == Chunk::kVec ? vec_id(s, g) : link_id(s, g); }

  template <class F> void for_each_object(F f) const {  // f(id, size)
    for (uint32_t s = 0; s < p_.segments; s++)
      for (uint64_t g = 0; g < p_.g.groups(); g++) {
        f(vec_id(s, g), p_.g.vchunk_bytes());
        f(link_id(s, g), p_.g.lchunk_bytes());
      }
    for (uint32_t u = 0; u < p_.nr_nodes; u++)
      for (uint64_t c = 0; c < dlog_chunks_; c++) f(dlog_id(u, c), uint64_t(p_.dlog_chunk) * sizeof(DlogEntry));
  }
  bool create_objects(std::string *err) const {  // node 0, prepare
    bool ok = true;
    for_each_object([&](uint64_t id, uint64_t size) {
      if (!ok) return;
      int rc = api_->create(id, size);
      if (rc != 0) {
        *err = "ObjectCreate(" + hex(id) + ", " + std::to_string(size) + ") = " + std::to_string(rc) +
               " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, run with MEGALON_REINIT=1)";
        ok = false;
      }
    });
    return ok;
  }
  bool check_objects(std::string *err) const {  // every node, after node 0 published its load
    bool ok = true;
    for_each_object([&](uint64_t id, uint64_t size) {
      size_t got = 0;
      int rc = ok ? api_->lookup(id, &got) : 0;
      if (ok && (rc != 0 || got != size)) {
        *err = "ObjectLookup(" + hex(id) + ") = " + std::to_string(rc) + " size " + std::to_string(got) + ", want " +
               std::to_string(size);
        ok = false;
      }
    });
    return ok;
  }

  // ---- sections
  void thread_init(int tid) const { api_->reg(tid); }
  // Read section over [off, off + len): f(const uint8_t *) may run more than once and must only produce its result
  // (per-attempt local state); returns the result of the accepted attempt.
  template <class F> auto read(uint64_t id, uint64_t off, uint64_t len, F f) const {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    for (;;) {
      MegObj h;
      const int rc = api_->read_start(id, &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(" + hex(id) + ") = " + std::to_string(rc));
      if (off + len > h.size) megalon_fatal("read beyond object " + hex(id));
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(h.ptr + off));
        if (api_->read_end(&h)) return;
      } else {
        R r = f(static_cast<const uint8_t *>(h.ptr + off));
        if (api_->read_end(&h)) return r;
      }
    }
  }
  // Write section; f(base, size) writes whole lines only and reads nothing of the object (D3).
  template <class F> void write_obj(uint64_t id, F f) const {
    MegObj h;
    const int rc = api_->write_start(id, &h);
    if (rc != 0) megalon_fatal("ObjectWriteStart(" + hex(id) + ") = " + std::to_string(rc));
    f(h.ptr, h.size);
    api_->write_end(&h);
  }
  // Write section over [off, off + len), whole lines (len may end at the object end).
  template <class F> void write(uint64_t id, uint64_t off, uint64_t len, F fill) const {
    write_obj(id, [&](uint8_t *base, size_t size) {
      check_lines(id, off, len, size);
      fill(base + off);
    });
  }
  static void check_lines(uint64_t id, uint64_t off, uint64_t len, size_t size) {
    if (off % 64 || off + len > size || (len % 64 && off + len != size))
      megalon_fatal("write of [" + std::to_string(off) + ", +" + std::to_string(len) + ") in object " + hex(id) +
                    " is not whole lines");
  }

  // ---- backend interface (server.cc)
  MegalonMem mem(uint32_t s, GraphMeta *meta) const { return MegalonMem{meta, this, s}; }
  template <class F> void write_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F fill) const {
    write(chunk_id(k, s, g), off, len, fill);
  }
  template <class F> auto read_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F f) const {
    return read(chunk_id(k, s, g), off, len, f);
  }
  void dlog_write(uint32_t node, uint64_t e, const DlogEntry &d) const {
    write(dlog_id(node, e / p_.dlog_chunk), (e % p_.dlog_chunk) * sizeof(DlogEntry), sizeof(DlogEntry),
          [&](uint8_t *dst) { std::memcpy(dst, &d, sizeof(d)); });
  }
  // Entries [from, to) of node's log: one read section per chunk copies them out; f runs after the section ended.
  template <class F> void dlog_scan(uint32_t node, uint64_t from, uint64_t to, F f) const {
    thread_local std::vector<DlogEntry> buf;
    for (uint64_t e = from; e < to;) {
      const uint64_t a = e % p_.dlog_chunk, n = std::min<uint64_t>(p_.dlog_chunk - a, to - e);
      buf.resize(n);
      read(dlog_id(node, e / p_.dlog_chunk), a * sizeof(DlogEntry), n * sizeof(DlogEntry),
           [&](const uint8_t *src) { std::memcpy(buf.data(), src, n * sizeof(DlogEntry)); });
      for (const DlogEntry &d : buf) f(d);
      e += n;
    }
  }
  std::string usage() const {
    uint64_t objs = 0, bytes = 0;
    for_each_object([&](uint64_t, uint64_t sz) { objs++, bytes += (sz + 63) / 64 * 64; });
    return "megalon objects=" + std::to_string(objs) + " object_bytes=" + std::to_string(bytes) + " segments=" +
           std::to_string(p_.segments) + " groups=" + std::to_string(p_.g.groups()) + " per_chunk=" +
           std::to_string(p_.g.per_chunk()) + " vchunk=" + std::to_string(p_.g.vchunk_bytes()) + " lchunk=" +
           std::to_string(p_.g.lchunk_bytes()) + " dlog_chunks_per_node=" + std::to_string(dlog_chunks_) +
           " dlog_chunk_bytes=" + std::to_string(uint64_t(p_.dlog_chunk) * sizeof(DlogEntry)) + " shim=" + api_->info;
  }
  std::string stats() const {
    MegStats s{};
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
  static std::string hex(uint64_t x) {
    char b[24];
    std::snprintf(b, sizeof(b), "%#lx", (unsigned long)x);
    return b;
  }
  Params p_;
  const MegalonApi *api_;
  uint64_t dlog_chunks_;
};

// HNSW accessor (shm_hnsw.h): every chunk access is one Megalon section; reads copy into the caller's scratch.
class MegalonAcc {
 public:
  using Mem = MegalonMem;
  MegalonAcc(const GraphParams &p, Mem m) : p_(p), m_(m) {
    N_ = p.per_chunk();
    vrec_ = p.vrec_bytes();
    l0_ = p.links0_bytes();
    upper_base_ = N_ * l0_;
  }
  GraphMeta *meta() const { return m_.meta; }
  float dot(const float *q, uint32_t i) const {
    return m_.be->read(vid(i), voff(i) + sizeof(ElemHeader), uint64_t(p_.dim) * 4,
                       [&](const uint8_t *v) { return vdb::dot(q, reinterpret_cast<const float *>(v), p_.dim); });
  }
  const ElemHeader &header(uint32_t i, ElemHeader &tmp) const {
    m_.be->read(vid(i), voff(i), sizeof(ElemHeader), [&](const uint8_t *src) { std::memcpy(&tmp, src, sizeof(tmp)); });
    return tmp;
  }
  const float *vec(uint32_t i, float *tmp) const {
    m_.be->read(vid(i), voff(i) + sizeof(ElemHeader), uint64_t(p_.dim) * 4,
                [&](const uint8_t *src) { std::memcpy(tmp, src, size_t(p_.dim) * 4); });
    return tmp;
  }
  const uint32_t *links(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const { return links_mut(i, level, uo, tmp); }
  uint32_t *links_mut(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const {
    const uint64_t n = lbytes(level);
    m_.be->read(lid(i), loff(i, level, uo), n, [&](const uint8_t *src) { std::memcpy(tmp, src, n); });
    return tmp;
  }
  void commit_links(uint32_t i, int level, uint64_t uo, const uint32_t *p) const {
    const uint64_t n = lbytes(level);
    m_.be->write(lid(i), loff(i, level, uo), n, [&](uint8_t *dst) { std::memcpy(dst, p, n); });
  }
  void write_elem(uint32_t i, const ElemHeader &h, const float *v, uint64_t upper_bytes) const {
    m_.be->write(vid(i), voff(i), vrec_, [&](uint8_t *dst) {
      std::memcpy(dst, &h, sizeof(h));
      std::memcpy(dst + sizeof(ElemHeader), v, size_t(p_.dim) * 4);
    });
    const uint64_t l0off = (i % N_) * l0_, uoff = upper_base_ + h.upper_off;
    m_.be->write_obj(lid(i), [&](uint8_t *base, size_t size) {
      MegalonBackend::check_lines(lid(i), l0off, l0_, size);
      std::memset(base + l0off, 0, l0_);
      if (upper_bytes) {
        MegalonBackend::check_lines(lid(i), uoff, upper_bytes, size);
        std::memset(base + uoff, 0, upper_bytes);
      }
    });
  }
  void prefetch(uint32_t) const {}

 private:
  uint64_t vid(uint32_t i) const { return MegalonBackend::vec_id(m_.seg, i / N_); }
  uint64_t lid(uint32_t i) const { return MegalonBackend::link_id(m_.seg, i / N_); }
  uint64_t voff(uint32_t i) const { return (i % N_) * vrec_; }
  uint64_t lbytes(int level) const { return level ? p_.links_bytes() : l0_; }
  uint64_t loff(uint32_t i, int level, uint64_t uo) const {
    return level == 0 ? (i % N_) * l0_ : upper_base_ + uo + uint64_t(level - 1) * p_.links_bytes();
  }
  GraphParams p_;
  Mem m_;
  uint64_t N_, vrec_, l0_, upper_base_;
};

}  // namespace vdb

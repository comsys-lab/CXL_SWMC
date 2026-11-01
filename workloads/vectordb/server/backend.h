// vectordb backends (DESIGN.md §7, §11): where SWcc data lives and which coherence actions wrap its access.
// SWcc objects (the data units a coherence system manages): per segment and group g a vector chunk (~32 MiB,
// immutable once written) and a link chunk (level-0 links + the group's upper-level links); one delete log per node. The common synchronisation (HWcc atomics, P, element locks) is identical in every system.
//   plain   all-HWcc and Popcorn: fixed placement, no coherence actions (direct pointers).
//   megalon paper §4 objects, one object per chunk, every access in a read/write section (megalon_backend.h, §12).
// Backend interface used by server.cc (Server<Backend>): Acc (shm_hnsw.h accessor) and mem(s, meta); thread_init(tid);
// create_objects / check_objects; write_chunk / read_chunk (whole-line writes; reads may re-run their body);
// dlog_write / dlog_scan; usage(), stats().
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

#include "cxl_region.h"
#include "layout.h"

namespace vdb {

enum class Chunk { kVec, kLink };

class PlainBackend {
 public:
  using Acc = PlainAcc;
  static constexpr const char *kLayoutTag = "";  // the plain HWcc layout hash is unchanged
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p) : map_(map), p_(p) {
    uint64_t off = r.swcc.offset;
    vstride_ = page(p.g.vchunk_bytes());
    lstride_ = page(p.g.lchunk_bytes());
    seg_bytes_ = align(p.g.groups() * (vstride_ + lstride_));
    segs_ = off;
    off += seg_bytes_ * p.segments;
    dlog_ = off;
    dlog_node_ = align((p.max_deletes + p.dlog_chunk - 1) / p.dlog_chunk * p.dlog_chunk * sizeof(DlogEntry));
    off += dlog_node_ * p.nr_nodes;
    end_ = off;
    swcc_end_ = r.swcc.end();
  }
  bool fits(std::string *err) const {
    if (end_ > swcc_end_) {
      *err = "SWcc too small: need " + std::to_string(end_) + " B end, have " + std::to_string(swcc_end_);
      return false;
    }
    return true;
  }
  std::string name() const { return "plain"; }
  uint8_t *vec_chunk(uint32_t s, uint64_t g) const { return map_ + segs_ + s * seg_bytes_ + g * vstride_; }
  uint8_t *link_chunk(uint32_t s, uint64_t g) const {
    return map_ + segs_ + s * seg_bytes_ + p_.g.groups() * vstride_ + g * lstride_;
  }
  DlogEntry *dlog(uint32_t node) const { return reinterpret_cast<DlogEntry *>(map_ + dlog_ + node * dlog_node_); }
  // segment s's SWcc arena: all its vector chunks then all its link chunks (2 MiB aligned; De Stijl T per segment)
  uint8_t *seg_arena(uint32_t s) const { return map_ + segs_ + s * seg_bytes_; }
  uint64_t seg_arena_bytes() const { return seg_bytes_; }

  Acc::Mem mem(uint32_t s, GraphMeta *meta) const {
    Acc::Mem m{meta, {}, {}};
    for (uint64_t g = 0; g < p_.g.groups(); g++) {
      m.vec.push_back(vec_chunk(s, g));
      m.link.push_back(link_chunk(s, g));
    }
    return m;
  }
  void thread_init(int) const {}
  bool create_objects(std::string *) const { return true; }
  bool check_objects(std::string *) const { return true; }
  uint8_t *chunk(Chunk k, uint32_t s, uint64_t g) const { return k == Chunk::kVec ? vec_chunk(s, g) : link_chunk(s, g); }
  // fill(dst) writes the bytes at chunk offset off
  template <class F> void write_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t, F fill) const {
    fill(chunk(k, s, g) + off);
  }
  template <class F> auto read_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t, F f) const {
    return f(static_cast<const uint8_t *>(chunk(k, s, g) + off));
  }
  void dlog_write(uint32_t node, uint64_t e, const DlogEntry &d) const {
    std::memcpy(dlog(node) + e, &d, sizeof(d));
    t_mod_bytes += sizeof(d);
  }
  template <class F> void dlog_scan(uint32_t node, uint64_t from, uint64_t to, F f) const {
    const DlogEntry *log = dlog(node);
    for (uint64_t e = from; e < to; e++) {
      DlogEntry d;
      std::memcpy(&d, log + e, sizeof(d));
      f(d);
    }
  }
  std::string stats() const { return ""; }
  std::string usage() const {
    return "plain segments=" + std::to_string(p_.segments) + " groups=" + std::to_string(p_.g.groups()) +
           " per_chunk=" + std::to_string(p_.g.per_chunk()) + " vchunk=" + std::to_string(p_.g.vchunk_bytes()) +
           " lchunk=" + std::to_string(p_.g.lchunk_bytes()) + " seg_bytes=" + std::to_string(seg_bytes_) +
           " dlog_per_node=" + std::to_string(dlog_node_) +
           " swcc_used_end=" + std::to_string(end_);
  }

 private:
  static uint64_t page(uint64_t x) { return (x + 4095) / 4096 * 4096; }
  static uint64_t align(uint64_t x) { return (x + (2ull << 20) - 1) / (2ull << 20) * (2ull << 20); }
  uint8_t *map_;
  Params p_;
  uint64_t vstride_, lstride_, seg_bytes_, segs_, dlog_, dlog_node_, end_, swcc_end_;
};

}  // namespace vdb

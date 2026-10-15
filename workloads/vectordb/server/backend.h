// vectordb backends (DESIGN.md §7): where SWcc objects live and which coherence actions wrap their access.
// Objects: raw chunk (node, seg, j) = chunk_recs records; delete-log chunk (node, j) = dlog_chunk entries;
// index blob (node, seg). The common synchronisation (HWcc atomics, P, descriptors) is not here: it is identical
// in every system.
//   plain   all-HWcc and Popcorn: deterministic placement in per-node SWcc partitions, no coherence actions.
//   megalon (later): paper §4 objects (ObjectCreate / read and write sections), same object granularity.
#pragma once

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>

#include "cxl_region.h"
#include "layout.h"

namespace vdb {

struct Obj {
  enum Kind : uint8_t { kRaw, kDlog, kIndex } kind;
  uint32_t node, seg, j;
  uint64_t off, size;  // off: SWcc offset where the plain backend placed it (index: from the descriptor)
};

class Backend {
 public:
  virtual ~Backend() = default;
  virtual std::string name() const = 0;
  virtual Obj raw_chunk(uint32_t node, uint32_t seg, uint32_t j) const = 0;
  virtual Obj dlog_chunk(uint32_t node, uint32_t j) const = 0;
  // owner node: place a new index blob of `size` bytes for (node, seg); returns its descriptor fields
  virtual Obj index_create(uint32_t node, uint32_t seg, uint64_t size) = 0;
  virtual Obj index_ref(uint32_t node, uint32_t seg, uint64_t off, uint64_t size) const = 0;
  // Coherence sections. read: body may run more than once (retry); it must only write per-attempt local state.
  // write: whole cache lines only, never read prior contents (D3).
  virtual void read(const Obj &o, const std::function<void(const uint8_t *, uint64_t)> &body) = 0;
  virtual void write(const Obj &o, const std::function<void(uint8_t *, uint64_t)> &body) = 0;
  // Zero-copy address for long-lived read-only views (sealed index blobs searched by Knowhere in place).
  virtual const uint8_t *view(const Obj &o) const = 0;
  virtual std::string usage() const = 0;  // for the manifest
};

// Per-node SWcc partition: [raw: max_segs * seg_cap records][dlog: max_deletes entries][index: bump to the end].
class PlainBackend : public Backend {
 public:
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p, uint32_t self)
      : map_(map), p_(p), self_(self) {
    part_ = r.swcc.size / p.nr_nodes / r.align * r.align;
    base_ = r.swcc.offset;
    raw_bytes_ = uint64_t(p.max_segs) * p.seg_cap * rec_bytes(p);
    uint64_t chunks = (p.max_deletes + p.dlog_chunk - 1) / p.dlog_chunk;
    dlog_bytes_ = chunks * p.dlog_chunk * sizeof(DlogEntry);
    index_base_ = (raw_bytes_ + dlog_bytes_ + 4095) / 4096 * 4096;
    cursor_ = index_base_;
  }
  bool fits(std::string *err) const {
    if (index_base_ >= part_) {
      *err = "SWcc partition " + std::to_string(part_) + " B too small for raw+dlog " + std::to_string(index_base_);
      return false;
    }
    return true;
  }
  std::string name() const override { return "plain"; }
  Obj raw_chunk(uint32_t node, uint32_t seg, uint32_t j) const override {
    uint64_t rb = rec_bytes(p_), cb = uint64_t(p_.chunk_recs) * rb;
    return Obj{Obj::kRaw, node, seg, j, node_base(node) + uint64_t(seg) * p_.seg_cap * rb + j * cb, cb};
  }
  Obj dlog_chunk(uint32_t node, uint32_t j) const override {
    uint64_t cb = uint64_t(p_.dlog_chunk) * sizeof(DlogEntry);
    return Obj{Obj::kDlog, node, 0, j, node_base(node) + raw_bytes_ + j * cb, cb};
  }
  Obj index_create(uint32_t node, uint32_t seg, uint64_t size) override {
    if (node != self_) throw std::logic_error("index_create for another node");
    uint64_t off = cursor_;
    cursor_ = (cursor_ + size + 4095) / 4096 * 4096;
    if (cursor_ > part_) throw std::runtime_error("SWcc index region full");
    return Obj{Obj::kIndex, node, seg, 0, node_base(node) + off, size};
  }
  Obj index_ref(uint32_t node, uint32_t seg, uint64_t off, uint64_t size) const override {
    return Obj{Obj::kIndex, node, seg, 0, off, size};
  }
  void read(const Obj &o, const std::function<void(const uint8_t *, uint64_t)> &body) override {
    body(map_ + o.off, o.size);
  }
  void write(const Obj &o, const std::function<void(uint8_t *, uint64_t)> &body) override {
    body(map_ + o.off, o.size);
  }
  const uint8_t *view(const Obj &o) const override { return map_ + o.off; }
  std::string usage() const override {
    return "plain part=" + std::to_string(part_) + " raw=" + std::to_string(raw_bytes_) +
           " dlog=" + std::to_string(dlog_bytes_) + " index_used=" + std::to_string(cursor_ - index_base_);
  }

 private:
  uint64_t node_base(uint32_t node) const { return base_ + uint64_t(node) * part_; }
  uint8_t *map_;
  Params p_;
  uint32_t self_;
  uint64_t part_, base_, raw_bytes_, dlog_bytes_, index_base_, cursor_;
};

}  // namespace vdb

// vectordb backends (DESIGN.md §7, §11): where SWcc data lives and which coherence actions wrap its access.
// SWcc regions: per segment level-0 slots (capacity * slot_bytes) and upper-level link arena; one delete log per
// node. The common synchronisation (HWcc atomics, P, element locks) is identical in every system.
//   plain   all-HWcc and Popcorn: fixed placement, no coherence actions.
//   megalon (next): paper §4 objects with read/write sections; granularity decided with the user.
#pragma once

#include <cstdint>
#include <string>

#include "cxl_region.h"
#include "layout.h"

namespace vdb {

class PlainBackend {
 public:
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p) : map_(map), p_(p) {
    uint64_t off = r.swcc.offset;
    seg_bytes_ = align(p.g.capacity * p.g.slot_bytes()) + align(p.g.upper_arena_bytes());
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
  uint8_t *level0(uint32_t s) const { return map_ + segs_ + s * seg_bytes_; }
  uint8_t *upper(uint32_t s) const { return level0(s) + align(p_.g.capacity * p_.g.slot_bytes()); }
  DlogEntry *dlog(uint32_t node) const { return reinterpret_cast<DlogEntry *>(map_ + dlog_ + node * dlog_node_); }
  std::string usage() const {
    return "plain segments=" + std::to_string(p_.segments) + " seg_bytes=" + std::to_string(seg_bytes_) +
           " dlog_per_node=" + std::to_string(dlog_node_) +
           " swcc_used_end=" + std::to_string(end_);
  }

 private:
  static uint64_t align(uint64_t x) { return (x + (2ull << 20) - 1) / (2ull << 20) * (2ull << 20); }
  uint8_t *map_;
  Params p_;
  uint64_t seg_bytes_, segs_, dlog_, dlog_node_, end_, swcc_end_;
};

}  // namespace vdb

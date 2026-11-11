// socialgraph backends (DESIGN.md §4): where the graph image lives and which coherence actions wrap each record
// access. Server logic (graph_ops.h, server.cc) is written once against this interface and compiled per backend
// (template parameter Be), as vectordb's Server<Backend>; systems differ only in region config and kernel for the
// plain-mmap backend (All HWcc, Popcorn, De Stijl), and in this class for Megalon (part 5).
//
// Records (layout.h ObjKind): kNode = one NodeSlot (slot index), kAdj = one primary adjacency block (node slot index),
// kOvf = one 4 KiB overflow block (block index). adj_index is read-only after the build: the backend answers
// adj_off(slot) from wherever it keeps it (plain: the image array; Megalon: a private copy or a HWcc array).
//
// Interface (duck-typed; MmapBackend in mmap_backend.h is the reference):
//   static constexpr const char *kName;              "plain" / "megalon-record" / "megalon-chunk"
//   const ImageHeader &header() const;               image header (validated by check_header at attach)
//   bool has_adj(uint64_t slot) const;  uint64_t adj_off(uint64_t slot) const;
//   uint64_t rec_bytes(ObjKind k, uint64_t idx) const;   record size (kAdj: primary block bytes of that node)
//   void thread_init(int tid);                       every thread that touches records, once at its start
//   template <class F> auto read(ObjKind k, uint64_t idx, F f);
//       f(const uint8_t *rec) -> value. A read section: Megalon may re-run f (f must be idempotent and must not
//       keep pointers into rec after it returns). Nested read() calls (adjacency walk: kAdj then kOvf segments)
//       are allowed. The seqlock in graph_ops.h runs inside f on every backend.
//   template <class F> void write(ObjKind k, uint64_t idx, F f);
//       f(uint8_t *rec): in-place modification of one record by the calling (writer) thread. Before f runs, the
//       backend gives the caller write ownership of the record's lines (plain: an atomic no-op RMW on every 4 KiB page
//       the record covers, so that a page-coherence system faults the page for write before the first read of its
//       bytes; Megalon: a write section). Nested write() calls (addlink: kAdj, then a kOvf pool block) are allowed.
//       write() of a sub-range: write_range(k, idx, off, len, f) with f(uint8_t *rec) (only [off, off+len) is owned
//       / flushed; the plain backend owns the pages of that range).
//   std::string usage() const, stats() const;        one line for logs / stats text
// Staleness bound (De Stijl): the plain backend exposes image_base()/image_bytes() for region_apply_staleness; other
// backends return nullptr / 0.
#pragma once

#include <cstdint>
#include <string>

#include "layout.h"

namespace sg {

// Record ids of the staleness logs (stale_log.h): kind in bits 40..47, slot / block index below.
constexpr uint64_t kRidNode = 1, kRidList = 2;
inline uint64_t rid(uint64_t kind, uint64_t idx) { return (kind << 40) | idx; }

}  // namespace sg

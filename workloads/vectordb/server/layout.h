// vectordb shared layout (DESIGN.md §5-§7, docs/hwcc-contract.md).
// HWcc (region.app): P, per-node counters, applied bitmap, segment descriptors; computed from Params only.
// SWcc: per-node partitions with raw-record, delete-log and index regions (placement: backend.h).
#pragma once

#include <cstdint>
#include <string>

#include "hwcc_app.h"

namespace vdb {

struct Params {
  uint32_t dim = 768;
  uint32_t nr_nodes = 2;
  uint64_t max_writes = 1u << 24;  // W: applied bitmap size (trace writes must stay below)
  uint64_t max_ids = 2000000;      // id space (pool A + pool B)
  uint32_t seg_cap = 50000;        // C: records per segment
  uint32_t chunk_recs = 50000;     // R: records per raw object (coherence unit for object-based backends)
  uint32_t max_segs = 256;         // per node
  uint32_t dlog_chunk = 4096;      // delete-log entries per object
  uint64_t max_deletes = 1u << 23; // per node
  std::string describe() const {
    return "dim=" + std::to_string(dim) + " nr_nodes=" + std::to_string(nr_nodes) +
           " max_writes=" + std::to_string(max_writes) + " max_ids=" + std::to_string(max_ids) +
           " seg_cap=" + std::to_string(seg_cap) + " chunk_recs=" + std::to_string(chunk_recs) +
           " max_segs=" + std::to_string(max_segs) + " dlog_chunk=" + std::to_string(dlog_chunk) +
           " max_deletes=" + std::to_string(max_deletes);
  }
};

// ---- SWcc record formats: whole cache lines only (Megalon D3 write-section contract, same in every system) ----
struct alignas(64) RecHeader {  // followed by float vec[dim] (dim * 4 must be a multiple of 64)
  uint64_t id;
  uint32_t ins_seq;
  uint32_t check;  // id ^ ins_seq ^ kRecMagic: debug canary for torn/unpublished records
  uint8_t pad[48];
};
static_assert(sizeof(RecHeader) == 64, "record header is one line");
constexpr uint32_t kRecMagic = 0x5644425fu;

struct alignas(64) DlogEntry {
  uint64_t id;
  uint32_t del_seq;
  uint32_t check;  // id ^ del_seq ^ kRecMagic
  uint8_t pad[48];
};
static_assert(sizeof(DlogEntry) == 64, "delete-log entry is one line");

inline uint64_t rec_bytes(const Params &p) { return sizeof(RecHeader) + uint64_t(p.dim) * 4; }

// ---- HWcc descriptors ----
enum SegState : uint32_t { kSegFree = 0, kSegGrowing = 1, kSegSealed = 2, kSegIndexed = 3 };

struct alignas(64) SegDesc {  // written only by the owner node
  uint32_t state;       // release-stored; readers acquire once per query and fix the path
  uint32_t published;   // records [0, published) are complete (release-stored after each append)
  uint32_t cap;         // records this segment holds when sealed
  uint32_t pad0;
  uint64_t idx_off;     // SWcc offset of the index blob (plain backend), valid once INDEXED
  uint64_t idx_size;
  uint64_t sealed_ns, indexed_ns;  // owner's CLOCK_MONOTONIC (diagnostics)
  uint8_t pad1[16];
};
static_assert(sizeof(SegDesc) == 64, "descriptor is one line");

struct alignas(64) NodeLine {  // written only by node v
  uint64_t seg_count;      // descriptors [0, seg_count) are initialised (release)
  uint64_t dlog_count;     // delete-log entries [0, dlog_count) are complete (release)
  uint64_t loaded;         // run_id once the node's initial segments are published
  uint64_t writes_applied; // diagnostics
  uint8_t pad[32];
};
static_assert(sizeof(NodeLine) == 64, "node line");

struct HwccLayout {
  cxl::hwcc::layout L;
  uint64_t off_p, off_nodes, off_applied, off_desc;
  explicit HwccLayout(const Params &p) {
    L.add(("vdb " + p.describe()).c_str(), 0, 8);  // parameters go into the layout hash
    off_p = L.add("P", 8);
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
    off_applied = L.add("applied", (p.max_writes + 1 + 63) / 64 * 8);
    off_desc = L.add("desc", uint64_t(p.nr_nodes) * p.max_segs * sizeof(SegDesc));
  }
};

// Typed view over the mapped app range.
struct Hwcc {
  uint64_t *P;
  NodeLine *nodes;
  uint64_t *applied;
  SegDesc *desc;
  uint32_t max_segs;
  Hwcc(uint8_t *app, const HwccLayout &h, const Params &p)
      : P(reinterpret_cast<uint64_t *>(app + h.off_p)),
        nodes(reinterpret_cast<NodeLine *>(app + h.off_nodes)),
        applied(reinterpret_cast<uint64_t *>(app + h.off_applied)),
        desc(reinterpret_cast<SegDesc *>(app + h.off_desc)),
        max_segs(p.max_segs) {}
  SegDesc &seg(uint32_t node, uint32_t i) const { return desc[uint64_t(node) * max_segs + i]; }
};

}  // namespace vdb

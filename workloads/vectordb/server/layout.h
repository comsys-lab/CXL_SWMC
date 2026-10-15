// vectordb shared layout (DESIGN.md §11 segments, docs/hwcc-contract.md).
// A segment = one HNSW graph (shm_hnsw.h) holding the records with id % segments == s (Qdrant-style: segment count
// = CPUs of the VM socket; every node writes every segment under the segment's reader-writer lock).
// HWcc (region.app): P, per-node lines, applied bitmap, per segment {rwlock, graph meta}.
// SWcc: per segment level-0 slots and upper-level link arena; one delete log per node (placement: backend.h).
#pragma once

#include <cstdint>
#include <string>

#include "hwcc_app.h"
#include "shm_hnsw.h"

namespace vdb {

struct Params {
  uint32_t nr_nodes = 2;
  uint32_t segments = 32;          // host node0 logical CPUs = vCPUs of all VMs (user decision 2026-10-15)
  GraphParams g;                   // dim, M, ef_construction; capacity derived: ceil(max_ids / segments)
  uint64_t max_writes = 1u << 24;  // W: applied bitmap size (trace writes must stay below)
  uint64_t max_ids = 2000000;      // record id space (pool A + pool B)
  uint32_t dlog_chunk = 4096;      // delete-log entries per object
  uint64_t max_deletes = 1u << 23; // per node
  void derive() { g.capacity = (max_ids + segments - 1) / segments; }
  uint32_t seg_of(uint64_t id) const { return uint32_t(id % segments); }
  std::string describe() const {
    return "nr_nodes=" + std::to_string(nr_nodes) + " segments=" + std::to_string(segments) +
           " dim=" + std::to_string(g.dim) + " M=" + std::to_string(g.M) + " efc=" + std::to_string(g.ef_construction) +
           " capacity=" + std::to_string(g.capacity) + " max_writes=" + std::to_string(max_writes) +
           " max_ids=" + std::to_string(max_ids) + " dlog_chunk=" + std::to_string(dlog_chunk) +
           " max_deletes=" + std::to_string(max_deletes);
  }
};

struct alignas(64) DlogEntry {  // whole line (Megalon D3 write-section contract, same in every system)
  uint64_t id;
  uint32_t del_seq;
  uint32_t check;  // id ^ del_seq ^ kDlogMagic
  uint8_t pad[48];
};
static_assert(sizeof(DlogEntry) == 64, "delete-log entry is one line");
constexpr uint32_t kDlogMagic = 0x5644425fu;

struct alignas(64) NodeLine {  // written only by node v
  uint64_t dlog_count;      // delete-log entries [0, dlog_count) are complete (release)
  uint64_t loaded;          // run_id once the node is ready to serve
  uint64_t writes_applied;  // diagnostics
  uint8_t pad[40];
};
static_assert(sizeof(NodeLine) == 64, "node line");

struct alignas(64) SegLines {  // HWcc per segment: lock and graph meta on separate lines
  cxl::hwcc::rwlock lock;
  GraphMeta meta;
};

struct HwccLayout {
  cxl::hwcc::layout L;
  uint64_t off_p, off_nodes, off_applied, off_segs;
  explicit HwccLayout(const Params &p) {
    L.add(("vdb-seg " + p.describe()).c_str(), 0, 8);  // parameters go into the layout hash
    off_p = L.add("P", 8);
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
    off_applied = L.add("applied", (p.max_writes + 1 + 63) / 64 * 8);
    off_segs = L.add("segments", uint64_t(p.segments) * sizeof(SegLines));
  }
};

struct Hwcc {
  uint64_t *P;
  NodeLine *nodes;
  uint64_t *applied;
  SegLines *segs;
  Hwcc(uint8_t *app, const HwccLayout &h)
      : P(reinterpret_cast<uint64_t *>(app + h.off_p)),
        nodes(reinterpret_cast<NodeLine *>(app + h.off_nodes)),
        applied(reinterpret_cast<uint64_t *>(app + h.off_applied)),
        segs(reinterpret_cast<SegLines *>(app + h.off_segs)) {}
};

}  // namespace vdb

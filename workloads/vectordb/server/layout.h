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
  uint64_t dlog_chunks() const { return (max_deletes + dlog_chunk - 1) / dlog_chunk; }  // per node
  // measurement (trace): one slot per coherence object of the Megalon backend (vector + link chunk per segment
  // group, delete-log chunks per node), sized identically for every backend
  // (element layout, GraphParams::elem_objects: vector + level-0 + upper object per slot)
  uint64_t trace_objects() const {
    return uint64_t(segments) * g.groups() * (g.elem_objects ? 3 : 2) + uint64_t(nr_nodes) * dlog_chunks();
  }
  std::string describe() const {
    return "nr_nodes=" + std::to_string(nr_nodes) + " segments=" + std::to_string(segments) +
           " dim=" + std::to_string(g.dim) + " M=" + std::to_string(g.M) + " efc=" + std::to_string(g.ef_construction) +
           " capacity=" + std::to_string(g.capacity) + " chunk_bytes=" + std::to_string(g.chunk_bytes) + " max_writes=" + std::to_string(max_writes) +
           " max_ids=" + std::to_string(max_ids) + " dlog_chunk=" + std::to_string(dlog_chunk) +
           " max_deletes=" + std::to_string(max_deletes) + (g.is_sq8() ? " vec=sq8" : "") +  // fp32: text unchanged
           (g.small_groups() ? " upper_blocks=" + std::to_string(g.upper_group_blocks()) : "") +  // large groups: unchanged
           (g.elem_objects ? " objects=element" : "");  // chunk layouts: text unchanged
  }
  // HWcc objseq array (unused since vdb build 10, stays 0): kept in the layout when it is small (every layout before
  // the page-granularity experiment: <= a few thousand objects, so their layout hash and offsets are unchanged); a
  // layout with more than kObjseqAlwaysObjects objects (4 KiB pages: 27M objects = 216 MB of the 256 MiB HWcc budget)
  // gets it only with --trace-dir (trace = true; every node and --print-app-bytes must pass the same --trace-dir).
  static constexpr uint64_t kObjseqAlwaysObjects = 1ull << 20;
  bool trace = false;  // --trace-dir given (not part of describe(): it only adds the objseq field, which is hashed)
  bool has_objseq() const { return trace || trace_objects() <= kObjseqAlwaysObjects; }
};

// E1 visibility of a record for snapshot s with the stale-header guard (shm_hnsw.h): -1 = header rejected (canary,
// upper-arena bounds, ext_id >= max_ids or ins_seq > max_writes), 1 = visible (inserted at or before s, not deleted
// at or before s), 0 = not visible. del_seq: the node's private delete sequence per record id (kInf = live).
// The vdb-server search predicate (server.cc run_segment) and tests/stale_header_test.cc use this function.
inline int elem_visible(const ElemHeader &hin, uint32_t s, const uint32_t *del_seq, const Params &p) {
  const ElemHeader h = hin;  // one copy: check and use the same bytes (plain headers are read in place)
  if (!elem_header_ok(h, p.g) || h.ext_id >= p.max_ids || h.ins_seq > p.max_writes) return -1;
  return h.ins_seq <= s && __atomic_load_n(&del_seq[h.ext_id], __ATOMIC_RELAXED) > s ? 1 : 0;
}

// sq8 quantizer in HWcc (only with --vec-format sq8; the fp32 layout has no such field): node 0 writes the
// parameters of the init dir's sq8.bin at prepare, then releases `ready`; read-only afterwards. Every node copies them
// into private memory after the start barrier (GraphParams::sq8) and checks dim and the FNV-1a sum.
struct alignas(64) Sq8Line {
  uint64_t ready;  // kSq8Magic once the parameters below are complete (release)
  uint32_t dim;
  uint32_t pad0;
  uint64_t fnv;    // FNV-1a 64 over the 2 dim floats
  uint8_t pad[40];
};
static_assert(sizeof(Sq8Line) == 64, "sq8 line");
constexpr uint64_t kSq8Magic = 0x5344423853513852ull;
inline uint64_t sq8_fnv(const float *p, uint32_t dim) {
  uint64_t h = 1469598103934665603ull;
  const uint8_t *b = reinterpret_cast<const uint8_t *>(p);
  for (uint64_t i = 0; i < uint64_t(dim) * 8; i++) h = (h ^ b[i]) * 1099511628211ull;
  return h;
}

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
  uint64_t off_p, off_nodes, off_applied, off_segs, off_wsec, off_objseq, off_sq8 = 0;  // off_sq8: sq8 only
  // backend_tag: "" for plain (hash unchanged), " backend=megalon" for Megalon; the size never depends on it
  explicit HwccLayout(const Params &p, const char *backend_tag = "") {
    L.add(("vdb-seg " + p.describe() + backend_tag).c_str(), 0, 8);  // parameters go into the layout hash
    off_p = L.add("P", 8);
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
    off_applied = L.add("applied", (p.max_writes + 1 + 63) / 64 * 8);
    off_segs = L.add("segments", uint64_t(p.segments) * sizeof(SegLines));
    // measurement (vdb-server --trace-dir, Megalon only; plain never touches them, nor does Megalon without trace):
    // wsec = write sections completed by all nodes; objseq[o] = wsec value of the last write section on object o
    off_wsec = L.add("wsec", 64);
    off_objseq = p.has_objseq() ? L.add("objseq", (p.trace_objects() * 8 + 63) / 64 * 64) : 0;  // 0: no objseq field
    if (p.g.is_sq8()) off_sq8 = L.add("sq8", sizeof(Sq8Line) + (uint64_t(p.g.dim) * 8 + 63) / 64 * 64);
  }
};

struct Hwcc {
  uint64_t *P;
  NodeLine *nodes;
  uint64_t *applied;
  SegLines *segs;
  uint64_t *wsec;
  uint64_t *objseq;
  Sq8Line *sq8 = nullptr;  // sq8 only: line, then 2 dim floats
  Hwcc(uint8_t *app, const HwccLayout &h)
      : P(reinterpret_cast<uint64_t *>(app + h.off_p)),
        nodes(reinterpret_cast<NodeLine *>(app + h.off_nodes)),
        applied(reinterpret_cast<uint64_t *>(app + h.off_applied)),
        segs(reinterpret_cast<SegLines *>(app + h.off_segs)),
        wsec(reinterpret_cast<uint64_t *>(app + h.off_wsec)),
        objseq(h.off_objseq ? reinterpret_cast<uint64_t *>(app + h.off_objseq) : nullptr),
        sq8(h.off_sq8 ? reinterpret_cast<Sq8Line *>(app + h.off_sq8) : nullptr) {}
  float *sq8_params() const { return reinterpret_cast<float *>(sq8 + 1); }
};

}  // namespace vdb

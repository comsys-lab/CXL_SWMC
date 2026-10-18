// rocksdb workload shared layout (DESIGN.md §2-§3, docs/hwcc-contract.md).
// HWcc app: global stamp, per node {node line, memtable descriptor, FS directory}, reader epoch lines.
// SWcc: node v owns the v-th equal share (1 MiB aligned): [arena blocks][file extents].
// Same layout on every system; the backend tag only enters the hash (both nodes must run the same backend).
// Every shared word is accessed with aligned <= 8 B atomics (hwcc_app.h); a field written by one node sits in that
// node's own lines.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

#include "cxl_region.h"
#include "hwcc_app.h"

namespace rdbw {

constexpr uint64_t kUnit = 1ull << 20;  // arena block = file extent = Megalon object (user decision 2026-10-18)
constexpr uint32_t kMaxMemtables = 8;   // descriptor entries: mutable + immutables (max_write_buffer_number <= 8)
constexpr uint32_t kNameWords = 7;      // file name <= 55 B + NUL, packed in u64 words
constexpr uint32_t kMaxTargets = 8;     // epoch line: one word per target node

struct Params {
  uint32_t nr_nodes = 2;
  uint32_t epoch_slots = 64;    // reader epoch slots per node (server threads + RocksDB background threads)
  uint32_t max_files = 2048;    // directory slots per node
  uint32_t max_ext = 192;       // extents per file (max file size = max_ext MiB)
  uint64_t arena_blocks = 512;  // arena blocks per node
  uint64_t file_extents = 0;    // file extents per node (0 = the rest of the node's share)
  uint64_t keys = 0;            // key space 0..keys-1
  std::string describe() const {
    return "nr_nodes=" + std::to_string(nr_nodes) + " epoch_slots=" + std::to_string(epoch_slots) +
           " max_files=" + std::to_string(max_files) + " max_ext=" + std::to_string(max_ext) +
           " arena_blocks=" + std::to_string(arena_blocks) + " file_extents=" + std::to_string(file_extents) +
           " keys=" + std::to_string(keys);
  }
};

struct alignas(64) NodeLine {  // written only by node v
  uint64_t loaded;             // run_id once the node's DB is open and its image ingested
  uint64_t puts;               // diagnostics
  uint64_t objects;            // node 0 only: run_id once every Megalon object of every node exists
  uint8_t pad[40];
};
static_assert(sizeof(NodeLine) == 64, "node line");

// Memtable descriptor of node v (seqlock; written only by node v with its DB mutex held). gen = seq / 2.
struct MemEntry {
  uint64_t id, head, height;
};
struct alignas(64) Desc {
  uint64_t seq;        // odd while being written
  uint64_t flush_gen;  // gen of the last install that dropped a memtable (its content is in the MANIFEST by then)
  uint64_t n;          // entries in m[] (mutable first, then immutables newest first)
  uint64_t pad;
  MemEntry m[kMaxMemtables];
};
static_assert(sizeof(Desc) % 64 == 0, "descriptor lines");

// FS directory slot of node v (per-slot seqlock for name/state changes; written only by node v).
// size grows with appends (release after the data and the extent entries it covers).
struct alignas(64) FileHead {
  uint64_t seq;    // odd while name/state change
  uint64_t state;  // 0 free, 1 live
  uint64_t size;   // bytes written
  uint64_t name[kNameWords];
  uint64_t serial;  // owner's creation counter (newest of several retired slots with one name, cxlfs.h find)
};
static_assert(sizeof(FileHead) == 128, "file head");

struct alignas(64) EpochLine {  // written only by the slot's owner thread (reader node u, slot s)
  uint64_t e[kMaxTargets];      // e[v] = 0 idle, else the gen of node v's state in use (>= 1)
};
static_assert(sizeof(EpochLine) == 64, "epoch line");

struct HwccLayout {
  cxl::hwcc::layout L;
  uint64_t off_stamp, off_nodes, off_desc, off_heads, off_ext, off_epochs;
  uint64_t slot_ext_bytes;
  HwccLayout(const Params &p, const char *backend_tag) {
    L.add(("rocksdb " + p.describe() + backend_tag).c_str(), 0, 8);  // parameters go into the layout hash
    off_stamp = L.add("stamp", 8);                                    // every node (fetch_add per put)
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
    off_desc = L.add("desc", uint64_t(p.nr_nodes) * sizeof(Desc));
    off_heads = L.add("dir.heads", uint64_t(p.nr_nodes) * p.max_files * sizeof(FileHead));
    slot_ext_bytes = (uint64_t(p.max_ext) * 4 + 63) / 64 * 64;  // u32 extent indexes of one slot
    off_ext = L.add("dir.ext", uint64_t(p.nr_nodes) * p.max_files * slot_ext_bytes);
    off_epochs = L.add("epochs", uint64_t(p.nr_nodes) * p.epoch_slots * sizeof(EpochLine));
  }
};

struct Hwcc {
  uint64_t *stamp;
  NodeLine *nodes;
  Desc *desc;
  uint8_t *heads, *ext;
  EpochLine *epochs;
  uint32_t max_files, epoch_slots;
  uint64_t slot_ext_bytes;
  Hwcc(uint8_t *app, const HwccLayout &h, const Params &p)
      : stamp(reinterpret_cast<uint64_t *>(app + h.off_stamp)),
        nodes(reinterpret_cast<NodeLine *>(app + h.off_nodes)),
        desc(reinterpret_cast<Desc *>(app + h.off_desc)),
        heads(app + h.off_heads),
        ext(app + h.off_ext),
        epochs(reinterpret_cast<EpochLine *>(app + h.off_epochs)),
        max_files(p.max_files),
        epoch_slots(p.epoch_slots),
        slot_ext_bytes(h.slot_ext_bytes) {}
  FileHead *head(uint32_t node, uint32_t slot) const {
    return reinterpret_cast<FileHead *>(heads) + uint64_t(node) * max_files + slot;
  }
  uint32_t *exts(uint32_t node, uint32_t slot) const {
    return reinterpret_cast<uint32_t *>(ext + (uint64_t(node) * max_files + slot) * slot_ext_bytes);
  }
  EpochLine *epoch(uint32_t node, uint32_t slot) const { return epochs + uint64_t(node) * epoch_slots + slot; }
};

// SWcc share of node v: [arena blocks][file extents], each kUnit; addresses relative to the device mapping.
struct SwccPlan {
  uint64_t share = 0, base0 = 0, arena_blocks = 0, file_extents = 0;
  bool make(const cxl::region &r, const Params &p, std::string *err) {
    share = r.swcc.size / p.nr_nodes / kUnit * kUnit;
    base0 = cxl::detail::align_up(r.swcc.offset, kUnit);
    if (base0 + share * p.nr_nodes > r.swcc.offset + r.swcc.size) share -= kUnit;
    arena_blocks = p.arena_blocks;
    const uint64_t units = share / kUnit;
    if (units <= arena_blocks + 16) return *err = "SWcc share too small for the arena pool", false;
    file_extents = p.file_extents ? p.file_extents : units - arena_blocks;
    if (arena_blocks + file_extents > units) return *err = "arena_blocks + file_extents exceed the node's SWcc share", false;
    if (file_extents >= (1ull << 32)) return *err = "too many extents", false;
    return true;
  }
  uint64_t block_off(uint32_t node, uint64_t i) const { return base0 + node * share + i * kUnit; }
  uint64_t extent_off(uint32_t node, uint64_t j) const { return base0 + node * share + (arena_blocks + j) * kUnit; }
  std::string describe() const {
    return "share=" + std::to_string(share) + " arena_blocks=" + std::to_string(arena_blocks) +
           " file_extents=" + std::to_string(file_extents) + " unit=" + std::to_string(kUnit);
  }
};

}  // namespace rdbw

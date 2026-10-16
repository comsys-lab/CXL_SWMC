// lmdb shared layout (DESIGN.md §2, docs/hwcc-contract.md): LMDB's lock-file state in the HWcc app range.
// Same layout on every system; the backend tag only enters the hash (both nodes must run the same backend).
#pragma once

#include <cstdint>
#include <string>

#include "hwcc_app.h"
#include "lmdb_cxl.h"

namespace lmdbw {

struct Params {
  uint32_t nr_nodes = 2;
  uint32_t readers = 32;       // reader slots per node (get worker threads + tools); slot = node * readers + i
  uint64_t max_pages = 0;      // LMDB page number space (mapsize / 4096); required
  uint64_t records = 0;        // key space 0..records-1 (from the image; 0 = empty DB)
  std::string describe() const {
    return "nr_nodes=" + std::to_string(nr_nodes) + " readers=" + std::to_string(readers) +
           " max_pages=" + std::to_string(max_pages) + " records=" + std::to_string(records);
  }
};

struct alignas(64) NodeLine {  // written only by node v
  uint64_t loaded;             // run_id once the node is ready to serve
  uint64_t updates;            // diagnostics
  uint8_t pad[48];
};
static_assert(sizeof(NodeLine) == 64, "node line");

struct HwccLayout {
  cxl::hwcc::layout L;
  uint64_t off_wlock, off_committed, off_meta, off_readers, off_nodes;
  explicit HwccLayout(const Params &p, const char *backend_tag = "") {
    L.add(("lmdb " + p.describe() + backend_tag).c_str(), 0, 8);  // parameters go into the layout hash
    off_wlock = L.add("wlock", 2 * MDB_CXL_LINE);                 // [0] next ticket (RMW by all), [64] serving
    off_committed = L.add("committed", 8);                        // writer-lock holder
    off_meta = L.add("meta", 2 * sizeof(MDB_cxl_meta));            // writer-lock holder (seqlock)
    off_readers = L.add("readers", uint64_t(p.nr_nodes) * p.readers * MDB_CXL_LINE);  // slot owner
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
  }
};
static_assert(sizeof(MDB_cxl_meta) == 128, "meta slot is two lines");

struct Hwcc {
  MDB_cxl_conf conf{};  // the HWcc part of the LMDB conf (page access is the backend's)
  NodeLine *nodes;
  Hwcc(uint8_t *app, const HwccLayout &h, const Params &p) {
    conf.wlock = reinterpret_cast<uint64_t *>(app + h.off_wlock);
    conf.committed = reinterpret_cast<uint64_t *>(app + h.off_committed);
    conf.meta = reinterpret_cast<MDB_cxl_meta *>(app + h.off_meta);
    conf.readers = reinterpret_cast<uint64_t *>(app + h.off_readers);
    conf.nreaders = p.nr_nodes * p.readers;
    conf.max_pages = p.max_pages;
    nodes = reinterpret_cast<NodeLine *>(app + h.off_nodes);
  }
};

}  // namespace lmdbw

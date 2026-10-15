// recsys shared layout (DESIGN.md §2-§4, docs/hwcc-contract.md).
// SWcc: one open-addressing linear-probing hash table per sparse feature; a slot is one cache-line-aligned record
//   {key, embedding[dim], seq, csum} (576 B for dim 128). Tables are contiguous, table k after table k-1.
// HWcc (region.app): header, parameter tag, per-node lines, one 32-bit version word (seqlock) per `group` (64)
//   consecutive slots of a table. Identical in every system.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "../proto.h"
#include "hwcc_app.h"

namespace rsys {

// MLPerf DLRMv2 (torchrec_dlrm, mlcommons inference dlrm_v2): rows per table and multi-hot sizes (sum 214).
inline const std::vector<uint64_t> &mlperf_rows() {
  static const std::vector<uint64_t> v{40000000, 39060, 17295, 7424,     20265, 3,        7122,     1543,  63,
                                       40000000, 3067956, 405282, 10,     2209,  11938,    155,      4,     976,
                                       14,       40000000, 40000000, 40000000, 590152, 12973, 108, 36};
  return v;
}
inline const std::vector<uint32_t> &mlperf_multi_hot() {
  static const std::vector<uint32_t> v{3, 2, 1, 2, 6, 1, 1, 1, 1, 7, 3, 8, 1, 6, 9, 5, 1, 1, 1, 12, 100, 27, 10, 3, 1, 1};
  return v;
}

inline uint64_t mix64(uint64_t x) {  // splitmix64 finalizer
  x ^= x >> 30;
  x *= 0xbf58476d1ce4e5b9ull;
  x ^= x >> 27;
  x *= 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}

struct Params {
  uint32_t nr_nodes = 2;
  uint32_t dim = 128;
  uint64_t row_cap = 26000000;  // rows per table are min(MLPerf rows, row_cap) (MOT1 §4.2: 5 tables capped at 26M)
  uint64_t row_div = 1;         // test scaling: rows = max(1, min(MLPerf, cap) / row_div)
  double load_factor = 0.8;     // slots = ceil(rows / load_factor), rounded up to whole groups
  uint32_t group = 64;          // slots per version word
  uint64_t seed = 20261016;     // initial embeddings, multi-hot expansion, model weights
  uint32_t multi_hot_div = 1;   // test scaling of multi-hot sizes (>= 1 each)
  // derived
  std::vector<uint64_t> rows, slots, slot_base, group_base;  // per table; slot_base in slots, group_base in groups
  std::vector<uint32_t> hot;
  uint64_t total_rows = 0, total_slots = 0, total_groups = 0, slot_bytes = 0;
  uint32_t lookups_per_sample = 0;

  void derive() {
    const auto &R = mlperf_rows();
    const auto &H = mlperf_multi_hot();
    rows.clear(), slots.clear(), slot_base.clear(), group_base.clear(), hot.clear();
    total_rows = total_slots = total_groups = 0;
    lookups_per_sample = 0;
    for (uint32_t k = 0; k < kSparse; k++) {
      uint64_t r = std::max<uint64_t>(1, std::min(R[k], row_cap) / row_div);
      uint64_t s = uint64_t(double(r) / load_factor + 0.999999);
      if (s <= r) s = r + 1;  // at least one empty slot: a miss terminates
      s = (s + group - 1) / group * group;
      rows.push_back(r);
      slots.push_back(s);
      slot_base.push_back(total_slots);
      group_base.push_back(total_groups);
      total_rows += r;
      total_slots += s;
      total_groups += s / group;
      hot.push_back(std::max<uint32_t>(1, H[k] / multi_hot_div));
      lookups_per_sample += hot.back();
    }
    slot_bytes = (8 + uint64_t(dim) * 4 + 16 + 63) / 64 * 64;  // key + emb + seq + csum/pad, whole lines
  }
  uint64_t swcc_bytes() const { return total_slots * slot_bytes; }
  std::string describe() const {
    std::ostringstream o;
    o << "nr_nodes=" << nr_nodes << " dim=" << dim << " row_cap=" << row_cap << " row_div=" << row_div
      << " load_factor=" << load_factor << " group=" << group << " seed=" << seed << " multi_hot_div=" << multi_hot_div
      << " rows=" << total_rows << " slots=" << total_slots << " groups=" << total_groups << " slot_bytes=" << slot_bytes
      << " swcc_bytes=" << swcc_bytes() << " lookups_per_sample=" << lookups_per_sample;
    return o.str();
  }

  // ---- keys and hashing
  // key = table+1 in the top byte, row index below (never 0; 0 marks an empty slot)
  static uint64_t key(uint32_t k, uint64_t row) { return (uint64_t(k) + 1) << 56 | row; }
  static uint32_t key_table(uint64_t key) { return uint32_t(key >> 56) - 1; }
  uint64_t home(uint32_t k, uint64_t key) const { return mix64(key ^ seed) % slots[k]; }
  uint64_t group_of(uint32_t k, uint64_t s) const { return group_base[k] + s / group; }
  // MLPerf multi-hot expansion of one-hot raw id `raw` of table k: element 0 = the id itself (capped: raw mod
  // rows), elements j >= 1 uniform over the rows (MLPerf: a fixed random lookup table generated with numpy seed 0;
  // here a hash of (seed, k, id, j), same distribution, not the same values; DESIGN.md §9 deviation D2).
  uint64_t multi_hot(uint32_t k, uint32_t raw, uint32_t j) const {
    const uint64_t id = raw % rows[k];
    if (j == 0) return id;
    return mix64(seed * 0x9e3779b97f4a7c15ull ^ (uint64_t(k) << 48) ^ (id << 8) ^ j) % rows[k];
  }
};

// Slot record in SWcc (slot_bytes, whole lines): key | emb[dim] | seq | csum | pad
struct SlotView {
  uint64_t key_off = 0, emb_off = 8, seq_off, csum_off;
  explicit SlotView(const Params &p) : seq_off(8 + uint64_t(p.dim) * 4), csum_off(8 + uint64_t(p.dim) * 4 + 8) {}
};

// Row values (synthetic, DESIGN.md §5): emb[j] of row `key` written by update `seq` (seq 0 = initial load).
inline void row_values(uint64_t key, uint64_t seq, uint64_t seed, uint32_t dim, float *out) {
  uint64_t x = mix64(key * 0x2545f4914f6cdd1dull ^ seq * 0x9e3779b97f4a7c15ull ^ seed) | 1;
  for (uint32_t j = 0; j < dim; j++) {
    x ^= x << 13, x ^= x >> 7, x ^= x << 17;
    out[j] = (float(int32_t(x >> 40) - (1 << 23)) / float(1 << 23)) * 0.05f;  // [-0.05, 0.05)
  }
}
inline uint32_t row_csum(uint64_t key, uint64_t seq, const float *emb, uint32_t dim) {
  uint32_t h = 0x811c9dc5u ^ uint32_t(key) ^ uint32_t(key >> 32) ^ uint32_t(seq) * 0x9e3779b1u;
  for (uint32_t j = 0; j < dim; j++) {
    uint32_t w;
    std::memcpy(&w, emb + j, 4);
    h = (h ^ w) * 0x01000193u;
  }
  return h | 1;  // never 0 (0 = empty slot)
}
// Fill a whole slot image (slot_bytes) for (key, seq); key 0 = empty slot (all zero).
inline void make_slot(const Params &p, uint64_t key, uint64_t seq, uint8_t *dst) {
  std::memset(dst, 0, p.slot_bytes);
  if (!key) return;
  SlotView v(p);
  float *e = reinterpret_cast<float *>(dst + v.emb_off);
  row_values(key, seq, p.seed, p.dim, e);
  const uint32_t c = row_csum(key, seq, e, p.dim);
  std::memcpy(dst + v.key_off, &key, 8);
  std::memcpy(dst + v.seq_off, &seq, 8);
  std::memcpy(dst + v.csum_off, &c, 4);
}

struct alignas(64) NodeLine {  // written only by node v
  uint64_t loaded;         // run_id once the node is ready to serve
  uint64_t published_seq;  // updater: rows of samples <= this are written
  uint64_t rows_written;   // diagnostics
  uint64_t flushes;        // publication rounds (T > 0)
  uint8_t pad[32];
};
static_assert(sizeof(NodeLine) == 64, "node line");

struct HwccLayout {
  cxl::hwcc::layout L;
  uint64_t off_nodes, off_ver, off_load;
  explicit HwccLayout(const Params &p, const char *backend_tag = "") {
    L.add(("recsys " + p.describe() + backend_tag).c_str(), 0, 8);  // parameters go into the layout hash
    off_nodes = L.add("nodes", uint64_t(p.nr_nodes) * sizeof(NodeLine));
    off_load = L.add("load_done", 64);  // node 0: run_id once every slot is written (initial image)
    off_ver = L.add("versions", p.total_groups * 4);
  }
};

struct Hwcc {
  NodeLine *nodes;
  uint32_t *ver;
  uint64_t *load_done;
  Hwcc(uint8_t *app, const HwccLayout &h)
      : nodes(reinterpret_cast<NodeLine *>(app + h.off_nodes)),
        ver(reinterpret_cast<uint32_t *>(app + h.off_ver)),
        load_done(reinterpret_cast<uint64_t *>(app + h.off_load)) {}
};

}  // namespace rsys

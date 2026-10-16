// recsys shared layout (DESIGN.md §2-§4, docs/hwcc-contract.md).
// SWcc: one open-addressing linear-probing hash table per sparse feature; a slot is one cache-line-aligned record
//   {key, embedding[dim], seq, csum} (576 B for dim 128). Tables are contiguous, table k after table k-1.
// HWcc (region.app): header, parameter tag, per-node lines, a striped version table (MemC3 NSDI'13 §3.2.1): S = 2^16
//   u32 counters, row key -> counter hash(table, key) mod S (v6, user 2026-10-16; replaced one word per 64 slots).
//   Identical in every system.
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
  double load_factor = 0.8;     // slots = ceil(rows / load_factor), rounded up to a multiple of slot_round
  uint32_t slot_round = 64;     // slot count granularity (SWcc layout kept from v5: 167,731,776 slots at full size)
  uint32_t ver_stripes = 1u << 16;  // S: striped version counters (power of two; libcuckoo kMaxNumLocks)
  uint64_t seed = 20261016;     // initial embeddings, multi-hot expansion, model weights
  uint32_t multi_hot_div = 1;   // test scaling of multi-hot sizes (>= 1 each)
  // derived
  std::vector<uint64_t> rows, slots, slot_base;  // per table; slot_base in slots
  std::vector<uint32_t> hot, hot_off;           // ids used per sample per table; offset of table k in Sample::ids
  uint64_t total_rows = 0, total_slots = 0, slot_bytes = 0;
  uint32_t lookups_per_sample = 0;

  void derive() {
    const auto &R = mlperf_rows();
    const auto &H = mlperf_multi_hot();
    rows.clear(), slots.clear(), slot_base.clear(), hot.clear(), hot_off.clear();
    total_rows = total_slots = 0;
    lookups_per_sample = 0;
    uint32_t off = 0;
    for (uint32_t k = 0; k < kSparse; k++) {
      uint64_t r = std::max<uint64_t>(1, std::min(R[k], row_cap) / row_div);
      uint64_t s = uint64_t(double(r) / load_factor + 0.999999);
      if (s <= r) s = r + 1;  // at least one empty slot: a miss terminates
      s = (s + slot_round - 1) / slot_round * slot_round;
      rows.push_back(r);
      slots.push_back(s);
      slot_base.push_back(total_slots);
      total_rows += r;
      total_slots += s;
      hot.push_back(std::max<uint32_t>(1, H[k] / multi_hot_div));  // the first hot[k] ids of the sample's H[k]
      hot_off.push_back(off);
      off += H[k];
      lookups_per_sample += hot.back();
    }
    slot_bytes = (8 + uint64_t(dim) * 4 + 16 + 63) / 64 * 64;  // key + emb + seq + csum/pad, whole lines
  }
  uint64_t swcc_bytes() const { return total_slots * slot_bytes; }
  std::string describe() const {
    std::ostringstream o;
    o << "nr_nodes=" << nr_nodes << " dim=" << dim << " row_cap=" << row_cap << " row_div=" << row_div
      << " load_factor=" << load_factor << " slot_round=" << slot_round << " ver_stripes=" << ver_stripes
      << " seed=" << seed << " multi_hot_div=" << multi_hot_div
      << " rows=" << total_rows << " slots=" << total_slots << " slot_bytes=" << slot_bytes
      << " swcc_bytes=" << swcc_bytes() << " lookups_per_sample=" << lookups_per_sample;
    return o.str();
  }

  // ---- keys and hashing
  // key = table+1 in the top byte, row index below (never 0; 0 marks an empty slot)
  static uint64_t key(uint32_t k, uint64_t row) { return (uint64_t(k) + 1) << 56 | row; }
  static uint32_t key_table(uint64_t key) { return uint32_t(key >> 56) - 1; }
  uint64_t home(uint32_t k, uint64_t key) const { return mix64(key ^ seed) % slots[k]; }
  // Striped version counter of a row (MemC3): hash(table, key) mod S. The key carries the table; a second salt keeps
  // the stripe independent of the home slot.
  uint32_t stripe(uint64_t key) const { return uint32_t(mix64(key ^ seed ^ 0x5eed5a17c0ffee11ull) & (ver_stripes - 1)); }
  // Row of the j-th multi-hot id of table k in sample s (MLPerf ids as is; table cap / row_div: id mod rows, D1)
  uint64_t row_of(uint32_t k, const Sample &s, uint32_t j) const { return s.ids[hot_off[k] + j] % rows[k]; }
};

// Synthetic multi-hot expansion (tools/gen_samples.cc only; real data carries MLPerf's own ids): element 0 = the one-hot
// id, elements j >= 1 uniform over the uncapped MLPerf rows of table k by a hash of (seed, k, id, j) — the distribution
// of MLPerf's numpy-generated table (`uniform`), not its values (deviation D2, synthetic inputs only).
inline uint32_t synth_multi_hot(uint64_t seed, uint32_t k, uint32_t id, uint32_t j) {
  if (j == 0) return id;
  return uint32_t(mix64(seed * 0x9e3779b97f4a7c15ull ^ (uint64_t(k) << 48) ^ (uint64_t(id) << 8) ^ j) % mlperf_rows()[k]);
}

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
    off_ver = L.add("versions", uint64_t(p.ver_stripes) * 4);
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

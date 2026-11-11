// socialgraph image builder (used by tools/sg_image_gen.cc and tests/layout_test.cc).
// Input: undirected edge list (u, v) of node ids. Each edge -> two directed links (assoc type kAssocFriend) with the
// same synthetic time; per node the links are sorted newest first (time desc, then id2 desc) and written into the
// layout of server/layout.h. Everything is a pure function of (edge list, BuildParams): deterministic.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "../server/layout.h"
#include "linkbench_params.h"

namespace sg {
namespace linkbench = ::socialgraph::linkbench;

inline uint64_t splitmix64(uint64_t x) {
  x += 0x9e3779b97f4a7c15ull;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}
inline double u01(uint64_t h) { return double(h >> 11) * (1.0 / 9007199254740992.0); }  // [0, 1)

struct BuildParams {
  uint64_t seed = 20261111;
  uint64_t node_slack = 1u << 20;   // free node slots for addnode
  uint64_t ovf_pool = 1u << 17;     // free 4 KiB overflow blocks for addlink
  uint64_t base_ms = 1700000000000ull;  // newest possible link time; times in (base_ms - 2^31, base_ms] (LinkBench: ~50 days)
};
constexpr uint64_t kTimeSpan = 1ull << 31;

// Directed CSR, per node newest first. key = rel_time << 32 | id2, rel_time = time - (base_ms - kTimeSpan) in
// [1, kTimeSpan], so a descending sort of keys = time desc, id2 desc.
struct Graph {
  uint64_t id_base = 1, n = 0;
  std::vector<uint64_t> off;  // n + 1
  std::vector<uint64_t> key;  // off[n]
  uint64_t undirected = 0, self_loops = 0, duplicates = 0;  // input edges, dropped self loops, dropped duplicate links
  uint64_t deg(uint64_t i) const { return off[i + 1] - off[i]; }
  static uint32_t id2_of(uint64_t k) { return uint32_t(k); }
  static uint64_t time_of(uint64_t k, uint64_t base_ms) { return base_ms - kTimeSpan + (k >> 32); }
};

inline uint64_t edge_rel_time(uint64_t seed, uint32_t a, uint32_t b) {
  uint32_t lo = a < b ? a : b, hi = a < b ? b : a;  // same time for both directions
  return 1 + splitmix64(seed ^ splitmix64((uint64_t(lo) << 32) | hi)) % kTimeSpan;
}

// src/dst: undirected edges (ids >= id_base); n: nodes (ids id_base .. id_base + n - 1). Consumes src/dst.
inline Graph build_csr(std::vector<uint32_t> &src, std::vector<uint32_t> &dst, uint64_t id_base, uint64_t n,
                       const BuildParams &p) {
  Graph g;
  g.id_base = id_base;
  g.n = n;
  g.undirected = src.size();
  std::vector<uint64_t> cnt(n + 1, 0);
  for (size_t e = 0; e < src.size(); e++) {
    if (src[e] < id_base || dst[e] < id_base || src[e] - id_base >= n || dst[e] - id_base >= n)
      throw std::runtime_error("edge id out of range");
    if (src[e] == dst[e]) { g.self_loops++; continue; }
    cnt[src[e] - id_base]++;
    cnt[dst[e] - id_base]++;
  }
  g.off.assign(n + 1, 0);
  for (uint64_t i = 0; i < n; i++) g.off[i + 1] = g.off[i] + cnt[i];
  g.key.assign(g.off[n], 0);
  std::vector<uint64_t> pos(g.off.begin(), g.off.end() - 1);
  for (size_t e = 0; e < src.size(); e++) {
    uint32_t a = src[e], b = dst[e];
    if (a == b) continue;
    uint64_t t = edge_rel_time(p.seed, a, b);
    g.key[pos[a - id_base]++] = (t << 32) | b;
    g.key[pos[b - id_base]++] = (t << 32) | a;
  }
  std::vector<uint32_t>().swap(src);
  std::vector<uint32_t>().swap(dst);
  std::vector<uint64_t>().swap(pos);
  // sort newest first; drop duplicate (same id2) links, keeping the first (newest)
  uint64_t w = 0;
  std::vector<uint32_t> seen;
  for (uint64_t i = 0; i < n; i++) {
    uint64_t b = g.off[i], e = g.off[i + 1];
    std::sort(g.key.begin() + b, g.key.begin() + e, [](uint64_t x, uint64_t y) { return x > y; });
    seen.clear();
    for (uint64_t j = b; j < e; j++) seen.push_back(uint32_t(g.key[j]));
    std::sort(seen.begin(), seen.end());
    bool dup = std::adjacent_find(seen.begin(), seen.end()) != seen.end();
    g.off[i] = w;
    if (!dup) {
      for (uint64_t j = b; j < e; j++) g.key[w++] = g.key[j];
    } else {
      std::vector<uint32_t> kept;
      for (uint64_t j = b; j < e; j++) {
        uint32_t id2 = uint32_t(g.key[j]);
        if (std::find(kept.begin(), kept.end(), id2) != kept.end()) { g.duplicates++; continue; }
        kept.push_back(id2);
        g.key[w++] = g.key[j];
      }
    }
  }
  g.off[n] = w;
  g.key.resize(w);
  g.key.shrink_to_fit();
  return g;
}

// LinkBench LogNormal payload size (linkbench_params.h kLinkDataSize / kNodeDataSize), deterministic in h.
inline uint64_t lognormal_size(const linkbench::LogNormalSpec &s, uint64_t h) {
  double u1 = u01(splitmix64(h ^ 0x1111)), u2 = u01(splitmix64(h ^ 0x2222));
  if (u1 <= 0) u1 = 1e-300;
  double z = std::sqrt(-2.0 * std::log(u1)) * std::cos(2.0 * M_PI * u2);
  double v = std::round(std::exp(s.sigma * z + std::log(s.median)));
  if (v < double(s.min)) v = double(s.min);
  if (v > double(s.max_excl - 1)) v = double(s.max_excl - 1);
  return uint64_t(v);
}
inline void fill_bytes(uint8_t *d, uint64_t len, uint64_t h, int lo, int hi_excl) {
  for (uint64_t i = 0; i < len; i++) d[i] = uint8_t(lo + splitmix64(h + i) % uint64_t(hi_excl - lo));
}
inline uint64_t node_hash(uint64_t seed, uint64_t id) { return splitmix64(seed ^ 0x6e6f6465ull ^ splitmix64(id)); }
inline uint64_t link_hash(uint64_t seed, uint64_t id1, uint32_t id2) {
  return splitmix64(seed ^ 0x6c696e6bull ^ splitmix64((id1 << 32) ^ id2));
}

struct BuildStats {
  uint64_t node_payload_capped = 0, link_payload_capped = 0, node_payload_bytes = 0, link_payload_bytes = 0;
  uint64_t primary_straddle = 0;  // primary blocks crossing a 4 KiB page boundary (image offsets)
};

// Write the image to f (sequential). Returns the header.
inline ImageHeader write_image(FILE *f, const Graph &g, const BuildParams &p, BuildStats &st) {
  ImageHeader h{};
  h.id_base = g.id_base;
  h.n_orig = g.n;
  h.node_slack = p.node_slack;
  h.n_links = g.off[g.n];
  h.seed = p.seed;
  uint64_t adj = 0, ovf = 0;
  std::vector<uint64_t> idx(g.n + p.node_slack, kNoAdj);
  for (uint64_t i = 0; i < g.n; i++) {
    idx[i] = adj;
    adj += primary_bytes(g.deg(i));
    ovf += ovf_blocks_for(g.deg(i));
  }
  h.adj_bytes = adj;
  h.ovf_built = ovf;
  h.ovf_pool = p.ovf_pool;
  finish_header(h);
  if (ovf + p.ovf_pool >= kSegInline) throw std::runtime_error("too many ovf blocks");
  if (g.id_base + g.n + p.node_slack > 0xffffffffull) throw std::runtime_error("node ids exceed 32 bits");

  uint64_t at = 0;
  auto put = [&](const void *b, uint64_t len) {
    if (len && fwrite(b, 1, len, f) != len) throw std::runtime_error("write failed");
    at += len;
  };
  auto pad_to = [&](uint64_t off) {
    static const uint8_t z[kPage] = {};
    if (off < at) throw std::runtime_error("layout overlap");
    while (at < off) put(z, std::min<uint64_t>(kPage, off - at));
  };
  put(&h, sizeof h);
  pad_to(h.adj_index_off);
  put(idx.data(), idx.size() * sizeof(uint64_t));
  pad_to(h.nodes_off);
  const uint32_t time_s = uint32_t(p.base_ms / 1000);
  for (uint64_t i = 0; i < g.n + p.node_slack; i++) {
    NodeSlot s{};
    s.id = g.id_base + i;
    if (i < g.n) {
      s.version = 1;
      s.type = uint32_t(linkbench::kDefaultNodeType);
      s.time_s = time_s;
      s.flags = kNodeLive;
      uint64_t hh = node_hash(p.seed, s.id);
      uint64_t len = lognormal_size(linkbench::kNodeDataSize, hh);
      if (len > kNodeDataCap) { len = kNodeDataCap; st.node_payload_capped++; }
      s.data_len = uint16_t(len);
      fill_bytes(s.data, len, hh, linkbench::kNodeDatagenStartByte, linkbench::kNodeDatagenEndByte);
      st.node_payload_bytes += len;
    }
    put(&s, sizeof s);
  }
  pad_to(h.adj_off);
  std::vector<uint8_t> blk;
  uint64_t next_ovf = 0;
  auto fill_edge = [&](EdgeSlot &e, uint64_t id1, uint64_t k) {
    e.id2 = Graph::id2_of(k);
    e.assoc_type = kAssocFriend;
    e.flags = kEdgeLive;
    e.time = Graph::time_of(k, p.base_ms);
    e.version = 0;
    uint64_t hh = link_hash(p.seed, id1, e.id2);
    uint64_t len = lognormal_size(linkbench::kLinkDataSize, hh);
    if (len > kEdgeDataCap) { len = kEdgeDataCap; st.link_payload_capped++; }
    e.data_len = uint8_t(len);
    fill_bytes(e.data, len, hh, linkbench::kLinkDatagenStartByte, linkbench::kLinkDatagenEndByte);
    st.link_payload_bytes += len;
  };
  for (uint64_t i = 0; i < g.n; i++) {
    uint64_t d = g.deg(i), id1 = g.id_base + i;
    uint64_t bytes = primary_bytes(d);
    uint64_t off = h.adj_off + idx[i];
    if (off / kPage != (off + bytes - 1) / kPage) st.primary_straddle++;
    blk.assign(bytes, 0);
    AdjHeader *a = reinterpret_cast<AdjHeader *>(blk.data());
    uint32_t ne = inline_edges(d), nb = uint32_t(ovf_blocks_for(d));
    a->id1 = id1;
    a->count = a->used = uint32_t(d);
    a->head = kSegInline;
    a->cap = uint16_t(inline_cap(d));
    a->start = uint16_t(a->cap - ne);
    a->next = nb ? uint32_t(next_ovf) : kSegNone;
    a->n_ovf = nb;
    next_ovf += nb;
    for (uint32_t j = 0; j < ne; j++) fill_edge(a->inline_slots()[a->start + j], id1, g.key[g.off[i] + j]);
    put(blk.data(), bytes);
  }
  pad_to(h.ovf_off);
  next_ovf = 0;
  OvfBlock *o = new OvfBlock;
  for (uint64_t i = 0; i < g.n; i++) {
    uint64_t d = g.deg(i), nb = ovf_blocks_for(d);
    for (uint64_t b = 0; b < nb; b++, next_ovf++) {
      std::memset(o, 0, sizeof *o);
      uint64_t first = kInlineMaxEdges + b * kOvfSlots, k = std::min<uint64_t>(kOvfSlots, d - first);
      o->h.id1 = g.id_base + i;
      o->h.next = b + 1 < nb ? uint32_t(next_ovf + 1) : kSegNone;
      o->h.cap = uint16_t(kOvfSlots);
      o->h.start = uint16_t(kOvfSlots - k);
      for (uint64_t j = 0; j < k; j++) fill_edge(o->slot[o->h.start + j], o->h.id1, g.key[g.off[i] + first + j]);
      put(o, sizeof *o);
    }
  }
  std::memset(o, 0, sizeof *o);
  o->h.next = kSegNone;
  o->h.cap = o->h.start = uint16_t(kOvfSlots);
  for (uint64_t b = 0; b < p.ovf_pool; b++) put(o, sizeof *o);
  delete o;
  if (at != h.total_bytes) throw std::runtime_error("image size mismatch");
  return h;
}

}  // namespace sg

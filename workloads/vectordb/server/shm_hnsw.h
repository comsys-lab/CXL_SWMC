// One HNSW graph (= one segment) in CXL shared memory. Port of hnswlib (Knowhere
// thirdparty/hnswlib/hnswlib/hnswalg.h): getRandomLevel, searchBaseLayer, getNeighborsByHeuristic2,
// mutuallyConnectNewElement, addPoint, searchKnn/searchBaseLayerST; same algorithm and parameters.
// Concurrency follows Qdrant (user decision 2026-10-15): every node may write every segment, and the segment's
// HWcc reader-writer lock serialises it — insert() runs under the write lock, search() under the read lock — so
// hnswlib's per-element mutexes are not needed and readers never see a list being rewritten.
// Changes for sharing: level-0 slots and upper-level link blocks live in SWcc and are addressed by offsets; the
// graph meta (entry point, max level, element count, upper-arena cursor) lives in HWcc (docs/hwcc-contract.md);
// deletions are not marked in the graph (queries filter results with a visibility predicate, E1 snapshot);
// inner product distance = -dot (hnswlib InnerProductSpace uses 1 - dot; same order).
#pragma once

#include <immintrin.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <queue>
#include <random>
#include <stdexcept>
#include <vector>

#include "hwcc_app.h"

namespace vdb {

struct alignas(64) GraphMeta {  // HWcc, one line; written under the segment write lock
  uint64_t ep_level;   // entry point (low 32) | max level (high 32); kNoEntry = empty graph
  uint64_t count;      // elements [0, count) are complete
  uint64_t upper_cur;  // bytes used in the segment's upper-level link arena
  uint8_t pad[40];
};
static_assert(sizeof(GraphMeta) == 64, "graph meta is one line");
constexpr uint64_t kNoEntry = ~0ull;

struct alignas(64) ElemHeader {  // first line of a level-0 slot
  uint64_t ext_id;     // record id
  uint32_t ins_seq;    // w_seq of the insert (0 = initial record)
  uint32_t level;
  uint64_t upper_off;  // offset of the element's upper-level link blocks in the segment's upper arena
  uint32_t check;      // canary: ext_id ^ ins_seq ^ level ^ magic
  uint8_t pad[36];
};
static_assert(sizeof(ElemHeader) == 64, "element header is one line");
constexpr uint32_t kElemMagic = 0x484e5357u;

struct GraphParams {
  uint32_t dim = 768, M = 16, ef_construction = 128;
  uint64_t capacity = 62500;  // elements per segment
  uint32_t M0() const { return 2 * M; }
  uint64_t links0_bytes() const { return (4ull * (1 + M0()) + 63) / 64 * 64; }
  uint64_t links_bytes() const { return (4ull * (1 + M) + 63) / 64 * 64; }  // per upper level
  uint64_t slot_bytes() const { return sizeof(ElemHeader) + links0_bytes() + uint64_t(dim) * 4; }
  uint64_t upper_arena_bytes() const {  // expected upper levels per element 1/(M-1); 4x margin
    return (capacity * 4 / (M - 1) + 1024) * links_bytes();
  }
};

class ShmHnsw {
 public:
  using Dist = float;
  struct Mem {
    GraphMeta *meta;  // HWcc
    uint8_t *level0;  // SWcc: capacity * slot_bytes
    uint8_t *upper;   // SWcc: upper_arena_bytes
  };

  ShmHnsw(const GraphParams &p, Mem m) : p_(p), m_(m), mult_(1 / std::log(double(p.M))) {
    if (p.M < 2 || p.M0() > 63) throw std::invalid_argument("HNSW M must be in [2, 31]");
    slot_ = p.slot_bytes();
    links0_off_ = sizeof(ElemHeader);
    vec_off_ = sizeof(ElemHeader) + p.links0_bytes();
  }

  static void init_empty(GraphMeta *meta) {
    meta->count = 0;
    meta->upper_cur = 0;
    cxl::hwcc::store_release(&meta->ep_level, kNoEntry);
  }

  uint64_t count() const { return cxl::hwcc::load_acquire(&m_.meta->count); }
  const ElemHeader &header(uint32_t i) const { return *reinterpret_cast<const ElemHeader *>(slot(i)); }
  const float *vec(uint32_t i) const { return reinterpret_cast<const float *>(slot(i) + vec_off_); }
  const GraphParams &params() const { return p_; }

  // ---------------------------------------------------------------- insert (hnswlib addPoint); write lock held
  uint32_t insert(uint64_t ext_id, uint32_t ins_seq, const float *v, std::mt19937_64 &rng) {
    const uint64_t n = m_.meta->count;
    if (n >= p_.capacity) throw std::runtime_error("segment full (capacity)");
    const uint32_t cur = uint32_t(n);
    const int curlevel = random_level(rng);
    uint8_t *s = slot(cur);
    ElemHeader h{};
    h.ext_id = ext_id;
    h.ins_seq = ins_seq;
    h.level = uint32_t(curlevel);
    if (curlevel > 0) {
      h.upper_off = m_.meta->upper_cur;
      if (h.upper_off + uint64_t(curlevel) * p_.links_bytes() > p_.upper_arena_bytes())
        throw std::runtime_error("upper-level arena full");
      m_.meta->upper_cur = h.upper_off + uint64_t(curlevel) * p_.links_bytes();
      std::memset(m_.upper + h.upper_off, 0, uint64_t(curlevel) * p_.links_bytes());
    }
    h.check = uint32_t(ext_id) ^ uint32_t(ext_id >> 32) ^ ins_seq ^ uint32_t(curlevel) ^ kElemMagic;
    std::memcpy(s, &h, sizeof(h));
    std::memset(s + links0_off_, 0, p_.links0_bytes());
    std::memcpy(s + vec_off_, v, size_t(p_.dim) * 4);

    const uint64_t epl = m_.meta->ep_level;
    if (epl == kNoEntry) {
      m_.meta->ep_level = (uint64_t(curlevel) << 32) | cur;
      cxl::hwcc::store_release(&m_.meta->count, n + 1);
      return cur;
    }
    const int maxlevel = int(epl >> 32);
    uint32_t curr = uint32_t(epl);
    if (curlevel < maxlevel) {  // greedy descent through the levels above curlevel
      Dist curdist = dist(v, curr);
      for (int level = maxlevel; level > curlevel; level--)
        for (bool changed = true; changed;) {
          changed = false;
          const uint32_t *ll = links(curr, level);
          for (uint32_t j = 0; j < ll[0]; j++) {
            Dist d = dist(v, ll[1 + j]);
            if (d < curdist) curdist = d, curr = ll[1 + j], changed = true;
          }
        }
    }
    for (int level = std::min(curlevel, maxlevel); level >= 0; level--) {
      MaxHeap top = search_layer_build(curr, v, level, cur);
      curr = connect(cur, top, level);
    }
    if (curlevel > maxlevel) m_.meta->ep_level = (uint64_t(curlevel) << 32) | cur;
    cxl::hwcc::store_release(&m_.meta->count, n + 1);
    return cur;
  }

  // ---------------------------------------------------------------- query (hnswlib searchKnn); read lock held
  // allowed(internal id) -> bool filters results (E1 visibility); traversal goes through every element, as
  // hnswlib searchBaseLayerST with deletions. visited/tag: the calling thread's own tag array (>= capacity).
  template <class Allowed>
  void search(const float *q, uint32_t k, uint32_t ef, Allowed allowed, std::vector<std::pair<Dist, uint32_t>> *out,
              std::vector<uint16_t> &visited, uint16_t &tag, uint64_t *dists = nullptr) const {
    out->clear();
    const uint64_t epl = m_.meta->ep_level;
    if (epl == kNoEntry) return;
    uint64_t nd = 0;
    uint32_t curr = uint32_t(epl);
    Dist curdist = dist(q, curr);
    nd++;
    for (int level = int(epl >> 32); level > 0; level--)
      for (bool changed = true; changed;) {
        changed = false;
        const uint32_t *ll = links(curr, level);
        for (uint32_t j = 0; j < ll[0]; j++) {
          Dist d = dist(q, ll[1 + j]);
          nd++;
          if (d < curdist) curdist = d, curr = ll[1 + j], changed = true;
        }
      }
    if (++tag == 0) {
      std::fill(visited.begin(), visited.end(), 0);
      tag = 1;
    }
    ef = std::max(ef, k);
    using P = std::pair<Dist, uint32_t>;
    std::priority_queue<P> top;                                   // worst kept result on top
    std::priority_queue<P, std::vector<P>, std::greater<P>> cand;  // closest candidate first
    Dist lower = std::numeric_limits<Dist>::max();
    if (allowed(curr)) top.emplace(curdist, curr), lower = curdist;
    cand.emplace(curdist, curr);
    visited[curr] = tag;
    while (!cand.empty()) {
      P c = cand.top();
      if (c.first > lower && top.size() == ef) break;
      cand.pop();
      const uint32_t *ll = links(c.second, 0);
      const uint32_t sz = ll[0];
      for (uint32_t j = 0; j < sz; j++) _mm_prefetch(reinterpret_cast<const char *>(vec(ll[1 + j])), _MM_HINT_T0);
      for (uint32_t j = 0; j < sz; j++) {
        const uint32_t id = ll[1 + j];
        if (visited[id] == tag) continue;
        visited[id] = tag;
        Dist d = dist(q, id);
        nd++;
        if (top.size() < ef || lower > d) {
          cand.emplace(d, id);
          if (allowed(id)) {
            top.emplace(d, id);
            if (top.size() > ef) top.pop();
          }
          if (!top.empty()) lower = top.top().first;
        }
      }
    }
    while (top.size() > k) top.pop();
    out->resize(top.size());
    for (size_t i = top.size(); i-- > 0;) (*out)[i] = top.top(), top.pop();
    if (dists) *dists += nd;
  }

  Dist dist(const float *a, uint32_t id) const { return -dot(a, vec(id)); }

 private:
  using MaxHeap = std::priority_queue<std::pair<Dist, uint32_t>>;  // hnswlib CompareByFirst: largest on top

  uint8_t *slot(uint32_t i) const { return m_.level0 + uint64_t(i) * slot_; }
  uint32_t *links(uint32_t i, int level) const {
    if (level == 0) return reinterpret_cast<uint32_t *>(slot(i) + links0_off_);
    return reinterpret_cast<uint32_t *>(m_.upper + header(i).upper_off + uint64_t(level - 1) * p_.links_bytes());
  }
  float dot(const float *a, const float *b) const {
    float s = 0;
#pragma omp simd reduction(+ : s)
    for (uint32_t i = 0; i < p_.dim; i++) s += a[i] * b[i];
    return s;
  }
  Dist dist_ids(uint32_t a, uint32_t b) const { return -dot(vec(a), vec(b)); }
  int random_level(std::mt19937_64 &rng) const {
    std::uniform_real_distribution<double> u(0.0, 1.0);
    return int(-std::log(u(rng)) * mult_);
  }

  // hnswlib searchBaseLayer (construction search at one level)
  MaxHeap search_layer_build(uint32_t ep, const float *v, int level, uint32_t cur) {
    if (marks_.size() < p_.capacity) marks_.assign(p_.capacity, 0);
    std::vector<uint32_t> seen;
    MaxHeap top;
    std::priority_queue<std::pair<Dist, uint32_t>> cand;  // -dist (hnswlib candidateSet)
    Dist d0 = dist(v, ep);
    top.emplace(d0, ep);
    cand.emplace(-d0, ep);
    Dist lower = d0;
    marks_[ep] = 1, seen.push_back(ep);
    marks_[cur] = 1, seen.push_back(cur);
    while (!cand.empty()) {
      auto c = cand.top();
      if (-c.first > lower && top.size() == p_.ef_construction) break;
      cand.pop();
      const uint32_t *ll = links(c.second, level);
      for (uint32_t j = 0; j < ll[0]; j++) {
        const uint32_t id = ll[1 + j];
        if (marks_[id]) continue;
        marks_[id] = 1, seen.push_back(id);
        Dist d = dist(v, id);
        if (top.size() < p_.ef_construction || lower > d) {
          cand.emplace(-d, id);
          top.emplace(d, id);
          if (top.size() > p_.ef_construction) top.pop();
          if (!top.empty()) lower = top.top().first;
        }
      }
    }
    for (uint32_t id : seen) marks_[id] = 0;
    return top;
  }

  // hnswlib getNeighborsByHeuristic2
  std::vector<uint32_t> heuristic(MaxHeap &top, size_t M) const {
    std::vector<uint32_t> ret;
    if (top.size() < M) {
      ret.resize(top.size());
      for (int i = int(top.size()) - 1; i >= 0; i--) ret[size_t(i)] = top.top().second, top.pop();
      return ret;
    }
    std::vector<std::pair<Dist, uint32_t>> closest(top.size());
    for (int i = int(top.size()) - 1; i >= 0; i--) closest[size_t(i)] = top.top(), top.pop();
    ret.reserve(M);
    for (auto &cp : closest) {
      bool good = true;
      for (uint32_t id : ret)
        if (dist_ids(id, cp.second) < cp.first) { good = false; break; }
      if (good) {
        ret.push_back(cp.second);
        if (ret.size() >= M) break;
      }
    }
    return ret;
  }

  // hnswlib mutuallyConnectNewElement
  uint32_t connect(uint32_t cur, MaxHeap &top, int level) {
    const uint32_t Mmax = level ? p_.M : p_.M0();
    std::vector<uint32_t> sel = heuristic(top, p_.M);
    if (sel.empty()) throw std::runtime_error("no neighbours selected");
    uint32_t *own = links(cur, level);
    for (size_t i = 0; i < sel.size(); i++) own[1 + i] = sel[i];
    own[0] = uint32_t(sel.size());
    for (uint32_t nb : sel) {
      uint32_t *ll = links(nb, level);
      const uint32_t sz = ll[0];
      if (sz < Mmax) {
        ll[1 + sz] = cur;
        ll[0] = sz + 1;
      } else {  // replace via the heuristic over the existing links plus cur
        MaxHeap c;
        c.emplace(dist_ids(cur, nb), cur);
        for (uint32_t j = 0; j < sz; j++) c.emplace(dist_ids(ll[1 + j], nb), ll[1 + j]);
        std::vector<uint32_t> s2 = heuristic(c, Mmax);
        for (size_t i = 0; i < s2.size(); i++) ll[1 + i] = s2[i];
        ll[0] = uint32_t(s2.size());
      }
    }
    return sel.front();
  }

  GraphParams p_;
  Mem m_;
  double mult_;
  uint64_t slot_, links0_off_, vec_off_;
  std::vector<uint8_t> marks_;  // construction visited marks (writer side; one ShmHnsw per writer thread)
};

}  // namespace vdb

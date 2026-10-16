// One HNSW graph (= one segment) in CXL shared memory. Port of hnswlib (Knowhere
// thirdparty/hnswlib/hnswlib/hnswalg.h): getRandomLevel, searchBaseLayer, getNeighborsByHeuristic2,
// mutuallyConnectNewElement, addPoint, searchKnn/searchBaseLayerST; same algorithm and parameters.
// Concurrency follows Qdrant (user decision 2026-10-15): every node may write every segment, and the segment's
// HWcc reader-writer lock serialises it — insert() runs under the write lock, search() under the read lock — so
// hnswlib's per-element mutexes are not needed and readers never see a list being rewritten.
// Storage is chunked (user decision 2026-10-15; data points grouped in contiguous chunks, the chunk located through a
// small table, the point by offset inside it): element i belongs to group g = i / N. Group g has a vector chunk
// (N x {header line, vector}; immutable once written; ~32 MiB) and a link chunk (N x level-0 link block, then the
// group's upper-level link arena; rewritten by inserts). hnswlib keeps links and vector together in one
// data_level0_memory_ slot; here vectors and links are separate chunks. The graph meta (entry point, max level,
// element count, upper-arena cursor of the current group) lives in HWcc (docs/hwcc-contract.md);
// deletions are not marked in the graph (queries filter results with a visibility predicate, E1 snapshot);
// inner product distance = -dot (hnswlib InnerProductSpace uses 1 - dot; same order).
// Memory access goes through an accessor policy (HnswT<Acc>): PlainAcc (all-HWcc, Popcorn) hands out direct pointers
// into the chunks, exactly as before; MegalonAcc (megalon_backend.h) wraps every chunk access in one Megalon object
// read or write section (DESIGN.md §12). Accessor interface:
//   float dot(q, i)                        q . vector(i)
//   const ElemHeader &header(i, tmp)       header of element i (plain: in place; megalon: copy in tmp)
//   const float *vec(i, tmp)               vector of element i (plain: in place; megalon: copy in tmp[dim])
//   const uint32_t *links(i, lv, uo, tmp)  link block of i at level lv (uo = header.upper_off, used if lv > 0)
//   uint32_t *links_mut(i, lv, uo, tmp)    the same block for an update; commit_links writes it back (whole block)
//   void commit_links(i, lv, uo, p)
//   void write_elem(i, h, v, uo_bytes)     header + vector, zeroed level-0 block and upper blocks [uo, uo + uo_bytes)
//   void prefetch(i)
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

// Bytes of the whole lines the application stores in SWcc data, by the calling thread (MOT1 v6 Fig 3b "modified
// bytes"; read around an update by server/opcoh.h): vector record + zeroed link blocks (write_elem), each committed
// link block (commit_links), each delete-log entry (backend dlog_write). The initial image copy is not counted.
inline thread_local uint64_t t_mod_bytes = 0;

struct alignas(64) GraphMeta {  // HWcc, one line; written under the segment write lock
  uint64_t ep_level;   // entry point (low 32) | max level (high 32); kNoEntry = empty graph
  uint64_t count;      // elements [0, count) are complete
  uint64_t upper_cur;  // bytes used in the current (last) group's upper-level link arena
  uint8_t pad[40];
};
static_assert(sizeof(GraphMeta) == 64, "graph meta is one line");
constexpr uint64_t kNoEntry = ~0ull;

struct alignas(64) ElemHeader {  // first line of a vector record (vector chunk)
  uint64_t ext_id;     // record id
  uint32_t ins_seq;    // w_seq of the insert (0 = initial record)
  uint32_t level;
  uint64_t upper_off;  // offset of the element's upper-level link blocks in its group's upper arena
  uint32_t check;      // canary: ext_id ^ ins_seq ^ level ^ magic
  uint8_t pad[36];
};
static_assert(sizeof(ElemHeader) == 64, "element header is one line");
constexpr uint32_t kElemMagic = 0x484e5357u;

struct GraphParams {
  uint32_t dim = 768, M = 16, ef_construction = 128;
  uint64_t capacity = 62500;          // elements per segment
  uint64_t chunk_bytes = 32ull << 20; // target vector chunk size (user: 32 MiB)
  uint32_t M0() const { return 2 * M; }
  uint64_t links0_bytes() const { return (4ull * (1 + M0()) + 63) / 64 * 64; }
  uint64_t links_bytes() const { return (4ull * (1 + M) + 63) / 64 * 64; }  // per upper level
  uint64_t vrec_bytes() const { return sizeof(ElemHeader) + uint64_t(dim) * 4; }
  uint64_t per_chunk() const { return chunk_bytes / vrec_bytes(); }  // N elements per group
  uint64_t groups() const { return (capacity + per_chunk() - 1) / per_chunk(); }
  uint64_t vchunk_bytes() const { return per_chunk() * vrec_bytes(); }
  uint64_t upper_group_bytes() const {  // expected upper levels per element 1/(M-1); 4x margin
    return (per_chunk() * 4 / (M - 1) + 64) * links_bytes();
  }
  uint64_t lchunk_bytes() const { return per_chunk() * links0_bytes() + upper_group_bytes(); }
};

inline float dot(const float *a, const float *b, uint32_t dim) {
  float s = 0;
#pragma omp simd reduction(+ : s)
  for (uint32_t i = 0; i < dim; i++) s += a[i] * b[i];
  return s;
}

constexpr uint32_t kMaxLinkWords = 64;  // link block scratch (M0 <= 63: 4 * (1 + 63) bytes)

// Direct access (all-HWcc, Popcorn): chunk pointer tables, no coherence actions.
class PlainAcc {
 public:
  struct Mem {
    GraphMeta *meta;              // HWcc
    std::vector<uint8_t *> vec;   // SWcc vector chunk g (vchunk_bytes), g < groups()
    std::vector<uint8_t *> link;  // SWcc link chunk g (lchunk_bytes)
  };
  PlainAcc(const GraphParams &p, Mem m) : p_(p), m_(std::move(m)) {
    if (m_.vec.size() != p.groups() || m_.link.size() != p.groups()) throw std::invalid_argument("chunk table size");
    N_ = p.per_chunk();
    vrec_ = p.vrec_bytes();
    l0_ = p.links0_bytes();
    upper_base_ = N_ * l0_;
  }
  GraphMeta *meta() const { return m_.meta; }
  float dot(const float *q, uint32_t i) const { return vdb::dot(q, vecp(i), p_.dim); }
  const ElemHeader &header(uint32_t i, ElemHeader &) const { return *reinterpret_cast<const ElemHeader *>(vrec(i)); }
  const float *vec(uint32_t i, float *) const { return vecp(i); }
  const uint32_t *links(uint32_t i, int level, uint64_t uo, uint32_t *) const { return linkp(i, level, uo); }
  uint32_t *links_mut(uint32_t i, int level, uint64_t uo, uint32_t *) const { return linkp(i, level, uo); }
  void commit_links(uint32_t, int level, uint64_t, const uint32_t *) const {
    t_mod_bytes += level ? p_.links_bytes() : l0_;  // in place already; the block is what an update stores
  }
  void write_elem(uint32_t i, const ElemHeader &h, const float *v, uint64_t upper_bytes) const {
    t_mod_bytes += vrec_ + l0_ + upper_bytes;
    uint8_t *lc = m_.link[i / N_];
    if (upper_bytes) std::memset(lc + upper_base_ + h.upper_off, 0, upper_bytes);
    uint8_t *vr = vrec(i);  // vector chunk: header + vector, whole lines, written once
    std::memcpy(vr, &h, sizeof(h));
    std::memcpy(vr + sizeof(ElemHeader), v, size_t(p_.dim) * 4);
    std::memset(lc + (i % N_) * l0_, 0, l0_);
  }
  void prefetch(uint32_t i) const { _mm_prefetch(reinterpret_cast<const char *>(vecp(i)), _MM_HINT_T0); }

 private:
  uint8_t *vrec(uint32_t i) const { return m_.vec[i / N_] + (i % N_) * vrec_; }
  const float *vecp(uint32_t i) const { return reinterpret_cast<const float *>(vrec(i) + sizeof(ElemHeader)); }
  uint32_t *linkp(uint32_t i, int level, uint64_t uo) const {
    uint8_t *lc = m_.link[i / N_];
    if (level == 0) return reinterpret_cast<uint32_t *>(lc + (i % N_) * l0_);
    return reinterpret_cast<uint32_t *>(lc + upper_base_ + uo + uint64_t(level - 1) * p_.links_bytes());
  }
  GraphParams p_;
  Mem m_;
  uint64_t N_, vrec_, l0_, upper_base_;
};

template <class Acc>
class HnswT {
 public:
  using Dist = float;
  using Mem = typename Acc::Mem;

  HnswT(const GraphParams &p, Mem m) : p_(p), a_(p, std::move(m)), mult_(1 / std::log(double(p.M))) {
    if (p.M < 2 || p.M0() > 63) throw std::invalid_argument("HNSW M must be in [2, 31]");
    N_ = p.per_chunk();
    meta_ = a_.meta();
    vtmp_.resize(p.dim);
  }

  static void init_empty(GraphMeta *meta) {
    meta->count = 0;
    meta->upper_cur = 0;
    cxl::hwcc::store_release(&meta->ep_level, kNoEntry);
  }

  uint64_t count() const { return cxl::hwcc::load_acquire(&meta_->count); }
  // header of element i: plain returns it in place, other accessors copy it into tmp
  const ElemHeader &header(uint32_t i, ElemHeader &tmp) const { return a_.header(i, tmp); }
  const GraphParams &params() const { return p_; }
  const Acc &acc() const { return a_; }

  // ---------------------------------------------------------------- insert (hnswlib addPoint); write lock held
  uint32_t insert(uint64_t ext_id, uint32_t ins_seq, const float *v, std::mt19937_64 &rng) {
    const uint64_t n = meta_->count;
    if (n >= p_.capacity) throw std::runtime_error("segment full (capacity)");
    const uint32_t cur = uint32_t(n);
    const int curlevel = random_level(rng);
    if (cur % N_ == 0) meta_->upper_cur = 0;  // first element of a new group: its upper arena starts empty
    ElemHeader h{};
    h.ext_id = ext_id;
    h.ins_seq = ins_seq;
    h.level = uint32_t(curlevel);
    if (curlevel > 0) {
      h.upper_off = meta_->upper_cur;
      if (h.upper_off + uint64_t(curlevel) * p_.links_bytes() > p_.upper_group_bytes())
        throw std::runtime_error("upper-level arena of the group full");
      meta_->upper_cur = h.upper_off + uint64_t(curlevel) * p_.links_bytes();
    }
    h.check = uint32_t(ext_id) ^ uint32_t(ext_id >> 32) ^ ins_seq ^ uint32_t(curlevel) ^ kElemMagic;
    a_.write_elem(cur, h, v, uint64_t(curlevel) * p_.links_bytes());

    const uint64_t epl = meta_->ep_level;
    if (epl == kNoEntry) {
      meta_->ep_level = (uint64_t(curlevel) << 32) | cur;
      cxl::hwcc::store_release(&meta_->count, n + 1);
      return cur;
    }
    const int maxlevel = int(epl >> 32);
    uint32_t curr = uint32_t(epl);
    uint32_t lb[kMaxLinkWords];
    if (curlevel < maxlevel) {  // greedy descent through the levels above curlevel
      Dist curdist = dist(v, curr);
      for (int level = maxlevel; level > curlevel; level--)
        for (bool changed = true; changed;) {
          changed = false;
          const uint32_t *ll = links(curr, level, lb);
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
    if (curlevel > maxlevel) meta_->ep_level = (uint64_t(curlevel) << 32) | cur;
    cxl::hwcc::store_release(&meta_->count, n + 1);
    return cur;
  }

  // ---------------------------------------------------------------- query (hnswlib searchKnn); read lock held
  // allowed(internal id) -> bool filters results (E1 visibility); traversal goes through every element, as
  // hnswlib searchBaseLayerST with deletions. visited/tag: the calling thread's own tag array (>= capacity).
  template <class Allowed>
  void search(const float *q, uint32_t k, uint32_t ef, Allowed allowed, std::vector<std::pair<Dist, uint32_t>> *out,
              std::vector<uint16_t> &visited, uint16_t &tag, uint64_t *dists = nullptr) const {
    out->clear();
    const uint64_t epl = meta_->ep_level;
    uint32_t lb[kMaxLinkWords];
    if (epl == kNoEntry) return;
    uint64_t nd = 0;
    uint32_t curr = uint32_t(epl);
    Dist curdist = dist(q, curr);
    nd++;
    for (int level = int(epl >> 32); level > 0; level--)
      for (bool changed = true; changed;) {
        changed = false;
        const uint32_t *ll = links(curr, level, lb);
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
      const uint32_t *ll = links(c.second, 0, lb);
      const uint32_t sz = ll[0];
      for (uint32_t j = 0; j < sz; j++) a_.prefetch(ll[1 + j]);
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

  Dist dist(const float *a, uint32_t id) const { return -a_.dot(a, id); }

 private:
  using MaxHeap = std::priority_queue<std::pair<Dist, uint32_t>>;  // hnswlib CompareByFirst: largest on top

  uint64_t upper_off(uint32_t i, int level) const {
    if (level == 0) return 0;
    ElemHeader tmp;
    return a_.header(i, tmp).upper_off;
  }
  const uint32_t *links(uint32_t i, int level, uint32_t *tmp) const {
    return a_.links(i, level, upper_off(i, level), tmp);
  }
  Dist dist_ids(uint32_t a, uint32_t b) const {
    return -a_.dot(a_.vec(a, vtmp_.data()), b);
  }
  int random_level(std::mt19937_64 &rng) const {
    std::uniform_real_distribution<double> u(0.0, 1.0);
    return int(-std::log(u(rng)) * mult_);
  }

  // hnswlib searchBaseLayer (construction search at one level)
  MaxHeap search_layer_build(uint32_t ep, const float *v, int level, uint32_t cur) {
    if (marks_.size() < p_.capacity) marks_.assign(p_.capacity, 0);
    std::vector<uint32_t> seen;
    MaxHeap top;
    uint32_t lb[kMaxLinkWords];
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
      const uint32_t *ll = links(c.second, level, lb);
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
    uint32_t ob[kMaxLinkWords], nbuf[kMaxLinkWords];
    const uint64_t own_uo = upper_off(cur, level);
    uint32_t *own = a_.links_mut(cur, level, own_uo, ob);
    for (size_t i = 0; i < sel.size(); i++) own[1 + i] = sel[i];
    own[0] = uint32_t(sel.size());
    a_.commit_links(cur, level, own_uo, own);
    for (uint32_t nb : sel) {
      const uint64_t uo = upper_off(nb, level);
      uint32_t *ll = a_.links_mut(nb, level, uo, nbuf);
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
      a_.commit_links(nb, level, uo, ll);
    }
    return sel.front();
  }

  GraphParams p_;
  Acc a_;
  GraphMeta *meta_;
  double mult_;
  uint64_t N_;
  std::vector<uint8_t> marks_;      // construction visited marks (writer side; one graph object per writer thread)
  mutable std::vector<float> vtmp_;  // dist_ids scratch (writer side only; unused by PlainAcc)
};

using ShmHnsw = HnswT<PlainAcc>;

}  // namespace vdb

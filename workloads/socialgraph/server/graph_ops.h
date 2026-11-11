// socialgraph record protocol and operations (DESIGN.md §4), shared by every backend (template Be, backend.h).
//
// Seqlock per record. The version word of a record (NodeSlot.version for a node slot, AdjHeader.version for an
// adjacency list = primary block + its overflow segments) is the sequence: a writer first sets bit 63 (kWriting) with
// an atomic fetch_or (also the first access to the record: write ownership before any read of its bytes), writes the
// record, sets commit_ns, then publishes version + 1 with a release store. A reader loads the version (acquire),
// retries if kWriting is set, copies the record, issues an acquire fence and re-loads the version; a changed version
// means the copy may be torn and the read is retried. Versions therefore keep the LinkBench meaning (node 1 at load,
// list 0 at load, +1 per committed write) and the "odd while writing" state is bit 63. A reader on De Stijl with
// T > 0 may complete the protocol on an older replica: that returns an older complete version (allowed staleness).
// Extra guards (a stale page replica can mix pages of different ages, which no version word on one page detects):
//   - node slots carry a check word (NodeSlot.pad, set by every writer; 0 = image record, accepted only with
//     commit_ns 0): a mismatch is treated like a changed version (retry);
//   - adjacency walks check bounds (start <= cap, segment index < ovf blocks, overflow block id1 = list owner, edge
//     data_len <= cap, id2 inside the node array): a failed check is retried as well (counted in guard_rejects).
// Retries spin 64 times, then yield; after retry_ns without a consistent copy the read gives up (kStatusBusy).
//
// Writers: one writer thread per VM. Mutual exclusion between VMs' writers on the same record: HWcc stripe locks
// (Locks, in the region's HWcc app range), striped by record id. Node slack slots and overflow pool blocks are
// allocated by index mod N (layout.h owned_by): writer w scans only its own indices (private cursor, no shared
// counter; a slot / block in use from an earlier run on the same region is skipped).
// addlink only to original ids (slot < n_orig, as LinkBench); an addlink of an existing (id1, type, id2) updates it
// (LinkBench addLink), a deleted one is revived.
#pragma once

#include <immintrin.h>
#include <sched.h>
#include <time.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../proto.h"
#include "backend.h"
#include "layout.h"
#include "stale_log.h"

namespace sg {

constexpr uint64_t kWriting = 1ull << 63;

inline uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

inline uint32_t node_check(const NodeSlot &s, uint64_t version) {
  uint64_t x = 1469598103934665603ull;
  auto mix = [&](const void *p, size_t n) {
    const uint8_t *b = static_cast<const uint8_t *>(p);
    for (size_t i = 0; i < n; i++) x = (x ^ b[i]) * 1099511628211ull;
  };
  mix(&s.id, 8), mix(&version, 8), mix(&s.commit_ns, 8), mix(&s.type, 4), mix(&s.time_s, 4), mix(&s.flags, 2);
  mix(&s.data_len, 2);
  mix(s.data, s.data_len <= kNodeDataCap ? s.data_len : kNodeDataCap);
  const uint32_t c = uint32_t(x ^ (x >> 32));
  return c ? c : 1;
}
inline bool node_check_ok(const NodeSlot &s) {
  if (s.data_len > kNodeDataCap) return false;
  if (s.pad == 0) return s.commit_ns == 0;  // image record (or free slack slot), never written
  return s.pad == node_check(s, s.version);
}

// HWcc stripe locks: n stripes, one 64 B line each (first word: 0 = free, else holder node + 1).
struct Locks {
  uint64_t *w = nullptr;
  uint32_t n = 0, owner = 1;
  static uint64_t mix(uint64_t k) {
    k ^= k >> 33, k *= 0xff51afd7ed558ccdull, k ^= k >> 33;
    return k;
  }
  uint64_t *word(uint64_t key) const { return w + (mix(key) % n) * 8; }
  void lock(uint64_t key) const {
    uint64_t *p = word(key);
    for (uint32_t i = 0;; i++) {
      uint64_t z = 0;
      if (__atomic_load_n(p, __ATOMIC_RELAXED) == 0 &&
          __atomic_compare_exchange_n(p, &z, uint64_t(owner), false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
      if (i < 1024) _mm_pause();
      else sched_yield();
    }
  }
  void unlock(uint64_t key) const { __atomic_store_n(word(key), uint64_t(0), __ATOMIC_RELEASE); }
};

// Per-thread counters (summed into the server stats by the owner of the Ctx).
struct OpCtr {
  uint64_t retries = 0, guard_rejects = 0, check_fails = 0, giveups = 0, records = 0;
};
struct Ctx {
  StaleLog::Buf *sb = nullptr;  // reader: read sample buffer; writer: commit buffer
  OpCtr c;
};

struct ListHead {  // consistent copy of a list header (version without kWriting)
  AdjHeader h;
};

template <class Be>
class GraphOps {
 public:
  GraphOps(Be &be, const Locks *locks, StaleLog *sl, uint32_t node, uint32_t n_writers, uint64_t retry_ns)
      : be_(be), h_(be.header()), locks_(locks), sl_(sl), node_(node), nw_(n_writers ? n_writers : 1), retry_ns_(retry_ns) {
    node_cur_ = first_owned(h_.n_orig);
    ovf_cur_ = first_owned(h_.ovf_built);
  }
  const ImageHeader &header() const { return h_; }
  uint64_t slot_of(uint64_t id) const {
    return id >= h_.id_base && id - h_.id_base < h_.n_nodes() ? id - h_.id_base : h_.n_nodes();
  }
  uint64_t id_of(uint64_t slot) const { return h_.id_base + slot; }

  // ------------------------------------------------------------------ reads
  // Node slot copy -> *out. kStatusOk (live node), kStatusNotFound (out of range, free or deleted), kStatusBusy.
  uint16_t get_node(Ctx &cx, uint64_t slot, NodeSlot *out) const {
    if (slot >= h_.n_nodes()) return kStatusNotFound;
    if (!retry(cx, [&] {
          return be_.read(ObjKind::kNode, slot, [&](const uint8_t *p) -> int {
            const NodeSlot *s = reinterpret_cast<const NodeSlot *>(p);
            const uint64_t v1 = __atomic_load_n(&s->version, __ATOMIC_ACQUIRE);
            if (v1 & kWriting) return 1;
            std::memcpy(static_cast<void *>(out), s, sizeof(NodeSlot));
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            if (__atomic_load_n(&s->version, __ATOMIC_RELAXED) != v1) return 1;
            out->version = v1;
            if (!node_check_ok(*out)) return 3;
            return 0;
          });
        }))
      return kStatusBusy;
    cx.c.records++;
    if (sl_) sl_->read(cx.sb, rid(kRidNode, slot), out->version);
    return (out->flags & kNodeLive) && !(out->flags & kNodeDeleted) ? kStatusOk : kStatusNotFound;
  }

  // List header only (countlink). kStatusOk / kStatusNotFound (no list) / kStatusBusy.
  uint16_t get_list_head(Ctx &cx, uint64_t slot, AdjHeader *out) const {
    if (!be_.has_adj(slot)) return kStatusNotFound;
    if (!retry(cx, [&] {
          return be_.read(ObjKind::kAdj, slot, [&](const uint8_t *p) -> int {
            const AdjHeader *a = reinterpret_cast<const AdjHeader *>(p);
            const uint64_t v1 = __atomic_load_n(&a->version, __ATOMIC_ACQUIRE);
            if (v1 & kWriting) return 1;
            std::memcpy(static_cast<void *>(out), a, sizeof(AdjHeader));
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            if (__atomic_load_n(&a->version, __ATOMIC_RELAXED) != v1) return 1;
            out->version = v1;
            if (out->count > out->used) return 2;
            return 0;
          });
        }))
      return kStatusBusy;
    cx.c.records++;
    if (sl_) sl_->read(cx.sb, rid(kRidList, slot), out->version);
    return kStatusOk;
  }

  // Edges of a list newest first (physical order) into *edges: live edges of assoc_type only (live_only) up to limit
  // (0 = all), or every occupied slot (live_only false; used by tests). *head = consistent header copy.
  uint16_t get_list(Ctx &cx, uint64_t slot, bool live_only, uint16_t assoc_type, uint32_t limit,
                    std::vector<EdgeSlot> *edges, AdjHeader *head) const {
    if (!be_.has_adj(slot)) return kStatusNotFound;
    if (!retry(cx, [&] {
          return be_.read(ObjKind::kAdj, slot, [&](const uint8_t *p) -> int {
            const AdjHeader *a = reinterpret_cast<const AdjHeader *>(p);
            const uint64_t v1 = __atomic_load_n(&a->version, __ATOMIC_ACQUIRE);
            if (v1 & kWriting) return 1;
            std::memcpy(static_cast<void *>(head), a, sizeof(AdjHeader));
            edges->clear();
            const int r = walk(slot, *head, p, false, [&](const EdgeSlot &e, uint32_t, uint32_t) {
              if (!live_only || ((e.flags & kEdgeLive) && e.assoc_type == assoc_type)) edges->push_back(e);
              return !(limit && edges->size() >= limit);
            });
            if (r) return r;
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            if (__atomic_load_n(&a->version, __ATOMIC_RELAXED) != v1) return 1;
            head->version = v1;
            return 0;
          });
        }))
      return kStatusBusy;
    cx.c.records++;
    if (sl_) sl_->read(cx.sb, rid(kRidList, slot), head->version);
    return kStatusOk;
  }

  // ------------------------------------------------------------------ writes (writer thread of this VM only)
  struct WriteOut {
    uint64_t id = 0, version = 0, commit_ns = 0;
  };
  uint16_t add_link(Ctx &cx, uint64_t id1, uint32_t id2, uint16_t type, uint64_t time, const uint8_t *data,
                    uint32_t len, WriteOut *w) {
    return link_write(cx, kOpAddLink, id1, id2, type, time, data, len, w);
  }
  uint16_t update_link(Ctx &cx, uint64_t id1, uint32_t id2, uint16_t type, uint64_t time, const uint8_t *data,
                       uint32_t len, WriteOut *w) {
    return link_write(cx, kOpUpdateLink, id1, id2, type, time, data, len, w);
  }
  uint16_t delete_link(Ctx &cx, uint64_t id1, uint32_t id2, uint16_t type, WriteOut *w) {
    return link_write(cx, kOpDeleteLink, id1, id2, type, 0, nullptr, 0, w);
  }
  // addnode: id ignored (a free owned slack slot is taken; w->id = its id)
  uint16_t node_write(Ctx &cx, uint16_t op, uint64_t id, uint32_t type, const uint8_t *data, uint32_t len,
                      WriteOut *w) {
    uint64_t slot;
    if (op == kOpAddNode) {
      slot = alloc_node();
      if (slot >= h_.n_nodes()) return kStatusFull;
    } else {
      slot = slot_of(id);
      if (slot >= h_.n_nodes()) return kStatusNotFound;
    }
    if (len > kNodeDataCap) len = kNodeDataCap;
    const uint64_t key = rid(kRidNode, slot);
    locks_->lock(key);
    uint16_t st = kStatusOk;
    uint64_t nv = 0, t0 = 0;
    be_.write(ObjKind::kNode, slot, [&](uint8_t *p) {
      NodeSlot *s = reinterpret_cast<NodeSlot *>(p);
      const uint64_t v = __atomic_fetch_or(&s->version, kWriting, __ATOMIC_ACQ_REL) & ~kWriting;
      __atomic_thread_fence(__ATOMIC_RELEASE);
      const bool live = (s->flags & kNodeLive) && !(s->flags & kNodeDeleted);
      if (op == kOpAddNode ? s->flags != 0 : !live) {
        st = op == kOpAddNode ? kStatusFull : kStatusNotFound;
        __atomic_store_n(&s->version, v, __ATOMIC_RELEASE);
        return;
      }
      if (op == kOpDeleteNode) {
        s->flags = kNodeLive | kNodeDeleted;
      } else {
        s->id = id_of(slot);
        s->type = type;
        s->time_s = uint32_t(realtime_ns() / 1000000000ull);
        s->flags = kNodeLive;
        s->data_len = uint16_t(len);
        if (len) std::memcpy(s->data, data, len);
      }
      nv = v + 1;
      t0 = realtime_ns();
      s->commit_ns = t0;
      s->pad = node_check(*s, nv);
      __atomic_store_n(&s->version, nv, __ATOMIC_RELEASE);
    });
    locks_->unlock(key);
    if (st != kStatusOk) return st;
    const uint64_t t1 = realtime_ns();
    if (sl_) sl_->commit(cx.sb, key, nv, t1);
    cx.c.records++;
    w->id = id_of(slot), w->version = nv, w->commit_ns = t0;
    return kStatusOk;
  }

  uint64_t pool_left() const { return ovf_cur_ < h_.ovf_blocks() ? (h_.ovf_blocks() - ovf_cur_ + nw_ - 1) / nw_ : 0; }
  uint64_t slack_left() const { return node_cur_ < h_.n_nodes() ? (h_.n_nodes() - node_cur_ + nw_ - 1) / nw_ : 0; }

 private:
  uint64_t first_owned(uint64_t from) const {
    uint64_t x = from;
    while (!owned_by(x, node_, nw_)) x++;
    return x;
  }
  // a: attempt -> 0 ok, 1 changed / writing, 2 guard, 3 node check
  template <class A> bool retry(Ctx &cx, A a) const {
    uint64_t t0 = 0;
    for (uint32_t i = 0;; i++) {
      const int r = a();
      if (r == 0) return true;
      if (r == 2) cx.c.guard_rejects++;
      else if (r == 3) cx.c.check_fails++;
      else cx.c.retries++;
      if (i < 64) {
        _mm_pause();
        continue;
      }
      const uint64_t now = mono_ns();
      if (!t0) t0 = now;
      else if (now - t0 > retry_ns_) {
        cx.c.giveups++;
        return false;
      }
      sched_yield();
    }
  }

  // Walk list `slot` with header copy h (inline slots at blk + 64): f(edge copy, segment, index) -> false stops.
  // Reader (writer == false): overflow segments through be.read; writer: segments read through be.read as well
  // (the writer holds the list lock), the head segment is owned by the caller. Returns 0 or 2 (guard).
  template <class F> int walk(uint64_t slot, const AdjHeader &h, const uint8_t *blk, bool writer, F f) const {
    (void)writer;
    const uint64_t blk_bytes = be_.rec_bytes(ObjKind::kAdj, slot);
    if (h.cap > kInlineMaxCap || h.start > h.cap || sizeof(AdjHeader) + uint64_t(h.cap) * sizeof(EdgeSlot) > blk_bytes)
      return 2;
    if (h.id1 != id_of(slot)) return 2;
    const uint64_t nb = h_.ovf_blocks(), nn = h_.n_nodes();
    uint32_t seg = h.head;
    for (uint64_t steps = 0; seg != kSegNone; steps++) {
      if (steps > uint64_t(h.n_ovf) + 1) return 2;
      if (seg == kSegInline) {
        const EdgeSlot *s = reinterpret_cast<const EdgeSlot *>(blk + sizeof(AdjHeader));
        for (uint32_t i = h.start; i < h.cap; i++) {
          EdgeSlot e;
          std::memcpy(&e, s + i, sizeof e);
          if (e.data_len > kEdgeDataCap || slot_of(e.id2) >= nn) return 2;
          if (!f(e, seg, i)) return 0;
        }
        seg = h.next;
        continue;
      }
      if (seg >= nb) return 2;
      uint32_t next = kSegNone;
      bool stop = false;
      const int r = be_.read(ObjKind::kOvf, seg, [&](const uint8_t *q) -> int {
        const OvfBlock *o = reinterpret_cast<const OvfBlock *>(q);
        OvfHeader oh;
        std::memcpy(&oh, &o->h, sizeof oh);
        if (oh.id1 != h.id1 || oh.cap != kOvfSlots || oh.start > oh.cap) return 2;
        for (uint32_t i = oh.start; i < oh.cap; i++) {
          EdgeSlot e;
          std::memcpy(&e, o->slot + i, sizeof e);
          if (e.data_len > kEdgeDataCap || slot_of(e.id2) >= nn) return 2;
          if (!f(e, seg, i)) { stop = true; return 0; }
        }
        next = oh.next;
        return 0;
      });
      if (r) return r;
      if (stop) return 0;
      seg = next;
    }
    return 0;
  }

  uint64_t alloc_node() {
    while (node_cur_ < h_.n_nodes()) {
      const uint64_t s = node_cur_;
      node_cur_ += nw_;
      const bool free = be_.read(ObjKind::kNode, s, [&](const uint8_t *p) {
        const NodeSlot *n = reinterpret_cast<const NodeSlot *>(p);
        return __atomic_load_n(&n->flags, __ATOMIC_ACQUIRE) == 0;
      });
      if (free) return s;  // owned: no other writer takes it (node_write re-checks under the lock)
    }
    return h_.n_nodes();
  }
  uint32_t alloc_ovf() {
    while (ovf_cur_ < h_.ovf_blocks()) {
      const uint64_t b = ovf_cur_;
      ovf_cur_ += nw_;
      const bool free = be_.read(ObjKind::kOvf, b, [&](const uint8_t *p) {
        return reinterpret_cast<const OvfBlock *>(p)->h.id1 == 0;
      });
      if (free) return uint32_t(b);
    }
    return kSegNone;
  }

  static void fill_edge(EdgeSlot *e, uint32_t id2, uint16_t type, uint64_t time, uint32_t version, const uint8_t *d,
                        uint32_t len) {
    EdgeSlot x{};
    x.id2 = id2, x.assoc_type = type, x.flags = kEdgeLive, x.data_len = uint8_t(len), x.time = time, x.version = version;
    if (len) std::memcpy(x.data, d, len);
    std::memcpy(static_cast<void *>(e), &x, sizeof x);
  }

  uint16_t link_write(Ctx &cx, uint16_t op, uint64_t id1, uint32_t id2, uint16_t type, uint64_t time,
                      const uint8_t *data, uint32_t len, WriteOut *w) {
    const uint64_t slot = slot_of(id1);
    if (slot >= h_.n_orig || !be_.has_adj(slot)) return kStatusNotFound;  // addlink only to original ids
    if (slot_of(id2) >= h_.n_nodes()) return kStatusBad;
    if (len > kEdgeDataCap) len = kEdgeDataCap;
    const uint64_t key = rid(kRidList, slot);
    locks_->lock(key);
    uint16_t st = kStatusOk;
    uint64_t nv = 0, t0 = 0;
    be_.write(ObjKind::kAdj, slot, [&](uint8_t *p) {
      AdjHeader *a = reinterpret_cast<AdjHeader *>(p);
      const uint64_t v = __atomic_fetch_or(&a->version, kWriting, __ATOMIC_ACQ_REL) & ~kWriting;
      __atomic_thread_fence(__ATOMIC_RELEASE);
      auto abort = [&](uint16_t s) {
        st = s;
        __atomic_store_n(&a->version, v, __ATOMIC_RELEASE);
      };
      AdjHeader h;
      std::memcpy(&h, a, sizeof h);
      // find (type, id2): first occupied slot (live preferred) newest first
      uint32_t fseg = kSegNone, fidx = 0;
      bool flive = false;
      EdgeSlot fe{};
      const int r = walk(slot, h, p, true, [&](const EdgeSlot &e, uint32_t seg, uint32_t i) {
        if (e.id2 != id2 || e.assoc_type != type) return true;
        if (fseg == kSegNone || (!flive && (e.flags & kEdgeLive))) fseg = seg, fidx = i, flive = e.flags & kEdgeLive, fe = e;
        return !flive;
      });
      if (r) return abort(kStatusBad);
      if (op != kOpAddLink && (fseg == kSegNone || !flive)) return abort(kStatusNotFound);
      if (fseg != kSegNone) {  // in-place: update / delete / addlink of an existing link
        auto mod = [&](EdgeSlot *e) {
          if (op == kOpDeleteLink) {
            uint8_t f = e->flags & uint8_t(~kEdgeLive);
            std::memcpy(&e->flags, &f, 1);
          } else {
            fill_edge(e, id2, type, time, fe.version + 1, data, len);
          }
        };
        if (fseg == kSegInline) {
          mod(a->inline_slots() + fidx);
        } else {
          const uint64_t off = offsetof(OvfBlock, slot) + uint64_t(fidx) * sizeof(EdgeSlot);
          be_.write_range(ObjKind::kOvf, fseg, off, sizeof(EdgeSlot), [&](uint8_t *q) {
            mod(reinterpret_cast<OvfBlock *>(q)->slot + fidx);
          });
        }
        if (op == kOpDeleteLink) a->count--;
        else if (!flive) a->count++;  // revived
      } else {  // append a new link at the head segment
        bool done = false;
        if (h.head == kSegInline) {
          if (h.start > 0) {
            fill_edge(a->inline_slots() + h.start - 1, id2, type, time, 0, data, len);
            a->start = uint16_t(h.start - 1);
            done = true;
          }
        } else {
          be_.write(ObjKind::kOvf, h.head, [&](uint8_t *q) {
            OvfBlock *o = reinterpret_cast<OvfBlock *>(q);
            if (o->h.start > 0) {
              fill_edge(o->slot + o->h.start - 1, id2, type, time, 0, data, len);
              o->h.start = uint16_t(o->h.start - 1);
              done = true;
            }
          });
        }
        if (!done) {
          const uint32_t b = alloc_ovf();
          if (b == kSegNone) return abort(kStatusFull);
          be_.write(ObjKind::kOvf, b, [&](uint8_t *q) {
            OvfBlock *o = reinterpret_cast<OvfBlock *>(q);
            fill_edge(o->slot + kOvfSlots - 1, id2, type, time, 0, data, len);
            o->h.cap = uint16_t(kOvfSlots);
            o->h.start = uint16_t(kOvfSlots - 1);
            o->h.next = h.head;
            __atomic_store_n(&o->h.id1, h.id1, __ATOMIC_RELEASE);
          });
          a->head = b;
          a->n_ovf = h.n_ovf + 1;
        }
        a->count = h.count + 1;
        a->used = h.used + 1;
      }
      nv = v + 1;
      t0 = realtime_ns();
      a->commit_ns = t0;
      __atomic_store_n(&a->version, nv, __ATOMIC_RELEASE);
    });
    locks_->unlock(key);
    if (st != kStatusOk) return st;
    const uint64_t t1 = realtime_ns();
    if (sl_) sl_->commit(cx.sb, key, nv, t1);
    cx.c.records++;
    w->id = id1, w->version = nv, w->commit_ns = t0;
    return kStatusOk;
  }

  Be &be_;
  const ImageHeader &h_;
  const Locks *locks_;
  StaleLog *sl_;
  uint32_t node_, nw_;
  uint64_t retry_ns_;
  uint64_t node_cur_ = 0, ovf_cur_ = 0;  // writer's private allocation cursors (owned indices)
};

}  // namespace sg

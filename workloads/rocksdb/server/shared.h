// Shared state of one process (node u): its own pools (owner side: arena blocks, file extents, directory slots,
// deferred free) and reader epochs for reading other nodes' state (DESIGN.md §3).
//
// Deferred free (owner v): an item retired at gen T (v's descriptor gen when retired) is reused only when every
// reader epoch for v of every other node is 0 or > T. A reader thread of node u that is about to read node v's
// state stores e = min(gen_v, applied_v) in its epoch line (seq_cst), then reads; the owner retires, then scans
// the epochs (seq_cst). Either the owner sees the epoch, or the reader sees the newer state that no longer refers
// to the item (DESIGN.md §3; the same argument as LMDB's reader table, workloads/lmdb/DESIGN.md §4).
#pragma once

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "backend.h"
#include "layout.h"

namespace rdbw {

inline uint64_t desc_gen(const Desc *d) { return cxl::hwcc::load_acquire(&d->seq) / 2; }

class Shared {
 public:
  Shared(const cxl::region &r, uint8_t *map, const Params &p, const SwccPlan &plan, Hwcc *h, Backend *be,
         uint32_t me)
      : r_(r), map_(map), p_(p), plan_(plan), h_(h), be_(be), me_(me) {
    for (uint64_t i = 0; i < plan_.arena_blocks; i++) free_blocks_.push_back(i);
    for (uint64_t j = 0; j < plan_.file_extents; j++) free_ext_.push_back(uint32_t(j));
    ext_refs_.assign(plan_.file_extents, 0);
    for (uint32_t s = 0; s < p_.max_files; s++) free_slots_.push_back(s);
  }

  const Params &params() const { return p_; }
  const SwccPlan &plan() const { return plan_; }
  Hwcc *hwcc() const { return h_; }
  Backend *backend() const { return be_; }
  uint32_t me() const { return me_; }
  uint8_t *map() const { return map_; }
  uint64_t my_gen() const { return desc_gen(&h_->desc[me_]); }

  uint8_t *block_addr(uint32_t node, uint64_t i) const { return map_ + plan_.block_off(node, i); }
  uint8_t *extent_addr(uint32_t node, uint32_t j) const { return map_ + plan_.extent_off(node, j); }
  bool block_index(const char *p, uint64_t *i) const {
    const uint64_t off = uint64_t(reinterpret_cast<const uint8_t *>(p) - map_);
    const uint64_t lo = plan_.block_off(me_, 0), hi = plan_.block_off(me_, plan_.arena_blocks);
    if (off < lo || off >= hi || (off - lo) % kUnit) return false;
    *i = (off - lo) / kUnit;
    return true;
  }

  // ---- owner side (node me): allocation and deferred free ----
  char *get_block() {
    std::lock_guard<std::mutex> g(mu_);
    if (free_blocks_.empty()) reclaim_locked();
    if (free_blocks_.empty()) return nullptr;
    const uint64_t i = free_blocks_.front();
    free_blocks_.pop_front();
    blocks_used_++;
    return reinterpret_cast<char *>(block_addr(me_, i));
  }
  void retire_blocks(const std::vector<char *> &blocks) {
    std::lock_guard<std::mutex> g(mu_);
    Retired r{my_gen(), {}, {}, UINT32_MAX};
    for (char *b : blocks) {
      uint64_t i;
      if (!block_index(b, &i)) die_bad("retire of a block outside the arena pool");
      r.blocks.push_back(i);
    }
    retired_.push_back(std::move(r));
  }
  // extents: owner-local reference counts (LinkFile shares extents between slots)
  bool get_extent(uint32_t *j) {
    std::lock_guard<std::mutex> g(mu_);
    if (free_ext_.empty()) reclaim_locked();
    if (free_ext_.empty()) return false;
    *j = free_ext_.front();
    free_ext_.pop_front();
    ext_refs_[*j] = 1;
    ext_used_++;
    return true;
  }
  void ref_extent(uint32_t j) {
    std::lock_guard<std::mutex> g(mu_);
    ext_refs_[j]++;
  }
  bool get_slot(uint32_t *s) {
    std::lock_guard<std::mutex> g(mu_);
    if (free_slots_.empty()) reclaim_locked();
    if (free_slots_.empty()) return false;
    *s = free_slots_.front();
    free_slots_.pop_front();
    return true;
  }
  // a deleted file: its slot and one reference of each of its extents, freed after the epochs pass
  void retire_file(uint32_t slot, const std::vector<uint32_t> &exts) {
    std::lock_guard<std::mutex> g(mu_);
    retired_.push_back(Retired{my_gen(), {}, exts, slot});
  }
  // a slot that never became visible (creation failed) goes straight back
  void free_slot_now(uint32_t s) {
    std::lock_guard<std::mutex> g(mu_);
    free_slots_.push_back(s);
  }
  void reclaim() {
    std::lock_guard<std::mutex> g(mu_);
    reclaim_locked();
  }
  std::string usage() {
    std::lock_guard<std::mutex> g(mu_);
    return "blocks_free=" + std::to_string(free_blocks_.size()) + " extents_free=" + std::to_string(free_ext_.size()) +
           " slots_free=" + std::to_string(free_slots_.size()) + " retired=" + std::to_string(retired_.size()) +
           " blocks_used_total=" + std::to_string(blocks_used_) + " extents_used_total=" + std::to_string(ext_used_);
  }
  uint64_t free_extents() {
    std::lock_guard<std::mutex> g(mu_);
    return free_ext_.size();
  }

  // ---- reader side (node me reading node v) ----
  // Per thread one epoch slot of this node (assigned on first use; fixed count, refuse when exhausted).
  EpochLine *my_epoch_line() {
    thread_local int slot = -1;
    thread_local const Shared *owner = nullptr;
    if (owner != this) {
      slot = next_slot_.fetch_add(1);
      owner = this;
      if (slot >= int(p_.epoch_slots)) die_bad("epoch slots exhausted (raise --epoch-slots)");
    }
    return h_->epoch(me_, uint32_t(slot));
  }
  void epoch_enter(uint32_t v, uint64_t e) {
    EpochLine *l = my_epoch_line();
    __atomic_store_n(&l->e[v], e < 1 ? 1 : e, __ATOMIC_SEQ_CST);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
  }
  void epoch_exit(uint32_t v) { __atomic_store_n(&my_epoch_line()->e[v], uint64_t(0), __ATOMIC_RELEASE); }

 private:
  struct Retired {
    uint64_t tag;
    std::vector<uint64_t> blocks;
    std::vector<uint32_t> exts;
    uint32_t slot;  // UINT32_MAX = none
  };
  [[noreturn]] static void die_bad(const char *m) {
    std::fprintf(stderr, "rocksdb-cxl: FATAL %s\n", m);
    std::fflush(stderr);
    std::_Exit(2);
  }
  // smallest active epoch for node me over every other node's slots (UINT64_MAX if none)
  uint64_t min_reader_epoch() const {
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    uint64_t m = UINT64_MAX;
    for (uint32_t u = 0; u < p_.nr_nodes; u++) {
      if (u == me_) continue;
      for (uint32_t s = 0; s < p_.epoch_slots; s++) {
        const uint64_t e = __atomic_load_n(&h_->epoch(u, s)->e[me_], __ATOMIC_SEQ_CST);
        if (e && e < m) m = e;
      }
    }
    return m;
  }
  void reclaim_locked() {
    if (retired_.empty()) return;
    const uint64_t m = min_reader_epoch();
    for (auto it = retired_.begin(); it != retired_.end();) {
      if (it->tag < m) {
        for (uint64_t b : it->blocks) free_blocks_.push_back(b);
        for (uint32_t j : it->exts)
          if (--ext_refs_[j] == 0) free_ext_.push_back(j);
        if (it->slot != UINT32_MAX) {
          FileHead *fh = h_->head(me_, it->slot);
          cxl::hwcc::store_relaxed(&fh->size, uint64_t(0));
          free_slots_.push_back(it->slot);
        }
        it = retired_.erase(it);
      } else {
        ++it;
      }
    }
  }

  const cxl::region &r_;
  uint8_t *map_;
  const Params p_;
  const SwccPlan plan_;
  Hwcc *h_;
  Backend *be_;
  const uint32_t me_;
  std::mutex mu_;
  std::deque<uint64_t> free_blocks_;
  std::deque<uint32_t> free_ext_;
  std::vector<uint16_t> ext_refs_;
  std::deque<uint32_t> free_slots_;
  std::deque<Retired> retired_;
  uint64_t blocks_used_ = 0, ext_used_ = 0;
  std::atomic<int> next_slot_{0};
};

}  // namespace rdbw

// Read-only view of another node's DB (DESIGN.md §2): its memtables read directly through the HWcc descriptor
// (rocksdb/cxl.h RemoteMemtableGet), its SSTs through a RocksDB secondary instance over the shared files
// (OpenAsSecondary / TryCatchUpWithPrimary, used only for the immutable SST/MANIFEST side; WAL off).
// Every access runs inside this thread's reader epoch for the node (shared.h).
#pragma once

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "cxlfs.h"
#include "proc_stats.h"
#include "proto.h"
#include "rocksdb/cxl.h"
#include "rocksdb/db.h"
#include "shared.h"

namespace rdbw {

struct DescSnap {
  uint64_t gen = 0, flush_gen = 0, n = 0;
  MemEntry m[kMaxMemtables];
};
inline DescSnap read_desc(const Desc *d) {
  for (;;) {
    const uint64_t s1 = cxl::hwcc::load_acquire(&d->seq);
    if (s1 & 1) {
      __builtin_ia32_pause();
      continue;
    }
    DescSnap s;
    s.gen = s1 / 2;
    s.flush_gen = cxl::hwcc::load_relaxed(&d->flush_gen);
    s.n = std::min<uint64_t>(cxl::hwcc::load_relaxed(&d->n), kMaxMemtables);
    for (uint64_t i = 0; i < s.n; i++) {
      s.m[i].id = cxl::hwcc::load_relaxed(&d->m[i].id);
      s.m[i].head = cxl::hwcc::load_relaxed(&d->m[i].head);
      s.m[i].height = cxl::hwcc::load_relaxed(&d->m[i].height);
    }
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (cxl::hwcc::load_relaxed(&d->seq) == s1) return s;
  }
}

struct RemoteStats {
  std::atomic<uint64_t> gets{0}, mem_hits{0}, sst_hits{0}, misses{0}, catchups{0}, sync_catchups{0},
      catchup_errors{0}, catchup_ns{0}, errors{0};
};

class RemoteView {
 public:
  RemoteView(Shared *sh, uint32_t node) : sh_(sh), v_(node) {}
  ~RemoteView() { stop_ = true; if (bg_.joinable()) bg_.join(); }

  bool open(ROCKSDB_NAMESPACE::Options o, const std::string &sec_dir, std::string *err) {
    o.db_host_id = "cxl-secondary";  // not the primary: no shared arena, no descriptor hook
    o.create_if_missing = false;
    o.wal_dir = sec_dir + "/wal";    // empty local dir: the WAL is off, memtables are read directly
    o.db_log_dir = "";
    o.max_open_files = -1;
    o.env->CreateDirIfMissing(sec_dir);
    o.env->CreateDirIfMissing(o.wal_dir);
    epoch_enter_now();
    const uint64_t g0 = desc_gen(&sh_->hwcc()->desc[v_]);
    ROCKSDB_NAMESPACE::DB *db = nullptr;
    auto s = ROCKSDB_NAMESPACE::DB::OpenAsSecondary(o, CxlFs::dir_of(v_), sec_dir, &db);
    sh_->epoch_exit(v_);
    if (!s.ok()) return *err = "OpenAsSecondary node " + std::to_string(v_) + ": " + s.ToString(), false;
    db_.reset(db);
    applied_.store(g0);
    bg_ = std::thread([this] { background(); });
    return true;
  }

  enum class Res { kNotFound, kFound, kError };
  // Newest value of key in node v's DB: memtables (newest first), then its SSTs. *stored = stamp + value.
  Res get(const std::string &key, std::string *stored) {
    st_.gets.fetch_add(1, std::memory_order_relaxed);
    epoch_enter_now();
    const DescSnap d = read_desc(&sh_->hwcc()->desc[v_]);
    if (applied_.load(std::memory_order_acquire) < d.flush_gen) {
      st_.sync_catchups.fetch_add(1, std::memory_order_relaxed);
      catch_up(d.flush_gen);
    }
    Res r = Res::kNotFound;
    bool done = false;
    for (uint64_t i = 0; i < d.n && !done; i++) {
      if (!d.m[i].head) continue;
      uint64_t seq;
      auto mr = ROCKSDB_NAMESPACE::cxl::RemoteMemtableGet(reinterpret_cast<const void *>(d.m[i].head),
                                                          int(d.m[i].height), key, stored, &seq);
      if (mr == ROCKSDB_NAMESPACE::cxl::RemoteResult::kFound) {
        r = Res::kFound, done = true;
        st_.mem_hits.fetch_add(1, std::memory_order_relaxed);
      } else if (mr == ROCKSDB_NAMESPACE::cxl::RemoteResult::kDeleted) {
        r = Res::kNotFound, done = true;
      } else if (mr == ROCKSDB_NAMESPACE::cxl::RemoteResult::kUnsupported) {
        r = Res::kError, done = true;
      }
    }
    if (!done) {
      auto s = db_->Get(ROCKSDB_NAMESPACE::ReadOptions(), key, stored);
      if (s.ok()) r = Res::kFound, st_.sst_hits.fetch_add(1, std::memory_order_relaxed);
      else if (s.IsNotFound()) r = Res::kNotFound;
      else r = Res::kError;
    }
    sh_->epoch_exit(v_);
    if (r == Res::kNotFound) st_.misses.fetch_add(1, std::memory_order_relaxed);
    if (r == Res::kError) st_.errors.fetch_add(1, std::memory_order_relaxed);
    return r;
  }

  const RemoteStats &stats() const { return st_; }
  uint64_t applied() const { return applied_.load(); }
  ROCKSDB_NAMESPACE::DB *db() const { return db_.get(); }

 private:
  // epoch = min(v's current gen, the gen the secondary is caught up to): covers both the descriptor snapshot this
  // thread reads next and the secondary state its Get uses (shared.h; DESIGN.md §3)
  void epoch_enter_now() {
    const uint64_t g = desc_gen(&sh_->hwcc()->desc[v_]);
    sh_->epoch_enter(v_, std::min(g, applied_.load(std::memory_order_acquire)));
  }
  void catch_up(uint64_t need) {
    std::lock_guard<std::mutex> l(cmu_);
    if (applied_.load(std::memory_order_acquire) >= need && need) return;
    const uint64_t g0 = desc_gen(&sh_->hwcc()->desc[v_]);  // every MANIFEST edit up to g0 is written already
    const auto t0 = std::chrono::steady_clock::now();
    auto s = db_->TryCatchUpWithPrimary();
    st_.catchup_ns.fetch_add(uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                          std::chrono::steady_clock::now() - t0).count()),
                             std::memory_order_relaxed);
    st_.catchups.fetch_add(1, std::memory_order_relaxed);
    if (!s.ok()) {
      st_.catchup_errors.fetch_add(1, std::memory_order_relaxed);
      std::fprintf(stderr, "rocksdb-server: catch-up node %u: %s\n", v_, s.ToString().c_str());
      return;
    }
    applied_.store(g0, std::memory_order_release);
  }
  // keeps the secondary close to the primary so a get rarely waits for a catch-up
  void background() {
    cxl::proc::name_thread("rdb-catchup");
    while (!stop_) {
      if (desc_gen(&sh_->hwcc()->desc[v_]) > applied_.load(std::memory_order_acquire)) {
        epoch_enter_now();
        catch_up(0);
        sh_->epoch_exit(v_);
      }
      std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
  }

  Shared *sh_;
  const uint32_t v_;
  std::unique_ptr<ROCKSDB_NAMESPACE::DB> db_;
  std::atomic<uint64_t> applied_{0};
  std::mutex cmu_;
  RemoteStats st_;
  std::atomic<bool> stop_{false};
  std::thread bg_;
};

}  // namespace rdbw

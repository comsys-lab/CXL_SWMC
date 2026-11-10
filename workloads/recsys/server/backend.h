// recsys backends (DESIGN.md §7): where the row records live and which coherence actions wrap each record access.
// Addressing is the same in every system (user decision 2026-10-18, reports/H1-workload-porting.md Q11/Q12): the key
// names its row, row r of table k is record (k, r); no hash table, no probing, no empty records.
//   plain   all-HWcc and Popcorn: records at SWcc offset (row_base[k] + r) * slot_bytes, direct loads/stores.
//           Consistency of a 9-line row copy is the application's job (kAppSeqlock): HWcc and Popcorn give coherence,
//           not multi-line atomicity, so server.cc wraps record accesses in the HWcc striped version table (MemC3).
//   megalon one Megalon object per table (--mg-rows-per-object 0, main), per row (1, restructured best case) or per
//           N-row chunk (N > 1); object id = (table, chunk), found by Megalon's own index as in the artifact KV store.
//           Every row read is one read section on its object; the updater writes a round's touched rows of an object
//           in one write section. The section validates/locks the object itself, so server.cc skips the striped
//           version table (kAppSeqlock = false).
// Interface used by server.cc (Server<Backend>): fits, name, usage, stats, thread_init(tid), create_objects (node 0),
// check_objects (every node), read_slot(k, r, f) (f(const uint8_t *rec) may run more than once and must only
// produce its result); plain: write_slot(k, r, fill) (fill(uint8_t *rec) writes the whole record, whole lines, reads
// nothing); Megalon: write_object(k, c, body) (one write section, body writes whole rows of object (k, c)).
#pragma once

#include <dlfcn.h>
#include <time.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <type_traits>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_objapi.h"  // systems/megalon/shim (shared object-API shim; DESIGN.md §7)

namespace rsys {

class PlainBackend {
 public:
  static constexpr const char *kLayoutTag = "";
  static constexpr bool kAppSeqlock = true;  // MemC3 striped version table in server.cc
  PlainBackend(const cxl::region &r, uint8_t *map, const Params &p) : map_(map), p_(p) {
    base_ = r.swcc.offset;
    end_ = base_ + p.swcc_bytes();
    swcc_end_ = r.swcc.end();
  }
  bool fits(std::string *err) const {
    if (end_ > swcc_end_) {
      *err = "SWcc too small: tables need " + std::to_string(p_.swcc_bytes()) + " B, SWcc ends at " +
             std::to_string(swcc_end_) + " (need end " + std::to_string(end_) + ")";
      return false;
    }
    return true;
  }
  std::string name() const { return "plain"; }
  uint8_t *slot(uint32_t k, uint64_t r) const { return map_ + base_ + (p_.row_base[k] + r) * p_.slot_bytes; }
  void thread_init(int, int = 0) const {}
  void set_time_sample(uint32_t) {}
  void (*coh_fn() const)(mshim::CohSnap *) { return nullptr; }  // no user-level coherence (Popcorn: swmc_acct)
  void (*anchor_fn() const)(mshim::AnchorSnap *) { return nullptr; }
  template <class Par> bool create_objects(std::string *, Par &&) const { return true; }
  bool check_objects(std::string *, uint64_t) const { return true; }
  template <class F> auto read_slot(uint32_t k, uint64_t s, F f) const { return f(static_cast<const uint8_t *>(slot(k, s))); }
  template <class F> void write_slot(uint32_t k, uint64_t s, F fill) const { fill(slot(k, s)); }
  std::string usage() const {
    return "plain swcc_offset=" + std::to_string(base_) + " swcc_used_end=" + std::to_string(end_);
  }
  std::string stats() const { return ""; }

 private:
  uint8_t *map_;
  Params p_;
  uint64_t base_, end_, swcc_end_;
};

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "recsys-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device, joins the run, start barrier).
inline const mshim::Api *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  if (!fn) return *err = path + ": no megalon_object_api", nullptr;
  const mshim::Api *api = fn();
  // v2 (thread_coh) is the minimum for v6 Fig 2; v3 adds thread_anchor (read only when version >= 3)
  if (!api || api->version < 2 || api->version > mshim::kApiVersion)
    return *err = path + ": shim API version " + std::to_string(api ? api->version : 0) + " (need 2.." +
                  std::to_string(mshim::kApiVersion) + ")", nullptr;
  return api;
}

// [va, va + len) must be covered by mappings of `path` (Megalon's mapping of the device at map_va).
inline bool mapped_by(uint64_t va, uint64_t len, const std::string &path, std::string *err) {
  std::ifstream f("/proc/self/maps");
  std::string line;
  uint64_t cur = va;
  while (cur < va + len && std::getline(f, line)) {
    std::istringstream is(line);
    std::string range, perms, off, dev, ino, file;
    is >> range >> perms >> off >> dev >> ino >> file;
    const size_t dash = range.find('-');
    const uint64_t lo = std::stoull(range.substr(0, dash), nullptr, 16), hi = std::stoull(range.substr(dash + 1), nullptr, 16);
    if (lo <= cur && cur < hi) {
      if (file != path) break;
      cur = hi;
    }
  }
  if (cur >= va + len) return true;
  *err = "region is not mapped from " + path + " (Megalon must map the same region config)";
  return false;
}

// Megalon coherence time (MOT1 §3.3: time inside Megalon calls + work re-executed after a failed read_end), per
// thread role. Timing every section would distort the measurement (≈ 150k sections per query), so 1 in `sample`
// sections per thread is timed with the steady clock (all of its calls, and its body if read_end fails); call
// counts are exact. Estimated time = sampled time × sections / sampled sections (per role and kind).
enum Role : int { kRoleMain = 0, kRolePrep = 1, kRoleUpdate = 2, kRoleServe = 3, kRoles = 4 };
inline const char *role_name(int r) {
  static const char *n[] = {"main", "prep", "update", "serve"};
  return n[r];
}
struct alignas(64) MegThr {
  int role = kRoleMain;
  uint32_t tick = 0;
  std::atomic<uint64_t> rsec{0}, rsec_sampled{0}, wsec{0}, wsec_sampled{0}, read_fail{0};
  std::atomic<uint64_t> rs_ns{0}, re_ns{0}, ws_ns{0}, we_ns{0}, reexec_ns{0};  // sampled sections only
};
inline uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

class MegalonBackend {
 public:
  static constexpr const char *kLayoutTag = " backend=megalon";
  static constexpr bool kAppSeqlock = false;  // read/write sections
  // rows_per_object (--mg-rows-per-object, DESIGN.md §7): 0 = one object per table (main configuration, user decision
  // 2026-10-18), 1 = one object per row (restructured best case; the 9819e1180/3ef27d8b6 behaviour), N > 1 = objects of
  // N contiguous rows (the last object of a table holds the rest). Object (k, c) holds rows [c x n_k, ...) of table k
  // contiguously, n_k = N (N > 0) or rows[k] (N = 0); row r is at byte (r mod n_k) x 576 of object (k, r / n_k).
  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const mshim::Api *api, uint64_t rows_per_object)
      : p_(p), api_(api), rpo_opt_(rows_per_object) {
    for (uint32_t k = 0; k < kSparse; k++) {
      const uint64_t n = rpo_opt_ ? std::min(rpo_opt_, p_.rows[k]) : p_.rows[k];
      rpo_.push_back(n);
      nobj_.push_back((p_.rows[k] + n - 1) / n);
      obj_base_.push_back(total_obj_);
      total_obj_ += nobj_.back();
      max_obj_bytes_ = std::max(max_obj_bytes_, n * p_.slot_bytes);
    }
  }
  bool fits(std::string *err) const {
    if (p_.slot_bytes % 64) return *err = "megalon: slot must be whole lines", false;
    for (uint32_t k = 0; k < kSparse; k++)
      if (p_.rows[k] >= (1ull << 40) || nobj_[k] >= (1ull << 40))
        return *err = "megalon: row/chunk index overflows the object id", false;
    return true;
  }
  std::string name() const { return "megalon"; }
  static constexpr uint64_t kBase = 0x5253ull << 48;  // "RS"
  // object id = (table, chunk index): "RS" | k << 40 | c (k < 26, c < 2^40: no collisions). N = 1: c = row, i.e. the
  // key's (table, row) as before; N = 0: c = 0.
  static uint64_t id(uint32_t k, uint64_t c) { return kBase | uint64_t(k) << 40 | c; }
  uint64_t rows_per_object_opt() const { return rpo_opt_; }
  uint64_t objects() const { return total_obj_; }
  uint64_t max_object_bytes() const { return max_obj_bytes_; }
  uint64_t chunk_of(uint32_t k, uint64_t r) const { return r / rpo_[k]; }
  uint64_t row_offset(uint32_t k, uint64_t r) const { return (r % rpo_[k]) * p_.slot_bytes; }
  uint64_t first_row(uint32_t k, uint64_t c) const { return c * rpo_[k]; }
  uint64_t object_rows(uint32_t k, uint64_t c) const { return std::min(rpo_[k], p_.rows[k] - c * rpo_[k]); }
  uint64_t object_bytes(uint32_t k, uint64_t c) const { return object_rows(k, c) * p_.slot_bytes; }
  // global object index (table-major): update-worker ownership is gobj % U (one writer per object). N = 1: = the
  // global row index row_base[k] + r.
  uint64_t gobj(uint32_t k, uint64_t c) const { return obj_base_[k] + c; }
  const std::vector<uint64_t> &obj_base() const { return obj_base_; }
  // tid: Megalon registration id; role: Role (per-thread timing slot)
  void thread_init(int tid, int role = kRoleMain) const {
    api_->reg(tid);
    std::lock_guard<std::mutex> g(thr_mu_);
    thr_.push_back(std::make_unique<MegThr>());
    thr_.back()->role = role;
    me_ = thr_.back().get();
  }
  void set_time_sample(uint32_t n) { sample_ = n; }
  void (*coh_fn() const)(mshim::CohSnap *) { return api_->thread_coh; }  // shim v2 CohSnap
  void (*anchor_fn() const)(mshim::AnchorSnap *) { return api_->version >= 3 ? api_->thread_anchor : nullptr; }

  // Node 0 at prepare: ObjectCreate of every object (no empty records: nothing probes). par(f) runs f(i) on every
  // thread of the server's registered prep pool (NR registrations are never freed, so threads are registered once and
  // reused) and returns when all are done; threads claim batches of global object indices (2^14 rows' worth, at least
  // one object; N = 1: 2^14 objects as before).
  template <class Par> bool create_objects(std::string *err, Par &&par) const {
    std::atomic<bool> ok{true};
    std::atomic<uint64_t> next{0};
    std::string e;
    std::mutex mu;
    const uint64_t batch = rpo_opt_ ? std::max<uint64_t>(1, (1 << 14) / rpo_opt_) : 1;
    par([&](int) {
      for (;;) {
        const uint64_t c = next.fetch_add(batch);
        if (c >= total_obj_ || !ok.load(std::memory_order_relaxed)) return;
        const uint64_t end = std::min(total_obj_, c + batch);
        uint32_t k = 0;
        for (uint64_t g = c; g < end; g++) {
          while (k + 1 < kSparse && obj_base_[k + 1] <= g) k++;
          const uint64_t ch = g - obj_base_[k];
          const int rc = api_->create(id(k, ch), object_bytes(k, ch));
          if (rc != 0) {
            std::lock_guard<std::mutex> l(mu);
            if (ok.exchange(false))
              e = "ObjectCreate(table " + std::to_string(k) + ", chunk " + std::to_string(ch) + ", " +
                  std::to_string(object_bytes(k, ch)) + " B) = " + std::to_string(rc) +
                  " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, MEGALON_REINIT=1)";
            return;
          }
        }
      }
    });
    if (!ok) *err = e;
    return ok;
  }
  // Every node: ObjectLookup of every `stride`-th object plus the last object of each table (size check).
  bool check_objects(std::string *err, uint64_t stride) const {
    auto one = [&](uint32_t k, uint64_t c) {
      size_t got = 0;
      const int rc = api_->lookup(id(k, c), &got);
      if (rc == 0 && got == object_bytes(k, c)) return true;
      *err = "ObjectLookup(table " + std::to_string(k) + ", chunk " + std::to_string(c) + ") = " + std::to_string(rc) +
             " size " + std::to_string(got) + " (want " + std::to_string(object_bytes(k, c)) + ")";
      return false;
    };
    for (uint32_t k = 0; k < kSparse; k++) {
      for (uint64_t c = 0; c < nobj_[k]; c += std::max<uint64_t>(stride, 1))
        if (!one(k, c)) return false;
      if (!one(k, nobj_[k] - 1)) return false;
    }
    return true;
  }
  // One row read = one read section on the containing object: read_start, f(row) (copies the 576 B row), read_end;
  // repeated until read_end accepts (no application seqlock).
  template <class F> auto read_slot(uint32_t k, uint64_t s, F f) const {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    const uint64_t oid = id(k, chunk_of(k, s)), off = row_offset(k, s);
    MegThr *t = me_;
    const bool timed = t && sample_ && ++t->tick % sample_ == 0;
    if (t) t->rsec.fetch_add(1, std::memory_order_relaxed);
    if (timed) t->rsec_sampled.fetch_add(1, std::memory_order_relaxed);
    for (;;) {
      mshim::Obj h;
      const uint64_t a = timed ? mono_ns() : 0;
      const int rc = api_->read_start(oid, &h);
      const uint64_t b = timed ? mono_ns() : 0;
      if (rc != 0) megalon_fatal("ObjectReadStart(" + std::to_string(oid) + ") = " + std::to_string(rc));
      const uint8_t *row = static_cast<const uint8_t *>(h.ptr) + off;
      if constexpr (std::is_void_v<R>) {
        f(row);
        const uint64_t c = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t, a, b, c, ok);
        if (ok) return;
      } else {
        R r = f(row);
        const uint64_t c = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t, a, b, c, ok);
        if (ok) return r;
      }
      if (t) t->read_fail.fetch_add(1, std::memory_order_relaxed);
    }
  }
  // One write section on object (k, c): body(uint8_t *object) writes whole rows (whole lines) at row_offset; write_end
  // flushes the whole object (paper semantics, DESIGN.md §7 D3). Megalon allows one writer per object: the caller owns
  // the object (updater: gobj % U; prepare: the claiming thread).
  template <class F> void write_object(uint32_t k, uint64_t c, F body) const {
    MegThr *t = me_;
    const bool timed = t && sample_ && ++t->tick % sample_ == 0;
    if (t) t->wsec.fetch_add(1, std::memory_order_relaxed);
    if (timed) t->wsec_sampled.fetch_add(1, std::memory_order_relaxed);
    mshim::Obj h;
    const uint64_t a = timed ? mono_ns() : 0;
    const int rc = api_->write_start(id(k, c), &h);
    const uint64_t b = timed ? mono_ns() : 0;
    if (rc != 0) megalon_fatal("ObjectWriteStart = " + std::to_string(rc));
    if (h.size != object_bytes(k, c)) megalon_fatal("object size " + std::to_string(h.size));
    body(h.ptr);
    const uint64_t d = timed ? mono_ns() : 0;
    api_->write_end(&h);
    if (timed) {
      t->ws_ns.fetch_add(b - a, std::memory_order_relaxed);
      t->we_ns.fetch_add(mono_ns() - d, std::memory_order_relaxed);
    }
  }
  std::string usage() const {
    return "megalon objects=" + std::to_string(total_obj_) + " rows_per_object=" + std::to_string(rpo_opt_) +
           (rpo_opt_ == 0 ? " (one per table)" : rpo_opt_ == 1 ? " (one per row)" : " (row chunks)") +
           " max_object_bytes=" + std::to_string(max_obj_bytes_) + " object_bytes=" +
           std::to_string(p_.total_rows * p_.slot_bytes) + " shim=" + api_->info;
  }
  std::string stats() const {
    mshim::Stats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.arena_bytes=" << s.arena_bytes << "\nmegalon.used_bytes=" << s.used_bytes
      << "\nmegalon.created=" << s.created << "\nmegalon.creates=" << s.creates
      << "\nmegalon.read_sections=" << s.read_sections << "\nmegalon.read_retry_notify=" << s.read_retry_notify
      << "\nmegalon.read_retry_incoherent=" << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections
      << "\nmegalon.write_retry=" << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw
      << "\nmegalon.flushes=" << s.flushes << "\nmegalon.flush_bytes=" << s.flush_bytes
      << "\nmegalon.replay_flushes=" << s.replay_flushes << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes
      << "\n";
    // shim v5 (Megalon build >= 80, GetWmetaCounts): coherence-record pool counters = Megalon's teardown "reclaim
    // count / allocate count" (cluster-wide SCR counters: every node reports the same value; never sum over nodes),
    // readable at any time, so they include the background record manager's reclaims (not only the critical path).
    // reclaim_count / allocate_count are cumulative since the SCR was initialised (stats_delta.py: per-step deltas);
    // records_in_use / record_slots / dyn_wmeta are current values (gauges). No keys with an older shim (v2..v4).
    if (api_->version >= 5 && api_->wmeta_counts) {
      mshim::WmetaCounts w{};
      api_->wmeta_counts(&w);
      o << "megalon.pool.reclaim_count=" << w.reclaim_count << "\nmegalon.pool.allocate_count=" << w.allocate_count
        << "\nmegalon.pool.records_in_use=" << w.records_in_use << "\nmegalon.pool.record_slots=" << w.record_slots
        << "\nmegalon.pool.dyn_wmeta=" << w.dyn_wmeta << "\n";
    }
    // per role: exact counts, sampled times and the estimate (sampled × total / sampled), see MegThr
    uint64_t v[kRoles][10] = {};
    {
      std::lock_guard<std::mutex> g(thr_mu_);
      for (auto &t : thr_) {
        uint64_t *x = v[t->role];
        x[0] += t->rsec, x[1] += t->rsec_sampled, x[2] += t->wsec, x[3] += t->wsec_sampled, x[4] += t->read_fail;
        x[5] += t->rs_ns, x[6] += t->re_ns, x[7] += t->ws_ns, x[8] += t->we_ns, x[9] += t->reexec_ns;
      }
    }
    o << "megalon_time.sample=" << sample_ << "\n";
    for (int r = 0; r < kRoles; r++) {
      const uint64_t *x = v[r];
      const double fr = x[1] ? double(x[0]) / double(x[1]) : 0, fw = x[3] ? double(x[2]) / double(x[3]) : 0;
      const std::string p = std::string("megalon_time.") + role_name(r) + ".";
      o << p << "read_sections=" << x[0] << "\n" << p << "read_sampled=" << x[1] << "\n" << p << "write_sections=" << x[2]
        << "\n" << p << "write_sampled=" << x[3] << "\n" << p << "read_fail=" << x[4] << "\n"
        << p << "read_start_ns_sampled=" << x[5] << "\n" << p << "read_end_ns_sampled=" << x[6] << "\n"
        << p << "write_start_ns_sampled=" << x[7] << "\n" << p << "write_end_ns_sampled=" << x[8] << "\n"
        << p << "reexec_ns_sampled=" << x[9] << "\n"
        << p << "est_check_ns=" << uint64_t(fr * double(x[5] + x[6]) + fw * double(x[7])) << "\n"
        << p << "est_flush_ns=" << uint64_t(fw * double(x[8])) << "\n"
        << p << "est_reexec_ns=" << uint64_t(fr * double(x[9])) << "\n";
    }
    return o.str();
  }

 private:
  static void account_read(MegThr *t, uint64_t a, uint64_t b, uint64_t c, bool ok) {
    // read_start = [a, b); body = [b, c); read_end = [c, now). A failed attempt's start + body + end is re-executed
    // work (the caller repeats it); the accepted attempt's start/end are section checks.
    const uint64_t d = mono_ns();
    if (ok) {
      t->rs_ns.fetch_add(b - a, std::memory_order_relaxed);
      t->re_ns.fetch_add(d - c, std::memory_order_relaxed);
    } else {
      t->reexec_ns.fetch_add(d - a, std::memory_order_relaxed);
    }
  }
  Params p_;
  const mshim::Api *api_;
  uint64_t rpo_opt_;
  std::vector<uint64_t> rpo_, nobj_, obj_base_;  // per table: rows per object, objects, global index of object 0
  uint64_t total_obj_ = 0, max_obj_bytes_ = 0;
  uint32_t sample_ = 32;
  mutable std::mutex thr_mu_;
  mutable std::vector<std::unique_ptr<MegThr>> thr_;
  static inline thread_local MegThr *me_ = nullptr;
};

}  // namespace rsys

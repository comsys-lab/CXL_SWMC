// recsys per-operation time split (MOT1 v6 Fig 2, reports/MOT1-v6-redesign-draft.md §3; DESIGN.md §8.1).
// T_o = sum over the threads that worked on operations of type o of (end - start), plain rdtsc (no fences).
// C_o = delta of the thread's coherence accounting over the same intervals:
//   Popcorn  swmc_acct (systems/popcorn_new/include/swmc_acct.h): fault_ns[3] + ipi_ns, kernel TSC clock [measured]
//   Megalon  CohSnap of the shim v2 (systems/megalon/shim/megalon_objapi.h thread_coh): section checks by the ratio
//            estimator check_ns_sampled x read_sections / check_sampled [sampled x N] (contract CXL_SWMC 2015a31f3)
//            + stale/concur/meta/spin/wstart/wflush ns [measured]
//            (switch_rw_ns and reclaim_ns are kept as raw columns only: they are inside write start, §4.1)
// A source that is not available (kernel without build 9, cxl_shm not enabled, v1 shim) contributes zeros; the
// stats say which sources are live (op.coh_src). Workloads call these at operation boundaries only.
#pragma once

#include <x86intrin.h>
#include <time.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>

#include "megalon_objapi.h"
#include "swmc_acct.h"

namespace rsys {

inline uint64_t tsc() { return __rdtsc(); }

// TSC rate (kHz) calibrated once against CLOCK_MONOTONIC over 50 ms.
inline uint64_t tsc_khz() {
  static const uint64_t k = [] {
    auto mono = [] {
      timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
    };
    const uint64_t n0 = mono(), c0 = tsc();
    while (mono() - n0 < 50000000ull) {
    }
    const uint64_t n1 = mono(), c1 = tsc();
    return uint64_t(double(c1 - c0) * 1e6 / double(n1 - n0));
  }();
  return k;
}
inline uint64_t tsc_to_ns(uint64_t cyc) { return uint64_t(double(cyc) * 1e6 / double(tsc_khz())); }

// Fields of one coherence snapshot: Popcorn swmc_acct (10: fault_ns/cnt[3], ipi_ns/cnt, and build 10's
// no-transition faults reserved[0..1] = nontrans_ns/cnt, exported but NOT part of C) then Megalon CohSnap up to
// wflush_bytes (21).
constexpr int kPcF = 10, kMgF = 21, kCohF = kPcF + kMgF;
inline const char *coh_field(int i) {
  static const char *n[kCohF] = {
      "pc.fault_ns.is", "pc.fault_ns.sm", "pc.fault_ns.wp", "pc.fault_cnt.is", "pc.fault_cnt.sm", "pc.fault_cnt.wp",
      "pc.ipi_ns", "pc.ipi_cnt", "pc.nontrans_ns", "pc.nontrans_cnt",
      "mg.read_sections", "mg.write_sections", "mg.check_sample", "mg.check_ns_sampled", "mg.check_sampled",
      "mg.stale_cnt", "mg.stale_ns", "mg.concur_cnt", "mg.concur_ns", "mg.meta_cnt", "mg.meta_ns", "mg.spin_cnt",
      "mg.spin_ns", "mg.wstart_ns", "mg.switch_rw_cnt", "mg.switch_rw_ns", "mg.reclaim_cnt", "mg.reclaim_ns",
      "mg.wflush_cnt", "mg.wflush_ns", "mg.wflush_bytes"};
  return n[i];
}
constexpr int kMgCheckSample = kPcF + 2;  // not additive: the sampling factor N (last value kept)
static_assert(offsetof(mshim::CohSnap, wflush_bytes) == (kMgF - 1) * 8, "CohSnap field order");

// Per-thread source of coherence snapshots. init() on the thread itself (registers its swmc_acct area).
struct ThreadCoh {
  swmc_acct acct{};
  bool pc = false;
  void (*mg)(mshim::CohSnap *) = nullptr;
  void init(void (*megalon_thread_coh)(mshim::CohSnap *)) {
    std::memset(&acct, 0, sizeof(acct));
    pc = swmc_acct_register(&acct) == 0;
    mg = megalon_thread_coh;
  }
  void read(uint64_t *v) const {
    const volatile swmc_acct *a = &acct;
    for (int i = 0; i < 3; i++) v[i] = a->fault_ns[i], v[3 + i] = a->fault_cnt[i];
    v[6] = a->ipi_ns, v[7] = a->ipi_cnt;
    v[8] = a->reserved[0], v[9] = a->reserved[1];  // build 10: nontrans_ns, nontrans_cnt (0 before)
    if (mg) {
      mshim::CohSnap s{};
      mg(&s);
      std::memcpy(v + kPcF, &s, kMgF * 8);
    } else {
      std::memset(v + kPcF, 0, kMgF * 8);
    }
  }
};

// Thread-local interval: begin() at the start of a thread's work on an operation (or a batch of operations), end()
// adds (end - start) and the coherence delta to the accumulator.
struct OpAcc {
  std::atomic<uint64_t> n{0}, t_cyc{0}, f[kCohF];
  std::atomic<uint64_t> check_sample{0};
  OpAcc() {
    for (auto &x : f) x = 0;
  }
  // Megalon section-check estimate (ratio estimator over the accumulated deltas): check_ns_sampled x read_sections /
  // check_sampled
  static uint64_t check_est(const uint64_t *v) {
    return v[kPcF + 4] ? uint64_t(double(v[kPcF + 3]) * double(v[kPcF + 0]) / double(v[kPcF + 4])) : 0;
  }
  // c_ns: Popcorn part + Megalon part (see the file comment)
  static uint64_t c_ns(const uint64_t *v) {
    const uint64_t pc = v[0] + v[1] + v[2] + v[6];
    const uint64_t mg = check_est(v) + v[kPcF + 6] + v[kPcF + 8] + v[kPcF + 10] + v[kPcF + 12] + v[kPcF + 13] +
                        v[kPcF + 19];
    return pc + mg;
  }
  void text(std::ostringstream &o, const std::string &name) const {
    uint64_t v[kCohF];
    for (int i = 0; i < kCohF; i++) v[i] = f[i].load();
    v[kMgCheckSample] = check_sample.load();
    const std::string p = "op." + name + ".";
    o << p << "n=" << n << "\n" << p << "t_ns=" << tsc_to_ns(t_cyc) << "\n" << p << "c_ns=" << c_ns(v) << "\n"
      << p << "pc.c_ns=" << v[0] + v[1] + v[2] + v[6] << "\n"
      << p << "mg.check_est_ns=" << check_est(v) << "\n";
    for (int i = 0; i < kCohF; i++) o << p << coh_field(i) << "=" << v[i] << "\n";
  }
};

struct OpTimer {
  const ThreadCoh *tc;
  uint64_t t0 = 0, v0[kCohF];
  explicit OpTimer(const ThreadCoh *t) : tc(t) {}
  void begin() {
    tc->read(v0);
    t0 = tsc();
  }
  void end(OpAcc *acc, uint64_t ops) {
    const uint64_t t1 = tsc();
    uint64_t v1[kCohF];
    tc->read(v1);
    acc->n.fetch_add(ops, std::memory_order_relaxed);
    acc->t_cyc.fetch_add(t1 - t0, std::memory_order_relaxed);
    for (int i = 0; i < kCohF; i++)
      if (i != kMgCheckSample && v1[i] != v0[i]) acc->f[i].fetch_add(v1[i] - v0[i], std::memory_order_relaxed);
    if (v1[kMgCheckSample]) acc->check_sample.store(v1[kMgCheckSample], std::memory_order_relaxed);
  }
};

// Column tags of the op.* stats (MOT1 v6 §6.3): measured / sampled x N / derived.
inline const char *op_tags() {
  return "op.tags=n:count:measured t_ns:duration:measured(rdtsc) pc.*:measured(kernel;pc.nontrans_*_not_in_c) mg.check_ns_sampled:sampled "
         "mg.check_est_ns:sampledxN(check_ns_sampled*read_sections/check_sampled) mg.*_ns:measured mg.*_cnt:count:measured c_ns:derived(pc.c_ns+mg.check_est_ns+"
         "mg.{stale,concur,meta,spin,wstart,wflush}_ns)\n";
}

}  // namespace rsys

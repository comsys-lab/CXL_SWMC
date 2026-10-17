// Per-operation time split (MOT1 v6 Fig 2, reports/MOT1-v6-redesign-draft.md §3): for every operation a worker thread
// executes, T = its duration (plain rdtsc at both ends, no fences, §0) = server processing from request dispatch to
// response ready, EXCLUDING the reply send and txn reset (same definition in every workload) and C = the coherence-management time the same
// thread accumulated inside it:
//   Popcorn  delta of swmc_acct_coh_ns() (systems/popcorn_new/include/swmc_acct.h; zeros while unsupported)
//   Megalon  delta of the thread's CohSnap (v2 thread_coh) and AnchorSnap (v3 thread_anchor, Megalon >= 75)
//            durations, by the workload's all-HWcc (user decision MOT1 v6 §3.1: C = only work all-HWcc does not do):
//            Formula::kKV   (all-HWcc = Megalon hwcc flavor, which also does the anchor work and the seqlock reads):
//                           (check - rseq) est + stale + concur + meta + spin + (wstart - wseq) + (wflush - wseq_end)
//            Formula::kLMDB (all-HWcc = plain backend, no Megalon):
//                           (check + read_lookup + read_nr) est + stale + concur + meta + spin + wstart + write_lookup
//                           + write_nr + wflush + validation copy est
//            (anchor lookup/NR parts are excluded from check/wstart in >= 74; rseq inside check, wseq inside wstart,
//            wseq_end inside wflush; switch_rw_ns and reclaim_ns are parts of wstart_ns, reported separately);
//            check estimate = ratio estimator check_ns_sampled x read_sections / check_sampled (contract
//            CXL_SWMC 2015a31f3; read sections only), applied to the per-op-type sums: opt.<op>.c_ns at a snapshot uses
//            the cumulative sums; tools/opsplit.py applies it to each step's deltas from the raw meg.* fields;
//            a v1 shim (thread_coh absent) gives zeros and opt.meg_coh=0
//            Megalon >= 76 (lean sampling, CohSnap.reserved[1] bit 1; reports/M2-megalon-port-changes.md §18): every
//            duration is a sum over TIMED sections only, so no part of C is exact per operation any more: read-side
//            parts (check, rseq, read anchor, and the (A)-(D) events stale/concur/meta/spin) x read_sections /
//            check_sampled, write-side parts (wstart, wseq, wflush, wseq_end, write anchor) x write_sections /
//            write_sampled (AnchorSnap.reserved[0]); with MEGALON_COH_EVENTS=always (bit 2) the events are full sums
//            (not scaled) and write_sampled = write_sections. Same formulas as above, applied to the per-op-type sums
//            in Table::text() (meg_lean_c_ns) and per step by tools/opsplit.py. Megalon >= 77 also exports the probe
//            cost (AnchorSnap.reserved[1..2]) and the timed event counts (reserved[3..5]): exported raw
//            (opt.meg_probe_ps_*, meg.anchor.timed_*), NOT subtracted from C (§19 probe rule; decision open).
// opt.<op>.mod_bytes = bytes the application stored in the operations (Fig 3b reference line).
// Aggregated per operation type over the threads of the process; stats text keys opt.* (cumulative; the analysis takes
// per-step deltas from loadgen --stats-op snapshots: workloads/kv/tools/opsplit.py). Shared by workloads/kv and
// workloads/lmdb (header-only; candidate for systems/common).
#pragma once

#include <time.h>
#include <x86intrin.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

#include "megalon_objapi.h"
#include "swmc_acct.h"

namespace opsplit {

inline uint64_t tsc() { return __rdtsc(); }  // plain rdtsc, no fences (MOT1 v6 §0)

// TSC rate from CLOCK_MONOTONIC_RAW over ~100 ms (once per process, before serving)
inline double calibrate_tsc_hz() {
  auto ns = [] {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
  };
  const uint64_t n0 = ns(), c0 = tsc();
  uint64_t n1;
  do n1 = ns(); while (n1 - n0 < 100000000ull);
  const uint64_t c1 = tsc();
  return double(c1 - c0) * 1e9 / double(n1 - n0);
}

// CohSnap fields before reserved[], in declaration order (megalon_objapi.h)
constexpr const char *kMegNames[] = {"read_sections", "write_sections", "check_sample", "check_ns_sampled",
                                     "check_sampled", "stale_cnt",      "stale_ns",     "concur_cnt",
                                     "concur_ns",     "meta_cnt",       "meta_ns",      "spin_cnt",
                                     "spin_ns",       "wstart_ns",      "switch_rw_cnt", "switch_rw_ns",
                                     "reclaim_cnt",   "reclaim_ns",     "wflush_cnt",   "wflush_ns",
                                     "wflush_bytes"};
constexpr int kMeg = sizeof(kMegNames) / sizeof(kMegNames[0]);
static_assert(offsetof(mshim::CohSnap, reserved) == kMeg * 8, "CohSnap layout changed: update kMegNames");
static_assert(offsetof(mshim::CohSnap, check_sample) == 2 * 8 && offsetof(mshim::CohSnap, wflush_bytes) == 20 * 8, "CohSnap");
enum MegIdx { kCheckSample = 2, kCheckNs = 3, kStaleNs = 6, kConcurNs = 8, kMetaNs = 10, kSpinNs = 12, kWstartNs = 13, kWflushNs = 19 };

enum class Formula { kKV, kLMDB };  // Megalon C by the workload's all-HWcc (see the header comment)

// AnchorSnap fields before reserved[], in declaration order (megalon_objapi.h v3)
constexpr const char *kAncNames[] = {"read_sections",   "write_sections", "check_sampled", "read_lookup_ns_sampled",
                                     "read_nr_ns_sampled", "rseq_ns_sampled", "write_lookup_ns", "write_nr_ns",
                                     "wseq_ns",         "wseq_end_ns"};
constexpr int kAnc = sizeof(kAncNames) / sizeof(kAncNames[0]);
static_assert(offsetof(mshim::AnchorSnap, reserved) == kAnc * 8, "AnchorSnap layout changed: update kAncNames");
enum AncIdx { kAReadLookup = 3, kAReadNr = 4, kARseq = 5, kAWriteLookup = 6, kAWriteNr = 7, kAWseq = 8, kAWseqEnd = 9 };
// AnchorSnap.reserved[] (Megalon >= 76: [0] write_sampled; >= 77: [1] probe_ns, [2] probe_ps, [3] timed (A) events,
// [4] timed (B)+(C) events, [5] timed (D) episodes). Accumulated per op type as deltas: [0], [3], [4], [5]
constexpr int kAResWriteSampled = 0, kAResProbePs = 2;
constexpr int kAnr = 4;
constexpr int kAnrRes[kAnr] = {kAResWriteSampled, 3, 4, 5};
constexpr const char *kAnrNames[kAnr] = {"write_sampled", "timed_a", "timed_bc", "timed_d"};
// CohSnap.reserved[1] flags: bit 0 timers on, bit 1 lean sampling (>= 76), bit 2 MEGALON_COH_EVENTS=always (>= 76)
constexpr int kMegFlags = 1;
constexpr uint64_t kFlagLean = 2, kFlagEventsAlways = 4;

enum MegIdx2 { kReadSections = 0, kWriteSections = 1, kCheckSampled = 4 };
constexpr int kTscBackwards = 2;
constexpr int kLookupNsSampled = 7;  // CohSnap.reserved[7] (Megalon >= 74): index-lookup part of the sampled checks; raw  // CohSnap.reserved[2] (Megalon >= 72: intervals clamped because the TSC went backwards)
// exact (every-event) part of Megalon C per operation (d = CohSnap deltas, an = AnchorSnap deltas, zeros below v3);
// the sampled read-section parts are added on sums (ratio estimator), see Table::text()
inline uint64_t meg_exact_ns(const uint64_t *d, const uint64_t *an, Formula f) {
  int64_t c = int64_t(d[kStaleNs] + d[kConcurNs] + d[kMetaNs] + d[kSpinNs]);
  if (f == Formula::kKV)
    c += int64_t(d[kWstartNs]) - int64_t(an[kAWseq]) + int64_t(d[kWflushNs]) - int64_t(an[kAWseqEnd]);
  else
    c += int64_t(d[kWstartNs] + an[kAWriteLookup] + an[kAWriteNr] + d[kWflushNs]);
  return c > 0 ? uint64_t(c) : 0;
}
// sampled read-section ns (before the ratio estimate) in C
inline int64_t meg_sampled_ns(uint64_t check_ns_sampled, const uint64_t *an, Formula f) {
  return f == Formula::kKV ? int64_t(check_ns_sampled) - int64_t(an[kARseq])
                           : int64_t(check_ns_sampled + an[kAReadLookup] + an[kAReadNr]);
}
inline uint64_t meg_check_est_ns(uint64_t check_ns_sampled, uint64_t read_sections, uint64_t check_sampled) {
  return check_sampled ? uint64_t(double(check_ns_sampled) * double(read_sections) / double(check_sampled)) : 0;
}
// Megalon >= 76 (lean): the whole Megalon C of an op type from its sums (m = CohSnap sums, an = AnchorSnap sums,
// write_sampled = AnchorSnap.reserved[0] sum); same terms as meg_exact_ns + meg_sampled_ns, scaled per side
inline uint64_t meg_lean_c_ns(const uint64_t *m, const uint64_t *an, uint64_t write_sampled, bool events_always, Formula f) {
  auto rd = [&](double x) { return m[kCheckSampled] ? x * double(m[kReadSections]) / double(m[kCheckSampled]) : 0.0; };
  auto wr = [&](double x) { return write_sampled ? x * double(m[kWriteSections]) / double(write_sampled) : 0.0; };
  const double ev = double(m[kStaleNs]) + double(m[kConcurNs]) + double(m[kMetaNs]) + double(m[kSpinNs]);
  double c = events_always ? ev : rd(ev);
  if (f == Formula::kKV)
    c += rd(std::max(0.0, double(m[kCheckNs]) - double(an[kARseq]))) +
         wr(double(m[kWstartNs]) - double(an[kAWseq]) + double(m[kWflushNs]) - double(an[kAWseqEnd]));
  else
    c += rd(double(m[kCheckNs]) + double(an[kAReadLookup]) + double(an[kAReadNr])) +
         wr(double(m[kWstartNs]) + double(an[kAWriteLookup]) + double(an[kAWriteNr]) + double(m[kWflushNs]));
  return c > 0 ? uint64_t(c) : 0;
}

// Popcorn fields: fault_ns[3] (I->S, S->M, wp), fault_cnt[3], ipi_ns, ipi_cnt, and reserved[0..1] = nontrans_ns /
// nontrans_cnt (build 10: coherence faults without an MSI transition; exported, NOT part of C; 0 before build 10)
constexpr int kPop = 10;
constexpr const char *kPopNames[kPop] = {"is_ns",  "sm_ns",   "wp_ns",  "is_cnt",      "sm_cnt",
                                         "wp_cnt", "ipi_ns",  "ipi_cnt", "nontrans_ns", "nontrans_cnt"};

enum class Source { kPopcorn, kMegalon };

// Megalon-only application work timed by the workload itself (user decision MOT1 v6 §3.1: C = only work all-HWcc does
// not do). lmdb: the "validation copy" = the 4 KiB page copy inside an accepted Megalon read section into the txn's
// private copy (the plain backend reads pages in place). Thread-local, written by the workload's own code; copies of
// discarded sections are not counted here (they are inside CohSnap's (B)/(C) intervals). Sampled 1 in kVcopySample;
// estimate = ns_sampled x cnt / sampled (ratio estimator). Added to C for --backend megalon.
constexpr uint64_t kVcopySample = 64;
struct VCopy {
  uint64_t ns_sampled = 0, sampled = 0, cnt = 0, tick = 0;
};
inline thread_local VCopy tl_vcopy;
inline uint64_t vcopy_est_ns(uint64_t ns_sampled, uint64_t sampled, uint64_t cnt) {
  return sampled ? uint64_t(double(ns_sampled) * double(cnt) / double(sampled)) : 0;
}

// One operation type's sums (one writer thread per Acc: plain load + store, no locked RMW)
struct alignas(64) Acc {
  std::atomic<uint64_t> ops{0}, t_cyc{0}, t_max_cyc{0}, c_ns{0}, mod_bytes{0}, pop[kPop]{}, meg[kMeg]{}, meg_tsc_back{0},
      vcopy[3]{},  // ns_sampled, sampled, cnt
      meg_lookup{0}, anc[kAnc]{}, anr[kAnr]{};
  static void add(std::atomic<uint64_t> &a, uint64_t d) { a.store(a.load(std::memory_order_relaxed) + d, std::memory_order_relaxed); }
};

// Process-wide: operation names, per-thread Acc arrays, sources. Create before the workers start.
class Table {
 public:
  Table(std::vector<std::string> ops, uint32_t threads, Source src, const mshim::Api *meg, Formula f)
      : ops_(std::move(ops)), threads_(threads), src_(src), f_(f), acc_(new Acc[ops_.size() * threads]) {
    // a v1 table has no thread_coh member, a v2 table no thread_anchor: read each only from its version
    meg_ = (src == Source::kMegalon && meg && meg->version >= 2 && meg->thread_coh) ? meg : nullptr;
    anc_ = meg_ && meg->version >= 3 && meg->thread_anchor;
    tsc_hz_ = calibrate_tsc_hz();
  }
  ~Table() { delete[] acc_; }
  Acc &acc(uint32_t thread, uint32_t op) { return acc_[size_t(thread) * ops_.size() + op]; }
  const mshim::Api *meg() const { return meg_; }
  bool anchor() const { return anc_; }
  Formula formula() const { return f_; }
  Source source() const { return src_; }
  double tsc_hz() const { return tsc_hz_; }
  std::atomic<uint32_t> pop_threads{0}, meg_threads{0};
  std::atomic<uint64_t> check_sample{0}, meg_flags{0}, probe_ps_min{~0ull}, probe_ps_max{0};
  bool lean() const { return meg_flags.load(std::memory_order_relaxed) & kFlagLean; }

  // key=value lines (cumulative). opt.<op>.t_ns / c_ns sum over all threads; components per source.
  std::string text() const {
    std::ostringstream o;
    o << "opt.version=1\nopt.c_source=" << (src_ == Source::kMegalon ? "megalon" : "popcorn")
      << "\nopt.tsc_hz=" << uint64_t(tsc_hz_) << "\nopt.threads=" << threads_ << "\nopt.pop_threads=" << pop_threads.load()
      << "\nopt.meg_coh=" << (meg_ ? 1 : 0) << "\nopt.meg_anchor=" << (anc_ ? 1 : 0)
      << "\nopt.c_formula=" << (f_ == Formula::kKV ? "kv" : "lmdb") << "\nopt.meg_threads=" << meg_threads.load()
      << "\nopt.meg_check_sample=" << check_sample.load() << "\nopt.meg_flags=" << meg_flags.load()
      << "\nopt.meg_lean=" << (meg_flags.load() & kFlagLean ? 1 : 0)
      << "\nopt.meg_events_always=" << (meg_flags.load() & kFlagEventsAlways ? 1 : 0)
      << "\nopt.meg_probe_ps_min=" << (probe_ps_max.load() ? probe_ps_min.load() : 0) << "\nopt.meg_probe_ps_max=" << probe_ps_max.load()
      << "\n";
    for (size_t op = 0; op < ops_.size(); op++) {
      uint64_t ops = 0, cyc = 0, mx = 0, c = 0, mb = 0, tb = 0, lk = 0, vc[3] = {}, pop[kPop] = {}, meg[kMeg] = {}, an[kAnc] = {},
               ar[kAnr] = {};
      for (uint32_t t = 0; t < threads_; t++) {
        const Acc &a = acc_[size_t(t) * ops_.size() + op];
        ops += a.ops.load(std::memory_order_relaxed), cyc += a.t_cyc.load(std::memory_order_relaxed);
        mx = std::max<uint64_t>(mx, a.t_max_cyc.load(std::memory_order_relaxed));
        c += a.c_ns.load(std::memory_order_relaxed), mb += a.mod_bytes.load(std::memory_order_relaxed);
        tb += a.meg_tsc_back.load(std::memory_order_relaxed), lk += a.meg_lookup.load(std::memory_order_relaxed);
        for (int i = 0; i < 3; i++) vc[i] += a.vcopy[i].load(std::memory_order_relaxed);
        for (int i = 0; i < kPop; i++) pop[i] += a.pop[i].load(std::memory_order_relaxed);
        for (int i = 0; i < kMeg; i++) meg[i] += a.meg[i].load(std::memory_order_relaxed);
        for (int i = 0; i < kAnc; i++) an[i] += a.anc[i].load(std::memory_order_relaxed);
        for (int i = 0; i < kAnr; i++) ar[i] += a.anr[i].load(std::memory_order_relaxed);
      }
      if (src_ == Source::kMegalon && meg_ && lean()) {  // >= 76: c holds no Megalon part (Thread::end)
        c += meg_lean_c_ns(meg, an, ar[0], meg_flags.load() & kFlagEventsAlways, f_);
      } else if (src_ == Source::kMegalon && meg_) {
        const int64_t sn = meg_sampled_ns(meg[kCheckNs], an, f_);
        c += meg_check_est_ns(sn > 0 ? uint64_t(sn) : 0, meg[kReadSections], meg[kCheckSampled]);
      }
      if (src_ == Source::kMegalon && f_ == Formula::kLMDB) c += vcopy_est_ns(ns(vc[0]), vc[1], vc[2]);
      const std::string p = "opt." + ops_[op] + ".";
      o << p << "ops=" << ops << "\n" << p << "t_ns=" << ns(cyc) << "\n" << p << "t_max_ns=" << ns(mx) << "\n"
        << p << "c_ns=" << c << "\n" << p << "mod_bytes=" << mb << "\n";
      for (int i = 0; i < kPop; i++) o << p << "pop." << kPopNames[i] << "=" << pop[i] << "\n";
      for (int i = 0; i < kMeg; i++)
        if (i != kCheckSample) o << p << "meg." << kMegNames[i] << "=" << meg[i] << "\n";
      o << p << "meg.tsc_backwards=" << tb << "\n" << p << "meg.vcopy_ns_sampled=" << ns(vc[0]) << "\n" << p
        << "meg.vcopy_sampled=" << vc[1] << "\n" << p << "meg.vcopy_cnt=" << vc[2] << "\n" << p << "meg.lookup_ns_sampled=" << lk << "\n";
      for (int i = 0; i < kAnc; i++) o << p << "meg.anchor." << kAncNames[i] << "=" << an[i] << "\n";
      for (int i = 0; i < kAnr; i++) o << p << "meg.anchor." << kAnrNames[i] << "=" << ar[i] << "\n";
    }
    return o.str();
  }
  uint64_t ns(uint64_t cyc) const { return uint64_t(double(cyc) * 1e9 / tsc_hz_); }
  const std::vector<std::string> &ops() const { return ops_; }

 private:
  std::vector<std::string> ops_;
  uint32_t threads_;
  Source src_;
  Formula f_;
  const mshim::Api *meg_ = nullptr;
  bool anc_ = false;
  Acc *acc_;
  double tsc_hz_ = 0;
};

// Per worker thread. init() on the thread itself (after Megalon reg()); the area lives as long as the Thread object,
// which must outlive the thread's registration (workers never exit before the process).
class Thread {
 public:
  void init(Table *t, uint32_t idx) {
    t_ = t;
    idx_ = idx;
    pop_ok_ = swmc_acct_register(&acct_) == 0;
    if (pop_ok_) t->pop_threads++;
    if (t->meg()) {
      t->meg_threads++;
      mshim::CohSnap s{};
      t->meg()->thread_coh(&s);
      t->check_sample.store(s.check_sample);
      t->meg_flags.fetch_or(s.reserved[kMegFlags]);
      lean_ = s.reserved[kMegFlags] & kFlagLean;
      if (t->anchor()) {  // probe cost of this thread (Megalon >= 77, calibrated at reg(); 0 before)
        mshim::AnchorSnap an{};
        t->meg()->thread_anchor(&an);
        const uint64_t pp = an.reserved[kAResProbePs];
        if (pp) {
          uint64_t v = t->probe_ps_min.load();
          while (pp < v && !t->probe_ps_min.compare_exchange_weak(v, pp)) {}
          v = t->probe_ps_max.load();
          while (pp > v && !t->probe_ps_max.compare_exchange_weak(v, pp)) {}
        }
      }
    }
  }
  void begin() {
    v0_ = tl_vcopy;
    if (pop_ok_) pop_snap(p0_);
    if (t_->meg()) t_->meg()->thread_coh(&m0_);
    if (t_->anchor()) t_->meg()->thread_anchor(&an0_);
    c0_ = tsc();
  }
  // mod_bytes: bytes the application stored in this operation (put/update value; 0 for reads)
  void end(uint32_t op, uint64_t mod_bytes = 0) {
    const uint64_t c1 = tsc();
    Acc &a = t_->acc(idx_, op);
    const uint64_t d = c1 - c0_;
    Acc::add(a.ops, 1);
    Acc::add(a.t_cyc, d);
    if (mod_bytes) Acc::add(a.mod_bytes, mod_bytes);
    if (d > a.t_max_cyc.load(std::memory_order_relaxed)) a.t_max_cyc.store(d, std::memory_order_relaxed);
    uint64_t c = 0;
    if (pop_ok_) {
      uint64_t p1[kPop];
      pop_snap(p1);
      for (int i = 0; i < kPop; i++) Acc::add(a.pop[i], p1[i] - p0_[i]);
      if (t_->source() == Source::kPopcorn) c = (p1[0] - p0_[0]) + (p1[1] - p0_[1]) + (p1[2] - p0_[2]) + (p1[6] - p0_[6]);
    }
    if (t_->meg()) {
      mshim::CohSnap m1;
      t_->meg()->thread_coh(&m1);
      uint64_t da[kAnc] = {};
      if (t_->anchor()) {
        mshim::AnchorSnap a1;
        t_->meg()->thread_anchor(&a1);
        const uint64_t *y0 = reinterpret_cast<const uint64_t *>(&an0_), *y1 = reinterpret_cast<const uint64_t *>(&a1);
        for (int i = 0; i < kAnc; i++) da[i] = y1[i] - y0[i], Acc::add(a.anc[i], da[i]);
        for (int i = 0; i < kAnr; i++) Acc::add(a.anr[i], a1.reserved[kAnrRes[i]] - an0_.reserved[kAnrRes[i]]);
      }
      const uint64_t *x0 = reinterpret_cast<const uint64_t *>(&m0_), *x1 = reinterpret_cast<const uint64_t *>(&m1);
      uint64_t dm[kMeg];
      for (int i = 0; i < kMeg; i++) dm[i] = x1[i] - x0[i];
      for (int i = 0; i < kMeg; i++)
        if (i != kCheckSample) Acc::add(a.meg[i], dm[i]);
      if (!lean_) c = meg_exact_ns(dm, da, t_->formula());  // lean (>= 76): all of C from the sums in Table::text()
      Acc::add(a.meg_tsc_back, m1.reserved[kTscBackwards] - m0_.reserved[kTscBackwards]);
      Acc::add(a.meg_lookup, m1.reserved[kLookupNsSampled] - m0_.reserved[kLookupNsSampled]);  // exported, not used in C
    }
    Acc::add(a.c_ns, c);
    const VCopy &v1 = tl_vcopy;  // cycles; converted at text()
    Acc::add(a.vcopy[0], v1.ns_sampled - v0_.ns_sampled);
    Acc::add(a.vcopy[1], v1.sampled - v0_.sampled);
    Acc::add(a.vcopy[2], v1.cnt - v0_.cnt);
  }

 private:
  // consistent copy (Popcorn build 12 update sequence in reserved[2]; a plain copy on builds 9-11); only the swmc_acct
  // area is used (the per-thread read/write_fault_ns of /proc read 0 unless instr/detail=1 on build >= 11)
  void pop_snap(uint64_t *v) const {
    swmc_acct c;
    swmc_acct_snapshot(&acct_, &c);
    v[0] = c.fault_ns[0], v[1] = c.fault_ns[1], v[2] = c.fault_ns[2];
    v[3] = c.fault_cnt[0], v[4] = c.fault_cnt[1], v[5] = c.fault_cnt[2];
    v[6] = c.ipi_ns, v[7] = c.ipi_cnt;
    v[8] = c.reserved[SWMC_ACCT_NONTRANS_NS], v[9] = c.reserved[SWMC_ACCT_NONTRANS_CNT];
  }
  swmc_acct acct_{};  // aligned(64) by its type
  Table *t_ = nullptr;
  uint32_t idx_ = 0;
  bool pop_ok_ = false, lean_ = false;
  uint64_t c0_ = 0, p0_[kPop] = {};
  mshim::CohSnap m0_{};
  mshim::AnchorSnap an0_{};
  VCopy v0_{};
};

}  // namespace opsplit

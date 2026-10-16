// Per-operation time split (MOT1 v6 Fig 2/3b; reports/MOT1-v6-redesign-draft.md §3, §4.2; DESIGN.md §15).
// An operation (search, update) is a set of sections, each run by one thread. Per section the thread takes plain
// rdtsc at start and end (no fences; T) and reads its own coherence counters at start and end (C):
//   Popcorn  struct swmc_acct registered for the thread (swmc_acct.h, Popcorn build 9; plain loads), or the Host-test
//            fake (VDB_OPCOH_FAKE=1: the server adds deterministic values to the thread's own area), or on older
//            kernels /proc/thread-self/swmc (build 8; an expensive pread, so read only at the section end: the delta
//            since the thread's previous section end, as in DESIGN.md §14; between sections a thread touches no
//            shared memory), else none (zeros).
//   Megalon  mshim::CohSnap of the calling thread (megalon_objapi.h v2 thread_coh; nullptr in a v1 shim or on a
//            Megalon build without it: zeros).
// Deltas are summed per operation (OpAcc) and sent in the response (proto.h OpCoh), and summed per operation type in
// the server's window counters (op.<type>.*).
#pragma once

#include <time.h>
#include <x86intrin.h>

#include <cstdint>
#include <cstring>
#include <string>

#include "../proto.h"
#include "megalon_objapi.h"
#include "qcoh.h"
#include "shm_hnsw.h"
#include "swmc_acct.h"

namespace vdb {

inline uint64_t rdtsc() { return __rdtsc(); }
using CohSnapFn = void (*)(mshim::CohSnap *);
using AnchorSnapFn = void (*)(mshim::AnchorSnap *);
constexpr int kAnWords = int(sizeof(mshim::AnchorSnap) / 8);
inline uint64_t *words(mshim::AnchorSnap &s) { return reinterpret_cast<uint64_t *>(&s); }
inline const uint64_t *words(const mshim::AnchorSnap &s) { return reinterpret_cast<const uint64_t *>(&s); }

// rdtsc rate: ticks over >= 100 ms of CLOCK_MONOTONIC (spin; once at server start). Both clocks are invariant on the
// Host and in the guests (constant_tsc, nonstop_tsc).
inline uint32_t calibrate_tsc_khz(uint64_t ms = 100) {
  const uint64_t m0 = qc_now_ns(), c0 = rdtsc();
  uint64_t m1;
  do m1 = qc_now_ns();
  while (m1 - m0 < ms * 1000000ull);
  const uint64_t c1 = rdtsc();
  return uint32_t((c1 - c0) * 1000000ull / (m1 - m0));
}
inline uint64_t ticks_to_ns(uint64_t ticks, uint32_t khz) {
  return khz ? uint64_t((unsigned __int128)ticks * 1000000u / khz) : 0;
}

constexpr int kSnapWords = int(sizeof(mshim::CohSnap) / 8);
static_assert(sizeof(mshim::CohSnap) % 8 == 0, "CohSnap is u64 words");
inline uint64_t *words(mshim::CohSnap &s) { return reinterpret_cast<uint64_t *>(&s); }
inline const uint64_t *words(const mshim::CohSnap &s) { return reinterpret_cast<const uint64_t *>(&s); }

struct CohVals {  // cumulative values of one thread
  uint64_t pf_ns[3] = {}, pf_cnt[3] = {}, ipi_ns = 0, ipi_cnt = 0, nt_ns = 0, nt_cnt = 0;
  uint64_t vc_cnt = 0, vc_sampled = 0, vc_ticks = 0;  // validation copies (shm_hnsw.h t_vcopy)
  mshim::CohSnap mg{};
  mshim::AnchorSnap an{};
};

// One operation's sums over its sections (ticks, then converted once).
struct OpAcc {
  uint64_t ticks = 0, wait_ticks = 0;  // wait_ticks: search E1 wait (part of ticks)
  uint32_t sections = 0;
  uint64_t pf_ns[3] = {}, pf_cnt[3] = {}, ipi_ns = 0, ipi_cnt = 0, mod_bytes = 0;
  uint64_t nt_ns = 0, nt_cnt = 0;  // Popcorn no-transition faults (swmc_acct reserved[0..1]); not part of C
  uint64_t vc_cnt = 0, vc_sampled = 0, vc_ticks = 0;  // Megalon validation copies (part of C, ratio estimate)
  mshim::CohSnap mg{};  // summed deltas; check_sample = the snapshot's value (not a delta)
  mshim::AnchorSnap an{};  // summed deltas (shim v3)
  void add(const OpAcc &d) {
    ticks += d.ticks, wait_ticks += d.wait_ticks, sections += d.sections, nt_ns += d.nt_ns, nt_cnt += d.nt_cnt,
    vc_cnt += d.vc_cnt, vc_sampled += d.vc_sampled, vc_ticks += d.vc_ticks, ipi_ns += d.ipi_ns, ipi_cnt += d.ipi_cnt, mod_bytes += d.mod_bytes;
    for (int i = 0; i < 3; i++) pf_ns[i] += d.pf_ns[i], pf_cnt[i] += d.pf_cnt[i];
    const uint64_t cs = mg.check_sample ? mg.check_sample : d.mg.check_sample;
    for (int k = 0; k < kSnapWords; k++) words(mg)[k] += words(d.mg)[k];
    mg.check_sample = cs;
    for (int k = 0; k < kAnWords; k++) words(an)[k] += words(d.an)[k];
  }
};

// Megalon coherence time of a CohSnap delta (ns): section checks estimate + (A) stale copy + (B) concurrent write +
// (C) metadata change + (D) spin (writer lock, NR combiner / replica read-lock waits) + write start (incl. switch_rw,
// reclaim) + write-end flush. Contract (megalon_objapi.h, CXL_SWMC 2015a31f3): the intervals are disjoint; checks =
// ratio estimator check_ns_sampled x read_sections / check_sampled (read sections only; 0 when nothing was sampled).
// Per operation the ratio uses the operation's own counts; step means in opsplit.py use the step's sums.
inline uint64_t mg_check_est_ns(const mshim::CohSnap &d) {
  return d.check_sampled ? uint64_t((unsigned __int128)d.check_ns_sampled * d.read_sections / d.check_sampled) : 0;
}
inline uint64_t mg_coh_ns(const mshim::CohSnap &d) {
  return mg_check_est_ns(d) + d.stale_ns + d.concur_ns + d.meta_ns + d.spin_ns + d.wstart_ns + d.wflush_ns;
}
// Validation-copy estimate of a block (ns): ratio estimator over the block's own counts (0 if nothing sampled).
inline uint64_t vcopy_est_ns(const OpCoh &b) {
  return b.vcopy_sampled ? uint64_t((unsigned __int128)b.vcopy_ns_sampled * b.vcopy_cnt / b.vcopy_sampled) : 0;
}
inline uint64_t pop_coh_ns(const OpAcc &a) { return a.pf_ns[0] + a.pf_ns[1] + a.pf_ns[2] + a.ipi_ns; }

enum PopSrc : int { kPopNone = 0, kPopAcct = 1, kPopFile = 2, kPopFake = 3 };
inline const char *pop_src_name(int s) {
  static const char *const n[] = {"none", "swmc_acct", "swmc_file", "fake"};
  return n[s & 3];
}

// Megalon anchor work that vector DB counts in C (no Megalon in its all-HWcc): read lookup + NR (sampled, ratio
// estimate over the operation's own read sections) + write lookup + NR. rseq / wseq / wseq_end are already inside
// check / wstart / wflush.
inline uint64_t an_coh_ns(const OpCoh &b) {
  const uint64_t rd = b.an_read_lookup_ns_sampled + b.an_read_nr_ns_sampled;
  return (b.mg_check_sampled ? uint64_t((unsigned __int128)rd * b.mg_read_sections / b.mg_check_sampled) : 0) +
         b.an_write_lookup_ns + b.an_write_nr_ns;
}
inline OpCoh op_block(const OpAcc &a, uint16_t op, int pop_src, bool mg_snap, uint32_t tsc_khz, bool an_snap = false) {
  OpCoh b{};
  b.version = kOpCohVersion;
  b.src = uint16_t((pop_src & 3) | (mg_snap ? 4 : 0) | (an_snap ? 8 : 0));
  b.op = op;
  b.sections = uint16_t(a.sections > 0xffff ? 0xffff : a.sections);
  b.tsc_khz = tsc_khz;
  const mshim::CohSnap &m = a.mg;
  b.mg_check_sample = uint32_t(m.check_sample);
  b.t_ns = ticks_to_ns(a.ticks, tsc_khz);
  for (int i = 0; i < 3; i++) b.pf_ns[i] = a.pf_ns[i], b.pf_cnt[i] = uint32_t(a.pf_cnt[i]);
  b.ipi_ns = a.ipi_ns, b.ipi_cnt = uint32_t(a.ipi_cnt);
  b.mg_check_ns_sampled = m.check_ns_sampled, b.mg_check_sampled = uint32_t(m.check_sampled);
  b.mg_read_sections = uint32_t(m.read_sections), b.mg_write_sections = uint32_t(m.write_sections);
  b.mg_stale_cnt = uint32_t(m.stale_cnt), b.mg_concur_cnt = uint32_t(m.concur_cnt), b.mg_meta_cnt = uint32_t(m.meta_cnt);
  b.mg_spin_cnt = uint32_t(m.spin_cnt), b.mg_switch_rw_cnt = uint32_t(m.switch_rw_cnt);
  b.mg_reclaim_cnt = uint32_t(m.reclaim_cnt), b.mg_wflush_cnt = uint32_t(m.wflush_cnt);
  b.mg_stale_ns = m.stale_ns, b.mg_concur_ns = m.concur_ns, b.mg_meta_ns = m.meta_ns, b.mg_spin_ns = m.spin_ns;
  b.mg_wstart_ns = m.wstart_ns, b.mg_switch_rw_ns = m.switch_rw_ns, b.mg_reclaim_ns = m.reclaim_ns;
  b.mg_wflush_ns = m.wflush_ns, b.mg_wflush_bytes = m.wflush_bytes;
  b.mod_bytes = a.mod_bytes;
  b.wait_ns = ticks_to_ns(a.wait_ticks, tsc_khz);
  b.nontrans_ns = a.nt_ns, b.nontrans_cnt = uint32_t(a.nt_cnt);
  b.vcopy_cnt = uint32_t(a.vc_cnt), b.vcopy_sampled = uint32_t(a.vc_sampled);
  b.vcopy_ns_sampled = ticks_to_ns(a.vc_ticks, tsc_khz);
  const mshim::AnchorSnap &n = a.an;
  b.an_read_lookup_ns_sampled = n.read_lookup_ns_sampled, b.an_read_nr_ns_sampled = n.read_nr_ns_sampled;
  b.an_rseq_ns_sampled = n.rseq_ns_sampled, b.an_write_lookup_ns = n.write_lookup_ns, b.an_write_nr_ns = n.write_nr_ns;
  b.an_wseq_ns = n.wseq_ns, b.an_wseq_end_ns = n.wseq_end_ns;
  b.c_ns = pop_coh_ns(a) + mg_coh_ns(m) + vcopy_est_ns(b) + an_coh_ns(b);
  return b;
}

// Per-thread source state (thread_local in the server).
struct alignas(64) OpCohThread {
  swmc_acct acct{};  // registered with the kernel (kPopAcct) or written by the server (kPopFake)
  SwmcReader file;
  bool file_ok = false;
  CohVals last_end;  // kPopFile: values at this thread's previous section end
};

class OpCohSrc {
 public:
  // Main thread, once: pick the Popcorn source (fake if forced; else swmc_acct if the main thread can register; else
  // the build-8 file; else none) and the Megalon snapshot function (nullptr: none).
  void setup(bool on, bool fake, CohSnapFn mg, uint32_t tsc_khz, std::string *why, AnchorSnapFn an = nullptr) {
    on_ = on, mg_ = on ? mg : nullptr, an_ = on ? an : nullptr;
    tsc_khz_ = tsc_khz;
    if (mg_) {  // the main thread is registered with Megalon
      mshim::CohSnap s{};
      mg_(&s);
      mg_sample_ = s.check_sample;
    }
    if (!on) {
      src_ = kPopNone;
      return;
    }
    if (fake) {
      src_ = kPopFake;
    } else if (swmc_acct_register(&thr().acct) == 0) {
      src_ = kPopAcct;
    } else {
      std::string err;
      SwmcReader r;
      if (r.open("/proc/thread-self/swmc", &err)) {
        src_ = kPopFile;
      } else {
        src_ = kPopNone;
        *why = "swmc_acct_register failed; " + err;
      }
    }
  }
  // Every thread that runs sections, once at its start (after Megalon registration). false: registration failed
  // (counted by the caller; the thread then reports zeros for Popcorn).
  bool thread_start() {
    if (!on_) return true;
    OpCohThread &t = thr();
    bool ok = true;
    if (src_ == kPopAcct) ok = swmc_acct_register(&t.acct) == 0;
    if (src_ == kPopFile) {
      std::string err;
      t.file_ok = t.file.open("/proc/thread-self/swmc", &err);
      ok = t.file_ok && read_file(&t.last_end);
    }
    return ok;
  }
  struct Start {
    uint64_t tsc;
    uint64_t mod;
    CohVals v;
  };
  void begin(Start *s) const {
    if (on_) {
      if (src_ == kPopFile) {
        s->v = thr().last_end;
        if (mg_) mg_(&s->v.mg);
        if (an_) an_(&s->v.an);
      } else {
        read(&s->v, false);
      }
    }
    s->mod = t_mod_bytes;
    s->v.vc_cnt = t_vcopy.cnt, s->v.vc_sampled = t_vcopy.sampled, s->v.vc_ticks = t_vcopy.ticks_sampled;
    s->tsc = rdtsc();
  }
  // End of a section begun with s: adds the deltas (and one section) to *a. false: a counter read failed (the
  // Popcorn part of this section is then zero).
  bool end(const Start &s, OpAcc *a) const {
    const uint64_t t1 = rdtsc();
    a->ticks += t1 - s.tsc;
    a->sections += 1;
    a->mod_bytes += t_mod_bytes - s.mod;
    a->vc_cnt += t_vcopy.cnt - s.v.vc_cnt, a->vc_sampled += t_vcopy.sampled - s.v.vc_sampled;
    a->vc_ticks += t_vcopy.ticks_sampled - s.v.vc_ticks;
    if (!on_) return true;
    CohVals e = s.v;
    const bool ok = read(&e, true);
    for (int i = 0; i < 3; i++) a->pf_ns[i] += e.pf_ns[i] - s.v.pf_ns[i], a->pf_cnt[i] += e.pf_cnt[i] - s.v.pf_cnt[i];
    a->ipi_ns += e.ipi_ns - s.v.ipi_ns, a->ipi_cnt += e.ipi_cnt - s.v.ipi_cnt;
    a->nt_ns += e.nt_ns - s.v.nt_ns, a->nt_cnt += e.nt_cnt - s.v.nt_cnt;
    if (mg_) {
      const uint64_t cs = e.mg.check_sample;
      for (int k = 0; k < kSnapWords; k++) words(a->mg)[k] += words(e.mg)[k] - words(s.v.mg)[k];
      a->mg.check_sample = cs;
    }
    if (an_)
      for (int k = 0; k < kAnWords; k++) words(a->an)[k] += words(e.an)[k] - words(s.v.an)[k];
    if (src_ == kPopFile && ok) thr().last_end = e;
    return ok;
  }
  // Host-test fake (kPopFake): the calling thread's coherence counters advance by these values.
  void fake_add(int kind, uint64_t ns, uint64_t ipi_ns, uint64_t nontrans_ns = 0) const {
    if (src_ != kPopFake) return;
    swmc_acct &a = thr().acct;
    a.fault_ns[kind] += ns, a.fault_cnt[kind] += 1;
    if (nontrans_ns) a.reserved[0] += nontrans_ns, a.reserved[1] += 1;
    if (ipi_ns) a.ipi_ns += ipi_ns, a.ipi_cnt += 1;
  }
  bool on() const { return on_; }
  int src() const { return src_; }
  bool mg_snap() const { return mg_ != nullptr; }
  bool an_snap() const { return an_ != nullptr; }
  uint64_t mg_check_sample() const { return mg_sample_; }  // CohSnap.check_sample (read at setup; 0 without CohSnap)
  uint32_t tsc_khz() const { return tsc_khz_; }
  static OpCohThread &thr() {
    thread_local OpCohThread t;
    return t;
  }

 private:
  bool read_file(CohVals *v) const {
    SwmcVals f;
    if (!thr().file.read(&f)) return false;
    v->pf_ns[0] = f.rd_fault_ns, v->pf_ns[1] = f.wr_fault_ns, v->pf_cnt[0] = f.rd_faults, v->pf_cnt[1] = f.wr_faults;
    return true;
  }
  bool read(CohVals *v, bool at_end) const {
    bool ok = true;
    if (src_ == kPopAcct || src_ == kPopFake) {
      const volatile swmc_acct *a = &thr().acct;
      for (int i = 0; i < 3; i++) v->pf_ns[i] = a->fault_ns[i], v->pf_cnt[i] = a->fault_cnt[i];
      v->ipi_ns = a->ipi_ns, v->ipi_cnt = a->ipi_cnt;
      v->nt_ns = a->reserved[0], v->nt_cnt = a->reserved[1];  // build 10 no-transition faults (0 on build 9)
    } else if (src_ == kPopFile && at_end) {
      ok = thr().file_ok && read_file(v);
    }
    if (mg_) mg_(&v->mg);
    if (an_) an_(&v->an);
    return ok;
  }
  bool on_ = false;
  int src_ = kPopNone;
  CohSnapFn mg_ = nullptr;
  AnchorSnapFn an_ = nullptr;
  uint32_t tsc_khz_ = 0;
  uint64_t mg_sample_ = 0;
};

}  // namespace vdb

// Window counters of one operation type: a copy of vectordb server.cc OpWin (workloads/vectordb/server/server.cc,
// keys opt.<op>.*; experiments/analysis/v6_common.py reads them), so the socialgraph stats text uses the same
// per-operation coherence keys as the vector DB. The OpCoh wire block (vectordb proto.h) and OpAcc / OpCohSrc
// (vectordb opcoh.h) are reused unchanged.
#pragma once

#include <atomic>
#include <ostream>
#include <string>

#include "../../vectordb/server/opcoh.h"

namespace sg {
using vdb::OpAcc;
using vdb::OpCoh;

struct OpWin {
  static constexpr int kPop = 10, kMeg = 23, kAn = 11;
  std::atomic<uint64_t> ops{0}, sections{0}, t_ns{0}, c_ns{0}, mod_bytes{0}, wait_ns{0}, pop[kPop]{}, meg[kMeg]{}, an[kAn]{};
  std::atomic<uint64_t> meg_flags{0};  // OR of the blocks' Megalon flag bits as CohSnap.reserved[1] bits 1-2 (not a sum)
  // Megalon >= 77 raw probe data (not in the wire block): AnchorSnap.reserved[3..5] and the probe cost reserved[2]
  std::atomic<uint64_t> timed_a{0}, timed_bc{0}, timed_d{0}, probe_ps_min{0}, probe_ps_max{0};
  void add_raw(const OpAcc &a) {
    timed_a += a.an.reserved[3], timed_bc += a.an.reserved[4], timed_d += a.an.reserved[5];
    if (a.probe_ps_min) {
      uint64_t v = probe_ps_min.load();
      while ((!v || a.probe_ps_min < v) && !probe_ps_min.compare_exchange_weak(v, a.probe_ps_min)) {}
    }
    uint64_t v = probe_ps_max.load();
    while (a.probe_ps_max > v && !probe_ps_max.compare_exchange_weak(v, a.probe_ps_max)) {}
  }
  void add(const OpCoh &b) {
    ops++, sections += b.sections, t_ns += b.t_ns, c_ns += b.c_ns, mod_bytes += b.mod_bytes, wait_ns += b.wait_ns;
    meg_flags.fetch_or((b.src & 16 ? 2u : 0u) | (b.src & 32 ? 4u : 0u));
    const uint64_t p[kPop] = {b.pf_ns[0], b.pf_ns[1], b.pf_ns[2], b.pf_cnt[0], b.pf_cnt[1], b.pf_cnt[2], b.ipi_ns, b.ipi_cnt,
                              b.nontrans_ns, b.nontrans_cnt};
    const uint64_t m[kMeg] = {b.mg_read_sections, b.mg_write_sections, b.mg_check_ns_sampled, b.mg_check_sampled,
                              b.mg_stale_cnt, b.mg_stale_ns, b.mg_concur_cnt, b.mg_concur_ns, b.mg_meta_cnt,
                              b.mg_meta_ns, b.mg_spin_cnt, b.mg_spin_ns, b.mg_wstart_ns, b.mg_switch_rw_cnt,
                              b.mg_switch_rw_ns, b.mg_reclaim_cnt, b.mg_reclaim_ns, b.mg_wflush_cnt, b.mg_wflush_ns,
                              b.mg_wflush_bytes, b.vcopy_ns_sampled, b.vcopy_sampled, b.vcopy_cnt};
    for (int i = 0; i < kPop; i++) pop[i] += p[i];
    for (int i = 0; i < kMeg; i++) meg[i] += m[i];
    const uint64_t x[kAn] = {b.mg_read_sections, b.mg_write_sections, b.mg_check_sampled, b.an_read_lookup_ns_sampled,
                             b.an_read_nr_ns_sampled, b.an_rseq_ns_sampled, b.an_write_lookup_ns, b.an_write_nr_ns,
                             b.an_wseq_ns, b.an_wseq_end_ns, b.mg_write_sampled};
    for (int i = 0; i < kAn; i++) an[i] += x[i];
  }
  void print(std::ostream &o, const char *name) const {
    static const char *const pn[kPop] = {"is_ns", "sm_ns", "wp_ns", "is_cnt", "sm_cnt", "wp_cnt", "ipi_ns", "ipi_cnt",
                                         "nontrans_ns", "nontrans_cnt"};  // nontrans: not part of c_ns
    static const char *const mn[kMeg] = {"read_sections", "write_sections", "check_ns_sampled", "check_sampled",
                                         "stale_cnt", "stale_ns", "concur_cnt", "concur_ns", "meta_cnt", "meta_ns",
                                         "spin_cnt", "spin_ns", "wstart_ns", "switch_rw_cnt", "switch_rw_ns",
                                         "reclaim_cnt", "reclaim_ns", "wflush_cnt", "wflush_ns", "wflush_bytes",
                                         "vcopy_ns_sampled", "vcopy_sampled", "vcopy_cnt"};
    const std::string p = std::string("\nopt.") + name + ".";
    o << p << "ops=" << ops << p << "sections=" << sections << p << "t_ns=" << t_ns << p << "c_ns=" << c_ns << p
      << "mod_bytes=" << mod_bytes << p << "wait_ns=" << wait_ns;
    for (int i = 0; i < kPop; i++) o << p << "pop." << pn[i] << "=" << pop[i];
    for (int i = 0; i < kMeg; i++) o << p << "meg." << mn[i] << "=" << meg[i];
    static const char *const an_n[kAn] = {"read_sections", "write_sections", "check_sampled", "read_lookup_ns_sampled",
                                          "read_nr_ns_sampled", "rseq_ns_sampled", "write_lookup_ns", "write_nr_ns",
                                          "wseq_ns", "wseq_end_ns", "write_sampled"};
    for (int i = 0; i < kAn; i++) o << p << "meg.anchor." << an_n[i] << "=" << an[i];
    o << p << "meg.flags=" << meg_flags;
    o << p << "meg.anchor.timed_a=" << timed_a << p << "meg.anchor.timed_bc=" << timed_bc << p
      << "meg.anchor.timed_d=" << timed_d << p << "meg.anchor.probe_ps_min=" << probe_ps_min << p
      << "meg.anchor.probe_ps_max=" << probe_ps_max;
  }
};

}  // namespace sg

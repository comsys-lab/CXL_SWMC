// Shared object-API shim between workload servers and Megalon (systems/megalon/shim; built by build-shim.sh into
// <out>/lib/libmegalon-objapi.so, linked against libmegalon). A server never links libmegalon: Megalon initialises in a
// static constructor of libmegalon (maps the whole device at region.map_va and waits in a start barrier for every node),
// so it must only run for a Megalon backend. The server dlopen()s this shim only then and calls megalon_object_api().
// Generalised from workloads/vectordb/server/megalon_api.h (same table; vectordb keeps its own copy, libvdb-megalon.so).
#pragma once

#include <cstddef>
#include <cstdint>

namespace mshim {

constexpr uint32_t kApiVersion = 3;  // 2: thread_coh (MOT1 v6 Fig 2/3a); 3: thread_anchor (Megalon build >= 75)

struct Obj {  // mirrors rackobj::ObjectHandle
  uint8_t *ptr;
  size_t size;
  uint64_t id;
  uint64_t token;
};

struct Stats {  // subset of rackobj::ObjectStats (this node unless noted)
  uint64_t arena_bytes, used_bytes, created;  // shared
  uint64_t creates, read_sections, read_retry_notify, read_retry_incoherent;
  uint64_t write_sections, write_retry, switch_rw, flushes, flush_bytes, replay_flushes, replay_flush_bytes;
};

// Per-thread coherence time of the CALLING thread since reg() (MOT1 v6 reports/MOT1-v6-redesign-draft.md §3.1, §4.1).
// Durations in ns (plain rdtsc, no fences, converted with the TSC rate), counts in events. Every event is timed
// except the READ-section checks, which are timed 1 in check_sample (check_ns_sampled = sum over the check_sampled
// sampled read sections; estimate for all read sections = check_ns_sampled * read_sections / check_sampled, the
// ratio estimator — preferred over * check_sample because each thread's first section is always sampled).
// (A) stale copy at read_start, (B) version changed during the read (read_end false), (C) NR metadata notification
// (read_end false), (D) contended waits inside ObjectReadStart/End: seqlock version odd (writer holds it), NR
// combiner-lock waits and NR replica read-lock waits. Exact intervals: reports/M2-megalon-port-changes.md §13.
// Build >= 73: KV Get/Put are counted in the same fields (one Get = one read section, one Put = one write section;
// §14). Build >= 74: check_ns_sampled and wstart_ns exclude the GetAnchor work a Megalon-hwcc all-HWcc also does (index
// lookup and NR anchor sync/replay; Megalon-only flushes inside the anchor stay in), see AnchorSnap (§15, §16).
// Build >= 76 (reserved[1] bit 1 set; §18): counts are exact in every section; EVERY duration (check, stale/concur/
// meta/spin, wstart, switch_rw, reclaim, wflush, KV create ns, AnchorSnap) is a sum over timed sections only: a
// jittered 1 in check_sample of the read sections (check_sampled of them) and, separately, of the write sections
// (AnchorSnap.reserved[0] = write_sampled). Estimates: read-side ns * read_sections / check_sampled; write-side ns *
// write_sections / write_sampled. Unsampled sections read no TSC. With MEGALON_COH_EVENTS=always (reserved[1] bit 2,
// validation only) the read-side event durations (stale, concur, meta, spin) and all write-side durations are timed
// in every section (full sums, do not scale them; write_sampled = write_sections), check and the read anchor split
// stay sampled. Build >= 76 also drops what no v6 figure uses unless MEGALON_COH_DETAIL=1: switch_rw_cnt/ns,
// reclaim_cnt/ns (parts of wstart) and reserved[3..6] stay 0 by default.
struct CohSnap {
  uint64_t read_sections, write_sections;
  uint64_t check_sample, check_ns_sampled, check_sampled;  // READ sections only: start+end work when no retry happens
  uint64_t stale_cnt, stale_ns;                            // (A) incl. the whole-object flush and the restart
  uint64_t concur_cnt, concur_ns;                          // (B) flush + the discarded section body
  uint64_t meta_cnt, meta_ns;                              // (C) discarded section
  uint64_t spin_cnt, spin_ns;                              // (D) contended only
  uint64_t wstart_ns, switch_rw_cnt, switch_rw_ns, reclaim_cnt, reclaim_ns;
  uint64_t wflush_cnt, wflush_ns, wflush_bytes;            // whole-object flush at write_end
  uint64_t reserved[8];  // [0] TSC kHz, [1] bit 0 timers on, bit 1 lean sampling (>= 76), bit 2 events_always (>= 76),
                         // [2] clamped negative intervals (>= 72), [3] KV creates, [4] their ns (inside wstart; >= 76
                         // write-sampled), [5] KV Gets, [6] KV Puts (>= 73), [7] = read_lookup_ns_sampled (>= 74)
};

// v3 (Megalon build >= 75): work of the CALLING thread since reg() that a Megalon-hwcc (FULL_COHERENCE) all-HWcc also
// executes, in ns, so each workload can apply "C = work its all-HWcc does not do". Sampled fields cover the same
// sampled read sections as CohSnap.check_ns_sampled (estimate for all read sections: x * read_sections /
// check_sampled). Build >= 76: the write_* fields are sums over the timed write sections too (estimate x *
// write_sections / write_sampled, write_sampled = reserved[0]). Relation to CohSnap (build >= 74):
//   read_lookup_ns_sampled, read_nr_ns_sampled  are EXCLUDED from check_ns_sampled (add them back if the workload's
//                                               all-HWcc has no Megalon index);
//   rseq_ns_sampled                             is INSIDE check_ns_sampled;
//   write_lookup_ns, write_nr_ns                are EXCLUDED from wstart_ns;
//   wseq_ns                                     is INSIDE wstart_ns;  wseq_end_ns is INSIDE wflush_ns.
// Fields:
//   read_lookup_ns_sampled  index hash lookup (NR dispatch) of the GetAnchors excluded from check: object sections the
//                           first attempt's anchor, KV Get the anchor of every attempt outside (A) incl. (B)/(C) retries
//   read_nr_ns_sampled      the rest of those GetAnchors: NR sync to the log tail, replay, combining, read lock, FFI;
//                           minus Megalon-only flushes inside it and minus (D) waits
//   rseq_ns_sampled         seqlock version reads whose time is in check: RSeqBegin in read_seq_start (minus its (D)
//                           spin) of attempts outside (A), RSeqRetry in read_seq_end of accepted sections
//   write_lookup_ns, write_nr_ns   the same split of the final attempt's GetAnchor of every write section
//   wseq_ns                 lock/version CAS (WSeqBegin, incl. its wait) of the final attempt's write_seq_start
//   wseq_end_ns             unlock/version store (WSeqEnd) in write_seq_end
// read_sections, write_sections, check_sampled are copies of the CohSnap values (same counters).
// Exact intervals: reports/M2-megalon-port-changes.md §16, §18.
struct AnchorSnap {
  uint64_t read_sections, write_sections, check_sampled;
  uint64_t read_lookup_ns_sampled, read_nr_ns_sampled, rseq_ns_sampled;
  uint64_t write_lookup_ns, write_nr_ns, wseq_ns, wseq_end_ns;
  uint64_t reserved[6];  // [0] write_sampled: timed write sections (build >= 76; 0 before); build >= 77: [1] probe_ns,
                         // [2] probe_ps, [3] timed (A) events, [4] timed (B)+(C) events, [5] timed (D) episodes
};
// Probe correction (build >= 77; reports/M2-megalon-port-changes.md §19): every timed interval also measures
// the TSC reads inside it. p = AnchorSnap.reserved[2] / 1000 ns (per-thread median of back-to-back TSC pairs at reg()).
// Subtract p x k from each sum before scaling: per sampled read section (check_sampled): check 7, read_lookup 1,
// read_nr 2, rseq 2; per timed write section (write_sampled): wstart 4, wflush 3, write_lookup 1, write_nr 2, wseq 1,
// wseq_end 1; per timed event: stale 1 x reserved[3], concur+meta 4 x reserved[4], spin 1 x reserved[5].
static_assert(sizeof(CohSnap) == 29 * 8, "CohSnap layout is fixed (v2)");
static_assert(sizeof(AnchorSnap) == 16 * 8, "AnchorSnap layout is fixed (v3)");

struct Api {
  uint32_t version;     // kApiVersion
  const char *info;     // shim build info
  size_t (*node_id)();  // Megalon's node id (config / MEGALON_NODE_ID)
  void (*reg)(int tid);
  void (*unreg)();
  int (*create)(uint64_t id, size_t size);
  int (*lookup)(uint64_t id, size_t *size);
  int (*read_start)(uint64_t id, Obj *h);
  bool (*read_end)(Obj *h);
  int (*write_start)(uint64_t id, Obj *h);
  void (*write_end)(Obj *h);
  void (*stats)(Stats *s);
  void (*thread_coh)(CohSnap *s);  // v2; nullptr in a v1 shim
  void (*thread_anchor)(AnchorSnap *s);  // v3; absent (version < 3) in older shims: check version >= 3 first
};

}  // namespace mshim

extern "C" {
typedef const mshim::Api *(*megalon_object_api_fn)();
}

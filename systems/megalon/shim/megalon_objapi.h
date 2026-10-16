// Shared object-API shim between workload servers and Megalon (systems/megalon/shim; built by build-shim.sh into
// <out>/lib/libmegalon-objapi.so, linked against libmegalon). A server never links libmegalon: Megalon initialises in a
// static constructor of libmegalon (maps the whole device at region.map_va and waits in a start barrier for every node),
// so it must only run for a Megalon backend. The server dlopen()s this shim only then and calls megalon_object_api().
// Generalised from workloads/vectordb/server/megalon_api.h (same table; vectordb keeps its own copy, libvdb-megalon.so).
#pragma once

#include <cstddef>
#include <cstdint>

namespace mshim {

constexpr uint32_t kApiVersion = 2;  // 2: thread_coh (MOT1 v6 Fig 2/3a; contract fixed 2026-10-16)

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
struct CohSnap {
  uint64_t read_sections, write_sections;
  uint64_t check_sample, check_ns_sampled, check_sampled;  // READ sections only: start+end work when no retry happens
  uint64_t stale_cnt, stale_ns;                            // (A) incl. the whole-object flush and the restart
  uint64_t concur_cnt, concur_ns;                          // (B) flush + the discarded section body
  uint64_t meta_cnt, meta_ns;                              // (C) discarded section
  uint64_t spin_cnt, spin_ns;                              // (D) contended only
  uint64_t wstart_ns, switch_rw_cnt, switch_rw_ns, reclaim_cnt, reclaim_ns;
  uint64_t wflush_cnt, wflush_ns, wflush_bytes;            // whole-object flush at write_end
  uint64_t reserved[8];
};

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
};

}  // namespace mshim

extern "C" {
typedef const mshim::Api *(*megalon_object_api_fn)();
}

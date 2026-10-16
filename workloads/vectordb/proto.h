// vectordb request/response payloads (inside experiments/loadgen/frame.h frames). Little-endian, packed.
#pragma once

#include <cstdint>

namespace vdb {

enum Op : uint16_t {
  kOpInsert = 1,  // InsertReq + float vec[dim]            -> WriteResp
  kOpDelete = 2,  // DeleteReq                             -> WriteResp
  kOpSearch = 3,  // SearchReq + float q[dim]              -> SearchResp + uint64 ids[n] + float scores[n]
  kOpUpdate = 4,  // UpdateReq + float vec[dim]            -> WriteResp (w_seq = w_ins)
  kOpStats = 10,  // empty                                 -> text (key=value lines)
};

struct __attribute__((packed)) InsertReq {
  uint32_t w_seq;  // global write order 1..W (trace)
  uint32_t pad;
  uint64_t id;
};

struct __attribute__((packed)) DeleteReq {
  uint32_t w_seq;
  uint32_t pad;
  uint64_t id;
};

// Update = replace one record: delete del_id (w_seq w_del), then insert ins_id (w_seq w_ins = w_del + 1) with the
// vector, applied and published in that order by the node's writer; one request, one response after both (not atomic:
// a search with snapshot w_del sees neither, as specified by the E1 rule).
struct __attribute__((packed)) UpdateReq {
  uint32_t w_del, w_ins;
  uint64_t del_id, ins_id;
};

struct __attribute__((packed)) WriteResp {
  uint32_t w_seq;
  uint32_t p_after;  // watermark P observed after this write's own publication
};

struct __attribute__((packed)) SearchReq {
  uint32_t ref_w;  // E1 snapshot: search sees writes w_seq <= ref_w
  uint16_t k;
  uint16_t flags;
};

struct __attribute__((packed)) SearchResp {
  uint32_t s_used;
  uint16_t n;  // results (<= k)
  uint16_t flags;
  uint32_t wait_us;    // waiting for P >= ref_w
  uint32_t replay_us;  // delete-log replay
  uint32_t search_us;  // all segments, including lock waits
  uint32_t lock_us;    // waiting for segment read locks (part of search_us)
  uint32_t dists;      // distance computations
  uint16_t segs;       // segments searched
  uint16_t pad;
};

// SearchResp.flags bit: an OpCoh block follows ids[n] and scores[n]. Update responses carry it after WriteResp (the
// response length says whether it is there). vdb builds 9 sent the v1 SearchCoh block (layout kept in
// experiments/vectordb/qcoh.py); since vdb build 10 the v2 OpCoh block below, on search and update responses.
constexpr uint16_t kRespCoh = 1;

// Per-operation time split (MOT1 v6 Fig 2/3b; reports/MOT1-v6-redesign-draft.md §3, §4.2; DESIGN.md §15). One block
// per operation (search or update), sums over the operation's sections, each section run by one thread (search:
// the start section = E1 wait + delete-log replay, then one section per segment task, on any search thread; update:
// one section on the writer = delete + publish + insert + publish). Per section: plain rdtsc at start and end (no
// fences), and the thread's coherence counters read at start and end:
//   Popcorn  struct swmc_acct (systems/popcorn_new/include/swmc_acct.h; registered per thread; build 9), or the
//            Host-test fake; earlier kernels: /proc/thread-self/swmc (build 8; read at section end, delta since the
//            thread's previous section end, read/write fault time only, no IPI time).
//   Megalon  mshim::CohSnap of the calling thread (systems/megalon/shim/megalon_objapi.h v2 thread_coh; zeros when
//            the shim has none, e.g. Megalon build 70).
// T covers server processing from the worker's dequeue of the request to the response being ready (search: the start
// section, the segment tasks and the final merge/encode on the finishing thread; update: the writer section); queueing
// before the dequeue and the socket send of the reply are outside T.
// t_ns = sum over sections of (end - start) [measured]; c_ns = pf_ns[0..2] + ipi_ns + mg_check_ns_sampled x
// mg_read_sections / mg_check_sampled (ratio estimator, 0 if nothing sampled) + vcopy_ns_sampled x vcopy_cnt /
// vcopy_sampled (Megalon validation copies, same estimator; user decision 2026-10-16) + mg_stale_ns + mg_concur_ns + mg_meta_ns + mg_spin_ns + mg_wstart_ns + mg_wflush_ns [derived;
// only one system's part is non-zero in practice]. mod_bytes (updates): bytes of the whole lines the application
// stores in SWcc (vector record, zeroed link blocks, committed link blocks, delete-log entry) [measured].
struct __attribute__((packed)) OpCoh {
  uint16_t version;   // kOpCohVersion
  uint16_t src;       // bits 0-1 Popcorn source: 0 none, 1 swmc_acct, 2 /proc/thread-self/swmc, 3 fake; bit 2 Megalon
                      // CohSnap present (shim v2 with thread_coh)
  uint16_t op;        // kOpSearch | kOpUpdate
  uint16_t sections;  // sections summed
  uint32_t tsc_khz;   // rdtsc rate used for t_ns (server start calibration)
  uint32_t mg_check_sample;  // CohSnap.check_sample (0: no CohSnap)
  uint64_t t_ns, c_ns;
  uint64_t pf_ns[3];  // Popcorn coherence-fault time: [0] I->S, [1] S->M, [2] write-protect upgrade (file source:
                      // read faults in [0], write faults in [1])
  uint32_t pf_cnt[3];
  uint32_t ipi_cnt;
  uint64_t ipi_ns;    // TLB-shootdown IPI handling on the thread's CPU
  uint64_t mg_check_ns_sampled;  // section checks, sampled sections only (estimate: x mg_read_sections / mg_check_sampled)
  uint32_t mg_check_sampled, mg_read_sections, mg_write_sections, mg_stale_cnt, mg_concur_cnt, mg_meta_cnt,
      mg_spin_cnt, mg_switch_rw_cnt, mg_reclaim_cnt, mg_wflush_cnt;
  uint64_t mg_stale_ns, mg_concur_ns, mg_meta_ns, mg_spin_ns, mg_wstart_ns, mg_switch_rw_ns, mg_reclaim_ns,
      mg_wflush_ns, mg_wflush_bytes;
  uint64_t mod_bytes;
  uint64_t wait_ns;   // search: E1 wait (polling P >= ref_w) inside the start section, part of t_ns [measured]
  uint64_t nontrans_ns;   // Popcorn coherence faults without an MSI transition (swmc_acct reserved[0], build 10);
  uint32_t nontrans_cnt;  // reserved[1]; NOT part of c_ns [measured]
  uint32_t vcopy_cnt;     // Megalon validation copies into per-attempt scratch (every copy) [measured]
  uint64_t vcopy_ns_sampled;  // sum over the sampled copies (1 in kVcopySample, rdtsc) [sampled]
  uint32_t vcopy_sampled, pad2;
};
constexpr uint16_t kOpCohVersion = 2;
static_assert(sizeof(OpCoh) == 248, "OpCoh wire size (experiments/vectordb/opsplit.py)");

}  // namespace vdb

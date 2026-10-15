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

// SearchResp.flags bit: a SearchCoh block follows ids[n] and scores[n] (servers since vdb build 9). Clients that do not
// know the block ignore the trailing bytes.
constexpr uint16_t kRespCoh = 1;

// Per-query coherence time (server/qcoh.h, DESIGN.md §14): sums over the query's sections on the search threads.
// Thread time, summed over the query's sections (segment tasks run in parallel on several threads).
// coh_ns = pf_fault_ns + mg_check_est_ns + mg_reexec_est_ns (only one system's part is non-zero in practice):
//   page MSI: managed-fault handler time of the query's sections (/proc/thread-self/swmc deltas)
//   Megalon:  mg_check_est_ns = max(0, rd_start + rd_end - 2 clock_ns x rd_sampled) x kSample (sampled read
//             sections, timer overhead subtracted); mg_reexec_est_ns = rd_retries x mean failed attempt (this
//             query's timed failed attempts minus clock_ns each; none timed: its mean sampled section minus 3 clock_ns)
struct __attribute__((packed)) SearchCoh {
  uint16_t version;  // kSearchCohVersion
  uint16_t source;   // page MSI counter source: 0 none (no swmc file), 1 swmc, 2 fake (Host tests only)
  uint32_t sections; // sections attributed (start + one per segment task)
  uint64_t coh_ns;
  uint64_t pf_fault_ns, pf_msg_wait_ns, pf_local_wait_ns;
  uint32_t pf_faults, pf_transactions;
  uint64_t mg_rd_sampled, mg_rd_start_ns, mg_rd_body_ns, mg_rd_end_ns, mg_rd_retries, mg_rd_failed_timed,
      mg_rd_failed_ns;          // raw (uncalibrated) sampled sums of the query's read sections
  uint32_t clock_ns;            // timer-read overhead per timed interval (server start calibration)
  uint32_t mg_sample;           // Megalon read-section sampling factor (0: not Megalon)
  uint64_t mg_check_est_ns, mg_reexec_est_ns;
  uint64_t busy_ns;             // thread time of the query's sections (start + segment tasks, incl. lock waits);
                                // segment tasks run in parallel, so busy_ns (and coh_ns) can exceed the latency
};
constexpr uint16_t kSearchCohVersion = 1;
static_assert(sizeof(SearchCoh) == 136, "SearchCoh wire size");

}  // namespace vdb

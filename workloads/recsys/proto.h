// recsys request/response payloads (inside experiments/loadgen/frame.h frames). Little-endian, packed.
// A sample is the MLPerf DLRMv2 multi-hot record (v6, DESIGN.md §3): 13 dense features (fp32) and the 214 multi-hot
// ids of the 26 sparse features in table order (MLPerf sizes 3,2,1,2,6,...; ids over the uncapped MLPerf rows; the
// server applies only the table cap, id mod rows). Real data: MLPerf day_23_sparse_multi_hot.npz as is.
#pragma once

#include <cstdint>

namespace rsys {

constexpr uint32_t kDense = 13, kSparse = 26, kMultiHot = 214;  // kMultiHot = sum of the MLPerf multi-hot sizes

struct __attribute__((packed)) Sample {
  float dense[kDense];
  uint32_t ids[kMultiHot];  // feature k: ids[hot_off(k) .. hot_off(k) + mlperf size k)
};
static_assert(sizeof(Sample) == 908, "sample record");

enum Op : uint16_t {
  kOpUpdate = 1,  // UpdateReq + Sample            -> UpdateResp (updater node; samples in time order)
  kOpQuery = 2,   // QueryReq + Sample[pairs]      -> QueryResp + float score[pairs] (serving node)
  kOpStats = 10,  // empty                         -> text (key=value lines)
};

struct __attribute__((packed)) UpdateReq {
  uint64_t seq;  // sample sequence number in the update trace (1..), time order
};

struct __attribute__((packed)) UpdateResp {
  uint64_t seq;
  uint64_t published_seq;  // every row of samples <= published_seq is visible in shared memory (this node)
};

struct __attribute__((packed)) QueryReq {
  uint32_t pairs;  // user-item pairs (samples) in this query
  uint32_t flags;  // kQueryReturnScores: append score[pairs]
};
constexpr uint32_t kQueryReturnScores = 1;

struct __attribute__((packed)) QueryResp {
  uint32_t pairs;
  uint32_t tasks;        // parallel chunks the query was split into
  uint32_t queue_us;     // arrival -> first task started
  uint32_t lookup_us;    // sum over tasks: embedding lookups (incl. coherence retries)
  uint32_t mlp_us;       // sum over tasks: bottom MLP + DCNv2 + top MLP
  uint32_t total_us;     // arrival -> reply
  uint32_t lookups;      // rows read (pairs x 214 for MLPerf sizes)
  uint32_t probes;       // slots inspected by linear probing
  uint32_t seq_retries;  // version-word (seqlock) re-reads (all; false ones in false_retries)
  uint32_t misses;       // ids not found (0 with a fully loaded table)
  uint64_t max_row_seq;  // newest update seq seen in any row read (staleness diagnostics)
  float mean_score;      // mean predicted CTR
  uint32_t false_retries;  // re-reads where the row itself was not rewritten (striped-version false retry)
};

}  // namespace rsys

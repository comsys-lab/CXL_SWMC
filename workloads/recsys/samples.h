// recsys sample files (tools/gen_samples.cc, tools/mlperf_npz_to_samples.py; read by the loadgen plugin).
// Header (128 B) + count records of rsys::Sample (proto.h: 13 fp32 dense features, as preprocessed by MLPerf/torchrec
// (log(x + 3), observed on day 23); 214 multi-hot ids, uncapped; click label). Records are in file order = trace order.
// Version 3 (v7, 912 B records with label); version-2 (v6, 908 B, no label) and version-1 files are rejected.
#pragma once

#include <cstdint>

#include "proto.h"

namespace rsys {

constexpr uint64_t kSamplesMagic = 0x31504d5353595352ull;  // "RSYSSMP1"
constexpr uint32_t kSamplesVersion = 3;

struct __attribute__((packed)) SamplesHeader {
  uint64_t magic;
  uint32_t version;       // kSamplesVersion
  uint32_t record_bytes;  // sizeof(Sample) = 912
  uint64_t count;
  uint64_t seed;          // generator seed (0 for real data)
  char source[96];        // e.g. "synthetic zipf alpha=1.05" or "mlperf dlrmv2 day_23 multi-hot [a, b)"
};
static_assert(sizeof(SamplesHeader) == 128, "samples header");

}  // namespace rsys

// recsys sample files (tools/gen_samples.cc, tools/mlperf_npz_to_samples.py; read by the loadgen plugin).
// Header (128 B) + count records of rsys::Sample (proto.h: 13 fp32 dense features, already log(1+x)-transformed as in
// MLPerf preprocessing; 214 multi-hot ids, uncapped). Records are in file order = trace order (update trace).
// Version 2 (v6, 908 B records); version-1 files (26 one-hot ids, 156 B) are rejected.
#pragma once

#include <cstdint>

#include "proto.h"

namespace rsys {

constexpr uint64_t kSamplesMagic = 0x31504d5353595352ull;  // "RSYSSMP1"
constexpr uint32_t kSamplesVersion = 2;

struct __attribute__((packed)) SamplesHeader {
  uint64_t magic;
  uint32_t version;       // kSamplesVersion
  uint32_t record_bytes;  // sizeof(Sample) = 908
  uint64_t count;
  uint64_t seed;          // generator seed (0 for real data)
  char source[96];        // e.g. "synthetic zipf alpha=1.05" or "mlperf dlrmv2 day_23 multi-hot [a, b)"
};
static_assert(sizeof(SamplesHeader) == 128, "samples header");

}  // namespace rsys

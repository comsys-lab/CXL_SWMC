// recsys sample files (tools/gen_samples.cc, tools/criteo_to_samples.py; read by the loadgen plugin).
// Header (128 B) + count records of rsys::Sample (proto.h: 13 fp32 dense features, already log(1+x)-transformed as in
// MLPerf preprocessing; 26 raw one-hot sparse ids, uncapped). Records are in time order (update trace).
#pragma once

#include <cstdint>

#include "proto.h"

namespace rsys {

constexpr uint64_t kSamplesMagic = 0x31504d5353595352ull;  // "RSYSSMP1"

struct __attribute__((packed)) SamplesHeader {
  uint64_t magic;
  uint32_t version;       // 1
  uint32_t record_bytes;  // sizeof(Sample) = 156
  uint64_t count;
  uint64_t seed;          // generator seed (0 for real data)
  char source[96];        // e.g. "synthetic zipf alpha=1.05" or "criteo-1tb day_23 (mlperf preprocessed)"
};
static_assert(sizeof(SamplesHeader) == 128, "samples header");

}  // namespace rsys

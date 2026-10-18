// rocksdb workload request/response payloads (inside experiments/loadgen/frame.h frames). Records, keys and the YCSB
// request distribution are the lmdb workload's (workloads/lmdb/proto.h: key 24 B, value 1,000 B with a checkable
// header, ScrambledZipfian 0.99), so both workloads load the same records.
// Stored value = 8 B global stamp (HWcc fetch_add per update; 0 = initial image) + the 1,000 B request value.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

#include "../lmdb/proto.h"

namespace rdbw {

using lmdbw::check_value;
using lmdbw::fill_value;
using lmdbw::kKeyBytes;
using lmdbw::kValueBytes;
using lmdbw::make_key;
using lmdbw::parse_key;
using lmdbw::ScrambledZipfian;
using lmdbw::ValHdr;

enum Op : uint16_t {
  kOpGet = 1,      // GetReq + key[klen]                  -> GetResp + value[vlen]   (status kStatusNotFound)
  kOpUpdate = 2,   // UpdateReq + key[klen] + value[vlen] -> UpdateResp              (overwrite; no existence check)
  kOpStats = 10,   // empty -> text (key=value lines, cumulative counters)
  kOpVerify = 11,  // empty -> text: scan of this node's DB (verify.*)
};
constexpr uint16_t kStatusNotFound = 5;

struct __attribute__((packed)) GetReq {
  uint16_t klen;
  uint16_t pad0;
  uint32_t pad1;
};
struct __attribute__((packed)) GetResp {
  uint64_t stamp;       // global stamp of the value returned (0 = initial image)
  uint32_t vlen;
  uint32_t service_us;  // dequeue -> reply
};
struct __attribute__((packed)) UpdateReq {
  uint16_t klen;
  uint16_t pad0;
  uint32_t vlen;
};
struct __attribute__((packed)) UpdateResp {
  uint64_t stamp;  // the stamp this update got (its position in the global order)
  uint32_t pad;
  uint32_t service_us;
};

constexpr uint32_t kStampBytes = 8;
inline uint64_t value_stamp(const char *v) {
  uint64_t s;
  std::memcpy(&s, v, kStampBytes);
  return s;
}
inline std::string make_stored(uint64_t stamp, const void *v, uint32_t len) {
  std::string s(kStampBytes + len, '\0');
  std::memcpy(&s[0], &stamp, kStampBytes);
  std::memcpy(&s[kStampBytes], v, len);
  return s;
}

}  // namespace rdbw

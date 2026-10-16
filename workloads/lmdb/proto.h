// lmdb workload request/response payloads (inside experiments/loadgen/frame.h frames), records, keys and the
// YCSB request distribution. Little-endian, packed. Shared by the server, the loadgen plugin and the tools.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>

namespace lmdbw {

enum Op : uint16_t {
  kOpGet = 1,     // GetReq + key[klen]                      -> GetResp + value[vlen]   (status kStatusNotFound)
  kOpUpdate = 2,  // UpdateReq + key[klen] + value[vlen]     -> UpdateResp               (status kStatusNotFound if
                  //                                             the key did not exist; nothing is written then)
  kOpStats = 10,  // empty                                   -> text (key=value lines, cumulative counters)
  kOpVerify = 11, // empty                                   -> text: full scan of the latest snapshot (verify.*)
};
constexpr uint16_t kStatusNotFound = 5;

struct __attribute__((packed)) GetReq {
  uint16_t klen;
  uint16_t pad0;
  uint32_t pad1;
};
struct __attribute__((packed)) GetResp {
  uint64_t txnid;      // snapshot the get read
  uint32_t vlen;
  uint32_t service_us; // dequeue -> reply
};
struct __attribute__((packed)) UpdateReq {
  uint16_t klen;
  uint16_t pad0;
  uint32_t vlen;
};
struct __attribute__((packed)) UpdateResp {
  uint64_t txnid;       // the committing write txn
  uint32_t lock_us;     // waiting for the cross-node writer lock
  uint32_t service_us;  // dequeue -> reply (incl. lock wait and commit)
};

// ---- records (YCSB defaults: key 24 B, value 1,000 B)
constexpr uint32_t kKeyBytes = 24;
constexpr uint32_t kValueBytes = 1000;

// key i = "user" + 20 decimal digits (YCSB insertorder=ordered key naming; sorted by i, so MDB_APPEND loads in i order)
inline void make_key(uint64_t i, char out[kKeyBytes]) {
  char b[32];
  std::snprintf(b, sizeof(b), "user%020llu", (unsigned long long)i);
  std::memcpy(out, b, kKeyBytes);
}
inline bool parse_key(const void *k, uint32_t len, uint64_t *i) {
  const char *c = static_cast<const char *>(k);
  if (len != kKeyBytes || std::memcmp(c, "user", 4) != 0) return false;
  uint64_t v = 0;
  for (uint32_t x = 4; x < kKeyBytes; x++) {
    if (c[x] < '0' || c[x] > '9') return false;
    v = v * 10 + uint64_t(c[x] - '0');
  }
  *i = v;
  return true;
}

// value = header + deterministic filler from (key, version, writer); a torn or misplaced value fails check_value.
struct __attribute__((packed)) ValHdr {
  uint64_t key;
  uint64_t version;  // 0 = initial image; updates: loadgen's global update sequence
  uint32_t writer;   // 0xffff initial image; updates: target node
  uint32_t magic;
};
constexpr uint32_t kValMagic = 0x4c4d4442u;  // "LMDB"
inline uint64_t splitmix(uint64_t &s) {
  uint64_t z = (s += 0x9e3779b97f4a7c15ull);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
  return z ^ (z >> 31);
}
inline void fill_value(uint64_t key, uint64_t version, uint32_t writer, uint8_t *v, uint32_t len = kValueBytes) {
  ValHdr h{key, version, writer, kValMagic};
  std::memcpy(v, &h, sizeof(h));
  uint64_t s = key * 0x100000001b3ull ^ version * 0x9e3779b97f4a7c15ull ^ writer;
  for (uint32_t o = sizeof(h); o < len; o += 8) {
    uint64_t r = splitmix(s);
    std::memcpy(v + o, &r, std::min<uint32_t>(8, len - o));
  }
}
// true if v is a complete value written for `key` (any version); *hdr receives the header
inline bool check_value(uint64_t key, const uint8_t *v, uint32_t len, ValHdr *hdr) {
  if (len != kValueBytes) return false;
  std::memcpy(hdr, v, sizeof(*hdr));
  if (hdr->magic != kValMagic || hdr->key != key) return false;
  uint8_t ref[kValueBytes];
  fill_value(key, hdr->version, hdr->writer, ref, len);
  return std::memcmp(ref, v, len) == 0;
}

// ---- YCSB request distribution: ScrambledZipfianGenerator (core workload requestdistribution=zipfian):
// Zipfian(theta 0.99) over 10^10 items with YCSB's precomputed zeta, then FNV-1a-64 of the rank mod record count.
class ScrambledZipfian {
 public:
  explicit ScrambledZipfian(uint64_t records) : n_(records) {
    const double theta = kTheta;
    zeta2_ = 1.0 + std::pow(0.5, theta);
    alpha_ = 1.0 / (1.0 - theta);
    eta_ = (1.0 - std::pow(2.0 / double(kItems), 1.0 - theta)) / (1.0 - zeta2_ / kZetan);
  }
  template <class R> uint64_t next(R &rng) {
    const double u = std::uniform_real_distribution<double>(0.0, 1.0)(rng);
    const double uz = u * kZetan;
    uint64_t r;
    if (uz < 1.0) r = 0;
    else if (uz < 1.0 + std::pow(0.5, kTheta)) r = 1;
    else r = uint64_t(double(kItems) * std::pow(eta_ * u - eta_ + 1.0, alpha_));
    return fnv64(r) % n_;
  }
  static uint64_t fnv64(uint64_t val) {  // YCSB Utils.fnvhash64 (incl. Math.abs on the signed result)
    int64_t h = int64_t(0xcbf29ce484222325ull);
    for (int i = 0; i < 8; i++) {
      h ^= int64_t(val & 0xff);
      val >>= 8;
      h = int64_t(uint64_t(h) * 1099511628211ull);
    }
    return h < 0 ? uint64_t(-(h + 1)) + 1 : uint64_t(h);
  }
  static constexpr double kTheta = 0.99;
  static constexpr uint64_t kItems = 10000000000ull;   // ScrambledZipfianGenerator.ITEM_COUNT
  static constexpr double kZetan = 26.46902820178302;  // ScrambledZipfianGenerator.ZETAN

 private:
  uint64_t n_;
  double zeta2_, alpha_, eta_;
};

}  // namespace lmdbw

// KV store request/response payloads (inside experiments/loadgen/frame.h frames) and the self-checking value format,
// shared by kv-server (workloads/kv/server) and the loadgen plugin (workloads/kv/loadgen). Little-endian, packed.
//
// One request carries n >= 1 operations of one kind (n = plugin option batch, default 1):
//   kOpGet   GetReq + uint64 keys[n]                         -> GetResp + n x kValueBytes (missing key: zeros)
//   kOpPut   PutReq + n x (uint64 key + kValueBytes value)   -> PutResp
//   kOpMixed MixedReq + uint64 ops[n] + one kValueBytes value per put op, in op order
//                                                            -> MixedResp + one kValueBytes value per get op, in op order
//            ops[i] = key | kPutBit for a put, key for a get (the plugin draws each op's kind with put_ratio)
//   kOpStats empty                                           -> text (key=value lines)
// Put = in-place rewrite of an existing key (the server loads every key 0..keys-1 before serving).
#pragma once

#include <cstdint>
#include <cstring>

namespace kv {

enum Op : uint16_t {
  kOpGet = 1,
  kOpPut = 2,
  kOpMixed = 3,
  kOpStats = 10,
};

constexpr uint32_t kValueBytes = 1024;  // Megalon SLOT_SIZE (artifact default); one value = one slot
constexpr uint32_t kValueWords = kValueBytes / 8;
constexpr uint32_t kMaxBatch = 64;

struct __attribute__((packed)) GetReq {
  uint16_t n;
  uint16_t flags;
  uint32_t pad;
};

struct __attribute__((packed)) PutReq {
  uint16_t n;
  uint16_t flags;
  uint32_t pad;
};

constexpr uint64_t kPutBit = 1ull << 63;

struct __attribute__((packed)) MixedReq {
  uint16_t n;
  uint16_t flags;
  uint32_t pad;
};

struct __attribute__((packed)) MixedResp {
  uint16_t n;
  uint16_t misses;
  uint32_t svc_ns;
  uint16_t gets, puts;
  uint32_t pad;
};

struct __attribute__((packed)) GetResp {
  uint16_t n;
  uint16_t misses;  // keys the store did not find (value bytes zero)
  uint32_t svc_ns;  // server time from dequeue to reply (all n operations)
};

struct __attribute__((packed)) PutResp {
  uint16_t n;
  uint16_t pad;
  uint32_t svc_ns;
};

// ---- self-checking values (same construction as the artifact's kv-store FillValue/CheckValue) ----
// word 0 = key, word 1 = stamp = writer << 56 | version, words 2.. = mix64(key ^ stamp ^ (i << 48)).
// version: per-key put count made by the request generator (0 = the server's initial load); writer: index of the node
// the put was sent to (target order = node order), kPreloadWriter for the initial load.
constexpr uint64_t kPreloadWriter = 0xff;
constexpr uint64_t kVersionMask = (1ull << 56) - 1;

inline uint64_t stamp(uint64_t writer, uint64_t version) { return (writer << 56) | (version & kVersionMask); }
inline uint64_t stamp_writer(uint64_t s) { return s >> 56; }
inline uint64_t stamp_version(uint64_t s) { return s & kVersionMask; }

inline uint64_t mix64(uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  x *= 0xc4ceb9fe1a85ec53ULL;
  x ^= x >> 33;
  return x;
}

inline void fill_value(uint8_t *buf, uint64_t key, uint64_t st) {
  uint64_t w[kValueWords];
  w[0] = key;
  w[1] = st;
  for (uint64_t i = 2; i < kValueWords; i++) w[i] = mix64(key ^ st ^ (i << 48));
  std::memcpy(buf, w, kValueBytes);
}

// true: a complete value written for `key` (any stamp); the stamp is returned in *st
inline bool check_value(const uint8_t *buf, uint64_t key, uint64_t *st) {
  uint64_t w[kValueWords];
  std::memcpy(w, buf, kValueBytes);
  *st = w[1];
  if (w[0] != key) return false;
  for (uint64_t i = 2; i < kValueWords; i++)
    if (w[i] != mix64(key ^ w[1] ^ (i << 48))) return false;
  return true;
}

// ---- trace logs (kv-server --trace-dir; MOT1 H2 Figure 2c KV classification) ----
// node<k>.kv-puts.bin / node<k>.kv-gets.bin: TraceRec records; node<k>.kv-trace.txt describes them.
// slot = device offset of the key's value / 1024, page = device offset / 4096 (offsets from the start of the device,
// i.e. of the region mapping at map_va); the slot of a key is fixed after the initial load (in-place rewrites).
struct __attribute__((packed)) TraceRec {
  uint64_t t_real_ns;  // CLOCK_REALTIME at the end of the operation (cross-node join)
  uint64_t t_mono_ns;  // CLOCK_MONOTONIC (same instant; joins with this guest's kernel traces)
  uint64_t key;
  uint64_t stamp;      // put: the value's stamp; get: the stamp read
  uint32_t slot;
  uint32_t page;
  uint32_t tid;        // kernel thread id of the worker
  uint32_t dur_ns;     // operation time (library call only)
};
static_assert(sizeof(TraceRec) == 48, "trace record is 48 bytes");

}  // namespace kv

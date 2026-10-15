// Workload control state in the HW-coherent range (docs/hwcc-contract.md). Header-only, no deps beyond cxl_region.h.
//
// Not an allocator: a workload computes its fixed layout once from the run parameters (field order, sizes,
// 64 B alignment), sets $CXL_APP_HWCC_BYTES to layout.bytes() for every node, and places fields at the computed
// offsets inside region.app. Nothing is allocated or freed while the run is live.
//
//   cxl::hwcc::layout L;                      // starts after the app header
//   uint64_t off_p   = L.add("P", 8);
//   uint64_t off_bmp = L.add("applied", W / 8);
//   ...                                       // same calls, same order, on every node
//   L.bytes()  -> value for CXL_APP_HWCC_BYTES (the harness computes it with the same function)
//   uint8_t *base = cxl::hwcc::app_base(region, map);   // map = start of the whole-device mapping
//   cxl::hwcc::app_init(base, L, run_id, nr_nodes, node_id, timeout_ms, &err)   // node 0 zeroes + publishes
#pragma once

#include <immintrin.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>

#include "cxl_region.h"

namespace cxl::hwcc {

// ---- shared words: aligned <= 8 B atomics with explicit ordering only (GCC builtins; usable from C++17) ----
template <class T> inline T load_acquire(const T *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
template <class T> inline T load_relaxed(const T *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
template <class T> inline void store_release(T *p, T v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
template <class T> inline void store_relaxed(T *p, T v) { __atomic_store_n(p, v, __ATOMIC_RELAXED); }
template <class T> inline T fetch_add(T *p, T v) { return __atomic_fetch_add(p, v, __ATOMIC_ACQ_REL); }
template <class T> inline T fetch_or(T *p, T v) { return __atomic_fetch_or(p, v, __ATOMIC_ACQ_REL); }
template <class T> inline bool cas(T *p, T *expected, T desired) {
  return __atomic_compare_exchange_n(p, expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

// Cross-VM waiting is polling only: a futex wakes threads of one kernel, never another VM's.
// Spins with pause, then yields; returns false on timeout (timeout_ms 0 = no limit).
template <class Pred> inline bool poll_until(Pred pred, uint64_t timeout_ms) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  for (uint32_t i = 0;; i++) {
    if (pred()) return true;
    if (i < 1024) { _mm_pause(); continue; }
    if (timeout_ms && (i & 1023) == 0 && std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::yield();
  }
}

// ---- header at the start of region.app ----
constexpr uint64_t kMagic = 0x4357434341505031ull;  // "CWCCAPP1"
constexpr uint32_t kVersion = 1;
constexpr uint32_t kStateInit = 0, kStateReady = 1;
constexpr uint32_t kMaxNodes = 64;

struct alignas(64) header {
  uint64_t magic;
  uint32_t version;
  uint32_t nr_nodes;
  uint64_t layout_hash;  // field names, sizes and alignments, in order
  uint64_t bytes;        // layout.bytes() as computed by node 0
  uint64_t run_id;       // written before state turns READY
  uint32_t state;        // kStateInit / kStateReady (release by node 0)
  uint32_t pad0;
  uint8_t pad1[64 - 48];
  uint64_t joined[kMaxNodes];  // joined[k] = run_id once node k validated the layout; one line per 8 nodes
};
static_assert(offsetof(header, joined) == 64 && sizeof(header) % 64 == 0, "header must be whole cache lines");

// Deterministic sequential packing; every node must make the same add() calls in the same order.
class layout {
 public:
  layout() : end_(sizeof(header)) { mix("hwcc_app v1"); }
  // Returns the field's offset from the app base. align: power of two >= 8; default one cache line, so fields
  // written by different nodes never share a line.
  uint64_t add(const char *name, uint64_t bytes, uint64_t align = 64) {
    end_ = (end_ + align - 1) / align * align;
    uint64_t off = end_;
    end_ += bytes;
    mix(name);
    mix(std::to_string(bytes) + "@" + std::to_string(align));
    return off;
  }
  uint64_t bytes() const { return (end_ + 4095) / 4096 * 4096; }  // what CXL_APP_HWCC_BYTES must be (at least)
  uint64_t used() const { return end_; }
  uint64_t hash() const { return h_; }

 private:
  void mix(const std::string &s) {  // FNV-1a
    for (unsigned char c : s) { h_ ^= c; h_ *= 0x100000001b3ull; }
    h_ ^= 0xff; h_ *= 0x100000001b3ull;
  }
  uint64_t end_;
  uint64_t h_ = 0xcbf29ce484222325ull;
};

inline uint8_t *app_base(const region &r, uint8_t *map) { return map + r.app.offset; }

// Node 0 zeroes the app range and publishes READY for run_id; every other node waits for READY with its own
// run_id (polling), checks magic/version/hash/size/nr_nodes, then marks itself joined. Callers refuse to run on
// false. The region's app.size must be >= L.bytes() (checked here).
inline bool app_init(const region &r, uint8_t *map, const layout &L, uint64_t run_id, uint32_t nr_nodes,
                     uint32_t node_id, uint64_t timeout_ms, std::string *err) {
  if (run_id == 0 || nr_nodes == 0 || nr_nodes > kMaxNodes || node_id >= nr_nodes) {
    *err = "hwcc_app: bad run_id/nr_nodes/node_id";
    return false;
  }
  if (r.app.size < L.bytes()) {
    *err = "hwcc_app: app range " + std::to_string(r.app.size) + " B < layout " + std::to_string(L.bytes()) +
           " B (set CXL_APP_HWCC_BYTES to the layout size on every node)";
    return false;
  }
  auto *h = reinterpret_cast<header *>(app_base(r, map));
  if (node_id == 0) {
    store_release(&h->state, kStateInit);
    std::memset(reinterpret_cast<uint8_t *>(h) + 64, 0, r.app.size - 64);  // fields and joined[]
    h->magic = kMagic;
    h->version = kVersion;
    h->nr_nodes = nr_nodes;
    h->layout_hash = L.hash();
    h->bytes = L.bytes();
    store_release(&h->run_id, run_id);  // after INIT: a joiner that sees this run_id can no longer see an old READY
    store_release(&h->state, kStateReady);
  } else if (!poll_until([&] { return load_acquire(&h->run_id) == run_id && load_acquire(&h->state) == kStateReady; },
                         timeout_ms)) {
    *err = "hwcc_app: node 0 did not publish READY for this run_id in time";
    return false;
  }
  if (h->magic != kMagic || h->version != kVersion || h->nr_nodes != nr_nodes || h->layout_hash != L.hash() ||
      h->bytes != L.bytes()) {
    *err = "hwcc_app: layout mismatch with node 0 (same binary, parameters and nr_nodes required)";
    return false;
  }
  store_release(&h->joined[node_id], run_id);
  return true;
}

// Wait until all nr_nodes nodes joined this run (e.g. before node 0 starts serving).
inline bool app_wait_all_joined(const region &r, uint8_t *map, uint64_t run_id, uint64_t timeout_ms) {
  auto *h = reinterpret_cast<header *>(app_base(r, map));
  return poll_until(
      [&] {
        for (uint32_t k = 0; k < h->nr_nodes; k++)
          if (load_acquire(&h->joined[k]) != run_id) return false;
        return true;
      },
      timeout_ms);
}

}  // namespace cxl::hwcc

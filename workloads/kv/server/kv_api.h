// KV adapter between kv-server and Megalon's artifact KV store (rackobj::Put/Get, systems/megalon/src/include/rackobj.h).
// Built per Megalon build into <out>/lib/libkv-megalon.so (kv_shim.cc, linked against that build's libmegalon.so):
// builds/kv/<n> against a hwcc-flavor build (--backend plain = the artifact's all-HWcc flavor, FULL_COHERENCE) and
// builds/kv-megalon/<n> against a megalon-flavor build (--backend megalon). kv-server dlopen()s it: libmegalon
// initialises in a static constructor (maps the whole device at region.map_va, node 0 MEGALON_REINIT=1, waits in its
// start barrier for every node).
// The shared object shim (systems/megalon/shim/megalon_objapi.h) has no Put/Get, so the KV store has its own table.
#pragma once

#include <sys/types.h>

#include <cstddef>
#include <cstdint>

namespace kvshim {

constexpr uint32_t kApiVersion = 1;

struct Api {
  uint32_t version;    // kApiVersion
  const char *info;    // shim build info (Megalon build id / flavor / wmeta layout)
  const char *flavor;  // "hwcc" or "megalon" (from the Megalon build manifest)
  size_t (*node_id)();
  size_t (*key_space)();
  void (*reg)(int tid);
  void (*unreg)();
  ssize_t (*put)(const uint8_t *buf, uint64_t count, uint64_t key);  // artifact: returns 0 (even when out of slots)
  ssize_t (*get)(uint8_t *buf, uint64_t count, uint64_t key);        // bytes read; 0 = no entry
};

}  // namespace kvshim

extern "C" {
typedef const kvshim::Api *(*kv_megalon_api_fn)();
}

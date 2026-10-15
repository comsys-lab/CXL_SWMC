// Shared object-API shim between workload servers and Megalon (systems/megalon/shim; built by build-shim.sh into
// <out>/lib/libmegalon-objapi.so, linked against libmegalon). A server never links libmegalon: Megalon initialises in a
// static constructor of libmegalon (maps the whole device at region.map_va and waits in a start barrier for every node),
// so it must only run for a Megalon backend. The server dlopen()s this shim only then and calls megalon_object_api().
// Generalised from workloads/vectordb/server/megalon_api.h (same table; vectordb keeps its own copy, libvdb-megalon.so).
#pragma once

#include <cstddef>
#include <cstdint>

namespace mshim {

constexpr uint32_t kApiVersion = 1;

struct Obj {  // mirrors rackobj::ObjectHandle
  uint8_t *ptr;
  size_t size;
  uint64_t id;
  uint64_t token;
};

struct Stats {  // subset of rackobj::ObjectStats (this node unless noted)
  uint64_t arena_bytes, used_bytes, created;  // shared
  uint64_t creates, read_sections, read_retry_notify, read_retry_incoherent;
  uint64_t write_sections, write_retry, switch_rw, flushes, flush_bytes, replay_flushes, replay_flush_bytes;
};

struct Api {
  uint32_t version;     // kApiVersion
  const char *info;     // shim build info
  size_t (*node_id)();  // Megalon's node id (config / MEGALON_NODE_ID)
  void (*reg)(int tid);
  void (*unreg)();
  int (*create)(uint64_t id, size_t size);
  int (*lookup)(uint64_t id, size_t *size);
  int (*read_start)(uint64_t id, Obj *h);
  bool (*read_end)(Obj *h);
  int (*write_start)(uint64_t id, Obj *h);
  void (*write_end)(Obj *h);
  void (*stats)(Stats *s);
};

}  // namespace mshim

extern "C" {
typedef const mshim::Api *(*megalon_object_api_fn)();
}

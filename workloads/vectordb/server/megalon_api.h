// C-style function table between vdb-server and libvdb-megalon.so (megalon_shim.cc), DESIGN.md §12.
// The server never links libmegalon: Megalon initialises in a static constructor of libmegalon (maps the whole device
// at region.map_va and waits in a start barrier for every node), so it must only run for --backend megalon. The
// server dlopen()s the shim (which links libmegalon) only then; the plain backend never loads it.
#pragma once

#include <cstddef>
#include <cstdint>

namespace vdb {

constexpr uint32_t kMegalonApiVersion = 1;

struct MegObj {  // mirrors rackobj::ObjectHandle
  uint8_t *ptr;
  size_t size;
  uint64_t id;
  uint64_t token;
};

struct MegStats {  // subset of rackobj::ObjectStats (this node unless noted)
  uint64_t arena_bytes, used_bytes, created;  // shared
  uint64_t creates, read_sections, read_retry_notify, read_retry_incoherent;
  uint64_t write_sections, write_retry, switch_rw, flushes, flush_bytes, replay_flushes, replay_flush_bytes;
};

struct MegalonApi {
  uint32_t version;     // kMegalonApiVersion
  const char *info;     // shim build info
  size_t (*node_id)();  // Megalon's node id (config / MEGALON_NODE_ID)
  void (*reg)(int tid);
  void (*unreg)();
  int (*create)(uint64_t id, size_t size);
  int (*lookup)(uint64_t id, size_t *size);
  int (*read_start)(uint64_t id, MegObj *h);
  bool (*read_end)(MegObj *h);
  int (*write_start)(uint64_t id, MegObj *h);
  void (*write_end)(MegObj *h);
  void (*stats)(MegStats *s);
};

}  // namespace vdb

extern "C" {
typedef const vdb::MegalonApi *(*vdb_megalon_api_fn)();
}

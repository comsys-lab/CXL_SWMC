// libvdb-megalon.so: thin adapter from megalon_api.h to Megalon's object API (systems/megalon/src/include/rackobj.h).
// Loading it loads libmegalon, whose static constructor initialises Megalon (DESIGN.md §12). No logic here.
#include <rackobj.h>

#include "megalon_api.h"

namespace {

vdb::MegObj out(const rackobj::ObjectHandle &h) { return vdb::MegObj{h.ptr, h.size, h.id, h.token}; }
rackobj::ObjectHandle in(const vdb::MegObj *o) {
  rackobj::ObjectHandle h;
  h.ptr = o->ptr;
  h.size = o->size;
  h.id = o->id;
  h.token = o->token;
  return h;
}

size_t node_id() { return rackobj::GetConfigSize_t("node_id"); }
void reg(int tid) { rackobj::Register(tid); }
void unreg() { rackobj::UnRegister(); }
int create(uint64_t id, size_t size) { return rackobj::ObjectCreate(id, size); }
int lookup(uint64_t id, size_t *size) { return rackobj::ObjectLookup(id, size); }
int read_start(uint64_t id, vdb::MegObj *o) {
  rackobj::ObjectHandle h;
  int rc = rackobj::ObjectReadStart(id, &h);
  *o = out(h);
  return rc;
}
bool read_end(vdb::MegObj *o) {
  rackobj::ObjectHandle h = in(o);
  return rackobj::ObjectReadEnd(&h);
}
int write_start(uint64_t id, vdb::MegObj *o) {
  rackobj::ObjectHandle h;
  int rc = rackobj::ObjectWriteStart(id, &h);
  *o = out(h);
  return rc;
}
void write_end(vdb::MegObj *o) {
  rackobj::ObjectHandle h = in(o);
  rackobj::ObjectWriteEnd(&h);
}
void stats(vdb::MegStats *s) {
  rackobj::ObjectStats t{};
  rackobj::GetObjectStats(&t);
  *s = vdb::MegStats{t.arena_bytes,    t.used_bytes,        t.created,
                     t.creates,        t.read_sections,     t.read_retry_notify,
                     t.read_retry_incoherent, t.write_sections, t.write_retry,
                     t.switch_rw,      t.flushes,           t.flush_bytes,
                     t.replay_flushes, t.replay_flush_bytes};
}

#ifndef VDB_SHIM_INFO
#define VDB_SHIM_INFO "unknown"
#endif

const vdb::MegalonApi kApi{vdb::kMegalonApiVersion, VDB_SHIM_INFO, node_id, reg, unreg, create, lookup,
                           read_start, read_end, write_start, write_end, stats};

}  // namespace

extern "C" __attribute__((visibility("default"))) const vdb::MegalonApi *vdb_megalon_api() { return &kApi; }

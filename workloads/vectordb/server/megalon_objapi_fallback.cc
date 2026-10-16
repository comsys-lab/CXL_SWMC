// Fallback object-API shim for Megalon builds without per-thread coherence accounting (build <= 70: libmegalon has no
// rackobj::GetObjectThreadCoh). Same table and symbol as systems/megalon/shim/megalon_objapi.cc (API version 2) with
// thread_coh = nullptr (API version 2, no thread_anchor): vdb-server then reports zeros for Megalon's coherence time (DESIGN.md §15). Compiled by
// build-megalon.sh against the rackobj.h of the Megalon build's own source commit (git show), never the working tree.
// No logic here.
#include <rackobj.h>

#include "megalon_objapi.h"

namespace {

mshim::Obj out(const rackobj::ObjectHandle &h) { return mshim::Obj{h.ptr, h.size, h.id, h.token}; }
rackobj::ObjectHandle in(const mshim::Obj *o) {
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
int read_start(uint64_t id, mshim::Obj *o) {
  rackobj::ObjectHandle h;
  int rc = rackobj::ObjectReadStart(id, &h);
  *o = out(h);
  return rc;
}
bool read_end(mshim::Obj *o) {
  rackobj::ObjectHandle h = in(o);
  return rackobj::ObjectReadEnd(&h);
}
int write_start(uint64_t id, mshim::Obj *o) {
  rackobj::ObjectHandle h;
  int rc = rackobj::ObjectWriteStart(id, &h);
  *o = out(h);
  return rc;
}
void write_end(mshim::Obj *o) {
  rackobj::ObjectHandle h = in(o);
  rackobj::ObjectWriteEnd(&h);
}
void stats(mshim::Stats *s) {
  rackobj::ObjectStats t{};
  rackobj::GetObjectStats(&t);
  *s = mshim::Stats{t.arena_bytes,    t.used_bytes,        t.created,
                    t.creates,        t.read_sections,     t.read_retry_notify,
                    t.read_retry_incoherent, t.write_sections, t.write_retry,
                    t.switch_rw,      t.flushes,           t.flush_bytes,
                    t.replay_flushes, t.replay_flush_bytes};
}

#ifndef MSHIM_INFO
#define MSHIM_INFO "unknown"
#endif

const mshim::Api kApi{2, MSHIM_INFO, node_id, reg, unreg, create, lookup,
                      read_start, read_end, write_start, write_end, stats, nullptr, nullptr};

}  // namespace

extern "C" __attribute__((visibility("default"))) const mshim::Api *megalon_object_api() { return &kApi; }

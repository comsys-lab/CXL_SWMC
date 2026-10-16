// libmegalon-objapi.so: thin adapter from megalon_objapi.h to Megalon's object API (src/include/rackobj.h). Loading it
// loads libmegalon, whose static constructor initialises Megalon. No logic here.
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

// v2 (build 71): the calling thread's coherence time; rackobj::ObjectThreadCoh has CohSnap's field order
void thread_coh(mshim::CohSnap *s) {
  static_assert(sizeof(mshim::CohSnap) == sizeof(rackobj::ObjectThreadCoh), "CohSnap != ObjectThreadCoh");
  rackobj::ObjectThreadCoh t{};
  rackobj::GetObjectThreadCoh(&t);
  *s = mshim::CohSnap{};
  s->read_sections = t.read_sections;
  s->write_sections = t.write_sections;
  s->check_sample = t.check_sample;
  s->check_ns_sampled = t.check_ns_sampled;
  s->check_sampled = t.check_sampled;
  s->stale_cnt = t.stale_cnt;
  s->stale_ns = t.stale_ns;
  s->concur_cnt = t.concur_cnt;
  s->concur_ns = t.concur_ns;
  s->meta_cnt = t.meta_cnt;
  s->meta_ns = t.meta_ns;
  s->spin_cnt = t.spin_cnt;
  s->spin_ns = t.spin_ns;
  s->wstart_ns = t.wstart_ns;
  s->switch_rw_cnt = t.switch_rw_cnt;
  s->switch_rw_ns = t.switch_rw_ns;
  s->reclaim_cnt = t.reclaim_cnt;
  s->reclaim_ns = t.reclaim_ns;
  s->wflush_cnt = t.wflush_cnt;
  s->wflush_ns = t.wflush_ns;
  s->wflush_bytes = t.wflush_bytes;
  for (size_t i = 0; i < 8; i++) s->reserved[i] = t.reserved[i];
}

#ifndef MSHIM_INFO
#define MSHIM_INFO "unknown"
#endif

const mshim::Api kApi{mshim::kApiVersion, MSHIM_INFO, node_id, reg, unreg, create, lookup,
                      read_start, read_end, write_start, write_end, stats, thread_coh};

}  // namespace

extern "C" __attribute__((visibility("default"))) const mshim::Api *megalon_object_api() { return &kApi; }

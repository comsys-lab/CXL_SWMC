// Megalon backend (DESIGN.md §12): the SWcc data are Megalon objects (paper §4; systems/megalon/src/include/rackobj.h)
// at deterministic ids, one object per indexing unit: per segment s and group g a vector chunk and a link chunk, per
// node u the delete log in chunks of dlog_chunk entries. Every access is one object section, as the paper prescribes:
//   read:  do { ObjectReadStart; read the bytes in place into per-attempt local state } while (!ObjectReadEnd)
//   write: ObjectWriteStart; write whole cache lines (never read prior contents, D3); ObjectWriteEnd (Megalon
//          flushes the whole object)
// An update of part of an object (an HNSW link block) reads it in a read section, then writes the whole block (whole
// lines) in a write section. Sections never nest; no create inside a section. Node 0 creates every object at prepare;
// every node checks every object's size by lookup. The device is mapped by Megalon (whole device at region.map_va);
// the server uses that mapping for the HWcc app range and never maps the device itself.
// Object API: the shared shim systems/megalon/shim (libmegalon-objapi.so, megalon_objapi.h; since vdb build 10;
// earlier builds used this directory's megalon_api.h / libvdb-megalon.so, still used by workloads/lmdb).
#pragma once

#include <dlfcn.h>
#include <time.h>
#include <x86intrin.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "cxl_region.h"
#include "hwcc_app.h"
#include "layout.h"
#include "megalon_objapi.h"
#include "shm_hnsw.h"

namespace vdb {

using MegObj = mshim::Obj;
using MegStats = mshim::Stats;
using MegalonApi = mshim::Api;

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "vdb-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device, joins the run, start barrier). Accepts API
// version 1 (no thread_coh) and 2 (thread_coh, may be nullptr when the Megalon build has no per-thread accounting).
inline const MegalonApi *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    *err = std::string("dlopen ") + path + ": " + dlerror();
    return nullptr;
  }
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  if (!fn) {
    *err = path + ": no megalon_object_api (vdb builds >= 10 need the shared shim systems/megalon/shim)";
    return nullptr;
  }
  const MegalonApi *api = fn();
  if (!api || api->version < 1 || api->version > mshim::kApiVersion) {
    *err = path + ": API version mismatch";
    return nullptr;
  }
  return api;
}
// thread_coh of a loaded API (nullptr for a v1 table, whose struct has no such field).
inline void (*megalon_thread_coh(const MegalonApi *api))(mshim::CohSnap *) {
  return api && api->version >= 2 ? api->thread_coh : nullptr;
}

// [va, va + len) must be covered by mappings of `path` (Megalon's mapping of the device at map_va).
inline bool mapped_by(uint64_t va, uint64_t len, const std::string &path, std::string *err) {
  std::ifstream f("/proc/self/maps");
  std::string line;
  uint64_t cur = va;
  while (cur < va + len && std::getline(f, line)) {
    std::istringstream is(line);
    std::string range, perms, off, dev, ino, file;
    is >> range >> perms >> off >> dev >> ino >> file;
    const size_t dash = range.find('-');
    const uint64_t lo = std::stoull(range.substr(0, dash), nullptr, 16), hi = std::stoull(range.substr(dash + 1), nullptr, 16);
    if (lo <= cur && cur < hi) {
      if (file != path) break;
      cur = hi;
    }
  }
  if (cur >= va + len) return true;
  std::ostringstream o;
  o << "region [0x" << std::hex << va << ", 0x" << va + len << ") is not mapped from " << path << " (stops at 0x" << cur
    << "); Megalon must map the same region config";
  *err = o.str();
  return false;
}

class MegalonBackend;
class MegalonAcc;

// Measurement (DESIGN.md §13, §16); Megalon itself is unchanged.
// Wrapper timers (window counters megt.*): 1 in kSample read sections (random per section) timed (read_start / body /
// read_end); a failed attempt of a timed section is timed in full. Write sections are always timed. Cost per read
// section: one xorshift and a branch; 1 in 64 sections 4 clock_gettime (vDSO); per write section 4 clock_gettime.
// Sharing trace (--trace-dir, MOT1 v6 Fig 3c; dedicated runs only, off by default; DESIGN.md §16): per section one
// TraceRec in the thread's own memory buffer (chunks of kTraceChunk records; no shared writes), dumped at stop:
//   write section: (object, element, units, seq) with seq = global write-section sequence number from the HWcc
//                  counter wsec (fetch-add inside the section, before ObjectWriteEnd);
//   read section:  (object, element, units, seq = wsec loaded after the accepted attempt's ObjectReadStart) and the
//                  event flags of the section: (A) = CohSnap.stale_cnt advanced (stale copy at read_start), (B) = failed
//                  ObjectReadEnd (CohSnap.concur_cnt when thread_coh exists, else the wrapper's own count, which then
//                  also includes (C) metadata failures); ev_ns = CohSnap (stale_ns + concur_ns) of the section.
//   Identical consecutive read records of one thread without flags (same object, element, units, seq) are kept once.
// Trace cost per read section: two thread_coh calls (if any), one HWcc load per attempt, one rdtsc and a 32 B store.
inline uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

// Element of an object section (trace): vector chunk = slot, delete-log chunk = entry, link chunk = slot | level << 24
// (one link block); n = consecutive units from elem (vector/delete log: slots/entries; link: levels of the slot);
// n = 0: the whole object (initial image copy, warm-up).
struct Elem {
  uint32_t elem = 0;
  uint16_t n = 0;
};
inline Elem link_elem(uint64_t slot, int level, uint32_t levels = 1) {
  return Elem{uint32_t(slot) | uint32_t(level) << 24, uint16_t(levels)};
}

struct __attribute__((packed)) TraceRec {  // 32 B (workloads/vectordb/tools/classify_sharing.py)
  uint64_t tsc;    // rdtsc at the end of the section (node-local order)
  uint32_t seq;    // write: global write-section seq (taken before write_end); read: wsec loaded after the accepted
                   // attempt's read_start
  uint32_t obj;    // dense object index (MegalonBackend::obj_index)
  uint32_t elem;   // Elem.elem
  uint16_t n;      // Elem.n
  uint8_t type;    // 1 read, 2 write
  uint8_t flags;   // read: (A) count (bits 0-3, saturating) | (B) count << 4 (saturating)
  uint32_t ev_ns;  // read: CohSnap stale_ns + concur_ns of the section (saturating)
  uint32_t pad;
};
static_assert(sizeof(TraceRec) == 32, "trace record");
struct __attribute__((packed)) TraceFileHdr {  // node<K>.vdbtrace.bin: header, then per thread TraceThreadHdr + records
  char magic[8];   // "VDBTRC1"
  uint32_t node, nr_nodes, segments, threads;
  uint64_t groups, dlog_chunks, per_chunk, dlog_chunk;
  uint64_t wsec_at_dump, tsc_khz, dropped, records;
  uint32_t has_coh, pad;
};
struct __attribute__((packed)) TraceThreadHdr {
  uint32_t index, role;  // role: MegTimers::kRole*
  uint64_t count, dropped;
};
constexpr uint8_t kTraceRead = 1, kTraceWrite = 2;
constexpr size_t kTraceChunk = size_t(1) << 16;  // records per buffer chunk (2 MiB)

struct TraceBuf {
  std::vector<std::unique_ptr<TraceRec[]>> chunks;
  size_t used = 0;  // records in the last chunk
  uint64_t dropped = 0;
  TraceRec last{};
  bool have_last = false;
  uint64_t count() const { return chunks.empty() ? 0 : (chunks.size() - 1) * kTraceChunk + used; }
};

// Wrapper counters, one block per thread (owner-only relaxed load + store: no shared cache-line writes on the read
// path), summed at stats time.
// Each block has the role of its thread (server thread ids: 0 main, 1 writer, >= 2 search; set by thread_init), so
// stats report the search-serving threads and the writer separately (megt.search.*, megt.writer.*, megt.main.*);
// megt.* without a role is the sum over all blocks.
struct alignas(64) MegTimers {
  enum : int { kRdSampled, kRdStartNs, kRdBodyNs, kRdEndNs, kRdRetries, kRdFailedTimed, kRdFailedNs, kWrSections,
               kWrStartNs, kWrBodyNs, kWrEndNs, kN };
  enum : int { kRoleMain, kRoleWriter, kRoleSearch, kRoleOther, kRoles };
  std::atomic<uint64_t> v[kN] = {};
  std::atomic<int> role{kRoleOther};
  TraceBuf tb;  // trace only (owner thread appends; dumped after the run)
  void add(int k, uint64_t d) { v[k].store(v[k].load(std::memory_order_relaxed) + d, std::memory_order_relaxed); }
};

struct MegalonMem {
  GraphMeta *meta;  // HWcc
  const MegalonBackend *be;
  uint32_t seg;
};

class MegalonBackend {
 public:
  using Acc = MegalonAcc;
  static constexpr const char *kLayoutTag = " backend=megalon";

  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const MegalonApi *api)
      : p_(p), api_(api), coh_(megalon_thread_coh(api)) {
    dlog_chunks_ = p.dlog_chunks();
  }
  bool fits(std::string *err) const {
    if (p_.g.vrec_bytes() % 64 || p_.g.links0_bytes() % 64 || p_.g.links_bytes() % 64) {
      *err = "megalon: records and link blocks must be whole cache lines (dim % 16 == 0)";
      return false;
    }
    if (p_.segments >= (1u << 20) || p_.g.groups() >= (1u << 24) || p_.nr_nodes >= (1u << 20) ||
        dlog_chunks_ >= (1u << 24)) {
      *err = "megalon: object id fields overflow";
      return false;
    }
    if (p_.g.per_chunk() >= (1u << 24) || p_.dlog_chunk > 0xffff || p_.trace_objects() >= (1ull << 32)) {
      *err = "megalon: trace element fields overflow";
      return false;
    }
    return true;
  }
  std::string name() const { return "megalon"; }
  // Megalon's per-thread coherence snapshot (shim v2 thread_coh), nullptr if the shim/Megalon build has none.
  void (*thread_coh() const)(mshim::CohSnap *) { return coh_; }

  // ---- object ids (deterministic; < 2^63 as ObjectCreate requires)
  static constexpr uint64_t kBase = 0x5644ull << 48;  // "VD"
  static uint64_t id(uint64_t kind, uint64_t a, uint64_t b) { return kBase | kind << 44 | a << 24 | b; }
  static uint64_t vec_id(uint32_t s, uint64_t g) { return id(1, s, g); }
  static uint64_t link_id(uint32_t s, uint64_t g) { return id(2, s, g); }
  static uint64_t dlog_id(uint32_t node, uint64_t c) { return id(3, node, c); }
  uint64_t chunk_id(Chunk k, uint32_t s, uint64_t g) const { return k == Chunk::kVec ? vec_id(s, g) : link_id(s, g); }

  template <class F> void for_each_object(F f) const {  // f(id, size)
    for (uint32_t s = 0; s < p_.segments; s++)
      for (uint64_t g = 0; g < p_.g.groups(); g++) {
        f(vec_id(s, g), p_.g.vchunk_bytes());
        f(link_id(s, g), p_.g.lchunk_bytes());
      }
    for (uint32_t u = 0; u < p_.nr_nodes; u++)
      for (uint64_t c = 0; c < dlog_chunks_; c++) f(dlog_id(u, c), uint64_t(p_.dlog_chunk) * sizeof(DlogEntry));
  }
  bool create_objects(std::string *err) const {  // node 0, prepare
    bool ok = true;
    for_each_object([&](uint64_t id, uint64_t size) {
      if (!ok) return;
      int rc = api_->create(id, size);
      if (rc != 0) {
        *err = "ObjectCreate(" + hex(id) + ", " + std::to_string(size) + ") = " + std::to_string(rc) +
               " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, run with MEGALON_REINIT=1)";
        ok = false;
      }
    });
    return ok;
  }
  bool check_objects(std::string *err) const {  // every node, after node 0 published its load
    bool ok = true;
    for_each_object([&](uint64_t id, uint64_t size) {
      size_t got = 0;
      int rc = ok ? api_->lookup(id, &got) : 0;
      if (ok && (rc != 0 || got != size)) {
        *err = "ObjectLookup(" + hex(id) + ") = " + std::to_string(rc) + " size " + std::to_string(got) + ", want " +
               std::to_string(size);
        ok = false;
      }
    });
    return ok;
  }

  // ---- sections
  void thread_init(int tid) const {
    api_->reg(tid);
    tm().role.store(tid == 0 ? MegTimers::kRoleMain : tid == 1 ? MegTimers::kRoleWriter : MegTimers::kRoleSearch);
  }
  // Timer-read overhead per timed interval (qcoh.h calibrate_clock_ns, measured once at server start); reported as
  // megt.clock_ns. The counters stay raw; analysis subtracts clock_ns per timed interval.
  void set_clock_ns(uint32_t c) { clock_ns_ = c; }
  // Read section over [off, off + len) of element e: f(const uint8_t *) may run more than once and must only produce
  // its result (per-attempt local state); returns the result of the accepted attempt.
  template <class F> auto read(uint64_t id, uint64_t off, uint64_t len, F f, Elem e = {}) const {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    // random 1/kSample sampling per section (a fixed every-k-th rule could alias with HNSW's regular access pattern)
    thread_local uint64_t rs = 0x9e3779b97f4a7c15ull ^ uint64_t(reinterpret_cast<uintptr_t>(&rs));
    rs ^= rs << 13, rs ^= rs >> 7, rs ^= rs << 17;  // xorshift64
    const bool timed = (rs >> 32 & (kSample - 1)) == 0;
    mshim::CohSnap c0;
    if (wsec_ && coh_) coh_(&c0);
    uint32_t fails = 0;
    uint64_t seq = 0;
    for (;;) {
      MegObj h;
      const uint64_t t0 = timed ? mono_ns() : 0;
      const int rc = api_->read_start(id, &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(" + hex(id) + ") = " + std::to_string(rc));
      if (off + len > h.size) megalon_fatal("read beyond object " + hex(id));
      if (wsec_) seq = cxl::hwcc::load_acquire(wsec_);
      const uint64_t t1 = timed ? mono_ns() : 0;
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(h.ptr + off));
        const uint64_t t2 = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t0, t1, t2, ok);
        if (ok) {
          if (wsec_) trace_read(id, e, seq, fails, c0);
          return;
        }
      } else {
        R r = f(static_cast<const uint8_t *>(h.ptr + off));
        const uint64_t t2 = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t0, t1, t2, ok);
        if (ok) {
          if (wsec_) trace_read(id, e, seq, fails, c0);
          return r;
        }
      }
      fails++;
      tm().add(MegTimers::kRdRetries, 1);
    }
  }
  // Write section of element e; f(base, size) writes whole lines only and reads nothing of the object (D3).
  template <class F> void write_obj(uint64_t id, F f, Elem e = {}) const {
    MegObj h;
    const uint64_t t0 = mono_ns();
    const int rc = api_->write_start(id, &h);
    if (rc != 0) megalon_fatal("ObjectWriteStart(" + hex(id) + ") = " + std::to_string(rc));
    const uint64_t t1 = mono_ns();
    f(h.ptr, h.size);
    // trace: the write's sequence number is taken inside the section (after the body, before ObjectWriteEnd), so a
    // reader whose section is accepted and that loads wsec after its ObjectReadStart has seen every write on the
    // object with seq <= its value and none with a larger one (a write that took its seq before the load but ends
    // after the reader's start overlaps the reader's section, which then fails): each write once (DESIGN.md §16)
    const uint64_t seq = wsec_ ? cxl::hwcc::fetch_add(wsec_, uint64_t(1)) + 1 : 0;
    const uint64_t t2 = mono_ns();
    api_->write_end(&h);
    const uint64_t t3 = mono_ns();
    MegTimers &t = tm();
    t.add(MegTimers::kWrSections, 1), t.add(MegTimers::kWrStartNs, t1 - t0), t.add(MegTimers::kWrBodyNs, t2 - t1);
    t.add(MegTimers::kWrEndNs, t3 - t2);
    if (wsec_) {
      TraceRec r{};
      r.tsc = __rdtsc(), r.seq = uint32_t(seq), r.obj = uint32_t(obj_index(id)), r.elem = e.elem, r.n = e.n;
      r.type = kTraceWrite;
      append(t, r);
    }
  }
  // Write section over [off, off + len), whole lines (len may end at the object end).
  template <class F> void write(uint64_t id, uint64_t off, uint64_t len, F fill, Elem e = {}) const {
    write_obj(
        id,
        [&](uint8_t *base, size_t size) {
          check_lines(id, off, len, size);
          fill(base + off);
        },
        e);
  }
  static void check_lines(uint64_t id, uint64_t off, uint64_t len, size_t size) {
    if (off % 64 || off + len > size || (len % 64 && off + len != size))
      megalon_fatal("write of [" + std::to_string(off) + ", +" + std::to_string(len) + ") in object " + hex(id) +
                    " is not whole lines");
  }

  // ---- backend interface (server.cc)
  MegalonMem mem(uint32_t s, GraphMeta *meta) const { return MegalonMem{meta, this, s}; }
  // whole-chunk accesses (initial image copy, warm-up): element = whole object
  template <class F> void write_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F fill) const {
    write(chunk_id(k, s, g), off, len, fill);
  }
  template <class F> auto read_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F f) const {
    return read(chunk_id(k, s, g), off, len, f);
  }
  void dlog_write(uint32_t node, uint64_t e, const DlogEntry &d) const {
    write(dlog_id(node, e / p_.dlog_chunk), (e % p_.dlog_chunk) * sizeof(DlogEntry), sizeof(DlogEntry),
          [&](uint8_t *dst) { std::memcpy(dst, &d, sizeof(d)); }, Elem{uint32_t(e % p_.dlog_chunk), 1});
    t_mod_bytes += sizeof(d);
  }
  // Entries [from, to) of node's log: one read section per chunk copies them out; f runs after the section ended.
  template <class F> void dlog_scan(uint32_t node, uint64_t from, uint64_t to, F f) const {
    thread_local std::vector<DlogEntry> buf;
    for (uint64_t e = from; e < to;) {
      const uint64_t a = e % p_.dlog_chunk, n = std::min<uint64_t>(p_.dlog_chunk - a, to - e);
      buf.resize(n);
      read(dlog_id(node, e / p_.dlog_chunk), a * sizeof(DlogEntry), n * sizeof(DlogEntry),
           [&](const uint8_t *src) { std::memcpy(buf.data(), src, n * sizeof(DlogEntry)); },
           Elem{uint32_t(a), uint16_t(n)});
      for (const DlogEntry &d : buf) f(d);
      e += n;
    }
  }
  std::string usage() const {
    uint64_t objs = 0, bytes = 0;
    for_each_object([&](uint64_t, uint64_t sz) { objs++, bytes += (sz + 63) / 64 * 64; });
    return "megalon objects=" + std::to_string(objs) + " object_bytes=" + std::to_string(bytes) + " segments=" +
           std::to_string(p_.segments) + " groups=" + std::to_string(p_.g.groups()) + " per_chunk=" +
           std::to_string(p_.g.per_chunk()) + " vchunk=" + std::to_string(p_.g.vchunk_bytes()) + " lchunk=" +
           std::to_string(p_.g.lchunk_bytes()) + " dlog_chunks_per_node=" + std::to_string(dlog_chunks_) +
           " dlog_chunk_bytes=" + std::to_string(uint64_t(p_.dlog_chunk) * sizeof(DlogEntry)) + " shim_api=" +
           std::to_string(api_->version) + " thread_coh=" + (coh_ ? "yes" : "no") + " shim=" + api_->info;
  }
  std::string stats() const {
    MegStats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.arena_bytes=" << s.arena_bytes << "\nmegalon.used_bytes=" << s.used_bytes
      << "\nmegalon.created=" << s.created << "\nmegalon.creates=" << s.creates
      << "\nmegalon.read_sections=" << s.read_sections << "\nmegalon.read_retry_notify=" << s.read_retry_notify
      << "\nmegalon.read_retry_incoherent=" << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections
      << "\nmegalon.write_retry=" << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw
      << "\nmegalon.flushes=" << s.flushes << "\nmegalon.flush_bytes=" << s.flush_bytes
      << "\nmegalon.replay_flushes=" << s.replay_flushes << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes
      << "\nmegt.sample=" << kSample << "\nmegt.clock_ns=" << clock_ns_ << "\nmegt.thread_coh=" << (coh_ ? 1 : 0);
    static const char *const names[MegTimers::kN] = {"rd_sampled", "rd_start_ns", "rd_body_ns", "rd_end_ns",
                                                      "rd_retries", "rd_failed_timed", "rd_failed_ns", "wr_sections",
                                                      "wr_start_ns", "wr_body_ns", "wr_end_ns"};
    static const char *const roles[MegTimers::kRoles] = {"main.", "writer.", "search.", "other."};
    const std::vector<uint64_t> sum = timers(-1);
    for (int k = 0; k < MegTimers::kN; k++) o << "\nmegt." << names[k] << "=" << sum[k];
    for (int r = 0; r < MegTimers::kRoles; r++) {
      const std::vector<uint64_t> rs = timers(r);
      for (int k = 0; k < MegTimers::kN; k++) o << "\nmegt." << roles[r] << names[k] << "=" << rs[k];
    }
    if (wsec_) {
      uint64_t recs = 0, dropped = 0;
      {
        std::lock_guard<std::mutex> g(tmu_);
        for (const MegTimers *t : tblocks_) recs += t->tb.count(), dropped += t->tb.dropped;
      }
      o << "\ntrace.records=" << recs << "\ntrace.bytes=" << recs * sizeof(TraceRec) << "\ntrace.dropped=" << dropped
        << "\ntrace.cost_ns_per_read_section=" << trace_cost_ns_ << "\ntrace.wsec=" << cxl::hwcc::load_acquire(wsec_);
    }
    o << "\n";
    return o.str();
  }

  // ---- measurement hooks (server.cc)
  static constexpr uint32_t kSample = 64;  // power of two
  // Trace on: wsec_counter = the HWcc line (layout.h), max_records = per-node cap (beyond it records are dropped and
  // counted). Off: nullptr, no HWcc access. Measures the per-read-section trace cost once (trace.cost_ns_per_read_section:
  // two thread_coh calls + an HWcc load of wsec + rdtsc + a record store, on a private line and buffer).
  void set_trace(uint64_t *wsec_counter, uint32_t node, uint64_t max_records, uint32_t tsc_khz) {
    wsec_ = wsec_counter, node_ = node, max_chunks_ = (max_records + kTraceChunk - 1) / kTraceChunk, tsc_khz_ = tsc_khz;
    if (!wsec_) return;
    alignas(64) uint64_t line = 0;
    std::vector<TraceRec> tmp(4096);
    const int n = 200000;
    const uint64_t a = mono_ns();
    for (int i = 0; i < n; i++) {
      mshim::CohSnap s0, s1;
      if (coh_) coh_(&s0);
      const uint64_t q = cxl::hwcc::load_acquire(&line);
      if (coh_) coh_(&s1);
      TraceRec &r = tmp[size_t(i) & 4095];
      r.tsc = __rdtsc(), r.seq = uint32_t(q), r.obj = uint32_t(i), r.flags = uint8_t(s1.stale_cnt - s0.stale_cnt);
    }
    trace_cost_ns_ = (mono_ns() - a) / n;
  }
  bool tracing() const { return wsec_ != nullptr; }
  // node<K>.vdbtrace.bin (format: TraceFileHdr, then per thread TraceThreadHdr + records)
  bool dump_trace(const std::string &path, std::string *err) const {
    if (!wsec_) return true;
    std::lock_guard<std::mutex> g(tmu_);
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) return *err = "cannot write " + path, false;
    TraceFileHdr h{};
    std::memcpy(h.magic, "VDBTRC1", 8);
    h.node = node_, h.nr_nodes = p_.nr_nodes, h.segments = p_.segments, h.threads = uint32_t(tblocks_.size());
    h.groups = p_.g.groups(), h.dlog_chunks = dlog_chunks_, h.per_chunk = p_.g.per_chunk(), h.dlog_chunk = p_.dlog_chunk;
    h.wsec_at_dump = cxl::hwcc::load_acquire(wsec_), h.tsc_khz = tsc_khz_, h.has_coh = coh_ ? 1 : 0;
    for (const MegTimers *t : tblocks_) h.dropped += t->tb.dropped, h.records += t->tb.count();
    bool ok = std::fwrite(&h, sizeof(h), 1, f) == 1;
    uint32_t i = 0;
    for (const MegTimers *t : tblocks_) {
      const TraceBuf &b = t->tb;
      TraceThreadHdr th{i++, uint32_t(t->role.load()), b.count(), b.dropped};
      ok = ok && std::fwrite(&th, sizeof(th), 1, f) == 1;
      for (size_t c = 0; c < b.chunks.size(); c++) {
        const size_t n = c + 1 == b.chunks.size() ? b.used : kTraceChunk;
        ok = ok && std::fwrite(b.chunks[c].get(), sizeof(TraceRec), n, f) == n;
      }
    }
    ok = std::fclose(f) == 0 && ok;
    if (!ok) *err = "short write " + path;
    return ok;
  }
  // dense index of an object id (for_each_object order: vec/link per segment group, then delete-log chunks per node)
  uint64_t obj_index(uint64_t id) const {
    const uint64_t kind = id >> 44 & 0xf, a = id >> 24 & 0xfffff, b = id & 0xffffff;
    if (kind == 1 || kind == 2) return (a * p_.g.groups() + b) * 2 + (kind - 1);
    return uint64_t(p_.segments) * p_.g.groups() * 2 + a * dlog_chunks_ + b;
  }

 private:
  static std::string hex(uint64_t x) {
    char b[24];
    std::snprintf(b, sizeof(b), "%#lx", (unsigned long)x);
    return b;
  }
  void account_read(uint64_t t0, uint64_t t1, uint64_t t2, bool ok) const {
    const uint64_t t3 = mono_ns();
    MegTimers &t = tm();
    if (ok) {
      t.add(MegTimers::kRdSampled, 1), t.add(MegTimers::kRdStartNs, t1 - t0), t.add(MegTimers::kRdBodyNs, t2 - t1);
      t.add(MegTimers::kRdEndNs, t3 - t2);
    } else {
      t.add(MegTimers::kRdFailedTimed, 1), t.add(MegTimers::kRdFailedNs, t3 - t0);
    }
  }
  static uint8_t sat4(uint64_t x) { return uint8_t(x > 15 ? 15 : x); }
  void trace_read(uint64_t id, Elem e, uint64_t seq, uint32_t fails, const mshim::CohSnap &c0) const {
    TraceRec r{};
    uint64_t a = 0, b = fails, ns = 0;
    if (coh_) {
      mshim::CohSnap c1;
      coh_(&c1);
      a = c1.stale_cnt - c0.stale_cnt, b = c1.concur_cnt - c0.concur_cnt;
      ns = (c1.stale_ns - c0.stale_ns) + (c1.concur_ns - c0.concur_ns);
    }
    r.tsc = __rdtsc(), r.seq = uint32_t(seq), r.obj = uint32_t(obj_index(id)), r.elem = e.elem, r.n = e.n;
    r.type = kTraceRead, r.flags = uint8_t(sat4(a) | sat4(b) << 4), r.ev_ns = uint32_t(ns > 0xffffffffu ? 0xffffffffu : ns);
    MegTimers &t = tm();
    TraceBuf &tb = t.tb;
    if (!r.flags && tb.have_last && tb.last.obj == r.obj && tb.last.elem == r.elem && tb.last.n == r.n &&
        tb.last.seq == r.seq)
      return;  // identical consecutive read (e.g. header + vector of one element)
    tb.last = r, tb.have_last = true;
    append(t, r);
  }
  void append(MegTimers &t, const TraceRec &r) const {
    TraceBuf &b = t.tb;
    if (b.chunks.empty() || b.used == kTraceChunk) {
      if (chunks_.fetch_add(1, std::memory_order_relaxed) >= max_chunks_) {
        chunks_.fetch_sub(1, std::memory_order_relaxed);
        b.dropped++;
        return;
      }
      b.chunks.emplace_back(new TraceRec[kTraceChunk]);
      b.used = 0;
    }
    b.chunks.back()[b.used++] = r;
  }
  MegTimers &tm() const {  // this thread's block for this backend (a process has one backend; tests may have two)
    thread_local const MegalonBackend *owner = nullptr;
    thread_local MegTimers *mine = nullptr;
    if (owner != this) {
      thread_local std::vector<std::pair<const MegalonBackend *, MegTimers *>> all;
      mine = nullptr;
      for (auto &e : all)
        if (e.first == this) mine = e.second;
      if (!mine) {
        mine = new MegTimers;  // lives as long as the process (threads are long-lived)
        std::lock_guard<std::mutex> g(tmu_);
        tblocks_.push_back(mine);
        all.emplace_back(this, mine);
      }
      owner = this;
    }
    return *mine;
  }
  std::vector<uint64_t> timers(int role) const {  // role -1: all blocks
    std::vector<uint64_t> sum(MegTimers::kN, 0);
    std::lock_guard<std::mutex> g(tmu_);
    for (const MegTimers *t : tblocks_)
      if (role < 0 || t->role.load() == role)
        for (int k = 0; k < MegTimers::kN; k++) sum[k] += t->v[k].load(std::memory_order_relaxed);
    return sum;
  }
  Params p_;
  const MegalonApi *api_;
  void (*coh_)(mshim::CohSnap *) = nullptr;
  uint64_t dlog_chunks_;
  uint64_t *wsec_ = nullptr;  // HWcc: write sections completed by all nodes (trace only)
  uint32_t node_ = 0, clock_ns_ = 0, tsc_khz_ = 0;
  uint64_t max_chunks_ = 0, trace_cost_ns_ = 0;
  mutable std::atomic<uint64_t> chunks_{0};    // trace chunks allocated by all threads (cap)
  mutable std::vector<MegTimers *> tblocks_;  // every thread's counter block (under tmu_)
  mutable std::mutex tmu_;
};

// HNSW accessor (shm_hnsw.h): every chunk access is one Megalon section; reads copy into the caller's scratch.
class MegalonAcc {
 public:
  using Mem = MegalonMem;
  MegalonAcc(const GraphParams &p, Mem m) : p_(p), m_(m) {
    N_ = p.per_chunk();
    vrec_ = p.vrec_bytes();
    l0_ = p.links0_bytes();
    upper_base_ = N_ * l0_;
  }
  GraphMeta *meta() const { return m_.meta; }
  float dot(const float *q, uint32_t i) const {
    return m_.be->read(vid(i), voff(i) + sizeof(ElemHeader), uint64_t(p_.dim) * 4,
                       [&](const uint8_t *v) { return vdb::dot(q, reinterpret_cast<const float *>(v), p_.dim); },
                       velem(i));
  }
  const ElemHeader &header(uint32_t i, ElemHeader &tmp) const {
    m_.be->read(vid(i), voff(i), sizeof(ElemHeader), [&](const uint8_t *src) { std::memcpy(&tmp, src, sizeof(tmp)); },
                velem(i));
    return tmp;
  }
  const float *vec(uint32_t i, float *tmp) const {
    m_.be->read(vid(i), voff(i) + sizeof(ElemHeader), uint64_t(p_.dim) * 4,
                [&](const uint8_t *src) { std::memcpy(tmp, src, size_t(p_.dim) * 4); }, velem(i));
    return tmp;
  }
  const uint32_t *links(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const { return links_mut(i, level, uo, tmp); }
  uint32_t *links_mut(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const {
    const uint64_t n = lbytes(level);
    m_.be->read(lid(i), loff(i, level, uo), n, [&](const uint8_t *src) { std::memcpy(tmp, src, n); },
                link_elem(i % N_, level));
    return tmp;
  }
  void commit_links(uint32_t i, int level, uint64_t uo, const uint32_t *p) const {
    const uint64_t n = lbytes(level);
    m_.be->write(lid(i), loff(i, level, uo), n, [&](uint8_t *dst) { std::memcpy(dst, p, n); }, link_elem(i % N_, level));
    t_mod_bytes += n;
  }
  void write_elem(uint32_t i, const ElemHeader &h, const float *v, uint64_t upper_bytes) const {
    m_.be->write(vid(i), voff(i), vrec_, [&](uint8_t *dst) {
      std::memcpy(dst, &h, sizeof(h));
      std::memcpy(dst + sizeof(ElemHeader), v, size_t(p_.dim) * 4);
    }, velem(i));
    const uint64_t l0off = (i % N_) * l0_, uoff = upper_base_ + h.upper_off;
    m_.be->write_obj(
        lid(i),
        [&](uint8_t *base, size_t size) {
          MegalonBackend::check_lines(lid(i), l0off, l0_, size);
          std::memset(base + l0off, 0, l0_);
          if (upper_bytes) {
            MegalonBackend::check_lines(lid(i), uoff, upper_bytes, size);
            std::memset(base + uoff, 0, upper_bytes);
          }
        },
        link_elem(i % N_, 0, uint32_t(1 + upper_bytes / p_.links_bytes())));
    t_mod_bytes += vrec_ + l0_ + upper_bytes;
  }
  void prefetch(uint32_t) const {}

 private:
  uint64_t vid(uint32_t i) const { return MegalonBackend::vec_id(m_.seg, i / N_); }
  uint64_t lid(uint32_t i) const { return MegalonBackend::link_id(m_.seg, i / N_); }
  uint64_t voff(uint32_t i) const { return (i % N_) * vrec_; }
  Elem velem(uint32_t i) const { return Elem{uint32_t(i % N_), 1}; }
  uint64_t lbytes(int level) const { return level ? p_.links_bytes() : l0_; }
  uint64_t loff(uint32_t i, int level, uint64_t uo) const {
    return level == 0 ? (i % N_) * l0_ : upper_base_ + uo + uint64_t(level - 1) * p_.links_bytes();
  }
  GraphParams p_;
  Mem m_;
  uint64_t N_, vrec_, l0_, upper_base_;
};

}  // namespace vdb

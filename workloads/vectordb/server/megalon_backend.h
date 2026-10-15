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
#pragma once

#include <dlfcn.h>
#include <time.h>

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
#include "megalon_api.h"
#include "shm_hnsw.h"

namespace vdb {

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "vdb-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device, joins the run, start barrier).
inline const MegalonApi *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    *err = std::string("dlopen ") + path + ": " + dlerror();
    return nullptr;
  }
  auto fn = reinterpret_cast<vdb_megalon_api_fn>(dlsym(h, "vdb_megalon_api"));
  if (!fn) {
    *err = path + ": no vdb_megalon_api";
    return nullptr;
  }
  const MegalonApi *api = fn();
  if (!api || api->version != kMegalonApiVersion) {
    *err = path + ": API version mismatch";
    return nullptr;
  }
  return api;
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

// Measurement (DESIGN.md §13; MOT1 v4 H1 "Instrumentation" and §4.3 false-sharing classification); Megalon
// itself is unchanged. Read sections: 1 in kSample sections (random per section) is timed (read_start / body / read_end);
// a failed attempt of a timed section is timed in full. Write sections are always timed. With a trace dir, every
// write section is logged (id, written ranges, wsec sequence number taken from an HWcc counter after write_end) and
// every failed read attempt (id, read range, wsec counter before read_start and after the failed read_end):
// tools/classify_retries.py marks a retry false sharing when a peer write with seq in (s0, s1] hit the same object
// on disjoint ranges, true sharing when ranges overlap. Also with a trace dir, an HWcc slot per object holds the seq
// of its last write section; a read that finds it past this node's cache logs a refetch (Megalon flushes and
// re-reads the object in ObjectReadStart), classified the same way (node<K>.megalon-refetch.bin).
// Without a trace dir none of the HWcc trace lines is touched.
// Overhead without a trace dir (per read section): one xorshift and a branch; 1 in 64 sections 4 clock_gettime
// (vDSO) + 4 thread-local counter updates; a failed read_end one thread-local update. Per write section: 4
// clock_gettime + 4 thread-local updates. With a trace dir, in addition: per read section one HWcc load of objseq,
// one HWcc load of wsec per attempt, a node-local cache load (a CAS on a change); per write section one HWcc
// fetch-add (wsec) and CAS (objseq), and a log append under a mutex (writer thread only); retries and refetches
// append under the same mutex.
// Note: ObjectReadStart retries internally when the object's counter moved since this node last read it (flush the
// whole object, retry; megalon.read_retry_incoherent): that time is inside rd_start_ns but is not a wrapper retry
// (rd_retries / the retry log see only failed ObjectReadEnd calls).
inline uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
struct __attribute__((packed)) WsecRec {  // 48 B
  uint64_t seq, id;
  uint32_t off0, len0, off1, len1;
  uint64_t t_ns, node;
};
struct __attribute__((packed)) RetryRec {  // 48 B
  uint64_t id;
  uint32_t off, len;
  uint64_t s0, s1, t_ns, node;
};
// Wrapper counters, one block per thread (owner-only relaxed load + store: no shared cache-line writes on the read
// path), summed at stats time.
// Each block has the role of its thread (server thread ids: 0 main, 1 writer, >= 2 search; set by thread_init), so
// stats report the search-serving threads and the writer separately (megt.search.*, megt.writer.*, megt.main.*);
// megt.* without a role is the sum over all blocks (as before).
struct alignas(64) MegTimers {
  enum : int { kRdSampled, kRdStartNs, kRdBodyNs, kRdEndNs, kRdRetries, kRdFailedTimed, kRdFailedNs, kWrSections,
               kWrStartNs, kWrBodyNs, kWrEndNs, kRefetch, kFirstSight, kN };
  enum : int { kRoleMain, kRoleWriter, kRoleSearch, kRoleOther, kRoles };
  std::atomic<uint64_t> v[kN] = {};
  std::atomic<int> role{kRoleOther};
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

  MegalonBackend(const cxl::region &, uint8_t *, const Params &p, const MegalonApi *api) : p_(p), api_(api) {
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
    return true;
  }
  std::string name() const { return "megalon"; }

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
  // This thread's counters (owner-only writes: exact deltas around a section; server.cc per-query attribution).
  void thread_snap(uint64_t *out) const {
    MegTimers &t = tm();
    for (int k = 0; k < MegTimers::kN; k++) out[k] = t.v[k].load(std::memory_order_relaxed);
  }
  // Timer-read overhead per timed interval (qcoh.h calibrate_clock_ns, measured once at server start); reported as
  // megt.clock_ns. The counters stay raw; analysis subtracts clock_ns per timed interval.
  void set_clock_ns(uint32_t c) { clock_ns_ = c; }
  // Read section over [off, off + len): f(const uint8_t *) may run more than once and must only produce its result
  // (per-attempt local state); returns the result of the accepted attempt.
  template <class F> auto read(uint64_t id, uint64_t off, uint64_t len, F f) const {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    // random 1/kSample sampling per section (a fixed every-k-th rule could alias with HNSW's regular access pattern)
    thread_local uint64_t rs = 0x9e3779b97f4a7c15ull ^ uint64_t(reinterpret_cast<uintptr_t>(&rs));
    rs ^= rs << 13, rs ^= rs >> 7, rs ^= rs << 17;  // xorshift64
    const bool timed = (rs >> 32 & (kSample - 1)) == 0;
    const uint64_t oi = oseq_ ? obj_index(id) : 0;
    if (oseq_) note_read(oi, id, off, len);
    bool failed = false;  // trace: Megalon resets its local seq on a failed read_end; the accepted re-read sets it
    uint64_t va = 0;
    for (;;) {
      MegObj h;
      const uint64_t s0 = wsec_ ? cxl::hwcc::load_acquire(wsec_) : 0;
      if (oseq_ && failed) va = cxl::hwcc::load_acquire(&oseq_[oi]);
      const uint64_t t0 = timed ? mono_ns() : 0;
      const int rc = api_->read_start(id, &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(" + hex(id) + ") = " + std::to_string(rc));
      if (off + len > h.size) megalon_fatal("read beyond object " + hex(id));
      const uint64_t t1 = timed ? mono_ns() : 0;
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(h.ptr + off));
        const uint64_t t2 = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t0, t1, t2, ok);
        if (ok) {
          if (failed && oseq_) raise_cache(oi, va);
          return;
        }
      } else {
        R r = f(static_cast<const uint8_t *>(h.ptr + off));
        const uint64_t t2 = timed ? mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed) account_read(t0, t1, t2, ok);
        if (ok) {
          if (failed && oseq_) raise_cache(oi, va);
          return r;
        }
      }
      failed = true;
      tm().add(MegTimers::kRdRetries, 1);
      if (trace_) log_retry(id, off, len, s0);
    }
  }
  // Write section; f(base, size) writes whole lines only and reads nothing of the object (D3). Ranges are for the
  // trace only (what the section wrote; [0, size) when not given).
  template <class F>
  void write_obj(uint64_t id, F f, uint64_t off0 = 0, uint64_t len0 = ~0ull, uint64_t off1 = 0, uint64_t len1 = 0) const {
    MegObj h;
    const uint64_t t0 = mono_ns();
    const int rc = api_->write_start(id, &h);
    if (rc != 0) megalon_fatal("ObjectWriteStart(" + hex(id) + ") = " + std::to_string(rc));
    const uint64_t t1 = mono_ns();
    f(h.ptr, h.size);
    const uint64_t t2 = mono_ns();
    api_->write_end(&h);
    const uint64_t t3 = mono_ns();
    MegTimers &t = tm();
    t.add(MegTimers::kWrSections, 1), t.add(MegTimers::kWrStartNs, t1 - t0), t.add(MegTimers::kWrBodyNs, t2 - t1);
    t.add(MegTimers::kWrEndNs, t3 - t2);
    if (wsec_) {
      const uint64_t seq = cxl::hwcc::fetch_add(wsec_, uint64_t(1)) + 1;
      note_write(id, seq);
      if (trace_) {
        if (len0 == ~0ull) len0 = h.size;
        std::lock_guard<std::mutex> g(tmu_);
        wlog_.push_back(WsecRec{seq, id, uint32_t(off0), uint32_t(len0), uint32_t(off1), uint32_t(len1), t3, node_});
      }
    }
  }
  // Write section over [off, off + len), whole lines (len may end at the object end).
  template <class F> void write(uint64_t id, uint64_t off, uint64_t len, F fill) const {
    write_obj(
        id,
        [&](uint8_t *base, size_t size) {
          check_lines(id, off, len, size);
          fill(base + off);
        },
        off, len);
  }
  static void check_lines(uint64_t id, uint64_t off, uint64_t len, size_t size) {
    if (off % 64 || off + len > size || (len % 64 && off + len != size))
      megalon_fatal("write of [" + std::to_string(off) + ", +" + std::to_string(len) + ") in object " + hex(id) +
                    " is not whole lines");
  }

  // ---- backend interface (server.cc)
  MegalonMem mem(uint32_t s, GraphMeta *meta) const { return MegalonMem{meta, this, s}; }
  template <class F> void write_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F fill) const {
    write(chunk_id(k, s, g), off, len, fill);
  }
  template <class F> auto read_chunk(Chunk k, uint32_t s, uint64_t g, uint64_t off, uint64_t len, F f) const {
    return read(chunk_id(k, s, g), off, len, f);
  }
  void dlog_write(uint32_t node, uint64_t e, const DlogEntry &d) const {
    write(dlog_id(node, e / p_.dlog_chunk), (e % p_.dlog_chunk) * sizeof(DlogEntry), sizeof(DlogEntry),
          [&](uint8_t *dst) { std::memcpy(dst, &d, sizeof(d)); });
  }
  // Entries [from, to) of node's log: one read section per chunk copies them out; f runs after the section ended.
  template <class F> void dlog_scan(uint32_t node, uint64_t from, uint64_t to, F f) const {
    thread_local std::vector<DlogEntry> buf;
    for (uint64_t e = from; e < to;) {
      const uint64_t a = e % p_.dlog_chunk, n = std::min<uint64_t>(p_.dlog_chunk - a, to - e);
      buf.resize(n);
      read(dlog_id(node, e / p_.dlog_chunk), a * sizeof(DlogEntry), n * sizeof(DlogEntry),
           [&](const uint8_t *src) { std::memcpy(buf.data(), src, n * sizeof(DlogEntry)); });
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
           " dlog_chunk_bytes=" + std::to_string(uint64_t(p_.dlog_chunk) * sizeof(DlogEntry)) + " shim=" + api_->info;
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
      << "\nmegt.sample=" << kSample << "\nmegt.clock_ns=" << clock_ns_;
    static const char *const names[MegTimers::kN] = {"rd_sampled", "rd_start_ns", "rd_body_ns", "rd_end_ns",
                                                      "rd_retries", "rd_failed_timed", "rd_failed_ns", "wr_sections",
                                                      "wr_start_ns", "wr_body_ns", "wr_end_ns", "trace_refetch",
                                                      "trace_first_sight"};
    static const char *const roles[MegTimers::kRoles] = {"main.", "writer.", "search.", "other."};
    const std::vector<uint64_t> sum = timers(-1);
    for (int k = 0; k < MegTimers::kN; k++) o << "\nmegt." << names[k] << "=" << sum[k];
    for (int r = 0; r < MegTimers::kRoles; r++) {
      const std::vector<uint64_t> rs = timers(r);
      for (int k = 0; k < MegTimers::kN; k++) o << "\nmegt." << roles[r] << names[k] << "=" << rs[k];
    }
    o << "\n";
    return o.str();
  }

  // ---- measurement hooks (server.cc)
  static constexpr uint32_t kSample = 64;  // power of two
  // Trace on: wsec_counter / objseq = the HWcc lines (layout.h), log = keep the logs. Off: nullptrs, no HWcc access.
  void set_trace(uint64_t *wsec_counter, uint64_t *objseq, bool log, uint32_t node) {
    wsec_ = wsec_counter, oseq_ = objseq, trace_ = log, node_ = node;
    if (oseq_) {
      ocache_.reset(new std::atomic<uint64_t>[p_.trace_objects()]);
      for (uint64_t i = 0; i < p_.trace_objects(); i++) ocache_[i].store(0);
    }
  }
  bool dump_trace(const std::string &prefix, std::string *err) const {
    if (!trace_) return true;
    std::lock_guard<std::mutex> g(tmu_);
    for (int k = 0; k < 3; k++) {
      static const char *const names[] = {".megalon-wsec.bin", ".megalon-retry.bin", ".megalon-refetch.bin"};
      const std::string path = prefix + names[k];
      FILE *f = std::fopen(path.c_str(), "wb");
      if (!f) return *err = "cannot write " + path, false;
      if (k == 0) std::fwrite(wlog_.data(), sizeof(WsecRec), wlog_.size(), f);
      else if (k == 1) std::fwrite(rlog_.data(), sizeof(RetryRec), rlog_.size(), f);
      else std::fwrite(flog_.data(), sizeof(RetryRec), flog_.size(), f);
      std::fclose(f);
    }
    return true;
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
  // dense index of an object id (for_each_object order: vec/link per segment group, then delete-log chunks per node)
  uint64_t obj_index(uint64_t id) const {
    const uint64_t kind = id >> 44 & 0xf, a = id >> 24 & 0xfffff, b = id & 0xffffff;
    if (kind == 1 || kind == 2) return (a * p_.g.groups() + b) * 2 + (kind - 1);
    return uint64_t(p_.segments) * p_.g.groups() * 2 + a * dlog_chunks_ + b;
  }
  // Trace only; the node cache mirrors Megalon's per-node local seq of the object (c3.cc): 0 = none (never read or
  // written here: Megalon's local seq is nullopt and its first read does not flush), set by an accepted read and,
  // unconditionally, by this node's own write_end. A read section whose object's HWcc objseq is past a non-zero
  // cache: a write section completed on the object since this node last saw it, so ObjectReadStart flushes and
  // re-reads the object. One thread per node logs the transition (cache CAS): refetch record (object, this read's
  // range, old seq, new seq); classify_retries.py classifies it like a retry.
  void note_read(uint64_t i, uint64_t id, uint64_t off, uint64_t len) const {
    const uint64_t v = cxl::hwcc::load_acquire(&oseq_[i]);
    uint64_t c = ocache_[i].load(std::memory_order_relaxed);
    if (v <= c || !ocache_[i].compare_exchange_strong(c, v)) return;
    if (c == 0) {  // first sight on this node: no flush in Megalon
      tm().add(MegTimers::kFirstSight, 1);
      return;
    }
    tm().add(MegTimers::kRefetch, 1);
    if (trace_) {
      std::lock_guard<std::mutex> g(tmu_);
      flog_.push_back(RetryRec{id, uint32_t(off), uint32_t(len), c, v, mono_ns(), node_});
    }
  }
  // Trace only, after write_end (inside the segment's HWcc write lock or the node's own delete log: one writer per
  // object at a time): objseq = seq; cache = seq unconditionally (Megalon's write_seq_end sets the node's local seq).
  void note_write(uint64_t id, uint64_t seq) const {
    if (!oseq_) return;
    const uint64_t i = obj_index(id);
    uint64_t prev = cxl::hwcc::load_acquire(&oseq_[i]);
    while (prev < seq && !cxl::hwcc::cas(&oseq_[i], &prev, seq)) {
    }
    ocache_[i].store(seq);
  }
  // Trace only: after a failed read_end Megalon's local seq is reset and the accepted re-read sets it to the counter
  // it read (va = objseq loaded before that attempt's read_start).
  void raise_cache(uint64_t i, uint64_t va) const {
    uint64_t c = ocache_[i].load(std::memory_order_relaxed);
    while (c < va && !ocache_[i].compare_exchange_weak(c, va)) {
    }
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
  void log_retry(uint64_t id, uint64_t off, uint64_t len, uint64_t s0) const {
    const uint64_t s1 = wsec_ ? cxl::hwcc::load_acquire(wsec_) : 0;
    std::lock_guard<std::mutex> g(tmu_);
    rlog_.push_back(RetryRec{id, uint32_t(off), uint32_t(len), s0, s1, mono_ns(), node_});
  }
  Params p_;
  const MegalonApi *api_;
  uint64_t dlog_chunks_;
  uint64_t *wsec_ = nullptr;  // HWcc: write sections completed by all nodes (trace only)
  uint64_t *oseq_ = nullptr;  // HWcc: per object, seq of its last write section (trace only)
  mutable std::unique_ptr<std::atomic<uint64_t>[]> ocache_;  // this node: last objseq value seen per object
  bool trace_ = false;
  uint32_t node_ = 0, clock_ns_ = 0;
  mutable std::vector<MegTimers *> tblocks_;  // every thread's counter block (under tmu_)
  mutable std::mutex tmu_;
  mutable std::vector<WsecRec> wlog_;
  mutable std::vector<RetryRec> rlog_;
  mutable std::vector<RetryRec> flog_;  // refetches (same record layout: s0 = old seq, s1 = new seq)
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
                       [&](const uint8_t *v) { return vdb::dot(q, reinterpret_cast<const float *>(v), p_.dim); });
  }
  const ElemHeader &header(uint32_t i, ElemHeader &tmp) const {
    m_.be->read(vid(i), voff(i), sizeof(ElemHeader), [&](const uint8_t *src) { std::memcpy(&tmp, src, sizeof(tmp)); });
    return tmp;
  }
  const float *vec(uint32_t i, float *tmp) const {
    m_.be->read(vid(i), voff(i) + sizeof(ElemHeader), uint64_t(p_.dim) * 4,
                [&](const uint8_t *src) { std::memcpy(tmp, src, size_t(p_.dim) * 4); });
    return tmp;
  }
  const uint32_t *links(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const { return links_mut(i, level, uo, tmp); }
  uint32_t *links_mut(uint32_t i, int level, uint64_t uo, uint32_t *tmp) const {
    const uint64_t n = lbytes(level);
    m_.be->read(lid(i), loff(i, level, uo), n, [&](const uint8_t *src) { std::memcpy(tmp, src, n); });
    return tmp;
  }
  void commit_links(uint32_t i, int level, uint64_t uo, const uint32_t *p) const {
    const uint64_t n = lbytes(level);
    m_.be->write(lid(i), loff(i, level, uo), n, [&](uint8_t *dst) { std::memcpy(dst, p, n); });
  }
  void write_elem(uint32_t i, const ElemHeader &h, const float *v, uint64_t upper_bytes) const {
    m_.be->write(vid(i), voff(i), vrec_, [&](uint8_t *dst) {
      std::memcpy(dst, &h, sizeof(h));
      std::memcpy(dst + sizeof(ElemHeader), v, size_t(p_.dim) * 4);
    });
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
        l0off, l0_, uoff, upper_bytes);
  }
  void prefetch(uint32_t) const {}

 private:
  uint64_t vid(uint32_t i) const { return MegalonBackend::vec_id(m_.seg, i / N_); }
  uint64_t lid(uint32_t i) const { return MegalonBackend::link_id(m_.seg, i / N_); }
  uint64_t voff(uint32_t i) const { return (i % N_) * vrec_; }
  uint64_t lbytes(int level) const { return level ? p_.links_bytes() : l0_; }
  uint64_t loff(uint32_t i, int level, uint64_t uo) const {
    return level == 0 ? (i % N_) * l0_ : upper_base_ + uo + uint64_t(level - 1) * p_.links_bytes();
  }
  GraphParams p_;
  Mem m_;
  uint64_t N_, vrec_, l0_, upper_base_;
};

}  // namespace vdb

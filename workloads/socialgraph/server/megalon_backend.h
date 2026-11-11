// Megalon backend (backend.h, DESIGN.md §5; experiment socialgraph-serving §2): the graph records live in Megalon
// objects (systems/megalon/src/include/rackobj.h through the shared shim systems/megalon/shim, libmegalon-objapi.so,
// dlopen()ed by sg-server --backend megalon only; mirrors workloads/vectordb/server/megalon_backend.h). Two object
// layouts (--object-layout):
//   record  one object per node slot, per primary adjacency block and per 4 KiB overflow block (layout.h
//           for_each_record_object): ~8.15M objects with image build 1;
//   chunk   one object per kChunkBytes chunk of the node, adjacency and overflow arrays (layout.h for_each_chunk /
//           chunk_of; data structure granularity as the vector DB Megalon chunk cells, 32 MiB).
// The image header and adj_index are read-only after the build and are no coherence objects of the run: node 0 puts
// them into one load-time object ("meta": image bytes [0, adj_index_off + adj_index_bytes)), every node copies that
// object into private memory once at attach (has_adj / adj_off answer from the copy) and never touches it again.
//
// Megalon contract (rackobj.h): at most one open section per thread; a write section writes whole 64 B lines and
// never reads prior contents of the object (D3). The server's record protocol (graph_ops.h, unchanged) nests accesses
// (a list read walks overflow blocks inside the list read; a link write reads overflow blocks and writes an overflow
// block inside the list write) and modifies records in place (read-modify-write). This class maps that onto sections:
//   read(kNode | kOvf)  one read section; f runs in place on the object (retried until ObjectReadEnd succeeds).
//   read(kAdj)          the primary block is copied out in a read section (two sections when a chunk boundary splits
//                       it), the section is closed and f runs on the copy, so f's nested overflow reads are sections of
//                       their own. When f made nested reads, or the block was split, the list version word is read
//                       again in a new section afterwards; a changed version re-runs f (as the plain seqlock re-check
//                       on live memory would). f's own seqlock check runs on the copy (always consistent there).
//   write / write_range the record is copied out in a read section (current: the writer holds the HWcc stripe lock,
//                       and Megalon read sections are coherent), f modifies the private copy, then one write section
//                       writes the lines of [off, off + len) of the record from the copy (whole lines, no prior bytes
//                       read). A record whose copy f left unchanged (an aborted write) is not written. Nested writes
//                       (overflow block inside a list write) publish first; before the first of them, the enclosing
//                       record's header line is published with the version word's writing bit (graph_ops kWriting)
//                       set, so a reader that combines the old list header with a new overflow block fails the version
//                       re-check above (the plain backend gets this from the in-place fetch_or). A record split over
//                       two chunks is written the same way: header line with the writing bit, second part, first part.
// Version word: NodeSlot.version and AdjHeader.version, both at byte 8 of the record's first line.
// Measurement: wrapper timers as the vector DB backend (1 in kSample read sections timed: read_start / body /
// read_end; every write section timed), per-thread blocks, keys megt.*; Megalon's own stats megalon.*.
#pragma once

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

#include "backend.h"
#include "layout.h"
#include "megalon_objapi.h"

namespace sg {

enum class MegLayout : uint8_t { kRecord = 0, kChunk = 1 };

[[noreturn]] inline void megalon_fatal(const std::string &m) {
  std::fprintf(stderr, "sg-server: FATAL megalon backend: %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

// dlopen the shim (loading it initialises Megalon: maps the device at map_va, joins the run, start barrier).
inline const mshim::Api *megalon_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<megalon_object_api_fn>(dlsym(h, "megalon_object_api"));
  if (!fn) return *err = path + ": no megalon_object_api", nullptr;
  const mshim::Api *api = fn();
  if (!api || api->version < 1) return *err = path + ": API version mismatch", nullptr;
  return api;
}

// [va, va + len) must be covered by mappings of `path` (Megalon's mapping of the device at map_va).
inline bool megalon_mapped_by(uint64_t va, uint64_t len, const std::string &path, std::string *err) {
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
  char b[160];
  std::snprintf(b, sizeof b, "region [%#lx, %#lx) is not mapped from ", (unsigned long)va, (unsigned long)(va + len));
  *err = b + path + " (Megalon must map the same region config)";
  return false;
}

inline uint64_t meg_mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

// Object ids (deterministic, < 2^63): "SG" | kind << 44 | index.
constexpr uint64_t kMegBase = 0x5347ull << 48;
constexpr uint64_t kMegKindNode = 1, kMegKindAdj = 2, kMegKindOvf = 3, kMegKindChunk = 4, kMegKindMeta = 5;
inline uint64_t meg_id(uint64_t kind, uint64_t idx) { return kMegBase | kind << 44 | idx; }

// Object totals of a layout (sizing of the Megalon config; sg-server --print-megalon-objects).
struct MegSizing {
  uint64_t objects = 0, object_bytes = 0;  // incl. the meta object; object_bytes = sum of 64 B-aligned sizes
  uint64_t meta_bytes = 0, max_object = 0;
};
inline uint64_t meta_bytes(const ImageHeader &h) { return h.adj_index_off + h.adj_index_bytes; }

class MegalonBackendBase {
 public:
  struct Piece { uint64_t id, off, len; };  // object, offset inside it, bytes
  struct Loc {
    Piece p[2];
    uint32_t n;
    uint64_t bytes;
  };

  MegalonBackendBase(const mshim::Api *api, MegLayout lay, uint64_t chunk_bytes, uint32_t node)
      : api_(api), lay_(lay), cb_(chunk_bytes), node_(node) {}

  const ImageHeader &header() const { return *reinterpret_cast<const ImageHeader *>(meta_.data()); }
  bool has_adj(uint64_t slot) const { return slot < header().n_orig && adj_index_[slot] != kNoAdj; }
  uint64_t adj_off(uint64_t slot) const { return adj_index_[slot]; }
  uint64_t rec_bytes(ObjKind k, uint64_t idx) const {
    switch (k) {
      case ObjKind::kNode: return sizeof(NodeSlot);
      case ObjKind::kAdj: return view().primary_block_bytes(idx);
      case ObjKind::kOvf: return kPage;
      default: return 0;
    }
  }
  void thread_init(int tid) const {  // once per thread (the main thread registers before load / attach)
    thread_local bool registered = false;
    if (registered) return;
    registered = true;
    api_->reg(tid);
    blk().role.store(tid == 0 ? kRoleMain : tid == 1 ? kRoleWriter : kRoleQuery, std::memory_order_relaxed);
  }
  uint8_t *image_base() const { return nullptr; }
  uint64_t image_bytes() const { return 0; }

  // ---- objects
  // Every object of the layout (meta first): f(id, size, image offset of its first byte).
  template <class F> void for_each_object(const View &v, F f) const {
    f(meg_id(kMegKindMeta, 0), meta_bytes(*v.h), 0);
    if (lay_ == MegLayout::kRecord) {
      for_each_record_object(v, [&](const ObjRef &o) { f(rec_id(o.kind, o.idx), o.bytes, o.off); });
    } else {
      for_each_chunk(*v.h, cb_, [&, c = uint64_t(0)](const ChunkRef &r) mutable {
        if (r.array != ObjKind::kAdjIndex) f(meg_id(kMegKindChunk, c), r.bytes, r.off);
        c++;
      });
    }
  }
  MegSizing sizing(const View &v) const {
    MegSizing s;
    s.meta_bytes = meta_bytes(*v.h);
    for_each_object(v, [&](uint64_t, uint64_t size, uint64_t) {
      s.objects++, s.object_bytes += align_up(size, 64);
      s.max_object = std::max(s.max_object, size);
    });
    return s;
  }

  // Node 0, after Megalon initialised and before any other node attaches: create every object and copy the image
  // file into it (one write section per object, in image order). Returns false + err on any failure.
  bool load(const std::string &file, std::string *err) {
    const int fd = open(file.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return *err = "open " + file, false;
    struct stat st;
    if (fstat(fd, &st) != 0) return close(fd), *err = "stat " + file, false;
    ImageHeader h;
    if (pread(fd, &h, sizeof h, 0) != ssize_t(sizeof h)) return close(fd), *err = "short read of the image header", false;
    const std::string e = check_header(h, uint64_t(st.st_size));
    if (!e.empty()) return close(fd), *err = "image file header: " + e, false;
    void *m = mmap(nullptr, h.total_bytes, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return *err = "mmap " + file, false;
    madvise(m, h.total_bytes, MADV_SEQUENTIAL);
    const uint8_t *img = static_cast<const uint8_t *>(m);
    const View v(const_cast<uint8_t *>(img));
    const uint64_t t0 = meg_mono_ns();
    uint64_t n = 0, bytes = 0, create_ns = 0;
    bool ok = true;
    for_each_object(v, [&](uint64_t id, uint64_t size, uint64_t off) {
      if (!ok) return;
      const uint64_t c0 = meg_mono_ns();
      const int rc = api_->create(id, size);
      create_ns += meg_mono_ns() - c0;
      if (rc != 0) {
        *err = "ObjectCreate(" + hex(id) + ", " + std::to_string(size) + ") = " + std::to_string(rc) +
               " (-12 ENOMEM: object_arena_size too small; -17 EEXIST: stale objects, run with MEGALON_REINIT=1)";
        ok = false;
        return;
      }
      write_section(id, 0, size, img + off);
      n++, bytes += size;
      if ((n & ((1u << 20) - 1)) == 0)
        std::fprintf(stderr, "sg-server: megalon load %lu objects, %lu MiB, %.1f s\n", (unsigned long)n,
                     (unsigned long)(bytes >> 20), (meg_mono_ns() - t0) / 1e9);
    });
    munmap(m, h.total_bytes);
    if (ok)
      std::fprintf(stderr, "sg-server: megalon LOAD DONE %lu objects, %lu B from %s in %.1f s (create %.1f s), layout %s\n",
                   (unsigned long)n, (unsigned long)bytes, file.c_str(), (meg_mono_ns() - t0) / 1e9, create_ns / 1e9,
                   layout_name());
    return ok;
  }

  // Every node, after node 0 published its load: private copy of the meta object (header + adj_index), header
  // check, object ids and sizes (ObjectLookup of every object).
  bool attach(std::string *err) {
    size_t sz = 0;
    const uint64_t mid = meg_id(kMegKindMeta, 0);
    if (api_->lookup(mid, &sz) != 0 || sz < sizeof(ImageHeader)) return *err = "megalon: no meta object (node 0 load)", false;
    meta_.assign(sz, 0);
    read_copy(mid, 0, sz, meta_.data());
    const ImageHeader &h = header();
    std::string e = check_header(h, h.total_bytes);
    if (!e.empty()) return *err = "image header (meta object): " + e, false;
    if (sz != meta_bytes(h)) return *err = "meta object size " + std::to_string(sz), false;
    adj_index_ = reinterpret_cast<const uint64_t *>(meta_.data() + h.adj_index_off);
    if (lay_ == MegLayout::kChunk) {
      if (cb_ % kPage || cb_ < kPage) return *err = "megalon: chunk bytes must be a multiple of 4096", false;
      for_each_chunk(h, cb_, [&](const ChunkRef &r) { chunks_.push_back(r); });
    }
    const View v = view();
    uint64_t bad = 0, n = 0;
    for_each_object(v, [&](uint64_t id, uint64_t size, uint64_t) {
      size_t got = 0;
      const int rc = api_->lookup(id, &got);
      n++;
      if ((rc != 0 || got != size) && bad++ == 0)
        *err = "ObjectLookup(" + hex(id) + ") = " + std::to_string(rc) + " size " + std::to_string(got) + ", want " +
               std::to_string(size);
    });
    objects_ = n;
    sizing_ = sizing(v);
    return bad == 0;
  }

  // Read every object once in full (warm-up: first touch of every line through read sections, every node).
  uint64_t warm_up() const {
    uint64_t sum = 0;
    for_each_object(view(), [&](uint64_t id, uint64_t size, uint64_t) {
      sum += section_read(id, 0, size, [&](const uint8_t *c) {
        uint64_t x = 0;
        for (uint64_t o = 0; o < size; o += 64) x += c[o];
        return x;
      });
    });
    return sum;
  }

  // ---- record accesses (backend.h)
  template <class F> auto read(ObjKind k, uint64_t idx, F f) const {
    t_reads++;
    const Loc L = loc(k, idx);
    if (k != ObjKind::kAdj) {
      if (L.n != 1) megalon_fatal("node / ovf record split over two objects");
      return section_read(L.p[0].id, L.p[0].off, L.p[0].len, f);
    }
    std::vector<uint8_t> &buf = tbuf(t_rdepth);
    t_rdepth++;
    buf.resize(L.bytes);
    for (;;) {
      copy_out(L, buf.data());
      uint64_t v0;
      std::memcpy(&v0, buf.data() + kVerOff, 8);
      const uint64_t r0 = t_reads;
      using R = decltype(f(static_cast<const uint8_t *>(buf.data())));
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(buf.data()));
        if (validated(L, v0, r0)) { t_rdepth--; return; }
      } else {
        R r = f(static_cast<const uint8_t *>(buf.data()));
        if (validated(L, v0, r0)) { t_rdepth--; return r; }
      }
    }
  }
  template <class F> void write(ObjKind k, uint64_t idx, F f) const { write_range(k, idx, 0, rec_bytes(k, idx), f); }
  template <class F> void write_range(ObjKind k, uint64_t idx, uint64_t off, uint64_t len, F f) const {
    const Loc L = loc(k, idx);
    const size_t d = t_wstack.size();
    t_wstack.push_back(Pending{L, k, false});
    std::vector<uint8_t> &buf = tbuf(kWBuf + 2 * d), &orig = tbuf(kWBuf + 2 * d + 1);
    buf.resize(L.bytes);
    orig.resize(L.bytes);
    copy_out(L, buf.data());
    std::memcpy(orig.data(), buf.data(), L.bytes);
    f(buf.data());
    const bool marked = t_wstack[d].marked;
    t_wstack.pop_back();
    const bool changed = std::memcmp(buf.data(), orig.data(), L.bytes) != 0;
    if (!changed && !marked) { blk().add(kWrSkipped, 1); return; }
    mark_parents();  // (no-op unless this is a nested write)
    // lines written: the changed lines of [off, off + len) (rounded to lines); from line 0 when the header line carries
    // a mark that the final write must replace (marked by a nested write, or split record)
    const uint64_t lo = off & ~(kLine - 1), hi = std::min(align_up(off + len, kLine), L.bytes);
    uint64_t a = hi, e = lo;
    for (uint64_t x = lo; x < hi; x += kLine) {
      const uint64_t n = std::min(kLine, hi - x);
      if (std::memcmp(buf.data() + x, orig.data() + x, n)) a = std::min(a, x), e = x + n;
    }
    const bool split_mark = L.n == 2 && has_version(k) && !marked;
    if (marked || split_mark) a = 0, e = std::max(e, kLine);
    if (a >= e) { blk().add(kWrSkipped, 1); return; }
    publish(L, buf.data(), orig.data(), a, e, split_mark);
  }

  // ---- reporting
  const char *layout_name() const { return lay_ == MegLayout::kRecord ? "record" : "chunk"; }
  std::string usage() const {
    const MegSizing &s = sizing_;
    return std::string("megalon-") + layout_name() + " objects=" + std::to_string(s.objects) + " object_bytes=" +
           std::to_string(s.object_bytes) + " max_object=" + std::to_string(s.max_object) + " meta_bytes=" +
           std::to_string(s.meta_bytes) + (lay_ == MegLayout::kChunk ? " chunk_bytes=" + std::to_string(cb_) +
           " chunks=" + std::to_string(s.objects - 1) : std::string()) + " adj_index=private shim_api=" +
           std::to_string(api_->version) + " thread_coh=" + (api_->version >= 2 && api_->thread_coh ? "yes" : "no") +
           " shim=" + api_->info;
  }
  std::string stats() const {
    mshim::Stats s{};
    api_->stats(&s);
    std::ostringstream o;
    o << "megalon.layout=" << layout_name() << "\nmegalon.objects=" << objects_ << "\nmegalon.arena_bytes=" << s.arena_bytes
      << "\nmegalon.used_bytes=" << s.used_bytes << "\nmegalon.created=" << s.created << "\nmegalon.creates=" << s.creates
      << "\nmegalon.read_sections=" << s.read_sections << "\nmegalon.read_retry_notify=" << s.read_retry_notify
      << "\nmegalon.read_retry_incoherent=" << s.read_retry_incoherent << "\nmegalon.write_sections=" << s.write_sections
      << "\nmegalon.write_retry=" << s.write_retry << "\nmegalon.switch_rw=" << s.switch_rw << "\nmegalon.flushes=" << s.flushes
      << "\nmegalon.flush_bytes=" << s.flush_bytes << "\nmegalon.replay_flushes=" << s.replay_flushes
      << "\nmegalon.replay_flush_bytes=" << s.replay_flush_bytes;
    if (api_->version >= 5 && api_->wmeta_counts) {  // Megalon >= 80: cluster-wide record pool counters (never sum)
      mshim::WmetaCounts w{};
      api_->wmeta_counts(&w);
      o << "\nmegalon.reclaim_count=" << w.reclaim_count << "\nmegalon.allocate_count=" << w.allocate_count
        << "\nmegalon.records_in_use=" << w.records_in_use << "\nmegalon.record_slots=" << w.record_slots;
    }
    o << "\nmegt.sample=" << kSample;
    static const char *const names[kN] = {"rd_sections", "rd_sampled", "rd_start_ns", "rd_body_ns", "rd_end_ns",
                                          "rd_retries", "wr_sections", "wr_start_ns", "wr_body_ns", "wr_end_ns",
                                          "wr_skipped", "rec_copies", "rec_copy_bytes", "adj_validations",
                                          "adj_validation_fails", "marks", "split_records"};
    static const char *const roles[kRoles] = {"main.", "writer.", "query.", "other."};
    for (int r = -1; r < kRoles; r++) {
      uint64_t sum[kN] = {};
      {
        std::lock_guard<std::mutex> g(mu_);
        for (const Blk *b : blks_)
          if (r < 0 || b->role.load(std::memory_order_relaxed) == r)
            for (int k = 0; k < kN; k++) sum[k] += b->v[k].load(std::memory_order_relaxed);
      }
      for (int k = 0; k < kN; k++) o << "\nmegt." << (r < 0 ? "" : roles[r]) << names[k] << "=" << sum[k];
    }
    o << "\n";
    return o.str();
  }

  static constexpr uint32_t kSample = 64;  // 1 in kSample read sections timed (random per section)

 protected:
  static constexpr uint64_t kVerOff = 8;  // NodeSlot.version / AdjHeader.version
  static bool has_version(ObjKind k) { return k == ObjKind::kNode || k == ObjKind::kAdj; }
  View view() const { return View(const_cast<uint8_t *>(meta_.data())); }
  uint64_t rec_id(ObjKind k, uint64_t idx) const {
    return meg_id(k == ObjKind::kNode ? kMegKindNode : k == ObjKind::kAdj ? kMegKindAdj : kMegKindOvf, idx);
  }
  uint64_t rec_off(ObjKind k, uint64_t idx) const {  // image offset of a record
    const ImageHeader &h = header();
    switch (k) {
      case ObjKind::kNode: return h.nodes_off + idx * sizeof(NodeSlot);
      case ObjKind::kAdj: return h.adj_off + adj_index_[idx];
      default: return h.ovf_off + idx * kPage;
    }
  }
  Loc loc(ObjKind k, uint64_t idx) const {
    Loc L{};
    L.bytes = rec_bytes(k, idx);
    if (lay_ == MegLayout::kRecord) {
      L.p[0] = Piece{rec_id(k, idx), 0, L.bytes};
      L.n = 1;
      return L;
    }
    const uint64_t off = rec_off(k, idx), c = chunk_of(header(), cb_, off);
    if (c >= chunks_.size()) megalon_fatal("record outside every chunk");
    const ChunkRef &r = chunks_[c];
    const uint64_t in = off - r.off, first = std::min(L.bytes, r.bytes - in);
    L.p[0] = Piece{meg_id(kMegKindChunk, c), in, first};
    L.n = 1;
    if (first < L.bytes) {  // split by a chunk boundary (adjacency blocks only; the next chunk of the same array)
      if (c + 1 >= chunks_.size() || chunks_[c + 1].off != r.off + r.bytes) megalon_fatal("split record at an array end");
      L.p[1] = Piece{meg_id(kMegKindChunk, c + 1), 0, L.bytes - first};
      L.n = 2;
    }
    return L;
  }

  // One read section over [off, off + len) of object id with f in place (retried until ObjectReadEnd succeeds).
  template <class F>
  auto section_read(uint64_t id, uint64_t off, uint64_t len, F f) const -> decltype(f(static_cast<const uint8_t *>(nullptr))) {
    using R = decltype(f(static_cast<const uint8_t *>(nullptr)));
    if (t_open) megalon_fatal("nested read section (one open section per thread)");
    thread_local uint64_t rs = 0x9e3779b97f4a7c15ull ^ uint64_t(reinterpret_cast<uintptr_t>(&rs));
    rs ^= rs << 13, rs ^= rs >> 7, rs ^= rs << 17;
    const bool timed = (rs >> 32 & (kSample - 1)) == 0;
    Blk &b = blk();
    b.add(kRdSections, 1);
    for (;;) {
      mshim::Obj h;
      const uint64_t t0 = timed ? meg_mono_ns() : 0;
      const int rc = api_->read_start(id, &h);
      if (rc != 0) megalon_fatal("ObjectReadStart(" + hex(id) + ") = " + std::to_string(rc));
      if (off + len > h.size) megalon_fatal("read beyond object " + hex(id));
      const uint64_t t1 = timed ? meg_mono_ns() : 0;
      t_open = true;
      if constexpr (std::is_void_v<R>) {
        f(static_cast<const uint8_t *>(h.ptr + off));
        t_open = false;
        const uint64_t t2 = timed ? meg_mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed && ok) b.timed_read(t0, t1, t2, meg_mono_ns());
        if (ok) return;
      } else {
        R r = f(static_cast<const uint8_t *>(h.ptr + off));
        t_open = false;
        const uint64_t t2 = timed ? meg_mono_ns() : 0;
        const bool ok = api_->read_end(&h);
        if (timed && ok) b.timed_read(t0, t1, t2, meg_mono_ns());
        if (ok) return r;
      }
      b.add(kRdRetries, 1);
    }
  }
  void read_copy(uint64_t id, uint64_t off, uint64_t len, uint8_t *dst) const {
    section_read(id, off, len, [&](const uint8_t *src) { std::memcpy(dst, src, len); });
  }
  void copy_out(const Loc &L, uint8_t *dst) const {
    uint64_t o = 0;
    for (uint32_t i = 0; i < L.n; i++) read_copy(L.p[i].id, L.p[i].off, L.p[i].len, dst + o), o += L.p[i].len;
    Blk &b = blk();
    b.add(kAdjCopies, 1), b.add(kAdjCopyBytes, L.bytes);
    if (L.n > 1) b.add(kSplit, 1);
  }
  // after f ran on a copy of list L (version v0 in the copy): re-check the version word when f made nested reads or
  // the copy took two sections
  bool validated(const Loc &L, uint64_t v0, uint64_t reads_before) const {
    if (L.n == 1 && t_reads == reads_before) return true;
    Blk &b = blk();
    b.add(kAdjValidations, 1);
    uint64_t v1;
    read_copy(L.p[0].id, L.p[0].off + kVerOff, 8, reinterpret_cast<uint8_t *>(&v1));
    if (v1 == v0) return true;
    b.add(kAdjValidationFails, 1);
    return false;
  }
  // One write section writing [off, off + len) of object id from src (whole lines, or up to the object's end).
  void write_section(uint64_t id, uint64_t off, uint64_t len, const uint8_t *src) const {
    if (t_open) megalon_fatal("write section inside a read section");
    mshim::Obj h;
    const uint64_t t0 = meg_mono_ns();
    const int rc = api_->write_start(id, &h);
    if (rc != 0) megalon_fatal("ObjectWriteStart(" + hex(id) + ") = " + std::to_string(rc));
    if (off % kLine || off + len > h.size || (len % kLine && off + len != h.size))
      megalon_fatal("write of [" + std::to_string(off) + ", +" + std::to_string(len) + ") in object " + hex(id) +
                    " (size " + std::to_string(h.size) + ") is not whole lines");
    const uint64_t t1 = meg_mono_ns();
    std::memcpy(h.ptr + off, src, len);
    const uint64_t t2 = meg_mono_ns();
    api_->write_end(&h);
    Blk &b = blk();
    b.add(kWrSections, 1), b.add(kWrStartNs, t1 - t0), b.add(kWrBodyNs, t2 - t1), b.add(kWrEndNs, meg_mono_ns() - t2);
  }
  // write [lo, hi) of record L from rec (record offsets); split records: header line with the writing bit first
  // (mark, unless the record was marked by a nested write already), then the second part, then the first
  void publish(const Loc &L, const uint8_t *rec, const uint8_t *orig, uint64_t lo, uint64_t hi, bool mark_split) const {
    if (L.n == 2 && mark_split) mark(L, orig);
    for (int i = int(L.n) - 1; i >= 0; i--) {
      const uint64_t base = i == 0 ? 0 : L.p[0].len, a = std::max(lo, base), e = std::min(hi, base + L.p[i].len);
      if (a < e) write_section(L.p[i].id, L.p[i].off + (a - base), e - a, rec + a);
    }
  }
  void mark(const Loc &L, const uint8_t *orig) const {
    uint8_t line[kLine];
    std::memcpy(line, orig, kLine);
    uint64_t v;
    std::memcpy(&v, line + kVerOff, 8);
    v |= 1ull << 63;  // graph_ops.h kWriting
    std::memcpy(line + kVerOff, &v, 8);
    write_section(L.p[0].id, L.p[0].off, kLine, line);
    blk().add(kMarks, 1);
  }
  // before a nested write publishes: every enclosing record with a version word not yet marked gets its header line
  // published with the writing bit (from that record's pre-write copy)
  void mark_parents() const {
    for (size_t d = 0; d < t_wstack.size(); d++) {
      Pending &p = t_wstack[d];
      if (p.marked || !has_version(p.kind)) continue;
      mark(p.L, tbuf(kWBuf + 2 * d + 1).data());
      p.marked = true;
    }
  }
  static std::string hex(uint64_t x) {
    char b[24];
    std::snprintf(b, sizeof(b), "%#lx", (unsigned long)x);
    return b;
  }

  // ---- per-thread state
  struct Pending {
    Loc L;
    ObjKind kind;
    bool marked;
  };
  static constexpr int kWBuf = 8;  // thread buffers: [0, kWBuf) list read copies by nesting depth, then 2 per write
  static constexpr size_t kWDepth = 16;
  static std::vector<uint8_t> &tbuf(size_t i) {  // fixed size: references stay valid across nested calls
    thread_local std::vector<std::vector<uint8_t>> b(kWBuf + 2 * kWDepth);
    if (i >= b.size()) megalon_fatal("write nesting too deep");
    if (i == kWBuf - 1) megalon_fatal("read nesting too deep");
    return b[i];
  }
  static inline thread_local uint64_t t_reads = 0;
  static inline thread_local uint32_t t_rdepth = 0;
  static inline thread_local bool t_open = false;
  static inline thread_local std::vector<Pending> t_wstack;

  enum : int { kRdSections, kRdSampled, kRdStartNs, kRdBodyNs, kRdEndNs, kRdRetries, kWrSections, kWrStartNs, kWrBodyNs,
               kWrEndNs, kWrSkipped, kAdjCopies, kAdjCopyBytes, kAdjValidations, kAdjValidationFails, kMarks, kSplit, kN };
  enum : int { kRoleMain, kRoleWriter, kRoleQuery, kRoleOther, kRoles };
  struct alignas(64) Blk {  // owner-only relaxed load + store (no shared cache-line writes on the read path)
    std::atomic<uint64_t> v[kN] = {};
    std::atomic<int> role{kRoleOther};
    void add(int k, uint64_t d) { v[k].store(v[k].load(std::memory_order_relaxed) + d, std::memory_order_relaxed); }
    void timed_read(uint64_t t0, uint64_t t1, uint64_t t2, uint64_t t3) {
      add(kRdSampled, 1), add(kRdStartNs, t1 - t0), add(kRdBodyNs, t2 - t1), add(kRdEndNs, t3 - t2);
    }
  };
  Blk &blk() const {  // a process has one backend
    thread_local Blk *mine = nullptr;
    if (!mine) {
      mine = new Blk;  // lives as long as the process
      std::lock_guard<std::mutex> g(mu_);
      blks_.push_back(mine);
    }
    return *mine;
  }

  const mshim::Api *api_;
  MegLayout lay_;
  uint64_t cb_;
  uint32_t node_;
  std::vector<uint8_t> meta_;            // private copy of image bytes [0, adj_index_off + adj_index_bytes)
  const uint64_t *adj_index_ = nullptr;  // into meta_
  std::vector<ChunkRef> chunks_;         // chunk layout: every chunk of for_each_chunk (global chunk number order)
  uint64_t objects_ = 0;
  MegSizing sizing_;
  mutable std::vector<Blk *> blks_;
  mutable std::mutex mu_;
};

// The two granularities as separate types (stats "backend=" names; Server<Be> is instantiated per type).
template <MegLayout L>
class MegalonBackend : public MegalonBackendBase {
 public:
  static constexpr const char *kName = L == MegLayout::kRecord ? "megalon-record" : "megalon-chunk";
  static constexpr bool kMegalon = true;
  MegalonBackend(const mshim::Api *api, uint64_t chunk_bytes, uint32_t node) : MegalonBackendBase(api, L, chunk_bytes, node) {}
};
using MegalonRecordBackend = MegalonBackend<MegLayout::kRecord>;
using MegalonChunkBackend = MegalonBackend<MegLayout::kChunk>;

}  // namespace sg

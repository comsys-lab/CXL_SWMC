// Plain-mmap backend (backend.h): the graph image is read and written in place through the process's mapping of the
// region (All HWcc, Popcorn, De Stijl; the coherence system is the kernel / hardware underneath). No coherence actions
// besides write ownership: before a writer reads a record it is about to modify, every 4 KiB page of the record gets an
// atomic no-op RMW (lock or 0), so a page-coherence system takes the write fault (and fetches the current page) before
// the writer reads any byte of it (a read first could hit a stale De Stijl replica).
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

#include "backend.h"
#include "layout.h"

namespace sg {

class MmapBackend {
 public:
  static constexpr const char *kName = "plain";
  // base: first byte of the image in this process (region map + swcc offset + image offset); avail: bytes available
  // there. attach() validates the header; the server refuses to run on false.
  MmapBackend(uint8_t *base, uint64_t avail) : base_(base), avail_(avail), v_(base) {}
  bool attach(std::string *err) {
    if (avail_ < sizeof(ImageHeader)) { *err = "image range smaller than the header"; return false; }
    const ImageHeader &h = *reinterpret_cast<const ImageHeader *>(base_);
    if (h.total_bytes > avail_) {
      *err = "image (" + std::to_string(h.total_bytes) + " B) does not fit the range (" + std::to_string(avail_) + " B)";
      return false;
    }
    std::string e = check_header(h, h.total_bytes);
    if (!e.empty()) { *err = "image header: " + e; return false; }
    return true;
  }
  const ImageHeader &header() const { return *v_.h; }
  const View &view() const { return v_; }
  bool has_adj(uint64_t slot) const { return slot < v_.h->n_orig && v_.adj_index()[slot] != kNoAdj; }
  uint64_t adj_off(uint64_t slot) const { return v_.adj_index()[slot]; }
  void thread_init(int) const {}

  uint8_t *rec(ObjKind k, uint64_t idx) const {
    switch (k) {
      case ObjKind::kNode: return reinterpret_cast<uint8_t *>(v_.node(idx));
      case ObjKind::kAdj: return reinterpret_cast<uint8_t *>(v_.adj(idx));
      case ObjKind::kOvf: return reinterpret_cast<uint8_t *>(v_.ovf(idx));
      default: return nullptr;
    }
  }
  uint64_t rec_bytes(ObjKind k, uint64_t idx) const {
    switch (k) {
      case ObjKind::kNode: return sizeof(NodeSlot);
      case ObjKind::kAdj: return v_.primary_block_bytes(idx);
      case ObjKind::kOvf: return kPage;
      default: return 0;
    }
  }
  template <class F> auto read(ObjKind k, uint64_t idx, F f) const { return f(static_cast<const uint8_t *>(rec(k, idx))); }
  template <class F> void write(ObjKind k, uint64_t idx, F f) const {
    uint8_t *p = rec(k, idx);
    own(p, rec_bytes(k, idx));
    f(p);
  }
  template <class F> void write_range(ObjKind k, uint64_t idx, uint64_t off, uint64_t len, F f) const {
    uint8_t *p = rec(k, idx);
    own(p + off, len);
    f(p);
  }
  // De Stijl staleness range (whole image, page aligned: the image starts on a page and is a page multiple)
  uint8_t *image_base() const { return base_; }
  uint64_t image_bytes() const { return v_.h->total_bytes; }
  std::string usage() const {
    return std::string(kName) + " image_bytes=" + std::to_string(v_.h->total_bytes) + " nodes=" +
           std::to_string(v_.h->n_nodes()) + " ovf_blocks=" + std::to_string(v_.h->ovf_blocks());
  }
  std::string stats() const { return ""; }

  // Atomic no-op RMW on one aligned word in every 4 KiB page that [p, p + len) touches (the word lies inside the range:
  // p and page starts are 8 B aligned for every record and sub-range the server writes).
  static void own(uint8_t *p, uint64_t len) {
    if (!len) return;
    uint64_t a = reinterpret_cast<uint64_t>(p) & ~7ull;
    const uint64_t end = reinterpret_cast<uint64_t>(p) + len;
    for (;;) {
      __atomic_fetch_or(reinterpret_cast<uint64_t *>(a), uint64_t(0), __ATOMIC_ACQ_REL);
      const uint64_t next = (a | (kPage - 1)) + 1;
      if (next >= end) break;
      a = next;
    }
  }

 private:
  uint8_t *base_;
  uint64_t avail_;
  View v_;
};

}  // namespace sg

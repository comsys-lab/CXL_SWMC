// contend: data invariant, checker, samplers and histograms for `faultlat contend` (header-only, no deps).
//
// Page format (4 KiB = 512 words of 8 bytes).  A write op by writer w with its seq s (per-writer, strictly
// increasing over all its writes) stores, in ASCENDING word order 0..511,
//     word[i] = stamp(w, s) ^ mask(salt, page, i)
// where stamp = check16(w, s) << 48 | w << 36 | s (writer 12 bits, seq 36 bits).  An 8-byte aligned store is single-copy atomic on x86, so
// every word always decodes to exactly one write; whole pages may legitimately mix writes (concurrent
// unsynchronised writers, a page taken away mid-write), so mixing is never a violation by itself.
//
// A read op loads the words in DESCENDING order 511..0.  With x86-TSO (stores become visible in program order,
// loads are not reordered with older loads) and coherence, the following hold on a correct system:
//  (A) intra-scan: if the scan saw (w, s) at word j, every word i < j (read later) holds a write by w with
//      seq >= s, or a write by another writer.  Violation: w's seq < s at a lower word ("stale_intra").
//  (B) cross-scan, word 511: (w, s) seen at word 511 means op s wrote the whole page, so in every later scan by
//      the same thread every word holds w's seq >= s or another writer ("stale_cross").
//  (C) cross-scan, word 0: (w, s) seen anywhere means op s wrote word 0, so in every later scan word 0 holds w's
//      seq >= s or another writer ("stale_cross").
//  (D) own writes: after the thread's own write s on page p, every later scan of p holds own seq >= s or
//      another writer at every word (as B).
//  (E) final: after all writers stopped, each word holds the LAST write of some writer to that page
//      (coherence-last write of a word is its writer's last write of it): (w, s) with s == last_seq[w][p],
//      or the init stamp only if no writer wrote p at all ("final_stale", "final_init_left").
//  (F) every word decodes (check bits, writer id in range; optionally seq <= a known max): catches a wrong
//      pfn / offset mapped, zeroed or foreign data, torn 8-byte words ("corrupt").
// The masks include the absolute page number and word index, so data from another page or offset never
// decodes (probability 2^-16 per word).
//
// Limitation (documented in the packet): on a hardware-coherent testbed (QEMU NVDIMM backed by Host RAM) a
// missing invalidation does not change the data a node reads, so (A)-(E) only catch protocol bugs that change
// data (wrong mapping, copying, stale write-back, zeroing).  The SWMR probe (T = 1 per node) catches a missing
// invalidation directly: a page this thread had mapped (no fault since its last scan of that page) must not
// change under it because of a remote write.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace contend {

constexpr uint64_t kWords = 512;            // 8-byte words per 4 KiB page
constexpr uint32_t kInitWriter = 4095;      // writer id of the initial stamp (seq 0)
constexpr uint32_t kMaxWriters = 4095;      // real writers are 0..4094 (node * threads + thread)
constexpr int kSeqBits = 36;
constexpr uint64_t kSeqMask = (1ull << kSeqBits) - 1;

inline uint64_t splitmix(uint64_t x) {
  x += 0x9e3779b97f4a7c15ull;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}
inline uint64_t page_mask(uint64_t salt, uint64_t page_abs) { return splitmix(salt ^ splitmix(page_abs)); }
inline uint64_t word_mask(uint64_t pmask, uint64_t i) { return pmask ^ ((i + 1) * 0xd6e8feb86659fd93ull); }
inline uint16_t check16(uint32_t w, uint64_t s) {
  return uint16_t(splitmix((uint64_t(w) << kSeqBits | s) ^ 0x5a17c0de5eedull) >> 48);
}
inline uint64_t make_stamp(uint32_t w, uint64_t s) {
  return uint64_t(check16(w, s)) << 48 | uint64_t(w & 0xfff) << kSeqBits | (s & kSeqMask);
}
struct Decoded {
  bool ok;
  uint32_t w;
  uint64_t s;
};
inline Decoded decode(uint64_t stamp) {
  Decoded d{false, uint32_t(stamp >> kSeqBits) & 0xfff, stamp & kSeqMask};
  d.ok = uint16_t(stamp >> 48) == check16(d.w, d.s);
  return d;
}

// Writes one page in ascending word order (volatile: one 8-byte store per word, in program order).
inline void write_page(volatile uint64_t *page, uint64_t salt, uint64_t page_abs, uint32_t w, uint64_t s) {
  const uint64_t st = make_stamp(w, s), pm = page_mask(salt, page_abs);
  for (uint64_t i = 0; i < kWords; i++) page[i] = st ^ word_mask(pm, i);
}
// Reads one page in descending word order into buf (buf[i] = word i).
inline void read_page(const volatile uint64_t *page, uint64_t *buf) {
  for (uint64_t i = kWords; i-- > 0;) buf[i] = page[i];
}

enum Kind { kCorrupt = 0, kStaleIntra, kStaleCross, kFinalStale, kFinalInitLeft, kUnfaultedRemote, kNumKinds };
inline const char *kind_name(int k) {
  static const char *n[] = {"corrupt", "stale_intra", "stale_cross", "final_stale", "final_init_left",
                            "unfaulted_remote_change"};
  return n[k];
}

struct Violation {
  int kind;
  uint64_t page_abs, word, raw;
  uint32_t w;
  uint64_t s, expected;  // expected: floor (stale_*) or last seq (final_*)
  std::string str() const {
    char b[200];
    snprintf(b, sizeof(b), "%s page %llu word %llu raw %#llx writer %u seq %llu expected %llu", kind_name(kind),
             (unsigned long long)page_abs, (unsigned long long)word, (unsigned long long)raw, w,
             (unsigned long long)s, (unsigned long long)expected);
    return b;
  }
};

// Collects counts by kind and the first few details.
struct Violations {
  uint64_t count[kNumKinds] = {};
  std::vector<Violation> first;
  size_t keep = 16;
  uint64_t total() const {
    uint64_t t = 0;
    for (uint64_t c : count) t += c;
    return t;
  }
  void add(const Violation &v) {
    count[v.kind]++;
    if (first.size() < keep) first.push_back(v);
  }
};

// Per-thread checker state: floors per (page, writer).  nwriters real writers; index nwriters = init stamp.
class Checker {
 public:
  Checker(uint64_t pages, uint32_t nwriters)
      : pages_(pages), nw_(nwriters), W_(nwriters + 1), all_(pages * W_, 0), w0_(pages * W_, 0), run_(W_) {}

  // Writer index for a decoded writer id, or -1 if out of range.
  int widx(uint32_t w) const { return w == kInitWriter ? int(nw_) : (w < nw_ ? int(w) : -1); }

  // Checks a scan (buf[i] = word i, read in descending order).  page = index within the hot set.
  // max_seq (optional, per writer index): seq above it = corrupt.  Returns the number of violations added.
  uint64_t check_scan(const uint64_t *buf, uint64_t page, uint64_t page_abs, uint64_t salt, Violations *out,
                      const uint64_t *max_seq = nullptr) {
    const uint64_t before = out->total(), pm = page_mask(salt, page_abs);
    uint64_t *all = &all_[page * W_], *w0 = &w0_[page * W_];
    std::copy(all, all + W_, run_.begin());
    int top_w = -1;     // writer index and seq at word 511 (applies to all words in later scans)
    uint64_t top_s = 0;
    for (uint64_t i = kWords; i-- > 0;) {
      const uint64_t raw = buf[i], st = raw ^ word_mask(pm, i);
      Decoded d = decode(st);
      int wi = d.ok ? widx(d.w) : -1;
      if (wi < 0 || (d.w == kInitWriter && d.s != 0) || (max_seq && wi < int(nw_) && d.s > max_seq[wi])) {
        out->add({kCorrupt, page_abs, i, raw, d.w, d.s, 0});
        continue;
      }
      if (d.s < run_[wi]) out->add({kStaleIntra, page_abs, i, raw, d.w, d.s, run_[wi]});
      if (i == 0 && d.s < w0[wi]) out->add({kStaleCross, page_abs, i, raw, d.w, d.s, w0[wi]});
      if (d.s > run_[wi]) run_[wi] = d.s;
      if (i == kWords - 1) { top_w = wi; top_s = d.s; }
    }
    // Carry floors to later scans: (C) max seen anywhere -> word 0; (B) word 511 -> all words.
    for (uint32_t k = 0; k < W_; k++) w0[k] = std::max(w0[k], run_[k]);
    if (top_w >= 0) all[top_w] = std::max(all[top_w], top_s);
    return out->total() - before;
  }
  // (D) the thread's own write s by writer index wi on page.
  void own_write(uint64_t page, uint32_t wi, uint64_t s) {
    uint64_t *all = &all_[page * W_], *w0 = &w0_[page * W_];
    all[wi] = std::max(all[wi], s);
    w0[wi] = std::max(w0[wi], s);
  }
  uint32_t nwriters() const { return nw_; }

 private:
  uint64_t pages_;
  uint32_t nw_, W_;
  std::vector<uint64_t> all_, w0_, run_;
};

// (E) final check of one page.  last(wi) = writer wi's last seq written on this page (0 = never wrote it).
template <class LastSeq>
uint64_t final_check(const uint64_t *buf, uint64_t page_abs, uint64_t salt, uint32_t nwriters, LastSeq last,
                     Violations *out) {
  const uint64_t before = out->total(), pm = page_mask(salt, page_abs);
  bool written = false;
  for (uint32_t k = 0; k < nwriters; k++) written |= last(k) != 0;
  for (uint64_t i = 0; i < kWords; i++) {
    const uint64_t raw = buf[i];
    Decoded d = decode(raw ^ word_mask(pm, i));
    if (!d.ok || (d.w != kInitWriter && d.w >= nwriters) || (d.w == kInitWriter && d.s != 0)) {
      out->add({kCorrupt, page_abs, i, raw, d.w, d.s, 0});
    } else if (d.w == kInitWriter) {
      if (written) out->add({kFinalInitLeft, page_abs, i, raw, d.w, d.s, 0});
    } else if (d.s != last(d.w)) {
      out->add({kFinalStale, page_abs, i, raw, d.w, d.s, last(d.w)});
    }
  }
  return out->total() - before;
}

// SWMR probe (T = 1 per node): snapshot per page after each FAULT-FREE scan of this thread; a later scan that
// took no fault (RUSAGE_THREAD minflt delta 0) means the page stayed mapped since the snapshot, so no word may
// have changed to a write by another node.  A faulted scan or an own write drops the snapshot.
class SwmrProbe {
 public:
  SwmrProbe(uint64_t pages, uint32_t threads, uint32_t node)
      : snap_(pages * kWords), valid_(pages, false), T_(threads), node_(node) {}
  // Returns violations added.  faulted = the scan took at least one fault.
  uint64_t scan(const uint64_t *buf, uint64_t page, uint64_t page_abs, uint64_t salt, bool faulted,
                Violations *out) {
    const uint64_t before = out->total();
    uint64_t *s = &snap_[page * kWords];
    if (valid_[page] && !faulted) {
      checks++;
      const uint64_t pm = page_mask(salt, page_abs);
      for (uint64_t i = 0; i < kWords; i++) {
        if (buf[i] == s[i]) continue;
        Decoded d = decode(buf[i] ^ word_mask(pm, i));
        if (d.w != kInitWriter && d.w / T_ != node_) out->add({kUnfaultedRemote, page_abs, i, buf[i], d.w, d.s, 0});
      }
    }
    if (faulted) {
      // A scan that faulted may mix words from before and after a mid-scan revocation: never a reference.
      faulted_scans++;
      valid_[page] = false;
    } else {
      std::memcpy(s, buf, kWords * 8);  // fault-free scan: the page stayed mapped, a stable snapshot
      valid_[page] = true;
    }
    return out->total() - before;
  }
  void own_write(uint64_t page) { valid_[page] = false; }
  uint64_t checks = 0, faulted_scans = 0;

 private:
  std::vector<uint64_t> snap_;
  std::vector<bool> valid_;
  uint32_t T_, node_;
};

// Page pickers.  Zipf over ranks 0..n-1 (rank 0 hottest = hot-set page 0), theta in (0, 3).
class Picker {
 public:
  Picker(uint64_t n, bool zipf, double theta) : n_(n), zipf_(zipf && n > 1) {
    if (!zipf_) return;
    cdf_.resize(n);
    double sum = 0;
    for (uint64_t k = 0; k < n; k++) sum += 1.0 / std::pow(double(k + 1), theta);
    double acc = 0;
    for (uint64_t k = 0; k < n; k++) {
      acc += 1.0 / std::pow(double(k + 1), theta) / sum;
      cdf_[k] = acc;
    }
    cdf_[n - 1] = 1.0;
  }
  // r: uniform 64-bit random value.
  uint64_t pick(uint64_t r) const {
    if (!zipf_) return n_ == 1 ? 0 : r % n_;
    double u = double(r >> 11) * (1.0 / 9007199254740992.0);
    return uint64_t(std::upper_bound(cdf_.begin(), cdf_.end(), u) - cdf_.begin()) % n_;
  }

 private:
  uint64_t n_;
  bool zipf_;
  std::vector<double> cdf_;
};

// Log-linear latency histogram: values < 16 exact, then 8 buckets per power of two (<= 12.5 % wide).
// Single writer (its thread); other threads may read it racily (relaxed loads) for watchdog reports.
struct Hist {
  static constexpr int kBuckets = 16 + 60 * 8;
  uint64_t b[kBuckets] = {};
  uint64_t n = 0, sum = 0, max = 0;
  static int index(uint64_t x) {
    if (x < 16) return int(x);
    int e = 63 - __builtin_clzll(x);
    return 16 + (e - 4) * 8 + int((x >> (e - 3)) & 7);
  }
  static uint64_t upper(int idx) {  // largest value in the bucket
    if (idx < 16) return uint64_t(idx);
    int e = (idx - 16) / 8 + 4, sub = (idx - 16) % 8;
    uint64_t lo = uint64_t(8 + sub) << (e - 3);
    return lo + (uint64_t(1) << (e - 3)) - 1;
  }
  void add(uint64_t x) {
    int i = index(x);
    __atomic_store_n(&b[i], __atomic_load_n(&b[i], __ATOMIC_RELAXED) + 1, __ATOMIC_RELAXED);
    __atomic_store_n(&n, n + 1, __ATOMIC_RELAXED);
    sum += x;
    if (x > max) __atomic_store_n(&max, x, __ATOMIC_RELAXED);
  }
  void merge(const Hist &o) {
    for (int i = 0; i < kBuckets; i++) b[i] += __atomic_load_n(&o.b[i], __ATOMIC_RELAXED);
    n += __atomic_load_n(&o.n, __ATOMIC_RELAXED);
    sum += o.sum;
    max = std::max(max, __atomic_load_n(&o.max, __ATOMIC_RELAXED));
  }
  // Upper bound of the bucket holding the p-quantile (conservative; exact max reported separately).
  uint64_t quantile(double p) const {
    if (!n) return 0;
    uint64_t want = uint64_t(std::ceil(p * double(n)));
    if (want < 1) want = 1;
    uint64_t acc = 0;
    for (int i = 0; i < kBuckets; i++) {
      acc += b[i];
      if (acc >= want) return std::min(upper(i), max);
    }
    return max;
  }
};

}  // namespace contend

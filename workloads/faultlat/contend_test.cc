// Unit tests for contend.h (Host only, no device).  Build/run: make test
#include "contend.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>

using namespace contend;

static int failures = 0;
#define EXPECT(c)                                                     \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);    \
      failures++;                                                     \
    }                                                                 \
  } while (0)

constexpr uint64_t kSalt = 0x1234, kPage = 77;

// Page whose words [0, split) come from (w_lo, s_lo) and [split, 512) from (w_hi, s_hi).
static void mixed(uint64_t *buf, uint64_t page_abs, uint32_t w_lo, uint64_t s_lo, uint32_t w_hi, uint64_t s_hi,
                  uint64_t split) {
  const uint64_t pm = page_mask(kSalt, page_abs);
  for (uint64_t i = 0; i < kWords; i++)
    buf[i] = (i < split ? make_stamp(w_lo, s_lo) : make_stamp(w_hi, s_hi)) ^ word_mask(pm, i);
}
static void whole(uint64_t *buf, uint64_t page_abs, uint32_t w, uint64_t s) { mixed(buf, page_abs, w, s, w, s, 0); }

int main() {
  uint64_t buf[kWords];
  // stamps
  for (uint32_t w : {0u, 1u, 129u, 4094u, kInitWriter})
    for (uint64_t s : {uint64_t(0), uint64_t(1), uint64_t(12345), kSeqMask}) {
      Decoded d = decode(make_stamp(w, s));
      EXPECT(d.ok && d.w == w && d.s == s);
    }
  EXPECT(!decode(0).ok || decode(0).w == 0);  // zero word: only valid if check16(0,0) == 0 (it is not)
  EXPECT(!decode(0).ok);

  {  // consistent page and own writes
    Checker c(4, 4);
    Violations v;
    whole(buf, kPage, 2, 10);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) == 0);
    // legal: a newer write by w3 in progress (low words new, high words old w2)
    mixed(buf, kPage, 3, 5, 2, 10, 100);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) == 0);
    // legal: the same writer's newer write in progress (low words seq 11, high words seq 10)
    mixed(buf, kPage, 2, 11, 2, 10, 300);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) == 0);
    EXPECT(v.total() == 0);
  }
  {  // (A) intra-scan: high words newer than low words of the same writer = stale
    Checker c(1, 4);
    Violations v;
    mixed(buf, kPage, 1, 4, 1, 9, 256);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) > 0);
    EXPECT(v.count[kStaleIntra] == 256);
  }
  {  // (B) word 511 floor carries to all words of later scans
    Checker c(1, 4);
    Violations v;
    whole(buf, kPage, 1, 9);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) == 0);
    mixed(buf, kPage, 0, 3, 1, 8, 10);  // words >= 10: writer 1 seq 8 < 9
    c.check_scan(buf, 0, kPage, kSalt, &v);
    EXPECT(v.count[kStaleIntra] == 502);
  }
  {  // (C) seq seen anywhere carries to word 0 of later scans; other words may lag
    Checker c(1, 4);
    Violations v;
    mixed(buf, kPage, 1, 9, 1, 8, 50);  // word 0..49 seq 9: legal (newer write in progress)
    EXPECT(c.check_scan(buf, 0, kPage, kSalt, &v) == 0);
    mixed(buf, kPage, 1, 8, 2, 3, 1);  // word 0 back to seq 8 -> stale_cross; words 1.. other writer: fine
    c.check_scan(buf, 0, kPage, kSalt, &v);
    EXPECT(v.count[kStaleCross] == 1 && v.count[kStaleIntra] == 0);
    mixed(buf, kPage, 2, 4, 1, 8, 1);  // word 0 other writer, word 1.. seq 8: legal (only word 0 is pinned)
    Violations v2;
    c.check_scan(buf, 0, kPage, kSalt, &v2);
    EXPECT(v2.total() == 0);
  }
  {  // (D) own write floor
    Checker c(2, 4);
    Violations v;
    c.own_write(1, 3, 20);
    whole(buf, kPage + 1, 3, 19);
    c.check_scan(buf, 1, kPage + 1, kSalt, &v);
    EXPECT(v.count[kStaleIntra] == kWords);
    Violations v2;
    whole(buf, kPage + 1, 0, 1);  // overwritten by another writer: fine
    EXPECT(c.check_scan(buf, 1, kPage + 1, kSalt, &v2) == 0);
  }
  {  // (F) corrupt: wrong page, wrong word, garbage, writer out of range, init with seq != 0
    Checker c(1, 4);
    Violations v;
    whole(buf, kPage + 1, 1, 5);  // data of page 78 seen at page 77
    c.check_scan(buf, 0, kPage, kSalt, &v);
    EXPECT(v.count[kCorrupt] >= kWords - 2);
    Violations v2;
    whole(buf, kPage, 1, 5);
    std::swap(buf[3], buf[4]);
    buf[9] = 0;
    c.check_scan(buf, 0, kPage, kSalt, &v2);
    EXPECT(v2.count[kCorrupt] == 3);
    Violations v3;
    whole(buf, kPage, 7, 5);  // writer 7 >= nwriters 4
    c.check_scan(buf, 0, kPage, kSalt, &v3);
    EXPECT(v3.count[kCorrupt] == kWords);
    Violations v4;
    whole(buf, kPage, kInitWriter, 3);
    c.check_scan(buf, 0, kPage, kSalt, &v4);
    EXPECT(v4.count[kCorrupt] == kWords);
    Violations v5;
    whole(buf, kPage, 1, 5);
    EXPECT(c.check_scan(buf, 0, kPage, kSalt ^ 1, &v5) > 0);  // other salt (previous run's data)
  }
  {  // (E) final check
    std::map<uint32_t, uint64_t> last = {{0, 7}, {1, 0}, {2, 3}};
    auto L = [&](uint32_t w) { return last.count(w) ? last[w] : 0; };
    Violations v;
    mixed(buf, kPage, 0, 7, 2, 3, 200);
    EXPECT(final_check(buf, kPage, kSalt, 3, L, &v) == 0);
    mixed(buf, kPage, 0, 6, 2, 3, 200);  // writer 0's last write was 7: 200 words lost
    final_check(buf, kPage, kSalt, 3, L, &v);
    EXPECT(v.count[kFinalStale] == 200);
    Violations v2;
    whole(buf, kPage, kInitWriter, 0);  // init left though writers wrote
    final_check(buf, kPage, kSalt, 3, L, &v2);
    EXPECT(v2.count[kFinalInitLeft] == kWords);
    Violations v3;
    auto none = [](uint32_t) { return uint64_t(0); };
    EXPECT(final_check(buf, kPage, kSalt, 3, none, &v3) == 0);  // nobody wrote: init is right
  }
  {  // SWMR probe: change without a fault by a remote writer = violation; with a fault or local = fine
    SwmrProbe p(1, 1, 0);  // T=1, this node 0 (writer 0); remote writer 1
    Violations v;
    whole(buf, kPage, 0, 1);
    p.scan(buf, 0, kPage, kSalt, true, &v);
    whole(buf, kPage, 1, 1);
    p.scan(buf, 0, kPage, kSalt, true, &v);   // faulted: fine (remote change seen through a fault)
    p.scan(buf, 0, kPage, kSalt, false, &v);  // fault-free: snapshot
    EXPECT(v.total() == 0);
    whole(buf, kPage, 1, 2);
    p.scan(buf, 0, kPage, kSalt, false, &v);  // no fault, remote change
    EXPECT(v.count[kUnfaultedRemote] == kWords);
    Violations v2;
    p.own_write(0);
    whole(buf, kPage, 0, 9);
    p.scan(buf, 0, kPage, kSalt, false, &v2);  // snapshot invalidated by own write
    EXPECT(v2.total() == 0 && p.checks == 1);
  }
  {  // a faulted scan mixing old and new words is never a reference (verifier HIGH, v1)
    SwmrProbe p(1, 1, 0);
    Violations v;
    whole(buf, kPage, 1, 1);
    p.scan(buf, 0, kPage, kSalt, false, &v);    // fault-free snapshot: remote seq 1
    mixed(buf, kPage, 1, 1, 1, 2, 256);          // revoked mid-scan: high words new (2), low words old (1)
    p.scan(buf, 0, kPage, kSalt, true, &v);     // faulted: no check, snapshot dropped
    whole(buf, kPage, 1, 2);                     // next scan fault-free, all words new
    p.scan(buf, 0, kPage, kSalt, false, &v);    // no reference -> no check, becomes the snapshot
    EXPECT(v.total() == 0 && p.checks == 0 && p.faulted_scans == 1);
    p.scan(buf, 0, kPage, kSalt, false, &v);    // unchanged, fault-free: checked, fine
    EXPECT(v.total() == 0 && p.checks == 1);
  }
  {  // pickers
    Picker u(16, false, 0), z(1024, true, 0.99), one(1, true, 0.99);
    std::mt19937_64 r(1);
    std::vector<uint64_t> cu(16), cz(1024);
    for (int i = 0; i < 200000; i++) {
      cu[u.pick(r())]++;
      cz[z.pick(r())]++;
      EXPECT(one.pick(r()) == 0);
    }
    for (uint64_t c : cu) EXPECT(c > 11000 && c < 14000);
    EXPECT(cz[0] > cz[1] && cz[1] > cz[10] && cz[10] > cz[500]);
    EXPECT(cz[0] > 200000 / 10);  // zipf 0.99 over 1024: top page ~ 13 %
  }
  {  // histogram
    Hist h;
    for (uint64_t x = 1; x <= 1000; x++) h.add(x * 1000);
    EXPECT(h.n == 1000 && h.max == 1000000);
    uint64_t p50 = h.quantile(0.5), p99 = h.quantile(0.99);
    EXPECT(p50 >= 500000 && p50 <= 500000 * 1.13);
    EXPECT(p99 >= 990000 && p99 <= 1000000);
    EXPECT(h.quantile(1.0) == 1000000);
    for (int i = 16; i < Hist::kBuckets - 1; i++) EXPECT(Hist::index(Hist::upper(i)) == i);
  }
  if (failures) {
    fprintf(stderr, "contend_test: %d FAILED\n", failures);
    return 1;
  }
  printf("contend_test: all PASS\n");
  return 0;
}

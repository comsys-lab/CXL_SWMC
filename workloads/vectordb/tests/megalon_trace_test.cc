// Unit test (Host, no Megalon, no shared memory): the Megalon wrapper's sharing trace (server/megalon_backend.h,
// DESIGN.md §16) and the per-operation coherence arithmetic (server/opcoh.h) against a fake object API v2 with a fake
// thread_coh. Two backends (node 0, node 1) share an in-memory wsec line. Scenario on vector chunk X (elements =
// slots), node 1 reading:
//   n0 writes slot 5 (seq 1); n1 reads slot 5 (first read: refresh point, seq 1)
//   n0 writes slot 7 (seq 2); n1 reads slot 3 with a stale copy (A) -> event 1, causing write {7}; n1 then reads 4
//   n0 writes slot 9 (seq 3); n1 reads slot 1 with (A) -> event 2, causing write {9}; n1 then reads 9   -> TRUE
//   n1 reads slot 2 while n0 writes slot 2 (seq 4) during the attempt (read_end false, (B)) -> event 3, causing
//   write {2}; the accepted re-read reads 2 -> TRUE.  Event 1 -> FALSE (7 never read before event 2).
//   n0 reads object Y with (A) as its first record -> no_prior_copy.
// The trace files are written to <scratch>/node{0,1}.vdbtrace.bin; tests/classify_sharing_test.py checks the
// classifier on them (expect: true_A 1, false_A 1, true_B 1, no_prior_copy 1).
// usage: megalon_trace_test <scratch dir>; build: tests/build_megalon_trace_test.sh <out>
#include <cstdio>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "backend.h"
#include "megalon_backend.h"
#include "opcoh.h"

using namespace vdb;

namespace {
std::map<uint64_t, std::vector<uint8_t>> g_obj;
std::function<void()> g_fail_once;  // set: the next read_end runs it and fails
bool g_stale_next = false;          // set: the next read_start is a stale copy (A)
thread_local mshim::CohSnap g_snap{};
thread_local mshim::AnchorSnap g_an{};  // fake v3: every write section adds 3 ns lookup + 4 ns NR anchor work
uint64_t g_tok = 0;
int obj(uint64_t id, MegObj *h) {
  auto &b = g_obj[id];
  b.resize(1 << 20);
  *h = MegObj{b.data(), b.size(), id, ++g_tok};
  return 0;
}
int rstart(uint64_t id, MegObj *h) {
  g_snap.read_sections++;
  if (g_stale_next) g_stale_next = false, g_snap.stale_cnt++, g_snap.stale_ns += 100;
  return obj(id, h);
}
const MegalonApi kApi = {mshim::kApiVersion,
                         "fake",
                         [] { return size_t(0); },
                         [](int) {},
                         [] {},
                         [](uint64_t, size_t) { return 0; },
                         [](uint64_t, size_t *s) { return *s = 1 << 20, 0; },
                         rstart,
                         [](MegObj *) {
                           if (!g_fail_once) return true;
                           auto f = std::move(g_fail_once);
                           g_fail_once = nullptr;
                           f();
                           g_snap.concur_cnt++, g_snap.concur_ns += 50;
                           return false;
                         },
                         [](uint64_t id, MegObj *h) {
                           g_an.write_lookup_ns += 3, g_an.write_nr_ns += 4, g_an.wseq_ns += 1;
                           return obj(id, h);
                         },
                         [](MegObj *) { g_snap.wflush_cnt++, g_snap.wflush_ns += 7, g_snap.wflush_bytes += 1 << 20; },
                         [](MegStats *s) { *s = MegStats{}; },
                         [](mshim::CohSnap *s) {
                           *s = g_snap;
                           s->check_sample = 64;
                         },
                         [](mshim::AnchorSnap *s) { *s = g_an; }};

int fails = 0;
#define CHECK(c)                                                                 \
  do {                                                                           \
    if (!(c)) std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c), fails++; \
  } while (0)

std::vector<TraceRec> records(const std::string &path) {
  std::vector<TraceRec> v;
  FILE *f = std::fopen(path.c_str(), "rb");
  TraceFileHdr h;
  if (!f || std::fread(&h, sizeof(h), 1, f) != 1) return v;
  for (uint32_t t = 0; t < h.threads; t++) {
    TraceThreadHdr th;
    if (std::fread(&th, sizeof(th), 1, f) != 1) break;
    for (uint64_t i = 0; i < th.count; i++) {
      TraceRec r;
      if (std::fread(&r, sizeof(r), 1, f) == 1) v.push_back(r);
    }
  }
  std::fclose(f);
  return v;
}
}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) return std::fprintf(stderr, "usage: %s <scratch dir>\n", argv[0]), 2;
  const std::string dir = argv[1];
  Params p;
  p.segments = 1, p.max_ids = 30000, p.max_deletes = 4096, p.dlog_chunk = 4096;
  p.derive();
  cxl::region r;
  std::vector<uint64_t> wsec(8, 0);
  MegalonBackend b0(r, nullptr, p, &kApi), b1(r, nullptr, p, &kApi);
  CHECK(b0.thread_coh() != nullptr);
  b0.set_trace(wsec.data(), 0, 1 << 20, 1000000);
  b1.set_trace(wsec.data(), 1, 1 << 20, 1000000);
  const uint64_t X = MegalonBackend::vec_id(0, 0), Y = MegalonBackend::vec_id(0, 1);
  const uint64_t vr = p.g.vrec_bytes();
  auto rd = [&](const MegalonBackend &b, uint64_t id, uint32_t slot) {
    b.read(id, slot * vr, 64, [](const uint8_t *) {}, Elem{slot, 1});
  };
  auto wr = [&](const MegalonBackend &b, uint64_t id, uint32_t slot) {
    b.write(id, slot * vr, vr, [](uint8_t *) {}, Elem{slot, 1});
  };
  g_stale_next = true;
  rd(b0, Y, 0);      // no prior copy on node 0
  wr(b0, X, 5);      // seq 1
  rd(b1, X, 5);
  wr(b0, X, 7);      // seq 2
  g_stale_next = true;
  rd(b1, X, 3);      // event 1 (A): caused by {7}
  rd(b1, X, 4);
  rd(b1, X, 4);      // identical consecutive read: deduplicated
  wr(b0, X, 9);      // seq 3
  g_stale_next = true;
  rd(b1, X, 1);      // event 2 (A): caused by {9}
  rd(b1, X, 9);      // -> TRUE
  g_fail_once = [&] { wr(b0, X, 2); };  // seq 4 during the attempt
  rd(b1, X, 2);      // event 3 (B): caused by {2}, re-read 2 -> TRUE
  CHECK(wsec[0] == 4);
  std::string err;
  CHECK(b0.dump_trace(dir + "/node0.vdbtrace.bin", &err) && b1.dump_trace(dir + "/node1.vdbtrace.bin", &err));
  const auto r0 = records(dir + "/node0.vdbtrace.bin"), r1 = records(dir + "/node1.vdbtrace.bin");
  CHECK(r0.size() == 5);  // 1 read + 4 writes
  CHECK(r1.size() == 6);  // 5, 3, 4 (one), 1, 9, 2
  if (r1.size() == 6) {
    CHECK(r1[0].type == kTraceRead && r1[0].elem == 5 && r1[0].seq == 1 && r1[0].flags == 0);
    CHECK(r1[1].elem == 3 && r1[1].seq == 2 && r1[1].flags == 1 && r1[1].ev_ns == 100);
    CHECK(r1[2].elem == 4 && r1[3].elem == 1 && r1[3].flags == 1 && r1[3].seq == 3);
    CHECK(r1[5].elem == 2 && r1[5].flags == (1 << 4) && r1[5].seq == 4 && r1[5].ev_ns == 50);
  }
  if (r0.size() == 5) {
    CHECK(r0[0].type == kTraceRead && r0[0].flags == 1);
    CHECK(r0[1].type == kTraceWrite && r0[1].seq == 1 && r0[1].elem == 5 && r0[4].seq == 4 && r0[4].elem == 2);
  }
  // per-operation arithmetic: one section around a write = wflush delta; mod bytes counted by dlog_write
  OpCohSrc src;
  std::string why;
  CHECK(b0.thread_anchor() != nullptr);
  src.setup(true, true, b0.thread_coh(), 1000000, &why, b0.thread_anchor());  // fake Popcorn, fake CohSnap + AnchorSnap
  CHECK(src.thread_start() && src.mg_snap() && src.mg_check_sample() == 64);
  OpCohSrc::Start s;
  OpAcc a;
  src.begin(&s);
  wr(b0, X, 11);
  b0.dlog_write(0, 3, DlogEntry{});
  src.fake_add(1, 1000, 30);
  CHECK(src.end(s, &a));
  const OpCoh blk = op_block(a, kOpUpdate, src.src(), src.mg_snap(), src.tsc_khz(), src.an_snap());
  CHECK(blk.mg_wflush_cnt == 2 && blk.mg_wflush_ns == 14 && blk.mg_wflush_bytes == 2u << 20);
  CHECK(blk.pf_ns[1] == 1000 && blk.pf_cnt[1] == 1 && blk.ipi_ns == 30 && blk.ipi_cnt == 1);
  // two write sections: anchor write lookup 6 + NR 8 added to C; wseq (inside wstart) exported, not added
  CHECK(blk.an_write_lookup_ns == 6 && blk.an_write_nr_ns == 8 && blk.an_wseq_ns == 2);
  CHECK(blk.c_ns == 1000 + 30 + 14 + 6 + 8 && blk.mod_bytes == sizeof(DlogEntry) && blk.sections == 1);
  CHECK(blk.src == (kPopFake | 4 | 8) && blk.mg_check_sample == 64 && blk.t_ns > 0);
  // without a trace: no HWcc access
  MegalonBackend c0(r, nullptr, p, &kApi);
  c0.set_trace(nullptr, 0, 0, 0);
  wr(c0, X, 0);
  rd(c0, X, 0);
  CHECK(!c0.tracing());
  std::fprintf(stderr, "%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
  return fails ? 1 : 0;
}

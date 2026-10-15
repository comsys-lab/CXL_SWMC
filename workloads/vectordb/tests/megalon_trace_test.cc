// Unit test (Host, no Megalon, no shared memory): the Megalon wrapper's refetch trace (server/megalon_backend.h,
// DESIGN.md §13) against a fake object API. Two backends (node 0, node 1) share in-memory wsec/objseq lines.
// Checks that the node cache follows Megalon's per-node local seq (systems/megalon/src/src/core/c3.cc):
//   own write -> no refetch on the next own read (write_seq_end sets the local seq unconditionally),
//   own write after an unseen peer write -> still no refetch,
//   first read of an object on a node (local seq nullopt) -> no refetch,
//   peer write after this node's read -> one refetch (old, new seq),
//   failed read_end with a peer write in between -> the accepted re-read resets the cache (no refetch next time).
// usage: megalon_trace_test <scratch dir>; build: tests/build_megalon_trace_test.sh <out>
#include <cstdio>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "backend.h"
#include "megalon_backend.h"

using namespace vdb;

namespace {
std::map<uint64_t, std::vector<uint8_t>> g_obj;
std::function<void()> g_fail_once;  // set: the next read_end runs it and fails
uint64_t g_tok = 0;
int obj(uint64_t id, MegObj *h) {
  auto &b = g_obj[id];
  b.resize(4096);
  *h = MegObj{b.data(), b.size(), id, ++g_tok};
  return 0;
}
const MegalonApi kApi = {kMegalonApiVersion,
                         "fake",
                         [] { return size_t(0); },
                         [](int) {},
                         [] {},
                         [](uint64_t, size_t) { return 0; },
                         [](uint64_t, size_t *s) { return *s = 4096, 0; },
                         obj,
                         [](MegObj *) {
                           if (!g_fail_once) return true;
                           auto f = std::move(g_fail_once);
                           g_fail_once = nullptr;
                           f();
                           return false;
                         },
                         obj,
                         [](MegObj *) {},
                         [](MegStats *s) { *s = MegStats{}; }};

int fails = 0;
#define CHECK(c)                                                                 \
  do {                                                                           \
    if (!(c)) std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c), fails++; \
  } while (0)

uint64_t stat(const MegalonBackend &b, const std::string &k) {
  std::istringstream in(b.stats());
  std::string line;
  while (std::getline(in, line))
    if (line.compare(0, k.size() + 1, k + "=") == 0) return std::stoull(line.substr(k.size() + 1));
  return ~0ull;
}
std::vector<RetryRec> refetches(const MegalonBackend &b, const std::string &prefix) {
  std::string err;
  if (!b.dump_trace(prefix, &err)) std::fprintf(stderr, "dump: %s\n", err.c_str());
  std::vector<RetryRec> v;
  FILE *f = std::fopen((prefix + ".megalon-refetch.bin").c_str(), "rb");
  RetryRec r;
  while (f && std::fread(&r, sizeof(r), 1, f) == 1) v.push_back(r);
  if (f) std::fclose(f);
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
  std::vector<uint64_t> wsec(8, 0), objseq(p.trace_objects(), 0);
  MegalonBackend b0(r, nullptr, p, &kApi), b1(r, nullptr, p, &kApi);
  b0.set_trace(wsec.data(), objseq.data(), true, 0);
  b1.set_trace(wsec.data(), objseq.data(), true, 1);
  const uint64_t X = MegalonBackend::vec_id(0, 0), Y = MegalonBackend::vec_id(0, 1);
  auto rd = [](const MegalonBackend &b, uint64_t id, uint64_t off) { b.read(id, off, 64, [](const uint8_t *) {}); };
  auto wr = [](const MegalonBackend &b, uint64_t id, uint64_t off) { b.write(id, off, 64, [](uint8_t *) {}); };

  rd(b1, X, 0);                   // nothing written yet
  wr(b0, X, 0);                   // seq 1
  rd(b0, X, 0);                   // own write: no refetch
  CHECK(stat(b0, "megt.trace_refetch") == 0);
  wr(b0, Y, 0);                   // seq 2
  rd(b1, Y, 0);                   // never seen on node 1: first sight, no refetch
  rd(b1, X, 0);                   // first sight of X's seq on node 1 (it read X before any write: local seq none)
  CHECK(stat(b1, "megt.trace_refetch") == 0 && stat(b1, "megt.trace_first_sight") == 2);
  wr(b0, X, 0);                   // seq 3
  rd(b1, X, 128);                 // peer write since node 1 saw seq 1: refetch (1 -> 3)
  CHECK(stat(b1, "megt.trace_refetch") == 1);
  wr(b0, X, 0);                   // seq 4: node 1 has not seen it
  wr(b1, X, 64);                  // seq 5: node 1's own write sets its local seq
  rd(b1, X, 0);                   // no refetch
  rd(b0, X, 0);                   // node 0: peer write 5 -> refetch (4 -> 5)
  CHECK(stat(b1, "megt.trace_refetch") == 1 && stat(b0, "megt.trace_refetch") == 1);
  wr(b0, X, 0);                   // seq 6
  g_fail_once = [&] { wr(b0, X, 0); };  // seq 7 during node 1's read: read_end fails, re-read
  rd(b1, X, 256);                 // refetch (5 -> 6), retry, accepted re-read at 7
  CHECK(stat(b1, "megt.trace_refetch") == 2 && stat(b1, "megt.rd_retries") == 1);
  rd(b1, X, 0);                   // Megalon's local seq is 7 after the re-read: no refetch
  CHECK(stat(b1, "megt.trace_refetch") == 2);
  const auto f1 = refetches(b1, dir + "/node1"), f0 = refetches(b0, dir + "/node0");
  CHECK(f1.size() == 2 && f0.size() == 1);
  if (f1.size() == 2) {
    CHECK(f1[0].id == X && f1[0].off == 128 && f1[0].s0 == 1 && f1[0].s1 == 3);
    CHECK(f1[1].off == 256 && f1[1].s0 == 5 && f1[1].s1 == 6);
  }
  if (f0.size() == 1) CHECK(f0[0].s0 == 4 && f0[0].s1 == 5);
  CHECK(wsec[0] == 7 && objseq[0] == 7);
  // without a trace: no HWcc trace access (the lines stay as they are)
  std::vector<uint64_t> w2(8, 0), o2(p.trace_objects(), 0);
  MegalonBackend c0(r, nullptr, p, &kApi);
  c0.set_trace(nullptr, nullptr, false, 0);
  wr(c0, X, 0);
  rd(c0, X, 0);
  CHECK(stat(c0, "megt.wr_sections") == 1 && stat(c0, "megt.trace_refetch") == 0);
  std::fprintf(stderr, "%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
  return fails ? 1 : 0;
}

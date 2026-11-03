// Host unit test (no shared memory) of the stale-header guard (shm_hnsw.h SearchRejects / search_links_upper,
// layout.h elem_visible; run 2, workspaces/damonx/e0a-crash/FINDINGS.md): a reader that sees a stale copy of a newly
// linked slot (garbage or zeroed header, garbage link block) must not crash, must not return the slot, and must count
// the rejection; a valid graph gives exactly the results of the pre-guard predicate with zero rejects.
// Build: tests/build_stale_header_test.sh <out binary>. Exit 0 = PASS.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "layout.h"
#include "shm_hnsw.h"

using namespace vdb;

static int fails = 0;
#define CHECK(c, ...)                         \
  do {                                        \
    if (!(c)) {                                \
      std::printf("FAIL %s: ", #c);           \
      std::printf(__VA_ARGS__);               \
      std::printf("\n");                      \
      fails++;                                \
    }                                         \
  } while (0)

int main() {
  Params p;
  p.nr_nodes = 2, p.segments = 1, p.max_ids = 4000, p.max_writes = 100000;
  p.g.dim = 16, p.g.M = 8, p.g.ef_construction = 64, p.g.chunk_bytes = 64 << 10;
  p.derive();
  const GraphParams &g = p.g;
  const uint64_t N = g.per_chunk(), vrec = g.vrec_bytes(), l0 = g.links0_bytes();
  std::printf("capacity=%lu per_chunk=%lu groups=%lu vrec=%lu l0=%lu\n", (unsigned long)g.capacity, (unsigned long)N,
              (unsigned long)g.groups(), (unsigned long)vrec, (unsigned long)l0);

  GraphMeta *meta = static_cast<GraphMeta *>(std::aligned_alloc(64, sizeof(GraphMeta)));
  PlainAcc::Mem m{meta, {}, {}};
  std::vector<uint8_t *> vc, lc;
  for (uint64_t x = 0; x < g.groups(); x++) {
    // never-written capacity = "bytes of an earlier experiment" (0xA5 / random), as the device before the fix
    uint8_t *v = static_cast<uint8_t *>(std::aligned_alloc(64, g.vchunk_bytes()));
    uint8_t *l = static_cast<uint8_t *>(std::aligned_alloc(64, (g.lchunk_bytes() + 63) / 64 * 64));
    std::memset(v, 0xA5, g.vchunk_bytes());
    std::memset(l, 0x5A, g.lchunk_bytes());
    vc.push_back(v), lc.push_back(l), m.vec.push_back(v), m.link.push_back(l);
  }
  ShmHnsw::init_empty(meta);
  ShmHnsw gr(g, m);
  auto hdr = [&](uint32_t i) { return reinterpret_cast<ElemHeader *>(vc[i / N] + (i % N) * vrec); };
  auto lnk0 = [&](uint32_t i) { return reinterpret_cast<uint32_t *>(lc[i / N] + (i % N) * l0); };

  std::mt19937_64 rng(20261103);
  std::normal_distribution<float> nd;
  auto randvec = [&](std::vector<float> &v) {
    v.resize(g.dim);
    double n = 0;
    for (auto &x : v) x = nd(rng), n += double(x) * x;
    for (auto &x : v) x = float(x / std::sqrt(n));
  };
  const uint32_t n0 = 2000;
  std::vector<std::vector<float>> vecs(n0 + 1);
  for (uint32_t i = 0; i < n0; i++) randvec(vecs[i]), gr.insert(i, 0, vecs[i].data(), rng);

  std::vector<uint32_t> del(p.max_ids, ~0u);
  del[7] = 3;  // a deleted record (visible before 3)
  std::vector<uint16_t> visited(g.capacity, 0);
  uint16_t tag = 0;
  const uint32_t k = 10, ef = 64;
  auto old_pred = [&](uint32_t s) {  // the predicate before the guard (server.cc run_segment up to e40bc920)
    return [&, s](uint32_t i) {
      ElemHeader tmp;
      const ElemHeader &h = gr.header(i, tmp);
      return h.ins_seq <= s && __atomic_load_n(&del[h.ext_id], __ATOMIC_RELAXED) > s;
    };
  };
  auto new_pred = [&](uint32_t s) {
    return [&, s](uint32_t i) {
      ElemHeader tmp;
      return elem_visible(gr.header(i, tmp), s, del.data(), p);
    };
  };

  // 1. valid graph: identical results, zero rejects
  std::vector<std::vector<float>> qs(200);
  for (auto &q : qs) randvec(q);
  {
    uint64_t diff = 0;
    SearchRejects rj;
    for (uint32_t s : {0u, 5u}) {
      for (auto &q : qs) {
        std::vector<std::pair<float, uint32_t>> a, b;
        gr.search(q.data(), k, ef, old_pred(s), &a, visited, tag);
        gr.search(q.data(), k, ef, new_pred(s), &b, visited, tag, nullptr, &rj);
        diff += a != b;
      }
    }
    CHECK(diff == 0, "valid graph: %lu of 400 searches differ from the pre-guard predicate", (unsigned long)diff);
    CHECK(rj.headers == 0 && rj.links == 0, "valid graph: rejects %lu / %lu", (unsigned long)rj.headers,
          (unsigned long)rj.links);
    std::printf("1. valid graph: 400 searches identical to the pre-guard predicate, rejects 0/0\n");
  }

  // 2. a newly inserted slot X (ins_seq 5), linked from its neighbours; the reader sees a stale copy of X's page
  const uint32_t X = n0;
  randvec(vecs[X]);
  gr.insert(X, 5, vecs[X].data(), rng);
  uint32_t linked_from = 0;
  for (uint32_t i = 0; i < n0; i++) {
    const uint32_t *ll = lnk0(i);
    for (uint32_t j = 0; j < ll[0]; j++) linked_from += ll[1 + j] == X;
  }
  CHECK(linked_from > 0, "X not linked from any neighbour");
  const ElemHeader good = *hdr(X);
  std::vector<uint32_t> good_l0(lnk0(X), lnk0(X) + l0 / 4);
  auto search_x = [&](SearchRejects *rj, bool *found) {
    std::vector<std::pair<float, uint32_t>> r;
    gr.search(vecs[X].data(), k, ef, new_pred(10), &r, visited, tag, nullptr, rj);
    *found = false;
    for (auto &pr : r) *found = *found || pr.second == X;
    return r.size();
  };
  {
    SearchRejects rj;
    bool found;
    search_x(&rj, &found);
    CHECK(found && rj.headers == 0, "valid X: found %d, rejects %lu", int(found), (unsigned long)rj.headers);
    std::printf("2. X (internal %u) linked from %u neighbours; valid X found by its own vector\n", X, linked_from);
  }
  // 3. garbage header (bytes of an earlier experiment: ext_id far beyond max_ids, the crash of E0a)
  {
    std::memset(hdr(X), 0xA5, sizeof(ElemHeader));
    hdr(X)->ext_id = 0x0000a5a5a5a5a5a5ull;  // non-canonical index into del_seq_ in the pre-guard code
    SearchRejects rj;
    bool found;
    const size_t n = search_x(&rj, &found);
    CHECK(!found && rj.headers >= 1 && n == k, "garbage header: found %d, rejects %lu, results %zu", int(found),
          (unsigned long)rj.headers, n);
    ElemHeader t;
    CHECK(elem_visible(gr.header(X, t), 10, del.data(), p) == -1, "garbage header not rejected by elem_visible");
    std::printf("3. garbage header: skipped, stale_header_rejects=%lu, %zu results\n", (unsigned long)rj.headers, n);
  }
  // 3b. valid canary but ext_id >= max_ids / ins_seq > max_writes: rejected by the bounds
  {
    ElemHeader h = good;
    h.ext_id = p.max_ids + 1, h.check = elem_check(h.ext_id, h.ins_seq, h.level);
    ElemHeader h2 = good;
    h2.ins_seq = uint32_t(p.max_writes + 1), h2.check = elem_check(h2.ext_id, h2.ins_seq, h2.level);
    ElemHeader h3 = good;
    h3.level = 3, h3.upper_off = g.upper_group_bytes(), h3.check = elem_check(h3.ext_id, h3.ins_seq, h3.level);
    CHECK(elem_visible(h, 10, del.data(), p) == -1 && elem_visible(h2, 10, del.data(), p) == -1 &&
              elem_visible(h3, 10, del.data(), p) == -1 && elem_visible(good, 10, del.data(), p) == 1 &&
              elem_visible(good, 4, del.data(), p) == 0,
          "bounds: ext_id / ins_seq / upper_off");
    std::printf("3b. bounds: ext_id >= max_ids, ins_seq > max_writes, upper_off past the arena rejected\n");
  }
  // 4. zeroed slot (after the preload zeroing, a never-written slot reads as zeros)
  {
    std::memset(hdr(X), 0, vrec);
    std::memset(lnk0(X), 0, l0);
    SearchRejects rj;
    bool found;
    search_x(&rj, &found);
    CHECK(!found && rj.headers >= 1, "zero header: found %d, rejects %lu", int(found), (unsigned long)rj.headers);
    std::printf("4. zeroed slot: skipped, stale_header_rejects=%lu\n", (unsigned long)rj.headers);
  }
  // 5. valid header, stale link block (garbage count, then garbage ids)
  {
    *hdr(X) = good;
    std::memcpy(reinterpret_cast<uint8_t *>(hdr(X)) + sizeof(ElemHeader), vecs[X].data(), g.vec_bytes());  // fp32
    std::memset(lnk0(X), 0x5A, l0);  // count 0x5a5a5a5a
    SearchRejects rj;
    bool found;
    search_x(&rj, &found);
    CHECK(found && rj.links >= 1, "garbage link count: found %d, link rejects %lu", int(found), (unsigned long)rj.links);
    uint32_t *ll = lnk0(X);
    ll[0] = 3, ll[1] = 0xffffff00u, ll[2] = uint32_t(g.capacity), ll[3] = good_l0[1];
    SearchRejects rj2;
    search_x(&rj2, &found);
    CHECK(found && rj2.links >= 2, "garbage link ids: found %d, link rejects %lu", int(found), (unsigned long)rj2.links);
    std::printf("5. stale link block: count / ids skipped, stale_link_rejects=%lu then %lu\n", (unsigned long)rj.links,
                (unsigned long)rj2.links);
    std::memcpy(lnk0(X), good_l0.data(), l0);
  }
  // 6. upper levels: garbage header of the entry point (level > 0) -> descent stops there, no out-of-arena read
  {
    const uint32_t ep = uint32_t(meta->ep_level), maxl = uint32_t(meta->ep_level >> 32);
    CHECK(maxl > 0, "entry point has no upper level (max level %u)", maxl);
    const ElemHeader save = *hdr(ep);
    std::memset(hdr(ep), 0xA5, sizeof(ElemHeader));
    hdr(ep)->upper_off = ~0ull >> 4;
    SearchRejects rj;
    std::vector<std::pair<float, uint32_t>> r;
    gr.search(qs[0].data(), k, ef, new_pred(10), &r, visited, tag, nullptr, &rj);
    bool has_ep = false;
    for (auto &pr : r) has_ep = has_ep || pr.second == ep;
    CHECK(rj.headers >= 1 && !has_ep && !r.empty(), "entry point garbage: rejects %lu, results %zu, ep in results %d",
          (unsigned long)rj.headers, r.size(), int(has_ep));
    std::printf("6. garbage entry-point header (max level %u): descent stopped, rejects %lu, %zu results\n", maxl,
                (unsigned long)rj.headers, r.size());
    *hdr(ep) = save;
  }
  // 7. restored graph: valid again, zero rejects, identical to the pre-guard predicate
  {
    uint64_t diff = 0;
    SearchRejects rj;
    for (auto &q : qs) {
      std::vector<std::pair<float, uint32_t>> a, b;
      gr.search(q.data(), k, ef, old_pred(10), &a, visited, tag);
      gr.search(q.data(), k, ef, new_pred(10), &b, visited, tag, nullptr, &rj);
      diff += a != b;
    }
    CHECK(diff == 0 && rj.headers == 0 && rj.links == 0, "restored: diff %lu rejects %lu/%lu", (unsigned long)diff,
          (unsigned long)rj.headers, (unsigned long)rj.links);
    std::printf("7. restored graph: 200 searches identical, rejects 0/0\n");
  }
  std::printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}

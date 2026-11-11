// socialgraph layout Host test (regular file, no DAX): builds an image from a small synthetic edge list with
// tools/image_builder.h, maps it and checks layout invariants, alignment, newest-first order, slack, overflow chains,
// record / chunk enumeration and the round trip of the edge list; then applies addlinks by the layout rules (inline
// slack, then a prepended pool block) and checks the walk again.
// usage: layout_test <scratch image path>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <map>
#include <set>

#include "../tools/image_builder.h"

using namespace sg;

static int fails = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } \
  } while (0)

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: layout_test <scratch image>\n"); return 2; }
  // synthetic graph, ids 5..(5+n-1): node 5 is a hub with 301 neighbours (2 ovf blocks, last partial), node 6 has
  // 120 (inline limit), node 7 has 121 (1 ovf block with 1 edge), node 8 has 0 links; plus a self loop and a duplicate.
  const uint32_t base = 5, n = 400;
  std::vector<uint32_t> src, dst;
  std::set<std::pair<uint32_t, uint32_t>> und;
  auto add = [&](uint32_t a, uint32_t b) {
    src.push_back(a); dst.push_back(b);
    if (a != b) und.insert({std::min(a, b), std::max(a, b)});
  };
  for (uint32_t k = 0; k < 300; k++) add(base, base + 10 + k);
  for (uint32_t k = 0; k < 119; k++) add(base + 1, base + 50 + k);  // + edge to the hub below = 120
  add(base + 1, base);
  for (uint32_t k = 0; k < 121; k++) add(base + 2, base + 100 + k);
  add(base + 20, base + 20);  // self loop
  add(base + 30, base + 31);
  add(base + 31, base + 30);  // duplicate of the previous edge
  for (uint32_t k = 0; k < 200; k++) add(base + 200 + k % 150, base + 210 + (k * 7) % 180);
  std::map<uint32_t, std::set<uint32_t>> nb;
  for (auto &e : und) { nb[e.first].insert(e.second); nb[e.second].insert(e.first); }
  uint64_t expect_links = 0;
  for (auto &kv : nb) expect_links += kv.second.size();

  BuildParams p;
  p.seed = 7;
  p.node_slack = 37;
  p.ovf_pool = 5;
  Graph g = build_csr(src, dst, base, n, p);
  CHECK(g.self_loops >= 1);
  CHECK(g.off[g.n] == expect_links);
  CHECK(g.duplicates >= 2);  // the repeated edge appears once in each endpoint's list
  FILE *f = fopen(argv[1], "wb");
  if (!f) { perror("open"); return 2; }
  BuildStats st;
  ImageHeader hw = write_image(f, g, p, st);
  fclose(f);

  int fd = open(argv[1], O_RDWR);
  struct stat sb;
  fstat(fd, &sb);
  void *m = mmap(nullptr, sb.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (m == MAP_FAILED) { perror("mmap"); return 2; }
  View v(m);
  const ImageHeader &h = *v.h;
  CHECK(check_header(h, uint64_t(sb.st_size)) == "");
  CHECK(h.layout_hash == hw.layout_hash);
  CHECK(h.n_orig == n && h.node_slack == 37 && h.ovf_pool == 5 && h.n_links == expect_links);
  // arrays page aligned, in order, non-overlapping
  CHECK(h.adj_index_off % kPage == 0 && h.nodes_off % kPage == 0 && h.adj_off % kPage == 0 && h.ovf_off % kPage == 0);
  CHECK(h.adj_index_off + h.adj_index_bytes <= h.nodes_off && h.nodes_off + h.nodes_bytes <= h.adj_off &&
        h.adj_off + h.adj_bytes <= h.ovf_off && h.total_bytes % kPage == 0);
  CHECK(h.ovf_built == 2 + 1);

  // records: line aligned, whole lines, contiguous and disjoint within each array
  uint64_t prev_end[3] = {h.nodes_off, h.adj_off, h.ovf_off};
  uint64_t nobj = for_each_record_object(v, [&](const ObjRef &o) {
    CHECK(o.off % kLine == 0 && o.bytes % kLine == 0 && o.bytes > 0);
    int k = int(o.kind);
    CHECK(k < 3);
    CHECK(o.off == prev_end[k]);
    prev_end[k] = o.off + o.bytes;
  });
  CHECK(nobj == record_objects(h) && nobj == h.n_nodes() + h.n_orig + h.ovf_blocks());
  CHECK(prev_end[0] == h.nodes_off + h.nodes_bytes && prev_end[1] == h.adj_off + h.adj_bytes &&
        prev_end[2] == h.ovf_off + h.ovf_bytes());
  // chunks (small chunk size so arrays span several chunks) agree with chunk_of
  const uint64_t cb = 8192;
  uint64_t ci = 0;
  uint64_t nch = for_each_chunk(h, cb, [&](const ChunkRef &c) {
    CHECK(chunk_of(h, cb, c.off) == ci && chunk_of(h, cb, c.off + c.bytes - 1) == ci);
    CHECK(c.bytes > 0 && c.bytes <= cb);
    ci++;
  });
  CHECK(nch == ci && nch > 4);
  CHECK(chunk_of(h, cb, 0) == ~0ull);
  CHECK(chunk_of(h, kChunkBytes, h.ovf_off) == 3);  // one chunk per (small) array

  // nodes
  for (uint64_t i = 0; i < h.n_nodes(); i++) {
    const NodeSlot *s = v.node(i);
    CHECK(reinterpret_cast<uintptr_t>(s) % kLine == 0);
    CHECK(s->id == base + i && v.slot_of(s->id) == i);
    if (i < n) CHECK(s->flags == kNodeLive && s->version == 1 && s->data_len <= kNodeDataCap && v.has_adj(i));
    else CHECK(s->flags == 0 && s->version == 0 && !v.has_adj(i));
  }
  CHECK(v.slot_of(base - 1) == h.n_nodes() && v.slot_of(base + h.n_nodes()) == h.n_nodes());

  // adjacency: round trip, newest first, slack, ovf chains
  uint64_t walked_total = 0;
  for (uint64_t i = 0; i < n; i++) {
    const AdjHeader *a = v.adj(i);
    uint32_t id1 = uint32_t(base + i);
    auto it = nb.find(id1);
    uint64_t d = it == nb.end() ? 0 : it->second.size();
    CHECK(reinterpret_cast<uintptr_t>(a) % kLine == 0);
    CHECK(a->id1 == id1 && a->count == d && a->used == d && a->head == kSegInline);
    CHECK(a->cap == inline_cap(d) && a->cap % 2 == 0 && a->cap <= kInlineMaxCap);
    CHECK(a->start == a->cap - inline_edges(d));
    CHECK(a->start >= (d >= kInlineMaxEdges ? 6 : 2));  // addlink slack
    CHECK(v.primary_block_bytes(i) == primary_bytes(d));
    CHECK(a->n_ovf == ovf_blocks_for(d));
    std::set<uint32_t> got;
    uint64_t last_t = ~0ull;
    bool order_ok = true;
    uint64_t cnt = walk_links(v, i, [&](const EdgeSlot &e) {
      order_ok &= e.time <= last_t;
      last_t = e.time;
      got.insert(e.id2);
      CHECK(e.flags == kEdgeLive && e.assoc_type == kAssocFriend && e.data_len <= kEdgeDataCap);
      // the reverse link exists with the same time
      uint64_t j = v.slot_of(e.id2);
      bool found = false;
      walk_links(v, j, [&](const EdgeSlot &r) { if (r.id2 == id1) { found = r.time == e.time; return false; } return true; });
      CHECK(found);
      return true;
    });
    CHECK(order_ok);
    CHECK(cnt == d);
    CHECK(got == (it == nb.end() ? std::set<uint32_t>() : it->second));
    walked_total += cnt;
  }
  CHECK(walked_total == expect_links);
  // hub: 301 links -> 120 inline + ovf 126 + ovf 55 (slack in front of the last block)
  {
    const AdjHeader *a = v.adj(0);
    CHECK(a->cap == kInlineMaxCap && a->start == 6 && a->next == 0);
    CHECK(v.ovf(0)->h.id1 == base && v.ovf(0)->h.start == 0 && v.ovf(0)->h.next == 1);
    CHECK(v.ovf(1)->h.id1 == base && v.ovf(1)->h.start == kOvfSlots - 55 && v.ovf(1)->h.next == kSegNone);
    CHECK(v.adj(1)->n_ovf == 0 && v.adj(1)->cap == kInlineMaxCap && v.adj(1)->start == 6);   // 120 links
    CHECK(v.adj(2)->n_ovf == 1 && v.ovf(2)->h.start == kOvfSlots - 1);                      // 121 links
    CHECK(v.adj(3)->count == 0 && v.adj(3)->cap == 2 && v.adj(3)->start == 2);              // 0 links
  }
  for (uint64_t b = h.ovf_built; b < h.ovf_blocks(); b++)
    CHECK(v.ovf(b)->h.id1 == 0 && v.ovf(b)->h.start == kOvfSlots && v.ovf(b)->h.next == kSegNone);

  // addlink by the layout rules on node 3 (0 links, cap 2): two inline, then a pool block becomes the head
  {
    AdjHeader *a = v.adj(3);
    uint64_t pool = h.ovf_built;
    for (uint32_t k = 0; k < 5; k++) {
      EdgeSlot e{};
      e.id2 = 1000 + k; e.flags = kEdgeLive; e.time = 2000000000000ull + k;
      if (a->head == kSegInline && a->start > 0) {
        a->inline_slots()[--a->start] = e;
      } else {
        OvfBlock *o = a->head == kSegInline ? nullptr : v.ovf(a->head);
        if (!o || o->h.start == 0) {
          OvfBlock *nbk = v.ovf(pool);
          nbk->h.id1 = a->id1;
          nbk->h.next = a->head;
          nbk->slot[--nbk->h.start] = e;
          a->head = uint32_t(pool++);
          a->n_ovf++;
        } else {
          o->slot[--o->h.start] = e;
        }
      }
      a->count++; a->used++; a->version++;
    }
    std::vector<uint32_t> seq;
    walk_links(v, 3, [&](const EdgeSlot &e) { seq.push_back(e.id2); return true; });
    CHECK((seq == std::vector<uint32_t>{1004, 1003, 1002, 1001, 1000}));
    CHECK(a->head == h.ovf_built && v.ovf(a->head)->h.next == kSegInline && a->count == 5);
    // the hub, newest first after an addlink: inline slack used, ovf chain unchanged
    AdjHeader *hub = v.adj(0);
    EdgeSlot e{};
    e.id2 = 999; e.flags = kEdgeLive; e.time = 2000000000000ull;
    hub->inline_slots()[--hub->start] = e;
    uint32_t first = 0;
    uint64_t c = walk_links(v, 0, [&](const EdgeSlot &x) { if (!first) first = x.id2 ? x.id2 : 1; return true; });
    CHECK(first == 999 && c == 302);
  }
  {  // write routes (layout.h): owners of every span index; range spans partition [first, first + count) in order
    for (uint32_t n : {1u, 2u, 3u, 4u, 8u}) {
      for (uint64_t cnt : {0ull, 1ull, 7ull, 64ull, 1001ull}) {
        uint64_t prev_end = 100;
        for (uint32_t w = 0; w < n; w++) {
          uint64_t b = 0, e = 0;
          span_range(100, cnt, w, n, &b, &e);
          CHECK(b == prev_end && e >= b && e <= 100 + cnt);
          for (uint64_t i = b; i < e; i++) CHECK(span_owner(Route::kRange, i, 100, cnt, n) == w);
          prev_end = e;
        }
        CHECK(prev_end == 100 + cnt);
        for (uint64_t i = 100; i < 100 + cnt; i++) CHECK(span_owner(Route::kMod, i, 100, cnt, n) == i % n);
      }
    }
    // slot_owner: original and slack slots are separate spans (range), plain % N (mod)
    CHECK(slot_owner(Route::kRange, 0, 10, 4, 2) == 0 && slot_owner(Route::kRange, 4, 10, 4, 2) == 0 &&
          slot_owner(Route::kRange, 5, 10, 4, 2) == 1 && slot_owner(Route::kRange, 9, 10, 4, 2) == 1 &&
          slot_owner(Route::kRange, 10, 10, 4, 2) == 0 && slot_owner(Route::kRange, 12, 10, 4, 2) == 1);
    CHECK(slot_owner(Route::kMod, 12, 10, 4, 2) == 0 && slot_owner(Route::kMod, 9, 10, 4, 4) == 1);
    CHECK(pool_owner(Route::kRange, 50, 50, 10, 4) == 0 && pool_owner(Route::kRange, 59, 50, 10, 4) == 3);
    Route r = Route::kMod;
    CHECK(parse_route("range", &r) && r == Route::kRange && parse_route("mod", &r) && r == Route::kMod &&
          !parse_route("owner", &r) && std::string(route_name(Route::kRange)) == "range");
  }
  munmap(m, sb.st_size);
  close(fd);
  printf("layout_test: image %lld bytes, %llu record objects, %llu chunks (8 KiB), %llu links, straddle %llu: %s\n",
         (long long)sb.st_size, (unsigned long long)nobj, (unsigned long long)nch, (unsigned long long)expect_links,
         (unsigned long long)st.primary_straddle, fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}

// seqlock stress (Host, regular file): one writer process and one reader process ("two hosts") map the same image
// file; the writer hammers a few node slots (updatenode) and adjacency lists (addlink / updatelink / deletelink) with
// self-describing payloads, the reader threads read them through GraphOps (graph_ops.h) and check every returned
// record: node data = pattern(counter in the first 8 bytes), data_len = f(counter); list = used / count match the
// walked slots, every edge payload = pattern(its counter), added links newest first. A torn record fails a check.
// usage: sg-seqlock-stress <image file (scratch copy; modified)> <seconds> [reader threads (3)]
// exit 0 = no torn record seen and the writer made progress concurrently with readers (retries > 0 reported).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#include "graph_ops.h"
#include "mmap_backend.h"

using namespace sg;

namespace {

uint64_t mix(uint64_t x) {
  x += 0x9e3779b97f4a7c15ull;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}
// node payload for counter c: 8 B counter, then bytes of mix(c, i); length 8 + c % 81
uint32_t node_len(uint64_t c) { return uint32_t(8 + c % 81); }
void node_data(uint64_t c, uint8_t *d) {
  std::memcpy(d, &c, 8);
  for (uint32_t i = 8; i < node_len(c); i++) d[i] = uint8_t(mix(c * 131 + i));
}
bool node_ok(const NodeSlot &s) {
  if (s.commit_ns == 0) return true;  // image record
  if (s.data_len < 8) return false;
  uint64_t c;
  std::memcpy(&c, s.data, 8);
  if (s.data_len != node_len(c)) return false;
  uint8_t d[kNodeDataCap];
  node_data(c, d);
  return std::memcmp(d, s.data, s.data_len) == 0;
}
// edge payload for counter c: 4 B counter, 8 B mix(c); 12 B
void edge_data(uint32_t c, uint8_t *d) {
  std::memcpy(d, &c, 4);
  const uint64_t m = mix(c);
  std::memcpy(d + 4, &m, 8);
}
bool edge_ok(const EdgeSlot &e) {
  // image links: times in (base_ms - 2^31, base_ms], base_ms ~1.7e12; stress links: 1e12 + counter
  if (e.time >= 1500000000000ull) return e.data_len <= kEdgeDataCap;
  if (e.data_len != 12) return false;
  uint32_t c;
  std::memcpy(&c, e.data, 4);
  uint8_t d[12];
  edge_data(c, d);
  return std::memcmp(d, e.data, 12) == 0 && e.time == 1000000000000ull + c;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: sg-seqlock-stress <image file> <seconds> [reader threads]\n");
    return 2;
  }
  const double secs = std::atof(argv[2]);
  const int nr = argc > 3 ? std::atoi(argv[3]) : 3;
  const int fd = open(argv[1], O_RDWR);
  struct stat st;
  if (fd < 0 || fstat(fd, &st)) { std::perror("open"); return 2; }
  uint8_t *m = static_cast<uint8_t *>(mmap(nullptr, size_t(st.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
  uint64_t *lockw = static_cast<uint64_t *>(mmap(nullptr, 64 * 64, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0));
  auto *ctl = static_cast<std::atomic<uint64_t> *>(mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0));
  if (m == MAP_FAILED || lockw == MAP_FAILED || ctl == MAP_FAILED) { std::perror("mmap"); return 2; }
  new (&ctl[0]) std::atomic<uint64_t>(0);  // stop flag
  new (&ctl[1]) std::atomic<uint64_t>(0);  // writer writes done
  MmapBackend be(m, uint64_t(st.st_size));
  std::string err;
  if (!be.attach(&err)) { std::fprintf(stderr, "attach: %s\n", err.c_str()); return 2; }
  const ImageHeader &h = be.header();
  // targets: 8 node slots, 4 lists (the first original nodes with a list)
  std::vector<uint64_t> nodes, lists;
  for (uint64_t s = 0; s < h.n_orig && nodes.size() < 8; s++) nodes.push_back(s);
  for (uint64_t s = 0; s < h.n_orig && lists.size() < 4; s++)
    if (be.has_adj(s)) lists.push_back(s);
  Locks locks;
  locks.w = lockw, locks.n = 64, locks.owner = 1;

  const pid_t wp = fork();
  if (wp == 0) {  // writer "host"
    GraphOps<MmapBackend> g(be, &locks, nullptr, 0, 1, 2000000000ull);
    Ctx cx;
    uint64_t c = 1, writes = 0, full = 0;
    uint8_t d[kNodeDataCap];
    std::vector<uint32_t> added[4];
    const uint32_t id2_base = uint32_t(h.id_base);
    while (!ctl[0].load()) {
      for (uint64_t s : nodes) {
        node_data(c, d);
        typename GraphOps<MmapBackend>::WriteOut w;
        if (g.node_write(cx, kOpUpdateNode, h.id_base + s, 2048, d, node_len(c), &w) == kStatusOk) writes++;
        c++;
      }
      for (size_t li = 0; li < lists.size(); li++) {
        typename GraphOps<MmapBackend>::WriteOut w;
        const uint64_t id1 = h.id_base + lists[li];
        uint8_t e[12];
        const uint32_t k = uint32_t(c++);
        edge_data(k, e);
        const uint64_t r = mix(k) % 8;
        uint16_t rc;
        if (r < 3 || added[li].empty()) {  // addlink of a new id2 (descending ids walk = newest first)
          const uint32_t id2 = id2_base + uint32_t(added[li].size() % (h.n_nodes() - 1));
          rc = g.add_link(cx, id1, id2, kAssocFriend, 1000000000000ull + k, e, 12, &w);
          if (rc == kStatusOk) added[li].push_back(id2);
          else if (rc == kStatusFull) full++;
        } else if (r < 7) {
          rc = g.update_link(cx, id1, added[li][mix(k + 1) % added[li].size()], kAssocFriend, 1000000000000ull + k, e, 12, &w);
        } else {
          rc = g.delete_link(cx, id1, added[li][mix(k + 1) % added[li].size()], kAssocFriend, &w);
          if (rc == kStatusOk) g.add_link(cx, id1, added[li][mix(k + 1) % added[li].size()], kAssocFriend, 1000000000000ull + k, e, 12, &w);
        }
        if (rc == kStatusOk) writes++;
      }
    }
    ctl[1].store(writes);
    std::printf("writer: %lu writes, %lu pool-full\n", (unsigned long)writes, (unsigned long)full);
    std::fflush(stdout);
    _exit(0);
  }
  const pid_t rp = fork();
  if (rp == 0) {  // reader "host"
    std::atomic<uint64_t> reads{0}, torn{0}, retries{0}, guard{0}, checkf{0}, busy{0};
    std::vector<std::thread> th;
    for (int t = 0; t < nr; t++)
      th.emplace_back([&, t] {
        GraphOps<MmapBackend> g(be, &locks, nullptr, 1, 2, 2000000000ull);
        Ctx cx;
        std::vector<EdgeSlot> edges;
        uint64_t i = uint64_t(t);
        while (!ctl[0].load()) {
          i++;
          NodeSlot n;
          const uint16_t s1 = g.get_node(cx, nodes[i % nodes.size()], &n);
          if (s1 == kStatusBusy) busy++;
          else if (!node_ok(n)) {
            if (torn++ < 5) std::fprintf(stderr, "TORN node slot %lu version %lu\n", (unsigned long)nodes[i % nodes.size()], (unsigned long)n.version);
          }
          AdjHeader a;
          const uint16_t s2 = g.get_list(cx, lists[i % lists.size()], false, kAssocFriend, 0, &edges, &a);
          if (s2 == kStatusBusy) { busy++; continue; }
          uint64_t live = 0;
          bool ok = a.used == edges.size();
          for (auto &e : edges) live += e.flags & kEdgeLive, ok = ok && edge_ok(e);
          ok = ok && live == a.count;
          if (!ok && torn++ < 5)
            std::fprintf(stderr, "TORN list slot %lu version %lu used %u walked %zu count %u live %lu\n",
                         (unsigned long)lists[i % lists.size()], (unsigned long)a.version, a.used, edges.size(), a.count,
                         (unsigned long)live);
          reads += 2;
        }
        retries += cx.c.retries, guard += cx.c.guard_rejects, checkf += cx.c.check_fails;
      });
    for (auto &x : th) x.join();
    std::printf("reader: %lu record reads, %lu torn, %lu seqlock retries, %lu guard rejects, %lu check fails, %lu busy\n",
                (unsigned long)reads.load(), (unsigned long)torn.load(), (unsigned long)retries.load(),
                (unsigned long)guard.load(), (unsigned long)checkf.load(), (unsigned long)busy.load());
    std::fflush(stdout);
    _exit(torn.load() ? 1 : (retries.load() + checkf.load() == 0 ? 3 : 0));
  }
  usleep(useconds_t(secs * 1e6));
  ctl[0].store(1);
  int ws = 0, rs = 0;
  waitpid(wp, &ws, 0);
  waitpid(rp, &rs, 0);
  const int rc = WIFEXITED(rs) ? WEXITSTATUS(rs) : 9;
  const bool pass = WIFEXITED(ws) && WEXITSTATUS(ws) == 0 && rc == 0 && ctl[1].load() > 0;
  std::printf("seqlock stress %s (reader exit %d%s)\n", pass ? "PASS" : "FAIL", rc,
              rc == 3 ? ": no retry observed, the stress did not overlap" : "");
  return pass ? 0 : 1;
}

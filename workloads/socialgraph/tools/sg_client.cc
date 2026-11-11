// sg-client: Host test client for sg-server (frame.h + proto.h). Not a load generator (that is the loadgen plugin).
// usage:
//   sg-client selftest <hostA:port> <hostB:port> <id1> <new id2 base>
//       Issues every request type against two servers that share one region ("two hosts") and checks that the
//       results agree and that every write made through one server is visible through the other. Exit 0 = PASS.
//   sg-client stats <host:port>      print the stats text
//   sg-client feed <host:port> <id1> [limit]
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "frame.h"
#include "proto.h"
#include "server/layout.h"

using namespace sg;

namespace {

int fails = 0;
#define CHECK(c, ...)                                                   \
  do {                                                                  \
    if (!(c)) {                                                         \
      std::fprintf(stderr, "FAIL line %d: %s: ", __LINE__, #c);         \
      std::fprintf(stderr, __VA_ARGS__);                                \
      std::fprintf(stderr, "\n");                                       \
      fails++;                                                          \
    }                                                                   \
  } while (0)

struct Client {
  int fd = -1;
  uint64_t next = 1;
  explicit Client(const std::string &hp) {
    const size_t c = hp.rfind(':');
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET, hints.ai_socktype = SOCK_STREAM;
    if (c == std::string::npos || getaddrinfo(hp.substr(0, c).c_str(), hp.substr(c + 1).c_str(), &hints, &res)) {
      std::fprintf(stderr, "bad address %s\n", hp.c_str());
      std::exit(2);
    }
    fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fd, res->ai_addr, res->ai_addrlen)) {
      std::fprintf(stderr, "connect %s failed\n", hp.c_str());
      std::exit(2);
    }
    freeaddrinfo(res);
  }
  // returns frame status; *out = payload
  uint16_t call(uint16_t op, const std::vector<uint8_t> &req, std::vector<uint8_t> *out) {
    frame::header h;
    frame::fill(&h, op, next++, uint32_t(req.size()));
    frame::write_full(fd, &h, sizeof h);
    if (!req.empty()) frame::write_full(fd, req.data(), req.size());
    frame::header r;
    if (!frame::read_full(fd, &r, sizeof r)) { std::fprintf(stderr, "connection closed\n"); std::exit(2); }
    out->resize(frame::payload_len(r));
    if (!out->empty() && !frame::read_full(fd, out->data(), out->size())) std::exit(2);
    return r.code;
  }
};

template <class T> void put(std::vector<uint8_t> &b, const T &x) {
  const size_t o = b.size();
  b.resize(o + sizeof x);
  std::memcpy(b.data() + o, &x, sizeof x);
}
template <class T> T get(const std::vector<uint8_t> &b, size_t off) {
  T x;
  std::memcpy(&x, b.data() + off, sizeof x);
  return x;
}
RespHead head(const std::vector<uint8_t> &b) { return b.size() >= sizeof(RespHead) ? get<RespHead>(b, 0) : RespHead{}; }

struct Feed {
  uint16_t status = 0xffff;
  FeedResp r{};
  std::vector<FeedRow> rows;
};
Feed feed(Client &c, uint64_t id1, uint16_t limit = 50) {
  std::vector<uint8_t> q, o;
  put(q, FeedReq{id1, kAssocFriend, limit, 0});
  Feed f;
  if (c.call(kOpFeed, q, &o) != frame::kStatusOk) return f;
  f.status = head(o).status;
  if (f.status != kStatusOk) return f;
  f.r = get<FeedResp>(o, sizeof(RespHead));
  for (uint32_t i = 0; i < f.r.n; i++) f.rows.push_back(get<FeedRow>(o, sizeof(RespHead) + sizeof(FeedResp) + i * sizeof(FeedRow)));
  return f;
}
struct Node {
  uint16_t status = 0xffff;
  NodeResp r{};
  std::string data;
};
Node getnode(Client &c, uint64_t id) {
  std::vector<uint8_t> q, o;
  put(q, NodeKeyReq{id});
  Node n;
  if (c.call(kOpGetNode, q, &o) != frame::kStatusOk) return n;
  n.status = head(o).status;
  if (n.status != kStatusOk) return n;
  n.r = get<NodeResp>(o, sizeof(RespHead));
  n.data.assign(reinterpret_cast<const char *>(o.data()) + sizeof(RespHead) + sizeof(NodeResp), n.r.data_len);
  return n;
}
CountResp countlink(Client &c, uint64_t id1, uint16_t *st) {
  std::vector<uint8_t> q, o;
  put(q, LinkListReq{id1, kAssocFriend, {0, 0, 0}});
  c.call(kOpCountLink, q, &o);
  *st = head(o).status;
  return *st == kStatusOk ? get<CountResp>(o, sizeof(RespHead)) : CountResp{};
}
std::vector<LinkRow> getlink(Client &c, uint64_t id1, const std::vector<uint32_t> &id2s, uint16_t *st) {
  std::vector<uint8_t> q, o;
  put(q, GetLinkReq{id1, kAssocFriend, uint16_t(id2s.size()), 0});
  for (uint32_t x : id2s) put(q, x);
  c.call(kOpGetLink, q, &o);
  *st = head(o).status;
  std::vector<LinkRow> rows;
  if (*st != kStatusOk) return rows;
  const GetLinkResp g = get<GetLinkResp>(o, sizeof(RespHead));
  for (uint32_t i = 0; i < g.n; i++) rows.push_back(get<LinkRow>(o, sizeof(RespHead) + sizeof(GetLinkResp) + i * sizeof(LinkRow)));
  return rows;
}
uint32_t g_wseq = 1;
WriteResp link_write(Client &c, uint16_t op, uint64_t id1, uint32_t id2, uint64_t time, const std::string &d, uint16_t *st) {
  std::vector<uint8_t> q, o;
  put(q, LinkWriteReq{id1, id2, kAssocFriend, uint16_t(d.size()), time, g_wseq++, 0});
  q.insert(q.end(), d.begin(), d.end());
  c.call(op, q, &o);
  *st = head(o).status;
  return *st == kStatusOk ? get<WriteResp>(o, sizeof(RespHead)) : WriteResp{};
}
WriteResp node_write(Client &c, uint16_t op, uint64_t id, const std::string &d, uint16_t *st) {
  std::vector<uint8_t> q, o;
  put(q, NodeWriteReq{id, 2048, uint16_t(d.size()), 0, g_wseq++, 0});
  q.insert(q.end(), d.begin(), d.end());
  c.call(op, q, &o);
  *st = head(o).status;
  return *st == kStatusOk ? get<WriteResp>(o, sizeof(RespHead)) : WriteResp{};
}

int selftest(Client &a, Client &b, uint64_t id1, uint32_t base) {
  uint16_t st;
  // reads agree on both servers
  Feed fa = feed(a, id1), fb = feed(b, id1);
  CHECK(fa.status == kStatusOk && fb.status == kStatusOk, "feed status %u %u", fa.status, fb.status);
  CHECK(fa.r.n == fb.r.n && fa.r.list_version == fb.r.list_version, "feed differs");
  CHECK(fa.r.n > 0 && fa.r.n <= 50, "feed rows %u", fa.r.n);
  for (size_t i = 1; i < fa.rows.size(); i++) CHECK(fa.rows[i - 1].link_time >= fa.rows[i].link_time, "feed order at %zu", i);
  for (auto &r : fa.rows) CHECK(r.node_version >= 1, "row node version");
  const CountResp c0 = countlink(a, id1, &st);
  CHECK(st == kStatusOk && c0.count >= fa.r.n, "countlink");
  const Node n0a = getnode(a, id1), n0b = getnode(b, id1);
  CHECK(n0a.status == kStatusOk && n0a.r.version == n0b.r.version && n0a.data == n0b.data, "getnode differs");
  std::vector<uint32_t> want = {fa.rows[0].id2, 2000000000u};
  auto gl = getlink(b, id1, want, &st);
  CHECK(st == kStatusOk && gl.size() == 1 && gl[0].id2 == fa.rows[0].id2, "getlink rows %zu", gl.size());
  // addlink on A -> visible on B (first row, list version + 1, count + 1)
  const uint64_t t_new = fa.rows[0].link_time + 1000;
  WriteResp w = link_write(a, kOpAddLink, id1, base, t_new, "hello", &st);
  CHECK(st == kStatusOk && w.version == fa.r.list_version + 1, "addlink st %u version %lu", st, (unsigned long)w.version);
  Feed f1 = feed(b, id1);
  CHECK(f1.status == kStatusOk && f1.rows.size() && f1.rows[0].id2 == base && f1.r.list_version == w.version,
        "addlink not visible on B (first id2 %u)", f1.rows.size() ? f1.rows[0].id2 : 0);
  CountResp c1 = countlink(b, id1, &st);
  CHECK(c1.count == c0.count + 1 && c1.list_version == w.version, "countlink after addlink %lu", (unsigned long)c1.count);
  // updatelink on B -> visible on A (link version 1, data length 3)
  w = link_write(b, kOpUpdateLink, id1, base, t_new, "abc", &st);
  CHECK(st == kStatusOk, "updatelink st %u", st);
  gl = getlink(a, id1, {base}, &st);
  CHECK(gl.size() == 1 && gl[0].version == 1 && gl[0].data_len == 3, "updatelink not visible on A");
  // deletelink on A -> B's count back, feed without it
  w = link_write(a, kOpDeleteLink, id1, base, 0, "", &st);
  CHECK(st == kStatusOk, "deletelink st %u", st);
  c1 = countlink(b, id1, &st);
  CHECK(c1.count == c0.count && c1.list_version == w.version, "countlink after deletelink");
  f1 = feed(b, id1);
  CHECK(f1.rows.size() && f1.rows[0].id2 != base, "deleted link still in the feed");
  link_write(a, kOpUpdateLink, id1, base, 0, "x", &st);
  CHECK(st == kStatusNotFound, "updatelink of a deleted link: %u", st);
  // addlink of the deleted link on B revives it
  link_write(b, kOpAddLink, id1, base, t_new, "re", &st);
  CHECK(st == kStatusOk && countlink(a, id1, &st).count == c0.count + 1, "revive");
  // addlink to a slack (non-original) id is refused
  // addnode on B -> visible on A; updatenode on A -> visible on B; deletenode on B -> gone on A
  w = node_write(b, kOpAddNode, 0, "newnode", &st);
  CHECK(st == kStatusOk && w.version == 1, "addnode st %u v %lu", st, (unsigned long)w.version);
  const uint64_t nid = w.id;
  Node n1 = getnode(a, nid);
  CHECK(n1.status == kStatusOk && n1.data == "newnode" && n1.r.version == 1, "addnode not visible on A");
  w = node_write(a, kOpUpdateNode, nid, "updated!", &st);
  CHECK(st == kStatusOk && w.version == 2, "updatenode");
  n1 = getnode(b, nid);
  CHECK(n1.status == kStatusOk && n1.data == "updated!" && n1.r.version == 2 && n1.r.commit_ns == w.commit_ns,
        "updatenode not visible on B");
  link_write(a, kOpAddLink, nid, 1, 1, "", &st);
  CHECK(st == kStatusNotFound, "addlink to a new (non-original) id must be refused: %u", st);
  node_write(b, kOpDeleteNode, nid, "", &st);
  CHECK(st == kStatusOk, "deletenode");
  CHECK(getnode(a, nid).status == kStatusNotFound, "deleted node still visible on A");
  // updatenode of an original node through A, seen by B; feed rows of A's neighbours carry the new node version
  w = node_write(a, kOpUpdateNode, fa.rows[1].id2, "nbr", &st);
  CHECK(st == kStatusOk && w.version == fa.rows[1].node_version + 1, "updatenode original");
  f1 = feed(b, id1);
  bool seen = false;
  for (auto &r : f1.rows) seen = seen || (r.id2 == fa.rows[1].id2 && r.node_version == w.version);
  CHECK(seen, "neighbour node version not in B's feed");
  // many addlinks through alternating servers: inline slack, then pool blocks (newest first across segments)
  const uint32_t extra = 300;
  for (uint32_t k = 1; k <= extra; k++) {
    link_write(k & 1 ? a : b, kOpAddLink, id1, base + k, t_new + k, "m", &st);
    if (st != kStatusOk) { CHECK(st == kStatusOk, "bulk addlink %u st %u", k, st); break; }
  }
  f1 = feed(a, id1, 50);
  CHECK(f1.rows.size() == 50, "bulk feed rows %zu", f1.rows.size());
  for (uint32_t i = 0; i < f1.rows.size(); i++) CHECK(f1.rows[i].id2 == base + extra - i, "bulk order row %u id2 %u", i, f1.rows[i].id2);
  c1 = countlink(b, id1, &st);
  CHECK(c1.count == c0.count + 1 + extra, "bulk count %lu", (unsigned long)c1.count);
  // stats text
  std::vector<uint8_t> o;
  a.call(kOpStats, {}, &o);
  const std::string t(o.begin(), o.end());
  CHECK(t.find("op.feed.ops=") != std::string::npos && t.find("opt.feed.c_ns=") != std::string::npos &&
        t.find("seq.retries=") != std::string::npos && t.find("stale.commits=") != std::string::npos, "stats keys");
  std::printf("sg-client selftest %s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: sg-client selftest A B id1 id2base | stats A | feed A id1 [limit]\n");
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "selftest" && argc == 6) {
    Client a(argv[2]), b(argv[3]);
    return selftest(a, b, std::stoull(argv[4]), uint32_t(std::stoul(argv[5])));
  }
  Client a(argv[2]);
  if (cmd == "stats") {
    std::vector<uint8_t> o;
    a.call(kOpStats, {}, &o);
    std::fwrite(o.data(), 1, o.size(), stdout);
    return 0;
  }
  if (cmd == "feed" && argc >= 4) {
    Feed f = feed(a, std::stoull(argv[3]), argc > 4 ? uint16_t(std::stoul(argv[4])) : 50);
    std::printf("status %u list_version %lu n %u missing %u\n", f.status, (unsigned long)f.r.list_version, f.r.n, f.r.missing);
    for (auto &r : f.rows)
      std::printf("%u v%u t%lu node_v%lu len%u\n", r.id2, r.link_version, (unsigned long)r.link_time,
                  (unsigned long)r.node_version, r.node_data_len);
    return 0;
  }
  return 2;
}

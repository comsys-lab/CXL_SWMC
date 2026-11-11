// Protocol stub for the socialgraph loadgen plugin (Host loopback test only; not the real server). Checks every request
// against proto.h (sizes, caps, id ranges, feed limit, owner routing, per-target w_seq = previous + 1) and answers with
// well-formed responses (RespHead + body + an OpCoh block on every OK response).
// usage: sg-loadgen-stub <port> <target index> <n targets> <n_orig> <id_base> <seconds> [mod|range (write route, mod)]
// After <seconds> prints counters (key=value) and exits; exit code 0 iff no request violated the protocol.
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../../vectordb/proto.h"
#include "../proto.h"
#include "../server/layout.h"
#include "frame.h"

static uint32_t g_target, g_targets;
static uint64_t g_n, g_base;
static sg::Route g_route = sg::Route::kMod;  // expected write route (layout.h slot_owner)
static std::atomic<uint64_t> g_req[32], g_bad{0}, g_wseq_bad{0}, g_owner_bad{0}, g_writes{0};
static std::mutex g_wmu;
static uint32_t g_last_wseq = 0;
static std::string g_first_bad;

static uint64_t hash64(uint64_t x) {
  x += 0x9e3779b97f4a7c15ull;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
  return x ^ (x >> 31);
}
static void bad(const char *why) {
  if (g_bad.fetch_add(1) == 0) {
    std::lock_guard<std::mutex> g(g_wmu);
    g_first_bad = why;
  }
}
static bool id_ok(uint64_t id) { return id >= g_base && id < g_base + g_n; }

struct Out {
  std::vector<uint8_t> b;
  template <class T> void put(const T &v) {
    const size_t o = b.size();
    b.resize(o + sizeof(T));
    std::memcpy(b.data() + o, &v, sizeof(T));
  }
};

// Returns frame status; fills out with the response payload.
static uint16_t handle(uint16_t op, const std::vector<uint8_t> &p, Out *o) {
  g_req[op & 31].fetch_add(1);
  if (op == sg::kOpStats) {
    const std::string s = "stub=1\nrequests=" + std::to_string(g_writes.load()) + "\n";
    o->b.assign(s.begin(), s.end());
    return frame::kStatusOk;
  }
  sg::RespHead h{op, sg::kStatusOk, sg::kRespCoh, 0, 7, 1};
  Out body;
  auto need = [&](size_t n, const char *why) {
    if (p.size() != n) bad(why);
    return p.size() == n;
  };
  switch (op) {
    case sg::kOpFeed: {
      sg::FeedReq q;
      if (!need(sizeof(q), "feed size")) return frame::kStatusBadRequest;
      std::memcpy(&q, p.data(), sizeof(q));
      if (!id_ok(q.id1) || q.limit != 50 || q.assoc_type != sg::kAssocFriend) return bad("feed fields"), frame::kStatusBadRequest;
      if (hash64(q.id1 ^ g_req[op].load()) % 1000 == 0) {  // RespHead.status 4 (Busy, part 3 proto.h): head only
        h.status = 4;
        break;
      }
      const uint16_t n = uint16_t(std::min<uint64_t>(q.limit, hash64(q.id1) % 120));
      body.put(sg::FeedResp{1, n, 0, 3});
      for (uint16_t i = 0; i < n; i++) body.put(sg::FeedRow{uint32_t(g_base + i), 0, 1, 1, 10, {0, 0, 0}});
      h.records = 1 + n;
      break;
    }
    case sg::kOpGetNode: {
      sg::NodeKeyReq q;
      if (!need(sizeof(q), "getnode size")) return frame::kStatusBadRequest;
      std::memcpy(&q, p.data(), sizeof(q));
      if (!id_ok(q.id)) return bad("getnode id"), frame::kStatusBadRequest;
      const uint16_t dl = uint16_t(hash64(q.id) % (sg::kNodeDataCap + 1));
      body.put(sg::NodeResp{q.id, 1, 0, 2048, 0, dl, {0, 0, 0}});
      body.b.resize(body.b.size() + dl, 'x');
      break;
    }
    case sg::kOpCountLink: {
      sg::LinkListReq q;
      if (!need(sizeof(q), "countlink size")) return frame::kStatusBadRequest;
      std::memcpy(&q, p.data(), sizeof(q));
      if (!id_ok(q.id1) || q.assoc_type != sg::kAssocFriend) return bad("countlink fields"), frame::kStatusBadRequest;
      body.put(sg::CountResp{1, hash64(q.id1) % 500});
      break;
    }
    case sg::kOpGetLink: {
      sg::GetLinkReq q;
      if (p.size() < sizeof(q)) return bad("getlink size"), frame::kStatusBadRequest;
      std::memcpy(&q, p.data(), sizeof(q));
      if (!need(sizeof(q) + size_t(q.n2) * 4, "getlink size n2")) return frame::kStatusBadRequest;
      if (!id_ok(q.id1) || q.n2 < 1 || q.n2 > 127) return bad("getlink fields"), frame::kStatusBadRequest;
      for (uint32_t i = 0; i < q.n2; i++) {
        uint32_t id2;
        std::memcpy(&id2, p.data() + sizeof(q) + 4 * i, 4);
        if (!id_ok(id2)) return bad("getlink id2"), frame::kStatusBadRequest;
      }
      const uint16_t n = q.n2 / 2;
      body.put(sg::GetLinkResp{1, n, {0, 0, 0}});
      for (uint16_t i = 0; i < n; i++) body.put(sg::LinkRow{uint32_t(g_base), 0, 1, 0, {0, 0, 0}});
      break;
    }
    case sg::kOpAddLink: case sg::kOpUpdateLink: case sg::kOpDeleteLink:
    case sg::kOpAddNode: case sg::kOpUpdateNode: case sg::kOpDeleteNode: {
      const bool link = op <= sg::kOpDeleteLink;
      uint64_t id;
      uint32_t wseq, dl, cap;
      size_t hs;
      if (link) {
        sg::LinkWriteReq q;
        if (p.size() < sizeof(q)) return bad("link write size"), frame::kStatusBadRequest;
        std::memcpy(&q, p.data(), sizeof(q));
        id = q.id1, wseq = q.w_seq, dl = q.data_len, cap = sg::kEdgeDataCap, hs = sizeof(q);
        if (!id_ok(q.id2) || q.assoc_type != sg::kAssocFriend || q.time < 1700000000000ull) bad("link write fields");
      } else {
        sg::NodeWriteReq q;
        if (p.size() < sizeof(q)) return bad("node write size"), frame::kStatusBadRequest;
        std::memcpy(&q, p.data(), sizeof(q));
        id = q.id, wseq = q.w_seq, dl = q.data_len, cap = sg::kNodeDataCap, hs = sizeof(q);
        if (q.type != 2048) bad("node type");
      }
      if (p.size() != hs + dl || dl > cap) bad("write data_len");
      if ((op == sg::kOpDeleteLink || op == sg::kOpDeleteNode) && dl) bad("delete with data");
      if (op == sg::kOpAddNode ? id != 0 : !id_ok(id)) bad("write id");
      if (op != sg::kOpAddNode && sg::slot_owner(g_route, id - g_base, g_n, 0, g_targets) != g_target) g_owner_bad.fetch_add(1);
      {
        std::lock_guard<std::mutex> g(g_wmu);
        if (wseq != g_last_wseq + 1) g_wseq_bad.fetch_add(1);
        g_last_wseq = wseq;
      }
      g_writes.fetch_add(1);
      if ((op == sg::kOpUpdateLink || op == sg::kOpDeleteLink) && hash64(wseq) % 10 == 0) h.status = sg::kStatusNotFound;
      body.put(sg::WriteResp{op == sg::kOpAddNode ? g_base + g_n + wseq : id, 2, 123, wseq, 0});
      break;
    }
    default:
      bad("unknown op");
      return frame::kStatusUnknownOp;
  }
  if (h.status != sg::kStatusOk) h.flags = 0;
  o->put(h);
  o->b.insert(o->b.end(), body.b.begin(), body.b.end());
  if (h.flags & sg::kRespCoh) {
    vdb::OpCoh c{};
    c.version = vdb::kOpCohVersion, c.op = op, c.sections = 1;
    o->put(c);
  }
  return frame::kStatusOk;
}

int main(int argc, char **argv) {
  if (argc != 7 && argc != 8)
    return std::fprintf(stderr, "usage: sg-loadgen-stub <port> <target> <targets> <n_orig> <id_base> <seconds> [mod|range]\n"), 2;
  if (argc == 8 && !sg::parse_route(argv[7], &g_route)) return std::fprintf(stderr, "route mod|range\n"), 2;
  const int port = std::atoi(argv[1]);
  g_target = uint32_t(std::atoi(argv[2])), g_targets = uint32_t(std::atoi(argv[3]));
  g_n = std::strtoull(argv[4], nullptr, 10), g_base = std::strtoull(argv[5], nullptr, 10);
  const int secs = std::atoi(argv[6]);
  int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons(uint16_t(port));
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(ls, (sockaddr *)&a, sizeof(a)) || listen(ls, 64)) return std::perror("bind"), 1;
  std::thread([ls, one] {
    for (;;) {
      int fd = accept(ls, nullptr, nullptr);
      if (fd < 0) continue;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      std::thread([fd] {
        frame::header h;
        std::vector<uint8_t> p;
        while (frame::read_full(fd, &h, sizeof(h))) {
          p.resize(frame::payload_len(h));
          if (!p.empty() && !frame::read_full(fd, p.data(), p.size())) break;
          Out o;
          const uint16_t st = handle(h.code, p, &o);
          frame::header r;
          frame::fill(&r, st, h.req_id, uint32_t(o.b.size()));
          if (!frame::write_full(fd, &r, sizeof(r)) || !frame::write_full(fd, o.b.data(), o.b.size())) break;
        }
        close(fd);
      }).detach();
    }
  }).detach();
  sleep(unsigned(secs));
  std::printf("target=%u feed=%lu getnode=%lu countlink=%lu getlink=%lu writes=%lu stats=%lu bad=%lu wseq_bad=%lu "
              "owner_bad=%lu last_wseq=%u first_bad=%s\n", g_target, (unsigned long)g_req[sg::kOpFeed].load(),
              (unsigned long)g_req[sg::kOpGetNode].load(), (unsigned long)g_req[sg::kOpCountLink].load(),
              (unsigned long)g_req[sg::kOpGetLink].load(), (unsigned long)g_writes.load(),
              (unsigned long)g_req[sg::kOpStats].load(), (unsigned long)g_bad.load(), (unsigned long)g_wseq_bad.load(),
              (unsigned long)g_owner_bad.load(), g_last_wseq, g_first_bad.empty() ? "-" : g_first_bad.c_str());
  std::fflush(stdout);
  _exit(g_bad.load() || g_wseq_bad.load() || g_owner_bad.load() ? 1 : 0);
}

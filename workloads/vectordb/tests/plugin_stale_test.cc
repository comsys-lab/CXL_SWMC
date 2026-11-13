// Unit test (Host, no server, no shared memory): the vectordb loadgen plugin's staleness copies (--opt stale_ms,
// --opt search_target; DESIGN.md §20). Updates and searches are made with chosen scheduled times (Request::sched_ns,
// as the engine sets them) and the snapshot of every copy is compared with the rule "insert w_seq of the last update
// scheduled at or before t - T, the initial snapshot before the first update"; history pruning (T_max lookback),
// w_start, search_target, burst(), searches.bin ref_w = sent snapshot and the stale.bin records are checked.
// usage: plugin_stale_test <data dir with pool_b.fbin, queries.fbin (dim 768)> <scratch dir>
// Build: c++ -std=c++17 -O1 -g -Wall -Wextra -pthread -I<CXL_SWMC>/experiments/loadgen plugin_stale_test.cc -o <out>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../loadgen/vectordb_plugin.cc"

namespace loadgen {
std::map<std::string, Factory> &registry() {
  static std::map<std::string, Factory> r;
  return r;
}
}  // namespace loadgen

static int fails = 0;
#define CHECK(c)                                                                     \
  do {                                                                               \
    if (!(c)) std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c), fails++; \
  } while (0)

static const uint64_t MS = 1000000ull;

int main(int argc, char **argv) {
  if (argc != 3) return std::fprintf(stderr, "usage: %s <data dir> <scratch dir>\n", argv[0]), 2;
  const std::string data = argv[1], dir = argv[2];
  // 6 updates to target 0: update u = DELETE w 2u-1 (id u), INSERT w 2u (id 1000 + u, pool B row u)
  std::vector<WriteRec> wr;
  for (uint32_t u = 1; u <= 6; u++) {
    WriteRec d{}, i{};
    d.op = vdb::kOpDelete, d.target = 0, d.w_seq = 2 * u - 1, d.id = u;
    i.op = vdb::kOpInsert, i.target = 0, i.w_seq = 2 * u, i.id = 1000 + u, i.vec_ref = u;
    wr.push_back(d), wr.push_back(i);
  }
  const std::string wf = dir + "/writes-stale.bin";
  FILE *f = std::fopen(wf.c_str(), "wb");
  std::fwrite(wr.data(), sizeof(WriteRec), wr.size(), f);
  std::fclose(f);
  const std::vector<uint32_t> T = {0, 1, 10, 100, 1000};
  std::string err;
  auto w = loadgen::registry().at("vectordb")();
  loadgen::Options o{{"data", data}, {"writes", wf}, {"stale_ms", "0,1,10,100,1000"}, {"search_target", "1"}};
  CHECK(w->init(o, 2, &err));
  if (!err.empty()) std::fprintf(stderr, "init: %s\n", err.c_str());
  CHECK(w->burst(0) == 1 && w->burst(1) == 5);
  std::vector<uint8_t> p;
  auto update = [&](uint64_t t_ms) {
    loadgen::Request r;
    r.sched_ns = t_ms * MS;
    p.clear();
    CHECK(w->make(0, &r, &p));
    CHECK(r.target == 0);
  };
  uint64_t seq = 0;
  // one arrival at t: 5 copies, same target 1, consecutive seqs, snapshots as expected
  auto search = [&](uint64_t t_ms, std::vector<uint32_t> want) {
    for (size_t i = 0; i < T.size(); i++) {
      loadgen::Request r;
      r.sched_ns = t_ms * MS;
      p.clear();
      CHECK(w->make(1, &r, &p));
      vdb::SearchReq q;
      std::memcpy(&q, p.data(), sizeof(q));
      CHECK(r.target == 1 && r.op == vdb::kOpSearch && r.seq == seq);
      if (q.ref_w != want[i])
        std::fprintf(stderr, "t=%lu ms T=%u ms: snapshot %u, expected %u\n", (unsigned long)t_ms, T[i], q.ref_w, want[i]);
      CHECK(q.ref_w == want[i]);
      // response: OK, n = 0 (enough for the record path)
      vdb::SearchResp sr{};
      sr.s_used = q.ref_w;
      loadgen::Request back{1, r.target, vdb::kOpSearch, r.seq};
      w->on_response(back, true, frame::kStatusOk, reinterpret_cast<const uint8_t *>(&sr), sizeof(sr));
      seq++;
    }
  };
  search(500, {0, 0, 0, 0, 0});  // before the first update: the initial snapshot (0) for every T
  update(1000);                  // w 2
  update(1005);                  // w 4
  update(1050);                  // w 6
  update(1200);                  // w 8
  search(1201, {8, 8, 6, 6, 0});  // cutoffs 1200 (at or before: 8), 1191, 1101, 201 (before the stream: initial)
  update(1250);                   // w 10
  search(1300, {10, 10, 10, 8, 0});  // cutoff 1200 for T = 100: the update scheduled exactly then (8)
  update(2500);                      // w 12
  search(2600, {12, 12, 12, 12, 10});  // T = 1000: cutoff 1600 -> update at 1250 (10); history pruned to it
  CHECK(w->finish(dir, &err));
  {  // stale.bin: one record per search made, in seq order
    FILE *sf = std::fopen((dir + "/stale.bin").c_str(), "rb");
    CHECK(sf != nullptr);
    std::vector<StaleLog> sl(64);
    const size_t n = sf ? std::fread(sl.data(), sizeof(StaleLog), sl.size(), sf) : 0;
    if (sf) std::fclose(sf);
    CHECK(n == 20);
    const uint32_t fresh[4] = {0, 8, 10, 12};
    for (size_t i = 0; i < n; i++) {
      const StaleLog &x = sl[i];
      CHECK(x.seq == i && x.group == i / 5 && x.t_idx == i % 5 && x.t_ms == T[i % 5]);
      CHECK(x.fresh == fresh[i / 5] && (x.flags & 3) == 3 && x.status == 0);
      CHECK(x.t_idx != 0 || x.sent == x.fresh);  // T = 0 copy = the fresh E1 snapshot
      CHECK(i % 5 == 0 || x.sent <= sl[i - 1].sent);  // non-increasing in T
    }
    CHECK(sl[16].sched_ns == 2600 * MS && sl[19].sent == 10);
  }
  {  // searches.bin: ref_w = sent snapshot
    FILE *sf = std::fopen((dir + "/searches.bin").c_str(), "rb");
    std::vector<uint8_t> b(1 << 16);
    const size_t n = sf ? std::fread(b.data(), 1, b.size(), sf) : 0;
    if (sf) std::fclose(sf);
    const size_t rs = sizeof(SearchLog) + 10 * 12;
    CHECK(n == 20 * rs);
    for (size_t i = 0; i * rs < n; i++) {
      SearchLog lg;
      std::memcpy(&lg, b.data() + i * rs, sizeof(lg));
      CHECK(lg.seq == i && lg.ref_w == lg.s_used);
    }
  }
  {  // w_start = 4 (two updates done earlier): the initial snapshot is 4; bad options are refused
    auto w2 = loadgen::registry().at("vectordb")();
    loadgen::Options o2{{"data", data}, {"writes", wf}, {"stale_ms", "0,10"}, {"w_start", "4"}};
    CHECK(w2->init(o2, 2, &err));
    loadgen::Request r;
    r.sched_ns = 20 * MS;
    vdb::SearchReq q;
    for (int i = 0; i < 2; i++) {
      p.clear();
      CHECK(w2->make(1, &r, &p));
      std::memcpy(&q, p.data(), sizeof(q));
      CHECK(q.ref_w == 4);
    }
    for (const char *bad : {"0,1,1", "x", "0,,1", "-1", ""}) {
      auto w3 = loadgen::registry().at("vectordb")();
      loadgen::Options o3{{"data", data}, {"writes", wf}, {"stale_ms", bad}};
      std::string e;
      const bool okb = w3->init(o3, 2, &e);
      CHECK(okb == (std::string(bad).empty()));  // empty = option off
      std::fprintf(stderr, "stale_ms '%s' -> %s\n", bad, okb ? "accepted (off)" : e.c_str());
    }
    auto w4 = loadgen::registry().at("vectordb")();
    loadgen::Options o4{{"data", data}, {"writes", wf}, {"search_target", "2"}};
    std::string e;
    CHECK(!w4->init(o4, 2, &e));
    std::fprintf(stderr, "search_target 2 of 2 -> %s\n", e.c_str());
  }
  {  // default (no stale_ms): one request per arrival, ref_w = last update made, target drawn
    auto w5 = loadgen::registry().at("vectordb")();
    loadgen::Options o5{{"data", data}, {"writes", wf}};
    CHECK(w5->init(o5, 2, &err) && w5->burst(1) == 1);
  }
  std::fprintf(stderr, "%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
  return fails ? 1 : 0;
}

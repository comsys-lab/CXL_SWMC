// Unit test (Host, no server, no shared memory): the vectordb loadgen plugin's update stream.
// usage: plugin_pairs_test <data dir with pool_b.fbin, queries.fbin> <scratch dir>
// Writes small writes files into the scratch dir (gen_writes.py record format) and checks: update pairs accepted and
// sent as one kOpUpdate (w_del, w_ins = w_del + 1, same target, ids, pool B vector), the E1 ref_w of a later search =
// the insert's w_seq, response checking (w_seq), and rejection of non-pair files.
// Build: tests/build_plugin_pairs_test.sh <out>
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
#define CHECK(c)                                                    \
  do {                                                              \
    if (!(c)) std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c), fails++; \
  } while (0)

static std::string write_file(const std::string &path, const std::vector<WriteRec> &w) {
  FILE *f = std::fopen(path.c_str(), "wb");
  std::fwrite(w.data(), sizeof(WriteRec), w.size(), f);
  std::fclose(f);
  return path;
}

static WriteRec rec(uint8_t op, uint8_t target, uint32_t w_seq, uint64_t id, uint32_t vec_ref) {
  WriteRec r{};
  r.op = op, r.target = target, r.w_seq = w_seq, r.id = id, r.vec_ref = vec_ref;
  return r;
}

int main(int argc, char **argv) {
  if (argc != 3) return std::fprintf(stderr, "usage: %s <data dir> <scratch dir>\n", argv[0]), 2;
  const std::string data = argv[1], dir = argv[2];
  auto make = [&](const std::string &writes, std::string *err) {
    auto w = loadgen::registry().at("vectordb")();
    loadgen::Options o{{"data", data}, {"writes", writes}};
    bool ok = w->init(o, 2, err);
    return std::make_pair(std::move(w), ok);
  };
  using vdb::kOpDelete;
  using vdb::kOpInsert;
  // good: two updates, targets 1 and 0
  const std::string good = write_file(dir + "/good.bin", {rec(kOpDelete, 1, 1, 7, 0), rec(kOpInsert, 1, 2, 100, 3),
                                                          rec(kOpDelete, 0, 3, 100, 0), rec(kOpInsert, 0, 4, 101, 4)});
  std::string err;
  auto [w, ok] = make(good, &err);
  CHECK(ok);
  if (!ok) std::fprintf(stderr, "init: %s\n", err.c_str());
  auto streams = w->streams();
  CHECK(streams.size() == 2 && streams[0].name == "update" && streams[0].ordered && streams[1].name == "search");
  loadgen::Request r;
  std::vector<uint8_t> p;
  CHECK(w->make(0, &r, &p));
  vdb::UpdateReq u;
  CHECK(p.size() == sizeof(u) + 768 * 4);
  std::memcpy(&u, p.data(), sizeof(u));
  CHECK(r.op == vdb::kOpUpdate && r.target == 1 && r.seq == 0);
  CHECK(u.w_del == 1 && u.w_ins == 2 && u.del_id == 7 && u.ins_id == 100);
  {  // vector = pool B row 3
    Fbin b;
    std::string e;
    CHECK(b.open(data + "/pool_b.fbin", &e));
    CHECK(std::memcmp(p.data() + sizeof(u), b.rows + 3 * 768, 768 * 4) == 0);
  }
  p.clear();
  CHECK(w->make(1, &r, &p));  // search after the first update: ref_w = 2
  vdb::SearchReq sq;
  std::memcpy(&sq, p.data(), sizeof(sq));
  CHECK(r.op == vdb::kOpSearch && sq.ref_w == 2);
  p.clear();
  CHECK(w->make(0, &r, &p));
  std::memcpy(&u, p.data(), sizeof(u));
  CHECK(r.target == 0 && r.seq == 1 && u.w_del == 3 && u.w_ins == 4 && u.del_id == 100 && u.ins_id == 101);
  p.clear();
  CHECK(!w->make(0, &r, &p));  // exhausted
  // responses: correct w_seq for update 1 is 4; a wrong one counts as a write error
  vdb::WriteResp ok_resp{4, 4}, bad_resp{3, 4};
  loadgen::Request q1{0, 0, vdb::kOpUpdate, 1};
  w->on_response(q1, true, frame::kStatusOk, reinterpret_cast<const uint8_t *>(&ok_resp), sizeof(ok_resp));
  CHECK(w->finish(dir, &err));
  w->on_response(q1, true, frame::kStatusOk, reinterpret_cast<const uint8_t *>(&bad_resp), sizeof(bad_resp));
  CHECK(!w->finish(dir, &err));
  // rejected files
  struct Bad {
    const char *name;
    std::vector<WriteRec> w;
  } bad[] = {
      {"odd", {rec(kOpDelete, 0, 1, 7, 0), rec(kOpInsert, 0, 2, 100, 0), rec(kOpDelete, 0, 3, 8, 0)}},
      {"order", {rec(kOpInsert, 0, 1, 100, 0), rec(kOpDelete, 0, 2, 7, 0)}},
      {"target", {rec(kOpDelete, 0, 1, 7, 0), rec(kOpInsert, 1, 2, 100, 0)}},
      {"two-deletes", {rec(kOpDelete, 0, 1, 7, 0), rec(kOpDelete, 0, 2, 8, 0)}},
  };
  for (auto &b : bad) {
    std::string e;
    auto [x, okb] = make(write_file(dir + "/bad-" + b.name + ".bin", b.w), &e);
    CHECK(!okb);
    std::fprintf(stderr, "reject %-12s -> %s\n", b.name, e.c_str());
  }
  // the generator's own files: update mode accepted, independent mode rejected
  for (const char *f : {"writes.bin", "writes-indep.bin"}) {
    std::string e;
    auto [x, okg] = make(data + "/" + f, &e);
    CHECK(okg == (std::string(f) == "writes.bin"));
    std::fprintf(stderr, "%-18s -> %s\n", f, okg ? "accepted" : e.c_str());
  }
  std::fprintf(stderr, "%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
  return fails ? 1 : 0;
}

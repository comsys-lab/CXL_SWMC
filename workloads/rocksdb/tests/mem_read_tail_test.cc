// Unit test of MegalonBackend::mem_read at a block tail (verifier LOW-1, 2026-11-03). Host only, no Megalon library:
// a fake object API over a heap buffer (one 1 MiB slot per object, objects contiguous, every neighbour filled 0xff).
// Checks: a 5-byte varint probe of an entry whose varint ends in the last 2 bytes of a block copies only those bytes
// inside that block's read section, zeroes the rest (decodes to the right length), opens no section on the neighbour
// object, and counts one tail clamp; a read in the middle of a block is unchanged and not clamped.
// build (needs a rocksdb build tree for rocksdb/cxl.h + librocksdb.a, e.g. builds/rocksdb/<n>):
//   c++ -std=c++20 -O1 -g -pthread -DROCKSDB_USE_RTTI -I<B>/rocksdb-src/include -I<wt>/workloads/rocksdb \
//     -I<wt>/workloads/rocksdb/server -I<wt>/systems/common -I<wt>/systems/megalon/shim -I<wt>/experiments/loadgen \
//     -I<wt>/systems/popcorn_new/include -I<wt>/workloads/kv/server tests/mem_read_tail_test.cc \
//     <B>/rocksdb-build/librocksdb.a -ldl -o mem_read_tail_test && ./mem_read_tail_test   -> "MEM READ TAIL TEST PASS"
// backend.h's own includes first (include guards), so the private -> public define reaches only backend.h's classes,
// not libstdc++ (which rejects redeclared access) or the RocksDB / region headers
#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "cxl_region.h"
#include "layout.h"
#include "megalon_objapi.h"
#include "rocksdb/cxl.h"
#define private public  // test access to MegalonBackend::mem_read / tail_clamps_ (no production API added)
#include "backend.h"
#undef private

#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>

using rdbw::kUnit;
using rdbw::MegalonBackend;

namespace {
constexpr uint32_t kNodes = 2, kBlocks = 2, kExt = 1;
uint8_t *g_buf = nullptr;
std::map<uint64_t, uint8_t *> g_obj;  // id -> slot
std::set<uint64_t> g_read_ids;
int fails = 0;
void check(bool ok, const char *what) {
  if (!ok) { std::printf("FAIL %s\n", what); fails++; }
}
size_t f_node() { return 0; }
void f_reg(int) {}
void f_unreg() {}
int f_create(uint64_t, size_t) { return 0; }
int f_lookup(uint64_t id, size_t *sz) { *sz = kUnit; return g_obj.count(id) ? 0 : -2; }
int f_read_start(uint64_t id, mshim::Obj *h) {
  g_read_ids.insert(id);
  h->ptr = g_obj.at(id); h->size = kUnit; h->id = id; h->token = 0;
  return 0;
}
bool f_read_end(mshim::Obj *) { return true; }
int f_write_start(uint64_t id, mshim::Obj *h) { return f_read_start(id, h); }
void f_write_end(mshim::Obj *) {}
void f_stats(mshim::Stats *s) { *s = mshim::Stats{}; }
}  // namespace

int main() {
  mshim::Api api{};
  api.version = mshim::kApiVersion; api.info = "fake"; api.node_id = f_node; api.reg = f_reg; api.unreg = f_unreg;
  api.create = f_create; api.lookup = f_lookup; api.read_start = f_read_start; api.read_end = f_read_end;
  api.write_start = f_write_start; api.write_end = f_write_end; api.stats = f_stats;
  const size_t nobj = kNodes * (kBlocks + kExt);
  g_buf = static_cast<uint8_t *>(std::aligned_alloc(kUnit, nobj * kUnit));
  std::memset(g_buf, 0xff, nobj * kUnit);
  size_t k = 0;  // layout: node-major, blocks then extents, contiguous (block (1,0) is followed by block (1,1))
  for (uint32_t v = 0; v < kNodes; v++)
    for (uint32_t kind = 0; kind < 2; kind++)
      for (uint64_t i = 0; i < (kind ? kExt : kBlocks); i++) g_obj[MegalonBackend::id(kind, v, i)] = g_buf + kUnit * k++;
  rdbw::Params p; p.nr_nodes = kNodes; p.arena_blocks = kBlocks; p.file_extents = kExt; p.keys = 1;
  rdbw::SwccPlan plan; plan.arena_blocks = kBlocks; plan.file_extents = kExt;
  cxl::region r;
  std::string err;
  MegalonBackend be(&api);
  check(be.setup(r, nullptr, p, plan, 0, &err), "setup");
  uint8_t *b10 = g_obj.at(MegalonBackend::id(0, 1, 0));
  check(g_obj.at(MegalonBackend::id(0, 1, 1)) == b10 + kUnit, "neighbour block contiguous (test layout)");
  // varint 133 = 0x85 0x01 in the last two bytes of block (1, 0)
  b10[kUnit - 2] = 0x85; b10[kUnit - 1] = 0x01;
  uint8_t out[5];
  std::memset(out, 0xaa, sizeof(out));
  g_read_ids.clear();
  be.mem_read(1, b10 + kUnit - 2, out, 5);
  check(out[0] == 0x85 && out[1] == 0x01 && out[2] == 0 && out[3] == 0 && out[4] == 0, "tail bytes copied, rest zeroed");
  uint32_t len = 0, used = 0;  // LEB128 as RocksDB's GetVarint32Ptr
  for (int s = 0; used < 5; s += 7) {
    const uint8_t c = out[used++];
    len |= uint32_t(c & 0x7f) << s;
    if (!(c & 0x80)) break;
  }
  check(len == 133 && used == 2, "varint decodes to 133 from the clamped copy");
  check(g_read_ids.size() == 1 && g_read_ids.count(MegalonBackend::id(0, 1, 0)), "only block (1,0) opened a read section");
  check(be.tail_clamps_.load() == 1, "one tail clamp counted");
  // a read in the middle is not clamped
  std::memcpy(b10 + 4096, "abcde", 5);
  be.mem_read(1, b10 + 4096, out, 5);
  check(std::memcmp(out, "abcde", 5) == 0 && be.tail_clamps_.load() == 1, "middle read unchanged, no clamp");
  // a read ending exactly at the block end is not clamped
  be.mem_read(1, b10 + kUnit - 5, out, 5);
  check(be.tail_clamps_.load() == 1 && out[3] == 0x85 && out[4] == 0x01, "read ending at the block end not clamped");
  std::printf("MEM READ TAIL TEST %s\n", fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}

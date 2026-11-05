// Host test (no device, no server): layout parameters of the page-granularity change (experiment
// megalon-page-granularity; server/shm_hnsw.h small-group upper reserve, server/layout.h objseq only with --trace-dir).
//  1. The 32 MiB chunk layout of the run-2 Megalon cells is unchanged: describe() text, HWcc app layout hash / bytes /
//     used, per_chunk / groups / vchunk / lchunk / upper arena = the values vdb-megalon/17-n2 printed in
//     recovery/eval-run2-vdb-mg-u50-n2-r1-v1 (node logs "app layout 303104 B (used 300480, hash aadebbc8a54ab6b3)").
//     Same for the per-chunk host-smoke layout (1 MiB chunks, objseq kept: small object count).
//  2. The 4 KiB layout (run-2 parameters, --chunk-bytes 4096, sq8): 4 records per group, 8 upper blocks (1,024 B),
//     link chunk 1,792 B, vector chunk 3,328 B, describe() marks it, objseq only with trace, layout fits a 256 MiB
//     HWcc range with and without trace; object bytes (Megalon arena) printed for systems/megalon/vectordb-2vm-c4k.yaml.
// usage: page_layout_test   (exit 0 = PASS)
#include <cstdio>
#include <string>

#include "layout.h"

namespace {
int fails = 0;
template <class A, class B> void eq(const char *what, const A &got, const B &want) {
  const bool ok = got == want;
  if (!ok) fails++;
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) std::printf("     got  %s\n     want %s\n", std::to_string(got).c_str(), std::to_string(want).c_str());
}
void eqs(const char *what, const std::string &got, const std::string &want) {
  const bool ok = got == want;
  if (!ok) fails++;
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) std::printf("     got  %s\n     want %s\n", got.c_str(), want.c_str());
}
vdb::Params run2(uint64_t chunk) {  // run-2 Megalon cell parameters (eval-run2-vdb.conf, node log describe())
  vdb::Params p;
  p.nr_nodes = 2, p.segments = 32, p.g.dim = 768, p.g.M = 16, p.g.ef_construction = 128, p.g.chunk_bytes = chunk;
  p.max_writes = 2097152, p.max_ids = 57400000, p.dlog_chunk = 4096, p.max_deletes = 1048576, p.g.vec_format = vdb::kVecSQ8;
  p.derive();
  return p;
}
uint64_t object_bytes(const vdb::Params &p) {  // megalon_backend.h usage(): every object rounded to whole lines
  auto r = [](uint64_t x) { return (x + 63) / 64 * 64; };
  return uint64_t(p.segments) * p.g.groups() * (r(p.g.vchunk_bytes()) + r(p.g.lchunk_bytes())) +
         uint64_t(p.nr_nodes) * p.dlog_chunks() * r(uint64_t(p.dlog_chunk) * sizeof(vdb::DlogEntry));
}
}  // namespace

int main() {
  {  // 1. run-2 32 MiB layout (Megalon tag)
    for (bool tr : {false, true}) {
      vdb::Params p = run2(32ull << 20);
      p.trace = tr;
      std::printf("-- 32 MiB run-2 layout, trace %d\n", int(tr));
      eqs("describe", p.describe(),
          "nr_nodes=2 segments=32 dim=768 M=16 efc=128 capacity=1793750 chunk_bytes=33554432 max_writes=2097152 "
          "max_ids=57400000 dlog_chunk=4096 max_deletes=1048576 vec=sq8");
      vdb::HwccLayout h(p, " backend=megalon");
      eq("hash aadebbc8a54ab6b3", h.L.hash(), 0xaadebbc8a54ab6b3ull);
      eq("app bytes", h.L.bytes(), uint64_t(303104));
      eq("app used", h.L.used(), uint64_t(300480));
      eq("per_chunk", p.g.per_chunk(), uint64_t(40329));
      eq("groups", p.g.groups(), uint64_t(45));
      eq("vchunk", p.g.vchunk_bytes(), uint64_t(33553728));
      eq("lchunk", p.g.lchunk_bytes(), uint64_t(9127872));
      eq("upper arena (old formula)", p.g.upper_group_bytes(), (40329ull * 4 / 15 + 64) * 128);
      eq("not small groups", int(p.g.small_groups()), 0);
      eq("objseq kept", int(h.off_objseq != 0), 1);
      eq("object bytes (run-2 log object_bytes=61595721728)", object_bytes(p), uint64_t(61595721728ull));
    }
  }
  {  // 1b. host-smoke style layout: fp32, 1 MiB chunks, plain tag; the old formula and objseq
    vdb::Params p;
    p.segments = 4, p.g.chunk_bytes = 1 << 20, p.max_ids = 300000, p.max_writes = 200000, p.max_deletes = 200000,
    p.dlog_chunk = 256;
    p.derive();
    std::printf("-- 1 MiB fp32 layout\n");
    eq("per_chunk 334", p.g.per_chunk(), uint64_t(334));
    eq("upper arena (old formula)", p.g.upper_group_bytes(), (334ull * 4 / 15 + 64) * 128);
    eq("describe has no upper_blocks", int(p.describe().find("upper_blocks") == std::string::npos), 1);
    eq("objseq kept", int(vdb::HwccLayout(p).off_objseq != 0), 1);
  }
  {  // 2. 4 KiB layout
    for (bool tr : {false, true}) {
      vdb::Params p = run2(4096);
      p.trace = tr;
      std::printf("-- 4 KiB layout, trace %d\n", int(tr));
      eq("per_chunk 4", p.g.per_chunk(), uint64_t(4));
      eq("small groups", int(p.g.small_groups()), 1);
      eq("upper blocks 8", p.g.upper_group_blocks(), uint64_t(8));
      eq("upper arena 1024", p.g.upper_group_bytes(), uint64_t(1024));
      eq("lchunk 1792", p.g.lchunk_bytes(), uint64_t(1792));
      eq("vchunk 3328", p.g.vchunk_bytes(), uint64_t(3328));
      eq("groups", p.g.groups(), uint64_t((1793750 + 3) / 4));
      eq("describe marks small groups", int(p.describe().find(" upper_blocks=8") != std::string::npos), 1);
      vdb::HwccLayout h(p, " backend=megalon");
      eq("objseq only with trace", int(h.off_objseq != 0), int(tr));
      eq("app range fits 256 MiB", int(h.L.bytes() <= (256ull << 20)), 1);
      // max upper levels an element can have in a group: 8 blocks; the record of the largest index level stays valid
      vdb::ElemHeader e{};
      e.ext_id = 1, e.level = 8, e.upper_off = 0, e.check = vdb::elem_check(1, 0, 8);
      eq("level 8 at upper_off 0 accepted", int(vdb::elem_header_ok(e, p.g)), 1);
      e.upper_off = 128;
      eq("level 8 at upper_off 128 rejected", int(vdb::elem_header_ok(e, p.g)), 0);
      std::printf("info: objects=%lu object_bytes=%lu (%.2f GiB) trace_objects=%lu app_bytes=%lu hash=%016lx\n",
                  (unsigned long)(uint64_t(p.segments) * p.g.groups() * 2 + p.nr_nodes * p.dlog_chunks()),
                  (unsigned long)object_bytes(p), object_bytes(p) / double(1ull << 30), (unsigned long)p.trace_objects(),
                  (unsigned long)h.L.bytes(), (unsigned long)h.L.hash());
    }
  }
  std::printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}

// Offline (Host): relayout an init image (tools/build_index.cc output, per-chunk files, e.g. 32 MiB chunks) into the
// 4 KiB-page layout of experiment megalon-page-granularity (--chunk-bytes 4096: 4 sq8 records per group, small-group
// upper arena of 8 blocks, shm_hnsw.h) as a packed image (server.cc ImageStream: seg-<s>-v.bin / seg-<s>-l.bin).
// Same graph: element ids are segment-local indices and stay unchanged, so every link block, level, entry point and
// count is copied as is. Only the place of the upper-level link blocks changes: element i moves to group i / 4, slot
// i % 4; its upper blocks move into the new group's arena at a per-group cursor (reset at i % 4 == 0, element order,
// exactly as HnswT::insert assigns them), and the header's upper_off is rewritten (the canary excludes upper_off).
// segments.txt upper_cur = cursor of the last group after its last element.
// An element group whose upper blocks exceed the arena (8 blocks) is reported (segment, group, levels) and the tool
// exits 1 before writing any output (phase 1 scans every header first).
// usage: vdb-relayout-c4k relayout <in dir> <out dir (must not exist)> [threads 8] [chunk_bytes 4096]
//        vdb-relayout-c4k verify   <in dir> <out dir> [threads 8]
//   relayout writes out/seg-<s>-v.bin, seg-<s>-l.bin, segments.txt, sq8.bin (copy), manifest.txt (input / rows / seed /
//   sq8 lines copied, params = describe() with the new chunk size, graph line, per_chunk line, "image packed", the
//   run-2 4 KiB layout describe() + HWcc layout hash for reference).
//   verify re-reads both images from disk: counts and segments.txt, every header (old bytes except upper_off, new
//   upper_off = recomputed cursor, elem_header_ok(new params), ext_id = s + segments x i, ins_seq 0), every vector
//   record byte (full, not sampled), every level-0 and upper-level link block (byte-equal, neighbour counts and ids in
//   range), unused link bytes zero, sq8.bin equal. Prints one summary line per segment and "RELAYOUT VERIFY PASS".
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "../server/layout.h"

namespace {

std::mutex g_mu;

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "vdb-relayout-c4k: %s\n", m.c_str());
  std::exit(1);
}

struct Map {  // read-only mapping of a whole file
  const uint8_t *p = nullptr;
  uint64_t n = 0;
  Map() = default;
  Map(const std::string &path, uint64_t want) {
    const int fd = open(path.c_str(), O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) die(path + ": missing");
    n = uint64_t(st.st_size);
    if (n != want) die(path + ": size " + std::to_string(n) + " != " + std::to_string(want));
    if (n) {
      void *m = mmap(nullptr, n, PROT_READ, MAP_SHARED, fd, 0);
      if (m == MAP_FAILED) die("mmap " + path);
      madvise(m, n, MADV_SEQUENTIAL);
      p = static_cast<const uint8_t *>(m);
    }
    close(fd);
  }
  Map(const Map &) = delete;
  Map &operator=(const Map &) = delete;
  Map(Map &&o) noexcept : p(o.p), n(o.n) { o.p = nullptr, o.n = 0; }
  ~Map() {
    if (p) munmap(const_cast<uint8_t *>(p), n);
  }
};

struct Image {  // manifest + segments.txt of an init dir
  vdb::Params p;  // segments, g (dim, M, efc, capacity, chunk_bytes, vec_format); max_ids etc. from params= if present
  std::string params_line, input_line, rows_line, seed_line, sq8_line;
  bool packed = false;
  struct Seg { uint64_t count, epl, ucur; };
  std::vector<Seg> segs;
};

uint64_t field(const std::string &s, const std::string &key) {  // "key=<n>" inside a describe() text
  const std::string t = " " + s, k = " " + key + "=";
  const size_t a = t.find(k);
  if (a == std::string::npos) die("params line without " + key);
  return std::strtoull(t.c_str() + a + k.size(), nullptr, 10);
}

Image read_image(const std::string &dir) {
  Image im;
  std::ifstream man(dir + "/manifest.txt");
  if (!man) die(dir + "/manifest.txt: missing");
  bool graph = false;
  for (std::string line; std::getline(man, line);) {
    if (line.rfind("graph ", 0) == 0) {
      std::istringstream is(line.substr(6));
      is >> im.p.segments >> im.p.g.dim >> im.p.g.M >> im.p.g.ef_construction >> im.p.g.capacity >> im.p.g.chunk_bytes;
      graph = bool(is);
    } else if (line == "vec_format sq8") {
      im.p.g.vec_format = vdb::kVecSQ8;
    } else if (line == "image packed") {
      im.packed = true;
    } else if (line.rfind("params=", 0) == 0) {
      im.params_line = line.substr(7);
    } else if (line.rfind("input=", 0) == 0) {
      im.input_line = line;
    } else if (line.rfind("rows=", 0) == 0) {
      im.rows_line = line;
    } else if (line.rfind("seed=", 0) == 0) {
      im.seed_line = line;
    } else if (line.rfind("sq8 ", 0) == 0) {
      im.sq8_line = line;
    }
  }
  if (!graph) die("no graph line in " + dir + "/manifest.txt");
  if (!im.params_line.empty()) {
    im.p.nr_nodes = uint32_t(field(im.params_line, "nr_nodes"));
    im.p.max_writes = field(im.params_line, "max_writes");
    im.p.max_ids = field(im.params_line, "max_ids");
    im.p.dlog_chunk = uint32_t(field(im.params_line, "dlog_chunk"));
    im.p.max_deletes = field(im.params_line, "max_deletes");
  }
  std::ifstream f(dir + "/segments.txt");
  uint64_t s, c, e, u;
  while (f >> s >> c >> e >> u) {
    if (s != im.segs.size()) die("segments.txt not in segment order");
    if (c > im.p.g.capacity) die("segments.txt: count > capacity");
    im.segs.push_back({c, e, u});
  }
  if (im.segs.size() != im.p.segments) die("segments.txt rows != segments");
  return im;
}

// Old (per-chunk files) segment, mapped
struct OldSeg {
  std::vector<Map> v, l;
  uint64_t N, vr, l0, lb, ubase;
  OldSeg(const std::string &dir, uint32_t s, uint64_t count, const vdb::GraphParams &g) {
    N = g.per_chunk(), vr = g.vrec_bytes(), l0 = g.links0_bytes(), lb = g.links_bytes(), ubase = N * l0;
    const uint64_t G = (count + N - 1) / N;
    const std::string b = dir + "/seg-" + std::to_string(s);
    for (uint64_t gi = 0; gi < G; gi++) {
      v.emplace_back(b + "-v" + std::to_string(gi) + ".bin", std::min(N, count - gi * N) * vr);
      l.emplace_back(b + "-l" + std::to_string(gi) + ".bin", g.lchunk_bytes());
    }
  }
  const uint8_t *rec(uint64_t i) const { return v[i / N].p + (i % N) * vr; }
  const vdb::ElemHeader &hdr(uint64_t i) const { return *reinterpret_cast<const vdb::ElemHeader *>(rec(i)); }
  const uint8_t *l0blk(uint64_t i) const { return l[i / N].p + (i % N) * l0; }
  const uint8_t *upper(uint64_t i, uint64_t uo) const { return l[i / N].p + ubase + uo; }  // first upper block
};

// Phase 1 per segment: old headers checked, new upper_off per element (cursor per 4-record group); returns the
// overflowing groups as text (empty = fits)
std::string plan_segment(const Image &in, const vdb::GraphParams &ng, uint32_t s, const OldSeg &o,
                         std::vector<uint32_t> *new_uo, uint64_t *ucur_last, uint64_t *max_used) {
  const uint64_t count = in.segs[s].count, N = ng.per_chunk(), lb = ng.links_bytes(), cap = ng.upper_group_bytes();
  new_uo->assign(count, 0);
  std::string bad;
  uint64_t cur = 0;
  *max_used = 0;
  for (uint64_t i = 0; i < count; i++) {
    const vdb::ElemHeader &h = o.hdr(i);
    if (!vdb::elem_header_ok(h, in.p.g)) die("segment " + std::to_string(s) + " element " + std::to_string(i) + ": old header fails elem_header_ok");
    if (h.ext_id != s + uint64_t(in.p.segments) * i || h.ins_seq != 0)
      die("segment " + std::to_string(s) + " element " + std::to_string(i) + ": unexpected ext_id / ins_seq");
    if (i % N == 0) cur = 0;
    if (h.level > 0) {
      (*new_uo)[i] = uint32_t(cur);
      cur += uint64_t(h.level) * lb;
    }
    *max_used = std::max(*max_used, cur);
    if ((i % N == N - 1 || i + 1 == count) && cur > cap) {
      std::string lv;
      for (uint64_t j = i - i % N; j <= i; j++) lv += (lv.empty() ? "" : ",") + std::to_string(o.hdr(j).level);
      bad += "segment " + std::to_string(s) + " group " + std::to_string(i / N) + ": upper levels " + lv + " = " +
             std::to_string(cur / lb) + " blocks > " + std::to_string(cap / lb) + "\n";
    }
  }
  *ucur_last = cur;
  return bad;
}

void write_segment(const std::string &out, const vdb::GraphParams &ng, uint32_t s, uint64_t count, const OldSeg &o,
                   const std::vector<uint32_t> &new_uo) {
  const uint64_t N = ng.per_chunk(), vr = ng.vrec_bytes(), l0 = ng.links0_bytes(), lb = ng.links_bytes(),
                 lc = ng.lchunk_bytes(), ubase = N * l0, G = (count + N - 1) / N;
  const std::string b = out + "/seg-" + std::to_string(s);
  FILE *fv = std::fopen((b + "-v.bin").c_str(), "wb"), *fl = std::fopen((b + "-l.bin").c_str(), "wb");
  if (!fv || !fl) die("cannot create " + b + "-{v,l}.bin");
  std::vector<char> bv(8 << 20), bl(8 << 20);
  std::setvbuf(fv, bv.data(), _IOFBF, bv.size());
  std::setvbuf(fl, bl.data(), _IOFBF, bl.size());
  std::vector<uint8_t> rec(vr), lchunk(lc);
  for (uint64_t gi = 0; gi < G; gi++) {
    std::fill(lchunk.begin(), lchunk.end(), 0);
    for (uint64_t i = gi * N; i < std::min(count, (gi + 1) * N); i++) {
      std::memcpy(rec.data(), o.rec(i), vr);
      vdb::ElemHeader h;
      std::memcpy(&h, rec.data(), sizeof(h));
      h.upper_off = h.level ? new_uo[i] : 0;
      std::memcpy(rec.data(), &h, sizeof(h));
      if (std::fwrite(rec.data(), 1, vr, fv) != vr) die("write " + b + "-v.bin");
      std::memcpy(lchunk.data() + (i % N) * l0, o.l0blk(i), l0);
      if (h.level) std::memcpy(lchunk.data() + ubase + h.upper_off, o.upper(i, o.hdr(i).upper_off), h.level * lb);
    }
    if (std::fwrite(lchunk.data(), 1, lc, fl) != lc) die("write " + b + "-l.bin");
  }
  if (std::fclose(fv) != 0 || std::fclose(fl) != 0) die("close " + b + "-{v,l}.bin");
}

vdb::Params run2_c4k() {  // run-2 Megalon cell parameters (tests/page_layout_test.cc run2) with --chunk-bytes 4096
  vdb::Params p;
  p.nr_nodes = 2, p.segments = 32, p.g.dim = 768, p.g.M = 16, p.g.ef_construction = 128, p.g.chunk_bytes = 4096;
  p.max_writes = 2097152, p.max_ids = 57400000, p.dlog_chunk = 4096, p.max_deletes = 1048576, p.g.vec_format = vdb::kVecSQ8;
  p.derive();
  return p;
}

template <class F> void for_segments(uint32_t n, unsigned threads, F f) {
  std::atomic<uint32_t> next{0};
  std::vector<std::thread> th;
  for (unsigned t = 0; t < threads; t++)
    th.emplace_back([&] {
      for (uint32_t s; (s = next++) < n;) f(s);
    });
  for (auto &t : th) t.join();
}

double since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

std::vector<uint8_t> slurp(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) die(path + ": missing");
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

int relayout(const std::string &in_dir, const std::string &out, unsigned threads, uint64_t chunk) {
  const auto t0 = std::chrono::steady_clock::now();
  const Image in = read_image(in_dir);
  if (in.packed) die("input must be a per-chunk image");
  if (!in.params_line.empty() && in.p.describe() != in.params_line)
    die("input params= line does not match describe() of its graph line:\n  " + in.params_line + "\n  " + in.p.describe());
  vdb::Params np = in.p;
  np.g.chunk_bytes = chunk;
  const vdb::GraphParams &ng = np.g;
  std::fprintf(stderr, "relayout %s -> %s: %u segments, per_chunk %lu -> %lu, groups %lu -> %lu, lchunk %lu -> %lu B, upper arena %lu B\n",
               in_dir.c_str(), out.c_str(), in.p.segments, (unsigned long)in.p.g.per_chunk(), (unsigned long)ng.per_chunk(),
               (unsigned long)in.p.g.groups(), (unsigned long)ng.groups(), (unsigned long)in.p.g.lchunk_bytes(),
               (unsigned long)ng.lchunk_bytes(), (unsigned long)ng.upper_group_bytes());
  // phase 1: plan every segment (no output yet)
  std::vector<std::vector<uint32_t>> uo(in.p.segments);
  std::vector<uint64_t> ucur(in.p.segments), maxu(in.p.segments);
  std::string bad;
  for_segments(in.p.segments, threads, [&](uint32_t s) {
    OldSeg o(in_dir, s, in.segs[s].count, in.p.g);
    std::string b = plan_segment(in, ng, s, o, &uo[s], &ucur[s], &maxu[s]);
    std::lock_guard<std::mutex> g(g_mu);
    bad += b;
  });
  std::fprintf(stderr, "phase 1 (headers, plan): %.0f s\n", since(t0));
  if (!bad.empty()) {
    std::fprintf(stderr, "vdb-relayout-c4k: UPPER-LEVEL ARENA OVERFLOW (no output written):\n%s", bad.c_str());
    return 1;
  }
  if (mkdir(out.c_str(), 0755) != 0) die("out dir must not exist: " + out);
  const auto t1 = std::chrono::steady_clock::now();
  for_segments(in.p.segments, threads, [&](uint32_t s) {
    OldSeg o(in_dir, s, in.segs[s].count, in.p.g);
    write_segment(out, ng, s, in.segs[s].count, o, uo[s]);
    std::lock_guard<std::mutex> g(g_mu);
    std::fprintf(stderr, "segment %u: %lu elements written, upper_cur %lu, max group upper bytes %lu (%.0f s)\n", s,
                 (unsigned long)in.segs[s].count, (unsigned long)ucur[s], (unsigned long)maxu[s], since(t1));
  });
  {
    std::ofstream segs(out + "/segments.txt");
    for (uint32_t s = 0; s < in.p.segments; s++)
      segs << s << " " << in.segs[s].count << " " << in.segs[s].epl << " " << ucur[s] << "\n";
    if (!segs) die("write segments.txt");
  }
  if (ng.is_sq8()) {
    const std::vector<uint8_t> q = slurp(in_dir + "/sq8.bin");
    std::ofstream f(out + "/sq8.bin", std::ios::binary);
    f.write(reinterpret_cast<const char *>(q.data()), std::streamsize(q.size()));
    if (!f) die("write sq8.bin");
  }
  const vdb::Params r2 = run2_c4k();
  const vdb::HwccLayout hm(r2, " backend=megalon"), hp(r2);
  std::ofstream m(out + "/manifest.txt");
  m << "# vdb initial segments, 4 KiB-page packed relayout (CXL_SWMC/workloads/vectordb/tools/relayout_c4k.cc) of\n"
    << "# " << in_dir << " (same graph: ids, levels, link blocks, entry points, counts; upper_off per 4-record group)\n";
  if (!in.input_line.empty()) m << in.input_line << "\n";
  if (!in.rows_line.empty()) m << in.rows_line << "\n";
  if (!in.seed_line.empty()) m << in.seed_line << "\n";
  m << "params=" << np.describe() << "\ngraph " << np.segments << " " << ng.dim << " " << ng.M << " " << ng.ef_construction
    << " " << ng.capacity << " " << ng.chunk_bytes << "\nper_chunk=" << ng.per_chunk() << " groups=" << ng.groups()
    << " vchunk_bytes=" << ng.vchunk_bytes() << " lchunk_bytes=" << ng.lchunk_bytes() << "\nimage packed\n";
  if (ng.is_sq8()) m << "vec_format sq8\n" << in.sq8_line << "\n";
  m << "relayout source=" << in_dir << " source_params=" << in.params_line << "\n";
  char hb[2][32];
  std::snprintf(hb[0], sizeof(hb[0]), "%016lx", (unsigned long)hm.L.hash());
  std::snprintf(hb[1], sizeof(hb[1]), "%016lx", (unsigned long)hp.L.hash());
  m << "layout_c4k_run2 describe=\"" << r2.describe() << "\" app_bytes=" << hm.L.bytes() << " hash_megalon=" << hb[0]
    << " hash_plain=" << hb[1] << " (vdb-server node log \"app layout ... hash\"; no --trace-dir)\n";
  if (!m) die("write manifest.txt");
  m.close();
  std::fprintf(stderr, "relayout done: %.0f s (phase 2 %.0f s)\n", since(t0), since(t1));
  return 0;
}

int verify(const std::string &in_dir, const std::string &out, unsigned threads) {
  const auto t0 = std::chrono::steady_clock::now();
  const Image in = read_image(in_dir), nw = read_image(out);
  if (!nw.packed) die("output manifest lacks 'image packed'");
  const vdb::GraphParams &og = in.p.g, &ng = nw.p.g;
  if (ng.dim != og.dim || ng.M != og.M || ng.ef_construction != og.ef_construction || ng.capacity != og.capacity ||
      ng.vec_format != og.vec_format || nw.p.segments != in.p.segments)
    die("graph parameters differ (other than chunk_bytes)");
  if (ng.vrec_bytes() != og.vrec_bytes() || ng.links0_bytes() != og.links0_bytes()) die("record sizes differ");
  if (ng.is_sq8() && slurp(in_dir + "/sq8.bin") != slurp(out + "/sq8.bin")) die("sq8.bin differs");
  std::atomic<int> fails{0};
  std::atomic<uint64_t> t_elems{0}, t_up_el{0}, t_up_blk{0}, t_ids{0}, t_groups{0}, t_vbytes{0};
  std::vector<uint64_t> hist(ng.upper_group_blocks() + 1);  // groups by upper blocks used
  for_segments(in.p.segments, threads, [&](uint32_t s) {
    const uint64_t count = in.segs[s].count;
    auto fail = [&](const std::string &m) {
      std::lock_guard<std::mutex> g(g_mu);
      if (fails++ < 20) std::fprintf(stderr, "VERIFY FAIL segment %u: %s\n", s, m.c_str());
    };
    if (nw.segs[s].count != count || nw.segs[s].epl != in.segs[s].epl) return fail("segments.txt count / ep_level");
    OldSeg o(in_dir, s, count, og);
    const uint64_t N = ng.per_chunk(), vr = ng.vrec_bytes(), l0 = ng.links0_bytes(), lb = ng.links_bytes(),
                   lc = ng.lchunk_bytes(), ubase = N * l0, ub = ng.upper_group_bytes(), G = (count + N - 1) / N;
    const std::string b = out + "/seg-" + std::to_string(s);
    Map v(b + "-v.bin", G ? (G - 1) * ng.vchunk_bytes() + (count - (G - 1) * N) * vr : 0), l(b + "-l.bin", G * lc);
    uint64_t up_el = 0, up_blk = 0, ids = 0, cur = 0, vbytes = 0;
    std::vector<uint64_t> hg(hist.size());
    std::vector<uint8_t> zero(std::max(lc, vr), 0);
    for (uint64_t gi = 0; gi < G; gi++) {
      const uint8_t *lch = l.p + gi * lc;
      cur = 0;
      for (uint64_t j = 0; j < N; j++) {
        const uint64_t i = gi * N + j;
        if (i >= count) {  // unused slot of the last group: zero level-0 block
          if (std::memcmp(lch + j * l0, zero.data(), l0) != 0) fail("unused level-0 block not zero, group " + std::to_string(gi));
          continue;
        }
        const uint8_t *orc = o.rec(i), *nrc = v.p + i * vr;
        vdb::ElemHeader oh, nh;
        std::memcpy(&oh, orc, sizeof(oh));
        std::memcpy(&nh, nrc, sizeof(nh));
        const uint64_t uoff = offsetof(vdb::ElemHeader, upper_off);
        if (std::memcmp(orc, nrc, uoff) != 0 || std::memcmp(orc + uoff + 8, nrc + uoff + 8, vr - uoff - 8) != 0)
          fail("record bytes differ (other than upper_off), element " + std::to_string(i));
        vbytes += vr;
        if (!vdb::elem_header_ok(oh, og)) fail("old header check, element " + std::to_string(i));
        if (!vdb::elem_header_ok(nh, ng) || nh.ext_id != s + uint64_t(in.p.segments) * i || nh.ins_seq != 0)
          fail("new header check, element " + std::to_string(i));
        if (std::memcmp(o.l0blk(i), lch + j * l0, l0) != 0) fail("level-0 block differs, element " + std::to_string(i));
        const uint32_t *ll = reinterpret_cast<const uint32_t *>(lch + j * l0);
        if (ll[0] > ng.M0()) fail("level-0 count > M0, element " + std::to_string(i));
        for (uint32_t k = 0; k < std::min(ll[0], ng.M0()); k++, ids++)
          if (ll[1 + k] >= count) fail("level-0 id out of range, element " + std::to_string(i));
        if (nh.level == 0) {
          if (nh.upper_off != 0) fail("level 0 with upper_off, element " + std::to_string(i));
          continue;
        }
        if (nh.upper_off != cur) fail("upper_off != group cursor, element " + std::to_string(i));
        up_el++;
        for (uint32_t lv = 1; lv <= nh.level; lv++, up_blk++) {
          const uint8_t *ob = o.upper(i, oh.upper_off) + (lv - 1) * lb, *nb = lch + ubase + nh.upper_off + (lv - 1) * lb;
          if (std::memcmp(ob, nb, lb) != 0) fail("upper block differs, element " + std::to_string(i) + " level " + std::to_string(lv));
          const uint32_t *ul = reinterpret_cast<const uint32_t *>(nb);
          if (ul[0] > ng.M) fail("upper count > M, element " + std::to_string(i));
          for (uint32_t k = 0; k < std::min(ul[0], ng.M); k++, ids++)
            if (ul[1 + k] >= count) fail("upper id out of range, element " + std::to_string(i));
        }
        cur += uint64_t(nh.level) * lb;
      }
      if (cur > ub) fail("group arena overflow, group " + std::to_string(gi));
      else if (std::memcmp(lch + ubase + cur, zero.data(), ub - cur) != 0) fail("unused arena bytes not zero, group " + std::to_string(gi));
      hg[std::min<uint64_t>(cur / lb, hg.size() - 1)]++;
    }
    if (nw.segs[s].ucur != cur) fail("segments.txt upper_cur " + std::to_string(nw.segs[s].ucur) + " != " + std::to_string(cur));
    t_elems += count, t_up_el += up_el, t_up_blk += up_blk, t_ids += ids, t_groups += G, t_vbytes += vbytes;
    std::lock_guard<std::mutex> g(g_mu);
    for (size_t k = 0; k < hg.size(); k++) hist[k] += hg[k];
    std::printf("segment %u: %lu elements, %lu groups, %lu with upper levels (%lu blocks), %lu link ids compared, upper_cur %lu ok\n",
                s, (unsigned long)count, (unsigned long)G, (unsigned long)up_el, (unsigned long)up_blk, (unsigned long)ids,
                (unsigned long)cur);
    std::fflush(stdout);
  });
  std::printf("total: %lu elements, %lu groups, %lu vector record bytes compared, %lu elements with upper levels, %lu upper blocks, %lu link ids\n",
              (unsigned long)t_elems, (unsigned long)t_groups, (unsigned long)t_vbytes, (unsigned long)t_up_el,
              (unsigned long)t_up_blk, (unsigned long)t_ids);
  std::printf("groups by upper blocks used:");
  for (size_t k = 0; k < hist.size(); k++) std::printf(" %zu:%lu", k, (unsigned long)hist[k]);
  std::printf("\nverify wall %.0f s\n%s\n", since(t0), fails ? "RELAYOUT VERIFY FAIL" : "RELAYOUT VERIFY PASS");
  return fails ? 1 : 0;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 4) die("usage: vdb-relayout-c4k relayout|verify <in dir> <out dir> [threads 8] [chunk_bytes 4096]");
  const std::string mode = argv[1];
  const unsigned threads = argc > 4 ? unsigned(std::atoi(argv[4])) : 8;
  if (mode == "relayout") return relayout(argv[2], argv[3], threads, argc > 5 ? std::strtoull(argv[5], nullptr, 10) : 4096);
  if (mode == "verify") return verify(argv[2], argv[3], threads);
  die("mode must be relayout or verify");
}

// sg-image-gen: build the socialgraph graph image (server/layout.h) from a SNAP undirected edge list (.txt or .gz).
// usage: sg-image-gen --input <edges.txt[.gz]> --out-dir <dir> [--seed N] [--node-slack N] [--ovf-pool N]
//                     [--perm-seed N] [--feed-limit N] [--read-zipf S]
// Writes <dir>/graph.img and <dir>/gen.json (stats; tools/make_image.sh wraps it into manifest.json with hashes).
// The input is untrusted data: lines are "# comment" or two decimal ids separated by blanks; anything else aborts.
#include <zlib.h>

#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "image_builder.h"

using namespace sg;

static void die(const std::string &m) {
  fprintf(stderr, "sg-image-gen: %s\n", m.c_str());
  exit(1);
}

// Parse the edge list; ids must be in [1, 2^31).
static void parse(const char *path, std::vector<uint32_t> &src, std::vector<uint32_t> &dst, uint64_t &lines,
                  uint64_t &comments) {
  gzFile z = gzopen(path, "rb");
  if (!z) die(std::string("cannot open ") + path);
  gzbuffer(z, 1 << 20);
  std::vector<char> buf(1 << 22);
  std::string carry;
  lines = comments = 0;
  auto line = [&](const char *s, size_t n) {
    lines++;
    if (n && s[n - 1] == '\r') n--;
    if (n == 0) return;
    if (s[0] == '#') { comments++; return; }
    uint64_t v[2] = {0, 0};
    int k = 0;
    size_t i = 0;
    while (k < 2) {
      while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
      if (i >= n || s[i] < '0' || s[i] > '9') die("bad line " + std::to_string(lines));
      while (i < n && s[i] >= '0' && s[i] <= '9') {
        v[k] = v[k] * 10 + uint64_t(s[i] - '0');
        if (v[k] >= (1ull << 31)) die("id too large, line " + std::to_string(lines));
        i++;
      }
      k++;
    }
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    if (i != n || v[0] == 0 || v[1] == 0) die("bad line " + std::to_string(lines));
    src.push_back(uint32_t(v[0]));
    dst.push_back(uint32_t(v[1]));
  };
  for (;;) {
    int r = gzread(z, buf.data(), unsigned(buf.size()));
    if (r < 0) die("gzread error");
    if (r == 0) break;
    size_t b = 0;
    for (size_t i = 0; i < size_t(r); i++)
      if (buf[i] == '\n') {
        if (!carry.empty()) {
          carry.append(buf.data() + b, i - b);
          line(carry.data(), carry.size());
          carry.clear();
        } else {
          line(buf.data() + b, i - b);
        }
        b = i + 1;
      }
    carry.append(buf.data() + b, size_t(r) - b);
    if (carry.size() > 4096) die("line too long");
  }
  int err = 0;
  gzerror(z, &err);
  if (err != Z_OK && err != Z_STREAM_END) die("gz stream error");
  gzclose(z);
  if (!carry.empty()) line(carry.data(), carry.size());
}

static uint64_t pct(const std::vector<uint64_t> &sorted, double q) {  // nearest rank
  uint64_t n = sorted.size();
  uint64_t r = uint64_t(std::ceil(q * double(n)));
  if (r < 1) r = 1;
  return sorted[r - 1];
}

int main(int argc, char **argv) {
  std::string in, out;
  BuildParams p;
  uint64_t perm_seed = 0x5347524541444b31ull, limit = 50;
  double zipf = 0.8;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto val = [&]() -> std::string { if (i + 1 >= argc) die("missing value for " + a); return argv[++i]; };
    if (a == "--input") in = val();
    else if (a == "--out-dir") out = val();
    else if (a == "--seed") p.seed = std::stoull(val());
    else if (a == "--node-slack") p.node_slack = std::stoull(val());
    else if (a == "--ovf-pool") p.ovf_pool = std::stoull(val());
    else if (a == "--perm-seed") perm_seed = std::stoull(val());
    else if (a == "--feed-limit") limit = std::stoull(val());
    else if (a == "--read-zipf") zipf = std::stod(val());
    else die("unknown argument " + a);
  }
  if (in.empty() || out.empty()) die("usage: --input <edges> --out-dir <dir>");
  auto t0 = std::chrono::steady_clock::now();
  auto secs = [&]() { return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); };

  std::vector<uint32_t> src, dst;
  src.reserve(120000000);
  dst.reserve(120000000);
  uint64_t lines, comments;
  parse(in.c_str(), src, dst, lines, comments);
  uint32_t mn = UINT32_MAX, mx = 0;
  for (size_t e = 0; e < src.size(); e++) {
    mn = std::min({mn, src[e], dst[e]});
    mx = std::max({mx, src[e], dst[e]});
  }
  if (src.empty()) die("no edges");
  fprintf(stderr, "parsed %zu edges (%" PRIu64 " lines) ids %u..%u in %.1f s\n", src.size(), lines, mn, mx, secs());
  const uint64_t id_base = mn, n = uint64_t(mx) - mn + 1;
  Graph g = build_csr(src, dst, id_base, n, p);
  fprintf(stderr, "csr: %" PRIu64 " nodes %" PRIu64 " links in %.1f s\n", g.n, g.off[g.n], secs());

  std::string img = out + "/graph.img";
  FILE *f = fopen(img.c_str(), "wb");
  if (!f) die("cannot create " + img);
  std::vector<char> fbuf(64 << 20);
  setvbuf(f, fbuf.data(), _IOFBF, fbuf.size());
  BuildStats st;
  ImageHeader h;
  try {
    h = write_image(f, g, p, st);
  } catch (const std::exception &e) {
    die(e.what());
  }
  if (fclose(f) != 0) die("close failed");
  fprintf(stderr, "image %" PRIu64 " bytes in %.1f s\n", h.total_bytes, secs());

  // degree statistics
  std::vector<uint64_t> deg(g.n);
  uint64_t zero = 0, ge50 = 0, sum = 0, inline_only = 0;
  for (uint64_t i = 0; i < g.n; i++) {
    deg[i] = g.deg(i);
    sum += deg[i];
    zero += deg[i] == 0;
    ge50 += deg[i] >= limit;
    inline_only += deg[i] <= kInlineMaxEdges;
  }
  std::vector<uint64_t> sd = deg;
  std::sort(sd.begin(), sd.end());
  // expected rows per feed query: read key rank r ~ Zipf(zipf) over n (p_r ~ r^-s, exact pmf), node = perm(r)
  std::vector<double> w(g.n);
  double H = 0;
  for (uint64_t r = 0; r < g.n; r++) { w[r] = std::pow(double(r + 1), -zipf); H += w[r]; }
  auto rows = [&](uint64_t node) { return double(std::min<uint64_t>(limit, deg[node])); };
  double e_uniform_perm = 0;  // expectation over a uniformly random permutation = mean of min(limit, deg)
  for (uint64_t i = 0; i < g.n; i++) e_uniform_perm += rows(i);
  e_uniform_perm /= double(g.n);
  std::vector<uint32_t> perm(g.n);
  for (uint64_t i = 0; i < g.n; i++) perm[i] = uint32_t(i);
  uint64_t rs = perm_seed;
  for (uint64_t i = g.n - 1; i > 0; i--) {  // Fisher-Yates, splitmix64 stream
    rs = splitmix64(rs);
    uint64_t j = uint64_t((unsigned __int128)rs * (i + 1) >> 64);
    std::swap(perm[i], perm[j]);
  }
  double e_fy = 0, e_lb = 0, top_rows = 0;
  linkbench::InvertibleShuffler *shuf = new linkbench::InvertibleShuffler(linkbench::kUncorrShufflerSeed, int64_t(g.n));
  for (uint64_t r = 0; r < g.n; r++) {
    e_fy += w[r] * rows(perm[r]);
    e_lb += w[r] * rows(uint64_t(shuf->permute(int64_t(r))));
  }
  delete shuf;
  e_fy /= H;
  e_lb /= H;
  double top1000 = 0;
  for (uint64_t r = 0; r < std::min<uint64_t>(1000, g.n); r++) { top1000 += w[r]; top_rows += w[r] * rows(perm[r]); }
  (void)top_rows;

  FILE *j = fopen((out + "/gen.json").c_str(), "w");
  if (!j) die("cannot create gen.json");
  fprintf(j, "{\n");
  fprintf(j, "  \"generator\": \"sg-image-gen (workloads/socialgraph/tools/sg_image_gen.cc)\",\n");
  fprintf(j, "  \"input_lines\": %" PRIu64 ", \"input_comment_lines\": %" PRIu64 ", \"input_edges\": %" PRIu64 ",\n",
          lines, comments, g.undirected);
  fprintf(j, "  \"self_loops_dropped\": %" PRIu64 ", \"duplicate_links_dropped\": %" PRIu64 ",\n", g.self_loops, g.duplicates);
  fprintf(j, "  \"id_base\": %" PRIu64 ", \"nodes\": %" PRIu64 ", \"zero_degree_nodes\": %" PRIu64 ", \"directed_links\": %" PRIu64 ",\n",
          g.id_base, g.n, zero, h.n_links);
  fprintf(j, "  \"seed\": %" PRIu64 ", \"base_ms\": %" PRIu64 ", \"time_span_ms\": %" PRIu64 ",\n", p.seed, p.base_ms, kTimeSpan);
  fprintf(j, "  \"layout_version\": %u, \"layout_hash\": \"%016" PRIx64 "\", \"image_bytes\": %" PRIu64 ",\n",
          h.layout_version, h.layout_hash, h.total_bytes);
  fprintf(j, "  \"arrays\": {\"header\": {\"off\": 0, \"bytes\": %u}, \"adj_index\": {\"off\": %" PRIu64 ", \"bytes\": %" PRIu64 "}, "
          "\"nodes\": {\"off\": %" PRIu64 ", \"bytes\": %" PRIu64 "}, \"adj\": {\"off\": %" PRIu64 ", \"bytes\": %" PRIu64 "}, "
          "\"ovf\": {\"off\": %" PRIu64 ", \"bytes\": %" PRIu64 ", \"built_blocks\": %" PRIu64 ", \"pool_blocks\": %" PRIu64 "}},\n",
          h.header_bytes, h.adj_index_off, h.adj_index_bytes, h.nodes_off, h.nodes_bytes, h.adj_off, h.adj_bytes, h.ovf_off,
          h.ovf_bytes(), h.ovf_built, h.ovf_pool);
  fprintf(j, "  \"slack\": {\"node_slots\": %" PRIu64 ", \"ovf_pool_blocks\": %" PRIu64 ", \"inline_rule\": \"cap = min(%u, even(e + max(2, ceil(e/8)))), e = min(deg, %u)\"},\n",
          p.node_slack, p.ovf_pool, kInlineMaxCap, kInlineMaxEdges);
  fprintf(j, "  \"record\": {\"node_slot_bytes\": %zu, \"edge_slot_bytes\": %zu, \"ovf_block_bytes\": %zu, \"ovf_slots\": %u},\n",
          sizeof(NodeSlot), sizeof(EdgeSlot), sizeof(OvfBlock), kOvfSlots);
  fprintf(j, "  \"caps\": {\"node_data_cap\": %u, \"edge_data_cap\": %u, \"node_payload_capped\": %" PRIu64 ", \"link_payload_capped\": %" PRIu64 ", "
          "\"node_payload_mean\": %.3f, \"link_payload_mean\": %.3f},\n",
          kNodeDataCap, kEdgeDataCap, st.node_payload_capped, st.link_payload_capped,
          double(st.node_payload_bytes) / double(g.n), double(st.link_payload_bytes) / double(h.n_links));
  fprintf(j, "  \"degree\": {\"mean\": %.4f, \"p50\": %" PRIu64 ", \"p90\": %" PRIu64 ", \"p99\": %" PRIu64 ", \"max\": %" PRIu64 ", "
          "\"min\": %" PRIu64 ", \"frac_ge_%" PRIu64 "\": %.6f, \"frac_inline_only\": %.6f, \"percentile\": \"nearest rank\"},\n",
          double(sum) / double(g.n), pct(sd, 0.5), pct(sd, 0.9), pct(sd, 0.99), sd.back(), sd.front(), limit,
          double(ge50) / double(g.n), double(inline_only) / double(g.n));
  fprintf(j, "  \"primary_blocks_straddling_page\": %" PRIu64 ", \"primary_straddle_frac\": %.6f,\n", st.primary_straddle,
          double(st.primary_straddle) / double(g.n));
  fprintf(j, "  \"record_objects\": %" PRIu64 ", \"chunk_bytes\": %" PRIu64 ", \"chunks\": %" PRIu64 ",\n", record_objects(h),
          kChunkBytes, for_each_chunk(h, kChunkBytes, [](const ChunkRef &) {}));
  fprintf(j, "  \"feed_rows_expected\": {\"limit\": %" PRIu64 ", \"read_zipf\": %.3f, \"pmf\": \"exact r^-s over n ranks\", "
          "\"uniform_random_perm\": %.4f, \"fisher_yates_perm\": %.4f, \"fisher_yates_perm_seed\": %" PRIu64 ", "
          "\"linkbench_uncorr_shuffler\": %.4f, \"top1000_rank_mass\": %.6f},\n",
          limit, zipf, e_uniform_perm, e_fy, perm_seed, e_lb, top1000 / H);
  fprintf(j, "  \"gen_seconds\": %.1f\n}\n", secs());
  fclose(j);
  fprintf(stderr, "done in %.1f s\n", secs());
  return 0;
}

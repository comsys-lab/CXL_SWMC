// LinkBench workload parameters for the socialgraph workload (image generator + loadgen).
//
// Source: facebookarchive/linkbench, branch master (archived repo), read 2026-11-11.
//   W = https://raw.githubusercontent.com/facebookarchive/linkbench/master/config/FBWorkload.properties
//   D = https://raw.githubusercontent.com/facebookarchive/linkbench/master/config/Distribution.dat
//   J = https://raw.githubusercontent.com/facebookarchive/linkbench/master/src/main/java/com/facebook/LinkBench/
// Line numbers of W are exact; Java line numbers are approximate (+-2).
// Notes on meaning, sampling, ambiguities and derived statistics: LINKBENCH_PARAMS.md (same dir).
// Values are transcribed as published; nothing here is a methodology decision of ours.
#pragma once

#include <cstdint>

namespace socialgraph::linkbench {

// ---------------------------------------------------------------------------------------------
// Id space and graph shape. W lines 28-35.
// Node ids are [kStartId1, kMaxId1) (maxid1 exclusive) -> 10,000,000 nodes. NodeLoader.java ~L139
// loads every id in that range; LinkBenchLoad.java ~L272 iterates id1 over the same range.
// maxid1 is NOT grown by addnode during the request phase (LinkBenchRequest.java ~L205): all
// request id distributions draw from [kStartId1, kMaxId1).
inline constexpr int64_t kStartId1 = 1;          // W L28 startid1
inline constexpr int64_t kMaxId1 = 10000001;     // W L32 maxid1 (exclusive)
inline constexpr int64_t kNumIds = kMaxId1 - kStartId1;  // 10,000,000
inline constexpr int kLinkTypeCount = 2;         // W L35 link_type_count
// LinkStore.java L25/L27: link types are kDefaultLinkType + {0..kLinkTypeCount-1}
// (ID2Chooser.getLinkTypes); every request op picks the type uniformly (chooseRandomLinkType).
inline constexpr int64_t kDefaultLinkType = 123456789;
inline constexpr int32_t kDefaultNodeType = 2048;

// ---------------------------------------------------------------------------------------------
// Operation mix (request phase). W lines 131-140, percentages of all requests, sum = 100.
// LinkBenchRequest.oneRequest (~L471-648): r = U[0,100); op = first cumulative threshold > r in
// the order addlink, deletelink, updatelink, countlink, getlink(multiget), getlinklist,
// getnode, addnode, updatenode, deletenode.
enum class Op : int {
  kAddLink, kDeleteLink, kUpdateLink, kCountLink, kGetLink /* multiget */, kGetLinkList,
  kGetNode, kAddNode, kUpdateNode, kDeleteNode, kCount
};
struct OpPct { Op op; const char* name; double pct; bool is_write; };
inline constexpr OpPct kOpMix[] = {
  {Op::kAddLink,     "addlink",     8.9886601,  true },  // W L131
  {Op::kDeleteLink,  "deletelink",  2.9907664,  true },  // W L132
  {Op::kUpdateLink,  "updatelink",  8.0122125,  true },  // W L133
  {Op::kCountLink,   "countlink",   4.8863567,  false},  // W L134
  {Op::kGetLink,     "getlink",     0.5261142,  false},  // W L135 (multiget of id2s)
  {Op::kGetLinkList, "getlinklist", 50.7119145, false},  // W L136
  {Op::kGetNode,     "getnode",     12.9326683, false},  // W L137
  {Op::kAddNode,     "addnode",     2.5732789,  true },  // W L138
  {Op::kUpdateNode,  "updatenode",  7.366437,   true },  // W L139
  {Op::kDeleteNode,  "deletenode",  1.0115914,  true },  // W L140
};
// Derived: reads = 69.0570537 %, writes = 30.9429463 %. Reads renormalized: getlinklist 73.435 %,
// getnode 18.727 %, countlink 7.076 %, getlink 0.762 %.
// Writes renormalized: addlink 29.05 %, updatelink 25.89 %, updatenode 23.81 %, deletelink 9.67 %,
// addnode 8.32 %, deletenode 3.27 %.

// getlinklist history: W L144 getlinklist_history = 0.3 (PERCENT; LinkBenchRequest divides by 100
// -> p = 0.003). With that probability, and if the tail cache is non-empty, a getlinklist is a
// "history" query: pick a cached (id1, type, time of last row) of an earlier list that hit the
// range limit, and fetch the next page: time <= prev.time, offset 1, limit kRangeLimit.
// Tail cache: up to 2048 entries (LinkBenchRequest ~L240).
inline constexpr double kGetLinkListHistoryPct = 0.3;
inline constexpr int kListTailCacheMax = 2048;
// Range limit for getlinklist: LinkStore.java L34 DEFAULT_LIMIT = 10000 (rangeLimit, L43).
// MySQL store: getLinkList(id1,type) = time in [0, INT64_MAX], visibility = VISIBLE,
// ORDER BY time DESC, LIMIT 0,10000 (LinkStoreMysql.java ~L680-718). Our spec uses limit 50.
inline constexpr int kRangeLimit = 10000;

// ---------------------------------------------------------------------------------------------
// Per-op id1 (key) distributions. W lines 171-213; Config.java L78-99; AccessDistributions.java
// L157-234; LinkBenchRequest.chooseRequestID ~L415-463.
// Every distribution draws a RANK in [kStartId1, kMaxId1) (rank kStartId1 = most popular), then
// the id is id = kStartId1 + Shuffler(seed).permute(rank - kStartId1) (InvertibleShuffler, below).
// Link reads/writes: with prob blend/100 use the "uncorr" distribution, else the correlated one
// (code: if (rng.nextDouble() >= blend) corr else uncorr).
// "Correlated" uses the same shuffler seed as the out-degree assignment, so popular ids are the
// high-degree ids; "uncorr" uses a different seed (popularity independent of degree).
//
// IMPORTANT (source bug, Config.java L90): WRITE_UNCORR_CONFIG_PREFIX = "read_uncorr_", so the
// write-uncorr blend/function/shape are read from read_uncorr_* (blend 99.5, Zipf 0.8). The
// write_uncorr_blend = 95 / write_uncorr_shape = 0.741 lines of W (L196-198) are never read.
// kEffective* below is what LinkBench actually runs; kAsWritten* is the file text.
enum class KeyDist : int { kZipf, kUniform };
enum class Shuffle : int { kNlinks /* = degree order */, kUncorr, kNode };
struct KeySpec { const char* what; KeyDist dist; double zipf_shape; Shuffle shuffle; };

inline constexpr KeySpec kLinkReadCorr     = {"read (corr)",        KeyDist::kZipf, 0.8,   Shuffle::kNlinks};  // W L173-174
inline constexpr KeySpec kLinkReadUncorr   = {"read_uncorr",        KeyDist::kZipf, 0.8,   Shuffle::kUncorr};  // W L185-186
inline constexpr double  kLinkReadUncorrBlendPct = 99.5;                                                        // W L184
inline constexpr KeySpec kLinkWriteCorr    = {"write (corr)",       KeyDist::kZipf, 0.741, Shuffle::kNlinks};  // W L190-191
inline constexpr KeySpec kLinkWriteUncorrEffective = {"write_uncorr (=read_uncorr_*)", KeyDist::kZipf, 0.8, Shuffle::kUncorr};
inline constexpr double  kLinkWriteUncorrBlendPctEffective = 99.5;   // Config.java L90 bug
inline constexpr double  kLinkWriteUncorrBlendPctAsWritten = 95.0;   // W L196 (not read)
inline constexpr double  kLinkWriteUncorrShapeAsWritten = 0.741;     // W L197 (not read)
inline constexpr KeySpec kNodeRead   = {"node_read",   KeyDist::kZipf,    0.625, Shuffle::kNode};  // W L202-203
inline constexpr KeySpec kNodeUpdate = {"node_update", KeyDist::kZipf,    0.606, Shuffle::kNode};  // W L207-208
inline constexpr KeySpec kNodeDelete = {"node_delete", KeyDist::kUniform, 0.0,   Shuffle::kNode};  // W L213
// Which distribution each op uses (LinkBenchRequest.oneRequest):
//   addlink, deletelink, updatelink -> link write (corr/uncorr blend)
//   countlink, getlink, getlinklist -> link read  (corr/uncorr blend)
//   getnode -> kNodeRead; updatenode -> kNodeUpdate; deletenode -> kNodeDelete;
//   addnode -> no key (store allocates a new id > all existing ids).
//
// Zipf sampler (ZipfDistribution.java L45-81, L199-207; Gray et al. SIGMOD'94), n = max - min:
//   zetan = sum_{i=1..n} i^-shape;  alpha = 1/(1-shape);
//   eta = (1 - (2/n)^(1-shape)) / (1 - (1 + 2^-shape)/zetan);
//   u = U[0,1); uz = u*zetan; if uz < 1 -> min; if uz < 1 + 0.5^shape -> min+1;
//   else min + min(n-1, floor(n * (eta*u - eta + 1)^alpha)).
// Uniform: UniformDistribution, U[min, max).

// Shuffler seeds/groups (RealDistribution.java L46-73). Port: InvertibleShuffler.java (below).
inline constexpr int64_t kNlinksShufflerSeed = 20343988438726021LL;  // degree, read corr, write corr
inline constexpr int64_t kUncorrShufflerSeed = 53238253823453LL;     // read uncorr, write uncorr
inline constexpr int64_t kNodeShufflerSeed   = 4766565305853767165LL; // node read/update/delete
inline constexpr int kShufflerGroups = 1024;                          // all shufflers

inline constexpr int64_t ShufflerSeed(Shuffle s) {
  return s == Shuffle::kNlinks ? kNlinksShufflerSeed
       : s == Shuffle::kUncorr ? kUncorrShufflerSeed : kNodeShufflerSeed;
}

// java.util.Random (48-bit LCG), needed to reproduce InvertibleShuffler params exactly.
struct JavaRandom {
  uint64_t seed;
  explicit JavaRandom(int64_t s) : seed((static_cast<uint64_t>(s) ^ 0x5DEECE66DULL) & ((1ULL << 48) - 1)) {}
  int32_t next(int bits) {
    seed = (seed * 0x5DEECE66DULL + 0xBULL) & ((1ULL << 48) - 1);
    return static_cast<int32_t>(static_cast<int64_t>(seed) >> (48 - bits));
  }
  int32_t nextInt(int32_t bound) {  // bound > 0
    if ((bound & -bound) == bound)
      return static_cast<int32_t>((static_cast<int64_t>(bound) * next(31)) >> 31);
    int32_t bits, val;
    do {
      bits = next(31);
      val = bits % bound;
    } while (static_cast<int32_t>(static_cast<uint32_t>(bits) - static_cast<uint32_t>(val) +
                                  static_cast<uint32_t>(bound - 1)) < 0);
    return val;
  }
};

// InvertibleShuffler.java L16-86: per residue class (i mod groups) a rotation by params[g]
// steps of `groups`. Usage: id = start + permute(rank); degree uses rank = invert(id - start).
// Caller allocates params[groups] (groups = min(1024, n)).
struct InvertibleShuffler {
  int64_t n, groups, min_group, rounded_down, rounded_up;
  int64_t params[kShufflerGroups];
  InvertibleShuffler(int64_t seed, int64_t n_) : n(n_) {
    JavaRandom rng(seed);
    groups = kShufflerGroups > n ? n : kShufflerGroups;
    min_group = static_cast<int32_t>(n) / groups;
    for (int64_t i = 0; i < groups; i++) {
      int32_t v = rng.nextInt(static_cast<int32_t>(min_group));
      params[i] = v < 0 ? -v : v;
    }
    rounded_down = (n / groups) * groups;
    rounded_up = n == rounded_down ? n : rounded_down + groups;
  }
  int64_t permute(int64_t i, bool inverse = false) const {
    int64_t g = i % groups;
    bool big = g < n % groups;
    int64_t rot = params[g];
    if (inverse) rot = big ? min_group + 1 - rot : min_group - rot;
    int64_t j = i + groups * rot;
    if (j < n) return j;
    int64_t r = big ? j % rounded_up : j % rounded_down;
    return r >= n ? g : r;
  }
  int64_t invert(int64_t i) const { return permute(i, true); }
};

// ---------------------------------------------------------------------------------------------
// Out-degree distribution: nlinks_func = real (W L45) -> D section "nlinks".
// Format: points {value, cumulative percent}; RealDistribution.readCDF divides percent by 100.
// How LinkBench assigns degrees (deterministic per id; ID2Chooser.calcTotalLinkCount ~L196-209,
// LinkDistributions.ProbLinkDistribution L48-56, PiecewiseLinearDistribution.expectedCount L127-141):
//   rank = kStartId1 + Shuffler(kNlinksShufflerSeed).invert(id1 - kStartId1)
//   u    = 1.0 - (rank - kStartId1) / double(kNumIds)       // u in (0, 1], rank 1 -> u = 1
//   ix   = first point with prob >= u (binary search)
//   total_nlinks(id1) = round(points[ix].value)
// Then per link type (ID2Chooser.calcLinkCount L240-251, source bug kept on purpose):
//   m = total / kLinkTypeCount; left = total - m;  // NOT total % kLinkTypeCount
//   count(type t) = (t < left) ? m + 1 : m          // -> loaded total >= nominal total
// Load: for each type, for j in [0, count): id2 = id1 + j (randomid2max = 0, ID2Chooser L82-89),
//   time = now_ms - 2^31 + JavaRandom.nextInt() (about the last 50 days; LinkBenchLoad ~L421-424),
//   version 0, visibility VISIBLE, data size ~ kLinkDataSize.
// 19951 points (> 2000), so the table lives in linkbench_degree_cdf.inc (19956 lines incl. 5
// comment lines), an exact copy of D lines 2-19952.
struct CdfPoint { int64_t value; double pct; };
inline constexpr CdfPoint kNlinksCdf[] = {
#include "linkbench_degree_cdf.inc"
};
inline constexpr int kNlinksCdfPoints = sizeof(kNlinksCdf) / sizeof(kNlinksCdf[0]);
static_assert(kNlinksCdfPoints == 19951, "Distribution.dat nlinks section has 19951 points");
// LinkBench's own expectedValue(nlinks) = 4.0973 (derived; PiecewiseLinearDistribution L189-205).
// Exact mean over 10M ids by the rule above: 4.1722 nominal, 4.4459 loaded (derived).

// Rank -> nominal total out-degree, mirroring PiecewiseLinearDistribution.expectedCount.
inline int64_t NlinksForRank(int64_t rank0 /* 0 = most links */, int64_t n = kNumIds) {
  double u = 1.0 - static_cast<double>(rank0) / static_cast<double>(n);
  int lo = 0, hi = kNlinksCdfPoints - 1;
  while (lo < hi) {
    int mid = (lo + hi) / 2;
    if (kNlinksCdf[mid].pct / 100.0 >= u) hi = mid; else lo = mid + 1;
  }
  if (kNlinksCdf[lo].pct / 100.0 < u) lo++;  // unreachable when last point is 100
  return kNlinksCdf[lo].value;
}
// Per-type count with the LinkBench split (bug included).
inline constexpr int64_t LinkCountForType(int64_t total, int type_idx) {
  int64_t m = total / kLinkTypeCount;
  int64_t left = total - m;
  return type_idx < left ? m + 1 : m;
}

// ---------------------------------------------------------------------------------------------
// id2 choice in the request phase (ID2Chooser.java L25-28, L99-187):
//   nlinks = LinkCountForType(total(id1), type); range = max(1, ceil(nlinks / pExist));
//   id2 = id1 + U[0, range).  (So id2 > maxid1 is possible; no node needs to exist.)
inline constexpr double kPGetExist = 0.5;     // getlink (multiget)
inline constexpr double kPUpdateExist = 0.9;  // updatelink
inline constexpr double kPDeleteExist = 0.9;  // deletelink
inline constexpr double kPAddExist = 0.05;    // addlink
// Multiget: chooseMultipleForOp: if range <= k fill id1+0..k-1, else k distinct draws (<=100 retries).

// getlink (multiget) size: W L217-221, GeometricDistribution.java ~L43-105.
//   k = min(max-1, min + ceil(ln(1-u)/ln(1-p))), u = U[0,1) (u == 0 -> min).
// NOTE: with min = 1 the smallest value for u > 0 is 2, mean ~= 1 + 1/p = 3.62 (the comment's
// "mean ~2.6" is 1/p); max is exclusive (127 reachable, 128 not).
inline constexpr int kMultigetMin = 1;        // W L218
inline constexpr int kMultigetMax = 128;      // W L219 (exclusive)
inline constexpr double kMultigetProb = 0.382;  // W L221

// ---------------------------------------------------------------------------------------------
// Payload sizes: LogNormal(median, sigma) (LogNormalDistribution.java L49-84):
//   size = round(exp(sigma * N(0,1) + ln(median))), clamped to [min, max-1].
// Used for load (NodeLoader ~L84-87, LinkBenchLoad ~L145-149, L406) and for add/update in the
// request phase (LinkBenchRequest ~L323-327, L381-385). sigma: Config.java L66-67.
struct LogNormalSpec { double median; double sigma; int64_t min; int64_t max_excl; };
inline constexpr LogNormalSpec kLinkDataSize = {8.0,   1.0, 0, 255};          // W L83; LinkStore L36 MAX_LINK_DATA
inline constexpr LogNormalSpec kNodeDataSize = {128.0, 1.0, 0, 1024 * 1024};  // W L101; NodeStore L28 MAX_NODE_DATA
// Derived quantiles (lognormal, before clamping): link p50 8, mean 13.2, p90 28.8, p99 81.9 B;
// node p50 128, mean 211, p90 461, p99 1310 B.
// Payload byte contents: MotifDataGenerator; startbyte/endbyte are the BYTE VALUE range, not sizes.
inline constexpr int kLinkDatagenStartByte = 32, kLinkDatagenEndByte = 100;  // W L88-89, L95-96
inline constexpr double kLinkDatagenUniqueness = 0.225;                     // W L90, L97
inline constexpr int kLinkDatagenMotifLength = 128;                         // W L91, L98
inline constexpr int kNodeDatagenStartByte = 50, kNodeDatagenEndByte = 220;  // W L106-107, L112-113
inline constexpr double kNodeDatagenUniqueness = 0.63;                      // W L108, L114

// Node fields at load (NodeLoader ~L171-172): type kDefaultNodeType, version 1, time = now (s).
// addnode: version 1; updatenode: version 2 (createUpdateNode).

// Reference run config (W is included from LinkConfigMysql.properties): requesters = 100,
// requests = 500000 per requester, requestrate = 0 (unthrottled), loaders = 10,
// loader_chunk_size = 2048. Informational only.

}  // namespace socialgraph::linkbench

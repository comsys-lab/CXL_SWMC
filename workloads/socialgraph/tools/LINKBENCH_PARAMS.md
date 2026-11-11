# LinkBench parameters: meaning, sampling, open points

Source: facebookarchive/linkbench (archived), branch master, read 2026-11-11 with WebFetch. Tables are in
`linkbench_params.h`; the out-degree CDF is in `linkbench_degree_cdf.inc` (exact copy of
`config/Distribution.dat` lines 2-19952, 19951 points, file sha256 `7ae8decb...0209`, 519238 bytes; the copy
was diffed against the fetched file). Java paths below are under `src/main/java/com/facebook/LinkBench/`.
Java line numbers are approximate (+-2); FBWorkload.properties line numbers are exact.

## Parameters and how LinkBench uses them

| Parameter | Value | How it is used (Java) |
| --- | --- | --- |
| startid1, maxid1 | 1, 10000001 (exclusive) | 10M node ids; every request distribution draws from this range; addnode does not widen it (LinkBenchRequest) |
| link_type_count | 2 | each request op picks a type uniformly (ID2Chooser.chooseRandomLinkType); a node's links are split across types (calcLinkCount) |
| nlinks_func | real | degree per id is deterministic from the `nlinks` CDF (RealDistribution, PiecewiseLinearDistribution.expectedCount, ID2Chooser.calcTotalLinkCount) |
| op mix | addlink 8.9886601, deletelink 2.9907664, updatelink 8.0122125, countlink 4.8863567, getlink 0.5261142, getlinklist 50.7119145, getnode 12.9326683, addnode 2.5732789, updatenode 7.366437, deletenode 1.0115914 (%) | one uniform draw per request against cumulative thresholds (LinkBenchRequest.oneRequest) |
| getlinklist_history | 0.3 (%) | p = 0.003: next page of a list that hit the range limit earlier (tail cache, 2048 entries) |
| range limit | 10000 | LinkStore.DEFAULT_LIMIT; getlinklist = all visible links of (id1, type), newest first, LIMIT 0,10000 (LinkStoreMysql) |
| link reads (countlink, getlink, getlinklist) | 99.5 % Zipf(0.8) uncorrelated + 0.5 % Zipf(0.8) correlated with degree | AccessDistributions + LinkBenchRequest.chooseRequestID |
| link writes (addlink, updatelink, deletelink) | effective: 99.5 % Zipf(0.8) uncorrelated + 0.5 % Zipf(0.741) correlated | see ambiguity 1 |
| node reads (getnode) | Zipf(0.625) | node shuffler |
| node updates (updatenode) | Zipf(0.606) | node shuffler (same seed as node reads) |
| node deletes | Uniform | node shuffler |
| link_multiget_dist | Geometric p=0.382, min 1, max 128 (exclusive) | getlink fetches k id2s of one (id1, type) |
| link_datasize | LogNormal median 8 B, sigma 1, [0, 255) | link payload at load, addlink and updatelink |
| node_datasize | LogNormal median 128 B, sigma 1, [0, 1 MiB) | node payload at load, addnode and updatenode |
| *_datagen_startbyte/endbyte/uniqueness | 32-100 / 0.225 (links), 50-220 / 0.63 (nodes) | MotifDataGenerator: byte-value range and compressibility of the payload, not sizes |
| id2 at load | id1 + j, j = 0..count(type)-1 (randomid2max = 0) | both types reuse the same id2s; id2 may exceed maxid1 |
| id2 in requests | id1 + U[0, ceil(count/pExist)), pExist: get 0.5, update 0.9, delete 0.9, add 0.05 | ID2Chooser.chooseForOp; addlink mostly adds a new link, update/delete mostly hit an existing one |
| link time at load | now_ms - 2^31 + nextInt() (last ~50 days) | LinkBenchLoad.chooseInitialTimestamp |

### Sampling details
- Key = rank then shuffle. A Zipf/uniform draw yields a rank in [startid1, maxid1) (rank startid1 is most
  popular); the id is `startid1 + InvertibleShuffler(seed, 1024 groups, n).permute(rank - startid1)`.
  Seeds: degree, correlated reads and correlated writes share 20343988438726021 (hot ids = high-degree ids);
  uncorrelated reads and writes share 53238253823453 (same hot ids for both, independent of degree); node
  read/update/delete share 4766565305853767165. The shuffler depends on java.util.Random; the header has a
  port (checked: bijection over 10M ids, invert(permute(i)) == i, Random(42).nextInt(10) = 0 as in Java).
- Zipf sampler is Gray et al. 1994 (ZipfDistribution.quantile); the formula is in the header.
- Degree: `rank = invert(id1 - startid1)`, `u = 1 - rank/n`, degree = value of the first CDF point with
  cumulative probability >= u. Rank 0 (one id) gets 961,963 links.
- Geometric: `min + ceil(ln(1-u)/ln(1-p))`, clamped to max-1. LogNormal: `round(exp(sigma*N(0,1) + ln median))`,
  clamped to [min, max-1].

## Ambiguities (need a decision or a note in the experiment document)
1. Write key distribution (source bug). Config.java L90 sets `WRITE_UNCORR_CONFIG_PREFIX = "read_uncorr_"`,
   so LinkBench never reads `write_uncorr_blend = 95` / `write_uncorr_shape = 0.741`; writes run 99.5 %
   uncorrelated Zipf(0.8). The header has both (`*Effective`, `*AsWritten`). Recommended default: as written
   (95 % uncorr, shape 0.741), the authors' intent; alternative: effective behaviour (what published LinkBench
   numbers measured). The difference is small (both ~Zipf 0.74-0.8).
2. Per-type link split (source bug). ID2Chooser.calcLinkCount uses `left = total - total/2` instead of
   `total % 2`, so a node with total t >= 3 loads 2*floor(t/2) + 2 links (t=2 loads 3). Mean loaded degree is
   4.446 instead of 4.172. Recommended default: mirror LinkBench (the CDF is what LinkBench loads).
3. Range limit. LinkBench getlinklist returns up to 10000 rows; our spec's feed query uses limit 50. With
   LinkBench's key distribution the feed is small: expected rows per getlinklist (random type) = 0.97 at
   limit 50, 7.9 at limit 10000 (derived). The uncorrelated 99.5 % mostly hits low-degree nodes (45 % of ids
   have no links). So the feed query is, on average, 1 list read + ~1 node read, not 50. Correlated reads
   (0.5 %) average 16.4 rows at limit 50. This affects how heavy the SLO query is; worth stating in §2.
4. Node payload vs 128 B slot. node_datasize is a LogNormal with median 128 B (mean 211, p99 ~1.3 KB), so
   half of the nodes do not fit a 128 B slot with its header. Options: cap the payload at the slot's data
   field (recommended default; record the cap), or variable-size node data. Link payload (median 8, p99 82,
   max 254 B) also exceeds a 32-48 B edge slot's "short data" at the tail; same choice.
5. "~10 GB" in FBWorkload.properties is MySQL/InnoDB size. Our layout gives ~2.6-3.4 GB at 10M nodes (below).
   Reaching ~10 GB needs either maxid1 ~30M or larger slots/slack; the spec's "~10 GB target" needs a choice.
6. Multiget size. The geometric with min 1 never returns 1 (smallest is 2) and its mean is ~3.62, not the
   "~2.6" of the comment; max 128 is exclusive. Recommended default: mirror the code.
7. getlinklist_history (0.3 %) needs lists that reached the range limit; with limit 50 it would trigger far
   more often than in LinkBench (497 ids have >= 10000 links, but 29,528 have >= 50). Recommended default:
   drop history queries or keep them at p = 0.003 only for lists that were truncated.
8. LinkBench issues writes and reads from the same requester threads; our design has one writer thread per
   VM. The mix percentages carry over; the thread mapping is ours.

## Derived dataset statistics (n = 10,000,000 ids; all numbers DERIVED by applying the rules above to the CDF)
| Statistic | Nominal (CDF) | Loaded (with the type-split rule) |
| --- | --- | --- |
| mean out-degree | 4.172 (LinkBench's own expectedValue: 4.097) | 4.446 |
| total links | 41,721,824 | 44,458,555 |
| ids with 0 links | 45.33 % | 45.33 % |
| ids with >= 1 / >= 2 / >= 10 links | 54.67 / 22.54 / 1.92 % | 54.67 / 22.54 / 2.68 % |
| ids with >= 50 links | 0.2856 % (28,562 ids) | 0.2953 % (29,528 ids) |
| ids with >= 100 / >= 1000 / >= 10000 | 0.170 / 0.0494 / 0.00496 % | about the same |
| degree p50 / p90 / p99 / p99.9 / p99.99 | 1 / 3 / 15 / 264 / 6051 | 1 / 4 / 16 / 266 / 6052 |
| degree max (top 4 ranks) | 961,963; 196,788; 140,837; 114,019 | about the same |
| share of all links held by ids with >= 50 links | 69.5 % | - |
| per (id1, type) list length: p99, fraction >= 50 | 8; 0.172 % | - |

Key skew (derived, share of draws on the hottest ids among 10M): Zipf 0.8: top 0.01 % of ids 12.8 %, top 1 %
37.6 %, top 10 % 61.7 %; Zipf 0.741: 8.0 / 29.4 / 54.5 %; Zipf 0.625 (getnode): 3.0 / 17.6 / 42.1 %.

Payload sizes (derived from the lognormal, before clamping): link p50 8, mean 13.2, p90 28.8, p99 81.9 B;
node p50 128, mean 211, p90 461, p99 1310 B.

Expected bytes at 10M nodes (DERIVED; slots only, no adjacency slack, overflow headers or indexes):
| Layout | Nodes | Edges (nominal 41.7M / loaded 44.5M) | Total |
| --- | --- | --- | --- |
| 128 B node slot + 32 B edge slot | 1.28 GB | 1.34 / 1.42 GB | 2.62 / 2.70 GB |
| 128 B node slot + 48 B edge slot | 1.28 GB | 2.00 / 2.13 GB | 3.28 / 3.41 GB |
During the request phase addlink adds ~0.09 x (1 - ~0.05) new links per request (deletelink removes ~0.03 x 0.9),
so the edge count grows by ~0.058 links per request (derived); the adjacency slack must absorb that for the
run length.

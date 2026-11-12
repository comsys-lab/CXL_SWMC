// Host unit test of the serving split (server/chunk.h query_chunk, recsys-server --split-ways / --chunk-pairs /
// --min-chunk). Prints one line per case and "CHUNK TEST PASS" (exit 0) or the failing cases (exit 1).
#include <cstdio>

#include "chunk.h"

int main() {
  struct Case {
    unsigned pairs, chunk_pairs, split_ways, serve_threads, min_chunk, want_chunk, want_tasks;
  };
  const Case cs[] = {
      // --split-ways 2 --min-chunk 100 (2-way split, user decision 2026-11-13: chunk = max(100, ceil(P / 2)));
      // 150 -> chunk 100 = tasks of 100 + 50 pairs (the formula; no query of tools/dist_quantile.txt has P in (100, 200))
      {100, 0, 2, 14, 100, 100, 1}, {150, 0, 2, 14, 100, 100, 2}, {200, 0, 2, 14, 100, 100, 2},
      {270, 0, 2, 14, 100, 135, 2}, {700, 0, 2, 14, 100, 350, 2},
      // the query sizes of tools/dist_quantile.txt (100..700 step 100), 4 serving threads as on the 4-vCPU VMs
      {300, 0, 2, 4, 100, 150, 2}, {400, 0, 2, 4, 100, 200, 2}, {500, 0, 2, 4, 100, 250, 2}, {600, 0, 2, 4, 100, 300, 2},
      // default (split_ways 0 = divide by serve_threads, min_chunk 16): unchanged
      {700, 0, 0, 14, 16, 50, 14}, {100, 0, 0, 14, 16, 16, 7}, {270, 0, 0, 4, 16, 68, 4},
      // --chunk-pairs wins over --split-ways
      {700, 700, 2, 14, 100, 700, 1}, {270, 700, 0, 14, 16, 700, 1},
  };
  int bad = 0;
  for (const Case &c : cs) {
    const unsigned chunk = query_chunk(c.pairs, c.chunk_pairs, c.split_ways, c.serve_threads, c.min_chunk);
    const unsigned tasks = (c.pairs + chunk - 1) / chunk;
    const bool ok = chunk == c.want_chunk && tasks == c.want_tasks;
    bad += !ok;
    std::printf("pairs %u chunk_pairs %u split_ways %u serve_threads %u min_chunk %u -> chunk %u x %u tasks %s\n",
                c.pairs, c.chunk_pairs, c.split_ways, c.serve_threads, c.min_chunk, chunk, tasks,
                ok ? "OK" : "FAIL");
  }
  std::printf(bad ? "CHUNK TEST FAIL (%d)\n" : "CHUNK TEST PASS\n", bad);
  return bad != 0;
}

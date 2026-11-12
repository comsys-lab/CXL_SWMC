// Serving split: pairs per parallel task of one query (recsys-server start_query; Host test tests/chunk_test.cc).
//   chunk_pairs > 0               : fixed chunk (--chunk-pairs)
//   chunk_pairs = 0, split_ways 0 : max(min_chunk, ceil(pairs / serve_threads))   (default, as before --split-ways)
//   chunk_pairs = 0, split_ways K : max(min_chunk, ceil(pairs / K))                (--split-ways K; 2-way split,
//                                   user decision 2026-11-13, reports/experiments/recsys-windowed-update.md)
#pragma once
#include <algorithm>
#include <cstdint>

inline uint32_t query_chunk(uint32_t pairs, uint32_t chunk_pairs, uint32_t split_ways, uint32_t serve_threads,
                            uint32_t min_chunk) {
  if (chunk_pairs) return chunk_pairs;
  const uint32_t ways = split_ways ? split_ways : serve_threads;
  return std::max(min_chunk, (pairs + ways - 1) / ways);
}

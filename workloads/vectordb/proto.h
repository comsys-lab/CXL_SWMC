// vectordb request/response payloads (inside experiments/loadgen/frame.h frames). Little-endian, packed.
#pragma once

#include <cstdint>

namespace vdb {

enum Op : uint16_t {
  kOpInsert = 1,  // InsertReq + float vec[dim]            -> WriteResp
  kOpDelete = 2,  // DeleteReq                             -> WriteResp
  kOpSearch = 3,  // SearchReq + float q[dim]              -> SearchResp + uint64 ids[n] + float scores[n]
  kOpUpdate = 4,  // UpdateReq + float vec[dim]            -> WriteResp (w_seq = w_ins)
  kOpStats = 10,  // empty                                 -> text (key=value lines)
};

struct __attribute__((packed)) InsertReq {
  uint32_t w_seq;  // global write order 1..W (trace)
  uint32_t pad;
  uint64_t id;
};

struct __attribute__((packed)) DeleteReq {
  uint32_t w_seq;
  uint32_t pad;
  uint64_t id;
};

// Update = replace one record: delete del_id (w_seq w_del), then insert ins_id (w_seq w_ins = w_del + 1) with the
// vector, applied and published in that order by the node's writer; one request, one response after both (not atomic:
// a search with snapshot w_del sees neither, as specified by the E1 rule).
struct __attribute__((packed)) UpdateReq {
  uint32_t w_del, w_ins;
  uint64_t del_id, ins_id;
};

struct __attribute__((packed)) WriteResp {
  uint32_t w_seq;
  uint32_t p_after;  // watermark P observed after this write's own publication
};

struct __attribute__((packed)) SearchReq {
  uint32_t ref_w;  // E1 snapshot: search sees writes w_seq <= ref_w
  uint16_t k;
  uint16_t flags;
};

struct __attribute__((packed)) SearchResp {
  uint32_t s_used;
  uint16_t n;  // results (<= k)
  uint16_t flags;
  uint32_t wait_us;    // waiting for P >= ref_w
  uint32_t replay_us;  // delete-log replay
  uint32_t search_us;  // all segments, including lock waits
  uint32_t lock_us;    // waiting for segment read locks (part of search_us)
  uint32_t dists;      // distance computations
  uint16_t segs;       // segments searched
  uint16_t pad;
};

}  // namespace vdb

// socialgraph request/response payloads (inside experiments/loadgen/frame.h frames). Little-endian, packed.
// Operations follow LinkBench (tools/linkbench_params.h); getlinklist_history is dropped (experiment doc §2).
// Every response starts with RespHead; per-operation bodies follow. A coherence block (vectordb proto.h OpCoh layout,
// reused unchanged by the server in part 3) may follow the body when RespHead.flags has kRespCoh.
#pragma once

#include <cstdint>

namespace sg {

enum Op : uint16_t {
  kOpFeed = 1,        // FeedReq         -> RespHead + FeedResp + FeedRow rows[n]
  kOpGetNode = 2,     // NodeKeyReq      -> RespHead + NodeResp + uint8 data[data_len]
  kOpCountLink = 3,   // LinkListReq     -> RespHead + CountResp
  kOpGetLink = 4,     // GetLinkReq + uint32 id2[n2] -> RespHead + GetLinkResp + LinkRow rows[n]
  kOpAddLink = 11,    // LinkWriteReq + uint8 data[data_len] -> RespHead + WriteResp
  kOpUpdateLink = 12, // LinkWriteReq + uint8 data[data_len] -> RespHead + WriteResp
  kOpDeleteLink = 13, // LinkWriteReq (data_len 0)          -> RespHead + WriteResp
  kOpAddNode = 14,    // NodeWriteReq + uint8 data[data_len] -> RespHead + WriteResp (id = new node id)
  kOpUpdateNode = 15, // NodeWriteReq + uint8 data[data_len] -> RespHead + WriteResp
  kOpDeleteNode = 16, // NodeWriteReq (data_len 0)          -> RespHead + WriteResp
  kOpStats = 20,      // empty -> text (key=value lines)
};

constexpr uint16_t kRespCoh = 1;     // RespHead.flags: coherence block follows the body
constexpr uint16_t kStatusOk = 0;
constexpr uint16_t kStatusNotFound = 1;  // node / link absent or deleted
constexpr uint16_t kStatusFull = 2;      // no slack slot / pool block left (write rejected)
constexpr uint16_t kStatusBad = 3;       // malformed request

struct __attribute__((packed)) RespHead {
  uint16_t op, status, flags, pad;
  uint32_t server_us;  // server processing time (dequeue to response ready)
  uint32_t records;    // records read (feed: 1 adjacency list + n nodes) or written
};

// Feed query: getlinklist(id1, assoc_type, limit) newest first, then multiget of the up-to-limit id2 nodes.
struct __attribute__((packed)) FeedReq {
  uint64_t id1;
  uint16_t assoc_type;  // kAssocFriend
  uint16_t limit;       // 50 (experiment doc §2)
  uint32_t pad;
};
struct __attribute__((packed)) FeedResp {
  uint64_t list_version;  // AdjHeader.version read
  uint16_t n;             // rows (<= limit)
  uint16_t missing;       // id2s whose node slot was absent or deleted (row kept with node_version 0)
  uint32_t list_us;       // getlinklist part of server_us
};
struct __attribute__((packed)) FeedRow {
  uint32_t id2;
  uint32_t link_version;
  uint64_t link_time;
  uint64_t node_version;
  uint16_t node_data_len;
  uint16_t pad[3];
};

struct __attribute__((packed)) NodeKeyReq {
  uint64_t id;
};
struct __attribute__((packed)) NodeResp {
  uint64_t id, version, commit_ns;
  uint32_t type, time_s;
  uint16_t data_len;
  uint16_t pad[3];
};

struct __attribute__((packed)) LinkListReq {
  uint64_t id1;
  uint16_t assoc_type;
  uint16_t pad[3];
};
struct __attribute__((packed)) CountResp {
  uint64_t list_version;
  uint64_t count;
};

// getlink = LinkBench multiget: rows for (id1, type, id2[i]) that exist.
struct __attribute__((packed)) GetLinkReq {
  uint64_t id1;
  uint16_t assoc_type;
  uint16_t n2;  // id2 count (LinkBench geometric, < 128)
  uint32_t pad;
};
struct __attribute__((packed)) GetLinkResp {
  uint64_t list_version;
  uint16_t n;
  uint16_t pad[3];
};
struct __attribute__((packed)) LinkRow {
  uint32_t id2;
  uint32_t version;
  uint64_t time;
  uint16_t data_len;
  uint16_t pad[3];
};

// Writes. w_seq: per-writer sequence from the loadgen (logged with the commit for the staleness join).
struct __attribute__((packed)) LinkWriteReq {
  uint64_t id1;
  uint32_t id2;
  uint16_t assoc_type;
  uint16_t data_len;  // <= kEdgeDataCap (server truncates and reports the cap otherwise)
  uint64_t time;      // link time (ms)
  uint32_t w_seq;
  uint32_t pad;
};
struct __attribute__((packed)) NodeWriteReq {
  uint64_t id;        // 0 for addnode
  uint32_t type;
  uint16_t data_len;  // <= kNodeDataCap
  uint16_t pad;
  uint32_t w_seq;
  uint32_t pad2;
};
struct __attribute__((packed)) WriteResp {
  uint64_t id;         // node id (addnode: the new id) or id1
  uint64_t version;    // record version after the write (node slot or adjacency list)
  uint64_t commit_ns;  // writer commit timestamp recorded in the record
  uint32_t w_seq;
  uint32_t pad;
};

static_assert(sizeof(RespHead) == 16 && sizeof(FeedReq) == 16 && sizeof(FeedRow) == 32 && sizeof(LinkWriteReq) == 32,
              "proto sizes");

}  // namespace sg

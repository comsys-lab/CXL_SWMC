// Wire format shared by the load generator and every workload server (vectordb, later LMDB, PageRank, recsys).
// Little-endian, length-prefixed binary frames over TCP; responses may come back out of order (matched by req_id).
// Python peer: experiments/loadgen/python/frame.py (e.g. for a LangChain VectorStore client).
//
//   request : [u32 len][u16 op][u16 flags][u64 req_id][payload, len - 12 bytes]
//   response: [u32 len][u16 status][u16 flags][u64 req_id][payload, len - 12 bytes]
//
// len counts everything after the len field. op and payload layout are defined by the workload; status 0 = OK,
// other values are workload errors (kStatusBadRequest .. are common).
#pragma once

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <unistd.h>

namespace frame {

struct __attribute__((packed)) header {
  uint32_t len;
  uint16_t code;  // op (request) / status (response)
  uint16_t flags;
  uint64_t req_id;
};
static_assert(sizeof(header) == 16, "frame header is 16 bytes");

constexpr uint32_t kHeaderTail = sizeof(header) - sizeof(uint32_t);  // part of len that is header
constexpr uint32_t kMaxFrame = 64u << 20;

constexpr uint16_t kStatusOk = 0;
constexpr uint16_t kStatusBadRequest = 1;
constexpr uint16_t kStatusUnknownOp = 2;
constexpr uint16_t kStatusServerError = 3;
constexpr uint16_t kStatusTimeout = 4;  // server-side wait bound exceeded (e.g. vectordb E1 readiness)

inline void fill(header *h, uint16_t code, uint64_t req_id, uint32_t payload_len, uint16_t flags = 0) {
  h->len = kHeaderTail + payload_len;
  h->code = code;
  h->flags = flags;
  h->req_id = req_id;
}

inline uint32_t payload_len(const header &h) { return h.len - kHeaderTail; }

// Blocking full read/write helpers (servers using one thread per connection). Return false on EOF/error.
inline bool read_full(int fd, void *buf, size_t n) {
  auto *p = static_cast<uint8_t *>(buf);
  while (n) {
    ssize_t r = ::read(fd, p, n);
    if (r == 0) return false;
    if (r < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += r;
    n -= static_cast<size_t>(r);
  }
  return true;
}

inline bool write_full(int fd, const void *buf, size_t n) {
  auto *p = static_cast<const uint8_t *>(buf);
  while (n) {
    ssize_t r = ::write(fd, p, n);
    if (r < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    p += r;
    n -= static_cast<size_t>(r);
  }
  return true;
}

}  // namespace frame

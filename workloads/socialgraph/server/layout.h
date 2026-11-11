// socialgraph shared layout (DESIGN.md §1): the graph image built on the Host by tools/sg_image_gen.cc and copied
// into the SWcc range of the region in the guest. All systems map the same bytes; nothing here is system specific.
//
// Image = header page, then four page-aligned (4 KiB) arrays:
//   adj_index  uint64 per node slot: byte offset of the node's primary adjacency block inside the adjacency array
//              (kNoAdj for slack slots); read-only after the build.
//   nodes      one 128 B NodeSlot per node (original nodes, then node_slack free slots for addnode).
//   adj        one primary adjacency block per original node, packed in node order: a 64 B AdjHeader line, then
//              inline_cap 32 B EdgeSlots (inline_cap even, so every block is a whole number of 64 B lines).
//   ovf        4 KiB overflow blocks (64 B OvfHeader + 126 EdgeSlots): first the blocks of high-degree nodes (built),
//              then ovf_pool free blocks for addlink when a node's inline slack is exhausted.
// Every record (node slot, adjacency block, overflow block) starts on a 64 B line and covers whole lines, so two
// records never share a cache line. Primary blocks are packed (not page-padded); a block may straddle a 4 KiB page
// (the generator reports the fraction).
//
// Adjacency list of node i, newest first: segment chain starting at AdjHeader.head (kSegInline = the inline slots
// of the primary block, else an ovf block index); within a segment the used slots are [start, cap), newest at start
// (addlink writes slot start-1 and then decrements start, so slack sits in front of the newest edge); each segment's
// `next` names the next (older) segment (kSegInline, an ovf block index, or kSegNone). At build: head = kSegInline,
// inline holds the newest min(deg, kInlineMaxEdges) edges, older edges go to full ovf blocks (the oldest block may be
// partial, its slack in front and unused). An addlink with no inline slack takes a pool block, fills it from the end,
// sets its next = the old head and publishes it as the new head.
// Deleted links keep their slot with kEdgeLive cleared (AdjHeader.count = live links, used = occupied slots).
// Write protocol (versions, seqlock / publication order, pool and slack-slot ownership per VM) belongs to the server
// (part 3); the layout only reserves the fields: per record version + writer commit timestamp (staleness measurement).
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace sg {

constexpr uint64_t kLine = 64;
constexpr uint64_t kPage = 4096;
constexpr uint64_t kImageMagic = 0x31474d4947474753ull;  // "SGGGIMG1" little-endian
constexpr uint32_t kLayoutVersion = 1;
constexpr uint64_t kNoAdj = ~0ull;
constexpr uint32_t kSegInline = 0xfffffffeu;
constexpr uint32_t kSegNone = 0xffffffffu;

inline constexpr uint64_t align_up(uint64_t x, uint64_t a) { return (x + a - 1) / a * a; }

// ---- node slot (128 B, two lines) ----
constexpr uint16_t kNodeLive = 1;     // flags: slot holds a node
constexpr uint16_t kNodeDeleted = 2;  // deletenode (slot kept, never reused)
constexpr uint32_t kNodeDataCap = 88; // node payload cap (LinkBench node data: LogNormal median 128 B; capped)
struct alignas(64) NodeSlot {
  uint64_t id;         // external node id (= index + id_base; slack slots carry their preassigned id)
  uint64_t version;    // record version (1 at load, as LinkBench NodeLoader)
  uint64_t commit_ns;  // writer commit timestamp, CLOCK_REALTIME ns (0 = from the image)
  uint32_t type;       // node type (LinkBench kDefaultNodeType 2048)
  uint32_t time_s;     // LinkBench node time (seconds)
  uint16_t flags;      // 0 = free slack slot, kNodeLive, kNodeDeleted
  uint16_t data_len;   // <= kNodeDataCap
  uint32_t pad;
  uint8_t data[kNodeDataCap];
};
static_assert(sizeof(NodeSlot) == 128 && alignof(NodeSlot) == 64, "node slot = 2 lines");
static_assert(offsetof(NodeSlot, data) == 40, "node header 40 B");

// ---- edge slot (32 B, two per line) ----
constexpr uint8_t kEdgeLive = 1;
constexpr uint32_t kEdgeDataCap = 12;  // link payload cap (LinkBench link data: LogNormal median 8 B; capped)
constexpr uint16_t kAssocFriend = 0;   // Orkut friendship (every image link)
struct EdgeSlot {
  uint32_t id2;        // target node id
  uint16_t assoc_type;
  uint8_t flags;       // kEdgeLive
  uint8_t data_len;    // <= kEdgeDataCap
  uint64_t time;       // link time (ms; synthetic at build) -> newest-first order
  uint32_t version;    // link version (0 at load, as LinkBench)
  uint8_t data[kEdgeDataCap];
};
static_assert(sizeof(EdgeSlot) == 32, "edge slot 32 B");

// ---- primary adjacency block header (first line of the block) ----
struct alignas(64) AdjHeader {
  uint64_t id1;        // owner node id
  uint64_t version;    // list version (bumped by every link write to this list)
  uint64_t commit_ns;  // commit timestamp of that write (0 = image)
  uint32_t count;      // live links over all segments (countlink)
  uint32_t used;       // occupied slots over all segments (live + deleted)
  uint32_t head;       // newest segment: kSegInline or ovf block index
  uint32_t next;       // segment after the inline one: ovf block index or kSegNone
  uint16_t start;      // first used inline slot
  uint16_t cap;        // inline slots (even)
  uint32_t n_ovf;      // ovf blocks in the chain (built + pool)
  uint8_t pad[16];
  EdgeSlot *inline_slots() { return reinterpret_cast<EdgeSlot *>(this + 1); }
  const EdgeSlot *inline_slots() const { return reinterpret_cast<const EdgeSlot *>(this + 1); }
};
static_assert(sizeof(AdjHeader) == 64, "adj header = 1 line");

// ---- overflow block (4 KiB) ----
constexpr uint32_t kOvfSlots = (kPage - kLine) / sizeof(EdgeSlot);  // 126
constexpr uint32_t kInlineMaxEdges = 120;  // built edges kept inline (the feed limit 50 is always served inline)
constexpr uint32_t kInlineMaxCap = kOvfSlots;  // primary block <= 4 KiB
struct alignas(64) OvfHeader {
  uint64_t id1;        // owner node id (0 = free pool block)
  uint32_t next;       // older segment: ovf block index, kSegInline or kSegNone
  uint16_t start;      // first used slot
  uint16_t cap;        // kOvfSlots
  uint8_t pad[48];
};
static_assert(sizeof(OvfHeader) == 64, "ovf header = 1 line");
struct alignas(4096) OvfBlock {
  OvfHeader h;
  EdgeSlot slot[kOvfSlots];
};
static_assert(sizeof(OvfBlock) == kPage, "ovf block = 1 page");

// Inline capacity of a node with built degree deg: inline edges = min(deg, kInlineMaxEdges), plus slack
// max(2, ceil(edges / 8)) for addlink, rounded up to an even count, capped at kInlineMaxCap.
inline uint32_t inline_edges(uint64_t deg) { return deg < kInlineMaxEdges ? uint32_t(deg) : kInlineMaxEdges; }
inline uint32_t inline_cap(uint64_t deg) {
  uint32_t e = inline_edges(deg);
  uint32_t s = (e + 7) / 8;
  if (s < 2) s = 2;
  uint32_t c = (e + s + 1) & ~1u;
  return c > kInlineMaxCap ? kInlineMaxCap : c;
}
inline uint64_t primary_bytes(uint64_t deg) { return sizeof(AdjHeader) + uint64_t(inline_cap(deg)) * sizeof(EdgeSlot); }
inline uint64_t ovf_blocks_for(uint64_t deg) {
  return deg <= kInlineMaxEdges ? 0 : (deg - kInlineMaxEdges + kOvfSlots - 1) / kOvfSlots;
}

// ---- image header (page 0) ----
struct alignas(4096) ImageHeader {
  uint64_t magic;
  uint32_t layout_version;
  uint32_t header_bytes;      // sizeof(ImageHeader)
  uint64_t id_base;           // node id of slot 0
  uint64_t n_orig;            // original (Orkut) nodes, slots [0, n_orig)
  uint64_t node_slack;        // free slots [n_orig, n_orig + node_slack) for addnode
  uint64_t n_links;           // directed links in the image (2 x undirected edges)
  uint64_t adj_index_off, adj_index_bytes;
  uint64_t nodes_off, nodes_bytes;
  uint64_t adj_off, adj_bytes;  // adj_bytes = packed primary blocks (array padded to a page in the image)
  uint64_t ovf_off;
  uint64_t ovf_built;         // ovf blocks [0, ovf_built) belong to high-degree nodes
  uint64_t ovf_pool;          // free pool blocks [ovf_built, ovf_built + ovf_pool)
  uint64_t total_bytes;       // image file size (page multiple)
  uint64_t seed;              // generator seed (link times, payloads)
  uint32_t node_data_cap, edge_data_cap, inline_max_edges, ovf_slots;
  uint64_t layout_hash;       // layout_hash() of the fields above
  uint8_t pad[4096 - 160];
  uint64_t n_nodes() const { return n_orig + node_slack; }
  uint64_t ovf_blocks() const { return ovf_built + ovf_pool; }
  uint64_t ovf_bytes() const { return ovf_blocks() * kPage; }
};
static_assert(sizeof(ImageHeader) == kPage, "header = 1 page");
static_assert(offsetof(ImageHeader, pad) == 160, "header fields");

inline uint64_t layout_hash(const ImageHeader &h) {  // FNV-1a 64 over the header bytes before layout_hash
  uint64_t x = 1469598103934665603ull;
  const uint8_t *b = reinterpret_cast<const uint8_t *>(&h);
  for (size_t i = 0; i < offsetof(ImageHeader, layout_hash); i++) x = (x ^ b[i]) * 1099511628211ull;
  return x;
}

// Fill the array offsets/sizes from n_orig, node_slack, adj_bytes, ovf_built, ovf_pool (caller sets those and the
// rest of the parameters).
inline void finish_header(ImageHeader &h) {
  h.magic = kImageMagic;
  h.layout_version = kLayoutVersion;
  h.header_bytes = sizeof(ImageHeader);
  h.node_data_cap = kNodeDataCap;
  h.edge_data_cap = kEdgeDataCap;
  h.inline_max_edges = kInlineMaxEdges;
  h.ovf_slots = kOvfSlots;
  h.adj_index_off = kPage;
  h.adj_index_bytes = h.n_nodes() * sizeof(uint64_t);
  h.nodes_off = align_up(h.adj_index_off + h.adj_index_bytes, kPage);
  h.nodes_bytes = h.n_nodes() * sizeof(NodeSlot);
  h.adj_off = align_up(h.nodes_off + h.nodes_bytes, kPage);
  h.ovf_off = align_up(h.adj_off + h.adj_bytes, kPage);
  h.total_bytes = h.ovf_off + h.ovf_bytes();
  h.layout_hash = layout_hash(h);
}

// Returns "" if the header is consistent, else the first problem.
inline std::string check_header(const ImageHeader &h, uint64_t file_bytes) {
  if (h.magic != kImageMagic) return "magic";
  if (h.layout_version != kLayoutVersion || h.header_bytes != sizeof(ImageHeader)) return "layout version";
  if (h.node_data_cap != kNodeDataCap || h.edge_data_cap != kEdgeDataCap || h.inline_max_edges != kInlineMaxEdges ||
      h.ovf_slots != kOvfSlots) return "caps";
  if (h.layout_hash != layout_hash(h)) return "layout hash";
  ImageHeader c = h;
  finish_header(c);
  if (c.adj_index_off != h.adj_index_off || c.nodes_off != h.nodes_off || c.adj_off != h.adj_off ||
      c.ovf_off != h.ovf_off || c.total_bytes != h.total_bytes) return "offsets";
  if (file_bytes != h.total_bytes) return "file size";
  return "";
}

// Typed view over a mapped image (or region base).
struct View {
  uint8_t *base = nullptr;
  const ImageHeader *h = nullptr;
  explicit View(void *b) : base(static_cast<uint8_t *>(b)), h(static_cast<const ImageHeader *>(b)) {}
  uint64_t *adj_index() const { return reinterpret_cast<uint64_t *>(base + h->adj_index_off); }
  NodeSlot *node(uint64_t slot) const { return reinterpret_cast<NodeSlot *>(base + h->nodes_off) + slot; }
  bool has_adj(uint64_t slot) const { return slot < h->n_nodes() && adj_index()[slot] != kNoAdj; }
  AdjHeader *adj(uint64_t slot) const { return reinterpret_cast<AdjHeader *>(base + h->adj_off + adj_index()[slot]); }
  OvfBlock *ovf(uint64_t b) const { return reinterpret_cast<OvfBlock *>(base + h->ovf_off) + b; }
  // slot of an id, or n_nodes() if out of range
  uint64_t slot_of(uint64_t id) const { return id >= h->id_base && id - h->id_base < h->n_nodes() ? id - h->id_base : h->n_nodes(); }
  // bytes of the primary block of an original node (blocks are packed in node order)
  uint64_t primary_block_bytes(uint64_t slot) const {
    uint64_t end = slot + 1 < h->n_orig ? adj_index()[slot + 1] : h->adj_bytes;
    return end - adj_index()[slot];
  }
};

// Walk node slot's list newest first: f(const EdgeSlot &) returns false to stop. Returns slots visited.
// (No concurrency protocol here; the server wraps reads in its own version check.)
template <class F> uint64_t walk_links(const View &v, uint64_t slot, F &&f) {
  if (!v.has_adj(slot)) return 0;
  const AdjHeader *a = v.adj(slot);
  uint64_t n = 0;
  uint32_t seg = a->head;
  for (uint64_t guard = 0; seg != kSegNone && guard <= v.h->ovf_blocks() + 1; guard++) {
    const EdgeSlot *s;
    uint32_t start, cap, next;
    if (seg == kSegInline) { s = a->inline_slots(); start = a->start; cap = a->cap; next = a->next; }
    else {
      if (seg >= v.h->ovf_blocks()) break;
      const OvfBlock *o = v.ovf(seg);
      s = o->slot; start = o->h.start; cap = o->h.cap; next = o->h.next;
    }
    for (uint32_t i = start; i < cap; i++, n++)
      if (!f(s[i])) return n + 1;
    seg = next;
  }
  return n;
}

// ---- coherence objects (Megalon) ----
// Record granularity: one object per node slot, per primary adjacency block, per ovf block (built + pool).
// Data structure granularity: kChunkBytes chunks of each array (adj_index, nodes, adj, ovf), each array chunked from
// its own start (the last chunk of an array may be short).
constexpr uint64_t kChunkBytes = 36ull << 20;  // "36 MB" (Motivation H1) taken as 36 MiB
enum class ObjKind : uint8_t { kNode = 0, kAdj = 1, kOvf = 2, kAdjIndex = 3 };
struct ObjRef { ObjKind kind; uint64_t idx; uint64_t off; uint64_t bytes; };  // off = image offset

// Record objects in image order: f(const ObjRef &). adj_index is read-only and not a record object (the backend may
// keep it private or HWcc). Returns the object count.
template <class F> uint64_t for_each_record_object(const View &v, F &&f) {
  uint64_t n = 0;
  for (uint64_t i = 0; i < v.h->n_nodes(); i++, n++)
    f(ObjRef{ObjKind::kNode, i, v.h->nodes_off + i * sizeof(NodeSlot), sizeof(NodeSlot)});
  for (uint64_t i = 0; i < v.h->n_orig; i++, n++)
    f(ObjRef{ObjKind::kAdj, i, v.h->adj_off + v.adj_index()[i], v.primary_block_bytes(i)});
  for (uint64_t b = 0; b < v.h->ovf_blocks(); b++, n++)
    f(ObjRef{ObjKind::kOvf, b, v.h->ovf_off + b * kPage, kPage});
  return n;
}
inline uint64_t record_objects(const ImageHeader &h) { return h.n_nodes() + h.n_orig + h.ovf_blocks(); }

struct ChunkRef { ObjKind array; uint64_t idx; uint64_t off; uint64_t bytes; };
template <class F> uint64_t for_each_chunk(const ImageHeader &h, uint64_t chunk_bytes, F &&f) {
  const struct { ObjKind k; uint64_t off, bytes; } arr[4] = {
      {ObjKind::kAdjIndex, h.adj_index_off, h.adj_index_bytes}, {ObjKind::kNode, h.nodes_off, h.nodes_bytes},
      {ObjKind::kAdj, h.adj_off, h.adj_bytes}, {ObjKind::kOvf, h.ovf_off, h.ovf_bytes()}};
  uint64_t n = 0;
  for (const auto &a : arr)
    for (uint64_t c = 0; c * chunk_bytes < a.bytes; c++, n++) {
      uint64_t len = a.bytes - c * chunk_bytes;
      f(ChunkRef{a.k, c, a.off + c * chunk_bytes, len < chunk_bytes ? len : chunk_bytes});
    }
  return n;
}
// Chunk containing image offset off: global chunk number in for_each_chunk order, or ~0 if outside every array.
inline uint64_t chunk_of(const ImageHeader &h, uint64_t chunk_bytes, uint64_t off) {
  const uint64_t offs[4] = {h.adj_index_off, h.nodes_off, h.adj_off, h.ovf_off};
  const uint64_t lens[4] = {h.adj_index_bytes, h.nodes_bytes, h.adj_bytes, h.ovf_bytes()};
  uint64_t first = 0;
  for (int i = 0; i < 4; i++) {
    if (off >= offs[i] && off < offs[i] + lens[i]) return first + (off - offs[i]) / chunk_bytes;
    first += (lens[i] + chunk_bytes - 1) / chunk_bytes;
  }
  return ~0ull;
}

// Node slack slot / pool block ownership for N writers (one writer per VM): writer w owns the slots and blocks with
// index % n == w, so no shared allocation counter is needed (the server keeps a private cursor per writer).
inline bool owned_by(uint64_t idx, uint32_t writer, uint32_t n_writers) { return idx % n_writers == writer; }

}  // namespace sg

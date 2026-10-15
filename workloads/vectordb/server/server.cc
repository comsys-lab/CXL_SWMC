// vectordb server, one process per VM (DESIGN.md). Speaks experiments/loadgen/frame.h with workloads/vectordb/proto.h.
// Threads: one reader per connection, one writer (applies this node's writes in arrival order), N search workers,
// one index builder. Shared state: region.app (HWcc, layout.h) and SWcc objects through a Backend (backend.h).
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "backend.h"
#include "frame.h"
#include "knowhere/comp/index_param.h"
#include "knowhere/comp/knowhere_config.h"
#include "knowhere/dataset.h"
#include "knowhere/index/index_factory.h"
#include "knowhere/version.h"
#include "layout.h"
#include "proto.h"

using namespace vdb;
using cxl::hwcc::cas;
using cxl::hwcc::fetch_or;
using cxl::hwcc::load_acquire;
using cxl::hwcc::store_release;

namespace {

constexpr uint32_t kInf = 0xffffffffu;

uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "vdb-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct Opts {
  Params p;
  uint32_t node = 0, port = 7000, search_threads = 8, build_threads = 4;
  uint64_t run_id = 0;
  uint32_t hnsw_m = 16, hnsw_efc = 128, hnsw_ef = 64;
  uint64_t wait_timeout_ms = 10000, start_timeout_ms = 600000;
  std::string init_dir, pool_a;  // initial segments (tools/build_index) and pool A vectors
  std::string region;            // region config (default $CXL_REGION_CONFIG)
};

// ------------------------------------------------------------------ connections
struct Conn {
  int fd;
  std::mutex wmu;
  void reply(uint16_t status, uint64_t req_id, const void *p, uint32_t n) {
    frame::header h;
    frame::fill(&h, status, req_id, n);
    std::lock_guard<std::mutex> g(wmu);
    frame::write_full(fd, &h, sizeof(h));
    if (n) frame::write_full(fd, p, n);
  }
};

struct Job {
  std::shared_ptr<Conn> c;
  frame::header h;
  std::vector<uint8_t> p;
  uint64_t arrive_ns;
};

class Queue {
 public:
  void push(Job j) {
    {
      std::lock_guard<std::mutex> g(mu_);
      q_.push_back(std::move(j));
    }
    cv_.notify_one();
  }
  Job pop() {
    std::unique_lock<std::mutex> l(mu_);
    cv_.wait(l, [&] { return !q_.empty(); });
    Job j = std::move(q_.front());
    q_.pop_front();
    return j;
  }
  size_t size() {
    std::lock_guard<std::mutex> g(mu_);
    return q_.size();
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Job> q_;
};

// ------------------------------------------------------------------ process-local view of one segment
using KIndex = knowhere::Index<knowhere::IndexNode>;

struct LocalSeg {
  std::mutex mu;                       // sync_rows / index creation
  uint32_t cap = 0;
  std::unique_ptr<uint64_t[]> ids;     // rows [0, cached)
  std::unique_ptr<uint32_t[]> ins;
  std::atomic<uint32_t> cached{0};
  std::unique_ptr<uint64_t[]> dels;    // (row << 32 | del_seq), appended under Server::meta_mu_
  std::atomic<uint32_t> ndels{0};
  std::unique_ptr<KIndex> index;       // zero-copy view of the SWcc blob, once INDEXED
  std::atomic<bool> index_ready{false};
};

struct Stats {
  std::atomic<uint64_t> inserts{0}, deletes{0}, searches{0}, timeouts{0}, bad_records{0}, raw_scanned{0},
      index_searches{0}, builds{0}, build_ns{0}, seals{0}, mask_ns{0}, wait_ns{0}, replay_ns{0}, search_ns{0};
};

class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), p_(o_.p) {}

  void start() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.dim * 4 % 64 || p_.seg_cap % p_.chunk_recs || p_.nr_nodes == 0 || o_.node >= p_.nr_nodes)
      die("bad parameters (dim*4 % 64, seg_cap % chunk_recs, node < nr_nodes)");
    HwccLayout lay(p_);
    int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    map_ = static_cast<uint8_t *>(m);
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err))
      die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay, p_);
    auto pb = std::make_unique<PlainBackend>(r_, map_, p_, o_.node);
    if (!pb->fits(&err)) die(err);
    be_ = std::move(pb);
    std::fprintf(stderr, "vdb-server: node %u/%u run %#lx %s\nvdb-server: region %s\nvdb-server: app layout %lu B "
                 "(used %lu, hash %016lx), backend %s\n",
                 o_.node, p_.nr_nodes, (unsigned long)o_.run_id, p_.describe().c_str(),
                 cxl::region_describe(r_).c_str(), (unsigned long)lay.L.bytes(), (unsigned long)lay.L.used(),
                 (unsigned long)lay.L.hash(), be_->name().c_str());

    del_seq_.reset(new uint32_t[p_.max_ids]);
    std::fill_n(del_seq_.get(), p_.max_ids, kInf);
    loc_.reset(new uint64_t[p_.max_ids]());
    segs_.reset(new std::atomic<LocalSeg *>[uint64_t(p_.nr_nodes) * p_.max_segs]);
    for (uint64_t i = 0; i < uint64_t(p_.nr_nodes) * p_.max_segs; i++) segs_[i].store(nullptr);
    dcursor_.assign(p_.nr_nodes, 0);
    dmu_.reset(new std::mutex[p_.nr_nodes]);

    knowhere::KnowhereConfig::SetSearchThreadPoolSize(o_.search_threads);
    knowhere::KnowhereConfig::SetBuildThreadPoolSize(o_.build_threads);
    load_initial();
    store_release(&h_->nodes[o_.node].loaded, o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t v = 0; v < p_.nr_nodes; v++)
                if (load_acquire(&h_->nodes[v].loaded) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("not every node loaded its initial segments in time");

    std::thread([this] { writer(); }).detach();
    std::thread([this] { builder(); }).detach();
    for (uint32_t i = 0; i < o_.search_threads; i++) std::thread([this] { searcher(); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  std::string stats_text() {
    std::ostringstream o;
    o << "node=" << o_.node << "\nP=" << load_acquire(h_->P) << "\ninserts=" << st_.inserts << "\ndeletes="
      << st_.deletes << "\nsearches=" << st_.searches << "\ntimeouts=" << st_.timeouts << "\nbad_records="
      << st_.bad_records << "\nraw_scanned=" << st_.raw_scanned << "\nindex_searches=" << st_.index_searches
      << "\nseals=" << st_.seals << "\nbuilds=" << st_.builds << "\nbuild_ms=" << st_.build_ns / 1000000
      << "\nwait_ms=" << st_.wait_ns / 1000000 << "\nreplay_ms=" << st_.replay_ns / 1000000
      << "\nsearch_ms=" << st_.search_ns / 1000000 << "\nmask_ms=" << st_.mask_ns / 1000000
      << "\nwrite_queue=" << wq_.size() << "\nsearch_queue=" << sq_.size();
    for (uint32_t v = 0; v < p_.nr_nodes; v++)
      o << "\nseg_count." << v << "=" << load_acquire(&h_->nodes[v].seg_count) << "\ndlog_count." << v << "="
        << load_acquire(&h_->nodes[v].dlog_count);
    o << "\nbackend=" << be_->usage() << "\n";
    return o.str();
  }

 private:
  // ---------------------------------------------------------------- initial segments (prepare, unmeasured)
  // init_dir/segments.txt: "<g> <owner> <row_start> <rows>" per pool-A segment; seg-<g>.index = serialized HNSW.
  // Each node writes only its own segments (records with ins_seq 0 + the index blob) and publishes them INDEXED.
  void load_initial() {
    if (o_.init_dir.empty()) return;
    std::ifstream f(o_.init_dir + "/segments.txt");
    if (!f) die("cannot read " + o_.init_dir + "/segments.txt");
    FILE *pa = std::fopen(o_.pool_a.c_str(), "rb");
    if (!pa) die("cannot open pool A " + o_.pool_a);
    int32_t hdr[2];
    if (std::fread(hdr, 4, 2, pa) != 2 || uint32_t(hdr[1]) != p_.dim) die("pool A header/dim mismatch");
    const uint64_t t0 = now_ns();
    uint64_t g, owner, start, rows, mine = 0;
    std::vector<float> vecs;
    while (f >> g >> owner >> start >> rows) {
      if (owner != o_.node) continue;
      if (rows > p_.seg_cap) die("initial segment larger than seg_cap");
      const uint32_t i = uint32_t(cur_seg_count_++);
      if (i >= p_.max_segs) die("max_segs too small for the initial segments");
      vecs.resize(rows * p_.dim);
      if (fseeko(pa, 8 + off_t(start) * p_.dim * 4, SEEK_SET) || std::fread(vecs.data(), 4, vecs.size(), pa) != vecs.size())
        die("short read from pool A");
      for (uint64_t r = 0; r < rows; r++) write_record(i, uint32_t(r), start + r, 0, &vecs[r * p_.dim]);
      std::ifstream bf(o_.init_dir + "/seg-" + std::to_string(g) + ".index", std::ios::binary | std::ios::ate);
      if (!bf) die("missing seg-" + std::to_string(g) + ".index");
      uint64_t sz = uint64_t(bf.tellg());
      bf.seekg(0);
      std::vector<char> blob(sz);
      bf.read(blob.data(), std::streamsize(sz));
      Obj o = be_->index_create(o_.node, i, sz);
      be_->write(o, [&](uint8_t *p, uint64_t) { std::memcpy(p, blob.data(), sz); });
      SegDesc &d = h_->seg(o_.node, i);
      d.cap = uint32_t(rows);
      d.idx_off = o.off;
      d.idx_size = sz;
      d.sealed_ns = d.indexed_ns = now_ns();
      store_release(&d.published, uint32_t(rows));
      store_release(&d.state, uint32_t(kSegIndexed));
      store_release(&h_->nodes[o_.node].seg_count, cur_seg_count_);
      mine += rows;
    }
    std::fclose(pa);
    std::fprintf(stderr, "vdb-server: loaded %lu initial records in %lu segments (%.1f s)\n", (unsigned long)mine,
                 (unsigned long)cur_seg_count_, (now_ns() - t0) / 1e9);
  }

  void write_record(uint32_t seg, uint32_t row, uint64_t id, uint32_t ins_seq, const float *vec) {
    const uint64_t rb = rec_bytes(p_);
    Obj o = be_->raw_chunk(o_.node, seg, row / p_.chunk_recs);
    const uint64_t off = uint64_t(row % p_.chunk_recs) * rb;
    be_->write(o, [&](uint8_t *p, uint64_t) {
      RecHeader hd{};
      hd.id = id;
      hd.ins_seq = ins_seq;
      hd.check = uint32_t(id) ^ uint32_t(id >> 32) ^ ins_seq ^ kRecMagic;
      std::memcpy(p + off, &hd, sizeof(hd));
      std::memcpy(p + off + sizeof(hd), vec, size_t(p_.dim) * 4);
    });
  }

  // ---------------------------------------------------------------- writer (this node's writes, arrival order)
  void writer() {
    for (;;) {
      Job j = wq_.pop();
      const uint32_t n = frame::payload_len(j.h);
      if (j.h.code == kOpInsert && n == sizeof(InsertReq) + p_.dim * 4) {
        InsertReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (rq.id >= p_.max_ids || rq.w_seq == 0 || rq.w_seq > p_.max_writes) { bad(j); continue; }
        do_insert(rq.w_seq, rq.id, reinterpret_cast<const float *>(j.p.data() + sizeof(rq)));
        finish_write(j, rq.w_seq);
        st_.inserts++;
      } else if (j.h.code == kOpDelete && n == sizeof(DeleteReq)) {
        DeleteReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (rq.id >= p_.max_ids || rq.w_seq == 0 || rq.w_seq > p_.max_writes) { bad(j); continue; }
        do_delete(rq.w_seq, rq.id);
        finish_write(j, rq.w_seq);
        st_.deletes++;
      } else {
        bad(j);
      }
    }
  }

  void bad(Job &j) { j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0); }

  void do_insert(uint32_t w, uint64_t id, const float *vec) {
    NodeLine &me = h_->nodes[o_.node];
    if (grow_seg_ < 0 || grow_rows_ == p_.seg_cap) {
      if (grow_seg_ >= 0) seal(uint32_t(grow_seg_));
      if (cur_seg_count_ >= p_.max_segs) die("max_segs reached");
      grow_seg_ = int64_t(cur_seg_count_);
      SegDesc &d = h_->seg(o_.node, uint32_t(grow_seg_));
      d.cap = p_.seg_cap;
      d.idx_off = d.idx_size = 0;
      store_release(&d.published, 0u);
      store_release(&d.state, uint32_t(kSegGrowing));
      store_release(&me.seg_count, ++cur_seg_count_);  // descriptor complete before it is listed
      grow_rows_ = 0;
    }
    write_record(uint32_t(grow_seg_), grow_rows_, id, w, vec);
    store_release(&h_->seg(o_.node, uint32_t(grow_seg_)).published, ++grow_rows_);
    if (grow_rows_ == p_.seg_cap) {
      seal(uint32_t(grow_seg_));
      grow_seg_ = -1;
    }
  }

  void seal(uint32_t seg) {
    SegDesc &d = h_->seg(o_.node, seg);
    if (load_acquire(&d.state) != kSegGrowing) return;
    d.sealed_ns = now_ns();
    store_release(&d.state, uint32_t(kSegSealed));
    st_.seals++;
    {
      std::lock_guard<std::mutex> g(bmu_);
      build_q_.push_back(seg);
    }
    bcv_.notify_one();
  }

  void do_delete(uint32_t w, uint64_t id) {
    NodeLine &me = h_->nodes[o_.node];
    const uint64_t e = dlog_next_++;
    if (e >= p_.max_deletes) die("max_deletes reached");
    Obj o = be_->dlog_chunk(o_.node, uint32_t(e / p_.dlog_chunk));
    const uint64_t off = (e % p_.dlog_chunk) * sizeof(DlogEntry);
    be_->write(o, [&](uint8_t *p, uint64_t) {
      DlogEntry de{};
      de.id = id;
      de.del_seq = w;
      de.check = uint32_t(id) ^ uint32_t(id >> 32) ^ w ^ kRecMagic;
      std::memcpy(p + off, &de, sizeof(de));
    });
    store_release(&me.dlog_count, e + 1);
  }

  // applied[w] then advance P over contiguous set bits (both nodes' writers race through CAS)
  void finish_write(Job &j, uint32_t w) {
    fetch_or(&h_->applied[w >> 6], uint64_t(1) << (w & 63));
    uint64_t p = load_acquire(h_->P);
    for (;;) {
      uint64_t q = p;
      while (q + 1 <= p_.max_writes && (load_acquire(&h_->applied[(q + 1) >> 6]) >> ((q + 1) & 63) & 1)) q++;
      if (q == p || cas(h_->P, &p, q)) break;
    }
    h_->nodes[o_.node].writes_applied++;
    WriteResp r{w, uint32_t(load_acquire(h_->P))};
    j.c->reply(frame::kStatusOk, j.h.req_id, &r, sizeof(r));
  }

  // ---------------------------------------------------------------- index builder (own sealed segments)
  void builder() {
    std::vector<float> vecs;
    for (;;) {
      uint32_t seg;
      {
        std::unique_lock<std::mutex> l(bmu_);
        bcv_.wait(l, [&] { return !build_q_.empty(); });
        seg = build_q_.front();
        build_q_.pop_front();
      }
      const uint64_t t0 = now_ns();
      SegDesc &d = h_->seg(o_.node, seg);
      const uint32_t cap = d.cap, rb = uint32_t(rec_bytes(p_));
      vecs.resize(uint64_t(cap) * p_.dim);
      for (uint32_t j = 0; j * p_.chunk_recs < cap; j++) {
        be_->read(be_->raw_chunk(o_.node, seg, j), [&](const uint8_t *p, uint64_t) {
          for (uint32_t r = 0; r < p_.chunk_recs && j * p_.chunk_recs + r < cap; r++)
            std::memcpy(&vecs[uint64_t(j * p_.chunk_recs + r) * p_.dim], p + uint64_t(r) * rb + sizeof(RecHeader),
                        size_t(p_.dim) * 4);
        });
      }
      auto idx = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(knowhere::IndexEnum::INDEX_HNSW,
                                                                           knowhere::Version::GetCurrentVersion().VersionNumber());
      if (!idx.has_value()) die("knowhere create");
      knowhere::Json conf = conf_base();
      conf[knowhere::indexparam::HNSW_M] = o_.hnsw_m;
      conf[knowhere::indexparam::EFCONSTRUCTION] = o_.hnsw_efc;
      auto ds = knowhere::GenDataSet(cap, p_.dim, vecs.data());
      if (idx.value().Build(ds, conf) != knowhere::Status::success) die("knowhere build");
      knowhere::BinarySet bs;
      if (idx.value().Serialize(bs) != knowhere::Status::success) die("knowhere serialize");
      auto bin = bs.GetByName(idx.value().Type());
      Obj o = be_->index_create(o_.node, seg, uint64_t(bin->size));
      be_->write(o, [&](uint8_t *p, uint64_t) { std::memcpy(p, bin->data.get(), size_t(bin->size)); });
      d.idx_off = o.off;
      d.idx_size = uint64_t(bin->size);
      d.indexed_ns = now_ns();
      store_release(&d.state, uint32_t(kSegIndexed));
      st_.builds++;
      st_.build_ns += now_ns() - t0;
    }
  }

  knowhere::Json conf_base() const {
    knowhere::Json c;
    c[knowhere::meta::METRIC_TYPE] = knowhere::metric::IP;
    c[knowhere::meta::DIM] = p_.dim;
    return c;
  }

  // ---------------------------------------------------------------- reader side
  LocalSeg *local(uint32_t node, uint32_t seg, uint32_t cap) {
    auto &slot = segs_[uint64_t(node) * p_.max_segs + seg];
    LocalSeg *s = slot.load(std::memory_order_acquire);
    if (s) return s;
    std::lock_guard<std::mutex> g(segs_mu_);
    s = slot.load(std::memory_order_acquire);
    if (!s) {
      s = new LocalSeg;
      s->cap = cap;
      s->ids.reset(new uint64_t[cap]);
      s->ins.reset(new uint32_t[cap]);
      s->dels.reset(new uint64_t[cap]);
      slot.store(s, std::memory_order_release);
    }
    return s;
  }

  // Cache ids/ins_seq of rows [cached, upto) (immutable once published); register them for delete replay.
  void sync_rows(uint32_t node, uint32_t seg, LocalSeg *L, uint32_t upto) {
    if (L->cached.load(std::memory_order_acquire) >= upto) return;
    std::lock_guard<std::mutex> g(L->mu);
    uint32_t from = L->cached.load(std::memory_order_relaxed);
    if (from >= upto) return;
    const uint32_t rb = uint32_t(rec_bytes(p_));
    std::vector<RecHeader> hdr(upto - from);
    for (uint32_t j = from / p_.chunk_recs; j * p_.chunk_recs < upto; j++) {
      const uint32_t a = std::max(from, j * p_.chunk_recs), b = std::min(upto, (j + 1) * p_.chunk_recs);
      be_->read(be_->raw_chunk(node, seg, j), [&](const uint8_t *p, uint64_t) {
        for (uint32_t r = a; r < b; r++)
          std::memcpy(&hdr[r - from], p + uint64_t(r - j * p_.chunk_recs) * rb, sizeof(RecHeader));
      });
    }
    std::lock_guard<std::mutex> m(meta_mu_);
    for (uint32_t r = from; r < upto; r++) {
      const RecHeader &h = hdr[r - from];
      if (h.check != (uint32_t(h.id) ^ uint32_t(h.id >> 32) ^ h.ins_seq ^ kRecMagic) || h.id >= p_.max_ids) {
        st_.bad_records++;
        L->ids[r] = ~0ull;
        L->ins[r] = kInf;
        continue;
      }
      L->ids[r] = h.id;
      L->ins[r] = h.ins_seq;
      loc_[h.id] = ((uint64_t(node) * p_.max_segs + seg) << 32 | r) + 1;
      uint32_t ds = del_seq_[h.id];
      if (ds != kInf) add_del(L, r, ds);
    }
    L->cached.store(upto, std::memory_order_release);
  }

  void add_del(LocalSeg *L, uint32_t row, uint32_t ds) {  // under meta_mu_
    uint32_t n = L->ndels.load(std::memory_order_relaxed);
    if (n >= L->cap) return;
    L->dels[n] = uint64_t(row) << 32 | ds;
    L->ndels.store(n + 1, std::memory_order_release);
  }

  // Replay node u's delete log up to `upto` entries into del_seq_ (one cursor per log, under dmu_[u]).
  void replay(uint32_t u, uint64_t upto) {
    std::lock_guard<std::mutex> g(dmu_[u]);
    uint64_t from = dcursor_[u];
    while (from < upto) {
      const uint32_t j = uint32_t(from / p_.dlog_chunk);
      const uint64_t a = from, b = std::min<uint64_t>(upto, uint64_t(j + 1) * p_.dlog_chunk);
      std::vector<DlogEntry> ent(b - a);
      be_->read(be_->dlog_chunk(u, j), [&](const uint8_t *p, uint64_t) {
        std::memcpy(ent.data(), p + (a - uint64_t(j) * p_.dlog_chunk) * sizeof(DlogEntry), ent.size() * sizeof(DlogEntry));
      });
      std::lock_guard<std::mutex> m(meta_mu_);
      for (auto &e : ent) {
        if (e.check != (uint32_t(e.id) ^ uint32_t(e.id >> 32) ^ e.del_seq ^ kRecMagic) || e.id >= p_.max_ids) {
          st_.bad_records++;
          continue;
        }
        if (e.del_seq < del_seq_[e.id]) __atomic_store_n(&del_seq_[e.id], e.del_seq, __ATOMIC_RELAXED);
        uint64_t lc = loc_[e.id];
        if (lc) {
          lc--;
          uint64_t gi = lc >> 32;
          LocalSeg *L = segs_[gi].load(std::memory_order_acquire);
          if (L) add_del(L, uint32_t(lc), e.del_seq);
        }
      }
      from = b;
    }
    dcursor_[u] = from;
  }

  struct Cand {
    float score;
    uint64_t id;
  };

  static void push_topk(std::vector<Cand> &top, uint32_t k, float s, uint64_t id) {
    if (top.size() < k) {
      top.push_back({s, id});
      std::push_heap(top.begin(), top.end(), [](const Cand &a, const Cand &b) { return a.score > b.score; });
    } else if (s > top.front().score) {
      std::pop_heap(top.begin(), top.end(), [](const Cand &a, const Cand &b) { return a.score > b.score; });
      top.back() = {s, id};
      std::push_heap(top.begin(), top.end(), [](const Cand &a, const Cand &b) { return a.score > b.score; });
    }
  }

  static float dot(const float *a, const float *b, uint32_t d) {
    float s = 0;
#pragma omp simd reduction(+ : s)
    for (uint32_t i = 0; i < d; i++) s += a[i] * b[i];
    return s;
  }

  void searcher() {
    std::vector<uint8_t> mask;
    std::vector<uint8_t> out;
    for (;;) {
      Job j = sq_.pop();
      const uint32_t n = frame::payload_len(j.h);
      if (n != sizeof(SearchReq) + p_.dim * 4) { bad(j); continue; }
      SearchReq rq;
      std::memcpy(&rq, j.p.data(), sizeof(rq));
      const float *q = reinterpret_cast<const float *>(j.p.data() + sizeof(rq));
      const uint32_t k = std::min<uint32_t>(std::max<uint32_t>(rq.k, 1), 1024);
      const uint64_t s = rq.ref_w;
      SearchResp resp{};
      resp.s_used = rq.ref_w;
      // E1 readiness: P >= s (every write <= s published by its writer)
      const uint64_t t0 = now_ns();
      if (!cxl::hwcc::poll_until([&] { return load_acquire(h_->P) >= s; }, o_.wait_timeout_ms)) {
        st_.timeouts++;
        j.c->reply(frame::kStatusTimeout, j.h.req_id, nullptr, 0);
        continue;
      }
      const uint64_t t1 = now_ns();
      for (uint32_t u = 0; u < p_.nr_nodes; u++) {
        uint64_t c = load_acquire(&h_->nodes[u].dlog_count);
        if (dcursor_snapshot(u) < c) replay(u, c);
      }
      const uint64_t t2 = now_ns();
      std::vector<Cand> top;
      top.reserve(k + 1);
      uint64_t mask_ns = 0;
      for (uint32_t u = 0; u < p_.nr_nodes; u++) {
        const uint64_t nseg = load_acquire(&h_->nodes[u].seg_count);
        for (uint32_t i = 0; i < nseg; i++) {
          SegDesc &d = h_->seg(u, i);
          const uint32_t state = load_acquire(&d.state);
          const uint32_t pub = load_acquire(&d.published);
          const uint32_t cap = d.cap;
          LocalSeg *L = local(u, i, cap);
          if (state == kSegIndexed) {
            sync_rows(u, i, L, cap);
            const uint64_t m0 = now_ns();
            // snapshot mask: bit = filtered out. Rows with ins_seq > s are a suffix (append order = w_seq order).
            const uint32_t vis = uint32_t(std::upper_bound(L->ins.get(), L->ins.get() + cap, uint32_t(s)) - L->ins.get());
            mask.assign((cap + 7) / 8, 0);
            for (uint32_t r = vis; r < cap; r++) mask[r >> 3] |= uint8_t(1u << (r & 7));
            const uint32_t nd = L->ndels.load(std::memory_order_acquire);
            for (uint32_t x = 0; x < nd; x++) {
              uint64_t e = L->dels[x];
              if (uint32_t(e) <= s) mask[(e >> 32) >> 3] |= uint8_t(1u << ((e >> 32) & 7));
            }
            mask_ns += now_ns() - m0;
            if (vis == 0) continue;
            search_index(u, i, d, L, q, k, mask.data(), cap, &top);
            resp.indexed_segs++;
          } else {
            if (state == kSegSealed) resp.sealed_backlog++;
            if (pub == 0) continue;
            sync_rows(u, i, L, pub);
            const uint32_t vis = uint32_t(std::upper_bound(L->ins.get(), L->ins.get() + pub, uint32_t(s)) - L->ins.get());
            scan_raw(u, i, L, vis, s, q, k, &top);
            resp.raw_scanned += vis;
          }
        }
      }
      const uint64_t t3 = now_ns();
      std::sort(top.begin(), top.end(), [](const Cand &a, const Cand &b) { return a.score > b.score; });
      resp.n = uint16_t(top.size());
      resp.wait_us = uint32_t((t1 - t0) / 1000);
      resp.replay_us = uint32_t((t2 - t1) / 1000);
      resp.search_us = uint32_t((t3 - t2) / 1000);
      resp.mask_us = uint32_t(mask_ns / 1000);
      out.resize(sizeof(resp) + top.size() * 12);
      std::memcpy(out.data(), &resp, sizeof(resp));
      for (size_t x = 0; x < top.size(); x++) {
        std::memcpy(out.data() + sizeof(resp) + x * 8, &top[x].id, 8);
        std::memcpy(out.data() + sizeof(resp) + top.size() * 8 + x * 4, &top[x].score, 4);
      }
      j.c->reply(frame::kStatusOk, j.h.req_id, out.data(), uint32_t(out.size()));
      st_.searches++;
      st_.raw_scanned += resp.raw_scanned;
      st_.index_searches += resp.indexed_segs;
      st_.wait_ns += t1 - t0;
      st_.replay_ns += t2 - t1;
      st_.search_ns += t3 - t2;
      st_.mask_ns += mask_ns;
    }
  }

  uint64_t dcursor_snapshot(uint32_t u) {
    std::lock_guard<std::mutex> g(dmu_[u]);
    return dcursor_[u];
  }

  void scan_raw(uint32_t u, uint32_t seg, LocalSeg *L, uint32_t vis, uint64_t s, const float *q, uint32_t k,
                std::vector<Cand> *top) {
    const uint32_t rb = uint32_t(rec_bytes(p_));
    std::vector<Cand> attempt;
    for (uint32_t j = 0; j * p_.chunk_recs < vis; j++) {
      const uint32_t a = j * p_.chunk_recs, b = std::min(vis, (j + 1) * p_.chunk_recs);
      be_->read(be_->raw_chunk(u, seg, j), [&](const uint8_t *p, uint64_t) {
        attempt.clear();  // per-attempt local result (a backend may re-run the body)
        for (uint32_t r = a; r < b; r++) {
          const uint64_t id = L->ids[r];
          if (id == ~0ull || del_seq_relaxed(id) <= s) continue;
          const float *v = reinterpret_cast<const float *>(p + uint64_t(r - a) * rb + sizeof(RecHeader));
          push_topk(attempt, k, dot(q, v, p_.dim), id);
        }
      });
      for (auto &c : attempt) push_topk(*top, k, c.score, c.id);
    }
  }

  uint32_t del_seq_relaxed(uint64_t id) const { return __atomic_load_n(&del_seq_[id], __ATOMIC_RELAXED); }

  void search_index(uint32_t u, uint32_t seg, SegDesc &d, LocalSeg *L, const float *q, uint32_t k,
                    const uint8_t *mask, uint32_t cap, std::vector<Cand> *top) {
    if (!L->index_ready.load(std::memory_order_acquire)) {
      std::lock_guard<std::mutex> g(L->mu);
      if (!L->index_ready.load(std::memory_order_relaxed)) {
        Obj o = be_->index_ref(u, seg, d.idx_off, d.idx_size);
        auto idx = knowhere::IndexFactory::Instance().Create<knowhere::fp32>(
            knowhere::IndexEnum::INDEX_HNSW, knowhere::Version::GetCurrentVersion().VersionNumber());
        if (!idx.has_value()) die("knowhere create");
        L->index = std::make_unique<KIndex>(std::move(idx.value()));
        knowhere::BinarySet bs;
        // zero-copy view of the immutable blob in SWcc (knowhere destijl-zero-copy patch)
        bs.Append(L->index->Type(),
                  std::shared_ptr<uint8_t[]>(const_cast<uint8_t *>(be_->view(o)), [](uint8_t *) {}), int64_t(o.size));
        knowhere::Json c = conf_base();
        c["zero_copy"] = true;
        if (L->index->Deserialize(bs, c) != knowhere::Status::success) die("knowhere deserialize (zero copy)");
        L->index_ready.store(true, std::memory_order_release);
      }
    }
    knowhere::Json c = conf_base();
    c[knowhere::meta::TOPK] = k;
    c[knowhere::indexparam::EF] = std::max<uint32_t>(o_.hnsw_ef, k);
    auto ds = knowhere::GenDataSet(1, p_.dim, q);
    auto res = L->index->Search(ds, c, knowhere::BitsetView(mask, cap));
    if (!res.has_value()) die("knowhere search");
    const int64_t *ids = res.value()->GetIds();
    const float *dist = res.value()->GetDistance();
    for (uint32_t x = 0; x < k; x++) {
      if (ids[x] < 0 || ids[x] >= int64_t(cap)) continue;
      push_topk(*top, k, dist[x], L->ids[ids[x]]);
    }
  }

  // ---------------------------------------------------------------- network
  void listen_loop() {
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "vdb-server: READY node %u port %u\n", o_.node, o_.port);
    for (;;) {
      int fd = accept(ls, nullptr, nullptr);
      if (fd < 0) continue;
      int buf = 4 << 20;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof(buf));
      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
      auto c = std::make_shared<Conn>();
      c->fd = fd;
      std::thread([this, c] { read_conn(c); }).detach();
    }
  }

  void read_conn(std::shared_ptr<Conn> c) {
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h)), now_ns()};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpInsert:
        case kOpDelete: wq_.push(std::move(j)); break;
        case kOpSearch: sq_.push(std::move(j)); break;
        case kOpStats: {
          std::string t = stats_text();
          c->reply(frame::kStatusOk, h.req_id, t.data(), uint32_t(t.size()));
          break;
        }
        default: c->reply(frame::kStatusUnknownOp, h.req_id, nullptr, 0);
      }
    }
    close(c->fd);
  }

  Opts o_;
  Params p_;
  cxl::region r_;
  uint8_t *map_ = nullptr;
  std::unique_ptr<Hwcc> h_;
  std::unique_ptr<Backend> be_;
  Stats st_;
  Queue wq_, sq_;
  // writer-owned
  uint64_t cur_seg_count_ = 0, dlog_next_ = 0;
  int64_t grow_seg_ = -1;
  uint32_t grow_rows_ = 0;
  // builder
  std::mutex bmu_;
  std::condition_variable bcv_;
  std::deque<uint32_t> build_q_;
  // reader-side local state
  std::unique_ptr<uint32_t[]> del_seq_;
  std::unique_ptr<uint64_t[]> loc_;  // id -> (global seg << 32 | row) + 1, 0 = unknown
  std::unique_ptr<std::atomic<LocalSeg *>[]> segs_;
  std::mutex segs_mu_, meta_mu_;
  std::vector<uint64_t> dcursor_;
  std::unique_ptr<std::mutex[]> dmu_;
};

volatile sig_atomic_t g_stop = 0;

void usage() {
  std::fprintf(stderr,
               "usage: vdb-server --node K --nodes N --run-id 0x.. [--port P] [--region yaml]\n"
               "  [--init-dir DIR --pool-a pool_a.fbin] [--search-threads N] [--build-threads N]\n"
               "  [--dim D] [--max-writes W] [--max-ids N] [--seg-cap C] [--chunk-recs R] [--max-segs S]\n"
               "  [--dlog-chunk E] [--max-deletes D] [--hnsw-m M] [--hnsw-efc E] [--hnsw-ef E]\n"
               "  [--wait-timeout-ms T] [--start-timeout-ms T]\n"
               "All nodes need identical parameters (checked through the HWcc app layout hash).\n"
               "CXL_APP_HWCC_BYTES must equal the app layout size: vdb-server --print-app-bytes [params].\n");
  std::exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  Opts o;
  bool print_bytes = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) usage();
      return argv[++i];
    };
    if (a == "--node") o.node = std::stoul(v());
    else if (a == "--nodes") o.p.nr_nodes = std::stoul(v());
    else if (a == "--run-id") o.run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--port") o.port = std::stoul(v());
    else if (a == "--region") o.region = v();
    else if (a == "--init-dir") o.init_dir = v();
    else if (a == "--pool-a") o.pool_a = v();
    else if (a == "--search-threads") o.search_threads = std::stoul(v());
    else if (a == "--build-threads") o.build_threads = std::stoul(v());
    else if (a == "--dim") o.p.dim = std::stoul(v());
    else if (a == "--max-writes") o.p.max_writes = std::stoull(v());
    else if (a == "--max-ids") o.p.max_ids = std::stoull(v());
    else if (a == "--seg-cap") o.p.seg_cap = std::stoul(v());
    else if (a == "--chunk-recs") o.p.chunk_recs = std::stoul(v());
    else if (a == "--max-segs") o.p.max_segs = std::stoul(v());
    else if (a == "--dlog-chunk") o.p.dlog_chunk = std::stoul(v());
    else if (a == "--max-deletes") o.p.max_deletes = std::stoull(v());
    else if (a == "--hnsw-m") o.hnsw_m = std::stoul(v());
    else if (a == "--hnsw-efc") o.hnsw_efc = std::stoul(v());
    else if (a == "--hnsw-ef") o.hnsw_ef = std::stoul(v());
    else if (a == "--wait-timeout-ms") o.wait_timeout_ms = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--print-app-bytes") print_bytes = true;
    else usage();
  }
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.p).L.bytes());
    return 0;
  }
  if (o.run_id == 0) usage();
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  Server s(o);
  s.start();
  while (!g_stop) usleep(200000);
  std::fprintf(stderr, "vdb-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);
}

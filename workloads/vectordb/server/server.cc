// vectordb server, one process per VM (DESIGN.md §11). Speaks experiments/loadgen/frame.h with
// workloads/vectordb/proto.h. Data: `segments` HNSW graphs (shm_hnsw.h) shared by all nodes in CXL memory; record id
// -> segment id % segments; every node inserts into every segment under the segment's HWcc write lock, searches take
// the read lock (Qdrant-style). Threads: one reader per connection, one writer (this node's writes in arrival
// order), N search workers. Backend (--backend plain|megalon, DESIGN.md §7, §12): where the SWcc data live and which
// coherence actions wrap each access; Server<Backend> is compiled once per backend, so the plain path has no
// indirection.
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
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include "backend.h"
#include "frame.h"
#include "layout.h"
#include "megalon_backend.h"
#include "proto.h"
#include "shm_hnsw.h"

using namespace vdb;
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
  uint32_t node = 0, port = 7000, search_threads = 8, ef = 64;
  uint64_t run_id = 0, seed = 20261015;
  uint64_t wait_timeout_ms = 10000, start_timeout_ms = 600000;
  std::string init_dir;  // initial segments (tools/build_index); node 0 loads them
  // Popcorn init_state=shared (reports/P-popcorn-init-shared.md): --preload-only writes the initial chunk images into
  // SWcc through a plain mapping BEFORE coherence is enabled and exits (no HWcc access); the later server run with
  // --preloaded only publishes the segment meta (HWcc) and does not copy the chunks again.
  bool preload_only = false, preloaded = false;
  std::string region;    // region config (default $CXL_REGION_CONFIG)
  std::string backend = "plain";
  std::string megalon_lib;  // default: <dir of the executable>/../lib/libvdb-megalon.so
};

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

struct Stats {
  std::atomic<uint64_t> inserts{0}, deletes{0}, searches{0}, timeouts{0}, bad_records{0}, dists{0}, wait_ns{0},
      replay_ns{0}, search_ns{0}, lock_ns{0}, insert_ns{0}, insert_lock_ns{0};
};

template <class Be>
class Server {
 public:
  using Graph = HnswT<typename Be::Acc>;
  explicit Server(Opts o) : o_(std::move(o)), p_(o_.p) {}

  void start() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || o_.node >= p_.nr_nodes || p_.segments == 0) die("bad node/nodes/segments");
    HwccLayout lay(p_, Be::kLayoutTag);
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      // Megalon maps the whole device at map_va when its library initialises (dlopen; joins the run and waits in its
      // start barrier for every node); the server uses that mapping and never maps the device itself.
      if (2 + o_.search_threads > 32) die("megalon: at most 32 registered threads per node (main, writer, searchers)");
      api_ = megalon_load(o_.megalon_lib, &err);
      if (!api_) die(err);
      if (api_->node_id() != o_.node) die("megalon node id " + std::to_string(api_->node_id()) + " != --node");
      if (!mapped_by(r_.map_va, r_.device_size, r_.device, &err)) die(err);
      map_ = reinterpret_cast<uint8_t *>(r_.map_va);
      std::fprintf(stderr, "vdb-server: megalon initialised (%s), device mapped by Megalon at map_va\n", api_->info);
    } else {
      int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
      if (fd < 0) die("open " + r_.device);
      void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
      if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
      map_ = static_cast<uint8_t *>(m);
    }
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay);
    if constexpr (std::is_same_v<Be, MegalonBackend>) be_ = std::make_unique<Be>(r_, map_, p_, api_);
    else be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    be_->thread_init(0);  // main thread: prepare (object creation, initial copy) and warm-up
    for (uint32_t s = 0; s < p_.segments; s++) g_.push_back(std::make_unique<Graph>(p_.g, be_->mem(s, &h_->segs[s].meta)));
    std::fprintf(stderr,
                 "vdb-server: node %u/%u run %#lx %s\nvdb-server: region %s\nvdb-server: app layout %lu B (used %lu, "
                 "hash %016lx), backend %s\n",
                 o_.node, p_.nr_nodes, (unsigned long)o_.run_id, p_.describe().c_str(), cxl::region_describe(r_).c_str(),
                 (unsigned long)lay.L.bytes(), (unsigned long)lay.L.used(), (unsigned long)lay.L.hash(),
                 be_->usage().c_str());
    del_seq_.reset(new uint32_t[p_.max_ids]);
    std::fill_n(del_seq_.get(), p_.max_ids, kInf);
    dcursor_.assign(p_.nr_nodes, 0);
    dmu_.reset(new std::mutex[p_.nr_nodes]);
    rng_.seed(o_.seed * 1000003 + o_.node);

    if (o_.node == 0) load_initial();
    store_release(&h_->nodes[o_.node].loaded, o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t v = 0; v < p_.nr_nodes; v++)
                if (load_acquire(&h_->nodes[v].loaded) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("not every node became ready in time");
    warm_up();
    std::thread([this] { writer(); }).detach();
    for (uint32_t i = 0; i < o_.search_threads; i++) std::thread([this, i] { searcher(int(2 + i)); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  std::string stats_text() {
    std::ostringstream o;
    uint64_t elems = 0;
    for (auto &g : g_) elems += g->count();
    o << "node=" << o_.node << "\nP=" << load_acquire(h_->P) << "\nelements=" << elems << "\ninserts=" << st_.inserts
      << "\ndeletes=" << st_.deletes << "\nsearches=" << st_.searches << "\ntimeouts=" << st_.timeouts
      << "\nbad_records=" << st_.bad_records << "\ndists=" << st_.dists << "\nwait_ms=" << st_.wait_ns / 1000000
      << "\nreplay_ms=" << st_.replay_ns / 1000000 << "\nsearch_ms=" << st_.search_ns / 1000000
      << "\nsearch_lock_ms=" << st_.lock_ns / 1000000 << "\ninsert_ms=" << st_.insert_ns / 1000000
      << "\ninsert_lock_ms=" << st_.insert_lock_ns / 1000000 << "\nwrite_queue=" << wq_.size()
      << "\nsearch_queue=" << search_queue_len();
    for (uint32_t v = 0; v < p_.nr_nodes; v++) o << "\ndlog_count." << v << "=" << load_acquire(&h_->nodes[v].dlog_count);
    o << "\nbackend=" << be_->usage() << "\n" << be_->stats();
    return o.str();
  }

 private:
  // ---------------------------------------------------------------- initial segments (prepare, node 0, unmeasured)
  // init_dir: segments.txt ("<s> <count> <ep_level> <upper_cur>"), per group g < ceil(count / per_chunk):
  // seg-<s>-v<g>.bin (vector chunk, used bytes) and seg-<s>-l<g>.bin (whole link chunk); manifest.txt with the graph
  // parameters. Images are copied into the chunk objects as is (offsets are chunk-relative).
  void load_initial() {
    for (uint32_t s = 0; s < p_.segments; s++) Graph::init_empty(&h_->segs[s].meta);
    const uint64_t t0 = now_ns();
    std::string err;
    if (!be_->create_objects(&err)) die(err);
    if (o_.init_dir.empty()) return;
    std::ifstream man(o_.init_dir + "/manifest.txt");
    std::string line, want = "graph " + std::to_string(p_.segments) + " " + std::to_string(p_.g.dim) + " " +
                             std::to_string(p_.g.M) + " " + std::to_string(p_.g.ef_construction) + " " +
                             std::to_string(p_.g.capacity) + " " + std::to_string(p_.g.chunk_bytes);
    bool ok = false;
    while (std::getline(man, line)) ok = ok || line == want;
    if (!ok) die("init_dir manifest does not contain '" + want + "' (built for other parameters)");
    std::ifstream f(o_.init_dir + "/segments.txt");
    uint64_t s, count, epl, ucur, total = 0;
    uint32_t seen = 0;
    while (f >> s >> count >> epl >> ucur) {
      if (s >= p_.segments || count > p_.g.capacity || ucur > p_.g.upper_group_bytes()) die("bad segments.txt");
      const uint64_t N = p_.g.per_chunk();
      for (uint64_t g = 0; !o_.preloaded && g * N < count; g++) {
        const std::string b = o_.init_dir + "/seg-" + std::to_string(s);
        const uint64_t vb = std::min(N, count - g * N) * p_.g.vrec_bytes(), lb = p_.g.lchunk_bytes();
        be_->write_chunk(Chunk::kVec, uint32_t(s), g, 0, vb, [&](uint8_t *dst) { read_file(b + "-v" + std::to_string(g) + ".bin", dst, vb); });
        be_->write_chunk(Chunk::kLink, uint32_t(s), g, 0, lb, [&](uint8_t *dst) { read_file(b + "-l" + std::to_string(g) + ".bin", dst, lb); });
      }
      GraphMeta &m = h_->segs[s].meta;
      m.upper_cur = ucur;
      m.ep_level = epl;
      store_release(&m.count, count);
      total += count;
      seen++;
    }
    if (seen != p_.segments) die("segments.txt lists " + std::to_string(seen) + " segments");
    std::fprintf(stderr, "vdb-server: %s %lu initial records in %u segments (%.1f s)\n",
                 o_.preloaded ? "published preloaded" : "loaded", (unsigned long)total, seen, (now_ns() - t0) / 1e9);
  }

 public:
  // --preload-only (plain backend, node 0): copy the initial chunk images into SWcc through a plain mapping, then
  // unmap and return. Touches no HWcc (no app_init, no meta); run before Popcorn enables coherence.
  void preload() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (o_.init_dir.empty()) die("--preload-only needs --init-dir");
    if (o_.node != 0) die("--preload-only runs on node 0 only");
    {  // same parameter check as load_initial: refuse an init dir built for other parameters before writing anything
      std::ifstream man(o_.init_dir + "/manifest.txt");
      std::string line, want = "graph " + std::to_string(p_.segments) + " " + std::to_string(p_.g.dim) + " " +
                               std::to_string(p_.g.M) + " " + std::to_string(p_.g.ef_construction) + " " +
                               std::to_string(p_.g.capacity) + " " + std::to_string(p_.g.chunk_bytes);
      bool ok = false;
      while (std::getline(man, line)) ok = ok || line == want;
      if (!ok) die("init_dir manifest does not contain '" + want + "' (built for other parameters)");
    }
    int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    map_ = static_cast<uint8_t *>(m);
    be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    const uint64_t t0 = now_ns();
    std::ifstream f(o_.init_dir + "/segments.txt");
    uint64_t s, count, epl, ucur, total = 0, bytes = 0;
    while (f >> s >> count >> epl >> ucur) {
      if (s >= p_.segments || count > p_.g.capacity) die("bad segments.txt");
      const uint64_t N = p_.g.per_chunk();
      for (uint64_t g = 0; g * N < count; g++) {
        const std::string b = o_.init_dir + "/seg-" + std::to_string(s);
        const uint64_t vb = std::min(N, count - g * N) * p_.g.vrec_bytes(), lb = p_.g.lchunk_bytes();
        be_->write_chunk(Chunk::kVec, uint32_t(s), g, 0, vb, [&](uint8_t *dst) { read_file(b + "-v" + std::to_string(g) + ".bin", dst, vb); });
        be_->write_chunk(Chunk::kLink, uint32_t(s), g, 0, lb, [&](uint8_t *dst) { read_file(b + "-l" + std::to_string(g) + ".bin", dst, lb); });
        bytes += vb + lb;
      }
      total += count;
    }
    if (munmap(m, r_.device_size) != 0) die("munmap");
    close(fd);
    std::fprintf(stderr, "vdb-server: PRELOAD DONE %lu records, %lu MiB in %.1f s (plain mapping, no HWcc access)\n",
                 (unsigned long)total, (unsigned long)(bytes >> 20), (now_ns() - t0) / 1e9);
  }

 private:

  // Read every byte of the populated chunks once (every node, before READY; identical in every system), so that
  // measurements do not include the first touch of shared pages (page faults / nested-paging fills).
  // Megalon: every node first checks every object (ids and sizes; node 0 created them before publishing `loaded`),
  // and the warm-up reads go through read sections.
  void warm_up() {
    const uint64_t t0 = now_ns();
    std::string err;
    if (!be_->check_objects(&err)) die(err);
    uint64_t bytes = 0, sum = 0;
    for (uint32_t s = 0; s < p_.segments; s++) {
      const uint64_t n = load_acquire(&h_->segs[s].meta.count), N = p_.g.per_chunk();
      for (uint64_t g = 0; g * N < n; g++) {
        const uint64_t vb = std::min(N, n - g * N) * p_.g.vrec_bytes();
        for (Chunk k : {Chunk::kVec, Chunk::kLink}) {
          const uint64_t len = k == Chunk::kVec ? vb : p_.g.lchunk_bytes();
          sum += be_->read_chunk(k, s, g, 0, len, [&](const uint8_t *c) {
            uint64_t x = 0;
            for (uint64_t o = 0; o < len; o += 64) x += c[o];
            return x;
          });
          bytes += len;
        }
      }
    }
    std::fprintf(stderr, "vdb-server: warm-up read %lu MiB in %.1f s (%lu)\n", (unsigned long)(bytes >> 20),
                 (now_ns() - t0) / 1e9, (unsigned long)(sum & 1));
  }

  static void read_file(const std::string &path, uint8_t *dst, uint64_t n) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f || uint64_t(f.tellg()) != n) die(path + ": missing or size != " + std::to_string(n));
    f.seekg(0);
    f.read(reinterpret_cast<char *>(dst), std::streamsize(n));
    if (!f) die("short read " + path);
  }

  // ---------------------------------------------------------------- writer (this node's writes, arrival order)
  void writer() {
    be_->thread_init(1);
    for (;;) {
      Job j = wq_.pop();
      const uint32_t n = frame::payload_len(j.h);
      if (j.h.code == kOpInsert && n == sizeof(InsertReq) + p_.g.dim * 4) {
        InsertReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (rq.id >= p_.max_ids || rq.w_seq == 0 || rq.w_seq > p_.max_writes) { bad(j); continue; }
        const uint64_t t0 = now_ns();
        SegLines &sl = h_->segs[p_.seg_of(rq.id)];
        cxl::hwcc::write_lock(&sl.lock);
        const uint64_t t1 = now_ns();
        try {
          g_[p_.seg_of(rq.id)]->insert(rq.id, rq.w_seq, reinterpret_cast<const float *>(j.p.data() + sizeof(rq)), rng_);
        } catch (const std::exception &e) {  // never leave the cross-VM write lock held (peers would spin)
          cxl::hwcc::write_unlock(&sl.lock);
          die(std::string("insert: ") + e.what());
        }
        cxl::hwcc::write_unlock(&sl.lock);
        st_.insert_lock_ns += t1 - t0;
        st_.insert_ns += now_ns() - t0;
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

  void do_delete(uint32_t w, uint64_t id) {
    const uint64_t e = dlog_next_++;
    if (e >= p_.max_deletes) die("max_deletes reached");
    DlogEntry de{};
    de.id = id;
    de.del_seq = w;
    de.check = uint32_t(id) ^ uint32_t(id >> 32) ^ w ^ kDlogMagic;
    be_->dlog_write(o_.node, e, de);  // whole line
    store_release(&h_->nodes[o_.node].dlog_count, e + 1);
  }

  // applied[w] then advance P over contiguous set bits (every node's writer races through CAS)
  void finish_write(Job &j, uint32_t w) {
    fetch_or(&h_->applied[w >> 6], uint64_t(1) << (w & 63));
    uint64_t p = load_acquire(h_->P);
    for (;;) {
      uint64_t q = p;
      while (q + 1 <= p_.max_writes && (load_acquire(&h_->applied[(q + 1) >> 6]) >> ((q + 1) & 63) & 1)) q++;
      if (q == p || cxl::hwcc::cas(h_->P, &p, q)) break;
    }
    h_->nodes[o_.node].writes_applied++;
    WriteResp r{w, uint32_t(load_acquire(h_->P))};
    j.c->reply(frame::kStatusOk, j.h.req_id, &r, sizeof(r));
  }

  // ---------------------------------------------------------------- reader side
  // Replay node u's delete log up to `upto` entries into del_seq_ (one cursor per log, under dmu_[u]).
  void replay(uint32_t u, uint64_t upto) {
    std::lock_guard<std::mutex> g(dmu_[u]);
    be_->dlog_scan(u, dcursor_[u], upto, [&](const DlogEntry &d) {
      if (d.check != (uint32_t(d.id) ^ uint32_t(d.id >> 32) ^ d.del_seq ^ kDlogMagic) || d.id >= p_.max_ids) {
        st_.bad_records++;
        return;
      }
      if (d.del_seq < del_seq_[d.id]) __atomic_store_n(&del_seq_[d.id], d.del_seq, __ATOMIC_RELAXED);
    });
    if (upto > dcursor_[u]) __atomic_store_n(&dcursor_[u], upto, __ATOMIC_RELEASE);
  }

  // Search scheduling: one pool of workers; a query's segment searches are spread over idle workers (intra-query
  // parallelism, as vector databases search the segments of one request in parallel). The worker that starts a
  // query waits for E1 readiness and replays deletes, then publishes S segment tasks; any worker claims segments
  // with fetch_add; whoever completes the last segment merges and replies.
  struct QueryCtx {
    Job job;
    const float *q = nullptr;
    uint32_t k = 0, s = 0;
    uint64_t t0 = 0, t1 = 0, t2 = 0;
    std::atomic<uint32_t> next{0}, done{0};
    std::atomic<uint32_t> refs{0};  // task entries + the owner; freed when the last one is released
    std::atomic<uint64_t> lock_ns{0}, dists{0};
    std::mutex mu;
    std::vector<std::pair<float, uint64_t>> all;
  };

  void push_search(Job j) {
    {
      std::lock_guard<std::mutex> g(smu_);
      queries_.push_back(std::move(j));
    }
    scv_.notify_one();
  }

  void searcher(int tid) {
    be_->thread_init(tid);
    for (;;) {
      QueryCtx *task = nullptr;
      Job job;
      {
        std::unique_lock<std::mutex> l(smu_);
        scv_.wait(l, [&] { return !tasks_.empty() || !queries_.empty(); });
        if (!tasks_.empty()) {  // help running queries first
          task = tasks_.front();
          tasks_.pop_front();
        } else {
          job = std::move(queries_.front());
          queries_.pop_front();
        }
      }
      if (task) {
        run_segment(task);
        release(task);
        continue;
      }
      QueryCtx *c = start_query(std::move(job));
      if (!c) continue;
      c->refs.store(p_.segments);  // S - 1 task entries + this owner
      {
        std::lock_guard<std::mutex> g(smu_);
        for (uint32_t x = 1; x < p_.segments; x++) tasks_.push_back(c);
      }
      scv_.notify_all();
      while (run_segment(c)) {
      }
      release(c);
    }
  }

  QueryCtx *start_query(Job j) {
    if (frame::payload_len(j.h) != sizeof(SearchReq) + p_.g.dim * 4) {
      bad(j);
      return nullptr;
    }
    SearchReq rq;
    std::memcpy(&rq, j.p.data(), sizeof(rq));
    auto *c = new QueryCtx;
    c->k = std::min<uint32_t>(std::max<uint32_t>(rq.k, 1), 1024);
    c->s = rq.ref_w;
    c->t0 = now_ns();
    // E1 readiness: P >= s (every write <= s applied by its writer)
    if (!cxl::hwcc::poll_until([&] { return load_acquire(h_->P) >= c->s; }, o_.wait_timeout_ms)) {
      st_.timeouts++;
      j.c->reply(frame::kStatusTimeout, j.h.req_id, nullptr, 0);
      delete c;
      return nullptr;
    }
    c->t1 = now_ns();
    for (uint32_t u = 0; u < p_.nr_nodes; u++) {
      uint64_t n = load_acquire(&h_->nodes[u].dlog_count);
      if (__atomic_load_n(&dcursor_[u], __ATOMIC_ACQUIRE) < n) replay(u, n);
    }
    c->t2 = now_ns();
    c->job = std::move(j);
    c->q = reinterpret_cast<const float *>(c->job.p.data() + sizeof(SearchReq));
    return c;
  }

  // Claim and search one segment of c; returns false when no segment was left to claim.
  bool run_segment(QueryCtx *c) {
    const uint32_t sg = c->next.fetch_add(1);
    if (sg >= p_.segments) return false;
    thread_local std::vector<uint16_t> visited;
    thread_local uint16_t tag = 0;
    thread_local std::vector<std::pair<float, uint32_t>> part;
    if (visited.size() < p_.g.capacity) visited.assign(p_.g.capacity, 0);
    SegLines &sl = h_->segs[sg];
    const uint64_t l0 = now_ns();
    cxl::hwcc::read_lock(&sl.lock);
    c->lock_ns += now_ns() - l0;
    const Graph &g = *g_[sg];
    const uint32_t s = c->s;
    auto allowed = [&](uint32_t i) {
      ElemHeader tmp;
      const ElemHeader &h = g.header(i, tmp);
      return h.ins_seq <= s && __atomic_load_n(&del_seq_[h.ext_id], __ATOMIC_RELAXED) > s;
    };
    uint64_t nd = 0;
    g.search(c->q, c->k, o_.ef, allowed, &part, visited, tag, &nd);
    std::vector<std::pair<float, uint64_t>> mine;
    for (auto &pr : part) {
      ElemHeader tmp;
      mine.emplace_back(pr.first, g.header(pr.second, tmp).ext_id);
    }
    cxl::hwcc::read_unlock(&sl.lock);
    c->dists += nd;
    {
      std::lock_guard<std::mutex> lg(c->mu);
      c->all.insert(c->all.end(), mine.begin(), mine.end());
    }
    if (c->done.fetch_add(1) + 1 == p_.segments) finish_query(c);
    return true;
  }

  void finish_query(QueryCtx *c) {
    const uint64_t t3 = now_ns();
    auto &all = c->all;
    std::sort(all.begin(), all.end());
    if (all.size() > c->k) all.resize(c->k);
    SearchResp resp{};
    resp.s_used = c->s;
    resp.n = uint16_t(all.size());
    resp.wait_us = uint32_t((c->t1 - c->t0) / 1000);
    resp.replay_us = uint32_t((c->t2 - c->t1) / 1000);
    resp.search_us = uint32_t((t3 - c->t2) / 1000);
    resp.lock_us = uint32_t(c->lock_ns.load() / 1000);
    resp.dists = uint32_t(c->dists.load());
    resp.segs = uint16_t(p_.segments);
    std::vector<uint8_t> out(sizeof(resp) + all.size() * 12);
    std::memcpy(out.data(), &resp, sizeof(resp));
    for (size_t x = 0; x < all.size(); x++) {
      const float score = -all[x].first;  // inner product
      std::memcpy(out.data() + sizeof(resp) + x * 8, &all[x].second, 8);
      std::memcpy(out.data() + sizeof(resp) + all.size() * 8 + x * 4, &score, 4);
    }
    c->job.c->reply(frame::kStatusOk, c->job.h.req_id, out.data(), uint32_t(out.size()));
    st_.searches++;
    st_.dists += c->dists.load();
    st_.wait_ns += c->t1 - c->t0;
    st_.replay_ns += c->t2 - c->t1;
    st_.search_ns += t3 - c->t2;
    st_.lock_ns += c->lock_ns.load();
  }

  size_t search_queue_len() {
    std::lock_guard<std::mutex> g(smu_);
    return queries_.size();
  }

  // Unclaimed task entries may outlive the reply; they only fetch_add `next` (>= S) and return. The context is
  // deleted when the owner and every task entry have released it.
  void release(QueryCtx *c) {
    if (c->refs.fetch_sub(1) == 1) delete c;
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
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpInsert:
        case kOpDelete: wq_.push(std::move(j)); break;
        case kOpSearch: push_search(std::move(j)); break;
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
  const MegalonApi *api_ = nullptr;
  std::unique_ptr<Be> be_;
  std::vector<std::unique_ptr<Graph>> g_;
  Stats st_;
  Queue wq_;
  std::mutex smu_;  // search scheduling
  std::condition_variable scv_;
  std::deque<Job> queries_;
  std::deque<QueryCtx *> tasks_;
  uint64_t dlog_next_ = 0;  // writer
  std::mt19937_64 rng_;     // writer: HNSW levels
  std::unique_ptr<uint32_t[]> del_seq_;
  std::vector<uint64_t> dcursor_;
  std::unique_ptr<std::mutex[]> dmu_;
};

volatile sig_atomic_t g_stop = 0;

template <class Be>
int run(const Opts &o) {
  Server<Be> s(o);
  if constexpr (std::is_same_v<Be, PlainBackend>) {
    if (o.preload_only) {
      s.preload();
      std::fflush(stderr);
      std::_Exit(0);
    }
  }
  s.start();
  while (!g_stop) usleep(200000);
  std::fprintf(stderr, "vdb-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);
}

void usage() {
  std::fprintf(stderr,
               "usage: vdb-server --node K --nodes N --run-id 0x.. [--port P] [--region yaml] [--init-dir DIR]\n"
               "  [--segments S] [--search-threads N] [--ef E] [--seed N]\n"
               "  [--dim D] [--M M] [--efc E] [--chunk-bytes B (32 MiB)] [--max-writes W] [--max-ids N] [--dlog-chunk E] [--max-deletes D]\n"
               "  [--wait-timeout-ms T] [--start-timeout-ms T] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "  [--preload-only | --preloaded]   Popcorn init_state=shared: node 0 writes the initial chunks before enable\n"
               "--backend megalon: Megalon (RACKOBJ_CONFIG, object_arena_size > 0) maps the device; MEGALON_NODE_ID and\n"
               "  MEGALON_RUN_ID default to --node and --run-id, CXL_REGION_CONFIG to --region (DESIGN.md §12).\n"
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
    else if (a == "--segments") o.p.segments = std::stoul(v());
    else if (a == "--search-threads") o.search_threads = std::stoul(v());
    else if (a == "--ef") o.ef = std::stoul(v());
    else if (a == "--seed") o.seed = std::stoull(v());
    else if (a == "--dim") o.p.g.dim = std::stoul(v());
    else if (a == "--M") o.p.g.M = std::stoul(v());
    else if (a == "--efc") o.p.g.ef_construction = std::stoul(v());
    else if (a == "--chunk-bytes") o.p.g.chunk_bytes = std::stoull(v());
    else if (a == "--max-writes") o.p.max_writes = std::stoull(v());
    else if (a == "--max-ids") o.p.max_ids = std::stoull(v());
    else if (a == "--dlog-chunk") o.p.dlog_chunk = std::stoul(v());
    else if (a == "--max-deletes") o.p.max_deletes = std::stoull(v());
    else if (a == "--wait-timeout-ms") o.wait_timeout_ms = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.megalon_lib = v();
    else if (a == "--print-app-bytes") print_bytes = true;
    else if (a == "--preload-only") o.preload_only = true;
    else if (a == "--preloaded") o.preloaded = true;
    else usage();
  }
  o.p.derive();
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.p).L.bytes());
    return 0;
  }
  if (o.run_id == 0 && !o.preload_only) usage();
  if ((o.preload_only || o.preloaded) && o.backend != "plain") {
    std::fprintf(stderr, "vdb-server: --preload-only/--preloaded are for the plain backend (Popcorn init_state=shared)\n");
    return 2;
  }
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  if (o.backend == "plain") return run<PlainBackend>(o);
  if (o.backend != "megalon") usage();
  // Megalon reads its node id, run id and region config from the environment when its library initialises.
  auto env = [](const char *k, const std::string &v) {
    const char *cur = getenv(k);
    if (cur && *cur && v != cur) {
      std::fprintf(stderr, "vdb-server: %s=%s contradicts the server option (%s)\n", k, cur, v.c_str());
      std::exit(2);
    }
    setenv(k, v.c_str(), 1);
  };
  env("MEGALON_NODE_ID", std::to_string(o.node));
  if (!getenv("MEGALON_RUN_ID") || !*getenv("MEGALON_RUN_ID")) setenv("MEGALON_RUN_ID", std::to_string(o.run_id).c_str(), 1);
  else if (std::stoull(getenv("MEGALON_RUN_ID"), nullptr, 0) != o.run_id) env("MEGALON_RUN_ID", std::to_string(o.run_id));
  if (!o.region.empty()) env("CXL_REGION_CONFIG", o.region);
  if (o.megalon_lib.empty()) {
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) usage();
    exe[n] = 0;
    std::string d(exe);
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libvdb-megalon.so";
  }
  return run<MegalonBackend>(o);
}

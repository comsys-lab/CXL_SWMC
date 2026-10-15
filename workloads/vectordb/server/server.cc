// vectordb server, one process per VM (DESIGN.md §11). Speaks experiments/loadgen/frame.h with
// workloads/vectordb/proto.h. Data: `segments` HNSW graphs (shm_hnsw.h) shared by all nodes in CXL memory; record id
// -> segment id % segments; every node inserts into every segment under the segment's HWcc write lock, searches take
// the read lock (Qdrant-style). Threads: one reader per connection, one writer (this node's writes in arrival
// order), N search workers.
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
#include <vector>

#include "backend.h"
#include "frame.h"
#include "layout.h"
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
  std::string region;    // region config (default $CXL_REGION_CONFIG)
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

class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), p_(o_.p) {}

  void start() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || o_.node >= p_.nr_nodes || p_.segments == 0) die("bad node/nodes/segments");
    HwccLayout lay(p_);
    int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    map_ = static_cast<uint8_t *>(m);
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay);
    be_ = std::make_unique<PlainBackend>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    for (uint32_t s = 0; s < p_.segments; s++)
      g_.push_back(std::make_unique<ShmHnsw>(p_.g, ShmHnsw::Mem{&h_->segs[s].meta, be_->level0(s), be_->upper(s)}));
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
    std::thread([this] { writer(); }).detach();
    for (uint32_t i = 0; i < o_.search_threads; i++) std::thread([this] { searcher(); }).detach();
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
      << "\nsearch_queue=" << sq_.size();
    for (uint32_t v = 0; v < p_.nr_nodes; v++) o << "\ndlog_count." << v << "=" << load_acquire(&h_->nodes[v].dlog_count);
    o << "\nbackend=" << be_->usage() << "\n";
    return o.str();
  }

 private:
  // ---------------------------------------------------------------- initial segments (prepare, node 0, unmeasured)
  // init_dir: segments.txt ("<s> <count> <ep_level> <upper_cur>"), seg-<s>.level0, seg-<s>.upper, manifest.txt with
  // the graph parameters; images are copied into SWcc as is (same layout, offsets inside the segment).
  void load_initial() {
    for (uint32_t s = 0; s < p_.segments; s++) ShmHnsw::init_empty(&h_->segs[s].meta);
    if (o_.init_dir.empty()) return;
    const uint64_t t0 = now_ns();
    std::ifstream man(o_.init_dir + "/manifest.txt");
    std::string line, want = "graph " + std::to_string(p_.segments) + " " + std::to_string(p_.g.dim) + " " +
                             std::to_string(p_.g.M) + " " + std::to_string(p_.g.ef_construction) + " " +
                             std::to_string(p_.g.capacity);
    bool ok = false;
    while (std::getline(man, line)) ok = ok || line == want;
    if (!ok) die("init_dir manifest does not contain '" + want + "' (built for other parameters)");
    std::ifstream f(o_.init_dir + "/segments.txt");
    uint64_t s, count, epl, ucur, total = 0;
    uint32_t seen = 0;
    while (f >> s >> count >> epl >> ucur) {
      if (s >= p_.segments || count > p_.g.capacity || ucur > p_.g.upper_arena_bytes()) die("bad segments.txt");
      read_file(o_.init_dir + "/seg-" + std::to_string(s) + ".level0", be_->level0(uint32_t(s)), count * p_.g.slot_bytes());
      read_file(o_.init_dir + "/seg-" + std::to_string(s) + ".upper", be_->upper(uint32_t(s)), ucur);
      GraphMeta &m = h_->segs[s].meta;
      m.upper_cur = ucur;
      m.ep_level = epl;
      store_release(&m.count, count);
      total += count;
      seen++;
    }
    if (seen != p_.segments) die("segments.txt lists " + std::to_string(seen) + " segments");
    std::fprintf(stderr, "vdb-server: loaded %lu initial records in %u segments (%.1f s)\n", (unsigned long)total, seen,
                 (now_ns() - t0) / 1e9);
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
        g_[p_.seg_of(rq.id)]->insert(rq.id, rq.w_seq, reinterpret_cast<const float *>(j.p.data() + sizeof(rq)), rng_);
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
    std::memcpy(be_->dlog(o_.node) + e, &de, sizeof(de));  // whole line
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
    const DlogEntry *log = be_->dlog(u);
    for (uint64_t e = dcursor_[u]; e < upto; e++) {
      DlogEntry d;
      std::memcpy(&d, log + e, sizeof(d));
      if (d.check != (uint32_t(d.id) ^ uint32_t(d.id >> 32) ^ d.del_seq ^ kDlogMagic) || d.id >= p_.max_ids) {
        st_.bad_records++;
        continue;
      }
      if (d.del_seq < del_seq_[d.id]) __atomic_store_n(&del_seq_[d.id], d.del_seq, __ATOMIC_RELAXED);
    }
    if (upto > dcursor_[u]) __atomic_store_n(&dcursor_[u], upto, __ATOMIC_RELEASE);
  }

  void searcher() {
    std::vector<uint16_t> visited(p_.g.capacity, 0);
    uint16_t tag = 0;
    std::vector<std::pair<float, uint32_t>> part;
    std::vector<std::pair<float, uint64_t>> all;
    std::vector<uint8_t> out;
    for (;;) {
      Job j = sq_.pop();
      if (frame::payload_len(j.h) != sizeof(SearchReq) + p_.g.dim * 4) { bad(j); continue; }
      SearchReq rq;
      std::memcpy(&rq, j.p.data(), sizeof(rq));
      const float *q = reinterpret_cast<const float *>(j.p.data() + sizeof(rq));
      const uint32_t k = std::min<uint32_t>(std::max<uint32_t>(rq.k, 1), 1024);
      const uint32_t s = rq.ref_w;
      SearchResp resp{};
      resp.s_used = s;
      // E1 readiness: P >= s (every write <= s applied by its writer)
      const uint64_t t0 = now_ns();
      if (!cxl::hwcc::poll_until([&] { return load_acquire(h_->P) >= s; }, o_.wait_timeout_ms)) {
        st_.timeouts++;
        j.c->reply(frame::kStatusTimeout, j.h.req_id, nullptr, 0);
        continue;
      }
      const uint64_t t1 = now_ns();
      for (uint32_t u = 0; u < p_.nr_nodes; u++) {
        uint64_t c = load_acquire(&h_->nodes[u].dlog_count);
        if (__atomic_load_n(&dcursor_[u], __ATOMIC_ACQUIRE) < c) replay(u, c);
      }
      const uint64_t t2 = now_ns();
      all.clear();
      uint64_t lock_ns = 0, nd = 0;
      for (uint32_t sg = 0; sg < p_.segments; sg++) {
        SegLines &sl = h_->segs[sg];
        const uint64_t l0 = now_ns();
        cxl::hwcc::read_lock(&sl.lock);
        lock_ns += now_ns() - l0;
        const ShmHnsw &g = *g_[sg];
        auto allowed = [&](uint32_t i) {
          const ElemHeader &h = g.header(i);
          return h.ins_seq <= s && __atomic_load_n(&del_seq_[h.ext_id], __ATOMIC_RELAXED) > s;
        };
        g.search(q, k, o_.ef, allowed, &part, visited, tag, &nd);
        for (auto &pr : part) all.emplace_back(pr.first, g.header(pr.second).ext_id);
        cxl::hwcc::read_unlock(&sl.lock);
      }
      const uint64_t t3 = now_ns();
      std::sort(all.begin(), all.end());
      if (all.size() > k) all.resize(k);
      resp.n = uint16_t(all.size());
      resp.wait_us = uint32_t((t1 - t0) / 1000);
      resp.replay_us = uint32_t((t2 - t1) / 1000);
      resp.search_us = uint32_t((t3 - t2) / 1000);
      resp.lock_us = uint32_t(lock_ns / 1000);
      resp.dists = uint32_t(nd);
      resp.segs = uint16_t(p_.segments);
      out.resize(sizeof(resp) + all.size() * 12);
      std::memcpy(out.data(), &resp, sizeof(resp));
      for (size_t x = 0; x < all.size(); x++) {
        const float score = -all[x].first;  // inner product
        std::memcpy(out.data() + sizeof(resp) + x * 8, &all[x].second, 8);
        std::memcpy(out.data() + sizeof(resp) + all.size() * 8 + x * 4, &score, 4);
      }
      j.c->reply(frame::kStatusOk, j.h.req_id, out.data(), uint32_t(out.size()));
      st_.searches++;
      st_.dists += nd;
      st_.wait_ns += t1 - t0;
      st_.replay_ns += t2 - t1;
      st_.search_ns += t3 - t2;
      st_.lock_ns += lock_ns;
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
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
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
  std::unique_ptr<PlainBackend> be_;
  std::vector<std::unique_ptr<ShmHnsw>> g_;
  Stats st_;
  Queue wq_, sq_;
  uint64_t dlog_next_ = 0;  // writer
  std::mt19937_64 rng_;     // writer: HNSW levels
  std::unique_ptr<uint32_t[]> del_seq_;
  std::vector<uint64_t> dcursor_;
  std::unique_ptr<std::mutex[]> dmu_;
};

volatile sig_atomic_t g_stop = 0;

void usage() {
  std::fprintf(stderr,
               "usage: vdb-server --node K --nodes N --run-id 0x.. [--port P] [--region yaml] [--init-dir DIR]\n"
               "  [--segments S] [--search-threads N] [--ef E] [--seed N]\n"
               "  [--dim D] [--M M] [--efc E] [--max-writes W] [--max-ids N] [--dlog-chunk E] [--max-deletes D]\n"
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
    else if (a == "--segments") o.p.segments = std::stoul(v());
    else if (a == "--search-threads") o.search_threads = std::stoul(v());
    else if (a == "--ef") o.ef = std::stoul(v());
    else if (a == "--seed") o.seed = std::stoull(v());
    else if (a == "--dim") o.p.g.dim = std::stoul(v());
    else if (a == "--M") o.p.g.M = std::stoul(v());
    else if (a == "--efc") o.p.g.ef_construction = std::stoul(v());
    else if (a == "--max-writes") o.p.max_writes = std::stoull(v());
    else if (a == "--max-ids") o.p.max_ids = std::stoull(v());
    else if (a == "--dlog-chunk") o.p.dlog_chunk = std::stoul(v());
    else if (a == "--max-deletes") o.p.max_deletes = std::stoull(v());
    else if (a == "--wait-timeout-ms") o.wait_timeout_ms = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--print-app-bytes") print_bytes = true;
    else usage();
  }
  o.p.derive();
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

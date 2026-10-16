// lmdb-server, one process per VM (workloads/lmdb/DESIGN.md). A key-value server over one LMDB B+tree shared by all
// nodes in CXL memory (liblmdb 0.9.70 + lmdb_cxl.h: pages in SWcc, lock-file state in the HWcc app range). Speaks
// experiments/loadgen/frame.h with workloads/lmdb/proto.h.
//   get    = one read-only txn (renew, mdb_get, copy the value into the reply, reset), on a get worker
//   update = one write txn overwriting an existing key (begin = cross-node writer lock, mdb_put, commit), on this
//            node's single writer thread in arrival order
// Threads: listen, one reader per connection, --get-threads get workers (reader slots 0..n-1 of this node), one
// writer. Backend (--backend plain|megalon): Server<Backend> is compiled once per backend.
// Per-operation split (MOT1 v6 Fig 2; workloads/kv/server/opsplit.h): every get / update is one operation, T = rdtsc
// from the start of its transaction (after request validation) to the end of its thread's work on it (get: renew ..
// reply .. reset; update: txn_begin incl. the cross-node writer-lock wait .. commit .. reply), C = the thread's
// coherence time inside it (Popcorn swmc_acct for --backend plain, Megalon thread_coh for --backend megalon).
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/socket.h>

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "frame.h"
#include "opsplit.h"
#include "node.h"
#include "proto.h"

using namespace lmdbw;

namespace {

struct Opts {
  NodeOpts n;
  uint32_t port = 7100, get_threads = 8;
  std::string backend = "plain";
};

struct Conn {
  int fd;
  std::mutex wmu;
  void reply(uint16_t status, uint64_t req_id, const void *a, uint32_t na, const void *b = nullptr, uint32_t nb = 0) {
    frame::header h;
    frame::fill(&h, status, req_id, na + nb);
    std::lock_guard<std::mutex> g(wmu);
    frame::write_full(fd, &h, sizeof(h));
    if (na) frame::write_full(fd, a, na);
    if (nb) frame::write_full(fd, b, nb);
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

struct alignas(64) WorkerStats {  // one per get worker (written by its thread only)
  std::atomic<uint64_t> gets{0}, not_found{0}, errors{0}, ns{0};
};
enum OpType : uint32_t { kGetOp = 0, kUpdateOp = 1 };  // opsplit operation types
struct alignas(64) WriterStats {
  std::atomic<uint64_t> updates{0}, not_found{0}, errors{0}, ns{0}, lock_ns{0}, commit_ns{0};
};

template <class Be>
class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), node_(o_.n) {}

  void start() {
    if constexpr (std::is_same_v<Be, MegalonBackend>)
      if (2 + o_.get_threads + (o_.n.prepare_threads > 1 ? o_.n.prepare_threads : 0) > 32)
        die("megalon: at most 32 thread registrations per process (NR replica: main, prepare threads, writer, get workers)");
    if (o_.get_threads == 0 || o_.get_threads > o_.n.p.readers) die("--get-threads must be 1..--readers");
    node_.start("lmdb-server");
    ws_.reset(new WorkerStats[o_.get_threads]);
    opt_.reset(new opsplit::Table({"get", "update"}, o_.get_threads + 1,
                                  std::is_same_v<Be, MegalonBackend> ? opsplit::Source::kMegalon : opsplit::Source::kPopcorn,
                                  node_.backend().api()));
    oth_.reset(new opsplit::Thread[o_.get_threads + 1]);
    std::fprintf(stderr, "lmdb-server: opsplit tsc_hz %.0f source %s megalon thread_coh %s\n", opt_->tsc_hz(),
                 opt_->source() == opsplit::Source::kMegalon ? "megalon" : "popcorn",
                 opt_->meg() ? "yes" : (std::is_same_v<Be, MegalonBackend> ? "no (v1 shim: C = 0)" : "n/a"));
    std::thread([this] { writer(); }).detach();
    for (uint32_t i = 0; i < o_.get_threads; i++) std::thread([this, i] { getter(i); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  std::string stats_text() {
    std::ostringstream o;
    uint64_t gets = 0, gnf = 0, gerr = 0, gns = 0;
    for (uint32_t i = 0; i < o_.get_threads; i++) {
      gets += ws_[i].gets.load(), gnf += ws_[i].not_found.load(), gerr += ws_[i].errors.load(), gns += ws_[i].ns.load();
    }
    MDB_cxl_stats cs{};
    mdb_cxl_get_stats(node_.env(), &cs);
    uint64_t t, lp, dbs[12];
    mdb_cxl_meta_get(&node_.hwcc().conf, &t, &lp, dbs);
    MDB_envinfo ei;
    mdb_env_info(node_.env(), &ei);
    o << "node=" << o_.n.node << "\nbackend=" << node_.backend().name() << "\ncommitted_txnid=" << t
      << "\nlast_pg=" << lp << "\ngets=" << gets << "\nget_not_found=" << gnf << "\nget_errors=" << gerr
      << "\nget_ns=" << gns << "\nupdates=" << wst_.updates.load() << "\nupdate_not_found=" << wst_.not_found.load()
      << "\nupdate_errors=" << wst_.errors.load() << "\nupdate_ns=" << wst_.ns.load()
      << "\nupdate_lock_ns=" << wst_.lock_ns.load() << "\nupdate_commit_ns=" << wst_.commit_ns.load()
      << "\nlmdb.page_writes=" << cs.page_writes << "\nlmdb.wlock_wait_ns=" << cs.wlock_wait_ns
      << "\nlmdb.wlock_acquires=" << cs.wlock_acquires << "\nlmdb.reader_retries=" << cs.reader_retries
      << "\nlmdb.oldest_scans=" << cs.oldest_scans << "\nlmdb.oldest_lag_max=" << cs.oldest_lag_max
      << "\nget_queue=" << gq_.size() << "\nupdate_queue=" << wq_.size() << "\n"
      << node_.backend().stats() << opt_->text() << cxl::proc::text(pst_);
    return o.str();
  }

 private:
  // ---------------------------------------------------------------- gets (read-only txns)
  void getter(uint32_t i) {
    cxl::proc::name_thread("lmdb-get");
    node_.backend().thread_init(int(2 + i));
    mdb_cxl_thread_slot(int(node_.reader_slot(i)));
    MDB_txn *txn = nullptr;
    int rc = mdb_txn_begin(node_.env(), nullptr, MDB_RDONLY, &txn);
    if (rc) die(std::string("get txn_begin: ") + mdb_strerror(rc));
    mdb_txn_reset(txn);
    WorkerStats &st = ws_[i];
    opsplit::Thread &ot = oth_[i];
    ot.init(opt_.get(), i);
    for (;;) {
      Job j = gq_.pop();
      const uint64_t t0 = now_ns();
      GetReq rq;
      if (frame::payload_len(j.h) < sizeof(rq)) { bad(j); continue; }
      std::memcpy(&rq, j.p.data(), sizeof(rq));
      if (frame::payload_len(j.h) != sizeof(rq) + rq.klen || rq.klen == 0 || rq.klen > 511) { bad(j); continue; }
      ot.begin();
      if ((rc = mdb_txn_renew(txn)) != 0) die(std::string("txn_renew: ") + mdb_strerror(rc));
      MDB_val k{rq.klen, j.p.data() + sizeof(rq)}, v{0, nullptr};
      rc = mdb_get(txn, node_.dbi(), &k, &v);
      GetResp rs{mdb_txn_id(txn), 0, 0};
      if (rc == 0) {
        rs.vlen = uint32_t(v.mv_size);
        rs.service_us = uint32_t((now_ns() - t0) / 1000);
        // the value is this txn's view (in place for plain, the txn's page copy for Megalon); valid until reset
        j.c->reply(frame::kStatusOk, j.h.req_id, &rs, sizeof(rs), v.mv_data, rs.vlen);
        mdb_txn_reset(txn);
        ot.end(kGetOp);
        st.gets.fetch_add(1, std::memory_order_relaxed);
      } else {
        mdb_txn_reset(txn);
        rs.service_us = uint32_t((now_ns() - t0) / 1000);
        if (rc == MDB_NOTFOUND) {
          st.not_found.fetch_add(1, std::memory_order_relaxed);
          j.c->reply(kStatusNotFound, j.h.req_id, &rs, sizeof(rs));
        } else {
          st.errors.fetch_add(1, std::memory_order_relaxed);
          std::fprintf(stderr, "lmdb-server: get: %s\n", mdb_strerror(rc));
          j.c->reply(frame::kStatusServerError, j.h.req_id, nullptr, 0);
        }
        ot.end(kGetOp);
      }
      st.ns.fetch_add(now_ns() - t0, std::memory_order_relaxed);
    }
  }

  // ---------------------------------------------------------------- updates (write txns, this node's arrival order)
  void writer() {
    cxl::proc::name_thread("lmdb-writer");
    node_.backend().thread_init(1);
    opsplit::Thread &ot = oth_[o_.get_threads];
    ot.init(opt_.get(), o_.get_threads);
    MDB_cxl_stats cs{};
    for (;;) {
      Job j = wq_.pop();
      if (j.h.code == kOpVerify) {
        std::string t = verify();
        j.c->reply(frame::kStatusOk, j.h.req_id, t.data(), uint32_t(t.size()));
        continue;
      }
      const uint64_t t0 = now_ns();
      UpdateReq rq;
      if (frame::payload_len(j.h) < sizeof(rq)) { bad(j); continue; }
      std::memcpy(&rq, j.p.data(), sizeof(rq));
      if (frame::payload_len(j.h) != sizeof(rq) + rq.klen + rq.vlen || rq.klen == 0 || rq.klen > 511) { bad(j); continue; }
      mdb_cxl_get_stats(node_.env(), &cs);
      const uint64_t lock0 = cs.wlock_wait_ns;
      ot.begin();
      MDB_txn *txn;
      int rc = mdb_txn_begin(node_.env(), nullptr, 0, &txn);  // takes the cross-node writer lock
      if (rc) die(std::string("write txn_begin: ") + mdb_strerror(rc));
      mdb_cxl_get_stats(node_.env(), &cs);
      const uint64_t lock_ns = cs.wlock_wait_ns - lock0;
      MDB_stat before, after;
      mdb_stat(txn, node_.dbi(), &before);
      MDB_val k{rq.klen, j.p.data() + sizeof(rq)}, v{rq.vlen, j.p.data() + sizeof(rq) + rq.klen};
      rc = mdb_put(txn, node_.dbi(), &k, &v, 0);
      if (rc == 0) mdb_stat(txn, node_.dbi(), &after);
      UpdateResp rs{mdb_txn_id(txn), uint32_t(lock_ns / 1000), 0};
      if (rc == 0 && after.ms_entries != before.ms_entries) {  // the key did not exist: not an update
        mdb_txn_abort(txn);
        wst_.not_found.fetch_add(1, std::memory_order_relaxed);
        rs.service_us = uint32_t((now_ns() - t0) / 1000);
        j.c->reply(kStatusNotFound, j.h.req_id, &rs, sizeof(rs));
        ot.end(kUpdateOp);
        continue;
      }
      const uint64_t c0 = now_ns();
      if (rc == 0) rc = mdb_txn_commit(txn);  // pages -> meta slot -> committed -> unlock
      else mdb_txn_abort(txn);
      wst_.commit_ns.fetch_add(now_ns() - c0, std::memory_order_relaxed);
      wst_.lock_ns.fetch_add(lock_ns, std::memory_order_relaxed);
      rs.service_us = uint32_t((now_ns() - t0) / 1000);
      if (rc) {
        wst_.errors.fetch_add(1, std::memory_order_relaxed);
        std::fprintf(stderr, "lmdb-server: update: %s\n", mdb_strerror(rc));
        j.c->reply(frame::kStatusServerError, j.h.req_id, nullptr, 0);
        if (rc == MDB_MAP_FULL) die("MDB_MAP_FULL: --max-pages too small for the copy-on-write working set");
      } else {
        wst_.updates.fetch_add(1, std::memory_order_relaxed);
        node_.hwcc().nodes[o_.n.node].updates++;
        j.c->reply(frame::kStatusOk, j.h.req_id, &rs, sizeof(rs));
      }
      ot.end(kUpdateOp, rc == 0 ? rq.vlen : 0);
      wst_.ns.fetch_add(now_ns() - t0, std::memory_order_relaxed);
    }
  }

  // ---------------------------------------------------------------- verify: scan the latest snapshot
  // Runs on the writer thread (queued behind earlier updates) with this node's last reader slot
  // (--readers must exceed --get-threads).
  std::string verify() {
    if (o_.n.p.readers <= o_.get_threads) return "verify.error=needs --readers > --get-threads\n";
    mdb_cxl_thread_slot(int(node_.reader_slot(o_.n.p.readers - 1)));
    const uint64_t t0 = now_ns();
    MDB_txn *txn;
    MDB_cursor *c;
    uint64_t n = 0, bad = 0, misorder = 0, max_version = 0, prev = 0;
    int rc = mdb_txn_begin(node_.env(), nullptr, MDB_RDONLY, &txn);
    if (rc) return std::string("verify.error=") + mdb_strerror(rc) + "\n";
    MDB_stat st;
    mdb_stat(txn, node_.dbi(), &st);
    mdb_cursor_open(txn, node_.dbi(), &c);
    MDB_val k, v;
    for (rc = mdb_cursor_get(c, &k, &v, MDB_FIRST); rc == 0; rc = mdb_cursor_get(c, &k, &v, MDB_NEXT)) {
      uint64_t i = 0;
      ValHdr h;
      if (!parse_key(k.mv_data, uint32_t(k.mv_size), &i) || !check_value(i, static_cast<uint8_t *>(v.mv_data), uint32_t(v.mv_size), &h))
        bad++;
      else if (h.version > max_version) max_version = h.version;
      if (n && i <= prev) misorder++;
      prev = i;
      n++;
    }
    const uint64_t txnid = mdb_txn_id(txn);
    mdb_cursor_close(c);
    mdb_txn_abort(txn);
    mdb_cxl_thread_slot(-1);
    std::ostringstream o;
    o << "verify.txnid=" << txnid << "\nverify.entries=" << n << "\nverify.stat_entries=" << st.ms_entries
      << "\nverify.depth=" << st.ms_depth << "\nverify.leaf_pages=" << st.ms_leaf_pages
      << "\nverify.branch_pages=" << st.ms_branch_pages << "\nverify.bad_values=" << bad
      << "\nverify.misordered=" << misorder << "\nverify.max_version=" << max_version
      << "\nverify.expected_entries=" << o_.n.p.records << "\nverify.end=" << (rc == MDB_NOTFOUND ? "ok" : mdb_strerror(rc))
      << "\nverify.ms=" << (now_ns() - t0) / 1000000 << "\n";
    return o.str();
  }

  void bad(Job &j) { j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0); }

  // ---------------------------------------------------------------- network
  void listen_loop() {
    cxl::proc::name_thread("lmdb-listen");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "lmdb-server: READY node %u port %u\n", o_.n.node, o_.port);
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
    cxl::proc::name_thread("lmdb-conn");
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpGet: gq_.push(std::move(j)); break;
        case kOpUpdate: wq_.push(std::move(j)); break;
        case kOpStats: {
          std::string t = stats_text();
          c->reply(frame::kStatusOk, h.req_id, t.data(), uint32_t(t.size()));
          break;
        }
        case kOpVerify: wq_.push(std::move(j)); break;
        default: c->reply(frame::kStatusUnknownOp, h.req_id, nullptr, 0);
      }
    }
    close(c->fd);
  }

  Opts o_;
  Node<Be> node_;
  std::unique_ptr<WorkerStats[]> ws_;
  WriterStats wst_;
  std::unique_ptr<opsplit::Table> opt_;
  std::unique_ptr<opsplit::Thread[]> oth_;
  Queue gq_, wq_;
  cxl::proc::Opts pst_{{"cxl_recv"},
                       {"TLB", "CAL", "RES", "LOC"},
                       {"/sys/kernel/swmc/page_coherence", "/sys/kernel/swmc/instr", "/sys/kernel/cxl_shm"}};
};

volatile sig_atomic_t g_stop = 0;

template <class Be>
int run(const Opts &o) {
  if constexpr (std::is_same_v<Be, PlainBackend>) {
    if (o.n.preload_only) {
      Node<Be> n(o.n);
      n.preload("lmdb-server");
      std::fflush(stderr);
      std::_Exit(0);
    }
  }
  Server<Be> s(o);
  s.start();
  while (!g_stop) usleep(200000);
  std::fprintf(stderr, "lmdb-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);  // no LMDB/Megalon teardown (as vdb-server); the next run re-initialises
}

void usage() {
  std::fprintf(stderr,
               "usage: lmdb-server --node K --nodes N --run-id 0x.. --max-pages P --records R [--image DIR]\n"
               "  [--port P (7100)] [--region yaml] [--get-threads N (8)] [--readers S (32, per node)]\n"
               "  [--start-timeout-ms T] [--no-warm] [--prepare-threads T (1)] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "  [--preload-only | --preloaded]   Popcorn init_state=shared: node 0 writes the image pages before enable\n"
               "  --preloaded with --backend megalon: the device already holds the image (restored snapshot, DESIGN.md §9);\n"
               "  node 0 only re-creates the page objects in pgno order and checks their placement\n"
               "All nodes need identical --nodes/--max-pages/--records/--readers (checked through the HWcc layout hash).\n"
               "CXL_APP_HWCC_BYTES must be at least the app layout size: lmdb-server --print-app-bytes [params].\n"
               "--backend megalon: Megalon (RACKOBJ_CONFIG, object_arena_size >= (max_pages-2) x 4096) maps the device;\n"
               "  MEGALON_NODE_ID / MEGALON_RUN_ID / CXL_REGION_CONFIG default to --node / --run-id / --region.\n");
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
    if (a == "--node") o.n.node = std::stoul(v());
    else if (a == "--nodes") o.n.p.nr_nodes = std::stoul(v());
    else if (a == "--run-id") o.n.run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--port") o.port = std::stoul(v());
    else if (a == "--region") o.n.region = v();
    else if (a == "--image") o.n.image = v();
    else if (a == "--max-pages") o.n.p.max_pages = std::stoull(v());
    else if (a == "--records") o.n.p.records = std::stoull(v());
    else if (a == "--readers") o.n.p.readers = std::stoul(v());
    else if (a == "--get-threads") o.get_threads = std::stoul(v());
    else if (a == "--start-timeout-ms") o.n.start_timeout_ms = std::stoull(v());
    else if (a == "--no-warm") o.n.warm = false;
    else if (a == "--prepare-threads") o.n.prepare_threads = std::stoul(v());
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.n.megalon_lib = v();
    else if (a == "--print-app-bytes") print_bytes = true;
    else if (a == "--preload-only") o.n.preload_only = true;
    else if (a == "--preloaded") o.n.preloaded = true;
    else usage();
  }
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.n.p).L.bytes());
    return 0;
  }
  if ((o.n.run_id == 0 && !o.n.preload_only) || o.n.p.max_pages <= 2) usage();
  if (o.n.preload_only && o.backend != "plain") {
    std::fprintf(stderr, "lmdb-server: --preload-only is for the plain backend (Popcorn init_state=shared)\n");
    return 2;
  }
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  if (o.backend == "plain") return run<PlainBackend>(o);
  if (o.backend != "megalon") usage();
  megalon_env(o.n, argv[0]);
  return run<MegalonBackend>(o);
}

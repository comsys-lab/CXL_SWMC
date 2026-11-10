// rocksdb-server, one process per VM (workloads/rocksdb/DESIGN.md). Each node runs its own RocksDB DB (memtables and
// files in CXL memory, written only by this node) and reads every other node's DB directly (remote.h). Speaks
// experiments/loadgen/frame.h with workloads/rocksdb/proto.h.
//   get    = newest value of the key over every node's DB (highest global stamp)
//   update = stamp = fetch_add on the HWcc global stamp, then a Put into this node's DB (WAL off); reply after the
//            memtable insert (visible to every later get on any node)
// Threads: listen, one reader per connection, --threads workers (one FIFO queue for both ops, as a RocksDB server's
// request threads), RocksDB's own flush/compaction threads, one catch-up thread per remote view, one reclaim thread.
// Per-operation split (MOT1 v6 Fig 2; workloads/kv/server/opsplit.h): every get / update is one operation, T = rdtsc
// from request dispatch (after validation) to response ready, excluding the reply send; C = the thread's coherence
// time inside it (Popcorn swmc_acct for --backend plain).
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
#include "node.h"
#include "opsplit.h"
#include "proc_stats.h"
#include "proto.h"

using namespace rdbw;

namespace {

struct Opts {
  NodeOpts n;
  uint32_t port = 7200, threads = 8;
};

// Diagnostic timer (builds/rocksdb/10, branch rocksdb-diag; counters only): event count, total ns and the largest
// single event since the last stats read (take_max resets it; with loadgen the only stats reader, a per-step max).
// Written by one worker thread; the stats reader sums count/ns over workers and takes the max of max_ns.
struct DiagT {
  std::atomic<uint64_t> count{0}, ns{0}, max_ns{0};
  void add(uint64_t d) {
    count.fetch_add(1, std::memory_order_relaxed);
    ns.fetch_add(d, std::memory_order_relaxed);
    uint64_t m = max_ns.load(std::memory_order_relaxed);
    while (d > m && !max_ns.compare_exchange_weak(m, d, std::memory_order_relaxed)) {
    }
  }
};
// Conn::reply timers: total (lock wait + blocking writes + unlock) and the lock wait alone (count = reply.count)
struct ReplyDiag {
  DiagT total;
  std::atomic<uint64_t> lock_ns{0}, lock_max_ns{0};
};

struct Conn {
  int fd;
  std::mutex wmu;
  // returns the time after the reply (now_ns); rd (nullable) receives the timers
  uint64_t reply(ReplyDiag *rd, uint16_t status, uint64_t req_id, const void *a, uint32_t na, const void *b = nullptr,
                 uint32_t nb = 0) {
    frame::header h;
    frame::fill(&h, status, req_id, na + nb);
    const uint64_t t0 = now_ns();
    uint64_t t1;
    {
      std::lock_guard<std::mutex> g(wmu);
      t1 = now_ns();
      frame::write_full(fd, &h, sizeof(h));
      if (na) frame::write_full(fd, a, na);
      if (nb) frame::write_full(fd, b, nb);
    }
    const uint64_t t2 = now_ns();
    if (rd) {
      rd->total.add(t2 - t0);
      const uint64_t w = t1 - t0;
      rd->lock_ns.fetch_add(w, std::memory_order_relaxed);
      uint64_t m = rd->lock_max_ns.load(std::memory_order_relaxed);
      while (w > m && !rd->lock_max_ns.compare_exchange_weak(m, w, std::memory_order_relaxed)) {
      }
    }
    return t2;
  }
};

struct Job {
  std::shared_ptr<Conn> c;
  frame::header h;
  std::vector<uint8_t> p;
  uint64_t t_enq = 0;  // now_ns at enqueue (reader thread), for the queue wait timer
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

enum OpType : uint32_t { kGetOp = 0, kUpdateOp = 1 };  // opsplit operation types
struct alignas(64) WorkerStats {                      // one per worker (written by its thread only)
  std::atomic<uint64_t> gets{0}, get_not_found{0}, get_errors{0}, get_ns{0}, updates{0}, update_errors{0},
      update_ns{0}, remote_errors{0};
  // diagnostic timers (stats keys diag.*; see stats_text)
  DiagT queue_wait, pop_idle, stripe_wait, stamp, put, wt_wait, memtable, write_delay;
  ReplyDiag reply;
};

class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), node_(o_.n) {}

  void start() {
    if (o_.threads == 0) die("--threads must be > 0");
    node_.start("rocksdb-server");
    ws_.reset(new WorkerStats[o_.threads]);
    const bool meg = o_.n.backend == "megalon";
    // C by the plain all-HWcc (no Megalon there): Formula::kLMDB, as the lmdb workload
    opt_.reset(new opsplit::Table({"get", "update"}, o_.threads, meg ? opsplit::Source::kMegalon : opsplit::Source::kPopcorn,
                                  node_.backend().api(), opsplit::Formula::kLMDB));
    oth_.reset(new opsplit::Thread[o_.threads]);
    std::fprintf(stderr, "rocksdb-server: opsplit tsc_hz %.0f source %s\n", opt_->tsc_hz(), meg ? "megalon" : "popcorn");
    for (uint32_t i = 0; i < o_.threads; i++) std::thread([this, i] { worker(i); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  std::string stats_text() {
    std::ostringstream o;
    uint64_t g = 0, gnf = 0, ge = 0, gns = 0, u = 0, ue = 0, uns = 0, re = 0;
    for (uint32_t i = 0; i < o_.threads; i++) {
      g += ws_[i].gets, gnf += ws_[i].get_not_found, ge += ws_[i].get_errors, gns += ws_[i].get_ns;
      u += ws_[i].updates, ue += ws_[i].update_errors, uns += ws_[i].update_ns, re += ws_[i].remote_errors;
    }
    o << "node=" << o_.n.node << "\nbackend=" << o_.n.backend << "\ngets=" << g << "\nget_not_found=" << gnf
      << "\nget_errors=" << ge << "\nget_ns=" << gns << "\nupdates=" << u << "\nupdate_errors=" << ue
      << "\nupdate_ns=" << uns << "\nremote_errors=" << re << "\nqueue=" << q_.size()
      << "\nstamp=" << cxl::hwcc::load_acquire(node_.hwcc().stamp) << "\ndesc_installs=" << node_.desc_installs()
      << "\npools=" << node_.shared().usage() << "\npools.blocks_free=" << node_.shared().blocks_free()
      << "\npools.extents_free=" << node_.shared().free_extents() << "\nget_retries=" << node_.get_retries()
      << "\nget_retry_limit=" << node_.get_retry_limit() << "\n" << node_.fs().stats_text();
    if (const StaleFilter *f = node_.filter())
      o << "gc.checked=" << f->checked.load() << "\ngc.dropped=" << f->dropped.load() << "\n";
    for (size_t v = 0; v < node_.views().size(); v++) {
      const RemoteView *rv = node_.views()[v];
      if (!rv) continue;
      const RemoteStats &s = rv->stats();
      o << "remote" << v << ".gets=" << s.gets << "\nremote" << v << ".mem_hits=" << s.mem_hits << "\nremote" << v
        << ".sst_hits=" << s.sst_hits << "\nremote" << v << ".misses=" << s.misses << "\nremote" << v
        << ".catchups=" << s.catchups << "\nremote" << v << ".sync_catchups=" << s.sync_catchups << "\nremote" << v
        << ".catchup_errors=" << s.catchup_errors << "\nremote" << v << ".catchup_ns=" << s.catchup_ns << "\nremote"
        << v << ".errors=" << s.errors << "\nremote" << v << ".applied_gen=" << rv->applied() << "\n";
    }
    auto prop = [&](const char *name) {
      std::string val;
      if (node_.db()->GetProperty(name, &val)) o << "rocksdb." << (name + 8) << "=" << val << "\n";
    };
    for (int l = 0; l < 7; l++) prop(("rocksdb.num-files-at-level" + std::to_string(l)).c_str());
    prop("rocksdb.estimate-pending-compaction-bytes");
    prop("rocksdb.num-running-compactions");
    prop("rocksdb.num-running-flushes");
    prop("rocksdb.cur-size-all-mem-tables");
    prop("rocksdb.num-immutable-mem-table");
    prop("rocksdb.total-sst-files-size");
    prop("rocksdb.actual-delayed-write-rate");
    prop("rocksdb.is-write-stopped");
    auto st = node_.statistics();
    for (auto t : {ROCKSDB_NAMESPACE::COMPACT_READ_BYTES, ROCKSDB_NAMESPACE::COMPACT_WRITE_BYTES,
                   ROCKSDB_NAMESPACE::FLUSH_WRITE_BYTES, ROCKSDB_NAMESPACE::STALL_MICROS,
                   ROCKSDB_NAMESPACE::MEMTABLE_HIT, ROCKSDB_NAMESPACE::MEMTABLE_MISS,
                   ROCKSDB_NAMESPACE::BLOCK_CACHE_HIT, ROCKSDB_NAMESPACE::BLOCK_CACHE_MISS,
                   ROCKSDB_NAMESPACE::BLOOM_FILTER_USEFUL})
      o << "rocksdb.ticker." << t << "=" << st->getTickerCount(t) << "\n";
    for (auto t : {ROCKSDB_NAMESPACE::WRITE_DONE_BY_SELF, ROCKSDB_NAMESPACE::WRITE_DONE_BY_OTHER})
      o << "rocksdb.ticker." << t << "=" << st->getTickerCount(t) << "\n";
    diag_text(o);
    o << node_.backend().stats() << opt_->text() << cxl::proc::text(pst_);
    return o.str();
  }

  // Diagnostic timers (builds/rocksdb/10; DESIGN.md section 12). Every timer X: diag.X_count, diag.X_ns (counters,
  // per-step deltas in stats-steps.csv) and diag.X_max_ns (largest single event since the previous stats read, reset
  // here; a gauge by its max_ns suffix). diag.reset_window_max_ns = ns since the previous stats read (the window the
  // maxima cover; a gauge by the same suffix).
  void diag_text(std::ostringstream &o) {
    auto emit = [&](const char *name, uint64_t c, uint64_t ns, uint64_t mx) {
      o << "diag." << name << "_count=" << c << "\ndiag." << name << "_ns=" << ns << "\ndiag." << name << "_max_ns=" << mx
        << "\n";
    };
    auto worker = [&](const char *name, DiagT WorkerStats::*m) {
      uint64_t c = 0, ns = 0, mx = 0;
      for (uint32_t i = 0; i < o_.threads; i++) {
        DiagT &t = ws_[i].*m;
        c += t.count.load(std::memory_order_relaxed), ns += t.ns.load(std::memory_order_relaxed);
        mx = std::max(mx, t.max_ns.exchange(0, std::memory_order_relaxed));
      }
      emit(name, c, ns, mx);
    };
    const uint64_t now = now_ns();
    o << "diag.reset_window_max_ns=" << now - diag_reset_ns_.exchange(now) << "\n";
    worker("queue_wait", &WorkerStats::queue_wait);    // (a) enqueue (reader thread) to dequeue (worker)
    worker("pop_idle", &WorkerStats::pop_idle);        // worker blocked in the queue pop (previous reply end to dequeue)
    {                                                  // (b) Conn::reply total; lock = its wmu acquisition alone
      uint64_t c = 0, ns = 0, mx = 0, lns = 0, lmx = 0;
      for (uint32_t i = 0; i < o_.threads; i++) {
        ReplyDiag &r = ws_[i].reply;
        c += r.total.count.load(std::memory_order_relaxed), ns += r.total.ns.load(std::memory_order_relaxed);
        lns += r.lock_ns.load(std::memory_order_relaxed);
        mx = std::max(mx, r.total.max_ns.exchange(0, std::memory_order_relaxed));
        lmx = std::max(lmx, r.lock_max_ns.exchange(0, std::memory_order_relaxed));
      }
      emit("reply", c, ns, mx);
      o << "diag.reply_lock_ns=" << lns << "\ndiag.reply_lock_max_ns=" << lmx << "\n";
    }
    worker("stripe_wait", &WorkerStats::stripe_wait);  // (c) key-stripe mutex acquisition in an update
    worker("stamp", &WorkerStats::stamp);              // HWcc stamp fetch_add (under the stripe)
    worker("put", &WorkerStats::put);                  // (d) db_->Put wall time (incl. the stored value build)
    worker("wt_wait", &WorkerStats::wt_wait);          // (f) RocksDB perf write_thread_wait_nanos (Puts that waited)
    worker("memtable", &WorkerStats::memtable);        // (f) RocksDB perf write_memtable_time (memtable insert)
    worker("write_delay", &WorkerStats::write_delay);  // (f) RocksDB perf write_delay_time (Puts delayed/stopped)
    auto rdb = [&](const char *name, ROCKSDB_NAMESPACE::cxl::DiagTimer &t) {  // patches/0004, process-wide
      emit(name, t.count.load(std::memory_order_relaxed), t.ns.load(std::memory_order_relaxed), t.TakeMax());
    };
    auto &dc = ROCKSDB_NAMESPACE::cxl::GetDiagCounters();
    rdb("slot_lock_wait", dc.slot_lock_wait);      // (e) arena slot SpinMutex wait (contended acquisitions only)
    rdb("slot_new_block", dc.slot_new_block);      // (e) new arena block (BlockSource::Get) inside the slot lock
    rdb("flush_mutex_wait", dc.flush_mutex_wait);  // (f) write leader: DB mutex wait before ScheduleFlushes
    rdb("schedule_flushes", dc.schedule_flushes);  // (f) write leader: WaitForPendingWrites + ScheduleFlushes (switch)
    rdb("wbm_flush", dc.wbm_flush);                // (f) write leader: write-buffer-manager flush block
    // builds/rocksdb/11 (patches/0005): MemTable::Add wall, and minus the backend section time inside it (diag.mg_mem_*
    // in the backend stats); the skiplist insert (search + link) inside Add, the same two ways
    rdb("memtable_add", dc.memtable_add);
    rdb("memtable_add_rdb", dc.memtable_add_rdb);
    rdb("skiplist_insert", dc.skiplist_insert);
    rdb("skiplist_insert_rdb", dc.skiplist_insert_rdb);
  }

 private:
  void worker(uint32_t i) {
    cxl::proc::name_thread("rdb-worker");
    node_.backend().thread_init();
    WorkerStats &st = ws_[i];
    opsplit::Thread &ot = oth_[i];
    ot.init(opt_.get(), i);
    std::string stored;
    ReplyDiag *rd = &st.reply;
    uint64_t tend = now_ns();  // end of the previous job (its reply): the pop wait starts here
    for (;;) {
      Job j = q_.pop();
      const uint64_t t0 = now_ns();
      st.pop_idle.add(t0 - tend);
      st.queue_wait.add(t0 - j.t_enq);
      if (j.h.code == kOpVerify) {
        std::string t = verify();
        tend = j.c->reply(rd, frame::kStatusOk, j.h.req_id, t.data(), uint32_t(t.size()));
        continue;
      }
      if (j.h.code == kOpGet) {
        GetReq rq;
        if (frame::payload_len(j.h) < sizeof(rq)) { tend = bad(j); continue; }
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (frame::payload_len(j.h) != sizeof(rq) + rq.klen || rq.klen == 0 || rq.klen > 511) { tend = bad(j); continue; }
        const std::string key(reinterpret_cast<const char *>(j.p.data() + sizeof(rq)), rq.klen);
        uint64_t rerr = 0;
        ot.begin();
        const bool found = node_.get(key, &stored, &rerr);
        ot.end(kGetOp);  // response ready; reply excluded
        GetResp rs{0, 0, 0};
        if (rerr) st.remote_errors.fetch_add(rerr, std::memory_order_relaxed);
        if (found) {
          rs.stamp = value_stamp(stored.data());
          rs.vlen = uint32_t(stored.size() - kStampBytes);
          rs.service_us = uint32_t((now_ns() - t0) / 1000);
          tend = j.c->reply(rd, frame::kStatusOk, j.h.req_id, &rs, sizeof(rs), stored.data() + kStampBytes, rs.vlen);
          st.gets.fetch_add(1, std::memory_order_relaxed);
        } else {
          rs.service_us = uint32_t((now_ns() - t0) / 1000);
          if (rerr) {
            st.get_errors.fetch_add(1, std::memory_order_relaxed);
            tend = j.c->reply(rd, frame::kStatusServerError, j.h.req_id, nullptr, 0);
          } else {
            st.get_not_found.fetch_add(1, std::memory_order_relaxed);
            tend = j.c->reply(rd, kStatusNotFound, j.h.req_id, &rs, sizeof(rs));
          }
        }
        st.get_ns.fetch_add(tend - t0, std::memory_order_relaxed);
        continue;
      }
      UpdateReq rq;  // kOpUpdate
      if (frame::payload_len(j.h) < sizeof(rq)) { tend = bad(j); continue; }
      std::memcpy(&rq, j.p.data(), sizeof(rq));
      if (frame::payload_len(j.h) != sizeof(rq) + rq.klen + rq.vlen || rq.klen == 0 || rq.klen > 511) { tend = bad(j); continue; }
      const std::string key(reinterpret_cast<const char *>(j.p.data() + sizeof(rq)), rq.klen);
      ROCKSDB_NAMESPACE::Status s;
      Node::PutDiag pd;
      ot.begin();
      const uint64_t stamp = node_.put(key, j.p.data() + sizeof(rq) + rq.klen, rq.vlen, &s, &pd);
      ot.end(kUpdateOp, s.ok() ? rq.vlen : 0);  // response ready (in the memtable); reply excluded
      UpdateResp rs{stamp, 0, uint32_t((now_ns() - t0) / 1000)};
      st.stripe_wait.add(pd.stripe_ns);
      st.stamp.add(pd.stamp_ns);
      st.put.add(pd.put_ns);
      st.memtable.add(pd.memtable_ns);
      if (pd.wt_wait_ns) st.wt_wait.add(pd.wt_wait_ns);  // counted only when the write thread waited (slow path)
      if (pd.delay_ns) st.write_delay.add(pd.delay_ns);
      if (!s.ok()) {
        st.update_errors.fetch_add(1, std::memory_order_relaxed);
        std::fprintf(stderr, "rocksdb-server: put: %s\n", s.ToString().c_str());
        tend = j.c->reply(rd, frame::kStatusServerError, j.h.req_id, nullptr, 0);
      } else {
        st.updates.fetch_add(1, std::memory_order_relaxed);
        tend = j.c->reply(rd, frame::kStatusOk, j.h.req_id, &rs, sizeof(rs));
      }
      st.update_ns.fetch_add(tend - t0, std::memory_order_relaxed);
    }
  }

  // Scan of this node's DB: entries, values complete for their key, highest stamp.
  std::string verify() {
    const uint64_t t0 = now_ns();
    uint64_t n = 0, bad = 0, misorder = 0, max_stamp = 0, prev = 0;
    std::unique_ptr<ROCKSDB_NAMESPACE::Iterator> it(node_.db()->NewIterator(ROCKSDB_NAMESPACE::ReadOptions()));
    for (it->SeekToFirst(); it->Valid(); it->Next()) {
      uint64_t i = 0;
      ValHdr h;
      const auto k = it->key(), v = it->value();
      if (!parse_key(k.data(), uint32_t(k.size()), &i) || v.size() != kStampBytes + kValueBytes ||
          !check_value(i, reinterpret_cast<const uint8_t *>(v.data()) + kStampBytes, kValueBytes, &h))
        bad++;
      else max_stamp = std::max(max_stamp, value_stamp(v.data()));
      if (n && i <= prev) misorder++;
      prev = i;
      n++;
    }
    std::ostringstream o;
    o << "verify.entries=" << n << "\nverify.bad_values=" << bad << "\nverify.misordered=" << misorder
      << "\nverify.max_stamp=" << max_stamp << "\nverify.end=" << (it->status().ok() ? "ok" : it->status().ToString())
      << "\nverify.ms=" << (now_ns() - t0) / 1000000 << "\n";
    return o.str();
  }

  uint64_t bad(Job &j) { return j.c->reply(nullptr, frame::kStatusBadRequest, j.h.req_id, nullptr, 0); }

  void listen_loop() {
    cxl::proc::name_thread("rdb-listen");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "rocksdb-server: READY node %u port %u\n", o_.n.node, o_.port);
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
    cxl::proc::name_thread("rdb-conn");
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpGet:
        case kOpUpdate:
        case kOpVerify: j.t_enq = now_ns(); q_.push(std::move(j)); break;
        case kOpStats: {
          std::string t = stats_text();
          c->reply(nullptr, frame::kStatusOk, h.req_id, t.data(), uint32_t(t.size()));
          break;
        }
        default: c->reply(nullptr, frame::kStatusUnknownOp, h.req_id, nullptr, 0);
      }
    }
    close(c->fd);
  }

  Opts o_;
  Node node_;
  std::unique_ptr<WorkerStats[]> ws_;
  std::unique_ptr<opsplit::Table> opt_;
  std::unique_ptr<opsplit::Thread[]> oth_;
  Queue q_;
  std::atomic<uint64_t> diag_reset_ns_{now_ns()};  // previous stats read (diag.*_max_ns window)
  // kthreads: receive thread cxl_recv_<n> and (run 2 adaptive receiver) idle pollers cxl_ipoll/<cpu>, kept apart
  cxl::proc::Opts pst_{{"cxl_recv", "cxl_ipoll"},
                       {"TLB", "CAL", "RES", "LOC"},
                       {"/sys/kernel/swmc/page_coherence", "/sys/kernel/swmc/instr", "/sys/kernel/cxl_shm"}};
};

volatile sig_atomic_t g_stop = 0;

// Megalon reads its node id, run id and region from the environment (as workloads/lmdb/server/node.h megalon_env)
void megalon_env(NodeOpts &o, const char *argv0) {
  auto env = [](const char *k, const std::string &v) {
    const char *cur = getenv(k);
    if (cur && *cur && v != cur) {
      std::fprintf(stderr, "rocksdb-server: %s=%s contradicts the option (%s)\n", k, cur, v.c_str());
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
    if (n <= 0) die(std::string("readlink /proc/self/exe for ") + argv0);
    exe[n] = 0;
    std::string d(exe);
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libmegalon-objapi.so";
  }
}

void usage() {
  std::fprintf(stderr,
               "usage: rocksdb-server --node K --nodes N --run-id 0x.. --keys N\n"
               "  [--port P (7200)] [--region yaml] [--threads N (8)] [--epoch-slots S (64)] [--max-files F (2048)]\n"
               "  [--max-ext E (192)] [--arena-blocks B (512)] [--file-extents X (0 = rest)] [--local-dir D]\n"
               "  [--prepare-threads T (8)] [--no-gc-filter] [--write-buffer-mb M (64)] [--target-file-mb M (64)]\n"
               "  [--max-manifest-kb K (max_ext/2 MiB)] (the last three: Host tests only)\n"
               "  [--start-timeout-ms T] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "--backend megalon: Megalon (RACKOBJ_CONFIG, object_arena_size >= 2 x (arena_blocks + file_extents) MiB,\n"
               "  --file-extents explicit) maps the device; MEGALON_NODE_ID / MEGALON_RUN_ID / CXL_REGION_CONFIG default to\n"
               "  --node / --run-id / --region; at most 32 threads open sections (keep --prepare-threads small).\n"
               "  [--mg-mem-object-bytes B (1048576)] [--mg-file-object-bytes B (1048576)]: Megalon object per memtable slot /\n"
               "  file slice (megalon-record: 1152 / 4096); the defaults are one object per arena block / file extent.\n"
               "All nodes need identical --nodes/--keys/--epoch-slots/--max-files/--max-ext/--arena-blocks/--file-extents\n"
               "(checked through the HWcc layout hash). CXL_APP_HWCC_BYTES must be at least the app layout size:\n"
               "rocksdb-server --print-app-bytes [params].\n");
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
    else if (a == "--keys") o.n.p.keys = std::stoull(v());
    else if (a == "--port") o.port = std::stoul(v());
    else if (a == "--region") o.n.region = v();
    else if (a == "--threads") o.threads = std::stoul(v());
    else if (a == "--epoch-slots") o.n.p.epoch_slots = std::stoul(v());
    else if (a == "--max-files") o.n.p.max_files = std::stoul(v());
    else if (a == "--max-ext") o.n.p.max_ext = std::stoul(v());
    else if (a == "--arena-blocks") o.n.p.arena_blocks = std::stoull(v());
    else if (a == "--file-extents") o.n.p.file_extents = std::stoull(v());
    else if (a == "--local-dir") o.n.local_dir = v();
    else if (a == "--prepare-threads") o.n.prepare_threads = std::stoul(v());
    else if (a == "--no-gc-filter") o.n.gc_filter = false;
    else if (a == "--write-buffer-mb") o.n.write_buffer_mb = std::stoull(v());
    else if (a == "--target-file-mb") o.n.target_file_mb = std::stoull(v());
    else if (a == "--max-manifest-kb") o.n.max_manifest_kb = std::stoull(v());
    else if (a == "--start-timeout-ms") o.n.start_timeout_ms = std::stoull(v());
    else if (a == "--backend") o.n.backend = v();
    else if (a == "--megalon-lib") o.n.megalon_lib = v();
    else if (a == "--mg-mem-object-bytes") o.n.mg_mem_object_bytes = std::stoull(v());
    else if (a == "--mg-file-object-bytes") o.n.mg_file_object_bytes = std::stoull(v());
    else if (a == "--print-app-bytes") print_bytes = true;
    else usage();
  }
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.n.p, o.n.backend == "megalon" ? " backend=megalon" : "").L.bytes());
    return 0;
  }
  if (o.n.run_id == 0 || o.n.p.keys == 0 || (o.n.backend != "plain" && o.n.backend != "megalon")) usage();
  if (o.n.backend != "megalon" && (o.n.mg_mem_object_bytes != kUnit || o.n.mg_file_object_bytes != kUnit)) usage();
  if (o.n.backend == "megalon") megalon_env(o.n, argv[0]);
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  Server s(o);
  s.start();
  while (!g_stop) usleep(200000);
  std::fprintf(stderr, "rocksdb-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);  // no RocksDB teardown (as lmdb-server); the next run re-initialises
}

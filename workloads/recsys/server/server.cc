// recsys server (DLRMv2-based recommendation system), one process per VM (DESIGN.md). Speaks
// experiments/loadgen/frame.h with workloads/recsys/proto.h. Shared state: 26 directly addressed embedding tables
// (row r of table k = record row_base[k] + r = key + embedding + seq + csum, 576 B), a striped HWcc version table
// (MemC3: S = 2^16 u32 counters, row -> hash(table, key) mod S; used by the plain backend). Every node accepts both ops; the harness sends updates to the
// updater node (0) and queries to the serving node (1). Threads: one reader per connection, U update workers (rows
// sharded by stripe % U on plain, by Megalon object % U on Megalon; Monolith-style touched-row publication every T,
// workers independent; --update-mode stream: every sample written right away, acknowledged on acceptance), S serving workers (a
// query is split into chunks of pairs; workers claim chunks). Backend (--backend plain|megalon): where the records live
// and which coherence actions wrap each record access; Server<Backend> is compiled per backend. Per-operation time
// split (MOT1 v6 Fig 2): optime.h.
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <vector>

#include "../proto.h"
#include "backend.h"
#include "chunk.h"
#include "emb_v7.h"
#include "frame.h"
#include "layout.h"
#include "model.h"
#include "optime.h"
#include "proc_stats.h"

using namespace rsys;
using cxl::hwcc::load_acquire;
using cxl::hwcc::load_relaxed;
using cxl::hwcc::store_release;

namespace {

volatile sig_atomic_t g_stop = 0;

uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
// v7 stale-read logs (both nodes): CLOCK_REALTIME, so that node 0's write times and node 1's read times share a clock
// (guests of one Host: kvm-clock; the residual offset between the guests bounds the age resolution; DESIGN.md §10.6)
uint64_t real_ns() {
  timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
uint64_t thread_cpu_ns() {
  timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "recsys-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct Opts {
  Params p;
  uint32_t node = 0, port = 7100, serve_threads = 14, update_threads = 4, load_threads = 8;
  uint32_t chunk_pairs = 0;     // pairs per parallel task; 0 = adaptive: max(min_chunk, ceil(pairs / ways))
  uint32_t split_ways = 0;      // ways of the adaptive split; 0 = serve_threads (chunk.h query_chunk)
  uint32_t min_chunk = 16;
  uint32_t rank = 512;          // DCNv2 low rank (MLPerf 512)
  Mlp mlp = Mlp::avx512;        // serving forward: avx512 (fp32) | amx (bf16 tiles, fp32 accumulate; model.h, amx.h)
  uint64_t publish_us = 0;     // publication interval T (0 = write each sample immediately)
  bool stream = false;          // --update-mode stream (T = 0 only): reply on acceptance, every worker writes its rows
                                // of each sample right away (RecSys methodology 2026-10-19, DESIGN.md §5.1)
  double publish_frac = 0;      // operating point: target fraction of all rows published per T (reported; the
                                // harness sets the sample rate with recsys-rate; 0 = none)
  uint64_t run_id = 0, start_timeout_ms = 3600000;
  uint64_t check_stride = 4096; // Megalon: ObjectLookup every n-th slot on every node
  bool warm_up = true, verify_rows = false, preload_only = false, preloaded = false;
  bool test_no_seqlock = false;  // negative test only: readers ignore the version words (torn rows must show up)
  int64_t mg_rows_per_object = -1;  // Megalon object granularity (required with --backend megalon): 0 = one object
                                    // per table (main), 1 = per row (restructured best case), N > 1 = N-row chunks
  uint32_t megalon_time_sample = 0;  // legacy app-level Megalon timers, 1 in N sections (backend.h MegThr); v6: off
                                     // by default (CohSnap replaces them; they perturb timing)
  std::string region, backend = "plain", megalon_lib;
  cxl::proc::Opts proc;
  // ---- v7 (DESIGN.md §10.6). Defaults of lr / acc_init / train_batch are NOT decided (user); every run records them
  // (startup line + stats `train.*`), the harness passes them explicitly.
  std::string image;            // --image: initial rows from the converted checkpoint (emb_v7.h ImageHeader + records)
  std::string model_dense;      // --model-dense: trained dense weights (RSYSDNS1); else deterministic random (v6)
  bool train = false;           // --update-mode train: online training on this node (test-then-train), implies stream
  uint32_t train_threads = 0;   // trainer threads (0 = --update-threads); rows are written by the U row owners
  uint32_t train_batch = 8;     // --train-batch: samples per training step (max; taken without waiting)
  AdagradCfg ada;               // --lr (0.004 = MLPerf DLRMv2 reference, to be confirmed), --eps
  double acc_init = -1;         // --acc-init: initial row-wise Adagrad state written at load (< 0: as in the image)
  std::string stale_log;        // --stale-log FILE: (row, seq, CLOCK_REALTIME ns) of sampled rows; node 0 = every
                                // write, other nodes = every serving lookup of a sampled row
  uint32_t stale_mod = 256;     // --stale-sample N: a row is sampled iff mix64(global row) % N == 0 (same on every node)
  // ---- windowed publication (reports/experiments/recsys-windowed-update.md; train mode only; 0 = off = write-through,
  // every earlier run). W > 0: owners update a node-0 DRAM copy of each touched row (first touch copies the record from
  // shared memory); the distinct rows D_w of wall-clock window w are written to shared memory during window w + 1 by one
  // publisher thread, ceil(|D_w| / W) rows per second, evenly spaced, each row's latest DRAM value.
  uint32_t publish_window_s = 0;  // --publish-window-s W
  uint64_t dram_rows_cap = 0;     // --publish-dram-rows N: DRAM copy capacity in rows (0 = min(total rows, 48M))
  std::string publish_trace;      // --publish-trace FILE: text log of every DRAM update / publish (Host tests only)
  uint64_t publish_test_delay_ns = 0;  // --publish-test-row-delay-ns N: busy-wait per published row (Host catch-up test only)
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
  uint64_t t_arr = 0;
};

template <class T>
class Queue {
 public:
  void push(T j) { push_size(std::move(j)); }
  size_t push_size(T j) {  // returns the queue length after the push
    size_t n;
    {
      std::lock_guard<std::mutex> g(mu_);
      q_.push_back(std::move(j));
      n = q_.size();
    }
    cv_.notify_one();
    return n;
  }
  // false on timeout (deadline_ns, CLOCK_MONOTONIC; 0 = wait forever)
  bool pop(T *out, uint64_t deadline_ns) {
    std::unique_lock<std::mutex> l(mu_);
    while (q_.empty()) {
      if (!deadline_ns) {
        cv_.wait(l);
        continue;
      }
      const uint64_t n = now_ns();
      if (n >= deadline_ns) return false;
      cv_.wait_for(l, std::chrono::nanoseconds(deadline_ns - n));
    }
    *out = std::move(q_.front());
    q_.pop_front();
    return true;
  }
  size_t size() {
    std::lock_guard<std::mutex> g(mu_);
    return q_.size();
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<T> q_;
};

struct Stats {
  std::atomic<uint64_t> queries{0}, pairs{0}, lookups{0}, probes{0}, seq_retries{0}, false_retries{0}, seq_spins{0},
      misses{0}, torn{0}, lookup_ns{0}, mlp_ns{0}, query_ns{0}, bad{0}, update_sections{0};
  std::atomic<uint64_t> samples{0}, rows_touched{0}, rows_written{0}, update_misses{0}, flushes{0}, flush_ns{0},
      flush_ns_max{0}, flush_overruns{0}, lock_spins{0}, write_ns{0}, accum_cyc{0}, publish_rounds{0},
      round_rows{0}, round_rows_max{0}, uq_max{0};
  std::atomic<uint64_t> accepted_seq{0}, lag_ns_sum{0}, lag_n{0}, lag_ns_max{0};  // stream mode (DESIGN.md §5.1)
  // v7 train mode: trainer (forward + backward) and row-owner (read-modify-write) thread CPU, from
  // CLOCK_THREAD_CPUTIME_ID; updater_cpu_ns = train_cpu_ns + owner_cpu_ns (steps.csv updater_cpu_s_per_s)
  std::atomic<uint64_t> train_samples{0}, train_batches{0}, train_cpu_ns{0}, train_fwd_ns{0}, train_bwd_ns{0},
      owner_cpu_ns{0}, train_lookups{0}, grad_rows{0}, stale_reads_logged{0}, stale_writes_logged{0};
  // windowed publication (--publish-window-s > 0 only; keys printed only then)
  std::atomic<uint64_t> published_rows{0}, publish_sections{0}, publish_lag_ns_sum{0}, publish_lag_n{0},
      publish_lag_ns_max{0}, publish_backlog{0}, publish_queued{0}, window_distinct{0}, publish_window{0},
      publish_carryover{0}, dram_updates{0}, train_dram_hits{0}, publish_start_ns{0};
  // publish lag histogram: kLagBuckets buckets of W / 64 each (0 .. 2 W) + one overflow bucket (p50 per step from deltas)
  static constexpr int kLagBuckets = 128;
  std::atomic<uint64_t> publish_lag_hist[kLagBuckets + 1] = {};
  OpAcc op_publish;
  OpAcc op_query, op_row_update;  // MOT1 v6 Fig 2 (optime.h)
  std::atomic<uint32_t> coh_pc_threads{0}, coh_mg_threads{0};
};

// Persistent worker pool for prepare work (create, initial write, warm-up). Megalon allows at most 32 thread
// registrations per process and never frees one, so these threads register once (tids 1..n) and are reused.
class PrepPool {
 public:
  template <class Init> void start(uint32_t n, Init init) {
    n_ = n;
    for (uint32_t i = 0; i < n; i++)
      std::thread([this, i, init] {
        init(int(i));
        uint64_t seen = 0;
        for (;;) {
          std::function<void(int)> *f;
          {
            std::unique_lock<std::mutex> l(mu_);
            cv_.wait(l, [&] { return gen_ != seen; });
            seen = gen_;
            f = f_;
          }
          (*f)(int(i));
          std::lock_guard<std::mutex> l(mu_);
          if (++done_ == n_) dcv_.notify_all();
        }
      }).detach();
  }
  void run(std::function<void(int)> f) {  // f(i) on every pool thread; returns when all returned
    std::unique_lock<std::mutex> l(mu_);
    f_ = &f;
    done_ = 0;
    gen_++;
    cv_.notify_all();
    dcv_.wait(l, [&] { return done_ == n_; });
  }

 private:
  uint32_t n_ = 0, done_ = 0;
  uint64_t gen_ = 0;
  std::function<void(int)> *f_ = nullptr;
  std::mutex mu_;
  std::condition_variable cv_, dcv_;
};

template <class Be>
class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), p_(o_.p) {}

  void start() {
    std::string err;
    // Megalon background threads (WriteMetadataManager reclaim etc.) that Megalon spawns from this thread inherit its
    // name: "mg-bg" while start() runs, so their CPU is exported as thr.mg-bg.* (with thr.nr-log-sync.*), separate
    // from rs-* (they are not in CohSnap; reports/M2-megalon-port-changes.md §13). Renamed rs-main at the end.
    cxl::proc::name_thread(std::is_same_v<Be, MegalonBackend> ? "mg-bg" : "rs-main");
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || o_.node >= p_.nr_nodes) die("bad node/nodes");
    if (o_.update_threads == 0 || o_.serve_threads == 0 || o_.min_chunk == 0) die("threads/min chunk must be > 0");
    // Megalon N != 1 adds its granularity to the layout hash (both nodes must agree); N = 1 keeps the 3ef27d8b6 tag
    std::string tag = Be::kLayoutTag;
    if (std::is_same_v<Be, MegalonBackend> && o_.mg_rows_per_object != 1)
      tag += " rows_per_object=" + std::to_string(o_.mg_rows_per_object);
    HwccLayout lay(p_, tag.c_str());
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      if (1 + o_.load_threads + o_.update_threads + o_.serve_threads + train_threads() + (win_on() ? 1 : 0) > 32)
        die("megalon: at most 32 thread registrations per node (main + load + update + serve + train threads"
            " + publisher)");
      api_ = megalon_load(o_.megalon_lib, &err);
      if (!api_) die(err);
      if (api_->node_id() != o_.node) die("megalon node id != --node");
      if (!mapped_by(r_.map_va, r_.device_size, r_.device, &err)) die(err);
      map_ = reinterpret_cast<uint8_t *>(r_.map_va);
    } else {
      map_ = map_device();
    }
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay);
    if constexpr (std::is_same_v<Be, MegalonBackend>)
      be_ = std::make_unique<Be>(r_, map_, p_, api_, uint64_t(o_.mg_rows_per_object));
    else be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    if constexpr (std::is_same_v<Be, PlainBackend>) {
      // De Stijl v2: staleness bound T ($CXL_DESTIJL_T_US, only with CXL_SYSTEM=ds) on each embedding table's row
      // range (widened to whole pages; neighbouring tables share a boundary page, same T), once after the mapping;
      // a no-op for every other system and for T unset / 0. The striped version table stays HWcc.
      uint64_t t = 0;
      for (uint32_t k = 0; k < kSparse; k++)
        if (p_.rows[k] && cxl::region_apply_staleness(r_, be_->slot(k, 0), p_.rows[k] * p_.slot_bytes, &t) != 0)
          die("de stijl staleness (CXL_DESTIJL_T_US) on table " + std::to_string(k) + ": " + std::strerror(errno));
      if (t) std::fprintf(stderr, "recsys-server: de stijl staleness T=%lu us on %u tables\n", (unsigned long)t, kSparse);
    }
    be_->set_time_sample(o_.megalon_time_sample);
    be_->thread_init(0);
    pool_.start(o_.load_threads, [this](int i) { be_->thread_init(1 + i, kRolePrep); cxl::proc::name_thread("rs-prep"); });
    if (o_.model_dense.empty()) {
      ModelSpec ms;
      ms.dim = p_.dim, ms.rank = o_.rank;
      model_.init(ms, p_.seed);
    } else {
      if (!model_.load_dense(o_.model_dense, &err)) die("model: " + err);
      if (model_.spec().dim != p_.dim || model_.spec().rank != o_.rank) die("model: dense weights do not match --dim/--rank");
    }
    if (o_.mlp == Mlp::amx) model_.prepare_amx();
    std::fprintf(stderr, "recsys-server: serving mlp=%s (training path fp32 avx512)\n", mlp_name(o_.mlp));
    if (!o_.stale_log.empty()) open_stale_log();
    if (!o_.publish_trace.empty() && win_on()) {
      trace_f_ = std::fopen(o_.publish_trace.c_str(), "wx");
      if (!trace_f_) die("--publish-trace " + o_.publish_trace + ": cannot create (exists?)");
    }
    std::fprintf(stderr, "recsys-server: v7 %s\n", v7_text(" ").c_str());
    std::fprintf(stderr,
                 "recsys-server: node %u/%u run %#lx %s\nrecsys-server: region %s\nrecsys-server: app layout %lu B "
                 "(used %lu, hash %016lx), backend %s\nrecsys-server: model %.1f MFLOP/pair, weights %.1f MiB\n",
                 o_.node, p_.nr_nodes, (unsigned long)o_.run_id, p_.describe().c_str(), cxl::region_describe(r_).c_str(),
                 (unsigned long)lay.L.bytes(), (unsigned long)lay.L.used(), (unsigned long)lay.L.hash(),
                 be_->usage().c_str(), model_.flops_per_pair() / 1e6, model_.weight_bytes() / 1048576.0);
    if (o_.node == 0) {
      load_initial();
      store_release(h_->load_done, o_.run_id);
    } else if (!cxl::hwcc::poll_until([&] { return g_stop || load_acquire(h_->load_done) == o_.run_id; }, o_.start_timeout_ms) ||
               g_stop) {
      die(g_stop ? "stopped (signal) before node 0 finished the initial load" : "node 0 did not finish the initial load in time");
    }
    if (!be_->check_objects(&err, o_.check_stride)) die(err);
    if (o_.warm_up) warm_up();
    store_release(&h_->nodes[o_.node].loaded, o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              if (g_stop) return true;  // SIGTERM before every node is ready: stop instead of waiting the timeout
              for (uint32_t v = 0; v < p_.nr_nodes; v++)
                if (load_acquire(&h_->nodes[v].loaded) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms) || g_stop)
      die(g_stop ? "stopped (signal) before every node was ready" : "not every node became ready in time");
    done_seq_.reset(new std::atomic<uint64_t>[o_.update_threads]);
    for (uint32_t w = 0; w < o_.update_threads; w++) done_seq_[w] = 0;
    uq_.reset(new Queue<std::shared_ptr<UpdJob>>[o_.update_threads]);
    gq_.reset(new Queue<std::shared_ptr<GradJob>>[o_.update_threads]);
    if (win_on()) dram_init();
    for (uint32_t w = 0; w < o_.update_threads; w++)
      std::thread([this, w] { o_.train ? owner(w) : updater(w); }).detach();
    for (uint32_t i = 0; i < o_.serve_threads; i++) std::thread([this, i] { server(i); }).detach();
    if (o_.train)
      for (uint32_t i = 0; i < train_threads(); i++) std::thread([this, i] { trainer(i); }).detach();
    if (win_on()) std::thread([this] { publisher(); }).detach();
    std::thread([this] { listen_loop(); }).detach();
    cxl::proc::name_thread("rs-main");
  }

  std::string stats_text() {
    std::ostringstream o;
    o << "node=" << o_.node << "\nqueries=" << st_.queries << "\npairs=" << st_.pairs << "\nlookups=" << st_.lookups
      << "\nprobes=" << st_.probes << "\nseq_retries=" << st_.seq_retries << "\nfalse_retries=" << st_.false_retries
      << "\nseq_spins=" << st_.seq_spins << "\nmisses=" << st_.misses
      << "\ntorn_rows=" << st_.torn << "\nlookup_ns=" << st_.lookup_ns << "\nmlp_ns=" << st_.mlp_ns
      << "\nquery_ns=" << st_.query_ns << "\nbad_requests=" << st_.bad << "\nsamples=" << st_.samples
      << "\nrows_touched=" << st_.rows_touched << "\nrows_written=" << st_.rows_written
      << "\nupdate_misses=" << st_.update_misses << "\nflushes=" << st_.flushes << "\nflush_ns=" << st_.flush_ns
      << "\nflush_ns_max=" << st_.flush_ns_max << "\nflush_overruns=" << st_.flush_overruns
      << "\nlock_spins=" << st_.lock_spins << "\nwrite_ns=" << st_.write_ns
      << "\nupdate_sections=" << st_.update_sections << "\npublished_seq="
      << load_acquire(&h_->nodes[o_.node].published_seq) << "\nserve_queue=" << sq_size()
      << "\npublish_us=" << o_.publish_us << "\npublish_frac=" << o_.publish_frac
      << "\nrows_per_round_target=" << uint64_t(o_.publish_frac * double(p_.total_rows) + 0.5)
      << "\npublish_rounds=" << st_.publish_rounds << "\nround_rows=" << st_.round_rows
      << "\nround_rows_max_worker=" << st_.round_rows_max << "\nupdate_rate_sustained=" << (st_.flush_overruns ? 0 : 1)
      << "\nupdate_queue_max=" << st_.uq_max << "\naccum_ns=" << tsc_to_ns(st_.accum_cyc)
      << stream_text() << window_text() << "\n" << v7_text("\n")
      << "\nver_stripes=" << p_.ver_stripes << "\nmodel.mlp=" << mlp_name(o_.mlp) << "\ntsc_khz=" << tsc_khz()
      << "\nop.coh_src=pc_threads:" << st_.coh_pc_threads << ",mg_threads:" << st_.coh_mg_threads << "\n" << op_tags()
      << op_text() << "mem.vm_rss_kb=" << status_kb("VmRSS:")
      << "\nmem.vm_hwm_kb=" << status_kb("VmHWM:") << "\nbackend=" << be_->usage() << "\n"
      << be_->stats() << cxl::proc::text(o_.proc);
    return o.str();
  }

  // --preload-only (plain backend, node 0; Popcorn init_state=shared): write the initial tables into SWcc through a
  // plain mapping before coherence is enabled, then unmap and return. Touches no HWcc.
  void preload() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (o_.node != 0) die("--preload-only runs on node 0 only");
    if constexpr (std::is_same_v<Be, PlainBackend>) {
      map_ = map_device();
      be_ = std::make_unique<Be>(r_, map_, p_);
      if (!be_->fits(&err)) die(err);
      pool_.start(o_.load_threads, [](int) {});
      write_tables();
      if (munmap(map_, r_.device_size) != 0) die("munmap");
    }
    std::fprintf(stderr, "recsys-server: PRELOAD DONE %lu rows (plain mapping, no HWcc access)\n",
                 (unsigned long)p_.total_rows);
  }

  void flush_stale_log() {  // drain every thread's buffer into the file (stats reads and stop)
    if (!stale_f_) return;
    std::lock_guard<std::mutex> g(stale_mu_);
    for (auto &b : stale_bufs_) {
      std::lock_guard<std::mutex> l(b->mu);
      if (!b->v.empty()) std::fwrite(b->v.data(), sizeof(StaleRec), b->v.size(), stale_f_);
      b->v.clear();
    }
    std::fflush(stale_f_);
  }

 private:
  // ---------------------------------------------------------------- v7 (DESIGN.md §10.6)
  uint32_t train_threads() const { return o_.train ? (o_.train_threads ? o_.train_threads : o_.update_threads) : 0; }
  // windowed publication runs on the training node only (node 0; serving nodes never get update samples)
  bool win_on() const { return o_.train && o_.publish_window_s > 0 && o_.node == 0; }
  std::string v7_text(const char *sep) {
    std::ostringstream o;
    o << "v7.image=" << (o_.image.empty() ? "-" : o_.image) << sep << "v7.model_dense="
      << (o_.model_dense.empty() ? "-" : o_.model_dense) << sep << "v7.record_bytes=" << p_.slot_bytes << sep
      << "v7.elt_bytes=" << p_.v7_elt << sep << "update_train=" << (o_.train ? 1 : 0) << sep
      << "train.threads=" << train_threads() << sep << "train.batch=" << o_.train_batch << sep
      << "train.lr=" << o_.ada.lr << sep << "train.eps=" << o_.ada.eps << sep << "train.acc_init="
      << (o_.acc_init < 0 ? std::string("image") : std::to_string(o_.acc_init)) << sep
      << "train.optimizer=rowwise_adagrad" << sep << "train.dense=frozen" << sep
      << "train_samples=" << st_.train_samples << sep << "train_batches=" << st_.train_batches << sep
      << "train_lookups=" << st_.train_lookups << sep << "train_grad_rows=" << st_.grad_rows << sep
      << "train_cpu_ns=" << st_.train_cpu_ns << sep << "train_fwd_ns=" << st_.train_fwd_ns << sep
      << "train_bwd_ns=" << st_.train_bwd_ns << sep << "owner_cpu_ns=" << st_.owner_cpu_ns << sep
      << "updater_cpu_ns=" << (st_.train_cpu_ns + st_.owner_cpu_ns) << sep
      << "stale.log=" << (o_.stale_log.empty() ? "-" : o_.stale_log) << sep << "stale.sample_mod=" << o_.stale_mod
      << sep << "stale.reads_logged=" << st_.stale_reads_logged << sep << "stale.writes_logged="
      << st_.stale_writes_logged << sep << "stale.clock=CLOCK_REALTIME";
    if (std::string(sep) == "\n") flush_stale_log();  // a stats read also drains the log (bounded buffers)
    return o.str();
  }

  // Stale-read log: header (64 B) "RSYSSTL1" | u32 node | u32 sample_mod | u64 record_bytes 24 | pad; records
  // {u64 global row, u64 seq, u64 CLOCK_REALTIME ns}. Node 0 logs each write of a sampled row after it is visible;
  // a serving node each lookup of a sampled row (seq read, time after the copy). Joined offline (tools/v7_metrics.py).
  struct StaleRec {
    uint64_t gslot, seq, t_ns;
  };
  struct StaleBuf {
    std::mutex mu;
    std::vector<StaleRec> v;
  };
  void open_stale_log() {
    stale_f_ = std::fopen(o_.stale_log.c_str(), "wbx");
    if (!stale_f_) die("--stale-log " + o_.stale_log + ": cannot create (exists?)");
    if (o_.stale_mod == 0) die("--stale-sample must be > 0");
    uint8_t h[64] = {};
    std::memcpy(h, "RSYSSTL1", 8);
    const uint32_t node = o_.node, mod = o_.stale_mod;
    const uint64_t rb = sizeof(StaleRec);
    std::memcpy(h + 8, &node, 4), std::memcpy(h + 12, &mod, 4), std::memcpy(h + 16, &rb, 8);
    std::fwrite(h, 1, 64, stale_f_);
  }
  bool stale_sampled(uint64_t gslot) const { return stale_f_ && mix64(gslot ^ 0x57a1e5ull) % o_.stale_mod == 0; }
  void stale_add(uint64_t gslot, uint64_t seq, bool write) {
    thread_local StaleBuf *b = nullptr;
    if (!b) {
      std::lock_guard<std::mutex> g(stale_mu_);
      stale_bufs_.push_back(std::make_unique<StaleBuf>());
      b = stale_bufs_.back().get();
    }
    {
      std::lock_guard<std::mutex> l(b->mu);
      b->v.push_back(StaleRec{gslot, seq, real_ns()});
    }
    (write ? st_.stale_writes_logged : st_.stale_reads_logged)++;
    if (b->v.size() >= (1u << 16)) flush_stale_log();  // never unbounded between stats reads
  }

  // Record format: v6 (layout.h SlotView: key | emb fp32 | seq | csum) or v7 (emb_v7.h: key | seq | csum | acc | pad |
  // emb fp16/fp32). The csum covers (key, seq, emb bytes as u32 words) in both (v6: = row_csum over the floats).
  struct RecFmt {
    uint64_t key_off, seq_off, csum_off, acc_off, emb_off;
    uint32_t elt, emb_bytes, ewords;
    explicit RecFmt(const Params &p) {
      elt = p.v7_elt ? p.v7_elt : 4;
      emb_bytes = p.dim * elt, ewords = emb_bytes / 4;
      if (p.v7_elt) key_off = RecOff::key, seq_off = RecOff::seq, csum_off = RecOff::csum, acc_off = RecOff::acc,
                    emb_off = RecOff::emb;
      else {
        const SlotView v(p);
        key_off = v.key_off, seq_off = v.seq_off, csum_off = v.csum_off, acc_off = ~0ull, emb_off = v.emb_off;
      }
    }
  };
  // Image file (--image): node 0 copies it into the tables at prepare; checked against the derived layout in main().
  void load_image_tables() {
    const RecFmt f(p_);
    const int fd = ::open(o_.image.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) die("--image " + o_.image + ": open");
    ImageHeader ih{};
    if (pread(fd, &ih, sizeof ih, 0) != ssize_t(sizeof ih)) die("--image: header");
    const uint64_t t0 = now_ns(), rb = p_.slot_bytes;
    std::atomic<uint64_t> next{0}, bad{0};
    const float acc = float(o_.acc_init);
    auto fix = [&](uint8_t *rec, uint32_t k, uint64_t r) {  // check the key, apply --acc-init (acc is not in the csum)
      uint64_t key;
      std::memcpy(&key, rec + f.key_off, 8);
      if (key != Params::key(k, r)) bad++;
      if (o_.acc_init >= 0) std::memcpy(rec + f.acc_off, &acc, 4);
    };
    auto rd = [&](uint8_t *dst, uint64_t row0, uint64_t n) {
      uint64_t got = 0, len = n * rb, off = ih.data_off + row0 * rb;
      while (got < len) {
        const ssize_t x = pread(fd, dst + got, len - got, off + got);
        if (x <= 0) die("--image: read");
        got += uint64_t(x);
      }
      posix_fadvise(fd, off, len, POSIX_FADV_DONTNEED);  // 61 GiB never stays in the page cache
    };
    if constexpr (!Be::kAppSeqlock) {
      // Megalon: one write section per object; rows read straight into the object in 16 MiB pieces
      const uint64_t nobj = be_->objects(), piece = std::max<uint64_t>(1, (16ull << 20) / rb);
      const std::vector<uint64_t> &ob = be_->obj_base();
      pool_.run([&](int) {
        for (;;) {
          const uint64_t g = next.fetch_add(1);
          if (g >= nobj) break;
          uint32_t k = 0;
          while (k + 1 < kSparse && ob[k + 1] <= g) k++;
          const uint64_t ch = g - ob[k], r0 = be_->first_row(k, ch), n = be_->object_rows(k, ch);
          be_->write_object(k, ch, [&](uint8_t *obj) {
            for (uint64_t i = 0; i < n; i += piece) {
              const uint64_t m = std::min(piece, n - i);
              rd(obj + i * rb, p_.row_base[k] + r0 + i, m);
              for (uint64_t x = 0; x < m; x++) fix(obj + (i + x) * rb, k, r0 + i + x);
            }
          });
        }
      });
    } else {
      pool_.run([&](int) {
        std::vector<uint8_t> buf(4096 * rb);
        for (;;) {
          const uint64_t c = next.fetch_add(4096);
          if (c >= p_.total_rows) break;
          const uint64_t e = std::min(p_.total_rows, c + 4096);
          rd(buf.data(), c, e - c);
          uint32_t k = 0;
          for (uint64_t g = c; g < e; g++) {
            while (k + 1 < kSparse && p_.row_base[k + 1] <= g) k++;
            uint8_t *rec = buf.data() + (g - c) * rb;
            fix(rec, k, g - p_.row_base[k]);
            be_->write_slot(k, g - p_.row_base[k], [&](uint8_t *dst) { std::memcpy(dst, rec, rb); });
          }
        }
      });
    }
    close(fd);
    if (bad) die("--image: " + std::to_string(bad.load()) + " records with a wrong key");
    std::fprintf(stderr, "recsys-server: initial tables from image %s: %lu rows, %.1f GiB in %.1f s (acc_init %s)\n",
                 o_.image.c_str(), (unsigned long)p_.total_rows, p_.swcc_bytes() / 1073741824.0, (now_ns() - t0) / 1e9,
                 o_.acc_init < 0 ? "image" : std::to_string(o_.acc_init).c_str());
  }
  // Stream mode: what a run needs to be judged (achieved update rate, lag not growing; DESIGN.md §5.1). Rates follow
  // from deltas of two snapshots (stats_mono_ns). update_lag_ns_* = acceptance (frame read) to the owning worker's rows
  // written, per (sample, worker); _max is reset by every stats read (one reader per node: the loadgen snapshots).
  std::string stream_text() {
    if (!o_.stream) return "";
    std::ostringstream o;
    const uint64_t acc = st_.accepted_seq.load(), pub = load_acquire(&h_->nodes[o_.node].published_seq);
    o << "\nupdate_mode=stream\nstats_mono_ns=" << now_ns() << "\nupdate_accepted_seq=" << acc
      << "\nupdate_lag_samples=" << (acc > pub ? acc - pub : 0) << "\nupdate_lag_ns_sum=" << st_.lag_ns_sum
      << "\nupdate_lag_n=" << st_.lag_n << "\nupdate_lag_ns_max=" << st_.lag_ns_max.exchange(0);
    if (uq_ && !o_.train)
      for (uint32_t w = 0; w < o_.update_threads; w++) o << "\nupdate_queue.w" << w << "=" << uq_[w].size();
    if (gq_ && o_.train) {  // v7: samples waiting for a trainer; gradient batches waiting for each row owner
      o << "\nupdate_queue.train=" << tq_.size();
      for (uint32_t w = 0; w < o_.update_threads; w++) o << "\nupdate_queue.w" << w << "=" << gq_[w].size();
    }
    return o.str();
  }
  std::string op_text() const {
    std::ostringstream o;
    st_.op_query.text(o, "query");
    st_.op_row_update.text(o, "row_update");
    if (win_on()) st_.op_publish.text(o, "publish");  // publisher: one op per row written to shared memory
    return o.str();
  }
  void coh_init() {  // on the worker thread itself, after the backend registered it
    tcoh_.init(be_->coh_fn(), be_->anchor_fn());
    if (tcoh_.pc) st_.coh_pc_threads++;
    if (tcoh_.mg) st_.coh_mg_threads++;
  }
  static inline thread_local ThreadCoh tcoh_;
  static uint64_t status_kb(const char *field) {  // /proc/self/status VmRSS/VmHWM (Megalon's replicated index is here)
    std::istringstream in(cxl::proc::slurp("/proc/self/status", 1 << 16));
    std::string k;
    uint64_t v = 0;
    while (in >> k)
      if (k == field && (in >> v)) return v;
    return 0;
  }
  uint8_t *map_device() {
    int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    close(fd);
    return static_cast<uint8_t *>(m);
  }

  // ---------------------------------------------------------------- initial tables (node 0, prepare, unmeasured)
  // Direct addressing (every system, user decision 2026-10-18): row r of table k is record row_base[k] + r (plain:
  // that offset in SWcc; Megalon: the object (k, r)). Every row written once with seq 0. Deterministic.
  void write_tables() {
    if (!o_.image.empty()) return load_image_tables();  // v7: the converted checkpoint instead of synthetic rows
    const uint64_t t0 = now_ns();
    std::atomic<uint64_t> next{0};
    if constexpr (!Be::kAppSeqlock) {
      // Megalon: one write section per object writing all of its rows (no chunking needed: the section's pointer
      // covers the whole object; write_end flushes the whole object). Threads claim batches of global object indices
      // (4096 rows' worth, at least one object; N = 1: 4096 objects = rows, as before). Per-object time is logged for
      // objects >= 1 GiB (the whole-object write_end of a multi-GB object, DESIGN.md §7).
      const uint64_t rpo = be_->rows_per_object_opt();
      const uint64_t batch = rpo ? std::max<uint64_t>(1, 4096 / rpo) : 1, nobj = be_->objects();
      const std::vector<uint64_t> &ob = be_->obj_base();
      pool_.run([&](int) {
        std::vector<uint8_t> buf(p_.slot_bytes);
        for (;;) {
          const uint64_t c = next.fetch_add(batch);
          if (c >= nobj) break;
          const uint64_t e = std::min(nobj, c + batch);
          uint32_t k = 0;
          for (uint64_t g = c; g < e; g++) {
            while (k + 1 < kSparse && ob[k + 1] <= g) k++;
            const uint64_t ch = g - ob[k], r0 = be_->first_row(k, ch), n = be_->object_rows(k, ch);
            const uint64_t w0 = now_ns();
            uint64_t w1 = 0;
            be_->write_object(k, ch, [&](uint8_t *obj) {
              for (uint64_t i = 0; i < n; i++) {
                make_slot(p_, Params::key(k, r0 + i), 0, buf.data());
                std::memcpy(obj + i * p_.slot_bytes, buf.data(), p_.slot_bytes);
              }
              w1 = now_ns();
            });
            if (n * p_.slot_bytes >= (1ull << 30))
              std::fprintf(stderr, "recsys-server: initial object table %u chunk %lu: %lu rows %.2f GiB, fill %.2f s, "
                                   "write_end (whole-object flush + unlock) %.2f s\n",
                           k, (unsigned long)ch, (unsigned long)n, n * p_.slot_bytes / 1073741824.0, (w1 - w0) / 1e9,
                           (now_ns() - w1) / 1e9);
          }
        }
      });
    } else {
    pool_.run([&](int) {
        std::vector<uint8_t> buf(p_.slot_bytes);
        for (;;) {
          const uint64_t c = next.fetch_add(4096);
          if (c >= p_.total_rows) break;
          const uint64_t e = std::min(p_.total_rows, c + 4096);
          uint32_t k = 0;
          for (uint64_t g = c; g < e; g++) {
            while (k + 1 < kSparse && p_.row_base[k + 1] <= g) k++;
            const uint64_t r = g - p_.row_base[k];
            make_slot(p_, Params::key(k, r), 0, buf.data());
            be_->write_slot(k, r, [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
          }
        }
      });
    }
    std::fprintf(stderr, "recsys-server: initial tables: %lu rows (%s), write %.1f s (%.1f GiB)\n",
                 (unsigned long)p_.total_rows, be_->name().c_str(), (now_ns() - t0) / 1e9,
                 p_.swcc_bytes() / 1073741824.0);
  }

  void load_initial() {
    std::string err;
    const uint64_t t0 = now_ns();
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      if (!be_->create_objects(&err, [this](std::function<void(int)> f) { pool_.run(std::move(f)); })) die(err);
      std::fprintf(stderr, "recsys-server: created %lu objects in %.1f s\n", (unsigned long)be_->objects(),
                   (now_ns() - t0) / 1e9);
    }
    if (o_.preloaded) {
      std::fprintf(stderr, "recsys-server: tables preloaded (--preloaded), not written again\n");
      return;
    }
    write_tables();
  }

  // Read every slot once (every node, before READY; identical in every system), so measurements do not include the
  // first touch of shared pages. Also checks that every occupied slot is intact.
  void warm_up() {
    const uint64_t t0 = now_ns();
    std::atomic<uint64_t> next{0}, occupied{0}, bad{0};
    const RecFmt v(p_);
    const uint64_t total = p_.total_rows;  // every row is a record and must hold its own key
    const std::vector<uint64_t> &base = p_.row_base;
    pool_.run([&](int) {
        std::vector<uint8_t> e(v.emb_bytes);
        for (;;) {
          const uint64_t c = next.fetch_add(4096);
          if (c >= total) break;
          const uint64_t end = std::min(total, c + 4096);
          uint32_t k = 0;
          for (uint64_t g = c; g < end; g++) {
            while (k + 1 < kSparse && base[k + 1] <= g) k++;
            const uint64_t i = g - base[k];
            const int r = be_->read_slot(k, i, [&](const uint8_t *s) {
              uint64_t key, seq;
              uint32_t cs;
              std::memcpy(&key, s + v.key_off, 8);
              if (!key) return 0;
              if (key != Params::key(k, i)) return 2;
              std::memcpy(&seq, s + v.seq_off, 8);
              std::memcpy(&cs, s + v.csum_off, 4);
              std::memcpy(e.data(), s + v.emb_off, v.emb_bytes);
              return row_csum_words(key, seq, e.data(), v.ewords) == cs ? 1 : 2;
            });
            if (r) occupied++;
            if (r == 2) bad++;
          }
        }
      });
    std::fprintf(stderr, "recsys-server: warm-up read %lu rows (%lu occupied, %lu bad) in %.1f s\n",
                 (unsigned long)total, (unsigned long)occupied.load(), (unsigned long)bad.load(),
                 (now_ns() - t0) / 1e9);
    if (occupied != p_.total_rows || bad) die("warm-up: table content does not match the initial load");
  }

  // ---------------------------------------------------------------- row access
  // Direct addressing: the key names its row (Params::key_row), so a lookup reads exactly one record (probes counts
  // record reads; probes = lookups). Consistency is each system's own mechanism:
  //   plain (Be::kAppSeqlock): MemC3-style optimistic reader (NSDI'13 §3.2.1) on the HWcc striped version table:
  //     v1 = counter of the key (even; spin while odd), copy the row, acquire fence, v2 == v1 or re-read. HWcc and
  //     Popcorn give coherence, not atomicity of a 9-line row copy. A retry is FALSE when the row itself was not
  //     rewritten: the discarded copy was consistent (csum) and the re-read has the same seq.
  //   Megalon: one read section; the backend repeats it until read_end accepts the copy (no application seqlock).
  // csum (--verify-rows) is the independent torn-row check in every system.
  struct Probe {
    uint64_t key;  // key found in the record
    uint64_t seq;
    uint32_t csum;
  };
  struct LookupCnt {
    uint64_t probes = 0, retries = 0, false_retries = 0, spins = 0, max_seq = 0;
  };
  uint32_t wait_even(const uint32_t *ver, LookupCnt *c) const {
    for (;;) {
      const uint32_t v = load_acquire(ver);
      if (!(v & 1) || o_.test_no_seqlock) return v;
      c->spins++;
      _mm_pause();
    }
  }
  // tmp receives the raw embedding bytes of the record (fp32 v6/v7-fp32, fp16 v7; fmt_.emb_bytes <= dim x 4)
  Probe read_probe(uint32_t k, uint64_t r, uint64_t key, float *tmp) const {
    const RecFmt &v = fmt_;
    return be_->read_slot(k, r, [&](const uint8_t *src) {
      Probe x{};
      x.key = __atomic_load_n(reinterpret_cast<const uint64_t *>(src + v.key_off), __ATOMIC_RELAXED);
      if (x.key == key) {
        std::memcpy(tmp, src + v.emb_off, v.emb_bytes);
        std::memcpy(&x.seq, src + v.seq_off, 8);
        std::memcpy(&x.csum, src + v.csum_off, 4);
      }
      return x;
    });
  }
  // Look up `key` in table k; on hit, adds the row's embedding into acc[dim]. Returns false on a miss (a key out of
  // range or a record holding another key; cannot happen after a complete initial load, warm-up checks every key).
  // log_stale: serving lookups of sampled rows go to the stale-read log (v7); the trainer's reads do not.
  bool lookup(uint32_t k, uint64_t key, float *acc, float *tmp, LookupCnt *c, bool log_stale = false) {
    const uint64_t r = Params::key_row(key);
    if (r >= p_.rows[k]) return false;
    Probe pr;
    if constexpr (Be::kAppSeqlock) {
      const uint32_t *ver = &h_->ver[p_.stripe(key)];
      uint32_t v1 = wait_even(ver, c);
      pr = read_probe(k, r, key, tmp);
      c->probes++;
      if (pr.key != key) return false;
      for (;;) {
        std::atomic_thread_fence(std::memory_order_acquire);
        if (o_.test_no_seqlock || load_relaxed(ver) == v1) break;   // v2 == v1: copy is consistent
        c->retries++;
        const bool consistent = row_csum_words(key, pr.seq, tmp, fmt_.ewords) == pr.csum;
        const uint64_t seq0 = pr.seq;
        v1 = wait_even(ver, c);
        pr = read_probe(k, r, key, tmp);
        if (consistent && pr.seq == seq0) c->false_retries++;
      }
    } else {
      pr = read_probe(k, r, key, tmp);
      c->probes++;
      if (pr.key != key) return false;
    }
    if (o_.verify_rows && row_csum_words(key, pr.seq, tmp, fmt_.ewords) != pr.csum) st_.torn++;
    if (fmt_.elt == 4 && !p_.v7_elt) {
      for (uint32_t j = 0; j < p_.dim; j++) acc[j] += tmp[j];  // sum pooling into x0 (v6 loop, unchanged)
    } else {
      emb_to_f32(tmp, fmt_.elt, p_.dim, acc, true);  // v7: sum pooling of the record's precision
    }
    if (pr.seq > c->max_seq) c->max_seq = pr.seq;
    if (log_stale && stale_sampled(p_.row_base[k] + r)) stale_add(p_.row_base[k] + r, pr.seq, false);
    return true;
  }
  // Writer: CAS even -> odd on the row's stripe (MemC3), write the row, release-store +2. Rows are owned by
  // stripe % U, so update workers never share a counter; the CAS still guards against any other writer.
  uint32_t lock_stripe(uint32_t *ver) {
    for (;;) {
      uint32_t v = load_relaxed(ver);
      if (!(v & 1) && cxl::hwcc::cas(ver, &v, v + 1)) return v;
      st_.lock_spins++;
      _mm_pause();
    }
  }

  // ---------------------------------------------------------------- updater (node 0)
  // T > 0 (Monolith §2.2.3 touched-key push, Ekko rates; DESIGN.md §5): every worker sees every sample in time order
  // and records the rows it owns (owner(): plain stripe % U == w, Megalon object % U == w) in a private map key ->
  // latest seq (latest wins); no shared memory
  // is read or written per sample, and the sample is acknowledged on acceptance (workers never wait for each other).
  // Every T the worker publishes its touched rows once: each row's record follows from its key (no probe), written
  // under its stripe (plain) or, per owned object, in one write section with all touched rows of that object (Megalon;
  // the app's own publication batch, Monolith touched-key push). A round longer than T is an overrun ("update rate not sustained"); the next round starts at the next
  // multiple of T after it (never bursted). T = 0 (diagnostic): every sample's rows are written before the reply.
  struct UpdJob {
    Job job;
    Sample s;
    uint64_t seq, t_arr;
    std::atomic<uint32_t> left;
  };
  struct Touched {
    uint64_t gslot;  // global record index row_base[k] + row: sort key (SWcc address order on plain)
    uint64_t key, seq;
    uint32_t k;
  };

  void dispatch_update(Job j) {
    if (frame::payload_len(j.h) != sizeof(UpdateReq) + sizeof(Sample)) return bad(j);
    auto u = std::make_shared<UpdJob>();
    UpdateReq rq;
    std::memcpy(&rq, j.p.data(), sizeof(rq));
    std::memcpy(&u->s, j.p.data() + sizeof(rq), sizeof(Sample));
    if (rq.seq == 0) return bad(j);
    u->seq = rq.seq;
    u->t_arr = j.t_arr;
    u->left = o_.update_threads;
    if (o_.publish_us || o_.stream) {  // accepted: reply now (workers are independent)
      st_.samples++;
      uint64_t a = st_.accepted_seq.load();
      while (rq.seq > a && !st_.accepted_seq.compare_exchange_weak(a, rq.seq)) {
      }
      UpdateResp r{u->seq, load_acquire(&h_->nodes[o_.node].published_seq)};
      j.c->reply(frame::kStatusOk, j.h.req_id, &r, sizeof(r));
    } else {
      u->job = std::move(j);
    }
    if (o_.train) {  // v7: one training queue in seq order (the ordered update stream); trainers take batches
      if (win_on() && !win_t0_.load(std::memory_order_relaxed)) {  // window 0 starts at the first update sample
        uint64_t z = 0;
        win_t0_.compare_exchange_strong(z, u->t_arr);
      }
      const uint64_t q = tq_.push_size(u);
      uint64_t m = st_.uq_max.load();
      while (q > m && !st_.uq_max.compare_exchange_weak(m, q)) {
      }
      return;
    }
    for (uint32_t w = 0; w < o_.update_threads; w++) {
      const uint64_t q = uq_[w].push_size(u);
      uint64_t m = st_.uq_max.load();
      while (q > m && !st_.uq_max.compare_exchange_weak(m, q)) {
      }
    }
  }

  // rows: sorted by gslot, resolved. Plain: one stripe hold per row. Megalon: one write section per object holding
  // all of this batch's rows of that object in address order (the write section locks and versions the object
  // itself; write_end flushes the whole object); N = 1: one section per row, as before.
  void write_rows(const std::vector<Touched> &rows, std::vector<uint8_t> &buf) {
    const uint64_t t0 = now_ns();
    buf.resize(p_.slot_bytes);
    uint64_t sections = 0;  // Megalon write sections of this batch, counted after the rows (below)
    if constexpr (!Be::kAppSeqlock) {
      for (size_t i = 0; i < rows.size();) {
        const uint32_t k = rows[i].k;
        const uint64_t c = be_->chunk_of(k, rows[i].gslot - p_.row_base[k]);
        size_t j = i + 1;
        while (j < rows.size() && rows[j].k == k && be_->chunk_of(k, rows[j].gslot - p_.row_base[k]) == c) j++;
        be_->write_object(k, c, [&](uint8_t *obj) {
          for (size_t x = i; x < j; x++) {
            make_slot(p_, rows[x].key, rows[x].seq, buf.data());
            std::memcpy(obj + be_->row_offset(k, rows[x].gslot - p_.row_base[k]), buf.data(), p_.slot_bytes);
          }
        });
        sections++;
        i = j;
      }
    } else {
      for (const Touched &t : rows) {
        make_slot(p_, t.key, t.seq, buf.data());
        uint32_t *ver = &h_->ver[p_.stripe(t.key)];
        const uint32_t v = lock_stripe(ver);
        be_->write_slot(t.k, t.gslot - p_.row_base[t.k], [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
        store_release(ver, v + 2);
      }
    }
    st_.write_ns += now_ns() - t0;
    st_.rows_written += rows.size();
    st_.update_sections += sections;  // not atomic with rows_written: a snapshot during a round may see sections > rows
    __atomic_fetch_add(&h_->nodes[o_.node].rows_written, uint64_t(rows.size()), __ATOMIC_RELAXED);
  }
  // key -> resolved row (direct: table and row from the key); false on a miss (counted)
  bool resolve(uint64_t key, uint64_t seq, Touched *t) {  // key -> its row (direct addressing, no probe)
    const uint32_t k = Params::key_table(key);
    const uint64_t r = Params::key_row(key);
    if (r >= p_.rows[k]) return st_.update_misses++, false;
    *t = Touched{p_.row_base[k] + r, key, seq, k};
    return true;
  }


  // Update worker owning a row: plain stripe(key) % U (unchanged); Megalon gobj(object) % U, because Megalon allows
  // one writer per object (N = 0: table k % U, at most 26 owners).
  uint32_t owner(uint32_t k, uint64_t key) const {
    if constexpr (Be::kAppSeqlock) return p_.stripe(key) % o_.update_threads;
    else return uint32_t(be_->gobj(k, be_->chunk_of(k, Params::key_row(key))) % o_.update_threads);
  }

  void publish() {  // published_seq = min over workers (single node-0 field, raised by CAS)
    uint64_t m = ~0ull;
    for (uint32_t w = 0; w < o_.update_threads; w++) m = std::min<uint64_t>(m, done_seq_[w].load());
    uint64_t *f = &h_->nodes[o_.node].published_seq, cur = load_acquire(f);
    while (cur < m && !cxl::hwcc::cas(f, &cur, m)) {
    }
  }

  void updater(uint32_t w) {
    be_->thread_init(int(1 + o_.load_threads + w), kRoleUpdate);
    cxl::proc::name_thread("rs-update");
    coh_init();
    OpTimer ot(&tcoh_);
    std::unordered_map<uint64_t, uint64_t> touched;  // T > 0: key -> latest seq in this interval
    touched.reserve(1 << 16);
    std::vector<Touched> rows;
    std::vector<uint8_t> buf;
    uint64_t accepted = 0, round = 0;
    const uint64_t T = o_.publish_us * 1000;
    const uint64_t t_start = now_ns();
    uint64_t next_flush = T ? t_start + T : 0;
    for (;;) {
      std::shared_ptr<UpdJob> u;
      const bool got = uq_[w].pop(&u, next_flush);
      if (T && now_ns() >= next_flush) {  // publication round: write every touched row once
        const uint64_t f0 = now_ns();
        ot.begin();
        rows.clear();
        Touched t;
        for (auto &kv : touched)
          if (resolve(kv.first, kv.second, &t)) rows.push_back(t);
        touched.clear();
        std::sort(rows.begin(), rows.end(), [](const Touched &a, const Touched &b) { return a.gslot < b.gslot; });
        write_rows(rows, buf);
        done_seq_[w] = accepted;
        publish();
        ot.end(&st_.op_row_update, rows.size());  // T: round start .. rows visible (published_seq raised)
        const uint64_t d = now_ns() - f0;
        st_.flushes++;
        st_.flush_ns += d;
        st_.round_rows += rows.size();
        uint64_t mx = st_.flush_ns_max.load();
        while (d > mx && !st_.flush_ns_max.compare_exchange_weak(mx, d)) {
        }
        mx = st_.round_rows_max.load();
        while (rows.size() > mx && !st_.round_rows_max.compare_exchange_weak(mx, rows.size())) {
        }
        const bool over = d > T;
        if (over) st_.flush_overruns++;
        if (w == 0) {
          st_.publish_rounds++;
          __atomic_fetch_add(&h_->nodes[o_.node].flushes, uint64_t(1), __ATOMIC_RELAXED);
        }
        if (T >= 1000000000ull)
          std::fprintf(stderr, "recsys-server: round w=%u r=%lu rows=%zu ms=%.1f%s published_seq=%lu\n", w,
                       (unsigned long)round, rows.size(), d / 1e6, over ? " OVERRUN (update rate not sustained)" : "",
                       (unsigned long)accepted);
        round++;
        next_flush += T;
        if (next_flush <= now_ns()) next_flush = t_start + ((now_ns() - t_start) / T + 1) * T;  // overrun: skip
      }
      if (!got) continue;
      const uint64_t a0 = tsc();
      if (T) {
        for (uint32_t k = 0; k < kSparse; k++)
          for (uint32_t j = 0; j < p_.hot[k]; j++) {
            const uint64_t key = Params::key(k, p_.row_of(k, u->s, j));
            if (owner(k, key) != w) continue;
            st_.rows_touched++;
            touched.insert_or_assign(key, u->seq);  // latest wins
          }
        accepted = u->seq;
        st_.accum_cyc += tsc() - a0;
        continue;
      }
      // T = 0: write this sample's rows now (deduplicated), reply when every worker is done (stream mode: the sample
      // was acknowledged on acceptance; record this worker's lag instead)
      ot.begin();
      rows.clear();
      Touched t;
      for (uint32_t k = 0; k < kSparse; k++)
        for (uint32_t j = 0; j < p_.hot[k]; j++) {
          const uint64_t key = Params::key(k, p_.row_of(k, u->s, j));
          if (owner(k, key) != w) continue;
          st_.rows_touched++;
          if (resolve(key, u->seq, &t)) rows.push_back(t);
        }
      std::sort(rows.begin(), rows.end(), [](const Touched &a, const Touched &b) { return a.gslot < b.gslot; });
      rows.erase(std::unique(rows.begin(), rows.end(), [](const Touched &a, const Touched &b) { return a.gslot == b.gslot; }),
                 rows.end());
      write_rows(rows, buf);
      accepted = u->seq;
      done_seq_[w] = accepted;
      publish();
      ot.end(&st_.op_row_update, rows.size());  // before the reply (send excluded from T)
      if (o_.stream) {
        const uint64_t lag = now_ns() - u->t_arr;
        st_.lag_ns_sum += lag, st_.lag_n++;
        uint64_t mx = st_.lag_ns_max.load();
        while (lag > mx && !st_.lag_ns_max.compare_exchange_weak(mx, lag)) {
        }
        continue;
      }
      if (u->left.fetch_sub(1) == 1) {
        st_.samples++;
        UpdateResp r{u->seq, load_acquire(&h_->nodes[o_.node].published_seq)};
        u->job.c->reply(frame::kStatusOk, u->job.h.req_id, &r, sizeof(r));
      }
    }
  }

  // ---------------------------------------------------------------- v7 online training (node 0; DESIGN.md §10.6)
  // Trainers (--train-threads, default U): take queued update samples in seq order in batches of up to --train-batch
  // (no waiting for a full batch), read the rows through the coherent lookup path (lookup(), as serving: plain = MemC3
  // reader, Megalon = read sections), forward + backward through the frozen dense part (BCE, mean over the batch),
  // per row the summed gradient of its lookups (sum pooling); then every row owner (owner(), as in stream mode) gets
  // its rows of the batch (possibly none). Owners: read-modify-write of each row (emb + acc + seq + csum) in the
  // system's write path (plain: under the row's stripe; Megalon: one write section per touched object), row-wise
  // Adagrad (emb_v7.h). Test-then-train: serving never sees a sample before node 0 got it (loadgen query window).
  // published_seq = last sample of the longest prefix of batches whose rows every owner has written (ledger_); row
  // seq = last sample seq of the batch that wrote it.
  struct GradJob {
    uint64_t batch = 0, seq = 0, t_arr = 0;  // batch id (seq order), last sample seq, earliest acceptance time
    std::vector<Touched> rows;               // this owner's rows, gslot order
    std::vector<float> g;                    // rows.size() x dim summed gradients
  };
  struct Led {
    uint64_t seq;
    uint32_t left;
  };

  void trainer(uint32_t i) {
    be_->thread_init(int(1 + o_.load_threads + o_.update_threads + o_.serve_threads + i), kRoleUpdate);
    cxl::proc::name_thread("rs-train");
    coh_init();
    const uint32_t B = o_.train_batch, D = model_.spec().inter(), dim = p_.dim, U = o_.update_threads;
    Model::Scratch sc;
    Model::Train tr;
    model_.scratch(&sc, B);
    model_.train_scratch(&tr, B);
    std::vector<float> dense(size_t(B) * kDense), score(B), dz(B), tmp(dim);
    std::vector<std::shared_ptr<UpdJob>> jobs;
    struct Ent {
      uint64_t gslot;
      uint32_t slot;  // batch row * 26 + table
    };
    std::vector<Ent> ent;
    for (;;) {
      jobs.clear();
      uint64_t batch, seq;
      {
        std::lock_guard<std::mutex> g(tmu_);  // batches are formed and numbered in seq order
        std::shared_ptr<UpdJob> u;
        tq_.pop(&u, 0);
        jobs.push_back(std::move(u));
        while (jobs.size() < B && tq_.pop(&u, 1)) jobs.push_back(std::move(u));  // deadline 1 ns: no waiting
        batch = next_batch_++;
        seq = jobs.back()->seq;
        std::lock_guard<std::mutex> l(lmu_);
        ledger_[batch] = Led{seq, U};
      }
      const uint64_t c0 = thread_cpu_ns();
      const uint32_t m = uint32_t(jobs.size());
      for (uint32_t r = 0; r < m; r++) std::memcpy(&dense[size_t(r) * kDense], jobs[r]->s.dense, kDense * 4);
      model_.bottom(dense.data(), m, &sc);
      LookupCnt lc;
      ent.clear();
      uint64_t looks = 0;
      for (uint32_t r = 0; r < m; r++) {
        const Sample &smp = jobs[r]->s;
        for (uint32_t k = 0; k < kSparse; k++) {
          float *acc = &sc.x0[size_t(r) * D + size_t(k + 1) * dim];
          std::memset(acc, 0, size_t(dim) * 4);
          for (uint32_t j = 0; j < p_.hot[k]; j++) {
            const uint64_t row = p_.row_of(k, smp, j);
            looks++;
            if (train_lookup(k, Params::key(k, row), acc, tmp.data(), &lc)) ent.push_back(Ent{p_.row_base[k] + row, r * kSparse + k});
            else st_.update_misses++;
          }
        }
      }
      model_.top_train(m, &sc, &tr, score.data());
      for (uint32_t r = 0; r < m; r++) dz[r] = (score[r] - float(jobs[r]->s.label)) / float(m);  // dBCE/dlogit, mean
      const uint64_t c1 = thread_cpu_ns();
      const float *gx = model_.backward(m, &tr, dz.data());
      const uint64_t c2 = thread_cpu_ns();
      std::sort(ent.begin(), ent.end(), [](const Ent &a, const Ent &b) { return a.gslot < b.gslot; });
      std::vector<std::shared_ptr<GradJob>> out(U);
      for (uint32_t w = 0; w < U; w++) {
        out[w] = std::make_shared<GradJob>();
        out[w]->batch = batch, out[w]->seq = seq, out[w]->t_arr = jobs[0]->t_arr;
      }
      uint64_t nrows = 0;
      for (size_t x = 0; x < ent.size();) {
        const uint64_t gs = ent[x].gslot;
        const uint32_t k = ent[x].slot % kSparse;
        const uint64_t key = Params::key(k, gs - p_.row_base[k]);
        GradJob &gj = *out[owner(k, key)];
        gj.rows.push_back(Touched{gs, key, seq, k});
        const size_t o0 = gj.g.size();
        gj.g.resize(o0 + dim, 0.f);
        for (; x < ent.size() && ent[x].gslot == gs; x++) {
          const float *g = gx + size_t(ent[x].slot / kSparse) * D + size_t(ent[x].slot % kSparse + 1) * dim;
          for (uint32_t c = 0; c < dim; c++) gj.g[o0 + c] += g[c];
        }
        nrows++;
      }
      st_.seq_spins += lc.spins;
      st_.train_samples += m, st_.train_batches++, st_.train_lookups += looks, st_.grad_rows += nrows;
      st_.train_fwd_ns += c1 - c0, st_.train_bwd_ns += c2 - c1;
      st_.train_cpu_ns += thread_cpu_ns() - c0;
      for (uint32_t w = 0; w < U; w++) gq_[w].push(std::move(out[w]));
    }
  }

  // One row update in a private copy of the record (rec, slot_bytes): Adagrad on the fp32 row, stored back in the
  // record precision; seq = the batch's last sample; csum over the new (key, seq, emb).
  void rmw_record(uint8_t *rec, const float *g, uint64_t key, uint64_t seq, float *w) {
    const RecFmt &f = fmt_;
    float acc;
    std::memcpy(&acc, rec + f.acc_off, 4);
    emb_to_f32(rec + f.emb_off, f.elt, p_.dim, w, false);
    rowwise_adagrad(w, &acc, g, p_.dim, o_.ada);
    f32_to_emb(w, f.elt, p_.dim, rec + f.emb_off);
    std::memcpy(rec + f.acc_off, &acc, 4);
    std::memcpy(rec + f.seq_off, &seq, 8);
    const uint32_t cs = row_csum_words(key, seq, rec + f.emb_off, f.ewords);
    std::memcpy(rec + f.csum_off, &cs, 4);
  }

  void owner(uint32_t w) {
    be_->thread_init(int(1 + o_.load_threads + w), kRoleUpdate);
    cxl::proc::name_thread("rs-update");
    coh_init();
    OpTimer ot(&tcoh_);
    const uint32_t dim = p_.dim;
    std::vector<float> wv(dim);
    std::vector<uint8_t> buf(p_.slot_bytes);
    // Every owner gets every batch (possibly empty) and applies them in batch order (= seq order), although several
    // trainers may finish out of order: row seqs then only grow, and a row's history is the sample order.
    std::map<uint64_t, std::shared_ptr<GradJob>> pend;
    uint64_t want = 0;
    for (;;) {
      if (pend.empty() || pend.begin()->first != want) {
        std::shared_ptr<GradJob> in;
        gq_[w].pop(&in, 0);
        const uint64_t b = in->batch;
        pend.emplace(b, std::move(in));
        continue;
      }
      std::shared_ptr<GradJob> jp = std::move(pend.begin()->second);
      pend.erase(pend.begin());
      want++;
      const GradJob &j = *jp;
      const uint64_t c0 = thread_cpu_ns(), t0 = now_ns();
      ot.begin();
      uint64_t sections = 0, bad_key = 0;
      if (win_on()) {
        bad_key = dram_apply(w, j, wv.data());  // windowed publication: DRAM copy only, no shared-memory write
      } else if constexpr (!Be::kAppSeqlock) {
        for (size_t i = 0; i < j.rows.size();) {
          const uint32_t k = j.rows[i].k;
          const uint64_t c = be_->chunk_of(k, j.rows[i].gslot - p_.row_base[k]);
          size_t e = i + 1;
          while (e < j.rows.size() && j.rows[e].k == k && be_->chunk_of(k, j.rows[e].gslot - p_.row_base[k]) == c) e++;
          be_->write_object(k, c, [&](uint8_t *obj) {
            for (size_t x = i; x < e; x++) {
              uint8_t *rec = obj + be_->row_offset(k, j.rows[x].gslot - p_.row_base[k]);
              std::memcpy(buf.data(), rec, p_.slot_bytes);
              uint64_t key;
              std::memcpy(&key, buf.data() + fmt_.key_off, 8);
              if (key != j.rows[x].key) { bad_key++; continue; }
              rmw_record(buf.data(), &j.g[x * dim], key, j.seq, wv.data());
              std::memcpy(rec, buf.data(), p_.slot_bytes);
            }
          });
          sections++;
          for (size_t x = i; x < e; x++)  // visible after write_end
            if (stale_sampled(j.rows[x].gslot)) stale_add(j.rows[x].gslot, j.seq, true);
          i = e;
        }
      } else {
        for (size_t x = 0; x < j.rows.size(); x++) {
          const Touched &t = j.rows[x];
          const uint64_t r = t.gslot - p_.row_base[t.k];
          uint32_t *ver = &h_->ver[p_.stripe(t.key)];
          const uint32_t v = lock_stripe(ver);
          be_->read_slot(t.k, r, [&](const uint8_t *src) { std::memcpy(buf.data(), src, p_.slot_bytes); });
          uint64_t key;
          std::memcpy(&key, buf.data() + fmt_.key_off, 8);
          if (key == t.key) {
            rmw_record(buf.data(), &j.g[x * dim], key, j.seq, wv.data());
            be_->write_slot(t.k, r, [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
          } else {
            bad_key++;
          }
          store_release(ver, v + 2);
          if (stale_sampled(t.gslot)) stale_add(t.gslot, j.seq, true);
        }
      }
      st_.write_ns += now_ns() - t0;
      st_.rows_written += j.rows.size() - bad_key;
      st_.update_misses += bad_key;
      st_.update_sections += sections;
      __atomic_fetch_add(&h_->nodes[o_.node].rows_written, uint64_t(j.rows.size() - bad_key), __ATOMIC_RELAXED);
      batch_done(j.batch);
      ot.end(&st_.op_row_update, j.rows.size());  // RMW of this owner's rows .. published_seq raised
      st_.owner_cpu_ns += thread_cpu_ns() - c0;
      const uint64_t lag = now_ns() - j.t_arr;
      st_.lag_ns_sum += lag, st_.lag_n++;
      uint64_t mx = st_.lag_ns_max.load();
      while (lag > mx && !st_.lag_ns_max.compare_exchange_weak(mx, lag)) {
      }
    }
  }

  void batch_done(uint64_t b) {  // owner finished its part of batch b: advance published_seq over the done prefix
    uint64_t pub = 0;
    {
      std::lock_guard<std::mutex> l(lmu_);
      auto it = ledger_.find(b);
      if (it == ledger_.end() || --it->second.left) return;
      while (!ledger_.empty() && ledger_.begin()->first == next_pub_ && ledger_.begin()->second.left == 0) {
        pub = ledger_.begin()->second.seq;
        ledger_.erase(ledger_.begin());
        next_pub_++;
      }
    }
    if (!pub) return;
    uint64_t *f = &h_->nodes[o_.node].published_seq, cur = load_acquire(f);
    while (cur < pub && !cxl::hwcc::cas(f, &cur, pub)) {
    }
  }

  // ---------------------------------------------------------------- windowed publication (node 0, --publish-window-s W)
  // reports/experiments/recsys-windowed-update.md. DRAM copy: one DramMap per row owner w (owner(): the rows owner w
  // updates), written only by owner w (insert = first touch: the whole record, embedding + Adagrad acc + seq + csum,
  // copied from shared memory; update = row-wise Adagrad on the copy), read by the trainers (forward pass) and the
  // publisher through a per-entry seqlock. Index: open addressing keyed by the global row index (linear probing, no
  // deletes, load factor <= 1/2), one u64 per slot = (gslot + 1) << 32 | entry; entries are dense arrays (record,
  // version, window tag, last update time) mapped MAP_NORESERVE, so only used entries take memory.
  // Window w = [t0 + w W, t0 + (w + 1) W), t0 = arrival of the first update sample (window 0 = training only). D_w =
  // entries updated in window w (dedup by the window tag). At the end of w the publisher takes D_w from every owner under
  // the owner's mutex, which the owner holds for a whole batch, so every row update of w is complete before the
  // hand-over, and writes them during w + 1: row i of the list (owners interleaved) is due at boundary + i / b s,
  // b = ceil(|D_w| / W) rows per second (per-second budget, evenly spaced inside each second). Behind schedule: rows are
  // written as fast as possible in list order, none dropped; a later list is appended after the current one
  // (publish_backlog = due rows not yet written; publish_carryover_rows = rows still queued when a new list arrives).
  // Each write = the row's DRAM record at that moment (last write wins) through the backend's row write path (plain:
  // under the row's stripe like an owner write; Megalon: one write section on the row's object). In this mode the
  // publisher is the only writer of the tables in shared memory (Megalon: one writer per object holds).
  struct DramMap {
    uint64_t mask = 0, cap = 0;
    std::atomic<uint64_t> *idx = nullptr;   // index slots
    uint8_t *rec = nullptr;                 // cap x slot_bytes records
    std::atomic<uint32_t> *ver = nullptr;   // per entry seqlock (odd: owner writing)
    uint32_t *tag = nullptr;                // 1 + window of the entry's last D_w insertion (0 = none); owner only
    std::atomic<uint64_t> *t_upd = nullptr; // CLOCK_MONOTONIC ns of the entry's last update
    std::atomic<uint64_t> n{0};             // entries used
    std::mutex mu;                          // D_w hand-over
    uint32_t win = 0;                       // window the owner's updates belong to (advanced by the publisher, under mu)
    std::vector<uint32_t> d;                // D_win (entries)
  };
  static void *anon(uint64_t bytes) {
    void *p = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) die("windowed publication: mmap " + std::to_string(bytes) + " B");
    return p;
  }
  void dram_init() {
    if (p_.total_rows >= (1ull << 32) - 1) die("windowed publication: more than 2^32 - 2 rows");
    const uint64_t U = o_.update_threads;
    const uint64_t total = o_.dram_rows_cap ? o_.dram_rows_cap : std::min<uint64_t>(p_.total_rows, 48ull << 20);
    const uint64_t share = (total + U - 1) / U;  // owner() spreads rows evenly; + 25 % + 4096 headroom per owner
    const uint64_t cap = std::min<uint64_t>(p_.total_rows, share + share / 4 + 4096);
    uint64_t slots = 1;
    while (slots < 2 * cap) slots <<= 1;
    for (uint64_t w = 0; w < U; w++) {
      auto m = std::make_unique<DramMap>();
      m->cap = cap, m->mask = slots - 1;
      m->idx = static_cast<std::atomic<uint64_t> *>(anon(slots * 8));
      m->rec = static_cast<uint8_t *>(anon(cap * p_.slot_bytes));
      m->ver = static_cast<std::atomic<uint32_t> *>(anon(cap * 4));
      m->tag = static_cast<uint32_t *>(anon(cap * 4));
      m->t_upd = static_cast<std::atomic<uint64_t> *>(anon(cap * 8));
      dm_.push_back(std::move(m));
    }
    dram_cap_ = cap * U, dram_index_bytes_ = slots * 8 * U;
    std::fprintf(stderr, "recsys-server: windowed publication W=%u s: DRAM copy %lu owners x %lu rows (%u B record + 16 B "
                         "per row used; index %lu slots x 8 B per owner = %.1f MiB)\n",
                 o_.publish_window_s, (unsigned long)U, (unsigned long)cap, unsigned(p_.slot_bytes), (unsigned long)slots,
                 dram_index_bytes_ / 1048576.0);
  }
  uint64_t lag_bucket_ns() const { return std::max<uint64_t>(1, uint64_t(o_.publish_window_s) * 1000000000ull / 64); }
  static uint64_t dram_hash(uint64_t gslot) { return mix64(gslot ^ 0xd7a3c0b1e5ull); }
  int64_t dram_find(const DramMap &m, uint64_t gslot) const {
    const uint64_t want = gslot + 1;
    for (uint64_t i = dram_hash(gslot) & m.mask;; i = (i + 1) & m.mask) {
      const uint64_t v = m.idx[i].load(std::memory_order_acquire);
      if (!v) return -1;
      if (v >> 32 == want) return int64_t(v & 0xffffffffu);
    }
  }
  uint64_t dram_insert(DramMap &m, uint64_t gslot, const uint8_t *src) {  // owner only; src = the shared record copy
    const uint64_t want = gslot + 1;
    uint64_t i = dram_hash(gslot) & m.mask;
    for (uint64_t v; (v = m.idx[i].load(std::memory_order_relaxed)); i = (i + 1) & m.mask)
      if (v >> 32 == want) return v & 0xffffffffu;
    const uint64_t e = m.n.load(std::memory_order_relaxed);
    if (e >= m.cap)
      die("windowed publication: DRAM copy of an owner full (" + std::to_string(m.cap) + " rows; raise --publish-dram-rows)");
    std::memcpy(m.rec + e * p_.slot_bytes, src, p_.slot_bytes);
    m.ver[e].store(0, std::memory_order_relaxed);
    m.tag[e] = 0;
    m.t_upd[e].store(0, std::memory_order_relaxed);
    m.idx[i].store(want << 32 | e, std::memory_order_release);
    m.n.store(e + 1, std::memory_order_release);
    return e;
  }
  // consistent copy of bytes [off, off + len) of entry e; returns the entry's last update time
  uint64_t dram_read(const DramMap &m, uint64_t e, uint8_t *dst, uint32_t off, uint32_t len) const {
    const uint8_t *r = m.rec + e * p_.slot_bytes + off;
    for (;;) {
      const uint32_t v1 = m.ver[e].load(std::memory_order_acquire);
      if (v1 & 1) {
        _mm_pause();
        continue;
      }
      std::memcpy(dst, r, len);
      const uint64_t t = m.t_upd[e].load(std::memory_order_relaxed);
      std::atomic_thread_fence(std::memory_order_acquire);
      if (m.ver[e].load(std::memory_order_relaxed) == v1) return t;
    }
  }
  // owner w, one gradient batch: update the DRAM copies (first touch copies the shared record), add rows to D_win.
  // Returns the rows whose shared record holds another key (not updated; counted as update misses like the RMW path).
  uint64_t dram_apply(uint32_t w, const GradJob &j, float *wv) {
    DramMap &m = *dm_[w];
    thread_local std::vector<uint8_t> buf;
    buf.resize(p_.slot_bytes);
    uint64_t bad_key = 0, n = 0;
    std::lock_guard<std::mutex> l(m.mu);
    const uint64_t now = now_ns();
    const uint32_t tg = m.win + 1;
    for (size_t x = 0; x < j.rows.size(); x++) {
      const Touched &t = j.rows[x];
      int64_t e = dram_find(m, t.gslot);
      if (e < 0) {  // first touch: no other writer of this row exists (the publisher writes only rows in the map)
        be_->read_slot(t.k, t.gslot - p_.row_base[t.k], [&](const uint8_t *src) { std::memcpy(buf.data(), src, p_.slot_bytes); });
        uint64_t key;
        std::memcpy(&key, buf.data() + fmt_.key_off, 8);
        if (key != t.key) {
          bad_key++;
          continue;
        }
        e = int64_t(dram_insert(m, t.gslot, buf.data()));
      }
      uint8_t *rec = m.rec + uint64_t(e) * p_.slot_bytes;
      const uint32_t v = m.ver[e].load(std::memory_order_relaxed);
      m.ver[e].store(v + 1, std::memory_order_relaxed);
      std::atomic_thread_fence(std::memory_order_release);
      rmw_record(rec, &j.g[x * p_.dim], t.key, j.seq, wv);
      m.t_upd[e].store(now, std::memory_order_relaxed);
      m.ver[e].store(v + 2, std::memory_order_release);
      if (m.tag[e] != tg) {
        m.tag[e] = tg;
        m.d.push_back(uint32_t(e));
      }
      n++;
      if (trace_f_) trace("U %u %lu %lu %lu\n", tg - 1, (unsigned long)t.gslot, (unsigned long)j.seq, (unsigned long)now);
    }
    st_.dram_updates += n;
    return bad_key;
  }
  // trainer forward lookup: the DRAM copy when the row has one, else the shared record (lookup())
  bool train_lookup(uint32_t k, uint64_t key, float *acc, float *tmp, LookupCnt *c) {
    if (!win_on()) return lookup(k, key, acc, tmp, c);
    const uint64_t r = Params::key_row(key);
    if (r >= p_.rows[k]) return false;
    const DramMap &m = *dm_[owner(k, key)];
    const int64_t e = dram_find(m, p_.row_base[k] + r);
    if (e < 0) return lookup(k, key, acc, tmp, c);
    dram_read(m, uint64_t(e), reinterpret_cast<uint8_t *>(tmp), uint32_t(fmt_.emb_off), fmt_.emb_bytes);
    emb_to_f32(tmp, fmt_.elt, p_.dim, acc, true);
    st_.train_dram_hits.fetch_add(1, std::memory_order_relaxed);
    return true;
  }
  void trace(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
    std::lock_guard<std::mutex> g(trace_mu_);
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(trace_f_, fmt, ap);
    va_end(ap);
  }
  static void sleep_until_ns(uint64_t t) {
    timespec ts{time_t(t / 1000000000ull), long(t % 1000000000ull)};
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr) == EINTR) {
    }
  }
  void publisher() {
    be_->thread_init(int(1 + o_.load_threads + o_.update_threads + o_.serve_threads + train_threads()), kRoleUpdate);
    cxl::proc::name_thread("rs-publish");
    coh_init();
    OpTimer ot(&tcoh_);
    const uint64_t Ws = o_.publish_window_s, W = Ws * 1000000000ull, U = o_.update_threads;
    std::vector<uint8_t> buf(p_.slot_bytes);
    struct Seg {
      std::vector<uint64_t> rows;  // owner << 32 | entry
      uint64_t start = 0, b = 0;   // window boundary (ns), rows per second
      size_t next = 0;
      uint32_t win = 0;            // the window whose D_w this is
    };
    std::deque<Seg> q;
    uint64_t t0;
    while (!(t0 = win_t0_.load(std::memory_order_acquire))) sleep_until_ns(now_ns() + 1000000);
    uint64_t boundary = t0 + W;
    uint32_t w = 0;
    std::vector<std::vector<uint32_t>> lists(U);
    for (;;) {
      const uint64_t now = now_ns();
      if (now >= boundary) {  // end of window w: D_w becomes the list published during w + 1
        size_t mx = 0;
        for (uint64_t u = 0; u < U; u++) {
          lists[u].clear();
          std::lock_guard<std::mutex> l(dm_[u]->mu);
          lists[u].swap(dm_[u]->d);
          dm_[u]->win = w + 1;
          mx = std::max(mx, lists[u].size());
        }
        Seg s;
        s.win = w, s.start = boundary;
        for (size_t i = 0; i < mx; i++)
          for (uint64_t u = 0; u < U; u++)
            if (i < lists[u].size()) s.rows.push_back(u << 32 | lists[u][i]);
        const uint64_t n = s.rows.size();
        s.b = (n + Ws - 1) / Ws;
        uint64_t carry = 0;
        for (const Seg &x : q) carry += x.rows.size() - x.next;
        st_.publish_carryover += carry;
        st_.window_distinct = n;
        st_.publish_window = w + 1;
        if (w == 0) st_.publish_start_ns = boundary;  // the harness waits from here (main-block.sh PUBLISH_AFTER_S)
        if (w == 0)
          std::fprintf(stderr, "recsys-server: publishing started (window 1, W=%lu s): %lu distinct rows of window 0\n",
                       (unsigned long)Ws, (unsigned long)n);
        std::fprintf(stderr, "recsys-server: publish window %u: %lu distinct rows of window %u, %lu rows/s, %lu rows carried over\n",
                     w + 1, (unsigned long)n, w, (unsigned long)s.b, (unsigned long)carry);
        if (trace_f_) trace("B %u %lu %lu %lu\n", w, (unsigned long)boundary, (unsigned long)n, (unsigned long)s.b);
        if (n) q.push_back(std::move(s));
        w++;
        boundary += W;
        continue;
      }
      uint64_t backlog = 0, queued = 0;
      for (const Seg &x : q) {
        queued += x.rows.size() - x.next;
        if (now < x.start) continue;
        const uint64_t due = std::min<uint64_t>(x.rows.size(), uint64_t(double(now - x.start) * double(x.b) / 1e9) + 1);
        if (due > x.next) backlog += due - x.next;
      }
      st_.publish_backlog.store(backlog, std::memory_order_relaxed);
      st_.publish_queued.store(queued, std::memory_order_relaxed);
      if (q.empty()) {
        sleep_until_ns(boundary);
        continue;
      }
      Seg &s = q.front();
      const uint64_t due = s.start + (s.next / s.b) * 1000000000ull + (s.next % s.b) * 1000000000ull / s.b;
      if (due > now) {
        sleep_until_ns(std::min(due, boundary));
        continue;
      }
      publish_row(s.rows[s.next], s.win, buf, ot);
      if (++s.next == s.rows.size()) q.pop_front();
    }
  }
  void publish_row(uint64_t pk, uint32_t win, std::vector<uint8_t> &buf, OpTimer &ot) {
    const DramMap &m = *dm_[pk >> 32];
    const uint64_t e = pk & 0xffffffffu;
    ot.begin();
    const uint64_t t_upd = dram_read(m, e, buf.data(), 0, p_.slot_bytes);
    uint64_t key, seq;
    std::memcpy(&key, buf.data() + fmt_.key_off, 8);
    std::memcpy(&seq, buf.data() + fmt_.seq_off, 8);
    const uint32_t k = Params::key_table(key);
    const uint64_t r = Params::key_row(key);
    if constexpr (Be::kAppSeqlock) {
      uint32_t *ver = &h_->ver[p_.stripe(key)];
      const uint32_t v = lock_stripe(ver);
      be_->write_slot(k, r, [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
      store_release(ver, v + 2);
    } else {
      be_->write_object(k, be_->chunk_of(k, r),
                        [&](uint8_t *obj) { std::memcpy(obj + be_->row_offset(k, r), buf.data(), p_.slot_bytes); });
      st_.publish_sections++;
    }
    const uint64_t t = now_ns();
    ot.end(&st_.op_publish, 1);
    const uint64_t lag = t > t_upd ? t - t_upd : 0;
    st_.publish_lag_ns_sum += lag, st_.publish_lag_n++;
    st_.publish_lag_hist[std::min<uint64_t>(Stats::kLagBuckets, lag / lag_bucket_ns())].fetch_add(1, std::memory_order_relaxed);
    if (o_.publish_test_delay_ns) {  // Host catch-up test only: a slow publisher
      const uint64_t until = now_ns() + o_.publish_test_delay_ns;
      while (now_ns() < until) _mm_pause();
    }
    uint64_t mx = st_.publish_lag_ns_max.load();
    while (lag > mx && !st_.publish_lag_ns_max.compare_exchange_weak(mx, lag)) {
    }
    st_.published_rows++;
    const uint64_t gslot = p_.row_base[k] + r;
    if (stale_sampled(gslot)) stale_add(gslot, seq, true);  // visible after the write
    if (trace_f_) {
      uint32_t cs;
      std::memcpy(&cs, buf.data() + fmt_.csum_off, 4);
      trace("P %u %lu %lu %u %lu\n", win, (unsigned long)gslot, (unsigned long)seq, cs, (unsigned long)t);
    }
  }
  std::string window_text() {
    if (!win_on()) return "";
    uint64_t rows = 0;
    for (auto &m : dm_) rows += m->n.load();
    std::ostringstream o;
    o << "\npublish_window_s=" << o_.publish_window_s << "\npublish_started=" << (st_.publish_window.load() ? 1 : 0)
      << "\npublish_start_mono_ns=" << st_.publish_start_ns << "\npublish_window=" << st_.publish_window
      << "\npublished_rows=" << st_.published_rows
      << "\npublish_sections=" << st_.publish_sections << "\npublish_backlog=" << st_.publish_backlog
      << "\npublish_queued=" << st_.publish_queued << "\nwindow_distinct=" << st_.window_distinct
      << "\npublish_carryover_rows=" << st_.publish_carryover << "\npublish_lag_ns_sum=" << st_.publish_lag_ns_sum
      << "\npublish_lag_ns_count=" << st_.publish_lag_n << "\npublish_lag_ns_max=" << st_.publish_lag_ns_max.exchange(0)
      << "\ndram_rows=" << rows << "\ndram_capacity=" << dram_cap_ << "\ndram_index_bytes=" << dram_index_bytes_
      << "\ndram_bytes=" << dram_index_bytes_ + rows * (p_.slot_bytes + 16) << "\ndram_updates=" << st_.dram_updates
      << "\ntrain_dram_hits=" << st_.train_dram_hits << "\npublish_lag_hist_bucket_ns=" << lag_bucket_ns();
    for (int i = 0; i <= Stats::kLagBuckets; i++) o << "\npublish_lag_hist.b" << i << "=" << st_.publish_lag_hist[i];
    if (trace_f_) {
      std::lock_guard<std::mutex> g(trace_mu_);
      std::fflush(trace_f_);
    }
    return o.str();
  }

  // ---------------------------------------------------------------- serving
  struct QueryCtx {
    Job job;
    uint32_t pairs = 0, tasks = 0, chunk = 0;
    const Sample *s = nullptr;
    std::vector<float> score;
    uint64_t t_start = 0;
    std::atomic<uint32_t> next{0}, done{0}, refs{0};
    std::atomic<uint64_t> lookup_ns{0}, mlp_ns{0}, lookups{0}, probes{0}, retries{0}, false_retries{0}, misses{0},
        max_seq{0};
    std::atomic<uint64_t> first_ns{0};
  };

  void push_query(Job j) {
    {
      std::lock_guard<std::mutex> g(smu_);
      queries_.push_back(std::move(j));
    }
    scv_.notify_one();
  }

  void server(uint32_t i) {
    be_->thread_init(int(1 + o_.load_threads + o_.update_threads + i), kRoleServe);
    cxl::proc::name_thread("rs-serve");
    coh_init();
    for (;;) {
      QueryCtx *task = nullptr;
      Job job;
      {
        std::unique_lock<std::mutex> l(smu_);
        scv_.wait(l, [&] { return !tasks_.empty() || !queries_.empty(); });
        if (!tasks_.empty()) {
          task = tasks_.front();
          tasks_.pop_front();
        } else {
          job = std::move(queries_.front());
          queries_.pop_front();
        }
      }
      if (task) {
        run_chunk(task);
        release(task);
        continue;
      }
      QueryCtx *c = start_query(std::move(job));
      if (!c) continue;
      c->refs.store(c->tasks);  // tasks - 1 entries + this owner
      {
        std::lock_guard<std::mutex> g(smu_);
        for (uint32_t x = 1; x < c->tasks; x++) tasks_.push_back(c);
      }
      if (c->tasks > 1) scv_.notify_all();
      while (run_chunk(c)) {
      }
      release(c);
    }
  }

  QueryCtx *start_query(Job j) {
    QueryReq rq;
    const uint32_t n = frame::payload_len(j.h);
    if (n < sizeof(rq)) return bad(j), nullptr;
    std::memcpy(&rq, j.p.data(), sizeof(rq));
    if (rq.pairs == 0 || n != sizeof(rq) + uint64_t(rq.pairs) * sizeof(Sample)) return bad(j), nullptr;
    auto *c = new QueryCtx;
    c->pairs = rq.pairs;
    c->chunk = query_chunk(rq.pairs, o_.chunk_pairs, o_.split_ways, o_.serve_threads, o_.min_chunk);
    c->tasks = (rq.pairs + c->chunk - 1) / c->chunk;
    c->score.assign(rq.pairs, 0.f);
    c->t_start = now_ns();
    c->job = std::move(j);
    c->s = reinterpret_cast<const Sample *>(c->job.p.data() + sizeof(rq));
    return c;
  }

  bool run_chunk(QueryCtx *c) {
    const uint32_t t = c->next.fetch_add(1);
    if (t >= c->tasks) return false;
    uint64_t z = 0;
    c->first_ns.compare_exchange_strong(z, now_ns());
    const uint32_t r0 = t * c->chunk, m = std::min(c->chunk, c->pairs - r0);
    thread_local Model::Scratch sc;
    thread_local std::vector<float> dense, tmp;
    model_.scratch(&sc, m);
    dense.resize(size_t(m) * kDense);
    tmp.resize(p_.dim);
    for (uint32_t r = 0; r < m; r++) std::memcpy(&dense[size_t(r) * kDense], c->s[r0 + r].dense, kDense * 4);
    OpTimer ot(&tcoh_);  // Fig 2 T: this thread's work on the query, chunk claimed .. its part of the response ready
    ot.begin();
    const uint64_t t0 = now_ns();
    model_.bottom(dense.data(), m, &sc, o_.mlp);
    const uint64_t t1 = now_ns();
    const uint32_t D = model_.spec().inter();
    LookupCnt lc;
    uint64_t misses = 0, lookups = 0;
    for (uint32_t r = 0; r < m; r++) {
      const Sample &smp = c->s[r0 + r];
      for (uint32_t k = 0; k < kSparse; k++) {
        float *acc = &sc.x0[size_t(r) * D + size_t(k + 1) * p_.dim];
        std::memset(acc, 0, size_t(p_.dim) * 4);
        for (uint32_t j = 0; j < p_.hot[k]; j++) {
          lookups++;
          if (!lookup(k, Params::key(k, p_.row_of(k, smp, j)), acc, tmp.data(), &lc, true)) misses++;
        }
      }
    }
    const uint64_t t2 = now_ns();
    model_.top(m, &sc, &c->score[r0], o_.mlp);
    const uint64_t t3 = now_ns();
    c->lookup_ns += t2 - t1;
    c->mlp_ns += (t1 - t0) + (t3 - t2);
    c->lookups += lookups, c->probes += lc.probes, c->retries += lc.retries, c->misses += misses;
    c->false_retries += lc.false_retries;
    st_.seq_spins += lc.spins;
    uint64_t ms = c->max_seq.load();
    while (lc.max_seq > ms && !c->max_seq.compare_exchange_weak(ms, lc.max_seq)) {
    }
    if (c->done.fetch_add(1) + 1 != c->tasks) {
      ot.end(&st_.op_query, 0);  // N_query is counted once per query in finish_query
      return true;
    }
    std::vector<uint8_t> out;
    const uint64_t t_resp = build_response(c, &out);
    ot.end(&st_.op_query, 0);  // response ready; the socket send below is excluded from T (all workloads)
    finish_query(c, out, t_resp);
    return true;
  }

  // Last chunk: assemble the response (part of T)
  uint64_t build_response(QueryCtx *c, std::vector<uint8_t> *outp) {
    std::vector<uint8_t> &out = *outp;
    const uint64_t t = now_ns();
    QueryResp r{};
    r.pairs = c->pairs;
    r.tasks = c->tasks;
    r.queue_us = uint32_t((c->first_ns - c->job.t_arr) / 1000);
    r.lookup_us = uint32_t(c->lookup_ns / 1000);
    r.mlp_us = uint32_t(c->mlp_ns / 1000);
    r.total_us = uint32_t((t - c->job.t_arr) / 1000);
    r.lookups = uint32_t(c->lookups), r.probes = uint32_t(c->probes), r.seq_retries = uint32_t(c->retries);
    r.misses = uint32_t(c->misses);
    r.max_row_seq = c->max_seq;
    double sum = 0;
    for (float x : c->score) sum += x;
    r.mean_score = float(sum / c->pairs);
    r.false_retries = uint32_t(c->false_retries);
    QueryReq rq;
    std::memcpy(&rq, c->job.p.data(), sizeof(rq));
    out.resize(sizeof(r) + ((rq.flags & kQueryReturnScores) ? c->pairs * 4 : 0));
    std::memcpy(out.data(), &r, sizeof(r));
    if (rq.flags & kQueryReturnScores) std::memcpy(out.data() + sizeof(r), c->score.data(), c->pairs * 4);
    return t;
  }

  void finish_query(QueryCtx *c, const std::vector<uint8_t> &out, uint64_t t) {  // send + counters (not in T)
    c->job.c->reply(frame::kStatusOk, c->job.h.req_id, out.data(), uint32_t(out.size()));
    st_.queries++, st_.pairs += c->pairs, st_.lookups += c->lookups, st_.probes += c->probes;
    st_.seq_retries += c->retries, st_.misses += c->misses, st_.lookup_ns += c->lookup_ns, st_.mlp_ns += c->mlp_ns;
    st_.false_retries += c->false_retries;
    st_.op_query.n.fetch_add(1, std::memory_order_relaxed);
    st_.query_ns += t - c->job.t_arr;
  }

  void release(QueryCtx *c) {
    if (c->refs.fetch_sub(1) == 1) delete c;
  }

  void bad(Job &j) {
    st_.bad++;
    j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0);
  }

  // ---------------------------------------------------------------- network
  void listen_loop() {
    cxl::proc::name_thread("rs-listen");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "recsys-server: READY node %u port %u\n", o_.node, o_.port);
    for (;;) {
      int fd = accept(ls, nullptr, nullptr);
      if (fd < 0) continue;
      int buf = 8 << 20;
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
      setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof(buf));
      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
      auto c = std::make_shared<Conn>();
      c->fd = fd;
      std::thread([this, c] { read_conn(c); }).detach();
    }
  }

  void read_conn(std::shared_ptr<Conn> c) {
    cxl::proc::name_thread("rs-conn");
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h)), 0};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      j.t_arr = now_ns();
      switch (h.code) {
        case kOpUpdate: dispatch_update(std::move(j)); break;
        case kOpQuery: push_query(std::move(j)); break;
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

  size_t sq_size() {
    std::lock_guard<std::mutex> g(smu_);
    return queries_.size();
  }

  Opts o_;
  Params p_;
  cxl::region r_;
  uint8_t *map_ = nullptr;
  std::unique_ptr<Hwcc> h_;
  const mshim::Api *api_ = nullptr;
  std::unique_ptr<Be> be_;
  Model model_;
  PrepPool pool_;
  Stats st_;
  std::unique_ptr<Queue<std::shared_ptr<UpdJob>>[]> uq_;
  std::unique_ptr<std::atomic<uint64_t>[]> done_seq_;
  std::mutex smu_;
  std::condition_variable scv_;
  std::deque<Job> queries_;
  std::deque<QueryCtx *> tasks_;
  // v7
  RecFmt fmt_{p_};
  Queue<std::shared_ptr<UpdJob>> tq_;                       // train mode: accepted samples, seq order
  std::unique_ptr<Queue<std::shared_ptr<GradJob>>[]> gq_;   // train mode: per row owner
  std::mutex tmu_, lmu_;
  uint64_t next_batch_ = 0, next_pub_ = 0;
  std::map<uint64_t, Led> ledger_;
  FILE *stale_f_ = nullptr;
  std::mutex stale_mu_;
  std::vector<std::unique_ptr<StaleBuf>> stale_bufs_;
  // windowed publication
  std::vector<std::unique_ptr<DramMap>> dm_;
  std::atomic<uint64_t> win_t0_{0};
  uint64_t dram_cap_ = 0, dram_index_bytes_ = 0;
  FILE *trace_f_ = nullptr;
  std::mutex trace_mu_;
};

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
  std::fprintf(stderr, "recsys-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);
}

// --image: record format and table sizes come from the image header; the derived layout must match it exactly (rows
// per table, row_base). Full image = no row cap (--row-cap defaults to the largest MLPerf table with --image); a
// scaled test image (tests/make_test_image.py) is built for given --row-cap/--row-div and needs the same options here.
bool apply_image(Opts *o, bool row_cap_set) {
  const int fd = ::open(o->image.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return std::fprintf(stderr, "recsys-server: --image %s: cannot open\n", o->image.c_str()), false;
  ImageHeader h{};
  struct stat st{};
  const bool ok = pread(fd, &h, sizeof h, 0) == ssize_t(sizeof h) && fstat(fd, &st) == 0;
  close(fd);
  if (!ok || h.magic != kImageMagic || h.version != kImageVersion || (h.elt_bytes != 2 && h.elt_bytes != 4) ||
      h.record_bytes != rec_bytes(h.dim, h.elt_bytes) || h.data_off != kImageHeaderBytes ||
      uint64_t(st.st_size) != h.data_off + h.rows * h.record_bytes)
    return std::fprintf(stderr, "recsys-server: --image %s: not a RSYSIMG1 v1 image or size mismatch\n", o->image.c_str()), false;
  o->p.dim = h.dim, o->p.v7_elt = h.elt_bytes;
  if (!row_cap_set) o->p.row_cap = *std::max_element(mlperf_rows().begin(), mlperf_rows().end());
  o->p.derive();
  for (uint32_t k = 0; k < kSparse; k++)
    if (o->p.rows[k] != h.table_rows[k] || o->p.row_base[k] != h.row_base[k])
      return std::fprintf(stderr, "recsys-server: --image table %u: %lu rows at %lu, layout has %lu at %lu (--row-cap/"
                                  "--row-div must be those of the image)\n", k, (unsigned long)h.table_rows[k],
                          (unsigned long)h.row_base[k], (unsigned long)o->p.rows[k], (unsigned long)o->p.row_base[k]),
             false;
  if (o->p.total_rows != h.rows || o->p.slot_bytes != h.record_bytes)
    return std::fprintf(stderr, "recsys-server: --image: rows/record size differ from the layout\n"), false;
  return true;
}

void usage() {
  std::fprintf(stderr,
               "usage: recsys-server --node K --nodes N --run-id 0x.. [--port P] [--region yaml]\n"
               "  [--serve-threads S (14)] [--update-threads U (4)] [--chunk-pairs C (0 = adaptive)] [--min-chunk M (16)] [--load-threads L (8)]\n"
               "  [--split-ways K (0 = S)]   adaptive chunk (C = 0) = max(M, ceil(pairs / K)); K = 0 divides by S as before\n"
               "  [--publish-ms T | --publish-us T (0 = write each sample immediately)] [--publish-frac F (target rows/T, reported)]\n"
               "  [--update-mode batch|stream|train]   stream (T = 0 only): reply on acceptance, rows written right away (batch = default)\n"
               "  v7 (DESIGN.md §10.6): [--image F] [--model-dense F] [--update-mode train] [--train-threads N (= U)]\n"
               "     [--train-batch B (8)] [--lr X (0.004)] [--eps X (1e-8)] [--acc-init X (< 0 = image)]\n"
               "     [--stale-log FILE] [--stale-sample N (256)]   train needs --image and --model-dense\n"
               "     [--publish-window-s W (0 = off: every row update written through)] [--publish-dram-rows N (0 = min(rows, 48M))]\n"
               "     [--publish-trace FILE (Host tests)]   W > 0 (node 0): train on a DRAM copy, publish the distinct rows of\n"
               "     each W-s window during the next window, ceil(n/W) rows/s evenly spaced (reports/experiments/recsys-windowed-update.md)\n"
               "  [--dim D (128)] [--row-cap R (26000000)] [--row-div N (1)] [--ver-stripes S (65536)]\n"
               "  [--multi-hot-div N (1)] [--rank R (512)] [--seed N] [--verify-rows 0|1] [--warm-up 0|1]\n"
               "  [--mlp avx512|amx (avx512)]   serving forward: fp32 AVX-512 | bf16 AMX tiles, fp32 accumulate (needs AMX\n"
               "     CPUID + XCR0 tile state + arch_prctl XTILEDATA permission; exits otherwise); training stays fp32\n"
               "  [--check-stride N (4096)] [--megalon-time-sample N (0 = off)] [--start-timeout-ms T] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "  [--mg-rows-per-object N]   required with --backend megalon: 0 = one object per table, 1 = per row, N = N-row chunks\n"
               "  [--proc-kthread PREFIX]... [--proc-sysfs DIR]...\n"
               "  [--preload-only | --preloaded]   Popcorn init_state=shared: node 0 writes the tables before enable\n"
               "CXL_APP_HWCC_BYTES must equal the app layout size: recsys-server --print-app-bytes [params].\n"
               "--print-layout prints the parameter summary and exits.\n");
  std::exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  Opts o;
  bool print_bytes = false, print_layout = false, row_cap_set = false;
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
    else if (a == "--serve-threads") o.serve_threads = std::stoul(v());
    else if (a == "--update-threads") o.update_threads = std::stoul(v());
    else if (a == "--chunk-pairs") o.chunk_pairs = std::stoul(v());
    else if (a == "--min-chunk") o.min_chunk = std::stoul(v());
    else if (a == "--split-ways") o.split_ways = std::stoul(v());
    else if (a == "--load-threads") o.load_threads = std::stoul(v());
    else if (a == "--publish-ms") o.publish_us = std::stoull(v()) * 1000;
    else if (a == "--publish-us") o.publish_us = std::stoull(v());
    else if (a == "--update-mode") {
      const std::string m = v();
      if (m != "stream" && m != "batch" && m != "train") usage();
      o.stream = m == "stream" || m == "train";  // train: acknowledged on acceptance as in stream (DESIGN.md §10.6)
      o.train = m == "train";
    }
    else if (a == "--image") o.image = v();
    else if (a == "--model-dense") o.model_dense = v();
    else if (a == "--train-threads") o.train_threads = std::stoul(v());
    else if (a == "--train-batch") o.train_batch = std::stoul(v());
    else if (a == "--lr") o.ada.lr = std::stof(v());
    else if (a == "--eps") o.ada.eps = std::stof(v());
    else if (a == "--acc-init") o.acc_init = std::stod(v());
    else if (a == "--stale-log") o.stale_log = v();
    else if (a == "--stale-sample") o.stale_mod = std::stoul(v());
    else if (a == "--publish-window-s") o.publish_window_s = std::stoul(v());
    else if (a == "--publish-dram-rows") o.dram_rows_cap = std::stoull(v());
    else if (a == "--publish-trace") o.publish_trace = v();
    else if (a == "--publish-test-row-delay-ns") o.publish_test_delay_ns = std::stoull(v());
    else if (a == "--dim") o.p.dim = std::stoul(v());
    else if (a == "--row-cap") o.p.row_cap = std::stoull(v()), row_cap_set = true;
    else if (a == "--row-div") o.p.row_div = std::stoull(v());
    else if (a == "--ver-stripes") o.p.ver_stripes = std::stoul(v());
    else if (a == "--publish-frac") o.publish_frac = std::stod(v());
    else if (a == "--multi-hot-div") o.p.multi_hot_div = std::stoul(v());
    else if (a == "--rank") o.rank = std::stoul(v());
    else if (a == "--mlp") {
      if (!parse_mlp(v(), &o.mlp)) usage();
    }
    else if (a == "--seed") o.p.seed = std::stoull(v());
    else if (a == "--verify-rows") o.verify_rows = std::stoul(v());
    else if (a == "--warm-up") o.warm_up = std::stoul(v());
    else if (a == "--test-no-seqlock") o.test_no_seqlock = true;
    else if (a == "--megalon-time-sample") o.megalon_time_sample = std::stoul(v());
    else if (a == "--check-stride") o.check_stride = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.megalon_lib = v();
    else if (a == "--mg-rows-per-object") o.mg_rows_per_object = std::stoll(v());
    else if (a == "--proc-kthread") o.proc.kthread_prefixes.push_back(v());
    else if (a == "--proc-sysfs") o.proc.sysfs_dirs.push_back(v());
    else if (a == "--print-app-bytes") print_bytes = true;
    else if (a == "--print-layout") print_layout = true;
    else if (a == "--preload-only") o.preload_only = true;
    else if (a == "--preloaded") o.preloaded = true;
    else usage();
  }
  if (o.p.dim % 32 || o.p.ver_stripes == 0 || (o.p.ver_stripes & (o.p.ver_stripes - 1)) ||
      o.rank % 32 || o.publish_frac < 0 || o.publish_frac > 1) {
    std::fprintf(stderr, "recsys-server: dim and rank must be multiples of 32, --ver-stripes a "
                         "power of two, 0 <= --publish-frac <= 1\n");
    return 2;
  }
  o.p.derive();
  if (!o.image.empty() && !apply_image(&o, row_cap_set)) return 2;
  if (o.train && (o.image.empty() || o.model_dense.empty() || o.publish_us || o.train_batch == 0 || o.train_batch > 64 ||
                  !(o.ada.lr > 0) || o.p.multi_hot_div != 1)) {
    std::fprintf(stderr, "recsys-server: --update-mode train needs --image, --model-dense, --publish-ms 0, "
                         "1 <= --train-batch <= 64, --lr > 0 and --multi-hot-div 1\n");
    return 2;
  }
  if ((o.publish_window_s || o.dram_rows_cap || !o.publish_trace.empty()) && !o.train) {
    std::fprintf(stderr, "recsys-server: --publish-window-s / --publish-dram-rows / --publish-trace need --update-mode train\n");
    return 2;
  }
  if (!o.publish_window_s && (o.dram_rows_cap || !o.publish_trace.empty() || o.publish_test_delay_ns)) {
    std::fprintf(stderr, "recsys-server: --publish-dram-rows / --publish-trace / --publish-test-row-delay-ns need --publish-window-s > 0\n");
    return 2;
  }
  if (!o.image.empty() && !o.train) {  // the v6 writer (make_slot) would overwrite v7 records with synthetic v6 rows
    std::fprintf(stderr, "recsys-server: --image needs --update-mode train (on every node; serving nodes idle their trainers)\n");
    return 2;
  }
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.p).L.bytes());
    return 0;
  }
  if (print_layout) {
    std::printf("%s app_bytes=%lu\n", o.p.describe().c_str(), (unsigned long)HwccLayout(o.p).L.bytes());
    for (uint32_t k = 0; k < kSparse; k++)
      std::printf("table %2u rows %9lu row_base %10lu hot %3u\n", k, (unsigned long)o.p.rows[k],
                  (unsigned long)o.p.row_base[k], o.p.hot[k]);
    if (o.mg_rows_per_object >= 0) {  // Megalon object granularity (same arithmetic as MegalonBackend)
      uint64_t objs = 0, mx = 0;
      for (uint32_t k = 0; k < kSparse; k++) {
        const uint64_t n = o.mg_rows_per_object ? std::min<uint64_t>(o.mg_rows_per_object, o.p.rows[k]) : o.p.rows[k];
        objs += (o.p.rows[k] + n - 1) / n;
        mx = std::max(mx, n * o.p.slot_bytes);
      }
      std::printf("megalon rows_per_object %ld objects %lu max_object_bytes %lu\n", (long)o.mg_rows_per_object,
                  (unsigned long)objs, (unsigned long)mx);
    }
    if (o.publish_frac > 0)
      std::printf("publish_frac %.9g rows_per_round_target %lu (of %lu rows)\n", o.publish_frac,
                  (unsigned long)(o.publish_frac * double(o.p.total_rows) + 0.5), (unsigned long)o.p.total_rows);
    return 0;
  }
  if (o.run_id == 0 && !o.preload_only) usage();
  if (o.mlp == Mlp::amx && !o.preload_only) {  // process-wide AMX permission before any thread exists or uses tiles
    std::string err;
    if (!amx_enable(&err)) {
      std::fprintf(stderr, "recsys-server: --mlp amx: %s\n", err.c_str());
      return 2;
    }
  }
  if (o.stream && o.publish_us) {
    std::fprintf(stderr, "recsys-server: --update-mode stream needs --publish-ms 0 (no publication period)\n");
    return 2;
  }
  if ((o.preload_only || o.preloaded) && o.backend != "plain") {
    std::fprintf(stderr, "recsys-server: --preload-only/--preloaded are for the plain backend\n");
    return 2;
  }
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  if (o.backend == "plain") {
    if (o.mg_rows_per_object >= 0) {
      std::fprintf(stderr, "recsys-server: --mg-rows-per-object is for --backend megalon only\n");
      return 2;
    }
    return run<PlainBackend>(o);
  }
  if (o.backend == "megalon" && o.mg_rows_per_object < 0) {
    std::fprintf(stderr, "recsys-server: --backend megalon needs --mg-rows-per-object N (0 = one object per table, "
                         "1 = per row, N > 1 = N-row chunks)\n");
    return 2;
  }
  if (o.backend != "megalon") usage();
  auto env = [](const char *k, const std::string &v) {
    const char *cur = getenv(k);
    if (cur && *cur && v != cur) {
      std::fprintf(stderr, "recsys-server: %s=%s contradicts the server option (%s)\n", k, cur, v.c_str());
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
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libmegalon-objapi.so";
  }
  return run<MegalonBackend>(o);
}

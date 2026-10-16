// recsys server (DLRMv2-based recommendation system), one process per VM (DESIGN.md). Speaks
// experiments/loadgen/frame.h with workloads/recsys/proto.h. Shared state: 26 open-addressing linear-probing
// embedding tables in SWcc (one slot = key + embedding + seq + csum, 576 B), a striped HWcc version table (MemC3:
// S = 2^16 u32 counters, row -> hash(table, key) mod S). Every node accepts both ops; the harness sends updates to the
// updater node (0) and queries to the serving node (1). Threads: one reader per connection, U update workers (rows
// sharded by stripe % U; Monolith-style touched-row publication every T, workers independent), S serving workers (a
// query is split into chunks of pairs; workers claim chunks). Backend (--backend plain|megalon): where the slots live
// and which coherence actions wrap each slot access; Server<Backend> is compiled per backend. Per-operation time
// split (MOT1 v6 Fig 2): optime.h.
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
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
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

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "recsys-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct Opts {
  Params p;
  uint32_t node = 0, port = 7100, serve_threads = 14, update_threads = 4, load_threads = 8;
  uint32_t chunk_pairs = 0;     // pairs per parallel task; 0 = adaptive: max(min_chunk, ceil(pairs / serve_threads))
  uint32_t min_chunk = 16;
  uint32_t rank = 512;          // DCNv2 low rank (MLPerf 512)
  uint64_t publish_us = 0;      // publication interval T (0 = write each sample immediately)
  double publish_frac = 0;      // operating point: target fraction of all rows published per T (reported; the
                                // harness sets the sample rate with recsys-rate; 0 = none)
  uint64_t run_id = 0, start_timeout_ms = 3600000;
  uint64_t check_stride = 4096; // Megalon: ObjectLookup every n-th slot on every node
  bool warm_up = true, verify_rows = false, preload_only = false, preloaded = false;
  bool test_no_seqlock = false;  // negative test only: readers ignore the version words (torn rows must show up)
  uint32_t megalon_time_sample = 0;  // legacy app-level Megalon timers, 1 in N sections (backend.h MegThr); v6: off
                                     // by default (CohSnap replaces them; they perturb timing)
  std::string region, backend = "plain", megalon_lib;
  cxl::proc::Opts proc;
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
      misses{0}, torn{0}, lookup_ns{0}, mlp_ns{0}, query_ns{0}, bad{0};
  std::atomic<uint64_t> samples{0}, rows_touched{0}, rows_written{0}, update_misses{0}, flushes{0}, flush_ns{0},
      flush_ns_max{0}, flush_overruns{0}, lock_spins{0}, write_ns{0}, accum_cyc{0}, publish_rounds{0},
      round_rows{0}, round_rows_max{0}, uq_max{0};
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
    HwccLayout lay(p_, Be::kLayoutTag);
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      if (1 + o_.load_threads + o_.update_threads + o_.serve_threads > 32)
        die("megalon: at most 32 thread registrations per node (main + load + update + serve threads)");
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
    if constexpr (std::is_same_v<Be, MegalonBackend>) be_ = std::make_unique<Be>(r_, map_, p_, api_);
    else be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    be_->set_time_sample(o_.megalon_time_sample);
    be_->thread_init(0);
    pool_.start(o_.load_threads, [this](int i) { be_->thread_init(1 + i, kRolePrep); cxl::proc::name_thread("rs-prep"); });
    ModelSpec ms;
    ms.dim = p_.dim, ms.rank = o_.rank;
    model_.init(ms, p_.seed);
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
    for (uint32_t w = 0; w < o_.update_threads; w++) std::thread([this, w] { updater(w); }).detach();
    for (uint32_t i = 0; i < o_.serve_threads; i++) std::thread([this, i] { server(i); }).detach();
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
      << "\nlock_spins=" << st_.lock_spins << "\nwrite_ns=" << st_.write_ns << "\npublished_seq="
      << load_acquire(&h_->nodes[o_.node].published_seq) << "\nserve_queue=" << sq_size()
      << "\npublish_us=" << o_.publish_us << "\npublish_frac=" << o_.publish_frac
      << "\nrows_per_round_target=" << uint64_t(o_.publish_frac * double(p_.total_rows) + 0.5)
      << "\npublish_rounds=" << st_.publish_rounds << "\nround_rows=" << st_.round_rows
      << "\nround_rows_max_worker=" << st_.round_rows_max << "\nupdate_rate_sustained=" << (st_.flush_overruns ? 0 : 1)
      << "\nupdate_queue_max=" << st_.uq_max << "\naccum_ns=" << tsc_to_ns(st_.accum_cyc)
      << "\nver_stripes=" << p_.ver_stripes << "\ntsc_khz=" << tsc_khz()
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
    std::fprintf(stderr, "recsys-server: PRELOAD DONE %lu slots (plain mapping, no HWcc access)\n",
                 (unsigned long)p_.total_slots);
  }

 private:
  std::string op_text() const {
    std::ostringstream o;
    st_.op_query.text(o, "query");
    st_.op_row_update.text(o, "row_update");
    return o.str();
  }
  void coh_init() {  // on the worker thread itself, after the backend registered it
    tcoh_.init(be_->coh_fn());
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
  // Placement: every row 0..rows-1 of every table inserted in row order by linear probing (DRAM occupancy), then
  // every slot (empty ones as zeros) written once with seq 0. Deterministic: same layout in every system.
  std::vector<std::vector<uint64_t>> placement() const {
    std::vector<std::vector<uint64_t>> keys(kSparse);
    std::vector<std::thread> t;
    for (uint32_t k = 0; k < kSparse; k++)
      t.emplace_back([&, k] {
        std::vector<uint64_t> &kk = keys[k];
        kk.assign(p_.slots[k], 0);
        for (uint64_t r = 0; r < p_.rows[k]; r++) {
          const uint64_t key = Params::key(k, r);
          uint64_t s = p_.home(k, key);
          while (kk[s]) s = s + 1 == p_.slots[k] ? 0 : s + 1;
          kk[s] = key;
        }
      });
    for (auto &x : t) x.join();
    return keys;
  }

  void write_tables() {
    const uint64_t t0 = now_ns();
    auto keys = placement();
    const uint64_t t1 = now_ns();
    std::atomic<uint64_t> next{0};
    pool_.run([&](int) {
        std::vector<uint8_t> buf(p_.slot_bytes);
        for (;;) {
          const uint64_t c = next.fetch_add(4096);
          if (c >= p_.total_slots) break;
          const uint64_t e = std::min(p_.total_slots, c + 4096);
          uint32_t k = 0;
          for (uint64_t g = c; g < e; g++) {
            while (k + 1 < kSparse && p_.slot_base[k + 1] <= g) k++;
            const uint64_t s = g - p_.slot_base[k];
            make_slot(p_, keys[k][s], 0, buf.data());
            be_->write_slot(k, s, [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
          }
        }
      });
    std::fprintf(stderr, "recsys-server: initial tables: %lu rows in %lu slots, placement %.1f s, write %.1f s (%.1f GiB)\n",
                 (unsigned long)p_.total_rows, (unsigned long)p_.total_slots, (t1 - t0) / 1e9, (now_ns() - t1) / 1e9,
                 p_.swcc_bytes() / 1073741824.0);
  }

  void load_initial() {
    std::string err;
    const uint64_t t0 = now_ns();
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      if (!be_->create_objects(&err, [this](std::function<void(int)> f) { pool_.run(std::move(f)); })) die(err);
      std::fprintf(stderr, "recsys-server: created %lu objects in %.1f s\n", (unsigned long)p_.total_slots,
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
    const SlotView v(p_);
    pool_.run([&](int) {
        std::vector<float> e(p_.dim);
        for (;;) {
          const uint64_t c = next.fetch_add(4096);
          if (c >= p_.total_slots) break;
          const uint64_t end = std::min(p_.total_slots, c + 4096);
          uint32_t k = 0;
          for (uint64_t g = c; g < end; g++) {
            while (k + 1 < kSparse && p_.slot_base[k + 1] <= g) k++;
            const int r = be_->read_slot(k, g - p_.slot_base[k], [&](const uint8_t *s) {
              uint64_t key, seq;
              uint32_t cs;
              std::memcpy(&key, s + v.key_off, 8);
              if (!key) return 0;
              std::memcpy(&seq, s + v.seq_off, 8);
              std::memcpy(&cs, s + v.csum_off, 4);
              std::memcpy(e.data(), s + v.emb_off, size_t(p_.dim) * 4);
              return row_csum(key, seq, e.data(), p_.dim) == cs ? 1 : 2;
            });
            if (r) occupied++;
            if (r == 2) bad++;
          }
        }
      });
    std::fprintf(stderr, "recsys-server: warm-up read %lu slots (%lu occupied, %lu bad) in %.1f s\n",
                 (unsigned long)p_.total_slots, (unsigned long)occupied.load(), (unsigned long)bad.load(),
                 (now_ns() - t0) / 1e9);
    if (occupied != p_.total_rows || bad) die("warm-up: table content does not match the initial load");
  }

  // ---------------------------------------------------------------- slot access under the striped version table
  // MemC3-style optimistic reader (NSDI'13 §3.2.1): v1 = counter of the looked-up key (even; spin while odd), probe,
  // copy the row, acquire fence, v2 == v1 or re-read. Keys never move and a slot's key field is rewritten only with
  // the same value (no inserts/deletes during a run), so the slots passed while probing need no version check; only
  // the copy of the matching row is validated. A retry is FALSE when the row itself was not rewritten: the discarded
  // copy was consistent (csum) and the re-read has the same seq (a writer of this row that finished between v1 and
  // the discarded copy is counted false too; window: one row copy).
  struct Probe {
    uint64_t key;  // key found in the slot
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
  Probe read_probe(uint32_t k, uint64_t s, uint64_t key, float *tmp) const {
    const SlotView v(p_);
    return be_->read_slot(k, s, [&](const uint8_t *src) {
      Probe x{};
      x.key = __atomic_load_n(reinterpret_cast<const uint64_t *>(src + v.key_off), __ATOMIC_RELAXED);
      if (x.key == key) {
        std::memcpy(tmp, src + v.emb_off, size_t(p_.dim) * 4);
        std::memcpy(&x.seq, src + v.seq_off, 8);
        std::memcpy(&x.csum, src + v.csum_off, 4);
      }
      return x;
    });
  }
  // Look up `key` in table k; on hit, adds the row's embedding into acc[dim]. Returns false on a miss.
  bool lookup(uint32_t k, uint64_t key, float *acc, float *tmp, LookupCnt *c) {
    const uint32_t *ver = &h_->ver[p_.stripe(key)];
    uint32_t v1 = wait_even(ver, c);
    uint64_t s = p_.home(k, key);
    for (uint64_t n = 0; n < p_.slots[k]; n++) {
      Probe pr = read_probe(k, s, key, tmp);
      c->probes++;
      if (pr.key == key) {
        for (;;) {
          std::atomic_thread_fence(std::memory_order_acquire);
          if (o_.test_no_seqlock || load_relaxed(ver) == v1) break;
          c->retries++;
          const bool consistent = row_csum(key, pr.seq, tmp, p_.dim) == pr.csum;
          const uint64_t seq0 = pr.seq;
          v1 = wait_even(ver, c);
          pr = read_probe(k, s, key, tmp);
          if (consistent && pr.seq == seq0) c->false_retries++;
        }
        if (o_.verify_rows && row_csum(key, pr.seq, tmp, p_.dim) != pr.csum) st_.torn++;
        for (uint32_t j = 0; j < p_.dim; j++) acc[j] += tmp[j];
        if (pr.seq > c->max_seq) c->max_seq = pr.seq;
        return true;
      }
      if (pr.key == 0) return false;
      s = s + 1 == p_.slots[k] ? 0 : s + 1;
    }
    return false;
  }
  // Slot of `key` in table k (keys never move: no deletes), or ~0 on a miss.
  uint64_t find_slot(uint32_t k, uint64_t key) {
    const SlotView v(p_);
    uint64_t s = p_.home(k, key);
    for (uint64_t n = 0; n < p_.slots[k]; n++) {
      const uint64_t got = be_->read_slot(k, s, [&](const uint8_t *src) {
        return __atomic_load_n(reinterpret_cast<const uint64_t *>(src + v.key_off), __ATOMIC_RELAXED);
      });
      if (got == key) return s;
      if (got == 0) return ~0ull;
      s = s + 1 == p_.slots[k] ? 0 : s + 1;
    }
    return ~0ull;
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
  // and records the rows it owns (stripe % U == w) in a private map key -> latest seq (latest wins); no shared memory
  // is read or written per sample, and the sample is acknowledged on acceptance (workers never wait for each other).
  // Every T the worker publishes its touched rows once: resolve each row's slot (probe in SWcc), write it under its
  // stripe. A round longer than T is an overrun ("update rate not sustained"); the next round starts at the next
  // multiple of T after it (never bursted). T = 0 (diagnostic): every sample's rows are written before the reply.
  struct UpdJob {
    Job job;
    Sample s;
    uint64_t seq;
    std::atomic<uint32_t> left;
  };
  struct Touched {
    uint64_t gslot;  // global slot index (slot_base[k] + s): sort key (SWcc address order)
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
    u->left = o_.update_threads;
    if (o_.publish_us) {  // accepted: reply now (workers are independent)
      st_.samples++;
      UpdateResp r{u->seq, load_acquire(&h_->nodes[o_.node].published_seq)};
      j.c->reply(frame::kStatusOk, j.h.req_id, &r, sizeof(r));
    } else {
      u->job = std::move(j);
    }
    for (uint32_t w = 0; w < o_.update_threads; w++) {
      const uint64_t q = uq_[w].push_size(u);
      uint64_t m = st_.uq_max.load();
      while (q > m && !st_.uq_max.compare_exchange_weak(m, q)) {
      }
    }
  }

  // rows: sorted by gslot, resolved. One stripe hold per row.
  void write_rows(const std::vector<Touched> &rows, std::vector<uint8_t> &buf) {
    const uint64_t t0 = now_ns();
    buf.resize(p_.slot_bytes);
    for (const Touched &t : rows) {
      make_slot(p_, t.key, t.seq, buf.data());
      uint32_t *ver = &h_->ver[p_.stripe(t.key)];
      const uint32_t v = lock_stripe(ver);
      be_->write_slot(t.k, t.gslot - p_.slot_base[t.k], [&](uint8_t *dst) { std::memcpy(dst, buf.data(), p_.slot_bytes); });
      store_release(ver, v + 2);
    }
    st_.write_ns += now_ns() - t0;
    st_.rows_written += rows.size();
    __atomic_fetch_add(&h_->nodes[o_.node].rows_written, uint64_t(rows.size()), __ATOMIC_RELAXED);
  }
  // key -> resolved row (slot by probing SWcc); false on a miss (counted)
  bool resolve(uint64_t key, uint64_t seq, Touched *t) {
    const uint32_t k = Params::key_table(key);
    const uint64_t s = find_slot(k, key);
    if (s == ~0ull) return st_.update_misses++, false;
    *t = Touched{p_.slot_base[k] + s, key, seq, k};
    return true;
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
        ot.end(&st_.op_row_update, rows.size());
        done_seq_[w] = accepted;
        publish();
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
            if (p_.stripe(key) % o_.update_threads != w) continue;
            st_.rows_touched++;
            touched.insert_or_assign(key, u->seq);  // latest wins
          }
        accepted = u->seq;
        st_.accum_cyc += tsc() - a0;
        continue;
      }
      // T = 0: write this sample's rows now (deduplicated), reply when every worker is done
      ot.begin();
      rows.clear();
      Touched t;
      for (uint32_t k = 0; k < kSparse; k++)
        for (uint32_t j = 0; j < p_.hot[k]; j++) {
          const uint64_t key = Params::key(k, p_.row_of(k, u->s, j));
          if (p_.stripe(key) % o_.update_threads != w) continue;
          st_.rows_touched++;
          if (resolve(key, u->seq, &t)) rows.push_back(t);
        }
      std::sort(rows.begin(), rows.end(), [](const Touched &a, const Touched &b) { return a.gslot < b.gslot; });
      rows.erase(std::unique(rows.begin(), rows.end(), [](const Touched &a, const Touched &b) { return a.gslot == b.gslot; }),
                 rows.end());
      write_rows(rows, buf);
      ot.end(&st_.op_row_update, rows.size());
      accepted = u->seq;
      done_seq_[w] = accepted;
      publish();
      if (u->left.fetch_sub(1) == 1) {
        st_.samples++;
        UpdateResp r{u->seq, load_acquire(&h_->nodes[o_.node].published_seq)};
        u->job.c->reply(frame::kStatusOk, u->job.h.req_id, &r, sizeof(r));
      }
    }
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
    c->chunk = o_.chunk_pairs ? o_.chunk_pairs : std::max(o_.min_chunk, (rq.pairs + o_.serve_threads - 1) / o_.serve_threads);
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
    OpTimer ot(&tcoh_);  // Fig 2: this thread's work on the query (bottom MLP .. top MLP)
    ot.begin();
    const uint64_t t0 = now_ns();
    model_.bottom(dense.data(), m, &sc);
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
          if (!lookup(k, Params::key(k, p_.row_of(k, smp, j)), acc, tmp.data(), &lc)) misses++;
        }
      }
    }
    const uint64_t t2 = now_ns();
    model_.top(m, &sc, &c->score[r0]);
    const uint64_t t3 = now_ns();
    ot.end(&st_.op_query, 0);  // N_query is counted once per query in finish_query
    c->lookup_ns += t2 - t1;
    c->mlp_ns += (t1 - t0) + (t3 - t2);
    c->lookups += lookups, c->probes += lc.probes, c->retries += lc.retries, c->misses += misses;
    c->false_retries += lc.false_retries;
    st_.seq_spins += lc.spins;
    uint64_t ms = c->max_seq.load();
    while (lc.max_seq > ms && !c->max_seq.compare_exchange_weak(ms, lc.max_seq)) {
    }
    if (c->done.fetch_add(1) + 1 == c->tasks) finish_query(c);
    return true;
  }

  void finish_query(QueryCtx *c) {
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
    std::vector<uint8_t> out(sizeof(r) + ((rq.flags & kQueryReturnScores) ? c->pairs * 4 : 0));
    std::memcpy(out.data(), &r, sizeof(r));
    if (rq.flags & kQueryReturnScores) std::memcpy(out.data() + sizeof(r), c->score.data(), c->pairs * 4);
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

void usage() {
  std::fprintf(stderr,
               "usage: recsys-server --node K --nodes N --run-id 0x.. [--port P] [--region yaml]\n"
               "  [--serve-threads S (14)] [--update-threads U (4)] [--chunk-pairs C (0 = adaptive)] [--min-chunk M (16)] [--load-threads L (8)]\n"
               "  [--publish-ms T | --publish-us T (0 = write each sample immediately)] [--publish-frac F (target rows/T, reported)]\n"
               "  [--dim D (128)] [--row-cap R (26000000)] [--row-div N (1)] [--load-factor F (0.8)] [--ver-stripes S (65536)]\n"
               "  [--multi-hot-div N (1)] [--rank R (512)] [--seed N] [--verify-rows 0|1] [--warm-up 0|1]\n"
               "  [--check-stride N (4096)] [--megalon-time-sample N (0 = off)] [--start-timeout-ms T] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "  [--proc-kthread PREFIX]... [--proc-sysfs DIR]...\n"
               "  [--preload-only | --preloaded]   Popcorn init_state=shared: node 0 writes the tables before enable\n"
               "CXL_APP_HWCC_BYTES must equal the app layout size: recsys-server --print-app-bytes [params].\n"
               "--print-layout prints the parameter summary and exits.\n");
  std::exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  Opts o;
  bool print_bytes = false, print_layout = false;
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
    else if (a == "--load-threads") o.load_threads = std::stoul(v());
    else if (a == "--publish-ms") o.publish_us = std::stoull(v()) * 1000;
    else if (a == "--publish-us") o.publish_us = std::stoull(v());
    else if (a == "--dim") o.p.dim = std::stoul(v());
    else if (a == "--row-cap") o.p.row_cap = std::stoull(v());
    else if (a == "--row-div") o.p.row_div = std::stoull(v());
    else if (a == "--load-factor") o.p.load_factor = std::stod(v());
    else if (a == "--ver-stripes") o.p.ver_stripes = std::stoul(v());
    else if (a == "--publish-frac") o.publish_frac = std::stod(v());
    else if (a == "--multi-hot-div") o.p.multi_hot_div = std::stoul(v());
    else if (a == "--rank") o.rank = std::stoul(v());
    else if (a == "--seed") o.p.seed = std::stoull(v());
    else if (a == "--verify-rows") o.verify_rows = std::stoul(v());
    else if (a == "--warm-up") o.warm_up = std::stoul(v());
    else if (a == "--test-no-seqlock") o.test_no_seqlock = true;
    else if (a == "--megalon-time-sample") o.megalon_time_sample = std::stoul(v());
    else if (a == "--check-stride") o.check_stride = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.megalon_lib = v();
    else if (a == "--proc-kthread") o.proc.kthread_prefixes.push_back(v());
    else if (a == "--proc-sysfs") o.proc.sysfs_dirs.push_back(v());
    else if (a == "--print-app-bytes") print_bytes = true;
    else if (a == "--print-layout") print_layout = true;
    else if (a == "--preload-only") o.preload_only = true;
    else if (a == "--preloaded") o.preloaded = true;
    else usage();
  }
  if (o.p.dim % 32 || o.p.ver_stripes == 0 || (o.p.ver_stripes & (o.p.ver_stripes - 1)) || o.p.load_factor <= 0 ||
      o.p.load_factor >= 1 || o.rank % 32 || o.publish_frac < 0 || o.publish_frac > 1) {
    std::fprintf(stderr, "recsys-server: dim and rank must be multiples of 32, 0 < load_factor < 1, --ver-stripes a "
                         "power of two, 0 <= --publish-frac <= 1\n");
    return 2;
  }
  o.p.derive();
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.p).L.bytes());
    return 0;
  }
  if (print_layout) {
    std::printf("%s app_bytes=%lu\n", o.p.describe().c_str(), (unsigned long)HwccLayout(o.p).L.bytes());
    for (uint32_t k = 0; k < kSparse; k++)
      std::printf("table %2u rows %9lu slots %9lu hot %3u\n", k, (unsigned long)o.p.rows[k], (unsigned long)o.p.slots[k],
                  o.p.hot[k]);
    if (o.publish_frac > 0)
      std::printf("publish_frac %.9g rows_per_round_target %lu (of %lu rows)\n", o.publish_frac,
                  (unsigned long)(o.publish_frac * double(o.p.total_rows) + 0.5), (unsigned long)o.p.total_rows);
    return 0;
  }
  if (o.run_id == 0 && !o.preload_only) usage();
  if ((o.preload_only || o.preloaded) && o.backend != "plain") {
    std::fprintf(stderr, "recsys-server: --preload-only/--preloaded are for the plain backend\n");
    return 2;
  }
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  if (o.backend == "plain") return run<PlainBackend>(o);
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

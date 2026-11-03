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
#include "opcoh.h"
#include "proc_stats.h"
#include "proto.h"
#include "qcoh.h"
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
  std::string trace_dir;    // sharing trace written at stop (empty: none; Megalon only; DESIGN.md §16)
  uint64_t trace_max_mb = 4096;  // per node trace buffer cap (records beyond it are dropped and counted)
  bool op_coh = true;       // per-operation time split (opcoh.h; --op-coh off disables the counter reads and blocks)
  // --init-capacity C (DESIGN.md §17): the init dir was built for C elements per segment (C <= capacity, same chunk
  // size). Chunk images are chunk-relative and per_chunk / lchunk do not depend on the capacity, so a larger run
  // capacity only adds groups. 0 = the run capacity (every earlier build).
  uint64_t init_capacity = 0;
  // Writer threads of this node (--writer-threads, default 1 = every run before the update-rate sweep). With N > 1
  // the node's writes are taken from one queue by N threads (DESIGN.md §17): segment writes stay serialised by the
  // segment's HWcc rwlock, an update's delete and insert stay on one thread in that order, the node's delete log is
  // appended under a node-local mutex (entries published in index order), applied/P are unchanged (bitmap + CAS).
  uint32_t writer_threads = 1;
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
  uint64_t t_acc = 0;  // write jobs: CLOCK_MONOTONIC when the connection reader queued it (write lag, DESIGN.md §17)
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
  std::atomic<uint64_t> inserts{0}, deletes{0}, updates{0}, searches{0}, timeouts{0}, bad_records{0}, dists{0},
      wait_ns{0}, replay_ns{0}, search_ns{0}, lock_ns{0}, insert_ns{0}, insert_lock_ns{0}, update_ns{0},
      search_busy_ns{0}, writer_busy_ns{0};
  std::atomic<uint64_t> opc_read_errors{0}, opc_register_errors{0}, opc_unattributed_ns{0}, opc_unattributed_t_ns{0};
  // stale-header guard (shm_hnsw.h SearchRejects, summed over every segment search; a staleness metric, PROJECT.md
  // "Evaluation run 2"); searches_with_stale_header = searches that rejected at least one header in some segment
  std::atomic<uint64_t> stale_header_rejects{0}, stale_link_rejects{0}, searches_with_stale_header{0};
  // write path accounting (DESIGN.md §17): jobs queued by the connection readers / finished by a writer (incl. bad
  // requests); lag = finish - queue time per job; lag max is a window value (reset by every stats read)
  std::atomic<uint64_t> write_jobs_accepted{0}, write_jobs_done{0}, write_lag_ns_sum{0}, write_lag_n{0}, write_lag_max_ns{0};
};

// Writer segment write-lock split (experiment popcorn-writer-lock-split, reports/experiments/; DESIGN.md §19). Off by
// default; VDB_LOCK_SPLIT=1 in the server environment turns it on (nothing is sampled or printed when off). Per insert,
// right after the segment write lock is acquired and right before it is released, the writer thread reads its own
// swmc_acct coherence counters (opcoh.h pop_now), its run-queue delay (/proc/thread-self/schedstat field 2, run_delay
// ns) and its CPU time (CLOCK_THREAD_CPUTIME_ID). hold = release - acquire (CLOCK_MONOTONIC, incl. the samples);
// hold_coh = coherence time C inside the hold (I->S + S->M + write-protect upgrade faults + coherence IPIs, as
// opt.<op>.c_ns; no-transition faults separately in hold_nt), hold_rq = run-queue delay inside the hold, hold_cpu =
// on-CPU time inside the hold. A fault that sleeps for its ACKs and then waits on the run queue counts in both coh and
// rq: hold_overlap_n counts inserts with hold_coh + hold_rq > hold. Histograms: log2 buckets of ns, b<k> = values in
// [2^k, 2^(k+1)) (b00 also 0; b39 also larger): hold per insert; per search: segment write-lock wait (sum over its
// segments, = the response's lock_us), per segment task the read-lock wait, E1 wait (= wait_us). Keys "lock_split.*".
struct LockSplit {
  static constexpr int kB = 40;
  std::atomic<uint64_t> inserts{0}, hold_ns{0}, hold_coh_ns{0}, hold_rq_ns{0}, hold_cpu_ns{0}, hold_nt_ns{0}, hold_nt_cnt{0},
      hold_ipi_ns{0}, hold_ipi_cnt{0}, hold_pf_ns[3]{}, hold_pf_cnt[3]{}, hold_overlap_n{0}, hold_max_ns{0}, sample_ns{0},
      coh_unavailable{0}, rq_errors{0}, searches{0}, search_lock_ns{0}, search_e1_ns{0}, seg_tasks{0};
  std::atomic<uint64_t> hold_hist[kB]{}, search_lock_hist[kB]{}, seg_lock_hist[kB]{}, e1_hist[kB]{};
  static int bucket(uint64_t ns) { return ns ? std::min(kB - 1, 63 - __builtin_clzll(ns)) : 0; }
  static void hist(std::atomic<uint64_t> *h, uint64_t ns) { h[bucket(ns)].fetch_add(1, std::memory_order_relaxed); }
  void print(std::ostream &o) {
    static const char *const pf[3] = {"is", "sm", "wp"};
    o << "\nlock_split.enabled=1\nlock_split.inserts=" << inserts << "\nlock_split.hold_ns=" << hold_ns
      << "\nlock_split.hold_coh_ns=" << hold_coh_ns << "\nlock_split.hold_rq_ns=" << hold_rq_ns
      << "\nlock_split.hold_cpu_ns=" << hold_cpu_ns << "\nlock_split.hold_nt_ns=" << hold_nt_ns
      << "\nlock_split.hold_nt_cnt=" << hold_nt_cnt << "\nlock_split.hold_ipi_ns=" << hold_ipi_ns
      << "\nlock_split.hold_ipi_cnt=" << hold_ipi_cnt;
    for (int i = 0; i < 3; i++)
      o << "\nlock_split.hold_" << pf[i] << "_ns=" << hold_pf_ns[i] << "\nlock_split.hold_" << pf[i] << "_cnt=" << hold_pf_cnt[i];
    o << "\nlock_split.hold_overlap_cnt=" << hold_overlap_n << "\nlock_split.hold_max_ns=" << hold_max_ns.exchange(0)
      << "\nlock_split.sample_ns=" << sample_ns << "\nlock_split.coh_unavailable=" << coh_unavailable
      << "\nlock_split.rq_errors=" << rq_errors << "\nlock_split.searches=" << searches
      << "\nlock_split.search_lock_ns=" << search_lock_ns << "\nlock_split.search_e1_ns=" << search_e1_ns
      << "\nlock_split.seg_tasks=" << seg_tasks;
    auto h = [&](const char *n, const std::atomic<uint64_t> *x) {
      for (int b = 0; b < kB; b++) o << "\nlock_split." << n << ".b" << (b < 10 ? "0" : "") << b << "=" << x[b];
    };
    h("hold_hist", hold_hist), h("search_lock_hist", search_lock_hist), h("seg_lock_hist", seg_lock_hist), h("e1_hist", e1_hist);
  }
};

// Run-queue delay of the calling thread (ns; schedstat field 2). One fd per thread, re-read with pread at offset 0
// (seq_file restarts at offset 0). false: open/read failed.
inline bool thread_run_delay(uint64_t *rq) {
  thread_local int fd = -1;
  if (fd < 0) fd = open("/proc/thread-self/schedstat", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  char b[128];
  const ssize_t n = pread(fd, b, sizeof(b) - 1, 0);
  if (n <= 0) return false;
  b[n] = 0;
  unsigned long long run = 0, delay = 0;
  if (std::sscanf(b, "%llu %llu", &run, &delay) != 2) return false;
  *rq = delay;
  return true;
}
inline uint64_t thread_cpu_ns() {
  timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

// Window counters of one operation type (opcoh.h), keys in the KV convention (workloads/kv/server/opsplit.h,
// experiments/analysis/v6_common.py): opt.<op>.{ops,t_ns,c_ns,mod_bytes}, opt.<op>.pop.<f>, opt.<op>.meg.<f>; sums over
// the operations answered (the same values as the response blocks; the server's completion time decides the window).
struct OpWin {
  static constexpr int kPop = 10, kMeg = 23, kAn = 11;
  std::atomic<uint64_t> ops{0}, sections{0}, t_ns{0}, c_ns{0}, mod_bytes{0}, wait_ns{0}, pop[kPop]{}, meg[kMeg]{}, an[kAn]{};
  std::atomic<uint64_t> meg_flags{0};  // OR of the blocks' Megalon flag bits as CohSnap.reserved[1] bits 1-2 (not a sum)
  // Megalon >= 77 raw probe data (not in the wire block; user decision 2026-10-17: kept raw, no correction):
  // AnchorSnap.reserved[3..5] timed (A) events, timed (B)+(C) events, timed (D) episodes (sums of deltas) and the
  // probe cost reserved[2] (ps; min / max over the threads seen)
  std::atomic<uint64_t> timed_a{0}, timed_bc{0}, timed_d{0}, probe_ps_min{0}, probe_ps_max{0};
  void add_raw(const OpAcc &a) {
    timed_a += a.an.reserved[3], timed_bc += a.an.reserved[4], timed_d += a.an.reserved[5];
    if (a.probe_ps_min) {
      uint64_t v = probe_ps_min.load();
      while ((!v || a.probe_ps_min < v) && !probe_ps_min.compare_exchange_weak(v, a.probe_ps_min)) {}
    }
    uint64_t v = probe_ps_max.load();
    while (a.probe_ps_max > v && !probe_ps_max.compare_exchange_weak(v, a.probe_ps_max)) {}
  }
  void add(const OpCoh &b) {
    ops++, sections += b.sections, t_ns += b.t_ns, c_ns += b.c_ns, mod_bytes += b.mod_bytes, wait_ns += b.wait_ns;
    meg_flags.fetch_or((b.src & 16 ? 2u : 0u) | (b.src & 32 ? 4u : 0u));
    const uint64_t p[kPop] = {b.pf_ns[0], b.pf_ns[1], b.pf_ns[2], b.pf_cnt[0], b.pf_cnt[1], b.pf_cnt[2], b.ipi_ns, b.ipi_cnt,
                              b.nontrans_ns, b.nontrans_cnt};
    const uint64_t m[kMeg] = {b.mg_read_sections, b.mg_write_sections, b.mg_check_ns_sampled, b.mg_check_sampled,
                              b.mg_stale_cnt, b.mg_stale_ns, b.mg_concur_cnt, b.mg_concur_ns, b.mg_meta_cnt,
                              b.mg_meta_ns, b.mg_spin_cnt, b.mg_spin_ns, b.mg_wstart_ns, b.mg_switch_rw_cnt,
                              b.mg_switch_rw_ns, b.mg_reclaim_cnt, b.mg_reclaim_ns, b.mg_wflush_cnt, b.mg_wflush_ns,
                              b.mg_wflush_bytes, b.vcopy_ns_sampled, b.vcopy_sampled, b.vcopy_cnt};
    for (int i = 0; i < kPop; i++) pop[i] += p[i];
    for (int i = 0; i < kMeg; i++) meg[i] += m[i];
    const uint64_t x[kAn] = {b.mg_read_sections, b.mg_write_sections, b.mg_check_sampled, b.an_read_lookup_ns_sampled,
                             b.an_read_nr_ns_sampled, b.an_rseq_ns_sampled, b.an_write_lookup_ns, b.an_write_nr_ns,
                             b.an_wseq_ns, b.an_wseq_end_ns, b.mg_write_sampled};
    for (int i = 0; i < kAn; i++) an[i] += x[i];
  }
  void print(std::ostream &o, const char *name) const {
    static const char *const pn[kPop] = {"is_ns", "sm_ns", "wp_ns", "is_cnt", "sm_cnt", "wp_cnt", "ipi_ns", "ipi_cnt",
                                         "nontrans_ns", "nontrans_cnt"};  // nontrans: not part of c_ns
    static const char *const mn[kMeg] = {"read_sections", "write_sections", "check_ns_sampled", "check_sampled",
                                         "stale_cnt", "stale_ns", "concur_cnt", "concur_ns", "meta_cnt", "meta_ns",
                                         "spin_cnt", "spin_ns", "wstart_ns", "switch_rw_cnt", "switch_rw_ns",
                                         "reclaim_cnt", "reclaim_ns", "wflush_cnt", "wflush_ns", "wflush_bytes",
                                         "vcopy_ns_sampled", "vcopy_sampled", "vcopy_cnt"};
    const std::string p = std::string("\nopt.") + name + ".";
    o << p << "ops=" << ops << p << "sections=" << sections << p << "t_ns=" << t_ns << p << "c_ns=" << c_ns << p
      << "mod_bytes=" << mod_bytes << p << "wait_ns=" << wait_ns;
    for (int i = 0; i < kPop; i++) o << p << "pop." << pn[i] << "=" << pop[i];
    for (int i = 0; i < kMeg; i++) o << p << "meg." << mn[i] << "=" << meg[i];
    static const char *const an_n[kAn] = {"read_sections", "write_sections", "check_sampled", "read_lookup_ns_sampled",
                                          "read_nr_ns_sampled", "rseq_ns_sampled", "write_lookup_ns", "write_nr_ns",
                                          "wseq_ns", "wseq_end_ns", "write_sampled"};  // AnchorSnap field names (shim
                                          // v3; write_sampled = reserved[0], Megalon >= 76)
    for (int i = 0; i < kAn; i++) o << p << "meg.anchor." << an_n[i] << "=" << an[i];
    o << p << "meg.flags=" << meg_flags;  // bit 1 lean sampling, bit 2 events_always (Megalon >= 76; else 0)
    o << p << "meg.anchor.timed_a=" << timed_a << p << "meg.anchor.timed_bc=" << timed_bc << p
      << "meg.anchor.timed_d=" << timed_d << p << "meg.anchor.probe_ps_min=" << probe_ps_min << p
      << "meg.anchor.probe_ps_max=" << probe_ps_max;  // Megalon >= 77 (else 0); raw, no correction applied
  }
};

template <class Be>
class Server {
 public:
  using Graph = HnswT<typename Be::Acc>;
  explicit Server(Opts o) : o_(std::move(o)), p_(o_.p) {}

  void start() {
    std::string err;
    if (p_.g.is_sq8()) {  // private quantizer copy, filled from HWcc after the start barrier (before any graph access)
      sq8_.assign(2 * size_t(p_.g.dim), 0.f);
      p_.g.sq8 = sq8_.data();
    }
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || o_.node >= p_.nr_nodes || p_.segments == 0) die("bad node/nodes/segments");
    HwccLayout lay(p_, Be::kLayoutTag);
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      // Megalon maps the whole device at map_va when its library initialises (dlopen; joins the run and waits in its
      // start barrier for every node); the server uses that mapping and never maps the device itself.
      if (1 + o_.writer_threads + o_.search_threads > 32) die("megalon: at most 32 registered threads per node (main, writer, searchers)");
      // threads the library starts while it initialises inherit this name (stats: thr.megalon-lib.*, the coherence
      // library's own CPU); the main thread gets its process name back afterwards (pgrep -x vdb-server)
      cxl::proc::name_thread("megalon-lib");
      api_ = megalon_load(o_.megalon_lib, &err);
      cxl::proc::name_thread("vdb-server");
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
    if constexpr (std::is_same_v<Be, PlainBackend>) {
      // De Stijl v2: staleness bound T ($CXL_DESTIJL_T_US, only with CXL_SYSTEM=ds) on every segment's arena (vectors
      // + links), once after the mapping; a no-op for every other system and for T unset / 0
      uint64_t t = 0;
      for (uint32_t s = 0; s < p_.segments; s++)
        if (cxl::region_apply_staleness(r_, be_->seg_arena(s), be_->seg_arena_bytes(), &t) != 0)
          die("de stijl staleness (CXL_DESTIJL_T_US) on segment " + std::to_string(s) + ": " + std::strerror(errno));
      if (t) std::fprintf(stderr, "vdb-server: de stijl staleness T=%lu us on %u segment arenas (%lu B each)\n",
                          (unsigned long)t, p_.segments, (unsigned long)be_->seg_arena_bytes());
    }
    tsc_khz_ = calibrate_tsc_khz();
    if constexpr (std::is_same_v<Be, MegalonBackend>)
      be_->set_trace(o_.trace_dir.empty() ? nullptr : h_->wsec, o_.node, (o_.trace_max_mb << 20) / sizeof(TraceRec),
                     tsc_khz_);
    {  // trace lines' device offsets (Host tests check that they stay 0 without --trace-dir; objseq is unused since
       // vdb build 10 and must stay 0)
      const uint64_t app = uint64_t(cxl::hwcc::app_base(r_, map_) - map_);
      std::fprintf(stderr, "vdb-server: trace %s (%s), wsec at device offset %lu, objseq at %lu (%lu objects)\n",
                   o_.trace_dir.empty() ? "off" : "on", Be::kLayoutTag[0] ? "megalon" : "plain: unused",
                   (unsigned long)(app + lay.off_wsec), (unsigned long)(app + lay.off_objseq),
                   (unsigned long)p_.trace_objects());
    }
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
    if (p_.g.is_sq8()) {
      const Sq8Line &l = *h_->sq8;
      if (load_acquire(&l.ready) != kSq8Magic || l.dim != p_.g.dim) die("sq8: quantizer not published by node 0 in HWcc");
      std::memcpy(sq8_.data(), h_->sq8_params(), sq8_.size() * sizeof(float));
      if (sq8_fnv(sq8_.data(), p_.g.dim) != l.fnv) die("sq8: quantizer checksum mismatch");
      std::fprintf(stderr, "vdb-server: vector format sq8 (quantizer fnv %016lx, record %lu B)\n", (unsigned long)l.fnv,
                   (unsigned long)p_.g.vrec_bytes());
    } else {
      std::fprintf(stderr, "vdb-server: vector format fp32 (record %lu B)\n", (unsigned long)p_.g.vrec_bytes());
    }
    warm_up();
    opc_setup();
    if (o_.writer_threads > 1) std::fprintf(stderr, "vdb-server: writer threads %u\n", o_.writer_threads);
    for (uint32_t w = 0; w < o_.writer_threads; w++) std::thread([this, w] { writer(w); }).detach();
    for (uint32_t i = 0; i < o_.search_threads; i++) std::thread([this, i] { searcher(int(2 + i)); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  // End of run: measurement traces into --trace-dir (node<K>.*; the harness collects node<K>.* from the run dir).
  void dump_traces() {
    if (o_.trace_dir.empty()) return;
    std::string err;
    if constexpr (std::is_same_v<Be, MegalonBackend>)
      if (!be_->dump_trace(o_.trace_dir + "/node" + std::to_string(o_.node) + ".vdbtrace.bin", &err))
        std::fprintf(stderr, "vdb-server: %s\n", err.c_str());
  }

  std::string stats_text() {
    std::ostringstream o;
    uint64_t elems = 0;
    for (auto &g : g_) elems += g->count();
    o << "node=" << o_.node << "\nP=" << load_acquire(h_->P) << "\nelements=" << elems << "\ninserts=" << st_.inserts
      << "\ndeletes=" << st_.deletes << "\nupdates=" << st_.updates << "\nsearches=" << st_.searches << "\ntimeouts=" << st_.timeouts
      << "\nbad_records=" << st_.bad_records << "\ndists=" << st_.dists << "\nwait_ms=" << st_.wait_ns / 1000000
      << "\nreplay_ms=" << st_.replay_ns / 1000000 << "\nsearch_ms=" << st_.search_ns / 1000000
      << "\nsearch_lock_ms=" << st_.lock_ns / 1000000 << "\ninsert_ms=" << st_.insert_ns / 1000000
      << "\ninsert_lock_ms=" << st_.insert_lock_ns / 1000000 << "\nwrite_queue=" << wq_.size()
      << "\nsearch_busy_ns=" << st_.search_busy_ns << "\nwriter_busy_ns=" << st_.writer_busy_ns
      << "\nupdate_ns=" << st_.update_ns << "\nsearch_ns_total=" << st_.search_ns << "\nwait_ns_total=" << st_.wait_ns
      << "\nreplay_ns_total=" << st_.replay_ns << "\nsearch_lock_ns_total=" << st_.lock_ns
      << "\ninsert_ns_total=" << st_.insert_ns << "\ninsert_lock_ns_total=" << st_.insert_lock_ns
      << "\nsearch_queue=" << search_queue_len();
    o << "\nstale_header_rejects=" << st_.stale_header_rejects << "\nstale_link_rejects=" << st_.stale_link_rejects
      << "\nsearches_with_stale_header=" << st_.searches_with_stale_header << "\nzeroed_unused_bytes=" << zeroed_bytes_
      << "\nzeroed_unused_ms=" << zeroed_ns_ / 1000000;
    {  // write path (DESIGN.md §17): done is read before accepted, so backlog >= 0
      const uint64_t done = st_.write_jobs_done.load(), acc = st_.write_jobs_accepted.load();
      o << "\nwriter_threads=" << o_.writer_threads << "\nwrite_jobs_accepted=" << acc << "\nwrite_jobs_done=" << done
        << "\nwrite_backlog=" << (acc >= done ? acc - done : 0) << "\nwrite_lag_ns_sum=" << st_.write_lag_ns_sum
        << "\nwrite_lag_n=" << st_.write_lag_n << "\nwrite_lag_max_ns=" << st_.write_lag_max_ns.exchange(0);
    }
    o << "\nopcoh.enabled=" << int(oc_.on()) << "\nopcoh.pop_source=" << pop_src_name(oc_.src())
      << "\nopcoh.mg_cohsnap=" << int(oc_.mg_snap()) << "\nopcoh.tsc_khz=" << tsc_khz_ << "\nopcoh.clock_ns=" << clock_ns_
      << "\nopcoh.read_errors=" << st_.opc_read_errors << "\nopcoh.register_errors=" << st_.opc_register_errors
      << "\nopcoh.unattributed_c_ns=" << st_.opc_unattributed_ns << "\nopcoh.unattributed_t_ns=" << st_.opc_unattributed_t_ns;
    o << "\nopt.version=1\nopt.c_source=" << (std::is_same_v<Be, MegalonBackend> ? "megalon" : "popcorn")
      << "\nopt.tsc_hz=" << uint64_t(tsc_khz_) * 1000 << "\nopt.meg_coh=" << int(oc_.mg_snap())
      << "\nopt.meg_check_sample=" << oc_.mg_check_sample() << "\nopt.meg_anchor=" << int(oc_.an_snap());
    win_search_.print(o, "search");
    win_update_.print(o, "update");
    if (lock_split_) ls_.print(o);  // VDB_LOCK_SPLIT=1 only (default: no lock_split.* keys)
    for (uint32_t v = 0; v < p_.nr_nodes; v++) o << "\ndlog_count." << v << "=" << load_acquire(&h_->nodes[v].dlog_count);
    o << "\nbackend=" << be_->usage() << "\n" << be_->stats();
    o << "\n" << cxl::proc::text(pst_);
    return o.str();
  }

 private:
  uint64_t init_capacity() const { return o_.init_capacity ? o_.init_capacity : p_.g.capacity; }

  // ---------------------------------------------------------------- initial segments (prepare, node 0, unmeasured)
  // init_dir: segments.txt ("<s> <count> <ep_level> <upper_cur>"), per group g < ceil(count / per_chunk):
  // seg-<s>-v<g>.bin (vector chunk, used bytes) and seg-<s>-l<g>.bin (whole link chunk); manifest.txt with the graph
  // parameters. Images are copied into the chunk objects as is (offsets are chunk-relative).
  // init dir parameter check (load_initial, preload): the "graph ..." line must match; an sq8 dir has the line
  // "vec_format sq8" (fp32 dirs, i.e. every dir before SQ8, have none) and it must match --vec-format
  void check_manifest() const {
    std::ifstream man(o_.init_dir + "/manifest.txt");
    std::string line, want = "graph " + std::to_string(p_.segments) + " " + std::to_string(p_.g.dim) + " " +
                             std::to_string(p_.g.M) + " " + std::to_string(p_.g.ef_construction) + " " +
                             std::to_string(init_capacity()) + " " + std::to_string(p_.g.chunk_bytes);
    bool ok = false, sq8 = false;
    while (std::getline(man, line)) ok = ok || line == want, sq8 = sq8 || line == "vec_format sq8";
    if (!ok) die("init_dir manifest does not contain '" + want + "' (built for other parameters)");
    if (sq8 != p_.g.is_sq8())
      die(std::string("init_dir vector format ") + (sq8 ? "sq8" : "fp32") + " != --vec-format " + (p_.g.is_sq8() ? "sq8" : "fp32"));
  }

  // sq8: node 0 publishes the init dir's quantizer (sq8.bin = min[dim], scale[dim] as float32) in HWcc
  void publish_sq8() {
    if (o_.init_dir.empty()) die("--vec-format sq8 needs --init-dir on node 0 (quantizer sq8.bin)");
    float *dst = h_->sq8_params();
    read_file(o_.init_dir + "/sq8.bin", reinterpret_cast<uint8_t *>(dst), uint64_t(p_.g.dim) * 8);
    for (uint32_t i = 0; i < p_.g.dim; i++)
      if (!(dst[p_.g.dim + i] >= 0) || !std::isfinite(dst[i]) || !std::isfinite(dst[p_.g.dim + i])) die("sq8.bin: bad parameters");
    h_->sq8->dim = p_.g.dim;
    h_->sq8->fnv = sq8_fnv(dst, p_.g.dim);
    store_release(&h_->sq8->ready, kSq8Magic);
  }

  // Preload zeroing (run 2, user decision 2026-11-03; stale-header guard in shm_hnsw.h): after the initial images,
  // node 0 zeroes every byte of segment s's chunks that the images did not write — the vector records [count, capacity)
  // of every group (the tail of the last populated group and the whole vector chunk of every later group) and the
  // link chunks of the groups without initial records (populated groups' link chunks are written whole by the image).
  // A never-written slot then holds zeros (canary fails), never bytes of an earlier experiment on the device. Same
  // code in every system: through the backend's write_chunk (plain mapping for --preload-only, Megalon write sections
  // over whole lines). Returns the bytes zeroed.
  uint64_t zero_unused(uint32_t s, uint64_t count) {
    const uint64_t N = p_.g.per_chunk(), vr = p_.g.vrec_bytes(), vc = p_.g.vchunk_bytes(), lc = p_.g.lchunk_bytes();
    uint64_t bytes = 0;
    for (uint64_t g = 0; g < p_.g.groups(); g++) {
      const uint64_t used = g * N < count ? std::min(N, count - g * N) : 0, vb = used * vr;
      if (vb < vc) {
        be_->write_chunk(Chunk::kVec, s, g, vb, vc - vb, [&](uint8_t *dst) { std::memset(dst, 0, vc - vb); });
        bytes += vc - vb;
      }
      if (!used) {
        be_->write_chunk(Chunk::kLink, s, g, 0, lc, [&](uint8_t *dst) { std::memset(dst, 0, lc); });
        bytes += lc;
      }
    }
    return bytes;
  }
  void zero_report(const char *where) const {
    std::fprintf(stderr, "vdb-server: ZEROED UNUSED %lu MiB of slot capacity in %.1f s (%s)\n",
                 (unsigned long)(zeroed_bytes_ >> 20), zeroed_ns_ / 1e9, where);
  }

  void load_initial() {
    for (uint32_t s = 0; s < p_.segments; s++) Graph::init_empty(&h_->segs[s].meta);
    const uint64_t t0 = now_ns();
    std::string err;
    if (!be_->create_objects(&err)) die(err);
    if (p_.g.is_sq8()) {
      if (!o_.init_dir.empty()) check_manifest();
      publish_sq8();
    }
    if (o_.init_dir.empty()) {  // no initial records: every slot is unused
      const uint64_t z0 = now_ns();
      for (uint32_t s = 0; s < p_.segments; s++) zeroed_bytes_ += zero_unused(s, 0);
      zeroed_ns_ += now_ns() - z0;
      zero_report("load, no init dir");
      return;
    }
    check_manifest();
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
      if (!o_.preloaded) {  // --preloaded: --preload-only zeroed them before coherence was enabled
        const uint64_t z0 = now_ns();
        zeroed_bytes_ += zero_unused(uint32_t(s), count);
        zeroed_ns_ += now_ns() - z0;
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
    if (!o_.preloaded) zero_report("load");
  }

 public:
  // --preload-only (plain backend, node 0): copy the initial chunk images into SWcc through a plain mapping, then
  // unmap and return. Touches no HWcc (no app_init, no meta); run before Popcorn enables coherence.
  void preload() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (o_.init_dir.empty()) die("--preload-only needs --init-dir");
    if (o_.node != 0) die("--preload-only runs on node 0 only");
    check_manifest();  // same check as load_initial: refuse an init dir built for other parameters before writing
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
      const uint64_t z0 = now_ns();  // never-written slot capacity (zero_unused), timed separately
      zeroed_bytes_ += zero_unused(uint32_t(s), count);
      zeroed_ns_ += now_ns() - z0;
      total += count;
    }
    if (munmap(m, r_.device_size) != 0) die("munmap");
    close(fd);
    zero_report("preload");
    std::fprintf(stderr, "vdb-server: PRELOAD DONE %lu records, %lu MiB in %.1f s (plain mapping, no HWcc access; "
                 "incl. zeroing %.1f s)\n",
                 (unsigned long)total, (unsigned long)(bytes >> 20), (now_ns() - t0) / 1e9, zeroed_ns_ / 1e9);
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

  // ---------------------------------------------------------------- per-operation time split (opcoh.h)
  // Main thread, after warm-up, before the worker threads start: timer calibration (Megalon wrapper), the Popcorn
  // counter source (swmc_acct, the build-8 file, or the Host-test fake VDB_OPCOH_FAKE=1) and Megalon's CohSnap.
  void opc_setup() {
    clock_ns_ = calibrate_clock_ns();
    if constexpr (std::is_same_v<Be, MegalonBackend>) be_->set_clock_ns(clock_ns_);
    const char *fake = getenv("VDB_OPCOH_FAKE");
    CohSnapFn mg = nullptr;
    AnchorSnapFn an = nullptr;
    if constexpr (std::is_same_v<Be, MegalonBackend>) mg = be_->thread_coh(), an = be_->thread_anchor();
    std::string why;
    oc_.setup(o_.op_coh, fake && std::string(fake) == "1", mg, tsc_khz_, &why, an);
    const bool meg = std::is_same_v<Be, MegalonBackend>;
    std::fprintf(stderr, "vdb-server: op coherence %s, popcorn source %s%s%s, megalon cohsnap %s, megalon anchor %s, tsc %u kHz, "
                 "clock_ns %u\n", oc_.on() ? "on" : "off", pop_src_name(oc_.src()), why.empty() ? "" : " (",
                 why.empty() ? "" : (why + ")").c_str(), meg ? (oc_.mg_snap() ? "on" : "absent") : "n/a",
                 meg ? (oc_.an_snap() ? "on" : "absent") : "n/a", tsc_khz_, clock_ns_);
    const char *ls = getenv("VDB_LOCK_SPLIT");
    lock_split_ = ls && std::string(ls) == "1";
    if (lock_split_) {
      const char *fn = getenv("VDB_LOCK_SPLIT_FAKE_NS");
      if (fn && *fn) {
        if (oc_.src() != kPopFake) die("VDB_LOCK_SPLIT_FAKE_NS needs VDB_OPCOH_FAKE=1 (Host test only)");
        ls_fake_ns_ = std::stoull(fn);
      }
      uint64_t rq;
      std::fprintf(stderr, "vdb-server: lock split on (writer hold: coherence %s, run queue %s%s)\n",
                   oc_.src() == kPopAcct || oc_.src() == kPopFake ? pop_src_name(oc_.src()) : "unavailable",
                   thread_run_delay(&rq) ? "schedstat" : "unavailable",
                   ls_fake_ns_ ? (", fake " + std::to_string(ls_fake_ns_) + " ns wp per insert").c_str() : "");
    }
  }
  // Worker thread start (after thread_init).
  void opc_thread_start() {
    if (!oc_.thread_start()) st_.opc_register_errors++;
  }
  void opc_end(const OpCohSrc::Start &s, OpAcc *a) {
    if (!oc_.end(s, a)) st_.opc_read_errors++;
  }

  static void read_file(const std::string &path, uint8_t *dst, uint64_t n) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f || uint64_t(f.tellg()) != n) die(path + ": missing or size != " + std::to_string(n));
    f.seekg(0);
    f.read(reinterpret_cast<char *>(dst), std::streamsize(n));
    if (!f) die("short read " + path);
  }

  // ---------------------------------------------------------------- writer (this node's writes, arrival order)
  // wi = writer index (0 .. writer_threads - 1). Writer 0 uses the node's HNSW level generator rng_ (seeded as in
  // every earlier build); further writers own a generator seeded from (seed, node, wi).
  void writer(uint32_t wi) {
    cxl::proc::name_thread("vdb-writer");
    be_->thread_init(1);
    opc_thread_start();
    const uint32_t dim = p_.g.dim;
    std::mt19937_64 own;
    if (wi) own.seed((o_.seed * 1000003 + o_.node) ^ (0x9e3779b97f4a7c15ull * wi));
    std::mt19937_64 &rng = wi ? own : rng_;
    for (;;) {
      Job j = wq_.pop();
      const uint64_t b0 = now_ns();
      const uint32_t n = frame::payload_len(j.h);
      if (j.h.code == kOpInsert && n == sizeof(InsertReq) + dim * 4) {
        InsertReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (!valid(rq.id, rq.w_seq)) { bad(j); job_done(j); continue; }
        do_insert(rq.w_seq, rq.id, reinterpret_cast<const float *>(j.p.data() + sizeof(rq)), rng);
        publish(rq.w_seq);
        reply_write(j, rq.w_seq);
        st_.inserts++;
      } else if (j.h.code == kOpDelete && n == sizeof(DeleteReq)) {
        DeleteReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (!valid(rq.id, rq.w_seq)) { bad(j); job_done(j); continue; }
        do_delete(rq.w_seq, rq.id);
        publish(rq.w_seq);
        reply_write(j, rq.w_seq);
        st_.deletes++;
      } else if (j.h.code == kOpUpdate && n == sizeof(UpdateReq) + dim * 4) {
        UpdateReq rq;
        std::memcpy(&rq, j.p.data(), sizeof(rq));
        if (!valid(rq.del_id, rq.w_del) || !valid(rq.ins_id, rq.w_ins) || rq.w_ins != rq.w_del + 1) { bad(j); job_done(j); continue; }
        const uint64_t t0 = now_ns();
        OpCohSrc::Start os;
        OpAcc oa;
        oc_.begin(&os);  // one section on this thread: delete + publish + insert + publish
        do_delete(rq.w_del, rq.del_id);
        publish(rq.w_del);
        do_insert(rq.w_ins, rq.ins_id, reinterpret_cast<const float *>(j.p.data() + sizeof(rq)), rng);
        publish(rq.w_ins);
        oc_.fake_add(1, 1000, 0, 500);  // Host-test fake: 1000 ns S->M and 500 ns no-transition fault per update
        opc_end(os, &oa);
        reply_update(j, rq.w_ins, oa);
        st_.update_ns += now_ns() - t0;
        st_.updates++;
        st_.deletes++;
        st_.inserts++;
      } else {
        bad(j);
        job_done(j);
        continue;
      }
      st_.writer_busy_ns += now_ns() - b0;
      job_done(j);
    }
  }

  void job_done(const Job &j) {
    const uint64_t lag = now_ns() - j.t_acc;
    st_.write_lag_ns_sum += lag;
    st_.write_lag_n++;
    uint64_t m = st_.write_lag_max_ns.load();
    while (lag > m && !st_.write_lag_max_ns.compare_exchange_weak(m, lag)) {}
    st_.write_jobs_done++;
  }

  bool valid(uint64_t id, uint32_t w) const { return id < p_.max_ids && w != 0 && w <= p_.max_writes; }

  void do_insert(uint32_t w, uint64_t id, const float *vec, std::mt19937_64 &rng) {
    const uint64_t t0 = now_ns();
    SegLines &sl = h_->segs[p_.seg_of(id)];
    cxl::hwcc::write_lock(&sl.lock);
    const uint64_t t1 = now_ns();
    LsSample s0;
    uint64_t t1s = t1;  // end of the acquire-side sample
    if (lock_split_) ls_sample(&s0), t1s = now_ns();
    try {
      g_[p_.seg_of(id)]->insert(id, w, vec, rng);
    } catch (const std::exception &e) {  // never leave the cross-VM write lock held (peers would spin)
      cxl::hwcc::write_unlock(&sl.lock);
      die(std::string("insert: ") + e.what());
    }
    if (lock_split_) ls_hold(s0, t1, t1s);
    cxl::hwcc::write_unlock(&sl.lock);
    st_.insert_lock_ns += t1 - t0;
    st_.insert_ns += now_ns() - t0;
  }

  // ---------------------------------------------------------------- writer lock split (VDB_LOCK_SPLIT=1, LockSplit)
  struct LsSample {
    OpCohSrc::PopNow coh;
    uint64_t rq = 0, cpu = 0;
    bool coh_ok = false, rq_ok = false;
  };
  void ls_sample(LsSample *s) {
    s->coh_ok = oc_.pop_now(&s->coh);
    s->rq_ok = thread_run_delay(&s->rq);
    s->cpu = thread_cpu_ns();
  }
  // Called holding the segment write lock acquired at t1 (CLOCK_MONOTONIC), right before the release.
  void ls_hold(const LsSample &s0, uint64_t t1, uint64_t t1s) {
    // Host test only (fake coherence source): VDB_LOCK_SPLIT_FAKE_NS ns of write-protect upgrade fault inside the hold
    if (ls_fake_ns_) oc_.fake_add(2, ls_fake_ns_, 0);
    const uint64_t a = now_ns();
    LsSample s1;
    ls_sample(&s1);
    const uint64_t t2 = now_ns(), hold = t2 - t1;
    LockSplit &L = ls_;
    L.inserts++;
    L.hold_ns += hold;
    LockSplit::hist(L.hold_hist, hold);
    uint64_t m = L.hold_max_ns.load();
    while (hold > m && !L.hold_max_ns.compare_exchange_weak(m, hold)) {}
    const uint64_t cpu = s1.cpu - s0.cpu;
    L.hold_cpu_ns += cpu;
    uint64_t coh = 0, rq = 0;
    if (s0.coh_ok && s1.coh_ok) {
      coh = s1.coh.coh_ns() - s0.coh.coh_ns();
      L.hold_coh_ns += coh;
      for (int i = 0; i < 3; i++) L.hold_pf_ns[i] += s1.coh.pf_ns[i] - s0.coh.pf_ns[i], L.hold_pf_cnt[i] += s1.coh.pf_cnt[i] - s0.coh.pf_cnt[i];
      L.hold_ipi_ns += s1.coh.ipi_ns - s0.coh.ipi_ns, L.hold_ipi_cnt += s1.coh.ipi_cnt - s0.coh.ipi_cnt;
      L.hold_nt_ns += s1.coh.nt_ns - s0.coh.nt_ns, L.hold_nt_cnt += s1.coh.nt_cnt - s0.coh.nt_cnt;
    } else {
      L.coh_unavailable++;
    }
    if (s0.rq_ok && s1.rq_ok) {
      rq = s1.rq - s0.rq;
      L.hold_rq_ns += rq;
    } else {
      L.rq_errors++;
    }
    if (coh + rq > hold) L.hold_overlap_n++;
    L.sample_ns += (t1s - t1) + (t2 - a);  // cost of the two samples (inside the hold)
  }

  void bad(Job &j) { j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0); }

  // With several writer threads the append (entry index, entry write, release of dlog_count) runs under dlog_mu_, so
  // dlog_count never covers an entry that is not written yet (readers replay [cursor, dlog_count)).
  void do_delete(uint32_t w, uint64_t id) {
    std::unique_lock<std::mutex> g(dlog_mu_, std::defer_lock);
    if (o_.writer_threads > 1) g.lock();
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
  void publish(uint32_t w) {
    fetch_or(&h_->applied[w >> 6], uint64_t(1) << (w & 63));
    uint64_t p = load_acquire(h_->P);
    for (;;) {
      uint64_t q = p;
      while (q + 1 <= p_.max_writes && (load_acquire(&h_->applied[(q + 1) >> 6]) >> ((q + 1) & 63) & 1)) q++;
      if (q == p || cxl::hwcc::cas(h_->P, &p, q)) break;
    }
    if (o_.writer_threads > 1) __atomic_fetch_add(&h_->nodes[o_.node].writes_applied, uint64_t(1), __ATOMIC_RELAXED);
    else h_->nodes[o_.node].writes_applied++;
  }

  void reply_write(Job &j, uint32_t w) {
    WriteResp r{w, uint32_t(load_acquire(h_->P))};
    j.c->reply(frame::kStatusOk, j.h.req_id, &r, sizeof(r));
  }
  // Update response: WriteResp + OpCoh (op coherence on)
  void reply_update(Job &j, uint32_t w, const OpAcc &a) {
    if (!oc_.on()) return reply_write(j, w);
    uint8_t out[sizeof(WriteResp) + sizeof(OpCoh)];
    WriteResp r{w, uint32_t(load_acquire(h_->P))};
    OpCoh b = op_block(a, kOpUpdate, oc_.src(), oc_.mg_snap(), tsc_khz_, oc_.an_snap());
    b.req_id = j.h.req_id;
    std::memcpy(out, &r, sizeof(r));
    std::memcpy(out + sizeof(r), &b, sizeof(b));
    win_update_.add(b);
    win_update_.add_raw(a);
    j.c->reply(frame::kStatusOk, j.h.req_id, out, sizeof(out));
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
    std::atomic<uint64_t> stale_headers{0};  // stale-header guard rejects over the query's segment searches
    std::mutex mu;
    std::vector<std::pair<float, uint64_t>> all;
    OpAcc oa;  // per-operation time split (under mu once the segment tasks are published)
  };

  void push_search(Job j) {
    {
      std::lock_guard<std::mutex> g(smu_);
      queries_.push_back(std::move(j));
    }
    scv_.notify_one();
  }

  void searcher(int tid) {
    cxl::proc::name_thread("vdb-search");
    be_->thread_init(tid);
    opc_thread_start();
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
      const uint64_t b0 = now_ns();
      if (task) {
        run_segment(task);
        release(task);
        st_.search_busy_ns += now_ns() - b0;
        continue;
      }
      QueryCtx *c = start_query(std::move(job));
      if (!c) {
        st_.search_busy_ns += now_ns() - b0;
        continue;
      }
      c->refs.store(p_.segments);  // S - 1 task entries + this owner
      {
        std::lock_guard<std::mutex> g(smu_);
        for (uint32_t x = 1; x < p_.segments; x++) tasks_.push_back(c);
      }
      scv_.notify_all();
      while (run_segment(c)) {
      }
      release(c);
      st_.search_busy_ns += now_ns() - b0;
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
    OpCohSrc::Start os;
    oc_.begin(&os);
    c->t0 = now_ns();
    // E1 readiness: P >= s (every write <= s applied by its writer)
    if (!cxl::hwcc::poll_until([&] { return load_acquire(h_->P) >= c->s; }, o_.wait_timeout_ms)) {
      st_.timeouts++;
      OpAcc d;  // no response carries this section
      opc_end(os, &d);
      st_.opc_unattributed_ns += pop_coh_ns(d) + mg_coh_ns(d);
      st_.opc_unattributed_t_ns += ticks_to_ns(d.ticks, tsc_khz_);
      j.c->reply(frame::kStatusTimeout, j.h.req_id, nullptr, 0);
      delete c;
      return nullptr;
    }
    c->t1 = now_ns();
    c->oa.wait_ticks += rdtsc() - os.tsc;  // E1 wait, part of the start section
    for (uint32_t u = 0; u < p_.nr_nodes; u++) {
      uint64_t n = load_acquire(&h_->nodes[u].dlog_count);
      if (__atomic_load_n(&dcursor_[u], __ATOMIC_ACQUIRE) < n) replay(u, n);
    }
    c->t2 = now_ns();
    opc_end(os, &c->oa);  // start section (E1 wait + delete-log replay); c is not shared yet
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
    OpCohSrc::Start os;
    oc_.begin(&os);
    const uint64_t l0 = now_ns();
    cxl::hwcc::read_lock(&sl.lock);
    const uint64_t lw = now_ns() - l0;
    c->lock_ns += lw;
    if (lock_split_) LockSplit::hist(ls_.seg_lock_hist, lw), ls_.seg_tasks++;
    const Graph &g = *g_[sg];
    const uint32_t s = c->s;
    auto allowed = [&](uint32_t i) {  // E1 visibility + stale-header guard (layout.h elem_visible)
      ElemHeader tmp;
      return elem_visible(g.header(i, tmp), s, del_seq_.get(), p_);
    };
    uint64_t nd = 0;
    SearchRejects rj;
    g.search(c->q, c->k, o_.ef, allowed, &part, visited, tag, &nd, &rj);
    if (rj.headers) st_.stale_header_rejects += rj.headers, c->stale_headers += rj.headers;
    if (rj.links) st_.stale_link_rejects += rj.links;
    std::vector<std::pair<float, uint64_t>> mine;
    for (auto &pr : part) {
      ElemHeader tmp;
      mine.emplace_back(pr.first, g.header(pr.second, tmp).ext_id);
    }
    cxl::hwcc::read_unlock(&sl.lock);
    c->dists += nd;
    oc_.fake_add(0, nd, nd / 8);  // Host-test fake: I->S fault time = distance computations, IPI = 1/8 of it
    OpAcc d;
    opc_end(os, &d);  // before done.fetch_add: the finishing thread sees every section's delta
    {
      std::lock_guard<std::mutex> lg(c->mu);
      c->all.insert(c->all.end(), mine.begin(), mine.end());
      c->oa.add(d);
    }
    if (c->done.fetch_add(1) + 1 == p_.segments) finish_query(c);
    return true;
  }

  void finish_query(QueryCtx *c) {
    const uint64_t m0 = rdtsc();  // merge + encode on the finishing thread: part of T (no shared memory, no C)
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
    OpCoh qb{};
    OpAcc qa;  // copy for the raw window counters (add_raw)
    {
      std::lock_guard<std::mutex> lg(c->mu);
      c->oa.ticks += rdtsc() - m0;  // up to the response being ready (the reply send is outside T)
      qb = op_block(c->oa, kOpSearch, oc_.src(), oc_.mg_snap(), tsc_khz_, oc_.an_snap());
      qb.req_id = c->job.h.req_id;
      qa = c->oa;
    }
    if (oc_.on()) resp.flags |= kRespCoh;
    std::vector<uint8_t> out(sizeof(resp) + all.size() * 12 + (oc_.on() ? sizeof(qb) : 0));
    std::memcpy(out.data(), &resp, sizeof(resp));
    for (size_t x = 0; x < all.size(); x++) {
      const float score = -all[x].first;  // inner product
      std::memcpy(out.data() + sizeof(resp) + x * 8, &all[x].second, 8);
      std::memcpy(out.data() + sizeof(resp) + all.size() * 8 + x * 4, &score, 4);
    }
    if (oc_.on()) {
      std::memcpy(out.data() + sizeof(resp) + all.size() * 12, &qb, sizeof(qb));
      win_search_.add(qb);
      win_search_.add_raw(qa);
    }
    c->job.c->reply(frame::kStatusOk, c->job.h.req_id, out.data(), uint32_t(out.size()));
    st_.searches++;
    if (c->stale_headers.load()) st_.searches_with_stale_header++;
    st_.dists += c->dists.load();
    st_.wait_ns += c->t1 - c->t0;
    st_.replay_ns += c->t2 - c->t1;
    st_.search_ns += t3 - c->t2;
    st_.lock_ns += c->lock_ns.load();
    if (lock_split_) {  // per search: segment write-lock wait (sum over its segments) and E1 wait
      const uint64_t lw = c->lock_ns.load(), e1 = c->t1 - c->t0;
      ls_.searches++, ls_.search_lock_ns += lw, ls_.search_e1_ns += e1;
      LockSplit::hist(ls_.search_lock_hist, lw), LockSplit::hist(ls_.e1_hist, e1);
    }
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
    cxl::proc::name_thread("vdb-listen");
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
    cxl::proc::name_thread("vdb-conn");
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpInsert:
        case kOpDelete:
        case kOpUpdate:
          j.t_acc = now_ns();
          st_.write_jobs_accepted++;
          wq_.push(std::move(j));
          break;
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
  std::vector<float> sq8_;  // sq8: private copy of the HWcc quantizer (p_.g.sq8 points here; read-only after start)
  Stats st_;
  // kthreads: receive thread cxl_recv_<n> and (run 2 adaptive receiver) idle pollers cxl_ipoll/<cpu>, kept apart
  cxl::proc::Opts pst_{{"cxl_recv", "cxl_ipoll"},
                       {"TLB", "CAL", "RES", "LOC"},
                       {"/sys/kernel/swmc/page_coherence", "/sys/kernel/swmc/instr", "/sys/kernel/cxl_shm",
                        "/sys/kernel/cxl_shm/instr"}};
  Queue wq_;
  std::mutex smu_;  // search scheduling
  std::condition_variable scv_;
  std::deque<Job> queries_;
  std::deque<QueryCtx *> tasks_;
  uint64_t dlog_next_ = 0;  // writer (writer_threads > 1: under dlog_mu_)
  std::mutex dlog_mu_;      // delete-log append with several writer threads
  std::mt19937_64 rng_;     // writer 0: HNSW levels
  std::unique_ptr<uint32_t[]> del_seq_;
  uint64_t zeroed_bytes_ = 0, zeroed_ns_ = 0;  // preload zeroing of the unused slot capacity (node 0, zero_unused)
  std::vector<uint64_t> dcursor_;
  std::unique_ptr<std::mutex[]> dmu_;
  OpCohSrc oc_;
  OpWin win_search_, win_update_;
  bool lock_split_ = false;  // VDB_LOCK_SPLIT=1 (set in opc_setup, before the worker threads start)
  uint64_t ls_fake_ns_ = 0;  // VDB_LOCK_SPLIT_FAKE_NS (Host test with VDB_OPCOH_FAKE=1 only)
  LockSplit ls_;
  uint32_t clock_ns_ = 0, tsc_khz_ = 0;
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
  s.dump_traces();
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
               "  [--trace-dir DIR] [--trace-max-mb M (4096)]   Megalon sharing trace (HWcc wsec line; node<K>.vdbtrace.bin at\n"
               "     stop; dedicated runs only; DESIGN.md §16)\n"
               "  [--op-coh on|off] per-operation time split block in every search/update response (default on; DESIGN.md §15)\n"
               "  [--writer-threads N] writer threads of this node (default 1; plain backend only for N > 1; DESIGN.md §17)\n"
               "  [--init-capacity C] init dir built for C elements per segment (<= capacity; default the capacity; §17)\n"
               "  [--vec-format fp32|sq8] stored vectors (default fp32; sq8 = 8-bit scalar quantization, init dir built\n"
               "     with vdb-build-index ... sq8; node 0 publishes its sq8.bin in HWcc; part of the layout hash)\n"
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
    else if (a == "--trace-dir") o.trace_dir = v();
    else if (a == "--trace-max-mb") o.trace_max_mb = std::stoull(v());
    else if (a == "--writer-threads") o.writer_threads = std::stoul(v());
    else if (a == "--init-capacity") o.init_capacity = std::stoull(v());
    else if (a == "--vec-format") {
      const std::string x = v();
      if (x != "fp32" && x != "sq8") usage();
      o.p.g.vec_format = x == "sq8" ? kVecSQ8 : kVecF32;
    }
    else if (a == "--op-coh" || a == "--query-coh") {
      const std::string x = v();
      if (x != "on" && x != "off") usage();
      o.op_coh = x == "on";
    }
    else usage();
  }
  o.p.derive();
  if (print_bytes) {
    std::printf("%lu\n", (unsigned long)HwccLayout(o.p).L.bytes());
    return 0;
  }
  if (o.run_id == 0 && !o.preload_only) usage();
  if (o.init_capacity > o.p.g.capacity) {
    std::fprintf(stderr, "vdb-server: --init-capacity %lu exceeds the run capacity %lu\n", (unsigned long)o.init_capacity,
                 (unsigned long)o.p.g.capacity);
    return 2;
  }
  if (o.writer_threads < 1 || o.writer_threads > 16 || (o.writer_threads > 1 && o.backend != "plain")) {
    std::fprintf(stderr, "vdb-server: --writer-threads must be 1..16 (> 1 only with the plain backend)\n");
    return 2;
  }
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
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libmegalon-objapi.so";
  }
  return run<MegalonBackend>(o);
}

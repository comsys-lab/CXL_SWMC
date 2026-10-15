// kv-server: Megalon's artifact KV store (rackobj::Put/Get over 1 KiB slots, NR shared log + per-node index replicas,
// per-slot seqlock records) behind the request-generator interface of vdb-server. One process per node (VM).
// Speaks experiments/loadgen/frame.h with workloads/kv/proto.h.
//
//   --backend plain    libkv-megalon.so built against a hwcc-flavor Megalon build (FULL_COHERENCE: no flushes, static
//                      records = seqlocks; NR log and index replication kept) -> all-HWcc and page MSI
//   --backend megalon  built against a megalon-flavor build (SCR + LIMITED_SCR: flushes, dynamic records) -> Megalon
// Both backends run the same server code; the library build is the only difference (checked: shim flavor).
//
// Placement (systems/megalon/src/src/shared_memory/cxl_port.h): Megalon maps the whole device at map_va; control
// block, slot bitmaps, NR log header and the seqlock records are in HWcc (hwcc_alloc); CacheNode array, slot data
// (the values) and NR log entries in SWcc. kv-server's own HWcc `app` state is a header plus per-node phase words.
//
// Phases: node 0 (or every node, --loader all) puts every key 0..keys-1 once with a version-0 value (initial load,
// unmeasured); every node then gets every key once and checks it (warm-up: first touch of every shared page and of
// the node's index replica, identical on every system); [--trace-dir: key -> slot map by scanning SWcc]; READY.
// Serving: one reader thread per connection queues requests; `--threads` registered workers execute them.
#include <dlfcn.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
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

#include "frame.h"
#include "hwcc_app.h"
#include "kv_api.h"
#include "proc_stats.h"
#include "proto.h"

using namespace kv;
using cxl::hwcc::load_acquire;
using cxl::hwcc::store_release;

namespace {

uint64_t clk(clockid_t c) {
  timespec ts;
  clock_gettime(c, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
uint64_t now_ns() { return clk(CLOCK_MONOTONIC); }

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "kv-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct Opts {
  uint32_t node = 0, nodes = 2, port = 7100, threads = 14;
  uint64_t run_id = 0, keys = 0;
  uint64_t start_timeout_ms = 3600000;
  std::string loader = "node0";  // node0 | all
  std::string region;            // default $CXL_REGION_CONFIG
  std::string backend = "plain";
  std::string megalon_lib;       // default <exe dir>/../lib/libkv-megalon.so
  std::string trace_dir;         // put/get logs written at stop (empty: off)
  uint64_t trace_get_sample = 1;  // log 1 of N gets per worker
  uint64_t trace_cap = 50000000;  // records per worker and kind
};

// app layout (identical on every node and system; mismatching parameters refuse at app_init)
struct AppLayout {
  cxl::hwcc::layout L;
  uint64_t off_loaded = 0, off_warmed = 0;
  AppLayout(const Opts &o) {
    const std::string id = "kv-server v1 keys=" + std::to_string(o.keys) + " value=" + std::to_string(kValueBytes) +
                           " nodes=" + std::to_string(o.nodes) + " loader=" + o.loader;
    L.add(id.c_str(), 64);
    off_loaded = L.add("loaded", 64ull * o.nodes);  // [k] = run_id once node k finished its load share (own line)
    off_warmed = L.add("warmed", 64ull * o.nodes);  // [k] = run_id once node k finished its warm-up check
  }
};

const kvshim::Api *shim_load(const std::string &path, std::string *err) {
  void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) return *err = std::string("dlopen ") + path + ": " + dlerror(), nullptr;
  auto fn = reinterpret_cast<kv_megalon_api_fn>(dlsym(h, "kv_megalon_api"));
  if (!fn) return *err = path + ": no kv_megalon_api", nullptr;
  const kvshim::Api *api = fn();
  if (!api || api->version != kvshim::kApiVersion) return *err = path + ": API version mismatch", nullptr;
  return api;
}

// [va, va + len) must be mapped from `path` (Megalon's mapping of the device at map_va)
bool mapped_by(uint64_t va, uint64_t len, const std::string &path, std::string *err) {
  std::ifstream f("/proc/self/maps");
  std::string line;
  uint64_t cur = va;
  while (cur < va + len && std::getline(f, line)) {
    std::istringstream is(line);
    std::string range, perms, off, dev, ino, file;
    is >> range >> perms >> off >> dev >> ino >> file;
    const size_t dash = range.find('-');
    const uint64_t lo = std::stoull(range.substr(0, dash), nullptr, 16), hi = std::stoull(range.substr(dash + 1), nullptr, 16);
    if (lo <= cur && cur < hi) {
      if (file != path) break;
      cur = hi;
    }
  }
  if (cur >= va + len) return true;
  std::ostringstream o;
  o << "region [0x" << std::hex << va << ", 0x" << va + len << ") is not mapped from " << path << " (stops at 0x" << cur
    << "); Megalon must map the same region config";
  *err = o.str();
  return false;
}

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

struct alignas(64) WorkerStats {
  std::atomic<uint64_t> get_reqs{0}, get_keys{0}, misses{0}, short_reads{0}, put_reqs{0}, put_keys{0}, get_svc_ns{0},
      put_svc_ns{0}, busy_ns{0}, bad_requests{0}, mixed_reqs{0}, mixed_svc_ns{0};
  std::atomic<uint64_t> t_get_n{0}, t_get_ns{0}, t_get_max{0}, t_put_n{0}, t_put_ns{0}, t_put_max{0};
  uint64_t get_tick = 0;  // worker-local
};
constexpr uint64_t kGetSample = 64;

struct TraceBuf {
  std::mutex mu;
  std::vector<TraceRec> puts, gets;
  uint64_t dropped_puts = 0, dropped_gets = 0, get_tick = 0;
};

class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)), lay_(o_) {}

  void start() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (o_.nodes == 0 || o_.node >= o_.nodes || o_.keys < 2) die("bad --node/--nodes/--keys");
    if (o_.threads == 0 || o_.threads + 1 > 32) die("--threads: 1..31 (Megalon: 32 NR registrations per node incl. its wmeta manager)");
    // Megalon maps the whole device at map_va while its library initialises (joins the run, start barrier); threads it
    // starts inherit this name (stats thr.megalon-lib.*: the library's own CPU)
    cxl::proc::name_thread("megalon-lib");
    api_ = shim_load(o_.megalon_lib, &err);
    cxl::proc::name_thread("kv-server");
    if (!api_) die(err);
    const std::string want = o_.backend == "plain" ? "hwcc" : "megalon";
    if (want != api_->flavor)
      die("--backend " + o_.backend + " needs a " + want + "-flavor Megalon build; " + o_.megalon_lib + " is " + api_->flavor);
    if (api_->node_id() != o_.node) die("megalon node id " + std::to_string(api_->node_id()) + " != --node");
    if (api_->key_space() != o_.keys)
      die("megalon config key_space " + std::to_string(api_->key_space()) + " != --keys " + std::to_string(o_.keys));
    if (!mapped_by(r_.map_va, r_.device_size, r_.device, &err)) die(err);
    map_ = reinterpret_cast<uint8_t *>(r_.map_va);
    if (!cxl::hwcc::app_init(r_, map_, lay_.L, o_.run_id, o_.nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    app_ = cxl::hwcc::app_base(r_, map_);
    std::fprintf(stderr,
                 "kv-server: node %u/%u run %#lx backend %s (%s) keys %lu value %u B threads %u loader %s trace %s\n"
                 "kv-server: region %s\nkv-server: app layout %lu B (used %lu, hash %016lx)\n",
                 o_.node, o_.nodes, (unsigned long)o_.run_id, o_.backend.c_str(), api_->info, (unsigned long)o_.keys,
                 kValueBytes, o_.threads, o_.loader.c_str(), o_.trace_dir.empty() ? "off" : o_.trace_dir.c_str(),
                 cxl::region_describe(r_).c_str(), (unsigned long)lay_.L.bytes(), (unsigned long)lay_.L.used(),
                 (unsigned long)lay_.L.hash());
    ws_.reset(new WorkerStats[o_.threads]);
    if (!o_.trace_dir.empty()) tb_.reset(new TraceBuf[o_.threads]);
    for (uint32_t i = 0; i < o_.threads; i++) std::thread([this, i] { worker(i); }).detach();

    // ---- initial load (unmeasured) ----
    const bool loads = o_.loader == "all" || o_.node == 0;
    uint64_t t0 = now_ns();
    phase_.store(1);
    poll_count(&done_load_, o_.threads);
    if (loads)
      std::fprintf(stderr, "kv-server: loaded %lu keys in %.1f s\n", (unsigned long)load_count_.load(), (now_ns() - t0) / 1e9);
    store_release(loaded(o_.node), o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t k = 0; k < o_.nodes; k++)
                if ((o_.loader == "all" || k == 0) && load_acquire(loaded(k)) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("initial load not finished in time");
    // ---- warm-up: every node gets and checks every key once ----
    t0 = now_ns();
    phase_.store(2);
    poll_count(&done_warm_, o_.threads);
    if (warm_bad_.load() || warm_miss_.load())
      die("warm-up check: " + std::to_string(warm_miss_.load()) + " missing keys, " + std::to_string(warm_bad_.load()) +
          " bad values (the initial load did not store every key; Megalon slots/records too small?)");
    std::fprintf(stderr, "kv-server: warm-up read and checked %lu keys in %.1f s\n", (unsigned long)o_.keys, (now_ns() - t0) / 1e9);
    {
      kvshim::Counters c{};
      api_->counters(&c);
      std::fprintf(stderr, "kv-server: megalon counters after warm-up: wmeta_allocated=%lu wmeta_reclaim=%lu wmeta_allocate=%lu "
                   "bitmap_count=%lu (keys %lu)\n", (unsigned long)c.wmeta_allocated, (unsigned long)c.wmeta_reclaim,
                   (unsigned long)c.wmeta_allocate, (unsigned long)c.bitmap_count, (unsigned long)o_.keys);
    }
    if (!o_.trace_dir.empty()) scan_slots();
    store_release(warmed(o_.node), o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t k = 0; k < o_.nodes; k++)
                if (load_acquire(warmed(k)) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("not every node finished its warm-up in time");
    t_serve_ = now_ns();
    phase_.store(3);
    std::thread([this] { listen_loop(); }).detach();
  }

  std::string stats_text() {
    uint64_t s[18] = {};
    for (uint32_t i = 0; i < o_.threads; i++) {
      const WorkerStats &w = ws_[i];
      s[0] += w.get_reqs, s[1] += w.get_keys, s[2] += w.misses, s[3] += w.short_reads, s[4] += w.put_reqs,
          s[5] += w.put_keys, s[6] += w.get_svc_ns, s[7] += w.put_svc_ns, s[8] += w.busy_ns, s[9] += w.bad_requests;
      s[10] += w.mixed_reqs, s[11] += w.mixed_svc_ns, s[12] += w.t_get_n, s[13] += w.t_get_ns, s[15] += w.t_put_n,
          s[16] += w.t_put_ns;
      s[14] = std::max<uint64_t>(s[14], w.t_get_max), s[17] = std::max<uint64_t>(s[17], w.t_put_max);
    }
    std::ostringstream o;
    o << "node=" << o_.node << "\nbackend=" << o_.backend << "\nmegalon.info=" << api_->info << "\nkeys=" << o_.keys
      << "\nthreads=" << o_.threads << "\nget_reqs=" << s[0] << "\ngets=" << s[1] << "\nmisses=" << s[2]
      << "\nshort_reads=" << s[3] << "\nput_reqs=" << s[4] << "\nputs=" << s[5] << "\nget_svc_ns=" << s[6]
      << "\nput_svc_ns=" << s[7] << "\nworker_busy_ns=" << s[8] << "\nbad_requests=" << s[9]
      << "\nmixed_reqs=" << s[10] << "\nmixed_svc_ns=" << s[11]
      << "\nkvt.sample=" << kGetSample << "\nkvt.get_timed=" << s[12] << "\nkvt.get_ns=" << s[13]
      << "\nkvt.get_max_ns=" << s[14] << "\nkvt.put_timed=" << s[15] << "\nkvt.put_ns=" << s[16]
      << "\nkvt.put_max_ns=" << s[17] << "\nqueue=" << q_.size() << "\nconns=" << conns_.load();
    if (tb_) {
      uint64_t np = 0, ng = 0, dp = 0, dg = 0;
      for (uint32_t i = 0; i < o_.threads; i++) {
        std::lock_guard<std::mutex> g(tb_[i].mu);
        np += tb_[i].puts.size(), ng += tb_[i].gets.size(), dp += tb_[i].dropped_puts, dg += tb_[i].dropped_gets;
      }
      o << "\ntrace.puts=" << np << "\ntrace.gets=" << ng << "\ntrace.dropped_puts=" << dp << "\ntrace.dropped_gets=" << dg;
    }
    kvshim::Counters c{};
    api_->counters(&c);  // Megalon's shared counter block (same values on every node)
    o << "\nmegalon.wmeta_allocated=" << c.wmeta_allocated << "\nmegalon.wmeta_reclaim=" << c.wmeta_reclaim
      << "\nmegalon.wmeta_allocate=" << c.wmeta_allocate << "\nmegalon.bitmap_count=" << c.bitmap_count;
    o << "\n" << cxl::proc::text(pst_);
    return o.str();
  }

  // End of run: put/get logs into --trace-dir (node<K>.kv-{puts,gets}.bin + node<K>.kv-trace.txt)
  void dump_traces() {
    if (!tb_) return;
    tracing_.store(false);
    const std::string b = o_.trace_dir + "/node" + std::to_string(o_.node);
    uint64_t n[2] = {0, 0}, d[2] = {0, 0};
    for (int kind = 0; kind < 2; kind++) {
      FILE *f = std::fopen((b + (kind ? ".kv-gets.bin" : ".kv-puts.bin")).c_str(), "wb");
      if (!f) {
        std::fprintf(stderr, "kv-server: cannot write traces into %s\n", o_.trace_dir.c_str());
        return;
      }
      for (uint32_t i = 0; i < o_.threads; i++) {
        std::lock_guard<std::mutex> g(tb_[i].mu);
        auto &v = kind ? tb_[i].gets : tb_[i].puts;
        std::fwrite(v.data(), sizeof(TraceRec), v.size(), f);
        n[kind] += v.size();
        d[kind] += kind ? tb_[i].dropped_gets : tb_[i].dropped_puts;
      }
      std::fclose(f);
    }
    std::ofstream t(b + ".kv-trace.txt");
    t << "# kv-server trace (workloads/kv/proto.h TraceRec, 48 B little-endian: t_real_ns t_mono_ns key stamp slot page "
         "tid dur_ns; records grouped per worker, each group in time order)\n"
      << "node=" << o_.node << "\nnodes=" << o_.nodes << "\nbackend=" << o_.backend << "\nkeys=" << o_.keys
      << "\nvalue_bytes=" << kValueBytes << "\nrecord_bytes=" << sizeof(TraceRec) << "\nputs=" << n[0] << "\ngets=" << n[1]
      << "\ndropped_puts=" << d[0] << "\ndropped_gets=" << d[1] << "\nget_sample=" << o_.trace_get_sample
      << "\nmap_va=" << r_.map_va << "\nswcc_offset=" << r_.swcc.offset << "\nslot_unit_bytes=1024\npage_bytes=4096"
      << "\nslot_scan_found=" << scan_found_ << "\nslot_min=" << scan_min_ << "\nslot_max=" << scan_max_
      << "\nreal_minus_mono_ns=" << int64_t(clk(CLOCK_REALTIME) - clk(CLOCK_MONOTONIC)) << "\n";
    std::fprintf(stderr, "kv-server: trace %s.kv-{puts,gets}.bin: %lu puts, %lu gets (dropped %lu/%lu)\n", b.c_str(),
                 (unsigned long)n[0], (unsigned long)n[1], (unsigned long)d[0], (unsigned long)d[1]);
  }

 private:
  uint64_t *loaded(uint32_t k) { return reinterpret_cast<uint64_t *>(app_ + lay_.off_loaded + 64ull * k); }
  uint64_t *warmed(uint32_t k) { return reinterpret_cast<uint64_t *>(app_ + lay_.off_warmed + 64ull * k); }

  static void poll_count(std::atomic<uint32_t> *c, uint32_t n) {
    while (c->load() < n) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }

  // ---------------------------------------------------------------- workers
  void worker(uint32_t i) {
    cxl::proc::name_thread("kv-worker");
    api_->reg(int(i));
    tid_self_ = uint32_t(syscall(SYS_gettid));
    std::unique_ptr<uint8_t[]> buf(new uint8_t[kValueBytes]);
    while (phase_.load() < 1) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    // initial load: key k is put by worker k % threads of its loader node
    if (o_.loader == "all" || o_.node == 0) {
      const uint64_t step = uint64_t(o_.threads) * (o_.loader == "all" ? o_.nodes : 1);
      const uint64_t first = (o_.loader == "all" ? uint64_t(o_.node) * o_.threads : 0) + i;
      uint64_t n = 0;
      for (uint64_t k = first; k < o_.keys; k += step, n++) {
        fill_value(buf.get(), k, preload_stamp(o_.run_id));
        api_->put(buf.get(), kValueBytes, k);
      }
      load_count_ += n;
    }
    done_load_++;
    while (phase_.load() < 2) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    {
      uint64_t bad = 0, miss = 0, st;
      for (uint64_t k = i; k < o_.keys; k += o_.threads) {
        const ssize_t rc = api_->get(buf.get(), kValueBytes, k);
        if (rc != ssize_t(kValueBytes)) miss++;
        else if (!check_value(buf.get(), k, &st) || st != preload_stamp(o_.run_id)) bad++;
      }
      warm_bad_ += bad;
      warm_miss_ += miss;
    }
    done_warm_++;
    while (phase_.load() < 3) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    WorkerStats &ws = ws_[i];
    TraceBuf *tb = tb_ ? &tb_[i] : nullptr;
    std::vector<uint8_t> out;
    for (;;) {
      Job j = q_.pop();
      const uint64_t b0 = now_ns();
      const uint32_t len = frame::payload_len(j.h);
      const uint8_t *p = j.p.data();
      if (j.h.code == kOpGet && len >= sizeof(GetReq)) {
        GetReq rq;
        std::memcpy(&rq, p, sizeof(rq));
        if (rq.n == 0 || rq.n > kMaxBatch || len != sizeof(GetReq) + 8ull * rq.n || !keys_ok(p + sizeof(GetReq), rq.n, 8)) {
          bad(j, ws);
          continue;
        }
        out.resize(sizeof(GetResp) + size_t(rq.n) * kValueBytes);
        GetResp rs{rq.n, 0, 0};
        for (uint32_t x = 0; x < rq.n; x++)
          rs.misses += do_get(rd64(p + sizeof(GetReq) + 8ull * x), out.data() + sizeof(GetResp) + size_t(x) * kValueBytes, ws, tb);
        const uint64_t e = now_ns();
        rs.svc_ns = uint32_t(std::min<uint64_t>(e - b0, 0xffffffffu));
        std::memcpy(out.data(), &rs, sizeof(rs));
        j.c->reply(frame::kStatusOk, j.h.req_id, out.data(), uint32_t(out.size()));
        ws.get_reqs.fetch_add(1, std::memory_order_relaxed);
        ws.get_keys.fetch_add(rq.n, std::memory_order_relaxed);
        ws.misses.fetch_add(rs.misses, std::memory_order_relaxed);
        ws.get_svc_ns.fetch_add(e - b0, std::memory_order_relaxed);
      } else if (j.h.code == kOpPut && len >= sizeof(PutReq)) {
        PutReq rq;
        std::memcpy(&rq, p, sizeof(rq));
        const uint64_t rec = 8 + kValueBytes;
        if (rq.n == 0 || rq.n > kMaxBatch || len != sizeof(PutReq) + rec * rq.n || !keys_ok(p + sizeof(PutReq), rq.n, rec)) {
          bad(j, ws);
          continue;
        }
        for (uint32_t x = 0; x < rq.n; x++) {
          const uint8_t *r = p + sizeof(PutReq) + rec * x;
          do_put(rd64(r), r + 8, ws, tb);
        }
        const uint64_t e = now_ns();
        PutResp rs{rq.n, 0, uint32_t(std::min<uint64_t>(e - b0, 0xffffffffu))};
        j.c->reply(frame::kStatusOk, j.h.req_id, &rs, sizeof(rs));
        ws.put_reqs.fetch_add(1, std::memory_order_relaxed);
        ws.put_keys.fetch_add(rq.n, std::memory_order_relaxed);
        ws.put_svc_ns.fetch_add(e - b0, std::memory_order_relaxed);
      } else if (j.h.code == kOpMixed && len >= sizeof(MixedReq)) {
        MixedReq rq;
        std::memcpy(&rq, p, sizeof(rq));
        uint32_t np = 0;
        bool ok = rq.n > 0 && rq.n <= kMaxBatch && len >= sizeof(MixedReq) + 8ull * rq.n;
        for (uint32_t x = 0; ok && x < rq.n; x++) {
          const uint64_t d = rd64(p + sizeof(MixedReq) + 8ull * x);
          np += (d & kPutBit) ? 1 : 0;
          ok = (d & ~kPutBit) < o_.keys;
        }
        if (!ok || len != sizeof(MixedReq) + 8ull * rq.n + uint64_t(np) * kValueBytes) {
          bad(j, ws);
          continue;
        }
        const uint32_t ng = rq.n - np;
        out.resize(sizeof(MixedResp) + size_t(ng) * kValueBytes);
        MixedResp rs{rq.n, 0, 0, uint16_t(ng), uint16_t(np), 0};
        const uint8_t *val = p + sizeof(MixedReq) + 8ull * rq.n;
        uint8_t *dst = out.data() + sizeof(MixedResp);
        for (uint32_t x = 0; x < rq.n; x++) {
          const uint64_t d = rd64(p + sizeof(MixedReq) + 8ull * x);
          if (d & kPutBit) {
            do_put(d & ~kPutBit, val, ws, tb);
            val += kValueBytes;
          } else {
            rs.misses += do_get(d, dst, ws, tb);
            dst += kValueBytes;
          }
        }
        const uint64_t e = now_ns();
        rs.svc_ns = uint32_t(std::min<uint64_t>(e - b0, 0xffffffffu));
        std::memcpy(out.data(), &rs, sizeof(rs));
        j.c->reply(frame::kStatusOk, j.h.req_id, out.data(), uint32_t(out.size()));
        ws.mixed_reqs.fetch_add(1, std::memory_order_relaxed);
        ws.get_keys.fetch_add(ng, std::memory_order_relaxed);
        ws.put_keys.fetch_add(np, std::memory_order_relaxed);
        ws.misses.fetch_add(rs.misses, std::memory_order_relaxed);
        ws.mixed_svc_ns.fetch_add(e - b0, std::memory_order_relaxed);
      } else {
        bad(j, ws);
        continue;
      }
      ws.busy_ns.fetch_add(now_ns() - b0, std::memory_order_relaxed);
    }
  }

  static uint64_t rd64(const uint8_t *p) {
    uint64_t v;
    std::memcpy(&v, p, 8);
    return v;
  }

  // One library Get / Put with the wrapper timers (kvt.*: every put timed, gets sampled 1 of kGetSample; the same
  // timers on every backend, so Megalon's KV cost is the difference to the plain backend at equal load).
  // Returns 1 on a miss (value zeroed).
  uint32_t do_get(uint64_t key, uint8_t *v, WorkerStats &ws, TraceBuf *tb) {
    const bool timed = (++ws.get_tick % kGetSample) == 0;
    const uint64_t t0 = (timed || tb) ? now_ns() : 0;
    const ssize_t rc = api_->get(v, kValueBytes, key);
    if (timed) {
      const uint64_t d = now_ns() - t0;
      ws.t_get_n.fetch_add(1, std::memory_order_relaxed);
      ws.t_get_ns.fetch_add(d, std::memory_order_relaxed);
      if (d > ws.t_get_max.load(std::memory_order_relaxed)) ws.t_get_max.store(d, std::memory_order_relaxed);
    }
    if (rc != ssize_t(kValueBytes)) {
      if (rc != 0) ws.short_reads.fetch_add(1, std::memory_order_relaxed);
      std::memset(v, 0, kValueBytes);
      return rc == 0 ? 1 : 0;
    }
    if (tb && ++tb->get_tick % o_.trace_get_sample == 0) log(tb, false, key, rd64(v + 8), t0);
    return 0;
  }

  void do_put(uint64_t key, const uint8_t *val, WorkerStats &ws, TraceBuf *tb) {
    const uint64_t t0 = now_ns();
    api_->put(val, kValueBytes, key);  // artifact Put returns 0; the value is checked by later gets
    const uint64_t d = now_ns() - t0;
    ws.t_put_n.fetch_add(1, std::memory_order_relaxed);
    ws.t_put_ns.fetch_add(d, std::memory_order_relaxed);
    if (d > ws.t_put_max.load(std::memory_order_relaxed)) ws.t_put_max.store(d, std::memory_order_relaxed);
    if (tb) log(tb, true, key, rd64(val + 8), t0);
  }

  bool keys_ok(const uint8_t *p, uint32_t n, uint64_t stride) const {
    for (uint32_t x = 0; x < n; x++) {
      uint64_t key;
      std::memcpy(&key, p + stride * x, 8);
      if (key >= o_.keys) return false;
    }
    return true;
  }

  void bad(Job &j, WorkerStats &ws) {
    ws.bad_requests.fetch_add(1, std::memory_order_relaxed);
    j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0);
  }

  void log(TraceBuf *tb, bool put, uint64_t key, uint64_t st, uint64_t t0) {
    if (!tracing_.load(std::memory_order_relaxed)) return;
    const uint64_t mono = now_ns(), real = clk(CLOCK_REALTIME);
    const uint32_t s = slot_[key];
    TraceRec r{real, mono, key, st, s, s / 4, tid_self_, uint32_t(std::min<uint64_t>(mono - t0, 0xffffffffu))};
    std::lock_guard<std::mutex> g(tb->mu);
    auto &v = put ? tb->puts : tb->gets;
    if (v.size() >= o_.trace_cap) {
      (put ? tb->dropped_puts : tb->dropped_gets)++;
      return;
    }
    v.push_back(r);
  }

  // Trace mode: key -> slot (device offset / 1024) by scanning SWcc for this run's initial-load values (stamp tagged
  // with the run id, so slots left by earlier runs in the reused region are ignored)
  // (layout-independent: the library decides where a slot lives). Read-only, before READY.
  void scan_slots() {
    const uint64_t t0 = now_ns();
    slot_.reset(new uint32_t[o_.keys]);
    std::fill_n(slot_.get(), o_.keys, UINT32_MAX);
    const uint64_t lo = (r_.swcc.offset + 1023) & ~1023ull, hi = r_.swcc.end() & ~1023ull, chunk = 64ull << 20;
    if (hi / 1024 > UINT32_MAX) die("device too large for 32-bit slot numbers");
    std::atomic<uint64_t> next{lo}, found{0}, dups{0};
    std::vector<std::thread> th;
    for (uint32_t t = 0; t < o_.threads; t++)
      th.emplace_back([&] {
        for (;;) {
          if (found.load() >= o_.keys) return;
          const uint64_t a = next.fetch_add(chunk);
          if (a >= hi) return;
          for (uint64_t off = a; off < std::min(a + chunk, hi); off += 1024) {
            const uint8_t *v = map_ + off;
            uint64_t key, st;
            std::memcpy(&key, v, 8);
            if (key >= o_.keys || !check_value(v, key, &st) || st != preload_stamp(o_.run_id)) continue;
            uint32_t exp = UINT32_MAX;
            if (__atomic_compare_exchange_n(&slot_[key], &exp, uint32_t(off / 1024), false, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
              found++;
            else
              dups++;
          }
        }
      });
    for (auto &t : th) t.join();
    scan_found_ = found.load();
    if (scan_found_ != o_.keys || dups.load())
      die("slot scan: found " + std::to_string(scan_found_) + " of " + std::to_string(o_.keys) + " keys, " +
          std::to_string(dups.load()) + " duplicates");
    scan_min_ = *std::min_element(slot_.get(), slot_.get() + o_.keys);
    scan_max_ = *std::max_element(slot_.get(), slot_.get() + o_.keys);
    tracing_.store(true);
    std::fprintf(stderr, "kv-server: slot scan found %lu keys in slots [%lu, %lu] (device offset / 1024) in %.1f s\n",
                 (unsigned long)scan_found_, (unsigned long)scan_min_, (unsigned long)scan_max_, (now_ns() - t0) / 1e9);
  }

  // ---------------------------------------------------------------- network
  void listen_loop() {
    cxl::proc::name_thread("kv-listen");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "kv-server: READY node %u port %u\n", o_.node, o_.port);
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
    cxl::proc::name_thread("kv-conn");
    conns_++;
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      switch (h.code) {
        case kOpGet:
        case kOpPut:
        case kOpMixed: q_.push(std::move(j)); break;
        case kOpStats: {
          std::string t = stats_text();
          c->reply(frame::kStatusOk, h.req_id, t.data(), uint32_t(t.size()));
          break;
        }
        default: c->reply(frame::kStatusUnknownOp, h.req_id, nullptr, 0);
      }
    }
    conns_--;
    close(c->fd);
  }

  Opts o_;
  AppLayout lay_;
  cxl::region r_;
  uint8_t *map_ = nullptr, *app_ = nullptr;
  const kvshim::Api *api_ = nullptr;
  std::atomic<int> phase_{0};
  std::atomic<uint32_t> done_load_{0}, done_warm_{0}, conns_{0};
  std::atomic<uint64_t> load_count_{0}, warm_bad_{0}, warm_miss_{0};
  std::unique_ptr<WorkerStats[]> ws_;
  std::unique_ptr<TraceBuf[]> tb_;
  std::unique_ptr<uint32_t[]> slot_;
  std::atomic<bool> tracing_{false};
  uint64_t scan_found_ = 0, scan_min_ = 0, scan_max_ = 0, t_serve_ = 0;
  static thread_local uint32_t tid_self_;
  Queue q_;
  cxl::proc::Opts pst_{{"cxl_recv"},
                       {"TLB", "CAL", "RES", "LOC"},
                       {"/sys/kernel/swmc/page_coherence", "/sys/kernel/swmc/instr", "/sys/kernel/cxl_shm",
                        "/sys/kernel/cxl_shm/instr"}};
};
thread_local uint32_t Server::tid_self_ = 0;

volatile sig_atomic_t g_stop = 0;

void usage() {
  std::fprintf(stderr,
               "usage: kv-server --node K --nodes N --run-id 0x.. --keys N [--port P (7100)] [--region yaml]\n"
               "  [--threads W (14)] [--loader node0|all] [--backend plain|megalon] [--megalon-lib PATH]\n"
               "  [--trace-dir DIR [--trace-get-sample S] [--trace-cap R]] [--start-timeout-ms T]\n"
               "  kv-server --print-app-bytes --nodes N --keys N [--loader ..]   CXL_APP_HWCC_BYTES for these parameters\n"
               "  kv-server --print-sizes --keys N                               Megalon config values (slots, logical_scr_size)\n"
               "Both backends load lib/libkv-megalon.so (plain: hwcc-flavor Megalon, megalon: megalon flavor) with\n"
               "RACKOBJ_CONFIG (key_space = --keys); MEGALON_NODE_ID / MEGALON_RUN_ID / CXL_REGION_CONFIG default to\n"
               "--node / --run-id / --region; node 0 needs MEGALON_REINIT=1.\n"
               "--preload-only / --preloaded are not supported (page MSI init_state=shared): the store's index replicas are\n"
               "process-local, so the load must run in the serving processes (reports/KV-port.md).\n");
  std::exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  Opts o;
  bool print_app = false, print_sizes = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) usage();
      return argv[++i];
    };
    if (a == "--node") o.node = std::stoul(v());
    else if (a == "--nodes") o.nodes = std::stoul(v());
    else if (a == "--run-id") o.run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--keys") o.keys = std::stoull(v());
    else if (a == "--port") o.port = std::stoul(v());
    else if (a == "--region") o.region = v();
    else if (a == "--threads") o.threads = std::stoul(v());
    else if (a == "--loader") o.loader = v();
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.megalon_lib = v();
    else if (a == "--trace-dir") o.trace_dir = v();
    else if (a == "--trace-get-sample") o.trace_get_sample = std::max<uint64_t>(1, std::stoull(v()));
    else if (a == "--trace-cap") o.trace_cap = std::stoull(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--print-app-bytes") print_app = true;
    else if (a == "--print-sizes") print_sizes = true;
    else if (a == "--preload-only" || a == "--preloaded") {
      std::fprintf(stderr, "kv-server: %s is not supported (see usage)\n", a.c_str());
      return 2;
    } else usage();
  }
  if (o.loader != "node0" && o.loader != "all") usage();
  if (print_app) {
    std::printf("%lu\n", (unsigned long)AppLayout(o).L.bytes());
    return 0;
  }
  if (print_sizes) {
    // Megalon config for N keys (kv-2vm.yaml): slots = N + N/1000 + 64 rounded up to 64 (Megalon rounds to 64);
    // records = min(logical_scr_size / 4, slots * 100 / 90) = slots * 100 / 90 (packed4: 4 B); Megalon's record
    // watermark threshold = records * 90 / 100 (c3.cc), so threshold >= N + N/1000 + 63 > N: every loaded key keeps
    // its record in the megalon flavor without reclaim (the hwcc flavor uses slot i's static record).
    const uint64_t slots = (o.keys + o.keys / 1000 + 64 + 63) / 64 * 64, records = slots * 100 / 90,
                   lscr = (records + 1) * 4, threshold = records * 90 / 100;
    const uint64_t bitmaps = 4 * (((slots + 63) / 64 * 8 + 63) / 64 * 64);  // four slot bitmaps, 64 B aligned
    std::printf("key_space=%lu\nslots=%lu\nlogical_scr_size=%lu\nrecords=%lu\nrecord_threshold=%lu\n"
                "record_margin=%lu\nrecord_bytes=%lu\nbitmap_bytes=%lu\nslot_data_bytes=%lu\n",
                (unsigned long)o.keys, (unsigned long)slots, (unsigned long)lscr, (unsigned long)records,
                (unsigned long)threshold, (unsigned long)(threshold - o.keys), (unsigned long)(records * 4),
                (unsigned long)bitmaps, (unsigned long)(slots * kValueBytes));
    return 0;
  }
  if (o.run_id == 0 || o.keys == 0 || (o.backend != "plain" && o.backend != "megalon")) usage();
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  // Megalon reads its node id, run id and region config from the environment when its library initialises.
  auto env = [](const char *k, const std::string &val) {
    const char *cur = getenv(k);
    if (cur && *cur && val != cur) {
      std::fprintf(stderr, "kv-server: %s=%s contradicts the server option (%s)\n", k, cur, val.c_str());
      std::exit(2);
    }
    setenv(k, val.c_str(), 1);
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
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libkv-megalon.so";
  }
  Server s(o);
  s.start();
  while (!g_stop) usleep(200000);
  std::fprintf(stderr, "kv-server: stopping\n%s\n", s.stats_text().c_str());
  s.dump_traces();
  std::fflush(stderr);
  std::_Exit(0);
}

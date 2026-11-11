// socialgraph server (sg-server), one process per VM (DESIGN.md §4; experiment socialgraph-serving §2). Speaks
// experiments/loadgen/frame.h with workloads/socialgraph/proto.h. Structure follows workloads/vectordb/server/server.cc:
// one reader thread per connection; read operations go to one queue served by the query threads, writes to one
// queue served by the VM's writer thread (arrival order); stats replies are answered by the connection thread.
// Threads: query threads = online CPUs - 1 (3 at 4 vCPU) + 1 writer, unless --query-threads is given.
// The graph image lives in the SWcc range of the region (offset swcc.offset + --image-offset); every system maps the
// same bytes. Systems differ only in region config and kernel for the plain backend (All HWcc, Popcorn, De Stijl with
// CXL_SYSTEM=ds and CXL_DESTIJL_T_US applied to the whole image); Megalon (part 5) plugs in as another backend class
// (backend.h) behind Server<Be>. Record protocol, guards and write allocation: graph_ops.h.
// HWcc app range (CXL_APP_HWCC_BYTES = sg-server --print-app-bytes ...): app header, per node ready line, writer
// stripe locks.
// Modes: serve (default); --copy-image FILE (node 0: copy the image into the region through a plain mapping, before
// coherence is enabled, like the vector DB --preload-only; no HWcc access) and --verify [--image FILE] (header,
// layout hash, record checks and a byte comparison of sampled records with FILE; read only; no HWcc access).
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
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
#include <type_traits>
#include <vector>

#include "../proto.h"
#include "backend.h"
#include "frame.h"
#include "graph_ops.h"
#include "hwcc_app.h"
#include "layout.h"
#include "mmap_backend.h"
#include "opwin.h"
#include "proc_stats.h"
#include "stale_log.h"

using namespace sg;
using cxl::hwcc::load_acquire;
using cxl::hwcc::store_release;

namespace {

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "sg-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct Opts {
  uint32_t node = 0, nodes = 0, port = 7100, query_threads = 0;
  uint64_t run_id = 0, image_off = 0, retry_ms = 2000, start_timeout_ms = 600000, stale_every = 1000, flush_ms = 1000;
  uint32_t lock_stripes = 16384;
  std::string region, stale_dir, copy_image, verify_image;
  bool verify = false, op_coh = true, warmup = true;
};

// HWcc app layout (same calls on every node; hash checked by app_init)
struct AppLayout {
  cxl::hwcc::layout L;
  uint64_t off_ready = 0, off_locks = 0;
  AppLayout(uint32_t nodes, uint32_t stripes) {
    off_ready = L.add("sg.ready", 64ull * nodes);
    off_locks = L.add("sg.locks", 64ull * stripes);
  }
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
  uint64_t t_acc = 0;  // CLOCK_MONOTONIC when the connection thread queued it
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

// Operation types of the stats text (index into OpStats arrays and OpWin)
enum OpIx { kIxFeed, kIxGetNode, kIxCountLink, kIxGetLink, kIxAddLink, kIxUpdateLink, kIxDeleteLink, kIxAddNode,
            kIxUpdateNode, kIxDeleteNode, kIxN };
const char *const kIxName[kIxN] = {"feed", "getnode", "countlink", "getlink", "addlink", "updatelink", "deletelink",
                                   "addnode", "updatenode", "deletenode"};
int op_ix(uint16_t op) {
  switch (op) {
    case kOpFeed: return kIxFeed;
    case kOpGetNode: return kIxGetNode;
    case kOpCountLink: return kIxCountLink;
    case kOpGetLink: return kIxGetLink;
    case kOpAddLink: return kIxAddLink;
    case kOpUpdateLink: return kIxUpdateLink;
    case kOpDeleteLink: return kIxDeleteLink;
    case kOpAddNode: return kIxAddNode;
    case kOpUpdateNode: return kIxUpdateNode;
    case kOpDeleteNode: return kIxDeleteNode;
    default: return -1;
  }
}
bool is_write(uint16_t op) { return op >= kOpAddLink && op <= kOpDeleteNode; }

struct OpStats {
  std::atomic<uint64_t> ops{0}, ok{0}, notfound{0}, full{0}, busy{0}, bad{0}, server_ns{0}, records{0}, rows{0};
};

struct Stats {
  OpStats op[kIxN];
  std::atomic<uint64_t> retries{0}, guard_rejects{0}, check_fails{0}, giveups{0}, feed_missing{0};
  std::atomic<uint64_t> query_busy_ns{0}, writer_busy_ns{0}, bad_frames{0};
  std::atomic<uint64_t> write_jobs_accepted{0}, write_jobs_done{0}, write_lag_ns_sum{0}, write_lag_n{0}, write_lag_max_ns{0};
  std::atomic<uint64_t> opc_read_errors{0}, opc_register_errors{0};
  void add(const OpCtr &c) {
    retries += c.retries, guard_rejects += c.guard_rejects, check_fails += c.check_fails, giveups += c.giveups;
  }
};

// Response builder: RespHead, body, optional OpCoh block at the end (RespHead.flags kRespCoh)
struct Resp {
  std::vector<uint8_t> b;
  Resp() { b.resize(sizeof(RespHead)); }
  template <class T> void put(const T &x) {
    const size_t o = b.size();
    b.resize(o + sizeof(T));
    std::memcpy(b.data() + o, &x, sizeof(T));
  }
  void put_bytes(const void *p, size_t n) {
    const size_t o = b.size();
    b.resize(o + n);
    if (n) std::memcpy(b.data() + o, p, n);
  }
  RespHead &head() { return *reinterpret_cast<RespHead *>(b.data()); }
};

template <class Be>
class Server {
 public:
  explicit Server(Opts o) : o_(std::move(o)) {}

  // map the whole device at map_va (plain mapping; a regular file in Host tests)
  void map_device() {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    const int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    close(fd);
    map_ = static_cast<uint8_t *>(m);
    if (o_.image_off % kPage) die("--image-offset must be a multiple of 4096");
    if (o_.image_off >= r_.swcc.size) die("--image-offset outside swcc");
    img_ = map_ + r_.swcc.offset + o_.image_off;
    img_avail_ = r_.swcc.size - o_.image_off;
  }

  // --copy-image: node 0, plain mapping, no HWcc access (run before coherence is enabled)
  int copy_image() {
    if (o_.node != 0) die("--copy-image runs on node 0 only");
    map_device();
    const int fd = open(o_.copy_image.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) die("open " + o_.copy_image);
    struct stat st;
    if (fstat(fd, &st) != 0) die("stat " + o_.copy_image);
    const uint64_t n = uint64_t(st.st_size);
    if (n > img_avail_) die("image " + std::to_string(n) + " B larger than the swcc range after the offset (" +
                            std::to_string(img_avail_) + " B)");
    ImageHeader h;
    if (pread(fd, &h, sizeof h, 0) != ssize_t(sizeof h)) die("short read of the image header");
    const std::string e = check_header(h, n);
    if (!e.empty()) die("image file header: " + e);
    const uint64_t t0 = mono_ns(), chunk = 64ull << 20;
    std::vector<uint8_t> buf(chunk);
    uint64_t fnv = 1469598103934665603ull;
    // header page last: an interrupted copy never leaves a valid header over a partial image
    for (uint64_t off = kPage; off < n; off += chunk) {
      const uint64_t len = std::min(chunk, n - off);
      if (pread(fd, buf.data(), len, off_t(off)) != ssize_t(len)) die("short read at " + std::to_string(off));
      std::memcpy(img_ + off, buf.data(), len);
    }
    std::memcpy(img_, &h, sizeof h);
    for (uint64_t i = 0; i < sizeof h; i++) fnv = (fnv ^ reinterpret_cast<const uint8_t *>(&h)[i]) * 1099511628211ull;
    close(fd);
    std::fprintf(stderr, "sg-server: COPY DONE %lu B into swcc+%lu in %.1f s (layout hash %016lx, header fnv %016lx)\n",
                 (unsigned long)n, (unsigned long)o_.image_off, (mono_ns() - t0) / 1e9, (unsigned long)h.layout_hash,
                 (unsigned long)fnv);
    return 0;
  }

  // --verify: read-only checks of the image in the region (no HWcc access, no writes)
  int verify() {
    map_device();
    Be be(img_, img_avail_);
    std::string err;
    if (!be.attach(&err)) {
      std::fprintf(stderr, "sg-server: VERIFY FAIL %s\n", err.c_str());
      return 1;
    }
    const ImageHeader &h = be.header();
    uint64_t bad = 0, checked = 0, cmp = 0;
    auto fail = [&](const std::string &m) {
      if (bad++ < 10) std::fprintf(stderr, "sg-server: VERIFY mismatch: %s\n", m.c_str());
    };
    Locks none;
    GraphOps<Be> g(be, &none, nullptr, 0, 1, o_.retry_ms * 1000000ull);
    Ctx cx;
    std::vector<EdgeSlot> edges;
    // sampled records: 64 node slots + 64 lists spread over the arrays (plus the first and last of each)
    std::vector<uint64_t> ns, ls;
    for (uint64_t i = 0; i < 64; i++) ns.push_back(i * (h.n_nodes() - 1) / 63), ls.push_back(i * (h.n_orig - 1) / 63);
    for (uint64_t s : ns) {
      NodeSlot n;
      const uint16_t st = g.get_node(cx, s, &n);
      checked++;
      if (st == kStatusBusy) fail("node slot " + std::to_string(s) + ": no consistent read");
      else if (s < h.n_orig && n.id != h.id_base + s) fail("node slot " + std::to_string(s) + ": id");
    }
    for (uint64_t s : ls) {
      AdjHeader a;
      checked++;
      const uint16_t st = g.get_list(cx, s, false, kAssocFriend, 0, &edges, &a);
      if (st == kStatusNotFound) continue;
      if (st != kStatusOk) { fail("list " + std::to_string(s) + ": walk failed (guard)"); continue; }
      uint64_t live = 0;
      for (auto &e : edges) live += e.flags & kEdgeLive;
      if (a.used != edges.size() || a.count != live) fail("list " + std::to_string(s) + ": count / used");
      for (size_t i = 1; i < edges.size() && a.version == 0; i++)
        if (edges[i - 1].time < edges[i].time) { fail("list " + std::to_string(s) + ": not newest first"); break; }
    }
    if (!o_.verify_image.empty()) {  // byte comparison with the image file: header page + the sampled records
      const int fd = open(o_.verify_image.c_str(), O_RDONLY | O_CLOEXEC);
      if (fd < 0) die("open " + o_.verify_image);
      std::vector<uint8_t> buf(kPage);
      auto same = [&](uint64_t off, uint64_t len, const std::string &what) {
        buf.resize(len);
        if (pread(fd, buf.data(), len, off_t(off)) != ssize_t(len)) { fail(what + ": short read of the file"); return; }
        cmp++;
        if (std::memcmp(buf.data(), img_ + off, len)) fail(what + ": bytes differ from the image file");
      };
      same(0, kPage, "header page");
      const View &v = be.view();
      for (uint64_t s : ns) same(h.nodes_off + s * sizeof(NodeSlot), sizeof(NodeSlot), "node slot " + std::to_string(s));
      for (uint64_t s : ls)
        if (v.has_adj(s)) same(h.adj_off + v.adj_index()[s], v.primary_block_bytes(s), "list " + std::to_string(s));
      for (uint64_t i = 0; i < 16 && h.ovf_blocks(); i++) {
        const uint64_t b = i * (h.ovf_blocks() - 1) / 15;
        same(h.ovf_off + b * kPage, kPage, "ovf block " + std::to_string(b));
      }
      close(fd);
    }
    std::fprintf(stderr, "sg-server: VERIFY %s layout hash %016lx, %lu records checked, %lu ranges compared with %s, "
                 "%lu mismatches (nodes %lu, lists %lu, links %lu, ovf %lu)\n", bad ? "FAIL" : "PASS",
                 (unsigned long)h.layout_hash, (unsigned long)checked, (unsigned long)cmp,
                 o_.verify_image.empty() ? "(no file)" : o_.verify_image.c_str(), (unsigned long)bad,
                 (unsigned long)h.n_nodes(), (unsigned long)h.n_orig, (unsigned long)h.n_links,
                 (unsigned long)h.ovf_blocks());
    return bad ? 1 : 0;
  }

  void start() {
    std::string err;
    map_device();
    lay_ = std::make_unique<AppLayout>(o_.nodes, o_.lock_stripes);
    if (!cxl::hwcc::app_init(r_, map_, lay_->L, o_.run_id, o_.nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    uint8_t *app = cxl::hwcc::app_base(r_, map_);
    locks_.w = reinterpret_cast<uint64_t *>(app + lay_->off_locks);
    locks_.n = o_.lock_stripes;
    locks_.owner = o_.node + 1;
    be_ = std::make_unique<Be>(img_, img_avail_);
    if (!be_->attach(&err)) die(err);
    const ImageHeader &h = be_->header();
    if constexpr (std::is_same_v<Be, MmapBackend>) {
      // De Stijl v2: staleness bound T ($CXL_DESTIJL_T_US with CXL_SYSTEM=ds) on the whole image; no-op otherwise
      uint64_t t = 0;
      if (cxl::region_apply_staleness(r_, be_->image_base(), be_->image_bytes(), &t) != 0)
        die(std::string("de stijl staleness (CXL_DESTIJL_T_US) on the image: ") + std::strerror(errno));
      if (t) std::fprintf(stderr, "sg-server: de stijl staleness T=%lu us on the image (%lu B)\n", (unsigned long)t,
                          (unsigned long)be_->image_bytes());
    }
    if (!o_.stale_dir.empty() && !sl_.open(o_.stale_dir, o_.node, o_.stale_every, &err)) die(err);
    ops_ = std::make_unique<GraphOps<Be>>(*be_, &locks_, sl_.on() ? &sl_ : nullptr, o_.node, o_.nodes,
                                          o_.retry_ms * 1000000ull);
    std::fprintf(stderr, "sg-server: node %u/%u run %#lx\nsg-server: region %s\nsg-server: app layout %lu B (hash "
                 "%016lx), image at swcc+%lu: %lu B, layout hash %016lx, %lu nodes (%lu original), %lu links, %lu ovf "
                 "blocks (%lu pool); backend %s\n", o_.node, o_.nodes, (unsigned long)o_.run_id,
                 cxl::region_describe(r_).c_str(), (unsigned long)lay_->L.bytes(), (unsigned long)lay_->L.hash(),
                 (unsigned long)o_.image_off, (unsigned long)h.total_bytes, (unsigned long)h.layout_hash,
                 (unsigned long)h.n_nodes(), (unsigned long)h.n_orig, (unsigned long)h.n_links,
                 (unsigned long)h.ovf_blocks(), (unsigned long)h.ovf_pool, be_->usage().c_str());
    be_->thread_init(0);
    if (o_.warmup) warm_up();
    // start barrier: every node has mapped, attached and warmed up
    uint64_t *ready = reinterpret_cast<uint64_t *>(app + lay_->off_ready);
    store_release(&ready[8 * o_.node], o_.run_id);
    if (!cxl::hwcc::poll_until([&] {
          for (uint32_t v = 0; v < o_.nodes; v++)
            if (load_acquire(&ready[8 * v]) != o_.run_id) return false;
          return true;
        }, o_.start_timeout_ms))
      die("not every node became ready in time");
    opc_setup();
    sl_.start_flusher(o_.flush_ms);
    uint32_t q = o_.query_threads;
    if (!q) {
      const long c = sysconf(_SC_NPROCESSORS_ONLN);
      q = c > 1 ? uint32_t(c - 1) : 1;
    }
    nq_ = q;
    std::fprintf(stderr, "sg-server: threads %u query + 1 writer; staleness log %s (1 in %lu reads)\n", q,
                 sl_.on() ? o_.stale_dir.c_str() : "off", (unsigned long)o_.stale_every);
    std::thread([this] { writer(); }).detach();
    for (uint32_t i = 0; i < q; i++) std::thread([this, i] { query(int(2 + i)); }).detach();
    std::thread([this] { listen_loop(); }).detach();
  }

  void stop() { sl_.close(); }

  std::string stats_text() {
    std::ostringstream o;
    o << "node=" << o_.node << "\nnodes=" << o_.nodes << "\nbackend=" << Be::kName << "\nquery_threads=" << nq_;
    for (int i = 0; i < kIxN; i++) {
      const OpStats &s = st_.op[i];
      const std::string p = std::string("\nop.") + kIxName[i] + ".";
      o << p << "ops=" << s.ops << p << "ok=" << s.ok << p << "notfound=" << s.notfound << p << "full=" << s.full << p
        << "busy=" << s.busy << p << "bad=" << s.bad << p << "server_ns=" << s.server_ns << p << "records=" << s.records
        << p << "rows=" << s.rows;
    }
    o << "\nseq.retries=" << st_.retries << "\nseq.guard_rejects=" << st_.guard_rejects
      << "\nseq.check_fails=" << st_.check_fails << "\nseq.giveups=" << st_.giveups
      << "\nfeed.missing_nodes=" << st_.feed_missing << "\nquery_busy_ns=" << st_.query_busy_ns
      << "\nwriter_busy_ns=" << st_.writer_busy_ns << "\nbad_frames=" << st_.bad_frames
      << "\nquery_queue=" << qq_.size() << "\nwrite_queue=" << wq_.size();
    {
      const uint64_t done = st_.write_jobs_done.load(), acc = st_.write_jobs_accepted.load();
      o << "\nwrite_jobs_accepted=" << acc << "\nwrite_jobs_done=" << done << "\nwrite_backlog=" << (acc >= done ? acc - done : 0)
        << "\nwrite_lag_ns_sum=" << st_.write_lag_ns_sum << "\nwrite_lag_n=" << st_.write_lag_n
        << "\nwrite_lag_max_ns=" << st_.write_lag_max_ns.exchange(0);
    }
    if (ops_) o << "\nalloc.pool_blocks_left=" << ops_->pool_left() << "\nalloc.slack_slots_left=" << ops_->slack_left();
    o << "\nstale.on=" << int(sl_.on()) << "\nstale.every=" << sl_.every() << "\nstale.read_samples=" << sl_.sampled()
      << "\nstale.commits=" << sl_.commits() << "\nstale.write_errors=" << sl_.errors();
    o << "\nopcoh.enabled=" << int(oc_.on()) << "\nopcoh.pop_source=" << vdb::pop_src_name(oc_.src())
      << "\nopcoh.tsc_khz=" << tsc_khz_ << "\nopcoh.read_errors=" << st_.opc_read_errors
      << "\nopcoh.register_errors=" << st_.opc_register_errors;
    o << "\nopt.version=1\nopt.c_source=popcorn\nopt.tsc_hz=" << uint64_t(tsc_khz_) * 1000 << "\nopt.meg_coh=0";
    for (int i = 0; i < kIxN; i++) win_[i].print(o, kIxName[i]);
    o << "\nbackend_usage=" << be_->usage() << "\n" << be_->stats();
    o << "\n" << cxl::proc::text(pst_);
    return o.str();
  }

 private:
  // Read every page of the image once (every node, before the start barrier; identical in every system), so that
  // measurements do not include the first touch of shared pages.
  void warm_up() {
    const uint64_t t0 = mono_ns(), n = be_->header().total_bytes;
    uint64_t x = 0;
    const volatile uint8_t *p = img_;
    for (uint64_t off = 0; off < n; off += kPage) x += p[off];
    std::fprintf(stderr, "sg-server: warm-up read %lu MiB (one byte per page) in %.1f s (%lu)\n",
                 (unsigned long)(n >> 20), (mono_ns() - t0) / 1e9, (unsigned long)(x & 1));
  }

  void opc_setup() {
    tsc_khz_ = vdb::calibrate_tsc_khz();
    const char *fake = getenv("SG_OPCOH_FAKE");
    std::string why;
    oc_.setup(o_.op_coh, fake && std::string(fake) == "1", nullptr, tsc_khz_, &why);
    std::fprintf(stderr, "sg-server: op coherence %s, popcorn source %s%s%s, tsc %u kHz\n", oc_.on() ? "on" : "off",
                 vdb::pop_src_name(oc_.src()), why.empty() ? "" : " (", why.empty() ? "" : (why + ")").c_str(), tsc_khz_);
  }
  void opc_thread_start() {
    if (!oc_.thread_start()) st_.opc_register_errors++;
  }

  // finish: OpCoh block (if on), RespHead fields, window counters, reply
  void finish(Job &j, Resp &r, uint16_t op, uint16_t status, uint32_t records, uint64_t t0,
              const vdb::OpCohSrc::Start &os, Ctx &cx, uint32_t rows) {
    vdb::OpAcc a;
    if (!oc_.end(os, &a)) st_.opc_read_errors++;
    const int ix = op_ix(op);
    RespHead &h = r.head();
    h.op = op, h.status = status, h.flags = 0, h.pad = 0, h.records = records;
    if (oc_.on()) {
      OpCoh b = vdb::op_block(a, op, oc_.src(), false, tsc_khz_);
      b.req_id = j.h.req_id;
      r.put(b);
      r.head().flags |= kRespCoh;
      win_[ix].add(b);
      win_[ix].add_raw(a);
    }
    const uint64_t dt = mono_ns() - t0;
    r.head().server_us = uint32_t(dt / 1000);
    OpStats &s = st_.op[ix];
    s.ops++, s.server_ns += dt, s.records += records, s.rows += rows;
    if (status == kStatusOk) s.ok++;
    else if (status == kStatusNotFound) s.notfound++;
    else if (status == kStatusFull) s.full++;
    else if (status == kStatusBusy) s.busy++;
    else s.bad++;
    st_.add(cx.c);
    cx.c = OpCtr{};
    j.c->reply(frame::kStatusOk, j.h.req_id, r.b.data(), uint32_t(r.b.size()));
  }
  void bad(Job &j) {
    st_.bad_frames++;
    j.c->reply(frame::kStatusBadRequest, j.h.req_id, nullptr, 0);
  }

  // ---------------------------------------------------------------- query threads
  void query(int tid) {
    cxl::proc::name_thread("sg-query");
    be_->thread_init(tid);
    opc_thread_start();
    Ctx cx;
    cx.sb = sl_.on() ? sl_.reg(false, (uint64_t(o_.node) << 32) ^ uint64_t(tid) ^ o_.run_id) : nullptr;
    std::vector<EdgeSlot> edges;
    std::vector<uint32_t> want;
    for (;;) {
      Job j = qq_.pop();
      const uint64_t t0 = mono_ns();
      serve_read(j, cx, edges, want, t0);
      st_.query_busy_ns += mono_ns() - t0;
    }
  }

  void serve_read(Job &j, Ctx &cx, std::vector<EdgeSlot> &edges, std::vector<uint32_t> &want, uint64_t t0) {
    const uint32_t n = frame::payload_len(j.h);
    const uint8_t *p = j.p.data();
    const uint64_t nn = ops_->header().n_nodes();
    Resp r;
    vdb::OpCohSrc::Start os;
    switch (j.h.code) {
      case kOpFeed: {
        if (n != sizeof(FeedReq)) return bad(j);
        FeedReq q;
        std::memcpy(&q, p, sizeof q);
        oc_.begin(&os);
        const uint32_t limit = std::min<uint32_t>(q.limit ? q.limit : 50, 1024);
        AdjHeader a;
        const uint64_t slot = ops_->slot_of(q.id1);
        uint16_t st = ops_->get_list(cx, slot, true, q.assoc_type, limit, &edges, &a);
        const uint64_t t1 = mono_ns();
        FeedResp fr{};
        uint32_t recs = st == kStatusOk ? 1 : 0;
        std::vector<FeedRow> rows;
        if (st == kStatusOk) {
          fr.list_version = a.version;
          for (const EdgeSlot &e : edges) {
            FeedRow row{};
            row.id2 = e.id2, row.link_version = e.version, row.link_time = e.time;
            NodeSlot ns;
            const uint16_t s2 = ops_->get_node(cx, ops_->slot_of(e.id2), &ns);
            if (s2 == kStatusBusy) { st = kStatusBusy; break; }
            recs++;
            if (s2 == kStatusOk) row.node_version = ns.version, row.node_data_len = ns.data_len;
            else fr.missing++;
            rows.push_back(row);
          }
        }
        st_.feed_missing += fr.missing;
        fr.n = uint16_t(rows.size());
        fr.list_us = uint32_t((t1 - t0) / 1000);
        if (st == kStatusOk) {
          r.put(fr);
          r.put_bytes(rows.data(), rows.size() * sizeof(FeedRow));
        }
        oc_.fake_add(0, 100 * recs, 0);  // Host-test fake source only: 100 ns I->S fault per record
        return finish(j, r, kOpFeed, st, recs, t0, os, cx, uint32_t(rows.size()));
      }
      case kOpGetNode: {
        if (n != sizeof(NodeKeyReq)) return bad(j);
        NodeKeyReq q;
        std::memcpy(&q, p, sizeof q);
        oc_.begin(&os);
        NodeSlot ns;
        const uint16_t st = ops_->get_node(cx, ops_->slot_of(q.id), &ns);
        if (st == kStatusOk) {
          NodeResp nr{};
          nr.id = ns.id, nr.version = ns.version, nr.commit_ns = ns.commit_ns, nr.type = ns.type, nr.time_s = ns.time_s;
          nr.data_len = ns.data_len;
          r.put(nr);
          r.put_bytes(ns.data, ns.data_len);
        }
        return finish(j, r, kOpGetNode, st, st == kStatusBusy ? 0 : 1, t0, os, cx, 0);
      }
      case kOpCountLink: {
        if (n != sizeof(LinkListReq)) return bad(j);
        LinkListReq q;
        std::memcpy(&q, p, sizeof q);
        oc_.begin(&os);
        AdjHeader a;
        const uint16_t st = ops_->get_list_head(cx, ops_->slot_of(q.id1), &a);
        if (st == kStatusOk) {
          // count over every assoc type (the image and every write use kAssocFriend only)
          CountResp c{a.version, a.count};
          r.put(c);
        }
        return finish(j, r, kOpCountLink, st, st == kStatusOk ? 1 : 0, t0, os, cx, 0);
      }
      case kOpGetLink: {
        if (n < sizeof(GetLinkReq)) return bad(j);
        GetLinkReq q;
        std::memcpy(&q, p, sizeof q);
        if (n != sizeof(GetLinkReq) + uint32_t(q.n2) * 4) return bad(j);
        want.resize(q.n2);
        std::memcpy(want.data(), p + sizeof q, q.n2 * 4ull);
        oc_.begin(&os);
        AdjHeader a;
        const uint16_t st = ops_->get_list(cx, ops_->slot_of(q.id1), true, q.assoc_type, 0, &edges, &a);
        std::vector<LinkRow> rows;
        if (st == kStatusOk) {
          for (uint32_t id2 : want)
            for (const EdgeSlot &e : edges)
              if (e.id2 == id2) {
                LinkRow lr{};
                lr.id2 = e.id2, lr.version = e.version, lr.time = e.time, lr.data_len = e.data_len;
                rows.push_back(lr);
                break;
              }
          GetLinkResp g{};
          g.list_version = a.version, g.n = uint16_t(rows.size());
          r.put(g);
          r.put_bytes(rows.data(), rows.size() * sizeof(LinkRow));
        }
        (void)nn;
        return finish(j, r, kOpGetLink, st, st == kStatusOk ? 1 : 0, t0, os, cx, uint32_t(rows.size()));
      }
      default: return bad(j);
    }
  }

  // ---------------------------------------------------------------- writer (this VM's writes, arrival order)
  void writer() {
    cxl::proc::name_thread("sg-writer");
    be_->thread_init(1);
    opc_thread_start();
    Ctx cx;
    cx.sb = sl_.on() ? sl_.reg(true, o_.node) : nullptr;
    for (;;) {
      Job j = wq_.pop();
      const uint64_t t0 = mono_ns();
      serve_write(j, cx, t0);
      st_.writer_busy_ns += mono_ns() - t0;
      const uint64_t lag = mono_ns() - j.t_acc;
      st_.write_lag_ns_sum += lag;
      st_.write_lag_n++;
      uint64_t m = st_.write_lag_max_ns.load();
      while (lag > m && !st_.write_lag_max_ns.compare_exchange_weak(m, lag)) {}
      st_.write_jobs_done++;
    }
  }

  void serve_write(Job &j, Ctx &cx, uint64_t t0) {
    const uint32_t n = frame::payload_len(j.h);
    const uint8_t *p = j.p.data();
    const uint16_t op = j.h.code;
    Resp r;
    vdb::OpCohSrc::Start os;
    typename GraphOps<Be>::WriteOut w;
    uint16_t st;
    uint32_t w_seq;
    if (op == kOpAddLink || op == kOpUpdateLink || op == kOpDeleteLink) {
      if (n < sizeof(LinkWriteReq)) return bad(j);
      LinkWriteReq q;
      std::memcpy(&q, p, sizeof q);
      if (n != sizeof(LinkWriteReq) + q.data_len || q.id2 == 0) return bad(j);
      w_seq = q.w_seq;
      oc_.begin(&os);
      const uint8_t *d = p + sizeof q;
      if (op == kOpAddLink) st = ops_->add_link(cx, q.id1, q.id2, q.assoc_type, q.time, d, q.data_len, &w);
      else if (op == kOpUpdateLink) st = ops_->update_link(cx, q.id1, q.id2, q.assoc_type, q.time, d, q.data_len, &w);
      else st = ops_->delete_link(cx, q.id1, q.id2, q.assoc_type, &w);
    } else if (op == kOpAddNode || op == kOpUpdateNode || op == kOpDeleteNode) {
      if (n < sizeof(NodeWriteReq)) return bad(j);
      NodeWriteReq q;
      std::memcpy(&q, p, sizeof q);
      if (n != sizeof(NodeWriteReq) + q.data_len) return bad(j);
      w_seq = q.w_seq;
      oc_.begin(&os);
      st = ops_->node_write(cx, op, q.id, q.type, p + sizeof q, op == kOpDeleteNode ? 0 : q.data_len, &w);
    } else {
      return bad(j);
    }
    oc_.fake_add(1, 1000, 0);  // Host-test fake source only: 1000 ns S->M fault per write
    if (st == kStatusOk) {
      WriteResp wr{};
      wr.id = w.id, wr.version = w.version, wr.commit_ns = w.commit_ns, wr.w_seq = w_seq;
      r.put(wr);
    }
    finish(j, r, op, st, st == kStatusOk ? 1 : 0, t0, os, cx, 0);
  }

  // ---------------------------------------------------------------- network
  void listen_loop() {
    cxl::proc::name_thread("sg-listen");
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(o_.port));
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(ls, reinterpret_cast<sockaddr *>(&a), sizeof(a)) || listen(ls, 128)) die("bind/listen");
    std::fprintf(stderr, "sg-server: READY node %u port %u\n", o_.node, o_.port);
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
    cxl::proc::name_thread("sg-conn");
    frame::header h;
    while (frame::read_full(c->fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      Job j{c, h, std::vector<uint8_t>(frame::payload_len(h))};
      if (!j.p.empty() && !frame::read_full(c->fd, j.p.data(), j.p.size())) break;
      if (is_write(h.code)) {
        j.t_acc = mono_ns();
        st_.write_jobs_accepted++;
        wq_.push(std::move(j));
      } else if (h.code == kOpFeed || h.code == kOpGetNode || h.code == kOpCountLink || h.code == kOpGetLink) {
        qq_.push(std::move(j));
      } else if (h.code == kOpStats) {
        const std::string t = stats_text();
        c->reply(frame::kStatusOk, h.req_id, t.data(), uint32_t(t.size()));
      } else {
        c->reply(frame::kStatusUnknownOp, h.req_id, nullptr, 0);
      }
    }
    close(c->fd);
  }

  Opts o_;
  cxl::region r_;
  uint8_t *map_ = nullptr, *img_ = nullptr;
  uint64_t img_avail_ = 0;
  std::unique_ptr<AppLayout> lay_;
  Locks locks_;
  std::unique_ptr<Be> be_;
  std::unique_ptr<GraphOps<Be>> ops_;
  StaleLog sl_;
  Stats st_;
  OpWin win_[kIxN];
  vdb::OpCohSrc oc_;
  uint32_t tsc_khz_ = 0, nq_ = 0;
  Queue qq_, wq_;
  // same process / node counters as vdb-server (receive kthreads, IPIs, Popcorn / cxl_shm sysfs counters)
  cxl::proc::Opts pst_{{"cxl_recv", "cxl_ipoll"},
                       {"TLB", "CAL", "RES", "LOC"},
                       {"/sys/kernel/swmc/page_coherence", "/sys/kernel/swmc/instr", "/sys/kernel/cxl_shm",
                        "/sys/kernel/cxl_shm/instr"}};
};

volatile sig_atomic_t g_stop = 0;

template <class Be>
int run(const Opts &o) {
  Server<Be> s(o);
  if (!o.copy_image.empty()) return s.copy_image();
  if (o.verify) return s.verify();
  s.start();
  while (!g_stop) usleep(200000);
  s.stop();
  std::fprintf(stderr, "sg-server: stopping\n%s", s.stats_text().c_str());
  std::fflush(stderr);
  std::_Exit(0);
}

void usage() {
  std::fprintf(stderr,
               "usage: sg-server --node K --nodes N --run-id 0x.. [--port P (7100)] [--region yaml]\n"
               "  [--image-offset B (0; from swcc start)] [--query-threads Q (online CPUs - 1)] [--retry-ms M (2000)]\n"
               "  [--stale-dir DIR] [--stale-every E (1000)] [--flush-ms M (1000)] [--op-coh on|off] [--warmup on|off]\n"
               "  [--lock-stripes S (16384)] [--start-timeout-ms T]\n"
               "  --copy-image FILE   node 0: copy the image into the region (plain mapping, no HWcc) and exit\n"
               "  --verify [--image FILE]   check the image in the region (header, layout hash, records; bytes vs FILE)\n"
               "  --print-app-bytes   value for CXL_APP_HWCC_BYTES (same --nodes / --lock-stripes on every node)\n");
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
    auto onoff = [&]() {
      const std::string x = v();
      if (x != "on" && x != "off") usage();
      return x == "on";
    };
    if (a == "--node") o.node = std::stoul(v());
    else if (a == "--nodes") o.nodes = std::stoul(v());
    else if (a == "--run-id") o.run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--port") o.port = std::stoul(v());
    else if (a == "--region") o.region = v();
    else if (a == "--image-offset") o.image_off = std::stoull(v(), nullptr, 0);
    else if (a == "--query-threads") o.query_threads = std::stoul(v());
    else if (a == "--retry-ms") o.retry_ms = std::stoull(v());
    else if (a == "--stale-dir") o.stale_dir = v();
    else if (a == "--stale-every") o.stale_every = std::stoull(v());
    else if (a == "--flush-ms") o.flush_ms = std::stoull(v());
    else if (a == "--op-coh") o.op_coh = onoff();
    else if (a == "--warmup") o.warmup = onoff();
    else if (a == "--lock-stripes") o.lock_stripes = std::stoul(v());
    else if (a == "--start-timeout-ms") o.start_timeout_ms = std::stoull(v());
    else if (a == "--copy-image") o.copy_image = v();
    else if (a == "--verify") o.verify = true;
    else if (a == "--image") o.verify_image = v();
    else if (a == "--print-app-bytes") print_bytes = true;
    else usage();
  }
  if (o.lock_stripes == 0) usage();
  if (print_bytes) {
    if (o.nodes == 0) usage();
    std::printf("%lu\n", (unsigned long)AppLayout(o.nodes, o.lock_stripes).L.bytes());
    return 0;
  }
  const bool serve = o.copy_image.empty() && !o.verify;
  if (serve && (o.run_id == 0 || o.nodes == 0 || o.node >= o.nodes)) usage();
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, [](int) { g_stop = 1; });
  signal(SIGINT, [](int) { g_stop = 1; });
  return run<MmapBackend>(o);
}

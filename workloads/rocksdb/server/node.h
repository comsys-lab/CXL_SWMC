// One node of the rocksdb workload (DESIGN.md §2-§6): region, HWcc app layout, pools, CXL file system, the node's
// primary DB (memtables in the shared arena pool, files in the shared file pool, memtable descriptor published at
// every SuperVersion install), its initial image, the readiness barrier and the views of every other node's DB.
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "backend.h"
#include "cxlfs.h"
#include "layout.h"
#include "proto.h"
#include "remote.h"
#include "rocksdb/compaction_filter.h"
#include "rocksdb/cxl.h"
#include "rocksdb/db.h"
#include "rocksdb/env.h"
#include "rocksdb/filter_policy.h"
#include "rocksdb/options.h"
#include "rocksdb/sst_file_writer.h"
#include "rocksdb/statistics.h"
#include "rocksdb/table.h"
#include "shared.h"

namespace rdbw {

namespace rdb = ROCKSDB_NAMESPACE;

inline uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}
[[noreturn]] inline void die(const std::string &m) {
  std::fprintf(stderr, "rocksdb-server: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct NodeOpts {
  Params p;
  uint32_t node = 0;
  uint64_t run_id = 0, start_timeout_ms = 1800000;
  std::string region;              // default $CXL_REGION_CONFIG
  std::string local_dir = "/tmp/rocksdb-cxl";  // node-local: info logs, (empty) WAL dirs, secondary dirs
  uint32_t prepare_threads = 8;    // image build threads (SST files of disjoint key ranges)
  uint64_t image_file_bytes = 60ull << 20;  // image SST size (< target_file_size_base, << max_ext MiB)
  bool gc_filter = true;           // G1 compaction filter (user decision 2026-10-18)
  uint64_t write_buffer_mb = 64;   // RocksDB default; smaller only in Host tests (forces flushes and compactions)
};

// G1 (DESIGN.md §5): drop an entry when another node's DB holds the key with a higher stamp.
class StaleFilter final : public rdb::CompactionFilter {
 public:
  explicit StaleFilter(std::vector<RemoteView *> *views) : views_(views) {}
  const char *Name() const override { return "CxlStaleFilter"; }
  Decision FilterV2(int, const rdb::Slice &key, ValueType vt, const rdb::Slice &value, std::string *,
                    std::string *) const override {
    if (vt != ValueType::kValue || value.size() < kStampBytes) return Decision::kKeep;
    checked.fetch_add(1, std::memory_order_relaxed);
    const uint64_t s = value_stamp(value.data());
    const std::string k = key.ToString();
    std::string other;
    for (RemoteView *v : *views_) {
      if (!v) continue;
      if (v->get(k, &other) == RemoteView::Res::kFound && other.size() >= kStampBytes && value_stamp(other.data()) > s) {
        dropped.fetch_add(1, std::memory_order_relaxed);
        return Decision::kRemove;
      }
    }
    return Decision::kKeep;
  }
  mutable std::atomic<uint64_t> checked{0}, dropped{0};

 private:
  std::vector<RemoteView *> *views_;
};

class ArenaSource final : public rdb::cxl::BlockSource {
 public:
  explicit ArenaSource(Shared *sh) : sh_(sh) {}
  char *Get(size_t bytes) override { return bytes > kUnit ? nullptr : sh_->get_block(); }
  void Put(const std::vector<char *> &blocks, uint64_t) override { sh_->retire_blocks(blocks); }

 private:
  Shared *sh_;
};

class Node {
 public:
  explicit Node(NodeOpts o) : o_(std::move(o)), p_(o_.p) {}

  void start(const char *who) {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || p_.nr_nodes > kMaxTargets || o_.node >= p_.nr_nodes || p_.keys == 0) die("bad node/nodes/keys");
    be_ = std::make_unique<PlainBackend>();
    HwccLayout lay(p_, be_->layout_tag());
    map_ = map_device();
    if (!plan_.make(r_, p_, &err)) die(err);
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay, p_);
    sh_ = std::make_unique<Shared>(r_, map_, p_, plan_, h_.get(), be_.get(), o_.node);
    std::fprintf(stderr, "%s: node %u/%u run %#lx %s\n%s: region %s\n%s: app layout %lu B (used %lu, hash %016lx), swcc %s, backend %s\n",
                 who, o_.node, p_.nr_nodes, (unsigned long)o_.run_id, p_.describe().c_str(), who,
                 cxl::region_describe(r_).c_str(), who, (unsigned long)lay.L.bytes(), (unsigned long)lay.L.used(),
                 (unsigned long)lay.L.hash(), plan_.describe().c_str(), be_->name());
    fs_ = std::make_shared<CxlFs>(rdb::FileSystem::Default(), sh_.get());
    env_ = rdb::NewCompositeEnv(fs_);
    arena_ = std::make_unique<ArenaSource>(sh_.get());
    views_.assign(p_.nr_nodes, nullptr);
    install_hooks();
    open_primary(who);
    build_image(who);
    cxl::hwcc::store_release(&h_->nodes[o_.node].loaded, o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t v = 0; v < p_.nr_nodes; v++)
                if (cxl::hwcc::load_acquire(&h_->nodes[v].loaded) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("not every node became ready in time");
    for (uint32_t v = 0; v < p_.nr_nodes; v++) {
      if (v == o_.node) continue;
      own_views_.push_back(std::make_unique<RemoteView>(sh_.get(), v));
      if (!own_views_.back()->open(base_options(false), o_.local_dir + "/sec" + std::to_string(v), &err)) die(err);
      views_[v] = own_views_.back().get();
    }
    std::thread([this] {
      cxl::proc::name_thread("rdb-reclaim");
      for (;;) {
        sh_->reclaim();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      }
    }).detach();
    std::fprintf(stderr, "%s: node %u ready, %u remote views, pools %s\n", who, o_.node, p_.nr_nodes - 1,
                 sh_->usage().c_str());
  }

  // ---- requests ----
  // Newest value over every node's DB (highest stamp). *stored = stamp + value.
  bool get(const std::string &key, std::string *stored, uint64_t *remote_errors) {
    std::string cand;
    bool found = false;
    uint64_t best = 0;
    auto s = db_->Get(rdb::ReadOptions(), key, &cand);
    if (s.ok() && cand.size() >= kStampBytes) found = true, best = value_stamp(cand.data()), stored->swap(cand);
    else if (!s.ok() && !s.IsNotFound()) (*remote_errors)++;
    for (RemoteView *v : views_) {
      if (!v) continue;
      auto r = v->get(key, &cand);
      if (r == RemoteView::Res::kError) (*remote_errors)++;
      if (r == RemoteView::Res::kFound && cand.size() >= kStampBytes && (!found || value_stamp(cand.data()) > best)) {
        found = true, best = value_stamp(cand.data()), stored->swap(cand);
      }
    }
    return found;
  }
  // Stamp and insert of one key are ordered per node by a local key stripe, so this node's DB (RocksDB sequence
  // order) never holds a lower stamp above a higher one for the same key; across nodes the highest stamp wins.
  uint64_t put(const std::string &key, const void *v, uint32_t len, rdb::Status *st) {
    rdb::WriteOptions wo;
    wo.disableWAL = true;
    std::lock_guard<std::mutex> g(stripes_[std::hash<std::string>()(key) % kStripes]);
    const uint64_t stamp = cxl::hwcc::fetch_add(h_->stamp, uint64_t(1)) + 1;
    *st = db_->Put(wo, key, make_stored(stamp, v, len));
    return stamp;
  }

  rdb::DB *db() const { return db_.get(); }
  Shared &shared() const { return *sh_; }
  Hwcc &hwcc() const { return *h_; }
  const std::vector<RemoteView *> &views() const { return views_; }
  const StaleFilter *filter() const { return filter_.get(); }
  std::shared_ptr<rdb::Statistics> statistics() const { return stats_; }
  uint64_t desc_installs() const { return installs_.load(); }

 private:
  uint8_t *map_device() {
    int fd = int(syscall(SYS_openat, AT_FDCWD, r_.device.c_str(), O_RDWR | O_CLOEXEC));
    if (fd < 0) die("open " + r_.device);
    void *m = mmap(reinterpret_cast<void *>(r_.map_va), r_.device_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED_NOREPLACE, fd, 0);
    if (m == MAP_FAILED || m != reinterpret_cast<void *>(r_.map_va)) die("mmap " + r_.device + " at map_va");
    close(fd);
    return static_cast<uint8_t *>(m);
  }

  // Options of every DB instance (primary and secondaries); non-defaults are listed in DESIGN.md §6.
  rdb::Options base_options(bool primary) {
    rdb::Options o;
    o.env = env_.get();
    o.create_if_missing = primary;
    o.compression = rdb::kNoCompression;
    o.bottommost_compression = rdb::kNoCompression;
    o.max_open_files = -1;
    o.write_buffer_size = size_t(o_.write_buffer_mb) << 20;
    o.arena_block_size = kUnit;  // = RocksDB's default for write_buffer_size 64 MiB (min(1 MiB, wbs / 8))
    o.max_manifest_file_size = (uint64_t(p_.max_ext) / 2) << 20;  // roll well before a file exceeds max_ext MiB
    o.statistics = stats_;
    rdb::BlockBasedTableOptions t;
    t.filter_policy.reset(rdb::NewBloomFilterPolicy(10));
    o.table_factory.reset(rdb::NewBlockBasedTableFactory(t));
    if (primary) {
      o.db_host_id = "cxl-primary-n" + std::to_string(o_.node);
      o.db_log_dir = o_.local_dir + "/log";
      o.wal_dir = o_.local_dir + "/wal";
      if (o_.gc_filter) o.compaction_filter = filter_.get();
    }
    return o;
  }

  void install_hooks() {
    auto &h = rdb::cxl::GetHooks();
    h.primary_host_id = "cxl-primary-n" + std::to_string(o_.node);
    h.blocks = arena_.get();
    h.on_superversion = [this](const std::vector<rdb::cxl::MemtableInfo> &mts) { publish(mts); };
  }
  // DB mutex held (rocksdb/cxl.h). Seqlock write of this node's descriptor; flush_gen moves when a memtable left.
  void publish(const std::vector<rdb::cxl::MemtableInfo> &mts) {
    if (mts.size() > kMaxMemtables) die("more memtables than descriptor entries (max_write_buffer_number)");
    Desc *d = &h_->desc[o_.node];
    const uint64_t s = cxl::hwcc::load_relaxed(&d->seq);
    std::set<uint64_t> now;
    for (auto &m : mts) now.insert(m.id);
    bool dropped = false;
    for (uint64_t id : published_)
      if (!now.count(id)) dropped = true;
    cxl::hwcc::store_relaxed(&d->seq, s + 1);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    cxl::hwcc::store_relaxed(&d->n, uint64_t(mts.size()));
    for (size_t i = 0; i < mts.size(); i++) {
      cxl::hwcc::store_relaxed(&d->m[i].id, mts[i].id);
      cxl::hwcc::store_relaxed(&d->m[i].head, uint64_t(reinterpret_cast<uintptr_t>(mts[i].head)));
      cxl::hwcc::store_relaxed(&d->m[i].height, uint64_t(mts[i].max_height));
    }
    if (dropped) cxl::hwcc::store_relaxed(&d->flush_gen, (s + 2) / 2);
    __atomic_store_n(&d->seq, s + 2, __ATOMIC_SEQ_CST);  // seq_cst: ordered before the owner's epoch scans
    published_ = now;
    installs_.fetch_add(1, std::memory_order_relaxed);
  }

  void open_primary(const char *who) {
    filter_ = std::make_unique<StaleFilter>(&views_);
    stats_ = rdb::CreateDBStatistics();
    rdb::Options o = base_options(true);
    o.env->CreateDirIfMissing(o_.local_dir);
    o.env->CreateDirIfMissing(o.db_log_dir);
    o.env->CreateDirIfMissing(o.wal_dir);
    rdb::DB *db = nullptr;
    auto s = rdb::DB::Open(o, CxlFs::dir_of(o_.node), &db);
    if (!s.ok()) die("open primary: " + s.ToString());
    db_.reset(db);
    std::fprintf(stderr, "%s: primary %s open (write_buffer_size %zu, arena_block_size %zu, max_write_buffer_number %d)\n",
                 who, CxlFs::dir_of(o_.node).c_str(), o.write_buffer_size, o.arena_block_size, o.max_write_buffer_number);
    if (o.max_write_buffer_number > int(kMaxMemtables)) die("max_write_buffer_number > descriptor entries");
  }

  // Keys i with i % nr_nodes == node, value stamp 0 (writer 0xffff), as SST files of disjoint ranges built in
  // parallel and ingested (moved) into the bottom level (unmeasured prepare).
  void build_image(const char *who) {
    const uint64_t t0 = now_ns();
    const uint64_t mine = (p_.keys - o_.node + p_.nr_nodes - 1) / p_.nr_nodes;  // keys of this node
    const uint64_t per_file = std::max<uint64_t>(1, o_.image_file_bytes / (kKeyBytes + kStampBytes + kValueBytes + 16));
    const uint64_t files = (mine + per_file - 1) / per_file;
    std::vector<std::string> paths(files);
    std::atomic<uint64_t> next{0};
    std::atomic<bool> fail{false};
    std::string ferr;
    std::mutex emu;
    auto worker = [&] {
      rdb::Options o = base_options(true);
      for (uint64_t f; !fail && (f = next.fetch_add(1)) < files;) {
        char name[64];
        std::snprintf(name, sizeof(name), "/img-%06lu.sst", (unsigned long)f);
        paths[f] = CxlFs::dir_of(o_.node) + name;
        rdb::SstFileWriter w(rdb::EnvOptions(), o);
        auto s = w.Open(paths[f]);
        uint8_t v[kValueBytes];
        char k[kKeyBytes];
        for (uint64_t r = f * per_file; s.ok() && r < std::min(mine, (f + 1) * per_file); r++) {
          const uint64_t key = r * p_.nr_nodes + o_.node;
          make_key(key, k);
          fill_value(key, 0, 0xffff, v);
          s = w.Put(rdb::Slice(k, kKeyBytes), make_stored(0, v, kValueBytes));
        }
        if (s.ok()) s = w.Finish();
        if (!s.ok()) {
          std::lock_guard<std::mutex> g(emu);
          ferr = paths[f] + ": " + s.ToString();
          fail = true;
        }
      }
    };
    std::vector<std::thread> th;
    for (uint32_t i = 0; i < std::max<uint32_t>(1, o_.prepare_threads); i++) th.emplace_back(worker);
    for (auto &t : th) t.join();
    if (fail) die("image: " + ferr);
    rdb::IngestExternalFileOptions io;
    io.move_files = true;
    auto s = db_->IngestExternalFile(paths, io);
    if (!s.ok()) die("ingest: " + s.ToString());
    std::fprintf(stderr, "%s: IMAGE %lu keys in %lu files ingested in %.1f s, pools %s\n", who, (unsigned long)mine,
                 (unsigned long)files, (now_ns() - t0) / 1e9, sh_->usage().c_str());
  }

  NodeOpts o_;
  const Params p_;
  cxl::region r_;
  uint8_t *map_ = nullptr;
  SwccPlan plan_;
  std::unique_ptr<Backend> be_;
  std::unique_ptr<Hwcc> h_;
  std::unique_ptr<Shared> sh_;
  std::shared_ptr<CxlFs> fs_;
  std::unique_ptr<rdb::Env> env_;
  std::unique_ptr<ArenaSource> arena_;
  std::unique_ptr<StaleFilter> filter_;
  std::shared_ptr<rdb::Statistics> stats_;
  std::unique_ptr<rdb::DB> db_;
  std::vector<RemoteView *> views_;  // index = node; nullptr for this node
  std::vector<std::unique_ptr<RemoteView>> own_views_;
  std::set<uint64_t> published_;
  std::atomic<uint64_t> installs_{0};
  static constexpr size_t kStripes = 4096;
  std::mutex stripes_[kStripes];  // process-local (this node's writers only)
};

}  // namespace rdbw

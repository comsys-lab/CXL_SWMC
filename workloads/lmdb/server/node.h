// One node of the shared LMDB (DESIGN.md §2-§5): region, HWcc app layout, backend, LMDB env over the region, initial
// image (node 0), readiness barrier, warm-up. Used by lmdb-server and lmdb-stress (identical setup).
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include "backend.h"
#include "layout.h"
#include "lmdb.h"
#include "lmdb_cxl.h"
#include "proc_stats.h"
#include "proto.h"

namespace lmdbw {

inline uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

[[noreturn]] inline void die(const std::string &m) {
  std::fprintf(stderr, "lmdb: FATAL %s\n", m.c_str());
  std::fflush(stderr);
  std::_Exit(2);
}

struct NodeOpts {
  Params p;
  uint32_t node = 0;
  uint64_t run_id = 0, start_timeout_ms = 600000;
  std::string region;       // default $CXL_REGION_CONFIG
  std::string image;        // initial image dir (tools/lmdb-image); node 0 loads it
  bool preload_only = false, preloaded = false;  // Popcorn init_state=shared (as vectordb)
  bool warm = true;
  uint32_t prepare_threads = 1;  // node 0 prepare: object creation and image copy threads (1 = deterministic order)
  std::string megalon_lib;  // default <exe dir>/../lib/libvdb-megalon.so
};

// Image dir: pages.bin ((last_pg + 1) * 4096 B; pages 0/1 unused) + meta.txt (key=value).
struct ImageMeta {
  uint64_t records = 0, txnid = 0, last_pg = 0, entries = 0, depth = 0;
  uint64_t dbs[12] = {};
};
inline bool read_image_meta(const std::string &dir, ImageMeta *m, std::string *err) {
  std::ifstream f(dir + "/meta.txt");
  if (!f) return *err = "cannot open " + dir + "/meta.txt", false;
  std::map<std::string, std::string> kv;
  std::string line;
  while (std::getline(f, line)) {
    const size_t eq = line.find('=');
    if (eq != std::string::npos && line[0] != '#') kv[line.substr(0, eq)] = line.substr(eq + 1);
  }
  if (kv["format"] != "lmdb-image-v1") return *err = "image format != lmdb-image-v1", false;
  try {
    m->records = std::stoull(kv.at("records"));
    m->txnid = std::stoull(kv.at("txnid"));
    m->last_pg = std::stoull(kv.at("last_pg"));
    m->entries = std::stoull(kv.at("entries"));
    m->depth = std::stoull(kv.at("depth"));
    std::istringstream d(kv.at("dbs"));
    std::string w;
    for (int i = 0; i < 12; i++) {
      if (!std::getline(d, w, ',')) return *err = "meta.txt dbs: 12 words expected", false;
      m->dbs[i] = std::stoull(w, nullptr, 0);
    }
    if (std::stoul(kv.at("key_bytes")) != kKeyBytes || std::stoul(kv.at("value_bytes")) != kValueBytes)
      return *err = "image key/value size differs", false;
  } catch (const std::exception &e) {
    return *err = std::string("meta.txt: ") + e.what(), false;
  }
  return true;
}

template <class Be>
class Node {
 public:
  explicit Node(NodeOpts o) : o_(std::move(o)), p_(o_.p) {}

  // Map the region (plain) or load Megalon (which maps it), join the app layout, open the env, load, warm up.
  void start(const char *who) {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (p_.nr_nodes == 0 || o_.node >= p_.nr_nodes || p_.max_pages <= 2 || p_.readers == 0) die("bad node/nodes/max_pages/readers");
    HwccLayout lay(p_, Be::kLayoutTag);
    if constexpr (std::is_same_v<Be, MegalonBackend>) {
      cxl::proc::name_thread("megalon-lib");  // threads Megalon starts while it initialises inherit this name
      api_ = megalon_load(o_.megalon_lib, &err);
      cxl::proc::name_thread(who);
      if (!api_) die(err);
      if (api_->node_id() != o_.node) die("megalon node id " + std::to_string(api_->node_id()) + " != --node");
      if (!mapped_by(r_.map_va, r_.device_size, r_.device, &err)) die(err);
      map_ = reinterpret_cast<uint8_t *>(r_.map_va);
    } else {
      map_ = map_device();
    }
    if (!cxl::hwcc::app_init(r_, map_, lay.L, o_.run_id, p_.nr_nodes, o_.node, o_.start_timeout_ms, &err)) die(err);
    h_ = std::make_unique<Hwcc>(cxl::hwcc::app_base(r_, map_), lay, p_);
    if constexpr (std::is_same_v<Be, MegalonBackend>) be_ = std::make_unique<Be>(r_, map_, p_, api_);
    else be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    be_->thread_init(0);
    std::fprintf(stderr, "%s: node %u/%u run %#lx %s\n%s: region %s\n%s: app layout %lu B (used %lu, hash %016lx), backend %s\n",
                 who, o_.node, p_.nr_nodes, (unsigned long)o_.run_id, p_.describe().c_str(), who,
                 cxl::region_describe(r_).c_str(), who, (unsigned long)lay.L.bytes(), (unsigned long)lay.L.used(),
                 (unsigned long)lay.L.hash(), be_->usage().c_str());
    if (o_.node == 0) load_initial(who);
    cxl::hwcc::store_release(&h_->nodes[o_.node].loaded, o_.run_id);
    if (!cxl::hwcc::poll_until(
            [&] {
              for (uint32_t v = 0; v < p_.nr_nodes; v++)
                if (cxl::hwcc::load_acquire(&h_->nodes[v].loaded) != o_.run_id) return false;
              return true;
            },
            o_.start_timeout_ms))
      die("not every node became ready in time");
    open_env();
    if (!be_->check_pages(&err)) die(err);
    if (o_.warm) warm_up(who);
  }

  // --preload-only (plain, node 0): copy the image pages into SWcc through a plain mapping before coherence is
  // enabled (Popcorn init_state=shared); no HWcc access.
  void preload(const char *who) {
    std::string err;
    if (!cxl::region_load(o_.region.empty() ? nullptr : o_.region.c_str(), &r_, &err)) die("region: " + err);
    if (o_.image.empty() || o_.node != 0) die("--preload-only needs --image and --node 0");
    ImageMeta m;
    if (!read_image_meta(o_.image, &m, &err)) die(err);
    check_image(m);
    map_ = map_device();
    if constexpr (std::is_same_v<Be, PlainBackend>) be_ = std::make_unique<Be>(r_, map_, p_);
    if (!be_->fits(&err)) die(err);
    const uint64_t t0 = now_ns();
    copy_pages(m, std::max<uint32_t>(1, o_.prepare_threads));
    if (munmap(map_, r_.device_size) != 0) die("munmap");
    std::fprintf(stderr, "%s: PRELOAD DONE %lu pages in %.1f s (plain mapping, no HWcc access)\n", who,
                 (unsigned long)(m.last_pg + 1), (now_ns() - t0) / 1e9);
  }

  MDB_env *env() const { return env_; }
  MDB_dbi dbi() const { return dbi_; }
  Be &backend() const { return *be_; }
  Hwcc &hwcc() const { return *h_; }
  const NodeOpts &opts() const { return o_; }
  const cxl::region &region() const { return r_; }
  uint32_t reader_slot(uint32_t i) const {  // this node's i-th reader slot
    if (i >= p_.readers) die("reader slot " + std::to_string(i) + " >= --readers");
    return o_.node * p_.readers + i;
  }

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

  void check_image(const ImageMeta &m) const {
    if (m.records != p_.records) die("image has " + std::to_string(m.records) + " records, --records " + std::to_string(p_.records));
    if (m.last_pg + 1 > p_.max_pages) die("image needs " + std::to_string(m.last_pg + 1) + " pages > --max-pages");
  }

  void copy_pages(const ImageMeta &m, uint32_t threads) {
    const std::string path = o_.image + "/pages.bin";
    {
      std::ifstream f(path, std::ios::binary | std::ios::ate);
      if (!f || uint64_t(f.tellg()) != (m.last_pg + 1) * MDB_CXL_PSIZE) die(path + ": missing or size != (last_pg+1)*4096");
    }
    // pages 2..last_pg in 4 MiB batches; batch b goes to thread b % T (tids 1..T on Megalon, registered per thread)
    const uint32_t T = std::max<uint32_t>(1, threads);
    const uint64_t per = (4u << 20) / MDB_CXL_PSIZE, n = m.last_pg - 1, batches = (n + per - 1) / per;
    auto work = [&](uint32_t t) {
      int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
      if (fd < 0) die("open " + path);
      std::vector<uint8_t> buf(per * MDB_CXL_PSIZE);
      for (uint64_t b = t; b < batches; b += T) {
        const uint64_t p0 = 2 + b * per, k = std::min<uint64_t>(per, m.last_pg + 1 - p0);
        if (pread(fd, buf.data(), k * MDB_CXL_PSIZE, off_t(p0 * MDB_CXL_PSIZE)) != ssize_t(k * MDB_CXL_PSIZE)) die("short read " + path);
        for (uint64_t q = 0; q < k; q++) be_->write_page(p0 + q, buf.data() + q * MDB_CXL_PSIZE);
      }
      close(fd);
    };
    if (T == 1) work(0);
    else {
      std::vector<std::thread> th;
      for (uint32_t t = 0; t < T; t++)
        th.emplace_back([&, t] {
          be_->thread_init(int(1 + t));
          work(t);
          be_->thread_exit();
        });
      for (auto &x : th) x.join();
    }
  }

  // node 0, prepare (unmeasured): create page objects (Megalon), copy the image, publish its meta
  void load_initial(const char *who) {
    const uint64_t t0 = now_ns();
    std::string err;
    ImageMeta m;
    const bool img = !o_.image.empty();
    if (img) {
      if (!read_image_meta(o_.image, &m, &err)) die(err);
      check_image(m);
    } else if (p_.records) {
      die("--records > 0 needs --image");
    }
    const uint32_t T = std::max<uint32_t>(1, o_.prepare_threads);
    double create_s = 0;
    if (T == 1) {  // pgno order on this thread: deterministic Megalon arena placement (required by --preloaded)
      if (!be_->create_pages(&err)) die(err);
      create_s = (now_ns() - t0) / 1e9;
      if (img && !o_.preloaded) copy_pages(m, 1);
      else if (img && !be_->check_placement(m.last_pg, &err)) die(err);
    } else {
      if (o_.preloaded) die("--preloaded needs --prepare-threads 1 (pages must be at their deterministic positions)");
      prepare_parallel(img ? &m : nullptr, T);
    }
    if (!img) {
      mdb_cxl_init_empty(&conf());
      std::fprintf(stderr, "%s: empty database (%.1f s)\n", who, (now_ns() - t0) / 1e9);
      return;
    }
    mdb_cxl_meta_set(&conf(), m.txnid, m.last_pg, m.dbs);
    std::fprintf(stderr, "%s: %s image %s: %lu records, %lu pages, txnid %lu, depth %lu (%.1f s; prepare threads %u%s)\n",
                 who, o_.preloaded ? "published preloaded" : "loaded", o_.image.c_str(), (unsigned long)m.records,
                 (unsigned long)(m.last_pg + 1), (unsigned long)m.txnid, (unsigned long)m.depth, (now_ns() - t0) / 1e9, T,
                 T == 1 ? (", page creation " + std::to_string(create_s) + " s").c_str() : ", create + copy interleaved");
  }

  // T threads (Megalon tids 1..T, registered once each: NR allows 32 registrations per process lifetime): thread t
  // takes 1,024-page batches b = t, t+T, ... of [2, max_pages): creates the batch's page objects, then writes the
  // batch's image pages. Arena placement then depends on timing (not usable with --preloaded).
  void prepare_parallel(const ImageMeta *m, uint32_t T) {
    const std::string path = m ? o_.image + "/pages.bin" : "";
    const uint64_t per = 1024, batches = (p_.max_pages - 2 + per - 1) / per;
    std::vector<std::thread> th;
    for (uint32_t t = 0; t < T; t++)
      th.emplace_back([&, t] {
        be_->thread_init(int(1 + t));
        int fd = m ? open(path.c_str(), O_RDONLY | O_CLOEXEC) : -1;
        if (m && fd < 0) die("open " + path);
        std::vector<uint8_t> buf(per * MDB_CXL_PSIZE);
        std::string err;
        for (uint64_t b = t; b < batches; b += T) {
          const uint64_t p0 = 2 + b * per, k = std::min<uint64_t>(per, p_.max_pages - p0);
          if (!be_->create_range(p0, k, &err)) die(err);
          if (!m || p0 > m->last_pg) continue;
          const uint64_t kk = std::min<uint64_t>(k, m->last_pg + 1 - p0);
          if (pread(fd, buf.data(), kk * MDB_CXL_PSIZE, off_t(p0 * MDB_CXL_PSIZE)) != ssize_t(kk * MDB_CXL_PSIZE))
            die("short read " + path);
          for (uint64_t q = 0; q < kk; q++) be_->write_page(p0 + q, buf.data() + q * MDB_CXL_PSIZE);
        }
        if (fd >= 0) close(fd);
        be_->thread_exit();
      });
    for (auto &x : th) x.join();
  }


  MDB_cxl_conf &conf() {
    conf_ = h_->conf;
    be_->conf(&conf_);
    return conf_;
  }

  void open_env() {
    int rc = mdb_env_create(&env_);
    if (rc) die(std::string("mdb_env_create: ") + mdb_strerror(rc));
    rc = mdb_env_open_cxl(env_, &conf(), 0);
    if (rc) die(std::string("mdb_env_open_cxl: ") + mdb_strerror(rc));
    MDB_txn *txn;
    mdb_cxl_thread_slot(int(reader_slot(0)));  // main thread borrows slot 0 for setup (released at txn end)
    rc = mdb_txn_begin(env_, nullptr, MDB_RDONLY, &txn);
    if (rc) die(std::string("txn_begin: ") + mdb_strerror(rc));
    rc = mdb_dbi_open(txn, nullptr, 0, &dbi_);
    if (rc) die(std::string("mdb_dbi_open: ") + mdb_strerror(rc));
    mdb_txn_abort(txn);
    mdb_cxl_thread_slot(-1);
  }

  // Every node reads every page of the latest snapshot's used range once (pages 2..last_pg), through the backend
  // (Megalon: read sections), so measurements do not include first touches. Identical in every system.
  void warm_up(const char *who) {
    uint64_t t, lp, dbs[12], sum = 0;
    mdb_cxl_meta_get(&h_->conf, &t, &lp, dbs);
    const uint64_t t0 = now_ns();
    for (uint64_t p = 2; p <= lp; p++) sum += be_->warm_page(p);
    std::fprintf(stderr, "%s: warm-up read %lu pages in %.1f s (%lu)\n", who, (unsigned long)(lp > 1 ? lp - 1 : 0),
                 (now_ns() - t0) / 1e9, (unsigned long)(sum & 1));
  }

  NodeOpts o_;
  Params p_;
  cxl::region r_;
  uint8_t *map_ = nullptr;
  const vdb::MegalonApi *api_ = nullptr;
  std::unique_ptr<Hwcc> h_;
  std::unique_ptr<Be> be_;
  MDB_cxl_conf conf_{};
  MDB_env *env_ = nullptr;
  MDB_dbi dbi_ = 0;
};

// Megalon reads node id, run id and region config from the environment when its library loads (as vdb-server).
inline void megalon_env(NodeOpts &o, const char *argv0) {
  auto env = [](const char *k, const std::string &v) {
    const char *cur = getenv(k);
    if (cur && *cur && v != cur) {
      std::fprintf(stderr, "lmdb: %s=%s contradicts the option (%s)\n", k, cur, v.c_str());
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
    o.megalon_lib = d.substr(0, d.rfind('/')) + "/../lib/libvdb-megalon.so";
  }
}

}  // namespace lmdbw

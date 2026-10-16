// lmdb-image: build the disposable initial image (DESIGN.md §5) on the Host, outside any measurement: N YCSB records
// (key "user%020d", 1,000 B value version 0) inserted in key order with MDB_APPEND, `--batch` records per write txn,
// by the same patched liblmdb the servers run (plain page access over a file instead of the region; the lock-file
// state in local memory). Output DIR/pages.bin ((last_pg + 1) x 4096 B; pages 0/1 unused) and DIR/meta.txt.
// usage: lmdb-image --out DIR --records N [--batch 100000] [--max-pages P] [--no-verify]
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "lmdb.h"
#include "lmdb_cxl.h"
#include "node.h"
#include "proto.h"

using namespace lmdbw;

int main(int argc, char **argv) {
  std::string out;
  uint64_t records = 0, batch = 100000, max_pages = 0;
  bool verify = true;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) die("missing value for " + a);
      return argv[++i];
    };
    if (a == "--out") out = v();
    else if (a == "--records") records = std::stoull(v());
    else if (a == "--batch") batch = std::stoull(v());
    else if (a == "--max-pages") max_pages = std::stoull(v());
    else if (a == "--no-verify") verify = false;
    else die("usage: lmdb-image --out DIR --records N [--batch B] [--max-pages P] [--no-verify]");
  }
  if (out.empty() || records == 0 || batch == 0) die("need --out and --records > 0");
  // 3 records per leaf (1,032 B nodes, 4,080 B usable) + branches + freeDB + slack
  if (!max_pages) max_pages = records / 3 + records / 50 + 4096;
  if (mkdir(out.c_str(), 0755) != 0) die("mkdir " + out + " (must not exist)");
  const std::string path = out + "/pages.bin";
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_EXCL, 0644);
  if (fd < 0 || ftruncate(fd, off_t(max_pages * MDB_CXL_PSIZE)) != 0) die("create " + path);
  char *base = static_cast<char *>(mmap(nullptr, max_pages * MDB_CXL_PSIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
  if (base == MAP_FAILED) die("mmap " + path);

  // lock-file state: the same structure the servers keep in HWcc, here in local memory
  auto *st = static_cast<uint64_t *>(aligned_alloc(64, 4096));
  std::memset(st, 0, 4096);
  MDB_cxl_conf c{};
  c.wlock = st;
  c.committed = st + 16;
  c.meta = reinterpret_cast<MDB_cxl_meta *>(st + 32);
  c.readers = st + 64;
  c.nreaders = 1;
  c.max_pages = max_pages;
  c.page_base = base;
  mdb_cxl_init_empty(&c);

  MDB_env *env;
  int rc = mdb_env_create(&env);
  if (!rc) rc = mdb_env_open_cxl(env, &c, 0);
  if (rc) die(std::string("env: ") + mdb_strerror(rc));
  mdb_cxl_thread_slot(0);
  const uint64_t t0 = now_ns();
  MDB_dbi dbi = 0;
  uint8_t val[kValueBytes];
  char key[kKeyBytes];
  for (uint64_t i = 0; i < records;) {
    MDB_txn *txn;
    if ((rc = mdb_txn_begin(env, nullptr, 0, &txn))) die(std::string("txn_begin: ") + mdb_strerror(rc));
    if (i == 0 && (rc = mdb_dbi_open(txn, nullptr, 0, &dbi))) die(std::string("dbi_open: ") + mdb_strerror(rc));
    for (uint64_t e = std::min(records, i + batch); i < e; i++) {
      make_key(i, key);
      fill_value(i, 0, 0xffff, val);
      MDB_val k{kKeyBytes, key}, v{kValueBytes, val};
      if ((rc = mdb_put(txn, dbi, &k, &v, MDB_APPEND))) die("put " + std::to_string(i) + ": " + mdb_strerror(rc));
    }
    if ((rc = mdb_txn_commit(txn))) die(std::string("commit: ") + mdb_strerror(rc));
    if ((i / batch) % 100 == 0 || i == records)
      std::fprintf(stderr, "lmdb-image: %lu / %lu records (%.1f s)\n", (unsigned long)i, (unsigned long)records,
                   (now_ns() - t0) / 1e9);
  }
  uint64_t txnid, last_pg, dbs[12];
  mdb_cxl_meta_get(&c, &txnid, &last_pg, dbs);
  MDB_txn *rt;
  if ((rc = mdb_txn_begin(env, nullptr, MDB_RDONLY, &rt))) die(std::string("read txn: ") + mdb_strerror(rc));
  MDB_stat s;
  mdb_stat(rt, dbi, &s);
  uint64_t n = 0, bad = 0;
  if (verify) {
    MDB_cursor *cur;
    mdb_cursor_open(rt, dbi, &cur);
    MDB_val k, v;
    for (rc = mdb_cursor_get(cur, &k, &v, MDB_FIRST); rc == 0; rc = mdb_cursor_get(cur, &k, &v, MDB_NEXT), n++) {
      uint64_t i;
      ValHdr h;
      if (!parse_key(k.mv_data, uint32_t(k.mv_size), &i) || i != n ||
          !check_value(i, static_cast<uint8_t *>(v.mv_data), uint32_t(v.mv_size), &h) || h.version != 0)
        bad++;
    }
    mdb_cursor_close(cur);
    if (n != records || bad) die("verify: " + std::to_string(n) + " entries, " + std::to_string(bad) + " bad");
  }
  mdb_txn_abort(rt);
  if (s.ms_entries != records) die("entries " + std::to_string(s.ms_entries) + " != records");
  if (msync(base, (last_pg + 1) * MDB_CXL_PSIZE, MS_SYNC) || munmap(base, max_pages * MDB_CXL_PSIZE) ||
      ftruncate(fd, off_t((last_pg + 1) * MDB_CXL_PSIZE)) || close(fd))
    die("finish " + path);
  FILE *m = std::fopen((out + "/meta.txt").c_str(), "w");
  std::fprintf(m, "format=lmdb-image-v1\nrecords=%lu\nkey_bytes=%u\nvalue_bytes=%u\nbatch=%lu\ntxnid=%lu\nlast_pg=%lu\n"
               "entries=%lu\ndepth=%u\nleaf_pages=%lu\nbranch_pages=%lu\noverflow_pages=%lu\nverified=%d\ndbs=",
               (unsigned long)records, kKeyBytes, kValueBytes, (unsigned long)batch, (unsigned long)txnid,
               (unsigned long)last_pg, (unsigned long)s.ms_entries, s.ms_depth, (unsigned long)s.ms_leaf_pages,
               (unsigned long)s.ms_branch_pages, (unsigned long)s.ms_overflow_pages, int(verify));
  for (int i = 0; i < 12; i++) std::fprintf(m, "%s%#lx", i ? "," : "", (unsigned long)dbs[i]);
  std::fprintf(m, "\nbuild_s=%.1f\n", (now_ns() - t0) / 1e9);
  std::fclose(m);
  std::fprintf(stderr, "lmdb-image: done %s: %lu records, depth %u, %lu leaf + %lu branch pages, last_pg %lu, txnid %lu, "
               "%.1f s\n", out.c_str(), (unsigned long)records, s.ms_depth, (unsigned long)s.ms_leaf_pages,
               (unsigned long)s.ms_branch_pages, (unsigned long)last_pg, (unsigned long)txnid, (now_ns() - t0) / 1e9);
  return 0;
}

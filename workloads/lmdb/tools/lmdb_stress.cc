// lmdb-stress: cross-node MVCC test of the shared LMDB (DESIGN.md §6), one process per node, no network.
// Same node setup as lmdb-server (node.h). Per node: one updater thread (write txns of --keys-per-txn overwrites,
// value writer = node id) and --readers-threads reader threads. A reader opens a snapshot, reads --read-keys random keys
// (copies), holds the snapshot for --hold-us while the other node keeps committing and reusing freed pages, re-reads the
// same keys and requires byte-identical values (snapshot isolation; fails if a page of a live snapshot was reused by
// either node's writer), checks every value's integrity and that its snapshot txnid never goes backwards.
// A small --max-pages forces page reuse (MDB_MAP_FULL = the oldest-reader rule kept too many pages: reported).
// Exit 0 only if no violation. At the end node 0 scans the whole DB (entries, order, value integrity).
// usage: lmdb-stress --node K --nodes N --run-id 0x.. --max-pages P --records R --image DIR (node 0) [--region yaml]
//          [--seconds 10] [--reader-threads 4] [--read-keys 8] [--hold-us 2000] [--keys-per-txn 4] [--seed S]
//          [--readers 32] [--backend plain|megalon] [--megalon-lib PATH]
#include <signal.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "node.h"
#include "proto.h"

using namespace lmdbw;

namespace {

struct Opts {
  NodeOpts n;
  uint32_t seconds = 10, reader_threads = 4, read_keys = 8, hold_us = 2000, keys_per_txn = 4;
  uint64_t seed = 20261016;
  std::string backend = "plain";
};

struct Counters {
  std::atomic<uint64_t> txns{0}, updates{0}, update_errors{0}, map_full{0};
  std::atomic<uint64_t> snapshots{0}, reads{0}, changed_in_snapshot{0}, bad_values{0}, txnid_backwards{0},
      read_errors{0}, other_node_values{0}, max_snapshot_age{0};
};

template <class Be>
int run(const Opts &o) {
  Node<Be> node(o.n);
  node.start("lmdb-stress");
  if (o.reader_threads + 1 > o.n.p.readers) die("--reader-threads must be < --readers");
  Counters c;
  std::atomic<bool> stop{false};
  std::vector<uint32_t> txn_us;  // updater: per write txn latency (begin incl. lock wait .. commit), us
  const uint64_t records = o.n.p.records;
  if (!records) die("needs an image (--records > 0)");
  std::vector<std::thread> th;
  th.emplace_back([&] {  // updater
    cxl::proc::name_thread("stress-writer");
    node.backend().thread_init(1);
    std::mt19937_64 rng(o.seed * 7919 + o.n.node);
    uint8_t val[kValueBytes];
    char key[kKeyBytes];
    uint64_t version = uint64_t(o.n.node + 1) << 40;
    while (!stop.load(std::memory_order_relaxed)) {
      MDB_txn *txn;
      const uint64_t ta = now_ns();
      int rc = mdb_txn_begin(node.env(), nullptr, 0, &txn);
      if (rc) die(std::string("write begin: ") + mdb_strerror(rc));
      for (uint32_t k = 0; k < o.keys_per_txn && !rc; k++) {
        const uint64_t i = rng() % records;
        make_key(i, key);
        fill_value(i, ++version, o.n.node, val);
        MDB_val kk{kKeyBytes, key}, vv{kValueBytes, val};
        rc = mdb_put(txn, node.dbi(), &kk, &vv, 0);
      }
      if (!rc) rc = mdb_txn_commit(txn);
      else mdb_txn_abort(txn);
      if (rc == MDB_MAP_FULL) {
        c.map_full++;
        die("MDB_MAP_FULL (page reuse did not keep up; see DESIGN.md §6)");
      }
      if (rc) {
        c.update_errors++;
        die(std::string("update: ") + mdb_strerror(rc));
      }
      c.txns++;
      c.updates += o.keys_per_txn;
      txn_us.push_back(uint32_t(std::min<uint64_t>((now_ns() - ta) / 1000, 0xffffffffu)));
    }
  });
  for (uint32_t r = 0; r < o.reader_threads; r++)
    th.emplace_back([&, r] {
      cxl::proc::name_thread("stress-reader");
      node.backend().thread_init(int(2 + r));
      mdb_cxl_thread_slot(int(node.reader_slot(r)));
      std::mt19937_64 rng(o.seed * 104729 + o.n.node * 1000 + r);
      std::vector<std::vector<uint8_t>> first(o.read_keys, std::vector<uint8_t>(kValueBytes));
      std::vector<uint64_t> keys(o.read_keys);
      char key[kKeyBytes];
      uint64_t last_txnid = 0;
      MDB_txn *txn;
      int rc = mdb_txn_begin(node.env(), nullptr, MDB_RDONLY, &txn);
      if (rc) die(std::string("read begin: ") + mdb_strerror(rc));
      mdb_txn_reset(txn);
      while (!stop.load(std::memory_order_relaxed)) {
        if ((rc = mdb_txn_renew(txn))) die(std::string("renew: ") + mdb_strerror(rc));
        const uint64_t t = mdb_txn_id(txn);
        if (t < last_txnid) c.txnid_backwards++;
        last_txnid = t;
        for (int pass = 0; pass < 2; pass++) {
          for (uint32_t k = 0; k < o.read_keys; k++) {
            if (pass == 0) keys[k] = rng() % records;
            make_key(keys[k], key);
            MDB_val kk{kKeyBytes, key}, vv;
            rc = mdb_get(txn, node.dbi(), &kk, &vv);
            c.reads++;
            if (rc) {
              c.read_errors++;
              continue;
            }
            ValHdr h;
            if (!check_value(keys[k], static_cast<uint8_t *>(vv.mv_data), uint32_t(vv.mv_size), &h)) c.bad_values++;
            else if (h.writer != 0xffff && h.writer != o.n.node) c.other_node_values++;
            if (pass == 0) std::memcpy(first[k].data(), vv.mv_data, kValueBytes);
            else if (std::memcmp(first[k].data(), vv.mv_data, kValueBytes) != 0) c.changed_in_snapshot++;
          }
          if (pass == 0) {  // hold the snapshot while both writers commit
            const uint64_t until = now_ns() + uint64_t(o.hold_us) * 1000;
            while (now_ns() < until) std::this_thread::yield();
          }
        }
        uint64_t committed, lp, dbs[12];
        mdb_cxl_meta_get(&node.hwcc().conf, &committed, &lp, dbs);
        uint64_t age = committed - t, cur = c.max_snapshot_age.load();
        while (age > cur && !c.max_snapshot_age.compare_exchange_weak(cur, age)) {
        }
        mdb_txn_reset(txn);
        c.snapshots++;
      }
      mdb_txn_abort(txn);
    });
  const uint64_t t0 = now_ns();
  while (now_ns() - t0 < uint64_t(o.seconds) * 1000000000ull) usleep(100000);
  stop = true;
  for (auto &t : th) t.join();
  MDB_cxl_stats cs{};
  mdb_cxl_get_stats(node.env(), &cs);
  {
    std::vector<uint32_t> v = txn_us;
    std::sort(v.begin(), v.end());
    uint64_t sum = 0, slow = 0, slow_sum = 0;
    for (uint32_t x : v) {
      sum += x;
      if (x >= 100000) slow++, slow_sum += x;
    }
    auto q = [&](double f) { return v.empty() ? 0u : v[std::min<size_t>(v.size() - 1, size_t(f * v.size()))]; };
    std::printf("node=%u write_txn_us p50=%u p90=%u p99=%u max=%u txns_ge_100ms=%lu share_of_time_ge_100ms=%.3f\n", o.n.node,
                q(0.5), q(0.9), q(0.99), v.empty() ? 0 : v.back(), (unsigned long)slow, sum ? double(slow_sum) / double(sum) : 0.0);
  }
  std::printf("node=%u seconds=%u txns=%lu updates=%lu snapshots=%lu reads=%lu other_node_values=%lu max_snapshot_age=%lu "
              "oldest_lag_max=%lu wlock_wait_ms=%lu page_writes=%lu reader_retries=%lu\n",
              o.n.node, o.seconds, (unsigned long)c.txns.load(), (unsigned long)c.updates.load(),
              (unsigned long)c.snapshots.load(), (unsigned long)c.reads.load(), (unsigned long)c.other_node_values.load(),
              (unsigned long)c.max_snapshot_age.load(), (unsigned long)cs.oldest_lag_max,
              (unsigned long)(cs.wlock_wait_ns / 1000000), (unsigned long)cs.page_writes, (unsigned long)cs.reader_retries);
  std::printf("node=%u violations: changed_in_snapshot=%lu bad_values=%lu txnid_backwards=%lu read_errors=%lu "
              "update_errors=%lu\n",
              o.n.node, (unsigned long)c.changed_in_snapshot.load(), (unsigned long)c.bad_values.load(),
              (unsigned long)c.txnid_backwards.load(), (unsigned long)c.read_errors.load(),
              (unsigned long)c.update_errors.load());
  uint64_t bad = c.changed_in_snapshot + c.bad_values + c.txnid_backwards + c.read_errors + c.update_errors;
  // both nodes finished writing before node 0 scans (barrier through the node lines: updates field = done marker)
  cxl::hwcc::store_release(&node.hwcc().nodes[o.n.node].updates, o.n.run_id);
  if (!cxl::hwcc::poll_until(
          [&] {
            for (uint32_t v = 0; v < o.n.p.nr_nodes; v++)
              if (cxl::hwcc::load_acquire(&node.hwcc().nodes[v].updates) != o.n.run_id) return false;
            return true;
          },
          o.n.start_timeout_ms))
    die("peer did not finish");
  if (o.n.node == 0) {
    mdb_cxl_thread_slot(int(node.reader_slot(o.n.p.readers - 1)));
    MDB_txn *txn;
    MDB_cursor *cur;
    if (mdb_txn_begin(node.env(), nullptr, MDB_RDONLY, &txn) || mdb_cursor_open(txn, node.dbi(), &cur)) die("scan");
    MDB_val k, v;
    uint64_t n = 0, sbad = 0, prev = 0;
    int rc;
    for (rc = mdb_cursor_get(cur, &k, &v, MDB_FIRST); rc == 0; rc = mdb_cursor_get(cur, &k, &v, MDB_NEXT), n++) {
      uint64_t i = 0;
      ValHdr h;
      if (!parse_key(k.mv_data, uint32_t(k.mv_size), &i) || (n && i <= prev) ||
          !check_value(i, static_cast<uint8_t *>(v.mv_data), uint32_t(v.mv_size), &h))
        sbad++;
      prev = i;
    }
    std::printf("node=0 final scan txnid=%lu entries=%lu expected=%lu bad=%lu end=%s\n", (unsigned long)mdb_txn_id(txn),
                (unsigned long)n, (unsigned long)records, (unsigned long)sbad, rc == MDB_NOTFOUND ? "ok" : mdb_strerror(rc));
    if (n != records || sbad || rc != MDB_NOTFOUND) bad++;
    mdb_cursor_close(cur);
    mdb_txn_abort(txn);
  }
  std::printf("node=%u RESULT %s\n", o.n.node, bad ? "FAIL" : "PASS");
  std::fflush(stdout);
  std::fflush(stderr);
  std::_Exit(bad ? 1 : 0);
}

}  // namespace

int main(int argc, char **argv) {
  Opts o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto v = [&]() -> std::string {
      if (i + 1 >= argc) die("missing value for " + a);
      return argv[++i];
    };
    if (a == "--node") o.n.node = std::stoul(v());
    else if (a == "--nodes") o.n.p.nr_nodes = std::stoul(v());
    else if (a == "--run-id") o.n.run_id = std::stoull(v(), nullptr, 0);
    else if (a == "--region") o.n.region = v();
    else if (a == "--image") o.n.image = v();
    else if (a == "--max-pages") o.n.p.max_pages = std::stoull(v());
    else if (a == "--records") o.n.p.records = std::stoull(v());
    else if (a == "--readers") o.n.p.readers = std::stoul(v());
    else if (a == "--seconds") o.seconds = std::stoul(v());
    else if (a == "--reader-threads") o.reader_threads = std::stoul(v());
    else if (a == "--read-keys") o.read_keys = std::stoul(v());
    else if (a == "--hold-us") o.hold_us = std::stoul(v());
    else if (a == "--keys-per-txn") o.keys_per_txn = std::stoul(v());
    else if (a == "--seed") o.seed = std::stoull(v());
    else if (a == "--start-timeout-ms") o.n.start_timeout_ms = std::stoull(v());
    else if (a == "--no-warm") o.n.warm = false;
    else if (a == "--prepare-threads") o.n.prepare_threads = std::stoul(v());
    else if (a == "--preloaded") o.n.preloaded = true;
    else if (a == "--backend") o.backend = v();
    else if (a == "--megalon-lib") o.n.megalon_lib = v();
    else die("unknown option " + a + " (see the header of tools/lmdb_stress.cc)");
  }
  if (o.n.run_id == 0 || o.n.p.max_pages <= 2) die("need --run-id and --max-pages");
  signal(SIGPIPE, SIG_IGN);
  if (o.backend == "plain") return run<PlainBackend>(o);
  if (o.backend != "megalon") die("--backend plain|megalon");
  megalon_env(o.n, argv[0]);
  return run<MegalonBackend>(o);
}

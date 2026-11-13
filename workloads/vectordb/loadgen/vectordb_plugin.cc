// loadgen plugin "vectordb" (workloads/vectordb/DESIGN.md, experiments/loadgen/README.md).
// Streams: "update" (ordered; the writes file in w_seq order, two records per update: DELETE w, INSERT w+1, same
// target VM -> one kOpUpdate request) and "search" (query row and target drawn with the seed; E1 snapshot ref_w = last
// write made before it, i.e. the insert's w_seq of the last update scheduled before it). The writes file must come
// from tools/gen_writes.py --mode update (checked at init); an update counts as one request/operation.
// Options: data=DIR (pool_b.fbin, queries.fbin), writes=FILE (tools/gen_writes.py), k=10, seed=N,
//          max_searches=N (default 100M; result slots are allocated in chunks as used),
//          w_start=N (default 0): first writes-file record of this invocation (even = an update boundary). A second
//          loadgen invocation inside the same server lifetime (H1-HOOK v2 parts) continues the update stream where the
//          previous one stopped (its vectordb.txt next_w), since the server accepts each id's writes only once and in
//          w_seq order; searches start with E1 snapshot ref_w = w_seq of record N-1.
// Output: <out>/searches.bin, one record per search response (header struct below + ids[k] u64 + scores[k] f32),
//         for offline recall (tools/compute_gt.py), <out>/op-coh.bin, one OpLog per OK search or update response
//         that carries the server's per-operation block (proto.h OpCoh v2; DESIGN.md §15; parsed by
//         experiments/vectordb/opsplit.py), and <out>/vectordb.txt (counts). Servers before vdb build 10 sent the
//         v1 SearchCoh block on searches only (search-coh.bin, qcoh.py); this plugin counts those as bad_coh_version.
// Staleness copies (DESIGN.md §20; experiment vector-db-staleness-recall; both default off = output unchanged):
//          stale_ms=T0,T1,..  (e.g. 0,1,10,100,1000,10000; integers ms, distinct, at most 16): every search arrival
//          (one query row = one "group") becomes len(LIST) search requests sent back to back to the same target
//          (engine burst(), same scheduled time t); copy i asks for snapshot s_i = the insert w_seq of the last update
//          scheduled at or before t - T_i (T = 0: the usual E1 ref_w); before the first update of this invocation the
//          snapshot is the initial one (w_start). The search stream's rate counts groups (query/s); requests/s =
//          rate x len(LIST). searches.bin ref_w = the SENT snapshot s_i (so e1_check.py checks what the server was asked
//          for); <out>/stale.bin (StaleLog, 40 B, one per search made, written at the end in seq order, also for
//          searches without a response) holds the group, T_i, the fresh ref_w (= s_0 of T = 0) and the latency.
//          search_target=N: every search goes to target N (the target draw still consumes the seeded generator, so
//          the query rows equal those of a run without the option).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

#include "frame.h"
#include "../proto.h"
#include "workload.h"

namespace {

struct __attribute__((packed)) WriteRec {
  uint8_t op, target;
  uint16_t pad0;
  uint32_t w_seq;
  uint64_t id;
  uint32_t vec_ref, pad1;
};
static_assert(sizeof(WriteRec) == 24, "gen_writes.py record");

struct __attribute__((packed)) SearchLog {  // one per search response, followed by ids[k] (u64) and scores[k] (f32)
  uint64_t seq;
  uint32_t qrow, ref_w, s_used;
  uint8_t measured, pad;
  uint16_t status, n, k;
  uint32_t wait_us, replay_us, search_us, lock_us, dists;
  uint16_t segs, pad2;
};

// stale_ms sidecar (stale.bin): one per search MADE (seq = searches.bin seq), written at finish in seq order.
// flags: bit 0 = a response arrived (status / lat_us valid), bit 1 = measured (from the response). sent = snapshot the
// request asked for (= searches.bin ref_w); fresh = ref_w of T = 0 at the same scheduled time (sched_ns).
// lat_us = response time - scheduled time (CLOCK_MONOTONIC, as the engine's latency), 0 without a response.
struct __attribute__((packed)) StaleLog {
  uint64_t seq, sched_ns;
  uint32_t group, t_ms, fresh, sent, lat_us;
  uint16_t status;
  uint8_t flags, t_idx;
};
static_assert(sizeof(StaleLog) == 40, "stale.bin record (experiments/vectordb/staleness_recall.py)");

// One per OK search/update response with an OpCoh block. seq joins searches.bin (searches) or is the update index
// (updates); recv_ns = CLOCK_MONOTONIC when the plugin got the response (the engine's done time of the same request is
// taken just before on_response on the same thread: joins the loadgen raw-step records, opsplit.py).
struct __attribute__((packed)) OpLog {
  uint64_t seq, recv_ns;
  uint8_t measured, target;
  uint16_t status;
  uint16_t op;  // vdb::kOpSearch | kOpUpdate
  uint16_t pad;
  vdb::OpCoh c;
};
static_assert(sizeof(OpLog) == 24 + sizeof(vdb::OpCoh), "OpLog layout (opsplit.py)");

uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

struct Fbin {
  const float *rows = nullptr;
  uint64_t n = 0, dim = 0;
  bool open(const std::string &path, std::string *err) {
    int fd = ::open(path.c_str(), O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) return *err = "cannot open " + path, false;
    void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED) return *err = "cannot map " + path, false;
    const int32_t *h = static_cast<const int32_t *>(m);
    n = uint64_t(h[0]), dim = uint64_t(h[1]);
    if (uint64_t(st.st_size) != 8 + n * dim * 4) return *err = path + ": size does not match header", false;
    rows = reinterpret_cast<const float *>(static_cast<const uint8_t *>(m) + 8);
    return true;
  }
};

class VectorDb : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    targets_ = targets;
    const std::string data = get("data", ""), writes = get("writes", "");
    if (data.empty() || writes.empty()) return *err = "need --opt data=DIR --opt writes=FILE", false;
    k_ = uint16_t(std::stoul(get("k", "10")));
    seed_ = std::stoull(get("seed", "20261015"));
    max_searches_ = std::stoull(get("max_searches", "100000000"));
    w_start_ = std::stoull(get("w_start", "0"));
    stale_spec_ = get("stale_ms", "");
    if (!stale_spec_.empty()) {
      size_t p = 0;
      while (p <= stale_spec_.size()) {
        const size_t c = std::min(stale_spec_.find(',', p), stale_spec_.size());
        const std::string tok = stale_spec_.substr(p, c - p);
        if (tok.empty() || tok.find_first_not_of("0123456789") != std::string::npos || tok.size() > 7)
          return *err = "stale_ms: '" + stale_spec_ + "' is not a comma list of integer ms (<= 9999999)", false;
        const uint32_t t = uint32_t(std::stoul(tok));
        if (std::find(stale_ms_.begin(), stale_ms_.end(), t) != stale_ms_.end())
          return *err = "stale_ms: " + tok + " listed twice", false;
        stale_ms_.push_back(t);
        p = c + 1;
      }
      if (stale_ms_.size() > 16) return *err = "stale_ms: at most 16 values", false;
      max_stale_ns_ = uint64_t(*std::max_element(stale_ms_.begin(), stale_ms_.end())) * 1000000ull;
    }
    search_target_ = std::stol(get("search_target", "-1"));
    if (search_target_ < -1 || search_target_ >= long(targets))
      return *err = "search_target " + std::to_string(search_target_) + " is not one of the " + std::to_string(targets) +
                    " targets", false;
    rng_.seed(seed_);
    if (!pool_b_.open(data + "/pool_b.fbin", err) || !queries_.open(data + "/queries.fbin", err)) return false;
    if (pool_b_.dim != queries_.dim) return *err = "pool B / queries dim differ", false;
    dim_ = uint32_t(pool_b_.dim);
    FILE *f = std::fopen(writes.c_str(), "rb");
    if (!f) return *err = "cannot open " + writes, false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz % long(sizeof(WriteRec))) return std::fclose(f), *err = writes + ": bad size", false;
    writes_.resize(size_t(sz) / sizeof(WriteRec));
    bool ok = std::fread(writes_.data(), sizeof(WriteRec), writes_.size(), f) == writes_.size();
    std::fclose(f);
    if (!ok) return *err = "short read " + writes, false;
    for (size_t i = 0; i < writes_.size(); i++) {
      const WriteRec &w = writes_[i];
      if (w.w_seq != i + 1 || w.target >= targets || (w.op == vdb::kOpInsert && w.vec_ref >= pool_b_.n) ||
          (w.op != vdb::kOpInsert && w.op != vdb::kOpDelete))
        return *err = "writes file record " + std::to_string(i) + " invalid for " + std::to_string(targets) +
                      " targets", false;
    }
    if (!check_pairs(writes_, err)) return false;
    if (w_start_ % 2 || w_start_ > writes_.size())
      return *err = "w_start " + std::to_string(w_start_) + " is odd or beyond the writes file", false;
    next_w_ = w_start_;
    last_w_ = w_start_ ? writes_[w_start_ - 1].w_seq : 0;
    init_w_ = last_w_;  // stale_ms: snapshot before the first update of this invocation
    chunks_.reset(new std::atomic<Slot *>[kMaxChunks]);
    for (uint64_t i = 0; i < kMaxChunks; i++) chunks_[i].store(nullptr);
    writes_path_ = writes, data_ = data;
    return true;
  }

  // Update pairs (gen_writes.py --mode update): record 2k = DELETE (w_seq 2k+1), record 2k+1 = INSERT (w_seq 2k+2),
  // same target. Records are already checked for w_seq order, targets and pool B rows.
  static bool check_pairs(const std::vector<WriteRec> &w, std::string *err) {
    if (w.size() % 2) return *err = "writes file: odd record count (not update pairs; gen_writes.py --mode update)", false;
    for (size_t i = 0; i < w.size(); i += 2)
      if (w[i].op != vdb::kOpDelete || w[i + 1].op != vdb::kOpInsert || w[i].target != w[i + 1].target)
        return *err = "writes file: records " + std::to_string(i) + "/" + std::to_string(i + 1) +
                      " are not a DELETE+INSERT pair to one target (gen_writes.py --mode update)", false;
    return true;
  }

  std::vector<loadgen::StreamSpec> streams() const override { return {{"update", true}, {"search", false}}; }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    if (stream == 0) {
      if (next_w_ + 2 > writes_.size()) return false;
      const WriteRec &d = writes_[next_w_], &w = writes_[next_w_ + 1];
      r->target = w.target;
      r->op = vdb::kOpUpdate;
      r->seq = next_w_ / 2;  // update index
      vdb::UpdateReq q{d.w_seq, w.w_seq, d.id, w.id};
      p->resize(sizeof(q) + dim_ * 4);
      std::memcpy(p->data(), &q, sizeof(q));
      std::memcpy(p->data() + sizeof(q), pool_b_.rows + uint64_t(w.vec_ref) * dim_, dim_ * 4);
      next_w_ += 2;
      last_w_ = w.w_seq;  // E1: the insert's w_seq (the update's last write)
      if (!stale_ms_.empty()) hist_.emplace_back(r->sched_ns, last_w_);  // schedule history for the lookback
      return true;
    }
    const uint32_t nb = burst(1);
    if (bpos_ == 0) {  // a new arrival (group): query row, target and the snapshot of every copy
      if (next_s_ + nb > max_searches_) return false;
      cur_qrow_ = uint32_t(std::uniform_int_distribution<uint64_t>(0, queries_.n - 1)(rng_));
      cur_target_ = uint32_t(std::uniform_int_distribution<uint32_t>(0, targets_ - 1)(rng_));
      if (search_target_ >= 0) cur_target_ = uint32_t(search_target_);
      cur_fresh_ = last_w_;
      cur_sched_ = r->sched_ns;
      cur_snap_.assign(nb, last_w_);
      if (!stale_ms_.empty()) {
        // drop history no lookback can need: keep the last update at or before the oldest cutoff (sched - T_max)
        while (hist_.size() >= 2 && cur_sched_ >= max_stale_ns_ && hist_[1].first <= cur_sched_ - max_stale_ns_)
          hist_.pop_front();
        for (uint32_t i = 0; i < nb; i++) {
          const uint64_t T = uint64_t(stale_ms_[i]) * 1000000ull;
          if (T == 0) continue;  // T = 0: ref_w = last update made (scheduled at or before this search)
          if (cur_sched_ < T) {
            cur_snap_[i] = init_w_;
            continue;
          }
          const uint64_t cut = cur_sched_ - T;
          auto it = std::upper_bound(hist_.begin(), hist_.end(), cut,
                                     [](uint64_t v, const std::pair<uint64_t, uint32_t> &h) { return v < h.first; });
          cur_snap_[i] = it == hist_.begin() ? init_w_ : std::prev(it)->second;
        }
      }
      cur_group_ = next_g_++;
    }
    const uint32_t ci = bpos_;
    bpos_ = (bpos_ + 1) % nb;
    const uint32_t snap = cur_snap_[ci];
    r->target = cur_target_;
    r->op = vdb::kOpSearch;
    r->seq = next_s_;
    Slot *s = slot(next_s_++, true);
    *s = Slot{};
    s->qrow = cur_qrow_;
    s->ref_w = snap;
    s->fresh = cur_fresh_;
    s->group = cur_group_;
    s->t_idx = uint8_t(ci);
    s->sched_ns = cur_sched_;
    vdb::SearchReq q{snap, k_, 0};
    p->resize(sizeof(q) + dim_ * 4);
    std::memcpy(p->data(), &q, sizeof(q));
    std::memcpy(p->data() + sizeof(q), queries_.rows + uint64_t(cur_qrow_) * dim_, dim_ * 4);
    return true;
  }

  uint32_t burst(uint32_t stream) const override {
    return stream == 1 && !stale_ms_.empty() ? uint32_t(stale_ms_.size()) : 1;
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t status, const uint8_t *p,
                   uint32_t len) override {
    if (r.op != vdb::kOpSearch) {
      vdb::WriteResp wr{};
      const bool ok_len = len == sizeof(wr) || len == sizeof(wr) + sizeof(vdb::OpCoh);
      if (status == frame::kStatusOk && ok_len) std::memcpy(&wr, p, sizeof(wr));
      // OK response for an update carries the insert's w_seq (= 2 * (update index + 1))
      if (status != frame::kStatusOk || !ok_len || wr.w_seq != uint32_t(2 * (r.seq + 1))) {
        write_errors_.fetch_add(1);
        return;
      }
      if (len == sizeof(wr)) {
        no_coh_update_.fetch_add(1);
        return;
      }
      OpLog cl{};
      cl.seq = r.seq, cl.recv_ns = mono_ns(), cl.measured = measured, cl.target = uint8_t(r.target);
      cl.status = status, cl.op = vdb::kOpUpdate;
      std::memcpy(&cl.c, p + sizeof(wr), sizeof(cl.c));
      if (cl.c.version != vdb::kOpCohVersion || cl.c.op != vdb::kOpUpdate) {
        bad_coh_.fetch_add(1);
        return;
      }
      std::lock_guard<std::mutex> g(out_mu_);
      coh_.push_back(cl);
      return;
    }
    const uint64_t t_recv = mono_ns();
    Slot *s = slot(r.seq, false);
    std::vector<uint8_t> rec(sizeof(SearchLog) + size_t(k_) * 12, 0);
    SearchLog lg{};
    lg.seq = r.seq;
    lg.qrow = s->qrow;
    lg.ref_w = s->ref_w;
    lg.measured = measured;
    lg.status = status;
    lg.k = k_;
    OpLog cl{};
    bool have_coh = false;
    if (status == frame::kStatusOk && len >= sizeof(vdb::SearchResp)) {
      vdb::SearchResp sr;
      std::memcpy(&sr, p, sizeof(sr));
      const uint16_t n = std::min<uint16_t>(sr.n, k_);
      if (len >= sizeof(sr) + size_t(sr.n) * 12) {
        lg.n = n;
        std::memcpy(rec.data() + sizeof(lg), p + sizeof(sr), size_t(n) * 8);
        std::memcpy(rec.data() + sizeof(lg) + size_t(k_) * 8, p + sizeof(sr) + size_t(sr.n) * 8, size_t(n) * 4);
      } else {
        bad_responses_.fetch_add(1);
      }
      const size_t co = sizeof(sr) + size_t(sr.n) * 12;
      if ((sr.flags & vdb::kRespCoh) && len >= co + sizeof(vdb::OpCoh)) {
        cl.seq = r.seq, cl.recv_ns = mono_ns(), cl.measured = measured, cl.target = uint8_t(r.target);
        cl.status = status, cl.op = vdb::kOpSearch;
        std::memcpy(&cl.c, p + co, sizeof(cl.c));
        have_coh = cl.c.version == vdb::kOpCohVersion && cl.c.op == vdb::kOpSearch;
        if (!have_coh) bad_coh_.fetch_add(1);
      } else if (sr.flags & vdb::kRespCoh) {
        bad_coh_.fetch_add(1);  // a block of another version / size (e.g. v1 SearchCoh)
      } else {
        no_coh_.fetch_add(1);
      }
      lg.s_used = sr.s_used, lg.wait_us = sr.wait_us, lg.replay_us = sr.replay_us, lg.search_us = sr.search_us;
      lg.lock_us = sr.lock_us, lg.dists = sr.dists, lg.segs = sr.segs;
    }
    std::memcpy(rec.data(), &lg, sizeof(lg));
    std::lock_guard<std::mutex> g(out_mu_);
    out_.insert(out_.end(), rec.begin(), rec.end());
    if (have_coh) coh_.push_back(cl);
    s->flags = uint8_t(1 | (measured ? 2 : 0));  // stale.bin (read at finish under out_mu_)
    s->status = status;
    s->lat_us = t_recv > s->sched_ns ? uint32_t(std::min<uint64_t>((t_recv - s->sched_ns) / 1000, 0xffffffffu)) : 0;
  }

  bool finish(const std::string &dir, std::string *err) override {
    FILE *f = std::fopen((dir + "/searches.bin").c_str(), "wb");
    if (!f) return *err = "cannot write searches.bin", false;
    {
      std::lock_guard<std::mutex> g(out_mu_);
      std::fwrite(out_.data(), 1, out_.size(), f);
    }
    std::fclose(f);
    FILE *cf = std::fopen((dir + "/op-coh.bin").c_str(), "wb");
    if (!cf) return *err = "cannot write op-coh.bin", false;
    {
      std::lock_guard<std::mutex> g(out_mu_);
      std::fwrite(coh_.data(), sizeof(OpLog), coh_.size(), cf);
    }
    std::fclose(cf);
    FILE *t = std::fopen((dir + "/vectordb.txt").c_str(), "w");
    // updates_made / writes_made: this invocation; w_start / next_w: absolute writes-file record indices
    std::fprintf(t, "updates_made=%lu\nwrites_made=%lu\nw_start=%lu\nnext_w=%lu\nlast_w=%u\nsearches_made=%lu\nwrite_errors=%lu\n"
                 "bad_search_responses=%lu\nsearch_record_bytes=%zu\nk=%u\ncoh_records=%zu\ncoh_record_bytes=%zu\n"
                 "ok_without_coh=%lu\nupdates_ok_without_coh=%lu\nbad_coh_version=%lu\n",
                 (unsigned long)((next_w_ - w_start_) / 2), (unsigned long)(next_w_ - w_start_),
                 (unsigned long)w_start_, (unsigned long)next_w_, last_w_, (unsigned long)next_s_,
                 (unsigned long)write_errors_.load(),
                 (unsigned long)bad_responses_.load(), sizeof(SearchLog) + size_t(k_) * 12, k_, coh_.size(),
                 sizeof(OpLog), (unsigned long)no_coh_.load(), (unsigned long)no_coh_update_.load(),
                 (unsigned long)bad_coh_.load());
    if (search_target_ >= 0) std::fprintf(t, "search_target=%ld\n", search_target_);
    if (!stale_ms_.empty()) {  // DESIGN.md §20; lines only with the option (older outputs unchanged)
      std::vector<StaleLog> sl(next_s_);
      uint64_t answered = 0;
      {
        std::lock_guard<std::mutex> g(out_mu_);
        for (uint64_t i = 0; i < next_s_; i++) {
          const Slot *s = slot(i, false);
          StaleLog &x = sl[i];
          x.seq = i, x.sched_ns = s->sched_ns, x.group = s->group, x.t_ms = stale_ms_[s->t_idx];
          x.fresh = s->fresh, x.sent = s->ref_w, x.lat_us = s->lat_us, x.status = s->status, x.flags = s->flags;
          x.t_idx = s->t_idx;
          answered += s->flags & 1;
        }
      }
      FILE *sf = std::fopen((dir + "/stale.bin").c_str(), "wb");
      if (!sf) return std::fclose(t), *err = "cannot write stale.bin", false;
      std::fwrite(sl.data(), sizeof(StaleLog), sl.size(), sf);
      std::fclose(sf);
      std::fprintf(t, "stale_ms=%s\nstale_copies=%zu\nstale_groups=%lu\nstale_records=%zu\nstale_record_bytes=%zu\n"
                   "stale_answered=%lu\n", stale_spec_.c_str(), stale_ms_.size(), (unsigned long)next_g_, sl.size(),
                   sizeof(StaleLog), (unsigned long)answered);
    }
    std::fclose(t);
    if (write_errors_.load()) *err = "write errors " + std::to_string(write_errors_.load());
    return write_errors_.load() == 0;
  }

  std::string describe() const override {
    return "vectordb data=" + data_ + " writes=" + writes_path_ + " (" + std::to_string(writes_.size()) +
           " records, update pairs) k=" + std::to_string(k_) + " seed=" + std::to_string(seed_) + " dim=" + std::to_string(dim_) +
           " w_start=" + std::to_string(w_start_) +
           (stale_ms_.empty() ? "" : " stale_ms=" + stale_spec_ + " (search rate = query groups/s; requests x" +
                                        std::to_string(stale_ms_.size()) + ")") +
           (search_target_ >= 0 ? " search_target=" + std::to_string(search_target_) : "");
  }

 private:
  struct Slot {
    uint32_t qrow = 0, ref_w = 0;  // ref_w = the snapshot sent (E1 ref_w without stale_ms)
    uint32_t fresh = 0, group = 0, lat_us = 0;  // stale_ms bookkeeping (stale.bin)
    uint16_t status = 0;
    uint8_t flags = 0, t_idx = 0;
    uint64_t sched_ns = 0;
  };
  static constexpr uint64_t kChunk = 1u << 16, kMaxChunks = 1u << 13;
  Slot *slot(uint64_t i, bool create) {
    const uint64_t c = i / kChunk;
    if (c >= kMaxChunks) throw std::runtime_error("max_searches beyond slot table");
    Slot *p = chunks_[c].load(std::memory_order_acquire);
    if (!p && create) {
      p = new Slot[kChunk];
      chunks_[c].store(p, std::memory_order_release);
    }
    return &p[i % kChunk];
  }

  uint32_t targets_ = 1, dim_ = 0, last_w_ = 0;
  uint16_t k_ = 10;
  uint64_t seed_ = 0, max_searches_ = 0, next_w_ = 0, next_s_ = 0, w_start_ = 0;
  // stale_ms / search_target (DESIGN.md §20); all used by make() only (the scheduler thread), except stale_ms_ (const
  // after init) and the Slot fields read at finish
  std::string stale_spec_;
  std::vector<uint32_t> stale_ms_;
  uint64_t max_stale_ns_ = 0, cur_sched_ = 0;
  long search_target_ = -1;
  uint32_t init_w_ = 0, bpos_ = 0, cur_qrow_ = 0, cur_target_ = 0, cur_fresh_ = 0, cur_group_ = 0, next_g_ = 0;
  std::vector<uint32_t> cur_snap_;
  std::deque<std::pair<uint64_t, uint32_t>> hist_;  // (scheduled ns, insert w_seq) per update made
  std::mt19937_64 rng_;
  Fbin pool_b_, queries_;
  std::vector<WriteRec> writes_;
  std::string writes_path_, data_;
  std::unique_ptr<std::atomic<Slot *>[]> chunks_;
  std::mutex out_mu_;
  std::vector<uint8_t> out_;
  std::vector<OpLog> coh_;  // under out_mu_ (searches and updates)
  std::atomic<uint64_t> write_errors_{0}, bad_responses_{0}, no_coh_{0}, no_coh_update_{0}, bad_coh_{0};
};
LOADGEN_REGISTER("vectordb", VectorDb);

}  // namespace

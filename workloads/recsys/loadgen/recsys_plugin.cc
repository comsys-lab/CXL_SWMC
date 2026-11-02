// loadgen plugin "recsys" (workloads/recsys/DESIGN.md §8, experiments/loadgen/README.md).
// Streams: "update" (ordered; samples of the update trace in time order, seq 1.., all to the updater target) and
// "query" (MLPerf DLRMv2 server queries: N consecutive samples of the query pool from a random start, N drawn from
// tools/dist_quantile.txt, or fixed with pairs=N; all to the serving target).
// Options: samples=FILE (update trace, samples.h format), queries=FILE (query pool; default samples), quantiles=FILE
//          or pairs=N, update_target=0, query_target=1 (index into --target), query_spread=rr (H3: queries round robin
//          over every target except update_target; exclusive with query_target), seed=N, scores=0|1 (return scores),
//          max_queries=N (default 50M), seq_base=N (default 0: update seqs continue after N; the trace position of
//          seq s is s-1, so measurements against one server lifetime replay the trace on from where the previous one
//          stopped), wrap=0|1 (default 0; 1 = the update trace wraps to its start instead of ending the stream).
// v7 (DESIGN.md §10.6, test-then-train): prequential=1 draws every query from the UPDATE trace ahead of the update
//          position: start uniform in [u, u + N), u = trace position of the next update to send (every sample before
//          u has been sent to node 0, none at or after it), N = query_window_samples, or query_window_s (default 60)
//          x update_rate (samples/s; the harness passes the --fixed update rate). Positions wrap with wrap=1. Scores
//          are always returned; queries= is ignored.
//          Outputs <out>/scores.bin ("RSYSSCR1" 64 B header + count; {u64 trace position, f32 score, u8 label,
//          u8 measured, u8[2]} per scored sample, tools/auc.py format) and <out>/scoreq.bin ("RSYSSCQ1" 64 B header
//          + count; ScoreQuery per query response: query seq, make time CLOCK_MONOTONIC ns = the loadgen's step clock
//          (stats/stepNNN-*.txt mono_ns), first score record, pairs, status, measured), so that tools/v7_metrics.py
//          assigns scores to ramp steps.
// Output: <out>/queries.bin (one QueryLog per query response) and <out>/recsys.txt (counts).
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include <time.h>

#include "../proto.h"
#include "../samples.h"
#include "frame.h"
#include "workload.h"

namespace {

using namespace rsys;

struct __attribute__((packed)) QueryLog {  // one per query response
  uint64_t seq, start;
  uint32_t pairs;
  uint16_t status;
  uint8_t measured, pad;
  uint64_t last_update_made;  // update seq made (scheduled) before this query
  QueryResp r;
};

struct __attribute__((packed)) ScoreRec {  // scores.bin (tools/auc.py REC: pad[0] = measured)
  uint64_t sample;  // absolute trace position (seq - 1 of the update carrying it; not reduced modulo the trace)
  float score;
  uint8_t label, measured, pad[2];
};
static_assert(sizeof(ScoreRec) == 16, "score record");
struct __attribute__((packed)) ScoreQuery {  // scoreq.bin
  uint64_t qseq, t_make_ns, first;  // first = index of the query's first ScoreRec
  uint32_t pairs;
  uint16_t status;
  uint8_t measured, pad;
};
static_assert(sizeof(ScoreQuery) == 32, "score query record");

inline uint64_t mono_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

struct SampleFile {
  const Sample *rows = nullptr;
  uint64_t n = 0;
  std::string source;
  bool open(const std::string &path, std::string *err) {
    int fd = ::open(path.c_str(), O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) return *err = "cannot open " + path, false;
    void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_SHARED, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED) return *err = "cannot map " + path, false;
    SamplesHeader h;
    if (size_t(st.st_size) < sizeof(h)) return *err = path + ": too small", false;
    std::memcpy(&h, m, sizeof(h));
    if (h.magic != kSamplesMagic || h.version != kSamplesVersion || h.record_bytes != sizeof(Sample) ||
        uint64_t(st.st_size) != sizeof(h) + h.count * sizeof(Sample))
      return *err = path + ": not a recsys v" + std::to_string(kSamplesVersion) + " samples file (908 B multi-hot records) or size mismatch", false;
    n = h.count;
    rows = reinterpret_cast<const Sample *>(static_cast<const uint8_t *>(m) + sizeof(h));
    source.assign(h.source, strnlen(h.source, sizeof(h.source)));
    return true;
  }
};

class Recsys : public loadgen::Workload {
 public:
  bool init(const loadgen::Options &o, uint32_t targets, std::string *err) override {
    auto get = [&](const char *k, const std::string &d) {
      auto it = o.find(k);
      return it == o.end() ? d : it->second;
    };
    samples_path_ = get("samples", "");
    queries_path_ = get("queries", samples_path_);
    if (samples_path_.empty()) return *err = "need --opt samples=FILE", false;
    if (!upd_.open(samples_path_, err) || !qry_.open(queries_path_, err)) return false;
    update_target_ = std::stoul(get("update_target", "0"));
    query_target_ = std::stoul(get("query_target", targets > 1 ? "1" : "0"));
    if (update_target_ >= targets || query_target_ >= targets) return *err = "update/query target out of range", false;
    // query_spread=rr (H3, N serving nodes): query k goes to the k-th target (round robin) of the targets other than
    // update_target, so the offered query rate is split evenly over the serving nodes; the (pairs, start) draws are
    // unchanged (same query sequence as query_target). Default "" = every query to query_target (unchanged).
    const std::string spread = get("query_spread", "");
    if (!spread.empty()) {
      if (spread != "rr") return *err = "query_spread must be rr", false;
      if (o.count("query_target")) return *err = "query_spread and query_target are exclusive", false;
      for (uint32_t t = 0; t < targets; t++)
        if (t != update_target_) serve_targets_.push_back(t);
      if (serve_targets_.empty()) return *err = "query_spread=rr needs a target other than update_target", false;
    }
    seed_ = std::stoull(get("seed", "20261016"));
    scores_ = get("scores", "0") == "1";
    max_queries_ = std::stoull(get("max_queries", "50000000"));
    seq_base_ = std::stoull(get("seq_base", "0"));
    wrap_ = get("wrap", "0") == "1";
    if (upd_.n == 0) return *err = "empty update trace", false;
    if (!wrap_ && seq_base_ >= upd_.n) return *err = "seq_base beyond the update trace (use wrap=1)", false;
    next_u_ = seq_base_;
    const std::string pairs = get("pairs", ""), qf = get("quantiles", "");
    if (!pairs.empty()) quant_.push_back(std::stoul(pairs));
    else if (!qf.empty()) {
      std::ifstream f(qf);
      std::string tok;
      while (std::getline(f, tok, ',')) {
        tok.erase(0, tok.find_first_not_of(" \t\r\n"));
        if (!tok.empty()) quant_.push_back(std::stoul(tok));
      }
      quantiles_path_ = qf;
    }
    if (quant_.empty()) return *err = "need --opt quantiles=dist_quantile.txt or --opt pairs=N", false;
    preq_ = get("prequential", "0") == "1";
    if (preq_) {
      scores_ = true;
      window_s_ = std::stod(get("query_window_s", "60"));
      const std::string ws = get("query_window_samples", ""), ur = get("update_rate", "");
      if (!ws.empty()) window_ = std::stoull(ws);
      else if (!ur.empty()) window_ = uint64_t(window_s_ * std::stod(ur) + 0.5);
      else return *err = "prequential=1 needs query_window_samples=N or update_rate=R (window = query_window_s x R)", false;
      if (window_ == 0) return *err = "query window must be >= 1 sample", false;
      qry_ = upd_;  // queries come from the update trace
      queries_path_ = samples_path_ + " (prequential)";
      scorelog_.reserve(1 << 22);
    }
    for (uint32_t q : quant_)
      if (q == 0 || q > qry_.n || sizeof(QueryReq) + uint64_t(q) * sizeof(Sample) > frame::kMaxFrame)
        return *err = "query size " + std::to_string(q) + " invalid for the query pool", false;
    rng_.seed(seed_);
    logs_.reserve(1 << 20);
    return true;
  }

  std::vector<loadgen::StreamSpec> streams() const override { return {{"update", true}, {"query", false}}; }

  bool make(uint32_t stream, loadgen::Request *r, std::vector<uint8_t> *p) override {
    if (stream == 0) {
      if (!wrap_ && next_u_ >= upd_.n) return false;
      r->target = update_target_;
      r->op = kOpUpdate;
      r->seq = ++next_u_;  // seq seq_base+1.. (trace position seq-1, modulo the trace length with wrap=1)
      UpdateReq q{next_u_};
      p->resize(sizeof(q) + sizeof(Sample));
      std::memcpy(p->data(), &q, sizeof(q));
      std::memcpy(p->data() + sizeof(q), &upd_.rows[(next_u_ - 1) % upd_.n], sizeof(Sample));
      return true;
    }
    if (next_q_ >= max_queries_) return false;
    const uint32_t pairs = quant_[std::uniform_int_distribution<size_t>(0, quant_.size() - 1)(rng_)];
    uint64_t start;
    if (preq_) {  // test-then-train: [u, u + W), u = next update's trace position (everything before it was sent)
      start = next_u_ + std::uniform_int_distribution<uint64_t>(0, window_ - 1)(rng_);
      if (!wrap_ && start + pairs > upd_.n) {  // end of an unwrapped trace: shift back (counted; may include trained)
        start = upd_.n - pairs;
        query_clamped_++;
      }
    } else {
      start = std::uniform_int_distribution<uint64_t>(0, qry_.n - pairs)(rng_);
    }
    r->target = serve_targets_.empty() ? query_target_ : serve_targets_[next_q_ % serve_targets_.size()];
    r->op = kOpQuery;
    r->seq = next_q_++;
    {
      std::lock_guard<std::mutex> g(mu_);
      meta_.push_back({start, pairs, next_u_, preq_ ? mono_ns() : 0});
    }
    QueryReq q{pairs, scores_ ? kQueryReturnScores : 0u};
    p->resize(sizeof(q) + uint64_t(pairs) * sizeof(Sample));
    std::memcpy(p->data(), &q, sizeof(q));
    if (preq_) {
      for (uint32_t i = 0; i < pairs; i++)
        std::memcpy(p->data() + sizeof(q) + uint64_t(i) * sizeof(Sample), &upd_.rows[(start + i) % upd_.n], sizeof(Sample));
    } else {
      std::memcpy(p->data() + sizeof(q), &qry_.rows[start], uint64_t(pairs) * sizeof(Sample));
    }
    return true;
  }

  void on_response(const loadgen::Request &r, bool measured, uint16_t status, const uint8_t *p, uint32_t len) override {
    if (r.op == kOpUpdate) {
      if (status != frame::kStatusOk || len < sizeof(UpdateResp)) {
        update_errors_++;
        return;
      }
      UpdateResp u;
      std::memcpy(&u, p, sizeof(u));
      uint64_t cur = published_.load();
      while (u.published_seq > cur && !published_.compare_exchange_weak(cur, u.published_seq)) {
      }
      return;
    }
    QueryLog lg{};
    lg.seq = r.seq;
    lg.status = status;
    lg.measured = measured;
    uint64_t t_make = 0;
    {
      std::lock_guard<std::mutex> g(mu_);
      const Meta &m = meta_[r.seq];
      lg.start = m.start, lg.pairs = m.pairs, lg.last_update_made = m.last_update;
      t_make = m.t_make;
    }
    bool ok = false;
    if (status == frame::kStatusOk && len >= sizeof(QueryResp)) {
      std::memcpy(&lg.r, p, sizeof(QueryResp));
      if (lg.r.pairs != lg.pairs || lg.r.misses) bad_responses_++;
      else ok = true;
    } else {
      query_errors_++;
    }
    std::lock_guard<std::mutex> g(mu_);
    logs_.push_back(lg);
    if (!preq_) return;
    ScoreQuery sq{r.seq, t_make, uint64_t(scorelog_.size()), 0, status, uint8_t(measured), 0};
    if (ok && len >= sizeof(QueryResp) + uint64_t(lg.pairs) * 4) {
      sq.pairs = lg.pairs;
      const float *sc = reinterpret_cast<const float *>(p + sizeof(QueryResp));
      for (uint32_t i = 0; i < lg.pairs; i++) {
        const uint64_t pos = lg.start + i;
        float s;
        std::memcpy(&s, sc + i, 4);
        scorelog_.push_back(ScoreRec{pos, s, upd_.rows[pos % upd_.n].label, uint8_t(measured), {0, 0}});
      }
    } else if (ok) {
      bad_responses_++;  // scores requested but missing
    }
    scoreq_.push_back(sq);
  }

  bool finish(const std::string &dir, std::string *err) override {
    FILE *f = std::fopen((dir + "/queries.bin").c_str(), "wb");
    if (!f) return *err = "cannot write queries.bin", false;
    uint64_t pairs = 0, lookups = 0, retries = 0, false_retries = 0, misses = 0;
    {
      std::lock_guard<std::mutex> g(mu_);
      std::fwrite(logs_.data(), sizeof(QueryLog), logs_.size(), f);
      for (auto &l : logs_)
        pairs += l.r.pairs, lookups += l.r.lookups, retries += l.r.seq_retries, false_retries += l.r.false_retries,
            misses += l.r.misses;
    }
    std::fclose(f);
    FILE *t = std::fopen((dir + "/recsys.txt").c_str(), "w");
    std::fprintf(t,
                 "updates_made=%lu\nqueries_made=%lu\nupdate_errors=%lu\nquery_errors=%lu\nbad_query_responses=%lu\n"
                 "max_published_seq=%lu\nquery_pairs=%lu\nquery_lookups=%lu\nquery_seq_retries=%lu\nquery_false_retries=%lu\nquery_misses=%lu\n"
                 "query_log_record_bytes=%zu\nseq_base=%lu\nlast_update_seq=%lu\ntrace_samples=%lu\ntrace_wraps=%lu\n",
                 (unsigned long)(next_u_ - seq_base_), (unsigned long)next_q_, (unsigned long)update_errors_.load(),
                 (unsigned long)query_errors_.load(), (unsigned long)bad_responses_.load(), (unsigned long)published_.load(),
                 (unsigned long)pairs, (unsigned long)lookups, (unsigned long)retries, (unsigned long)false_retries,
                 (unsigned long)misses,
                 sizeof(QueryLog), (unsigned long)seq_base_, (unsigned long)next_u_, (unsigned long)upd_.n,
                 (unsigned long)(next_u_ ? (next_u_ - 1) / upd_.n : 0));
    if (preq_) {
      std::fprintf(t, "prequential=1\nquery_window_s=%g\nquery_window_samples=%lu\nquery_clamped=%lu\nscores_logged=%zu\n"
                      "score_queries=%zu\n", window_s_, (unsigned long)window_, (unsigned long)query_clamped_,
                   scorelog_.size(), scoreq_.size());
      auto wr = [&](const char *name, const char *magic, const void *d, size_t rec, size_t n) {
        FILE *o = std::fopen((dir + "/" + name).c_str(), "wb");
        if (!o) return false;
        char h[64] = {};
        std::memcpy(h, magic, 8);
        const uint64_t c = n;
        std::memcpy(h + 8, &c, 8);
        std::fwrite(h, 1, 64, o);
        if (n) std::fwrite(d, rec, n, o);
        return std::fclose(o) == 0;
      };
      std::lock_guard<std::mutex> g(mu_);
      if (!wr("scores.bin", "RSYSSCR1", scorelog_.data(), sizeof(ScoreRec), scorelog_.size()) ||
          !wr("scoreq.bin", "RSYSSCQ1", scoreq_.data(), sizeof(ScoreQuery), scoreq_.size())) {
        std::fclose(t);
        return *err = "cannot write scores.bin / scoreq.bin", false;
      }
    }
    std::fclose(t);
    if (update_errors_ || query_errors_ || bad_responses_) {
      *err = "errors: update " + std::to_string(update_errors_.load()) + " query " + std::to_string(query_errors_.load()) +
             " bad " + std::to_string(bad_responses_.load());
      return false;
    }
    return true;
  }

  std::string describe() const override {
    std::ostringstream o;
    o << "recsys samples=" << samples_path_ << " (" << upd_.n << ", " << upd_.source << ") queries=" << queries_path_
      << " (" << qry_.n << ") quantiles=" << (quantiles_path_.empty() ? "fixed" : quantiles_path_) << " sizes=";
    for (size_t i = 0; i < quant_.size(); i++) o << (i ? "," : "") << quant_[i];
    o << " update_target=" << update_target_;
    if (serve_targets_.empty()) o << " query_target=" << query_target_;
    else {
      o << " query_spread=rr query_targets=";
      for (size_t i = 0; i < serve_targets_.size(); i++) o << (i ? "," : "") << serve_targets_[i];
    }
    o << " seed=" << seed_
      << " seq_base=" << seq_base_ << " wrap=" << wrap_;
    if (preq_) o << " prequential=1 query_window_s=" << window_s_ << " query_window_samples=" << window_;
    return o.str();
  }

 private:
  struct Meta {
    uint64_t start;
    uint32_t pairs;
    uint64_t last_update;
    uint64_t t_make;  // prequential: CLOCK_MONOTONIC at make()
  };
  SampleFile upd_, qry_;
  std::string samples_path_, queries_path_, quantiles_path_;
  std::vector<uint32_t> quant_;
  uint32_t update_target_ = 0, query_target_ = 1;
  std::vector<uint32_t> serve_targets_;  // query_spread=rr: query k -> serve_targets_[k % size]
  uint64_t seed_ = 0, max_queries_ = 0, next_u_ = 0, next_q_ = 0, seq_base_ = 0;
  bool scores_ = false, wrap_ = false, preq_ = false;
  double window_s_ = 60;
  uint64_t window_ = 0, query_clamped_ = 0;
  std::vector<ScoreRec> scorelog_;
  std::vector<ScoreQuery> scoreq_;
  std::mt19937_64 rng_;
  std::mutex mu_;
  std::vector<Meta> meta_;
  std::vector<QueryLog> logs_;
  std::atomic<uint64_t> update_errors_{0}, query_errors_{0}, bad_responses_{0}, published_{0};
};
LOADGEN_REGISTER("recsys", Recsys);

}  // namespace

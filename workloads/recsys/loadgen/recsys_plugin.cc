// loadgen plugin "recsys" (workloads/recsys/DESIGN.md §8, experiments/loadgen/README.md).
// Streams: "update" (ordered; samples of the update trace in time order, seq 1.., all to the updater target) and
// "query" (MLPerf DLRMv2 server queries: N consecutive samples of the query pool from a random start, N drawn from
// tools/dist_quantile.txt, or fixed with pairs=N; all to the serving target).
// Options: samples=FILE (update trace, samples.h format), queries=FILE (query pool; default samples), quantiles=FILE
//          or pairs=N, update_target=0, query_target=1 (index into --target), seed=N, scores=0|1 (return scores),
//          max_queries=N (default 50M).
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
    if (h.magic != kSamplesMagic || h.version != 1 || h.record_bytes != sizeof(Sample) ||
        uint64_t(st.st_size) != sizeof(h) + h.count * sizeof(Sample))
      return *err = path + ": not a recsys samples file (or size mismatch)", false;
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
    seed_ = std::stoull(get("seed", "20261016"));
    scores_ = get("scores", "0") == "1";
    max_queries_ = std::stoull(get("max_queries", "50000000"));
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
      if (next_u_ >= upd_.n) return false;
      r->target = update_target_;
      r->op = kOpUpdate;
      r->seq = ++next_u_;  // seq 1..
      UpdateReq q{next_u_};
      p->resize(sizeof(q) + sizeof(Sample));
      std::memcpy(p->data(), &q, sizeof(q));
      std::memcpy(p->data() + sizeof(q), &upd_.rows[next_u_ - 1], sizeof(Sample));
      return true;
    }
    if (next_q_ >= max_queries_) return false;
    const uint32_t pairs = quant_[std::uniform_int_distribution<size_t>(0, quant_.size() - 1)(rng_)];
    const uint64_t start = std::uniform_int_distribution<uint64_t>(0, qry_.n - pairs)(rng_);
    r->target = query_target_;
    r->op = kOpQuery;
    r->seq = next_q_++;
    {
      std::lock_guard<std::mutex> g(mu_);
      meta_.push_back({start, pairs, next_u_});
    }
    QueryReq q{pairs, scores_ ? kQueryReturnScores : 0u};
    p->resize(sizeof(q) + uint64_t(pairs) * sizeof(Sample));
    std::memcpy(p->data(), &q, sizeof(q));
    std::memcpy(p->data() + sizeof(q), &qry_.rows[start], uint64_t(pairs) * sizeof(Sample));
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
    {
      std::lock_guard<std::mutex> g(mu_);
      const Meta &m = meta_[r.seq];
      lg.start = m.start, lg.pairs = m.pairs, lg.last_update_made = m.last_update;
    }
    if (status == frame::kStatusOk && len >= sizeof(QueryResp)) {
      std::memcpy(&lg.r, p, sizeof(QueryResp));
      if (lg.r.pairs != lg.pairs || lg.r.misses) bad_responses_++;
    } else {
      query_errors_++;
    }
    std::lock_guard<std::mutex> g(mu_);
    logs_.push_back(lg);
  }

  bool finish(const std::string &dir, std::string *err) override {
    FILE *f = std::fopen((dir + "/queries.bin").c_str(), "wb");
    if (!f) return *err = "cannot write queries.bin", false;
    uint64_t pairs = 0, lookups = 0, retries = 0, misses = 0;
    {
      std::lock_guard<std::mutex> g(mu_);
      std::fwrite(logs_.data(), sizeof(QueryLog), logs_.size(), f);
      for (auto &l : logs_) pairs += l.r.pairs, lookups += l.r.lookups, retries += l.r.seq_retries, misses += l.r.misses;
    }
    std::fclose(f);
    FILE *t = std::fopen((dir + "/recsys.txt").c_str(), "w");
    std::fprintf(t,
                 "updates_made=%lu\nqueries_made=%lu\nupdate_errors=%lu\nquery_errors=%lu\nbad_query_responses=%lu\n"
                 "max_published_seq=%lu\nquery_pairs=%lu\nquery_lookups=%lu\nquery_seq_retries=%lu\nquery_misses=%lu\n"
                 "query_log_record_bytes=%zu\n",
                 (unsigned long)next_u_, (unsigned long)next_q_, (unsigned long)update_errors_.load(),
                 (unsigned long)query_errors_.load(), (unsigned long)bad_responses_.load(), (unsigned long)published_.load(),
                 (unsigned long)pairs, (unsigned long)lookups, (unsigned long)retries, (unsigned long)misses,
                 sizeof(QueryLog));
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
    o << " update_target=" << update_target_ << " query_target=" << query_target_ << " seed=" << seed_;
    return o.str();
  }

 private:
  struct Meta {
    uint64_t start;
    uint32_t pairs;
    uint64_t last_update;
  };
  SampleFile upd_, qry_;
  std::string samples_path_, queries_path_, quantiles_path_;
  std::vector<uint32_t> quant_;
  uint32_t update_target_ = 0, query_target_ = 1;
  uint64_t seed_ = 0, max_queries_ = 0, next_u_ = 0, next_q_ = 0;
  bool scores_ = false;
  std::mt19937_64 rng_;
  std::mutex mu_;
  std::vector<Meta> meta_;
  std::vector<QueryLog> logs_;
  std::atomic<uint64_t> update_errors_{0}, query_errors_{0}, bad_responses_{0}, published_{0};
};
LOADGEN_REGISTER("recsys", Recsys);

}  // namespace

// Open-loop load generator with a max-throughput-under-SLO search (experiments/loadgen/README.md).
// Workloads plug in through workload.h; every server speaks frame.h.
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "frame.h"
#include "workload.h"

namespace loadgen {

std::map<std::string, Factory> &registry() {
  static std::map<std::string, Factory> r;
  return r;
}

namespace {

uint64_t now_ns() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

[[noreturn]] void die(const std::string &m) {
  std::fprintf(stderr, "loadgen: %s\n", m.c_str());
  std::exit(2);
}

std::vector<std::string> split(const std::string &s, char sep) {
  std::vector<std::string> out;
  std::string cur;
  std::istringstream in(s);
  while (std::getline(in, cur, sep))
    if (!cur.empty()) out.push_back(cur);
  return out;
}

// ---------------------------------------------------------------- configuration
struct Config {
  std::string workload, out;
  std::vector<std::string> targets;  // host:port
  Options opts;
  uint32_t conns = 4;                    // per target; ordered streams use connection 0
  std::string mode = "slo";              // slo | fixed
  std::map<std::string, double> mix;     // scaled streams: weight (default every non-fixed stream 1)
  std::map<std::string, double> fixed;   // streams at a fixed rate (req/s), not scaled
  std::string slo_stream;
  double slo_pct = 99, slo_ms = 0;
  std::string x_stream;                  // x axis: a stream name or "total" (default: slo stream)
  std::vector<double> rates;             // fixed mode: total scaled rate per step
  double start = 0, factor = 1.5, precision = 0.05;
  uint32_t max_steps = 20;
  double warmup_s = 10, warmup_rate = 0;  // run-start warmup (rate 0 = first step's rate)
  double step_warmup_s = 3, step_measure_s = 15, drain_s = 5;
  double confirm_s = 30;
  uint32_t confirm_reps = 3;
  std::vector<double> overload = {1.05, 1.1, 1.2};  // SLO mode: extra points at first-fail x f (past the knee)
  double tol = 0.05;            // achieved >= (1 - tol) * offered
  double max_err = 0.001;       // errors + timeouts / measured
  double abort_queue_s = 2.0;   // abort a step when outstanding > max(1000, rate * this)
  double lag_limit_us = 500;    // a passing step with send-lag p99 above this is flagged (loadgen-bound)
  std::string arrival = "poisson";
  uint64_t seed = 20261015;
  bool raw = false;
};

void usage() {
  std::fprintf(stderr,
               "usage: loadgen --workload NAME --target host:port[,host:port...] --out DIR [options]\n"
               "  --opt k=v               workload option (repeatable)\n"
               "  --conns N               connections per target (default 4)\n"
               "  --mode slo|fixed        max throughput under SLO (default) or a fixed rate list\n"
               "  --mix s=w,...           weights of the scaled streams (default: every non-fixed stream 1)\n"
               "  --fixed s=r,...         streams at a fixed rate (req/s), not scaled\n"
               "  --slo s:pct:ms          SLO on stream s, e.g. search:99:20 (required for --mode slo)\n"
               "  --x-stream s|total      x axis (default: SLO stream)\n"
               "  --rates r1,r2,...       fixed mode: total scaled rate per step\n"
               "  --start R --factor F --precision P --max-steps N   SLO search (defaults -, 1.5, 0.05, 20)\n"
               "  --warmup-s S --warmup-rate R          run-start warmup (default 10 s at the first rate)\n"
               "  --step-warmup-s S --step-measure-s S --drain-s S  (defaults 3, 15, 5)\n"
               "  --confirm-s S --confirm-reps N        SLO mode: repeats at the found rate (30 s x 3)\n"
               "  --overload f1,f2,...|none             SLO mode: points at first-fail rate x f, measured in full\n"
               "                                        (no early SLO abort) for the curve past the knee (1.05,1.1,1.2)\n"
               "  --tol T --max-err E --abort-queue-s S --lag-limit-us U\n"
               "  --arrival poisson|uniform --seed N --raw\n"
               "workloads:");
  for (auto &kv : registry()) std::fprintf(stderr, " %s", kv.first.c_str());
  std::fprintf(stderr, "\n");
  std::exit(2);
}

std::map<std::string, double> parse_kv(const std::string &s) {
  std::map<std::string, double> m;
  for (auto &p : split(s, ',')) {
    auto eq = p.find('=');
    if (eq == std::string::npos) die("bad k=v list: " + s);
    m[p.substr(0, eq)] = std::atof(p.substr(eq + 1).c_str());
  }
  return m;
}

Config parse(int argc, char **argv) {
  Config c;
  auto need = [&](int &i) -> std::string {
    if (i + 1 >= argc) usage();
    return argv[++i];
  };
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--workload") c.workload = need(i);
    else if (a == "--target") for (auto &t : split(need(i), ',')) c.targets.push_back(t);
    else if (a == "--out") c.out = need(i);
    else if (a == "--opt") {
      std::string kv = need(i);
      auto eq = kv.find('=');
      if (eq == std::string::npos) die("--opt needs k=v");
      c.opts[kv.substr(0, eq)] = kv.substr(eq + 1);
    } else if (a == "--conns") c.conns = std::stoul(need(i));
    else if (a == "--mode") c.mode = need(i);
    else if (a == "--mix") c.mix = parse_kv(need(i));
    else if (a == "--fixed") c.fixed = parse_kv(need(i));
    else if (a == "--slo") {
      auto p = split(need(i), ':');
      if (p.size() != 3) die("--slo s:pct:ms");
      c.slo_stream = p[0], c.slo_pct = std::atof(p[1].c_str()), c.slo_ms = std::atof(p[2].c_str());
    } else if (a == "--x-stream") c.x_stream = need(i);
    else if (a == "--rates") for (auto &r : split(need(i), ',')) c.rates.push_back(std::atof(r.c_str()));
    else if (a == "--start") c.start = std::atof(need(i).c_str());
    else if (a == "--factor") c.factor = std::atof(need(i).c_str());
    else if (a == "--precision") c.precision = std::atof(need(i).c_str());
    else if (a == "--max-steps") c.max_steps = std::stoul(need(i));
    else if (a == "--warmup-s") c.warmup_s = std::atof(need(i).c_str());
    else if (a == "--warmup-rate") c.warmup_rate = std::atof(need(i).c_str());
    else if (a == "--step-warmup-s") c.step_warmup_s = std::atof(need(i).c_str());
    else if (a == "--step-measure-s") c.step_measure_s = std::atof(need(i).c_str());
    else if (a == "--drain-s") c.drain_s = std::atof(need(i).c_str());
    else if (a == "--confirm-s") c.confirm_s = std::atof(need(i).c_str());
    else if (a == "--confirm-reps") c.confirm_reps = std::stoul(need(i));
    else if (a == "--overload") {
      std::string v = need(i);
      c.overload.clear();
      if (v != "none")
        for (auto &f : split(v, ',')) c.overload.push_back(std::atof(f.c_str()));
    }
    else if (a == "--tol") c.tol = std::atof(need(i).c_str());
    else if (a == "--max-err") c.max_err = std::atof(need(i).c_str());
    else if (a == "--abort-queue-s") c.abort_queue_s = std::atof(need(i).c_str());
    else if (a == "--lag-limit-us") c.lag_limit_us = std::atof(need(i).c_str());
    else if (a == "--arrival") c.arrival = need(i);
    else if (a == "--seed") c.seed = std::stoull(need(i));
    else if (a == "--raw") c.raw = true;
    else usage();
  }
  if (c.workload.empty() || c.targets.empty() || c.out.empty()) usage();
  if (c.mode != "slo" && c.mode != "fixed") die("--mode slo|fixed");
  if (c.mode == "slo" && (c.slo_stream.empty() || c.slo_ms <= 0 || c.start <= 0))
    die("--mode slo needs --slo s:pct:ms and --start R");
  if (c.mode == "fixed" && c.rates.empty()) die("--mode fixed needs --rates");
  if (c.factor <= 1 || c.precision <= 0 || c.conns == 0) die("bad --factor/--precision/--conns");
  if (c.arrival != "poisson" && c.arrival != "uniform") die("--arrival poisson|uniform");
  return c;
}

// ---------------------------------------------------------------- request records (never reused within a run)
struct Rec {
  uint64_t sched, send;
  std::atomic<uint64_t> done;  // 0 = outstanding
  uint64_t seq;
  uint32_t target;
  uint16_t op;
  std::atomic<uint16_t> status;
  uint8_t stream, measured;
};

class Store {
 public:
  static constexpr uint64_t kChunk = 1u << 16, kMaxChunks = 1u << 14;  // up to ~1G requests per run
  Store() : chunks_(new std::atomic<Rec *>[kMaxChunks]) {
    for (uint64_t i = 0; i < kMaxChunks; i++) chunks_[i].store(nullptr);
  }
  Rec *alloc(uint64_t id) {  // scheduler thread only, ids dense from 0
    uint64_t c = id / kChunk;
    if (c >= kMaxChunks) die("too many requests in one run");
    Rec *p = chunks_[c].load(std::memory_order_acquire);
    if (!p) {
      p = new Rec[kChunk];
      chunks_[c].store(p, std::memory_order_release);
    }
    return &p[id % kChunk];
  }
  Rec *get(uint64_t id) const {  // receivers; ids issued already
    uint64_t c = id / kChunk;
    if (c >= kMaxChunks) return nullptr;
    Rec *p = chunks_[c].load(std::memory_order_acquire);
    return p ? &p[id % kChunk] : nullptr;
  }

 private:
  std::unique_ptr<std::atomic<Rec *>[]> chunks_;
};

// ---------------------------------------------------------------- engine
struct StepResult {
  struct S {
    double offered = 0, achieved = 0;
    uint64_t sent = 0, done = 0, errors = 0, timeouts = 0;
    double p50 = 0, p90 = 0, p99 = 0, p999 = 0, pslo = 0, max = 0;  // ms; inf if requests timed out
    double lag_p99_us = 0, lag_max_us = 0;
  };
  std::vector<S> s;
  bool aborted = false, exhausted = false, pass = false, lag_flag = false;
  std::string reason;
};

class Engine {
 public:
  Engine(Config c, std::unique_ptr<Workload> w) : c_(std::move(c)), w_(std::move(w)) {}

  void setup() {
    std::string err;
    if (!w_->init(c_.opts, uint32_t(c_.targets.size()), &err)) die("workload init: " + err);
    specs_ = w_->streams();
    for (size_t i = 0; i < specs_.size(); i++) idx_[specs_[i].name] = i;
    for (auto &kv : c_.mix)
      if (!idx_.count(kv.first)) die("--mix: unknown stream " + kv.first);
    for (auto &kv : c_.fixed)
      if (!idx_.count(kv.first)) die("--fixed: unknown stream " + kv.first);
    if (c_.mix.empty())
      for (auto &sp : specs_)
        if (!c_.fixed.count(sp.name)) c_.mix[sp.name] = 1;
    if (!c_.slo_stream.empty() && !idx_.count(c_.slo_stream)) die("--slo: unknown stream " + c_.slo_stream);
    slo_idx_ = c_.slo_stream.empty() ? 0xff : uint8_t(idx_[c_.slo_stream]);
    slo_ns_ = c_.slo_ms * 1e6;
    if (c_.x_stream.empty()) c_.x_stream = c_.slo_stream.empty() ? "total" : c_.slo_stream;
    if (c_.x_stream != "total" && !idx_.count(c_.x_stream)) die("--x-stream: unknown stream");
    for (auto &t : c_.targets) {
      std::vector<int> fds;
      for (uint32_t k = 0; k < c_.conns; k++) fds.push_back(connect_to(t));
      fds_.push_back(fds);
    }
    rr_.assign(c_.targets.size(), 0);
    for (size_t t = 0; t < fds_.size(); t++)
      for (int fd : fds_[t]) rx_.emplace_back([this, fd] { receive(fd); });
    if (mkdir(c_.out.c_str(), 0755) != 0) die("cannot create --out " + c_.out + " (must not exist)");
    steps_ = std::fopen((c_.out + "/steps.jsonl").c_str(), "w");
    write_manifest();
  }

  int run() {
    double first = c_.mode == "slo" ? c_.start : c_.rates[0];
    if (c_.warmup_s > 0) {
      StepResult w = step("warmup", c_.warmup_rate > 0 ? c_.warmup_rate : first, c_.warmup_s, 0);
      if (w.exhausted) return finish("streams exhausted during warmup");
    }
    if (c_.mode == "fixed") {
      for (double r : c_.rates)
        if (step("fixed", r, c_.step_warmup_s, c_.step_measure_s).exhausted) return finish("streams exhausted");
      return finish("");
    }
    // SLO search: ramp (x factor, x factor^2 while far below the SLO) until a step fails, bisect geometrically
    // to the precision, then confirm the best passing rate with longer repeats.
    double good = 0, bad = 0, r = c_.start;
    uint32_t n = 0;
    for (; n < c_.max_steps; n++) {
      StepResult s = step("ramp", r, c_.step_warmup_s, c_.step_measure_s);
      if (s.exhausted) return finish("streams exhausted during ramp");
      if (!s.pass) { bad = r; break; }
      good = r;
      r *= s.s[idx_[c_.slo_stream]].pslo < c_.slo_ms / 4 ? c_.factor * c_.factor : c_.factor;
    }
    if (good == 0) return finish("the start rate already violates the SLO; lower --start");
    if (bad == 0) return finish("max steps reached without an SLO violation; raise --start or --max-steps");
    for (; n < c_.max_steps && bad / good > 1 + c_.precision; n++) {
      double m = std::sqrt(good * bad);
      StepResult s = step("bisect", m, c_.step_warmup_s, c_.step_measure_s);
      if (s.exhausted) return finish("streams exhausted during bisection");
      (s.pass ? good : bad) = m;
    }
    // confirm with longer repeats; if most repeats fail (the point sits on the knee), step down by the precision
    // and confirm again, at most twice
    for (int round = 0; round < 3; round++) {
      confirm_.clear();
      uint32_t fails = 0;
      for (uint32_t k = 0; k < c_.confirm_reps; k++) {
        StepResult s = step("confirm", good, c_.step_warmup_s, c_.confirm_s);
        if (s.exhausted) return finish("streams exhausted during confirm");
        fails += !s.pass;
        confirm_.push_back(s);
      }
      best_ = good;
      best_bad_ = bad;
      if (2 * fails <= c_.confirm_reps) {
        overload(bad);
        return finish("");
      }
      bad = good;
      good /= 1 + c_.precision;
    }
    overload(best_bad_);
    return finish("confirm failed at three rates; the knee is noisy (longer --confirm-s?)");
  }

 private:
  int connect_to(const std::string &t) {
    auto colon = t.rfind(':');
    if (colon == std::string::npos) die("target must be host:port: " + t);
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(t.substr(0, colon).c_str(), t.substr(colon + 1).c_str(), &hints, &res) != 0 || !res)
      die("cannot resolve " + t);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1, buf = 4 << 20;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof(buf));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) die("cannot connect to " + t);
    freeaddrinfo(res);
    return fd;
  }

  void receive(int fd) {
    std::vector<uint8_t> buf;
    frame::header h;
    while (frame::read_full(fd, &h, sizeof(h))) {
      if (h.len < frame::kHeaderTail || h.len > frame::kMaxFrame) break;
      buf.resize(frame::payload_len(h));
      if (!buf.empty() && !frame::read_full(fd, buf.data(), buf.size())) break;
      uint64_t t = now_ns();
      Rec *r = h.req_id < issued_.load(std::memory_order_acquire) ? store_.get(h.req_id) : nullptr;
      if (!r || r->done.load(std::memory_order_relaxed)) {
        unknown_.fetch_add(1);
        continue;
      }
      r->status.store(h.code, std::memory_order_relaxed);
      Request q{r->stream, r->target, r->op, r->seq};
      w_->on_response(q, r->measured, h.code, buf.data(), uint32_t(buf.size()));
      r->done.store(t, std::memory_order_release);
      if (r->measured && r->stream == slo_idx_ && double(t - r->sched) > slo_ns_) slow_.fetch_add(1);
      outstanding_.fetch_sub(1, std::memory_order_acq_rel);
    }
    if (!stopping_.load()) die("connection lost");
  }

  std::vector<double> stream_rates(double x) const {
    std::vector<double> r(specs_.size(), 0);
    double wsum = 0;
    for (auto &kv : c_.mix) wsum += kv.second;
    for (auto &kv : c_.mix) r[idx_.at(kv.first)] = wsum > 0 ? x * kv.second / wsum : 0;
    for (auto &kv : c_.fixed) r[idx_.at(kv.first)] = kv.second;
    return r;
  }

  // One step: warmup_s at rate x (not measured), then measure_s measured; stop sending; drain.
  // Points past the knee for the throughput/latency curve: measured in full (the early "SLO already exceeded"
  // abort is off; the saturation abort stays). They never change the SLO result.
  void overload(double first_fail) {
    for (double f : c_.overload) {
      StepResult s = step("overload", first_fail * f, c_.step_warmup_s, c_.step_measure_s, false);
      if (s.exhausted) return;
    }
  }

  StepResult step(const char *phase, double x, double warmup_s, double measure_s, bool slo_abort = true) {
    const size_t S = specs_.size();
    std::vector<double> rate = stream_rates(x);
    double total = 0;
    for (double v : rate) total += v;
    slow_.store(0);
    const uint64_t out_base = outstanding_.load();  // leftovers of earlier steps (timed out) do not count here
    const double slo_rate = slo_idx_ != 0xff ? rate[slo_idx_] : 0;
    const double allowed_slow = (1 - c_.slo_pct / 100) * slo_rate * measure_s;
    const uint64_t queue_cap = uint64_t(std::max(1000.0, total * c_.abort_queue_s));

    std::mt19937_64 rng(c_.seed + 7919 * step_no_);
    auto gap = [&](size_t s) -> double {  // ns
      if (rate[s] <= 0) return INFINITY;
      if (c_.arrival == "uniform") return 1e9 / rate[s];
      return std::exponential_distribution<double>(rate[s])(rng) * 1e9;
    };
    const uint64_t t0 = now_ns() + 1000000;  // 1 ms to settle
    const uint64_t ws = t0 + uint64_t(warmup_s * 1e9), we = ws + uint64_t(measure_s * 1e9);
    std::vector<double> next(S);
    for (size_t s = 0; s < S; s++) next[s] = double(t0) + gap(s);
    const uint64_t first_id = issued_.load();
    StepResult res;
    std::vector<uint8_t> payload;
    std::vector<uint8_t> wire;
    uint64_t checks = 0;
    for (;;) {
      size_t s = size_t(std::min_element(next.begin(), next.end()) - next.begin());
      if (!std::isfinite(next[s]) || next[s] >= double(we)) break;
      const uint64_t sched = uint64_t(next[s]);
      for (uint64_t t = now_ns(); t < sched; t = now_ns()) {
        if (sched - t > 200000) {
          timespec ts{0, long(sched - t - 100000)};
          nanosleep(&ts, nullptr);
        }
      }
      if ((++checks & 255) == 0) {
        if (outstanding_.load() > out_base + queue_cap) {
          res.aborted = true;
          res.reason = "outstanding > " + std::to_string(queue_cap) + " (saturated)";
          break;
        }
        if (slo_abort && measure_s > 0 && slo_rate > 0 && sched >= ws && double(slow_.load()) > allowed_slow + 10) {
          res.aborted = true;
          res.reason = "SLO percentile already exceeded";
          break;
        }
      }
      Request q;
      q.stream = uint32_t(s);
      payload.clear();
      if (!w_->make(uint32_t(s), &q, &payload)) {
        res.exhausted = true;
        res.reason = "stream " + specs_[s].name + " exhausted";
        break;
      }
      if (q.target >= fds_.size()) die("workload chose a bad target");
      const uint64_t id = issued_.load(std::memory_order_relaxed);
      Rec *r = store_.alloc(id);
      r->sched = sched;
      r->seq = q.seq;
      r->target = q.target;
      r->op = q.op;
      r->stream = uint8_t(s);
      r->measured = sched >= ws;
      r->status.store(0, std::memory_order_relaxed);
      r->done.store(0, std::memory_order_relaxed);
      outstanding_.fetch_add(1, std::memory_order_acq_rel);
      issued_.store(id + 1, std::memory_order_release);
      wire.resize(sizeof(frame::header) + payload.size());
      frame::fill(reinterpret_cast<frame::header *>(wire.data()), q.op, id, uint32_t(payload.size()));
      if (!payload.empty()) std::memcpy(wire.data() + sizeof(frame::header), payload.data(), payload.size());
      int fd = pick_fd(q.target, specs_[s].ordered);
      r->send = now_ns();
      if (!frame::write_full(fd, wire.data(), wire.size())) die("send failed");
      next[s] += gap(s);
    }
    const uint64_t send_end = now_ns();
    const uint64_t last_id = issued_.load();
    const uint64_t drain_until = send_end + uint64_t(c_.drain_s * 1e9);
    while (outstanding_.load() > out_base && now_ns() < drain_until) usleep(1000);

    // statistics over measured requests
    const uint64_t we_eff = std::min(we, send_end);  // an aborted step's window ends when sending stopped
    const double win = std::max(1e-9, (we_eff - std::min(ws, send_end)) / 1e9);
    res.s.resize(S);
    std::vector<std::vector<double>> lat(S), lag(S);
    for (uint64_t id = first_id; id < last_id; id++) {
      Rec *r = store_.get(id);
      uint64_t d = r->done.load(std::memory_order_acquire);
      auto &st = res.s[r->stream];
      if (d && d >= ws && d < we_eff) st.achieved += 1;  // completions inside the window
      if (!r->measured) continue;
      st.sent++;
      lag[r->stream].push_back((r->send - r->sched) / 1e3);
      if (!d) {
        st.timeouts++;
        lat[r->stream].push_back(INFINITY);
        continue;
      }
      st.done++;
      if (r->status.load() != frame::kStatusOk) st.errors++;
      lat[r->stream].push_back((d - r->sched) / 1e6);
    }
    bool pass = !res.aborted && !res.exhausted;
    std::string why = res.reason;
    for (size_t s = 0; s < S; s++) {
      auto &st = res.s[s];
      st.offered = rate[s];
      st.achieved = measure_s > 0 ? st.achieved / win : 0;
      auto pct = [&](std::vector<double> &v, double p) {
        if (v.empty()) return 0.0;
        double rank = std::ceil(p / 100 * double(v.size()));  // nearest-rank percentile
        size_t k = rank < 1 ? 0 : std::min(v.size() - 1, size_t(rank) - 1);
        std::nth_element(v.begin(), v.begin() + k, v.end());
        return v[k];
      };
      st.p50 = pct(lat[s], 50), st.p90 = pct(lat[s], 90), st.p99 = pct(lat[s], 99), st.p999 = pct(lat[s], 99.9);
      st.pslo = pct(lat[s], c_.slo_pct);
      st.max = lat[s].empty() ? 0 : *std::max_element(lat[s].begin(), lat[s].end());
      st.lag_p99_us = pct(lag[s], 99);
      st.lag_max_us = lag[s].empty() ? 0 : *std::max_element(lag[s].begin(), lag[s].end());
      if (measure_s > 0 && rate[s] > 0) {
        // keeping up = completions in the window vs requests actually sent in it (not the nominal rate: a Poisson
        // count over a short window is itself noisy); tiny counts are not judged
        if (st.sent >= 100 && st.achieved * win < (1 - c_.tol) * double(st.sent) && pass)
          pass = false, why = specs_[s].name + " completions < sent (falling behind)";
        if (st.sent && double(st.errors + st.timeouts) / st.sent > c_.max_err && pass)
          pass = false, why = specs_[s].name + " errors/timeouts";
      }
      if (st.lag_p99_us > c_.lag_limit_us) res.lag_flag = true;
    }
    if (slo_idx_ != 0xff && measure_s > 0 && res.s[slo_idx_].pslo > c_.slo_ms && pass)
      pass = false, why = "p" + fmt(c_.slo_pct) + " " + fmt(res.s[slo_idx_].pslo) + " ms > SLO";
    res.pass = pass && measure_s > 0;
    res.reason = why;
    log_step(phase, x, measure_s, res);
    if (c_.raw && measure_s > 0) dump_raw(first_id, last_id);
    step_no_++;
    return res;
  }

  int pick_fd(uint32_t t, bool ordered) {
    auto &v = fds_[t];
    if (ordered || v.size() == 1) return v[0];
    uint32_t k = 1 + (rr_[t]++ % uint32_t(v.size() - 1));
    return v[k];
  }

  static std::string fmt(double v) {
    if (std::isinf(v)) return "\"inf\"";
    char b[64];
    std::snprintf(b, sizeof(b), "%.6g", v);
    return b;
  }

  double xval(const StepResult &r) const {
    if (c_.x_stream != "total") return r.s[idx_.at(c_.x_stream)].achieved;
    double t = 0;
    for (auto &kv : c_.mix) t += r.s[idx_.at(kv.first)].achieved;
    return t;
  }

  void log_step(const char *phase, double x, double measure_s, const StepResult &r) {
    std::ostringstream o;
    o << "{\"step\":" << step_no_ << ",\"phase\":\"" << phase << "\",\"offered_x\":" << fmt(x)
      << ",\"measure_s\":" << fmt(measure_s) << ",\"x\":" << fmt(xval(r)) << ",\"pass\":" << (r.pass ? "true" : "false")
      << ",\"aborted\":" << (r.aborted ? "true" : "false") << ",\"lag_flag\":" << (r.lag_flag ? "true" : "false")
      << ",\"reason\":\"" << r.reason << "\",\"streams\":{";
    for (size_t s = 0; s < r.s.size(); s++) {
      auto &st = r.s[s];
      o << (s ? "," : "") << "\"" << specs_[s].name << "\":{\"offered\":" << fmt(st.offered)
        << ",\"achieved\":" << fmt(st.achieved) << ",\"sent\":" << st.sent << ",\"done\":" << st.done
        << ",\"errors\":" << st.errors << ",\"timeouts\":" << st.timeouts << ",\"p50_ms\":" << fmt(st.p50)
        << ",\"p90_ms\":" << fmt(st.p90) << ",\"p99_ms\":" << fmt(st.p99) << ",\"p999_ms\":" << fmt(st.p999)
        << ",\"pslo_ms\":" << fmt(st.pslo) << ",\"max_ms\":" << fmt(st.max) << ",\"lag_p99_us\":" << fmt(st.lag_p99_us)
        << ",\"lag_max_us\":" << fmt(st.lag_max_us) << "}";
    }
    o << "}}";
    std::fprintf(steps_, "%s\n", o.str().c_str());
    std::fflush(steps_);
    std::fprintf(stderr, "[%s] step %u x=%.1f -> %s%s%s\n", phase, step_no_, x,
                 measure_s <= 0 ? "done" : r.pass ? "PASS" : "FAIL",
                 r.reason.empty() ? "" : " (", r.reason.empty() ? "" : (r.reason + ")").c_str());
    if (slo_idx_ != 0xff) {
      auto &st = r.s[slo_idx_];
      std::fprintf(stderr, "        %s achieved %.1f/s p50 %.3f p99 %.3f ms, lag p99 %.0f us\n",
                   specs_[slo_idx_].name.c_str(), st.achieved, st.p50, st.p99, st.lag_p99_us);
    }
    steps_log_.push_back({phase, xval(r), r.pass, r.lag_flag});
  }

  void dump_raw(uint64_t a, uint64_t b) {
    std::string p = c_.out + "/raw-step" + std::to_string(step_no_) + ".bin";
    FILE *f = std::fopen(p.c_str(), "wb");
    for (uint64_t id = a; id < b; id++) {
      Rec *r = store_.get(id);
      uint64_t row[4] = {r->sched, r->send, r->done.load(), (uint64_t(r->stream) << 32) | r->status.load() |
                                                                 (uint64_t(r->measured) << 40)};
      std::fwrite(row, sizeof(row), 1, f);
    }
    std::fclose(f);
  }

  void write_manifest() {
    std::ofstream m(c_.out + "/manifest.txt");
    char host[256] = {};
    gethostname(host, sizeof(host) - 1);
    m << "# loadgen run (CXL_SWMC/experiments/loadgen)\nhost=" << host << "\nstart_unix=" << time(nullptr)
      << "\nworkload=" << c_.workload << "\nworkload_describe=" << w_->describe() << "\n";
    for (auto &t : c_.targets) m << "target=" << t << "\n";
    for (auto &kv : c_.opts) m << "opt." << kv.first << "=" << kv.second << "\n";
    m << "mode=" << c_.mode << "\nslo=" << c_.slo_stream << ":" << c_.slo_pct << ":" << c_.slo_ms
      << "\nx_stream=" << c_.x_stream << "\nconns=" << c_.conns << "\narrival=" << c_.arrival
      << "\nseed=" << c_.seed << "\nstart=" << c_.start << " factor=" << c_.factor << " precision=" << c_.precision
      << " max_steps=" << c_.max_steps << "\nwarmup_s=" << c_.warmup_s << " warmup_rate=" << c_.warmup_rate
      << " step_warmup_s=" << c_.step_warmup_s << " step_measure_s=" << c_.step_measure_s
      << " drain_s=" << c_.drain_s << " confirm_s=" << c_.confirm_s << " confirm_reps=" << c_.confirm_reps
      << " overload=" << [&] { std::string o; for (double f : c_.overload) o += (o.empty() ? "" : ",") + fmt(f); return o.empty() ? std::string("none") : o; }()
      << "\ntol=" << c_.tol << " max_err=" << c_.max_err << " abort_queue_s=" << c_.abort_queue_s
      << " lag_limit_us=" << c_.lag_limit_us << "\n";
    for (auto &kv : c_.mix) m << "mix." << kv.first << "=" << kv.second << "\n";
    for (auto &kv : c_.fixed) m << "fixed." << kv.first << "=" << kv.second << "\n";
  }

  int finish(const std::string &note) {
    std::string err;
    bool ok = w_->finish(c_.out, &err);
    std::ofstream s(c_.out + "/summary.json");
    s << "{\"mode\":\"" << c_.mode << "\",\"note\":\"" << note << "\",\"steps\":" << step_no_
      << ",\"unknown_responses\":" << unknown_.load();
    if (c_.mode == "slo" && best_ > 0) {
      double sx = 0, sxx = 0, sp = 0, spp = 0;
      uint32_t n = 0, fails = 0;
      for (auto &r : confirm_) {
        double xv = xval(r), pv = r.s[slo_idx_].pslo;
        sx += xv, sxx += xv * xv, sp += pv, spp += pv * pv, n++;
        if (!r.pass) fails++;
      }
      auto sd = [&](double a, double aa) { return n > 1 ? std::sqrt(std::max(0.0, (aa - a * a / n) / (n - 1))) : 0; };
      s << ",\"slo\":{\"stream\":\"" << c_.slo_stream << "\",\"pct\":" << fmt(c_.slo_pct) << ",\"ms\":" << fmt(c_.slo_ms)
        << "},\"max_offered_x_pass\":" << fmt(best_) << ",\"min_offered_x_fail\":" << fmt(best_bad_)
        << ",\"confirm\":{\"reps\":" << n << ",\"fails\":" << fails << ",\"x_mean\":" << fmt(n ? sx / n : 0)
        << ",\"x_sd\":" << fmt(sd(sx, sxx)) << ",\"pslo_mean_ms\":" << fmt(n ? sp / n : 0)
        << ",\"pslo_sd_ms\":" << fmt(sd(sp, spp)) << "}";
    }
    uint32_t lag_pass = 0;
    for (auto &st : steps_log_) lag_pass += st.pass && st.lag;
    s << ",\"passing_steps_with_send_lag\":" << lag_pass << ",\"workload_finish\":\"" << (ok ? "ok" : err) << "\"}\n";
    s.close();
    std::fclose(steps_);
    std::fprintf(stderr, "loadgen: done%s%s -> %s\n", note.empty() ? "" : ": ", note.c_str(), c_.out.c_str());
    stopping_.store(true);
    for (auto &v : fds_)
      for (int fd : v) shutdown(fd, SHUT_RDWR);
    for (auto &t : rx_) t.join();
    return note.empty() && ok ? 0 : 1;
  }

  struct StepLog {
    std::string phase;
    double x;
    bool pass, lag;
  };

  Config c_;
  std::unique_ptr<Workload> w_;
  std::vector<StreamSpec> specs_;
  std::map<std::string, size_t> idx_;
  std::vector<std::vector<int>> fds_;
  std::vector<uint32_t> rr_;
  std::vector<std::thread> rx_;
  Store store_;
  std::atomic<uint64_t> issued_{0}, outstanding_{0}, unknown_{0}, slow_{0};
  std::atomic<bool> stopping_{false};
  uint8_t slo_idx_ = 0xff;  // fixed in setup() before receivers start
  double slo_ns_ = 0;
  uint32_t step_no_ = 0;
  FILE *steps_ = nullptr;
  std::vector<StepLog> steps_log_;
  std::vector<StepResult> confirm_;
  double best_ = 0, best_bad_ = 0;
};

}  // namespace
}  // namespace loadgen

int main(int argc, char **argv) {
  using namespace loadgen;
  Config c = parse(argc, argv);
  auto it = registry().find(c.workload);
  if (it == registry().end()) usage();
  Engine e(c, it->second());
  e.setup();
  return e.run();
}

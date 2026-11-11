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
#include <ctime>
#include <fstream>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "drain.h"
#include "frame.h"
#include "slo_search.h"
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
  double drain_full_s = 0;  // > 0: full drain + clean-start rule (drain.h, user 2026-11-12); 0 = the old drain
  double drain_fail_s = 0;  // > 0 (with drain_full_s): a step whose full drain took > this fails (non-latency)
  double confirm_s = 30;
  double confirm_warmup_s = -1;  // warmup before each confirm repeat; < 0 = step_warmup_s (main 2026-10-21)
  uint32_t confirm_reps = 3;
  double confirm_precision = 0.01;  // after a failed confirm: confirm-length bisection to hi/lo <= 1 + this (2026-10-18)
  uint32_t max_confirm_probes = 6;  // confirms after the first one (>= 2: the legacy "three rates" note stays true)
  // while no rate is confirmed: next candidate = max(nearest ramp/bisect pass below the last failed confirm f,
  // f / (1 + this)) (H1 v0.6.5, 2026-10-18; v0.6.3 jumped to the next lower ramp pass however far below)
  double confirm_step_down = 0.05;
  // confirm rule (slo_search.h judge_probe, 2026-10-21); defaults = the rule since 2026-10-18
  std::string confirm_rule = "majority";  // majority | pooled
  bool confirm_full = false;              // confirm repeats never stop early (no SLO early abort)
  uint64_t confirm_min_samples = 0;       // merged SLO-stream count below this -> "insufficient samples" (0 = off)
  std::vector<double> overload = {1.05, 1.1, 1.2};  // SLO mode: extra points at first-fail x f (past the knee)
  std::vector<double> fill = {0.7, 0.8, 0.9};       // SLO mode: extra points at the result x f (bend before the knee)
  // past-the-knee rule (de-stijl-motivation-isca27 §3, user 2026-10-21 23:5x), opt-in; defaults = the old behaviour
  std::string overload_base = "first-fail";  // overload points at first-fail x f (default) or at the result x f
  std::vector<double> start_fail;            // start rate fails: extra overload points at start x f (default none)
  // RecSys methodology (2026-10-19), opt-in; 0 = the old behaviour (every existing caller)
  uint32_t min_step_queries = 0;  // every measured step lasts at least N / (SLO stream rate) s
  uint32_t ramp_knee = 0;         // KneeRamp K (slo_search.h): low-rate failures do not end the ramp
  double ramp_knee_rise = 1.2;    // KneeRamp: a failed step counts toward K if its percentile rose >= this x
  double ramp_knee_floor = 1.5;   // KneeRamp: a rising-percentile stop needs the step's percentile > this x SLO
  uint32_t knee_bisect_steps = 12;  // --ramp-knee: bisect steps after the ramp (own budget, not --max-steps)
  double tol = 0.05;            // achieved >= (1 - tol) * offered
  double max_err = 0.001;       // errors + timeouts / measured
  double abort_queue_s = 2.0;   // abort a step when outstanding > max(1000, rate * this)
  double lag_limit_us = 500;    // a passing step with send-lag p99 above this is flagged (loadgen-bound)
  std::string arrival = "poisson";
  uint64_t seed = 20261015;
  bool raw = false;
  uint16_t stats_op = 0;  // 0 = off; else op code of the server's text stats request (snapshots per measured step)
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
               "  --drain-full-s S                      after each step wait until no request of any stream is\n"
               "                                        outstanding (at most S s, replaces --drain-s); a step that\n"
               "                                        starts with requests outstanding is not judged and is run\n"
               "                                        once more (default 0 = off)\n"
               "  --drain-fail-s D                      with --drain-full-s: a step (any phase, also each confirm\n"
               "                                        repeat) whose drain took > D s fails as \"drain > D s (backlog)\",\n"
               "                                        a non-latency failure (default 0 = off)\n"
               "  --confirm-s S --confirm-reps N        SLO mode: repeats at the found rate (30 s x 3)\n"
               "  --confirm-precision P --max-confirm-probes N   SLO mode: after a failed confirm, bisect with full\n"
               "                                        confirms between the highest confirmed pass and the lowest\n"
               "                                        confirm fail to hi/lo <= 1 + P, at most N confirms (0.01, 6)\n"
               "  --confirm-step-down S                 SLO mode: until a confirm passes, the next candidate below a\n"
               "                                        failed confirm f is max(nearest ramp/bisect pass below f,\n"
               "                                        f / (1 + S)); S in [0.02, 0.05] (0.05)\n"
               "  --confirm-rule majority|pooled        SLO mode: a confirm passes if fails x 2 <= reps (majority, default)\n"
               "                                        or if the SLO percentile of the merged latencies of its repeats\n"
               "                                        <= SLO and no repeat failed for a non-latency reason (pooled);\n"
               "                                        both verdicts are recorded either way (summary.json, confirm_probes.csv)\n"
               "  --confirm-full                        confirm repeats run the full --confirm-s (no SLO early abort)\n"
               "  --confirm-warmup-s S                  SLO mode: unmeasured warmup before each confirm repeat\n"
               "                                        (default: --step-warmup-s)\n"
               "  --confirm-min-samples K               a confirm with < K merged SLO-stream requests is \"insufficient\n"
               "                                        samples\" (not a pass) under both rules (default 0 = off)\n"
               "  --overload f1,f2,...|none             SLO mode: points at first-fail rate x f, measured in full\n"
               "                                        (no early SLO abort) for the curve past the knee (1.05,1.1,1.2)\n"
               "  --overload-base first-fail|result     SLO mode: base rate of the --overload points (first-fail)\n"
               "  --start-fail-steps f1,f2,...|none     SLO mode: when the start rate already violates the SLO, overload\n"
               "                                        points at start x f, measured in full, before the search ends\n"
               "                                        (same note; default none; not with --ramp-knee)\n"
               "  --fill f1,f2,...|none                 SLO mode: points at the result x f for the bend (0.7,0.8,0.9)\n"
               "  --min-step-queries N                  every measured step lasts >= N / SLO-stream rate s (default 0 = off)\n"
               "  --ramp-knee K                         SLO mode: a failed ramp step does not end the ramp; it ends at K\n"
               "                                        consecutive fails after a pass with a non-falling SLO percentile,\n"
               "                                        or a saturated fail; no SLO early abort in ramp steps (default 0 = off)\n"
               "  --ramp-knee-rise X                    a failed step counts toward K if its percentile >= X x the previous\n"
               "                                        step's (1.2); bisect then has its own budget of 12 steps\n"
               "  --ramp-knee-floor F                   ... and the stopping step's percentile > F x SLO (1.5)\n"
               "  --tol T --max-err E --abort-queue-s S --lag-limit-us U\n"
               "  --arrival poisson|uniform --seed N --raw\n"
               "  --stats-op N            server stats snapshot (request op N, text reply) per target at each measured\n"
               "                          step's window start and right after sending stops: <out>/stats/ (default off)\n"
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
      if (!(c.slo_pct > 0 && c.slo_pct < 100)) die("--slo: pct must be in (0, 100), e.g. 99 or 95");
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
    else if (a == "--drain-full-s") c.drain_full_s = std::atof(need(i).c_str());
    else if (a == "--drain-fail-s") c.drain_fail_s = std::atof(need(i).c_str());
    else if (a == "--confirm-s") c.confirm_s = std::atof(need(i).c_str());
    else if (a == "--confirm-warmup-s") c.confirm_warmup_s = std::atof(need(i).c_str());
    else if (a == "--confirm-reps") c.confirm_reps = std::stoul(need(i));
    else if (a == "--confirm-precision") c.confirm_precision = std::atof(need(i).c_str());
    else if (a == "--max-confirm-probes") c.max_confirm_probes = std::stoul(need(i));
    else if (a == "--confirm-step-down") c.confirm_step_down = std::atof(need(i).c_str());
    else if (a == "--confirm-rule") c.confirm_rule = need(i);
    else if (a == "--confirm-full") c.confirm_full = true;
    else if (a == "--confirm-min-samples") c.confirm_min_samples = std::stoull(need(i));
    else if (a == "--fill") {
      std::string v = need(i);
      c.fill.clear();
      if (v != "none")
        for (auto &f : split(v, ',')) c.fill.push_back(std::atof(f.c_str()));
    } else if (a == "--overload") {
      std::string v = need(i);
      c.overload.clear();
      if (v != "none")
        for (auto &f : split(v, ',')) c.overload.push_back(std::atof(f.c_str()));
    } else if (a == "--overload-base") {
      c.overload_base = need(i);
    } else if (a == "--start-fail-steps") {
      std::string v = need(i);
      c.start_fail.clear();
      if (v != "none")
        for (auto &f : split(v, ',')) c.start_fail.push_back(std::atof(f.c_str()));
    }
    else if (a == "--min-step-queries") c.min_step_queries = std::stoul(need(i));
    else if (a == "--ramp-knee") c.ramp_knee = std::stoul(need(i));
    else if (a == "--ramp-knee-rise") c.ramp_knee_rise = std::atof(need(i).c_str());
    else if (a == "--ramp-knee-floor") c.ramp_knee_floor = std::atof(need(i).c_str());
    else if (a == "--tol") c.tol = std::atof(need(i).c_str());
    else if (a == "--max-err") c.max_err = std::atof(need(i).c_str());
    else if (a == "--abort-queue-s") c.abort_queue_s = std::atof(need(i).c_str());
    else if (a == "--lag-limit-us") c.lag_limit_us = std::atof(need(i).c_str());
    else if (a == "--arrival") c.arrival = need(i);
    else if (a == "--seed") c.seed = std::stoull(need(i));
    else if (a == "--raw") c.raw = true;
    else if (a == "--stats-op") {
      const unsigned long v = std::stoul(need(i));
      if (v == 0 || v > 0xffff) die("--stats-op 1..65535");
      c.stats_op = uint16_t(v);
    }
    else usage();
  }
  if (c.workload.empty() || c.targets.empty() || c.out.empty()) usage();
  if (c.mode != "slo" && c.mode != "fixed") die("--mode slo|fixed");
  if (c.mode == "slo" && (c.slo_stream.empty() || c.slo_ms <= 0 || c.start <= 0))
    die("--mode slo needs --slo s:pct:ms and --start R");
  if (c.mode == "fixed" && c.rates.empty()) die("--mode fixed needs --rates");
  if (c.factor <= 1 || c.precision <= 0 || c.conns == 0) die("bad --factor/--precision/--conns");
  if (c.ramp_knee && !(c.ramp_knee_rise > 1)) die("bad --ramp-knee-rise (> 1)");
  if (c.ramp_knee && !(c.ramp_knee_floor >= 1)) die("bad --ramp-knee-floor (>= 1)");
  if (c.confirm_precision <= 0 || c.max_confirm_probes < 2 || c.confirm_reps == 0)
    die("bad --confirm-precision (> 0) / --max-confirm-probes (>= 2) / --confirm-reps (>= 1)");
  if (!(c.confirm_step_down >= 0.02 && c.confirm_step_down <= 0.05)) die("bad --confirm-step-down (0.02 .. 0.05)");
  if (c.arrival != "poisson" && c.arrival != "uniform") die("--arrival poisson|uniform");
  if (c.confirm_rule != "majority" && c.confirm_rule != "pooled") die("--confirm-rule majority|pooled");
  if (c.overload_base != "first-fail" && c.overload_base != "result") die("--overload-base first-fail|result");
  for (double f : c.overload)
    if (!(f > 0)) die("bad --overload factor (> 0)");
  for (double f : c.start_fail)
    if (!(f > 1)) die("bad --start-fail-steps factor (> 1)");
  if (!c.start_fail.empty() && c.ramp_knee) die("--start-fail-steps is not used with --ramp-knee");
  if (!(c.drain_full_s >= 0)) die("bad --drain-full-s (>= 0)");
  if (!(c.drain_fail_s >= 0)) die("bad --drain-fail-s (>= 0)");
  if (c.drain_fail_s > 0 && !(c.drain_full_s > 0)) die("--drain-fail-s needs --drain-full-s");
  if (c.drain_fail_s > 0 && c.drain_fail_s >= c.drain_full_s) die("--drain-fail-s must be < --drain-full-s");
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
    double p50 = 0, p90 = 0, p95 = 0, p99 = 0, p999 = 0, pslo = 0, max = 0;  // ms; inf if requests timed out
    double lag_p99_us = 0, lag_max_us = 0;
  };
  std::vector<S> s;
  bool aborted = false, exhausted = false, pass = false, lag_flag = false;
  bool saturated = false, behind = false;  // the queue cap aborted the step / the SLO stream fell behind
  std::string reason;
  // confirm steps only (judge_probe): failed for a reason other than the SLO percentile; SLO-stream latencies (ms)
  bool nonlatency_fail = false;
  uint32_t step_no = 0;
  std::vector<double> slo_lat;
  // --drain-full-s (drain.h); recorded in steps.jsonl only when the option is on
  bool contaminated = false;  // requests were outstanding when the step started
  bool drain_fail = false;    // --drain-fail-s: the drain took longer than D (non-latency failure)
  bool judged = true;         // false: contaminated first attempt, not a search decision point (re-run follows)
  int64_t rerun_of = -1;      // a re-run: step number of the unjudged attempt
  uint64_t outstanding_at_start = 0, outstanding_after_drain = 0;
  double drain_wait_s = 0;
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
    if (c_.stats_op) {  // one extra connection per target, used only for the synchronous stats requests
      for (auto &t : c_.targets) stats_fds_.push_back(connect_to(t));
      if (mkdir((c_.out + "/stats").c_str(), 0755) != 0) die("cannot create " + c_.out + "/stats");
    }
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
    // to the precision, then confirm the best passing rate with longer repeats (slo_search.h).
    double good = 0, bad = 0, r = c_.start, prev_pslo = 0;
    uint32_t n = 0;
    uint32_t bisect_cap = c_.max_steps;
    if (c_.ramp_knee) {  // knee ramp (slo_search.h KneeRamp): low-rate failures are recorded, the ramp goes on
      KneeRamp kr(c_.ramp_knee, c_.ramp_knee_rise, c_.ramp_knee_floor * c_.slo_ms);
      bool ended = false;
      for (; n < c_.max_steps; n++) {
        StepResult s = step("ramp", r, c_.step_warmup_s, measure_for(r, c_.step_measure_s), false);
        if (s.exhausted) return finish("streams exhausted during ramp");
        search_note(s, "ramp", r);
        const double p = s.s[idx_[c_.slo_stream]].pslo;
        // --drain-fail-s: a drain-failing step counts like the SLO stream falling behind (false with the option off)
        if (kr.add(r, s.pass, s.saturated, s.behind || s.drain_fail, p)) { ended = true; break; }
        // a pass: the usual adaptive step; a fail (low-rate regime or past the knee): x factor
        r *= s.pass ? next_factor(p, prev_pslo) : c_.factor;
        prev_pslo = p;
      }
      ramp_end_ = ended ? kr.why() : kr.knee() > 0 ? "max steps (last steps failed)" : "max steps";
      if (kr.good() == 0) return finish("no passing ramp step below the knee (" + ramp_end_ + ")");
      // verifier MED (v1 delta): a failing run the stop rule never confirmed may be low-rate failures, not the knee
      if (!ended) return finish("max steps reached before the knee was confirmed (" + ramp_end_ + "); raise --max-steps");
      good = kr.good(), bad = kr.knee();
      ramp_knee_ = bad;
      bisect_cap = n + c_.knee_bisect_steps;
    } else
    for (; n < c_.max_steps; n++) {
      StepResult s = step("ramp", r, c_.step_warmup_s, c_.step_measure_s);
      if (s.exhausted) return finish("streams exhausted during ramp");
      search_note(s, "ramp", r);
      if (!s.pass) { bad = r; break; }
      good = r;
      r *= next_factor(s.s[idx_[c_.slo_stream]].pslo, prev_pslo);
      prev_pslo = s.s[idx_[c_.slo_stream]].pslo;
    }
    if (good == 0 && !c_.ramp_knee) {
      // --start-fail-steps (past-the-knee rule): the curve of a system that fails at the start rate gets points above
      // it, measured in full like the overload points (phase "overload"; saturation abort stays); same note
      for (double f : c_.start_fail) {
        const double x = c_.start * f;
        if (step("overload", x, c_.step_warmup_s, measure_for(x, c_.step_measure_s), false).exhausted)
          return finish("streams exhausted during the start-fail steps");
      }
      return finish("the start rate already violates the SLO; lower --start");
    }
    if (good == 0) return finish("no passing ramp step below the knee");
    if (bad == 0) return finish("max steps reached without an SLO violation; raise --start or --max-steps");
    for (; n < bisect_cap && bad / good > 1 + c_.precision; n++) {
      double m = std::sqrt(good * bad);
      StepResult s = step("bisect", m, c_.step_warmup_s, measure_for(m, c_.step_measure_s));
      if (s.exhausted) return finish("streams exhausted during bisection");
      search_note(s, "bisect", m);
      (s.pass ? good : bad) = m;
    }
    bisect_cut_ = bad / good > 1 + c_.precision;
    // confirm phase (decision 2026-10-18 "A+C", fallback H1 v0.6.5): confirm `good`; if most repeats fail, step down
    // from the last failed confirm by at most --confirm-step-down (a known ramp/bisect pass closer below is taken
    // instead) until a confirm passes, then bisect between the highest confirmed pass and the lowest confirm fail
    // with full confirms to --confirm-precision (slo_search.h)
    std::vector<double> passes;
    for (auto &f : search_) if (f.pass) passes.push_back(f.offered);
    const ConfirmOutcome o = confirm_search(good, passes, c_.confirm_step_down, c_.confirm_precision, c_.max_confirm_probes,
                                            [&](double x, const char *) -> int {
      Probe p;
      p.offered = x;
      std::vector<RepeatInput> in;
      keep_slo_lat_ = true;
      for (uint32_t k = 0; k < c_.confirm_reps; k++) {
        StepResult s = step("confirm", x, c_.confirm_warmup_s < 0 ? c_.step_warmup_s : c_.confirm_warmup_s,
                            measure_for(x, c_.confirm_s), !c_.confirm_full);
        if (s.exhausted) return keep_slo_lat_ = false, -1;
        p.fails += !s.pass;
        in.push_back({s.pass, s.nonlatency_fail, std::move(s.slo_lat)});
        s.slo_lat.clear();
        p.reps.push_back(s);
      }
      keep_slo_lat_ = false;
      p.j = judge_probe(in, c_.slo_pct, c_.slo_ms, c_.confirm_min_samples);
      // majority with --confirm-min-samples 0: p.j.majority == pass iff 2 * fails <= reps (the rule since 2026-10-18)
      p.pass = (c_.confirm_rule == "pooled" ? p.j.pooled : p.j.majority) == kVerdictPass;
      probes_.push_back(p);
      if (c_.confirm_rule != "majority" || c_.confirm_full || c_.confirm_min_samples)
        std::fprintf(stderr, "[confirm] x=%.1f majority %s, pooled %s (p%s %.3f ms over %llu), rule %s -> %s\n", x,
                     verdict_name(p.j.majority), verdict_name(p.j.pooled), fmt(c_.slo_pct).c_str(), p.j.pooled_pslo,
                     (unsigned long long)p.j.n, c_.confirm_rule.c_str(), p.pass ? "PASS" : "FAIL");
      return p.pass ? 1 : 0;
    });
    for (size_t k = 0; k < probes_.size() && k < o.probes.size(); k++) probes_[k].role = o.probes[k].role;
    if (o.exhausted) return finish("streams exhausted during confirm");
    // both rules: the followed one = o; the other one replayed on the probes that were run (flag: unrun probe needed)
    {
      const int fol = c_.confirm_rule == "pooled" ? 1 : 0;
      for (int r = 0; r < 2; r++) {
        std::vector<std::pair<double, int>> rec;
        for (auto &p : probes_) rec.push_back({p.offered, r ? p.j.pooled : p.j.majority});
        rule_res_[r].valid = true, rule_res_[r].followed = r == fol;
        if (r == fol) rule_res_[r].rr.o = o;
        else
          rule_res_[r].rr = replay_rule(good, passes, c_.confirm_step_down, c_.confirm_precision,
                                        c_.max_confirm_probes, rec);
      }
    }
    confirm_search_finish_ = o.finish;
    confirmed_ = o.confirmed;
    // result: the highest confirmed pass; no confirmed pass -> the lowest probed rate (its repeats failed; legacy
    // semantics of the noted result)
    best_ = o.confirmed ? o.best : o.lo_fail;
    for (auto &p : probes_)
      if (p.offered == best_) confirm_ = p.reps;
    // knee bracket above the result: the lowest failed rate above it, ramp/bisect step or failed confirm
    best_bad_ = 0, bracket_phase_ = "", bracket_hi_x_ = 0;
    auto lower = [&](double off, const char *ph, double x) {
      if (off > best_ && (best_bad_ == 0 || off < best_bad_)) best_bad_ = off, bracket_phase_ = ph, bracket_hi_x_ = x;
    };
    for (auto &f : search_) if (!f.pass) lower(f.offered, f.phase.c_str(), f.x);
    for (auto &p : probes_) if (!p.pass) lower(p.offered, "confirm", mean_x(p.reps));
    overload(best_bad_ > 0 ? best_bad_ : bad);
    if (!o.confirmed) return finish("confirm failed at three rates; the knee is noisy (longer --confirm-s?)");
    return finish("");
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
  // Ramp step size from how close the SLO percentile is to the SLO and how fast it grew in the last step: big steps
  // far below the SLO, small steps where the curve bends (denser points around the knee).
  double next_factor(double p, double prev) const {
    const double f = c_.factor;  // default 1.5
    if (prev > 0 && p > 1.5 * prev) return 1 + (f - 1) / 5;  // steep: latency grew > 1.5x in one step -> x1.1
    if (p < c_.slo_ms / 4) return f * f;                     // far below the SLO: x2.25
    if (p < c_.slo_ms / 2) return f;                         // x1.5
    if (p < 0.8 * c_.slo_ms) return 1 + (f - 1) * 2 / 5;     // x1.2
    return 1 + (f - 1) / 5;                                  // close to the SLO: x1.1
  }

  // Points past the knee for the throughput/latency curve: measured in full (the early "SLO already exceeded"
  // abort is off; the saturation abort stays). They never change the SLO result.
  // --overload-base result: the points are at the result (the confirmed offered rate; with no confirmed rate the
  // lowest probed rate, as max_offered_x_pass) x f instead of the first failed rate above it x f.
  void overload(double first_fail) {
    for (double f : c_.fill) {  // bend before the knee (result = best_)
      StepResult s = step("fill", best_ * f, c_.step_warmup_s, measure_for(best_ * f, c_.step_measure_s), false);
      if (s.exhausted) return;
    }
    const double base = c_.overload_base == "result" ? best_ : first_fail;
    for (double f : c_.overload) {
      StepResult s = step("overload", base * f, c_.step_warmup_s, measure_for(base * f, c_.step_measure_s), false);
      if (s.exhausted) return;
    }
  }

  // --min-step-queries N: a measured step holds about N SLO-stream requests (nearest-rank percentiles of a handful of
  // queries are the slowest query); 0 = the given length (old behaviour)
  double measure_for(double x, double measure_s) {
    if (!c_.min_step_queries || slo_idx_ == 0xff) return measure_s;
    const double r = stream_rates(x)[slo_idx_];
    return r > 0 ? std::max(measure_s, std::ceil(c_.min_step_queries / r)) : measure_s;
  }

  // ramp/bisect step record for the confirm phase (lower-bound candidates) and the knee bracket
  void search_note(const StepResult &s, const char *phase, double offered) {
    const auto *st = slo_idx_ != 0xff ? &s.s[slo_idx_] : nullptr;
    search_.push_back({offered, phase, s.pass, xval(s), st ? st->pslo : 0, st ? st->sent : 0, s.reason});
  }
  double mean_x(const std::vector<StepResult> &v) const {
    double t = 0;
    for (auto &r : v) t += xval(r);
    return v.empty() ? 0 : t / v.size();
  }
  double mean_pslo(const std::vector<StepResult> &v) const {
    double t = 0;
    for (auto &r : v) t += r.s[slo_idx_].pslo;
    return v.empty() ? 0 : t / v.size();
  }

  // Every search phase calls step(); with --drain-full-s a contaminated first attempt (drain.h) is logged as phase
  // "contaminated" and the same step is run once more, so the callers only ever see the judged result.
  StepResult step(const char *phase, double x, double warmup_s, double measure_s, bool slo_abort = true) {
    int64_t first = -1;
    return clean_step([&](bool rerun) {
      StepResult r = step_once(phase, x, warmup_s, measure_s, slo_abort, rerun, rerun ? first : -1);
      if (!rerun) first = r.step_no;
      return r;
    });
  }

  StepResult step_once(const char *phase_in, double x, double warmup_s, double measure_s, bool slo_abort, bool rerun,
                       int64_t rerun_of) {
    const size_t S = specs_.size();
    std::vector<double> rate = stream_rates(x);
    double total = 0;
    for (double v : rate) total += v;
    slow_.store(0);
    const uint64_t out_base = outstanding_.load();  // leftovers of earlier steps (timed out) do not count here
    // --drain-full-s: clean-start check before the warmup (always judged with the option off)
    const bool judged = step_judged(c_.drain_full_s, out_base, rerun, measure_s > 0);
    const char *phase = judged ? phase_in : "contaminated";
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
    // stats snapshots (--stats-op): "begin" from a helper thread at the window start ws, "end" right after sending
    // stops; only for measured steps, and "end" only if "begin" was taken (a step that stops before ws has none)
    std::atomic<bool> snap_cancel{false}, snap_begun{false};
    std::thread snap;
    if (c_.stats_op && measure_s > 0)
      snap = std::thread([&, phase, x, ws] {
        for (uint64_t t = now_ns(); t < ws; t = now_ns()) {
          if (snap_cancel.load()) return;
          const uint64_t d = std::min<uint64_t>(ws - t, 1000000);
          timespec ts{0, long(d)};
          nanosleep(&ts, nullptr);
        }
        if (snap_cancel.load()) return;
        snapshot_all("begin", phase, x);
        snap_begun.store(true);
      });
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
          res.saturated = true;
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
    if (snap.joinable()) {
      snap_cancel.store(true);
      snap.join();
      if (snap_begun.load()) snapshot_all("end", phase, x);
    }
    // default: wait while outstanding > out_base, at most --drain-s (unchanged); --drain-full-s S: until 0, at most S
    const DrainResult dr = drain_step(
        send_end, c_.drain_s, c_.drain_full_s, out_base, [&] { return outstanding_.load(); }, [] { return now_ns(); },
        [] { usleep(1000); });
    res.drain_wait_s = dr.wait_s, res.outstanding_after_drain = dr.outstanding_after;
    res.outstanding_at_start = out_base, res.contaminated = c_.drain_full_s > 0 && out_base > 0;
    res.judged = judged, res.rerun_of = rerun_of;

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
      st.p95 = pct(lat[s], 95);
      st.pslo = pct(lat[s], c_.slo_pct);  // the --slo percentile (e.g. p95 for DLRM, p99 otherwise)
      st.max = lat[s].empty() ? 0 : *std::max_element(lat[s].begin(), lat[s].end());
      st.lag_p99_us = pct(lag[s], 99);
      st.lag_max_us = lag[s].empty() ? 0 : *std::max_element(lag[s].begin(), lag[s].end());
      if (measure_s > 0 && rate[s] > 0) {
        // keeping up = completions in the window vs requests actually sent in it (not the nominal rate: a Poisson
        // count over a short window is itself noisy); tiny counts are not judged
        if (st.sent >= 100 && st.achieved * win < (1 - c_.tol) * double(st.sent) && pass)
          pass = false, why = specs_[s].name + " completions < sent (falling behind)", res.behind |= s == slo_idx_,
          res.nonlatency_fail = true;
        if (st.sent && double(st.errors + st.timeouts) / st.sent > c_.max_err && pass)
          pass = false, why = specs_[s].name + " errors/timeouts", res.nonlatency_fail = true;
      }
      if (st.lag_p99_us > c_.lag_limit_us) res.lag_flag = true;
    }
    // --drain-fail-s: a backlog left after the step is a non-latency failure (flagged even when another check already
    // failed, so --confirm-rule pooled never passes a probe with a drain-failing repeat)
    if (drain_failed(c_.drain_full_s, c_.drain_fail_s, res.drain_wait_s, measure_s > 0)) {
      res.drain_fail = true, res.nonlatency_fail = true;
      if (pass) pass = false, why = "drain > " + fmt(c_.drain_fail_s) + " s (backlog)";
    }
    if (slo_idx_ != 0xff && measure_s > 0 && res.s[slo_idx_].pslo > c_.slo_ms && pass)
      pass = false, why = "p" + fmt(c_.slo_pct) + " " + fmt(res.s[slo_idx_].pslo) + " ms > SLO";
    res.pass = pass && measure_s > 0;
    res.reason = why;
    if (!judged) {  // --drain-full-s: neither a pass nor a fail; step() runs it once more
      res.pass = false;
      res.reason = "contaminated: " + std::to_string(out_base) + " outstanding at step start (" + phase_in +
                   "; not judged, re-run)";
    }
    res.nonlatency_fail |= res.saturated || res.exhausted;
    res.step_no = step_no_;
    if (keep_slo_lat_ && slo_idx_ != 0xff) res.slo_lat = lat[slo_idx_];  // same multiset (nth_element only reorders)
    log_step(phase, x, measure_s, res);
    if (c_.raw && measure_s > 0) dump_raw(first_id, last_id);
    step_no_++;
    return res;
  }

  // One stats snapshot per target, in parallel: request op --stats-op on the target's stats connection, write the
  // text reply to <out>/stats/step<NNN>-<when>-t<k>.txt after one header line.
  void snapshot_all(const char *when, const char *phase, double x) {
    std::vector<std::thread> th;
    for (size_t t = 0; t < stats_fds_.size(); t++) th.emplace_back([=] { snapshot(t, when, phase, x); });
    for (auto &h : th) h.join();
  }
  void snapshot(size_t t, const char *when, const char *phase, double x) {
    timespec rt;
    clock_gettime(CLOCK_REALTIME, &rt);
    const uint64_t t0 = now_ns();
    frame::header h;
    frame::fill(&h, c_.stats_op, step_no_, 0);
    if (!frame::write_full(stats_fds_[t], &h, sizeof(h))) die("stats request failed (target " + c_.targets[t] + ")");
    frame::header rh;
    std::string body;
    if (!frame::read_full(stats_fds_[t], &rh, sizeof(rh)) || rh.len < frame::kHeaderTail || rh.len > frame::kMaxFrame)
      die("stats reply failed (target " + c_.targets[t] + ")");
    body.resize(frame::payload_len(rh));
    if (!body.empty() && !frame::read_full(stats_fds_[t], &body[0], body.size()))
      die("stats reply failed (target " + c_.targets[t] + ")");
    const uint64_t t1 = now_ns();
    char name[64];
    std::snprintf(name, sizeof(name), "/stats/step%03u-%s-t%zu.txt", step_no_, when, t);
    FILE *f = std::fopen((c_.out + name).c_str(), "w");
    if (!f) die("cannot write " + c_.out + name);
    std::fprintf(f, "# when=%s phase=%s step=%u offered_x=%s target=%zu addr=%s status=%u wall_ns=%llu mono_ns=%llu "
                 "rtt_us=%.1f\n",
                 when, phase, step_no_, fmt(x).c_str(), t, c_.targets[t].c_str(), unsigned(rh.code),
                 (unsigned long long)(uint64_t(rt.tv_sec) * 1000000000ull + uint64_t(rt.tv_nsec)),
                 (unsigned long long)t0, (t1 - t0) / 1e3);
    std::fwrite(body.data(), 1, body.size(), f);
    std::fclose(f);
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
        << ",\"lag_max_us\":" << fmt(st.lag_max_us) << ",\"p95_ms\":" << fmt(st.p95) << "}";
    }
    o << "}";
    if (c_.drain_full_s > 0)  // opt-in keys only, appended after "streams" (steps.jsonl of earlier callers unchanged)
      o << ",\"contaminated\":" << (r.contaminated ? "true" : "false") << ",\"judged\":" << (r.judged ? "true" : "false")
        << ",\"rerun_of\":" << (r.rerun_of >= 0 ? std::to_string(r.rerun_of) : std::string("null"))
        << ",\"outstanding_at_start\":" << r.outstanding_at_start << ",\"drain_wait_s\":" << fmt(r.drain_wait_s)
        << ",\"outstanding_after_drain\":" << r.outstanding_after_drain;
    if (c_.drain_fail_s > 0) o << ",\"drain_fail\":" << (r.drain_fail ? "true" : "false");
    o << "}";
    std::fprintf(steps_, "%s\n", o.str().c_str());
    std::fflush(steps_);
    std::fprintf(stderr, "[%s] step %u x=%.1f -> %s%s%s\n", phase, step_no_, x,
                 measure_s <= 0 ? "done" : r.pass ? "PASS" : "FAIL",
                 r.reason.empty() ? "" : " (", r.reason.empty() ? "" : (r.reason + ")").c_str());
    if (slo_idx_ != 0xff) {
      auto &st = r.s[slo_idx_];
      std::fprintf(stderr, "        %s achieved %.1f/s p50 %.3f p99 %.3f p%s(SLO) %.3f ms, lag p99 %.0f us\n",
                   specs_[slo_idx_].name.c_str(), st.achieved, st.p50, st.p99, fmt(c_.slo_pct).c_str(), st.pslo,
                   st.lag_p99_us);
    }
    if (c_.drain_full_s > 0) {
      std::fprintf(stderr, "        drain %.1f s, outstanding at start %llu, after drain %llu%s\n", r.drain_wait_s,
                   (unsigned long long)r.outstanding_at_start, (unsigned long long)r.outstanding_after_drain,
                   r.contaminated ? (r.judged ? " (contaminated re-run, judged)" : " (contaminated, re-run follows)") : "");
      n_contaminated_ += r.contaminated, n_reruns_ += r.rerun_of >= 0, n_drain_fails_ += r.drain_fail;
    }
    steps_log_.push_back({phase, xval(r), r.pass, r.lag_flag});
  }

  void dump_raw(uint64_t a, uint64_t b) {
    std::string p = c_.out + "/raw-step" + std::to_string(step_no_) + ".bin";
    FILE *f = std::fopen(p.c_str(), "wb");
    // request ids (the frame req_id the server echoes), one u64 per raw row in the same order, in a sidecar file so
    // the 32-byte raw rows stay unchanged for existing readers (glob raw-step*.bin does not match rawid-step*.bin)
    FILE *g = std::fopen((c_.out + "/rawid-step" + std::to_string(step_no_) + ".bin").c_str(), "wb");
    for (uint64_t id = a; id < b; id++) {
      Rec *r = store_.get(id);
      uint64_t row[4] = {r->sched, r->send, r->done.load(), (uint64_t(r->stream) << 32) | r->status.load() |
                                                                 (uint64_t(r->measured) << 40)};
      std::fwrite(row, sizeof(row), 1, f);
      std::fwrite(&id, sizeof(id), 1, g);
    }
    std::fclose(f);
    std::fclose(g);
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
      << (c_.confirm_warmup_s >= 0 ? " confirm_warmup_s=" + std::to_string(c_.confirm_warmup_s) : std::string())
      << " confirm_precision=" << c_.confirm_precision << " max_confirm_probes=" << c_.max_confirm_probes
      << " confirm_step_down=" << c_.confirm_step_down << " overload=" << [&] { std::string o; for (double f : c_.overload) o += (o.empty() ? "" : ",") + fmt(f); return o.empty() ? std::string("none") : o; }()
      << "\ntol=" << c_.tol << " max_err=" << c_.max_err << " abort_queue_s=" << c_.abort_queue_s
      << " lag_limit_us=" << c_.lag_limit_us << "\nstats_op=" << c_.stats_op << "\n";
    if (c_.min_step_queries || c_.ramp_knee)  // opt-in keys only (manifests of earlier callers stay unchanged)
      m << "min_step_queries=" << c_.min_step_queries << " ramp_knee=" << c_.ramp_knee << " ramp_knee_rise="
        << c_.ramp_knee_rise << " ramp_knee_floor=" << c_.ramp_knee_floor << " knee_bisect_steps=" << c_.knee_bisect_steps << "\n";
    if (c_.confirm_rule != "majority" || c_.confirm_full || c_.confirm_min_samples)  // opt-in keys only
      m << "confirm_rule=" << c_.confirm_rule << " confirm_full=" << (c_.confirm_full ? 1 : 0)
        << " confirm_min_samples=" << c_.confirm_min_samples << "\n";
    if (c_.overload_base != "first-fail" || !c_.start_fail.empty()) {  // opt-in keys only (past-the-knee rule)
      std::string sf;
      for (double f : c_.start_fail) sf += (sf.empty() ? "" : ",") + fmt(f);
      m << "overload_base=" << c_.overload_base << " start_fail_steps=" << (sf.empty() ? "none" : sf) << "\n";
    }
    if (c_.drain_full_s > 0)  // opt-in keys only
      m << "drain_full_s=" << c_.drain_full_s << " drain_fail_s=" << c_.drain_fail_s << "\n";
    for (auto &kv : c_.mix) m << "mix." << kv.first << "=" << kv.second << "\n";
    for (auto &kv : c_.fixed) m << "fixed." << kv.first << "=" << kv.second << "\n";
  }

  // <out>/confirm_probes.csv: one row per confirm repeat, probe-level columns repeated on each row of the probe
  void write_confirm_csv() {
    FILE *f = std::fopen((c_.out + "/confirm_probes.csv").c_str(), "w");
    if (!f) return;
    auto num = [](double v) {
      if (std::isinf(v)) return std::string("inf");
      char b[64];
      std::snprintf(b, sizeof(b), "%.6g", v);
      return std::string(b);
    };
    std::fprintf(f, "probe,offered_x,role,rep,step,rep_pass,rep_aborted,rep_reason,rep_x,rep_pslo_ms,rep_p99_ms,rep_n,"
                    "fails,nonlatency_fails,pooled_n,pooled_pslo_ms,pooled_p99_ms,verdict_majority,verdict_pooled,"
                    "rule,probe_pass%s\n",
                 c_.drain_full_s > 0 ? ",rep_drain_wait_s,rep_drain_fail,rep_nonlatency_fail,rep_contaminated" : "");
    for (size_t k = 0; k < probes_.size(); k++) {
      const Probe &p = probes_[k];
      for (size_t q = 0; q < p.reps.size(); q++) {
        const StepResult &r = p.reps[q];
        const auto &st = r.s[slo_idx_];
        std::string why = r.reason;
        for (char &ch : why) if (ch == ',' || ch == '"') ch = ';';
        std::fprintf(f, "%zu,%s,%s,%zu,%u,%d,%d,%s,%s,%s,%s,%llu,%u,%u,%llu,%s,%s,%s,%s,%s,%d", k,
                     num(p.offered).c_str(), p.role.c_str(), q, r.step_no, int(r.pass), int(r.aborted), why.c_str(),
                     num(xval(r)).c_str(), num(st.pslo).c_str(), num(st.p99).c_str(), (unsigned long long)st.sent,
                     p.fails, p.j.nonlatency_fails, (unsigned long long)p.j.n, num(p.j.pooled_pslo).c_str(),
                     num(p.j.pooled_p99).c_str(), verdict_name(p.j.majority), verdict_name(p.j.pooled),
                     c_.confirm_rule.c_str(), int(p.pass));
        if (c_.drain_full_s > 0)  // opt-in columns, appended after the older ones
          std::fprintf(f, ",%s,%d,%d,%d", num(r.drain_wait_s).c_str(), int(r.drain_fail), int(r.nonlatency_fail),
                       int(r.contaminated));
        std::fprintf(f, "\n");
      }
    }
    std::fclose(f);
  }

  int finish(const std::string &note) {
    std::string err;
    bool ok = w_->finish(c_.out, &err);
    std::ofstream s(c_.out + "/summary.json");
    s << "{\"mode\":\"" << c_.mode << "\",\"note\":\"" << note << "\",\"steps\":" << step_no_
      << ",\"unknown_responses\":" << unknown_.load();
    if (!c_.slo_stream.empty())  // every run with --slo (also fixed mode and SLO runs without a passing step)
      s << ",\"slo\":{\"stream\":\"" << c_.slo_stream << "\",\"pct\":" << fmt(c_.slo_pct) << ",\"ms\":" << fmt(c_.slo_ms)
        << "}";
    if (c_.mode == "slo" && best_ > 0) {
      double sx = 0, sxx = 0, sp = 0, spp = 0;
      uint32_t n = 0, fails = 0;
      for (auto &r : confirm_) {
        double xv = xval(r), pv = r.s[slo_idx_].pslo;
        sx += xv, sxx += xv * xv, sp += pv, spp += pv * pv, n++;
        if (!r.pass) fails++;
      }
      auto sd = [&](double a, double aa) { return n > 1 ? std::sqrt(std::max(0.0, (aa - a * a / n) / (n - 1))) : 0; };
      s << ",\"max_offered_x_pass\":" << fmt(best_) << ",\"min_offered_x_fail\":" << fmt(best_bad_)
        << ",\"confirm\":{\"reps\":" << n << ",\"fails\":" << fails << ",\"x_mean\":" << fmt(n ? sx / n : 0)
        << ",\"x_sd\":" << fmt(sd(sx, sxx)) << ",\"pslo_mean_ms\":" << fmt(n ? sp / n : 0)
        << ",\"pslo_sd_ms\":" << fmt(sd(sp, spp)) << "}";
      // knee bracket (decision 2026-10-18 "A+C"): lo = the confirmed result (null if no rate confirmed), hi = the
      // lowest failed rate above it (ramp/bisect step or failed confirm; hi_x = that step's x or the confirm mean x)
      s << ",\"confirmed\":" << (confirmed_ ? "true" : "false") << ",\"bracket\":{\"lo_offered\":"
        << (confirmed_ ? fmt(best_) : std::string("null")) << ",\"hi_offered\":"
        << (best_bad_ > 0 ? fmt(best_bad_) : std::string("null")) << ",\"hi_phase\":\"" << bracket_phase_
        << "\",\"hi_x\":" << (best_bad_ > 0 ? fmt(bracket_hi_x_) : std::string("null")) << ",\"rel_width\":"
        << (confirmed_ && best_bad_ > 0 ? fmt(best_bad_ / best_ - 1) : std::string("null")) << "}"
        << ",\"confirm_search\":{\"finish\":\"" << confirm_search_finish_ << "\",\"precision\":" << fmt(c_.precision)
        << ",\"confirm_precision\":" << fmt(c_.confirm_precision) << ",\"max_probes\":" << c_.max_confirm_probes
        << ",\"step_down\":" << fmt(c_.confirm_step_down) << ",\"probes\":" << (probes_.empty() ? 0 : probes_.size() - 1) << "},\"confirm_probes\":[";
      for (size_t k = 0; k < probes_.size(); k++) {
        auto &p = probes_[k];
        s << (k ? "," : "") << "{\"offered_x\":" << fmt(p.offered) << ",\"role\":\"" << p.role << "\",\"reps\":"
          << p.reps.size() << ",\"fails\":" << p.fails << ",\"pass\":" << (p.pass ? "true" : "false")
          << ",\"x_mean\":" << fmt(mean_x(p.reps)) << ",\"pslo_mean_ms\":" << fmt(mean_pslo(p.reps));
        // both confirm rules (2026-10-21; keys appended after the older ones): per-repeat SLO percentile, p99 and
        // SLO-stream count, the pooled percentile over the merged latencies, and both verdicts
        auto arr = [&](auto f) {
          std::string a = "[";
          for (size_t q = 0; q < p.reps.size(); q++) a += (q ? "," : "") + f(p.reps[q]);
          return a + "]";
        };
        s << ",\"rep_pslo_ms\":" << arr([&](const StepResult &r) { return fmt(r.s[slo_idx_].pslo); })
          << ",\"rep_p99_ms\":" << arr([&](const StepResult &r) { return fmt(r.s[slo_idx_].p99); })
          << ",\"rep_n\":" << arr([&](const StepResult &r) { return std::to_string(r.s[slo_idx_].sent); })
          << ",\"rep_pass\":" << arr([&](const StepResult &r) { return std::string(r.pass ? "true" : "false"); })
          << ",\"rep_aborted\":" << arr([&](const StepResult &r) { return std::string(r.aborted ? "true" : "false"); })
          << ",\"nonlatency_fails\":" << p.j.nonlatency_fails << ",\"pooled_n\":" << p.j.n
          << ",\"pooled_pslo_ms\":" << fmt(p.j.pooled_pslo) << ",\"pooled_p99_ms\":" << fmt(p.j.pooled_p99)
          << ",\"verdict_majority\":\"" << verdict_name(p.j.majority) << "\",\"verdict_pooled\":\""
          << verdict_name(p.j.pooled) << "\"";
        if (c_.drain_full_s > 0)  // opt-in keys only
          s << ",\"rep_drain_wait_s\":" << arr([&](const StepResult &r) { return fmt(r.drain_wait_s); })
            << ",\"rep_drain_fail\":" << arr([&](const StepResult &r) { return std::string(r.drain_fail ? "true" : "false"); });
        s << "}";
      }
      s << "]";
      s << ",\"confirm_rule\":{\"rule\":\"" << c_.confirm_rule << "\",\"full\":" << (c_.confirm_full ? "true" : "false")
        << ",\"min_samples\":" << c_.confirm_min_samples << "}";
      for (int r = 0; r < 2; r++) {
        // result_<rule>: what that rule concludes; the followed rule = the search itself; the other rule = replay on
        // the probes that were run; complete=false: it would have needed the unrun probe needs_offered (needs_role),
        // and confirmed/max_offered_x_pass are then its state when that probe was needed (not a final result)
        const RuleResult &rr = rule_res_[r];
        if (!rr.valid) continue;
        const ConfirmOutcome &q = rr.rr.o;
        s << ",\"result_" << (r ? "pooled" : "majority") << "\":{\"followed\":" << (rr.followed ? "true" : "false")
          << ",\"complete\":" << (rr.rr.complete ? "true" : "false") << ",\"confirmed\":"
          << (q.confirmed ? "true" : "false") << ",\"max_offered_x_pass\":"
          << (q.confirmed ? fmt(q.best) : std::string("null")) << ",\"lo_fail_offered\":"
          << (q.lo_fail > 0 ? fmt(q.lo_fail) : std::string("null")) << ",\"finish\":\"" << q.finish
          << "\",\"probes_used\":" << q.probes.size() << ",\"needs_offered\":"
          << (rr.rr.complete ? std::string("null") : fmt(rr.rr.unrun_offered)) << ",\"needs_role\":\""
          << rr.rr.unrun_role << "\"}";
      }
      write_confirm_csv();
      if (c_.ramp_knee) {  // knee ramp: low-rate violations = failed ramp/bisect steps below the result
        s << ",\"ramp_policy\":{\"knee_k\":" << c_.ramp_knee << ",\"knee_rise\":" << fmt(c_.ramp_knee_rise)
          << ",\"knee_floor_x_slo\":" << fmt(c_.ramp_knee_floor)
          << ",\"min_step_queries\":" << c_.min_step_queries << ",\"knee_offered\":"
          << (ramp_knee_ > 0 ? fmt(ramp_knee_) : std::string("null")) << ",\"ramp_end\":\"" << ramp_end_
          << "\",\"bisect_cut\":" << (bisect_cut_ ? "true" : "false") << "},\"low_rate_violations\":[";
        bool first = true;
        for (auto &f : search_)
          if (!f.pass && f.offered < best_) {
            s << (first ? "" : ",") << "{\"phase\":\"" << f.phase << "\",\"offered_x\":" << fmt(f.offered) << ",\"x\":" << fmt(f.x)
              << ",\"pslo_ms\":" << fmt(f.pslo) << ",\"n\":" << f.sent << ",\"reason\":\"" << f.reason << "\"}";
            first = false;
          }
        s << "]";
      }
    }
    uint32_t lag_pass = 0;
    for (auto &st : steps_log_) lag_pass += st.pass && st.lag;
    s << ",\"passing_steps_with_send_lag\":" << lag_pass << ",\"workload_finish\":\"" << (ok ? "ok" : err) << "\"";
    if (c_.drain_full_s > 0)  // opt-in keys only
      s << ",\"drain_full\":{\"cap_s\":" << fmt(c_.drain_full_s) << ",\"contaminated_steps\":" << n_contaminated_
        << ",\"reruns\":" << n_reruns_ << ",\"fail_s\":" << fmt(c_.drain_fail_s) << ",\"drain_fails\":" << n_drain_fails_
        << "}";
    s << "}\n";
    s.close();
    std::fclose(steps_);
    std::fprintf(stderr, "loadgen: done%s%s -> %s\n", note.empty() ? "" : ": ", note.c_str(), c_.out.c_str());
    stopping_.store(true);
    for (auto &v : fds_)
      for (int fd : v) shutdown(fd, SHUT_RDWR);
    for (int fd : stats_fds_) close(fd);
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
  std::vector<int> stats_fds_;  // --stats-op: one per target
  std::vector<uint32_t> rr_;
  std::vector<std::thread> rx_;
  Store store_;
  std::atomic<uint64_t> issued_{0}, outstanding_{0}, unknown_{0}, slow_{0};
  std::atomic<bool> stopping_{false};
  uint8_t slo_idx_ = 0xff;  // fixed in setup() before receivers start
  double slo_ns_ = 0;
  uint32_t step_no_ = 0;
  uint32_t n_contaminated_ = 0, n_reruns_ = 0, n_drain_fails_ = 0;  // --drain-full-s, --drain-fail-s
  FILE *steps_ = nullptr;
  std::vector<StepLog> steps_log_;
  std::vector<StepResult> confirm_;  // repeats of the confirm at the result best_
  double best_ = 0, best_bad_ = 0;   // result and the knee bracket's upper end (lowest failed rate above it)
  struct SearchStep {
    double offered;
    std::string phase;
    bool pass;
    double x;
    double pslo = 0;
    uint64_t sent = 0;
    std::string reason;
  };
  std::vector<SearchStep> search_;  // ramp/bisect steps in order
  double ramp_knee_ = 0;            // --ramp-knee: the knee bracket of the ramp (0 = none)
  std::string ramp_end_;            // --ramp-knee: why the ramp stopped
  bool bisect_cut_ = false;         // the bisect budget ended above the precision  // ramp/bisect steps in order
  struct Probe {
    double offered = 0;
    std::string role;
    uint32_t fails = 0;
    bool pass = false;
    std::vector<StepResult> reps;
    ProbeJudgement j;  // both rules' verdicts (slo_search.h judge_probe)
  };
  std::vector<Probe> probes_;  // every confirm (confirm_reps repeats each), in order
  bool keep_slo_lat_ = false;  // step() keeps the SLO-stream latencies (confirm repeats, judge_probe)
  // both rules' conclusions (--confirm-rule followed by the search; the other one replayed on the recorded probes)
  struct RuleResult {
    bool valid = false, followed = false;
    RuleReplay rr;
  };
  RuleResult rule_res_[2];  // [0] majority, [1] pooled
  bool confirmed_ = false;
  std::string confirm_search_finish_, bracket_phase_;
  double bracket_hi_x_ = 0;
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

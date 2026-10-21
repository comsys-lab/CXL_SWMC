// Confirm phase of the max-throughput-under-SLO search (loadgen --mode slo, README "Max throughput under SLO").
// Kept apart from the engine so test/slo_search_test.cc drives it with a synthetic confirm oracle (no server).
//
// Input: `good` = the best ramp/bisect pass (one short step), `passes` = every ramp/bisect pass (unconfirmed), and a
// confirm callback (one confirm = confirm_reps x confirm_s, --confirm-rule majority (default) or pooled, see
// judge_probe below; 1 pass, 0 fail or insufficient samples, -1 streams exhausted).
// 1. Confirm `good`; a pass ends the search (bracket above it = the bisect/ramp first fail).
// 2. Otherwise hi = good (the lowest failed confirm), and
//    a) while no rate is confirmed yet (H1 v0.6.5, decision 2026-10-18 "탐색 fallback 수정"; v0.6.3 jumped to the
//       next lower ramp pass however far below): confirm c = max(highest ramp/bisect pass below hi ("lower"),
//       hi / (1 + step_down) ("step-down")), i.e. never more than one geometric step below the last failed confirm
//       unless a known pass lies closer; a fail lowers hi and the next step starts from it;
//    b) once lo is confirmed: confirm sqrt(lo * hi) ("bisect") until hi / lo <= 1 + confirm_precision;
//    at most max_probes confirms after the first. Result = the highest confirmed pass (lo).
// Finish reasons (summary.json confirm_search.finish): "first confirm passed", "bracket within confirm precision",
// "probe limit (hi/lo X > 1 + cp)" (a confirmed result with a wider bracket), "no confirmed pass in N probes" (the
// engine then keeps the legacy note "confirm failed at three rates; ..."; max_probes >= 2 makes that literally true:
// the first rate and at least two lower ones failed).
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace loadgen {

struct ConfirmProbe {
  double offered = 0;
  std::string role;  // first | lower | step-down | bisect
  int pass = 0;      // 1 pass, 0 fail (majority of the repeats)
};

struct ConfirmOutcome {
  bool confirmed = false, exhausted = false;
  double best = 0;     // highest confirmed pass (0 if none)
  double lo_fail = 0;  // lowest confirm-failed rate above best (0 if none); all-fail case: the lowest failed rate
  std::string finish;
  std::vector<ConfirmProbe> probes;  // in order; probes[0] = the first confirm at `good`
};

// confirm(x, role) -> 1 pass, 0 fail, -1 streams exhausted (outcome.exhausted, search stops)
// step_down: geometric step below the last failed confirm while nothing is confirmed (loadgen --confirm-step-down)
inline ConfirmOutcome confirm_search(double good, std::vector<double> passes, double step_down, double confirm_precision,
                                     uint32_t max_probes, const std::function<int(double, const char *)> &confirm) {
  ConfirmOutcome o;
  auto run = [&](double x, const char *role) {
    int r = confirm(x, role);
    if (r < 0) {
      o.exhausted = true;
      return -1;
    }
    o.probes.push_back({x, role, r});
    return r;
  };
  int r = run(good, "first");
  if (r < 0) return o;
  if (r == 1) {
    o.confirmed = true, o.best = good, o.finish = "first confirm passed";
    return o;
  }
  // candidates for the lower bound: ramp/bisect passes below the confirm-failed rate, highest first
  std::sort(passes.begin(), passes.end(), [](double a, double b) { return a > b; });
  passes.erase(std::unique(passes.begin(), passes.end()), passes.end());
  double hi = good, lo = 0;
  size_t ci = 0;
  uint32_t k = 0;
  for (; k < max_probes; k++) {
    double m;
    const char *role;
    if (lo == 0) {
      while (ci < passes.size() && passes[ci] >= hi) ci++;
      m = hi / (1 + step_down), role = "step-down";
      if (ci < passes.size() && passes[ci] >= m) m = passes[ci++], role = "lower";
    } else if (hi / lo > 1 + confirm_precision) {
      m = std::sqrt(lo * hi), role = "bisect";
    } else {
      break;
    }
    r = run(m, role);
    if (r < 0) return o;
    (r == 1 ? lo : hi) = m;
  }
  o.lo_fail = hi;
  char b[160];
  if (lo == 0) {
    std::snprintf(b, sizeof(b), "no confirmed pass in %u probes", k);
    o.finish = b;
  } else if (hi / lo <= 1 + confirm_precision) {
    o.confirmed = true, o.best = lo, o.finish = "bracket within confirm precision";
  } else {
    o.confirmed = true, o.best = lo;
    std::snprintf(b, sizeof(b), "probe limit (hi/lo %.4f > 1 + %g)", hi / lo, confirm_precision);
    o.finish = b;
  }
  return o;
}

// ---------------------------------------------------------------- confirm rules (--confirm-rule, 2026-10-21)
// One confirm probe = confirm_reps repeats at one rate. Both rules are judged on every probe; the search follows
// --confirm-rule, the other rule is replayed on the recorded probes (replay_rule).
//   majority (default, the rule since 2026-10-18): each repeat is judged alone (the engine's step pass: SLO percentile
//     of the repeat <= SLO, keeping up, errors); the probe passes iff fails * 2 <= reps.
//   pooled: the SLO-stream latencies of all repeats are merged exactly (per-request latencies, timeouts = inf) and the
//     probe passes iff the nearest-rank SLO percentile of the merged set <= SLO AND no repeat failed for a reason
//     other than latency (saturated queue cap, SLO stream falling behind, errors/timeouts, streams exhausted): pooling
//     only replaces the per-repeat latency judgement, never the throughput/error checks.
//   --confirm-min-samples K (> 0): a probe whose merged SLO-stream count (measured requests, sent) is < K gets the
//     verdict "insufficient samples" under BOTH rules; the search treats it as not passing (like a fail).
enum ProbeVerdict { kVerdictFail = 0, kVerdictPass = 1, kVerdictInsufficient = 2 };
inline const char *verdict_name(int v) {
  return v == kVerdictPass ? "pass" : v == kVerdictInsufficient ? "insufficient samples" : "fail";
}

// nearest-rank percentile (same definition as the engine's per-step percentiles); 0 for an empty set
inline double nearest_rank(std::vector<double> v, double p) {
  if (v.empty()) return 0.0;
  double rank = std::ceil(p / 100 * double(v.size()));
  size_t k = rank < 1 ? 0 : std::min(v.size() - 1, size_t(rank) - 1);
  std::nth_element(v.begin(), v.begin() + k, v.end());
  return v[k];
}

struct RepeatInput {
  bool pass = false;           // the engine's verdict of the repeat alone
  bool nonlatency_fail = false;  // failed for a reason other than the SLO percentile
  std::vector<double> lat;     // SLO-stream latencies (ms) of the measured requests, inf = timeout
};

struct ProbeJudgement {
  uint32_t reps = 0, fails = 0, nonlatency_fails = 0;
  uint64_t n = 0;                          // merged SLO-stream count
  double pooled_pslo = 0, pooled_p99 = 0;  // ms, over the merged latencies
  int majority = kVerdictFail, pooled = kVerdictFail;
};

inline ProbeJudgement judge_probe(const std::vector<RepeatInput> &reps, double slo_pct, double slo_ms,
                                  uint64_t min_samples) {
  ProbeJudgement j;
  std::vector<double> all;
  for (auto &r : reps) {
    j.reps++, j.fails += !r.pass, j.nonlatency_fails += r.nonlatency_fail;
    all.insert(all.end(), r.lat.begin(), r.lat.end());
  }
  j.n = all.size();
  j.pooled_pslo = nearest_rank(all, slo_pct);
  j.pooled_p99 = nearest_rank(all, 99);
  j.majority = 2 * j.fails <= j.reps ? kVerdictPass : kVerdictFail;
  j.pooled = (!all.empty() && j.pooled_pslo <= slo_ms && j.nonlatency_fails == 0) ? kVerdictPass : kVerdictFail;
  if (min_samples > 0 && j.n < min_samples) j.majority = j.pooled = kVerdictInsufficient;
  return j;
}

// What a rule would have concluded from the probes that were run: confirm_search driven by the recorded verdicts
// (offered rate -> verdict). The first candidate with no recorded probe stops the replay: complete = false and
// unrun_offered/unrun_role name the probe that would have been needed.
struct RuleReplay {
  ConfirmOutcome o;
  bool complete = true;
  double unrun_offered = 0;
  std::string unrun_role;
};
inline RuleReplay replay_rule(double good, const std::vector<double> &passes, double step_down,
                              double confirm_precision, uint32_t max_probes,
                              const std::vector<std::pair<double, int>> &recorded) {
  RuleReplay rr;
  rr.o = confirm_search(good, passes, step_down, confirm_precision, max_probes, [&](double x, const char *role) {
    for (auto &p : recorded)
      if (std::fabs(p.first - x) <= 1e-9 * std::max(1.0, std::fabs(x))) return p.second == kVerdictPass ? 1 : 0;
    rr.complete = false, rr.unrun_offered = x, rr.unrun_role = role;
    return -1;
  });
  return rr;
}

// Knee ramp (--ramp-knee K, opt-in; RecSys methodology, user decisions 2026-10-19, state/PROJECT.md): a failed ramp
// step does not end the ramp by itself. Reason: when updates arrive at an absolute rate, a query at a LOW rate absorbs
// every invalidation since the previous one, so tail latency can be worst at low load and fall as the load rises.
// Stop rule (when to stop ramping): (a) a hard saturation (the queue cap aborted the step), or (b) after a pass, the SLO
// stream falls behind, or (c) after a pass, K consecutive failed steps whose SLO percentile rose by >= `rise` x the
// previous step's (queueing past the knee; low-rate failures have a flat or falling percentile) AND the stopping
// step's percentile is above `floor` (user decision 2026-10-19, verifier MED-2 option (c): 1.5 x SLO, so two
// chance rises of low-rate failures just above the SLO never end the ramp).
// Bracket (independent of the stop rule): knee = the first step of the final run of failed steps (every ramp step at
// or above it failed), good = the last pass before it = the highest pass below the knee (definition (가)).
// Failed steps below `good` are the low-rate violations (reported).
class KneeRamp {
 public:
  KneeRamp(uint32_t k, double rise, double floor = 0) : k_(k), rise_(rise), floor_(floor) {}
  // after each ramp step; true = stop ramping (good()/knee() are the bracket; good() == 0: no pass below the knee)
  bool add(double x, bool pass, bool hard, bool behind, double pslo) {
    const bool prev_pass = n_ == 0 || last_pass_;
    n_++, last_pass_ = pass;
    const double prev = prev_p_;
    prev_p_ = pslo;
    if (pass) {
      good_ = x, run_ = 0, knee_ = 0;
      return false;
    }
    if (prev_pass) knee_ = x;  // first fail after a pass (or the first step): start of the failing run
    if (hard) return why_ = "saturated (queue cap)", true;
    if (good_ > 0 && behind) return why_ = "saturated (SLO stream falls behind)", true;
    if (good_ > 0 && prev > 0 && pslo >= rise_ * prev) run_++;  // inf >= anything: counts as rising
    else run_ = 0;
    if (good_ > 0 && run_ >= k_ && pslo > floor_) return why_ = "percentile rising", true;
    return false;
  }
  double good() const { return good_; }
  double knee() const { return knee_; }  // 0 while the last step passed
  bool any_pass() const { return good_ > 0; }
  const char *why() const { return why_; }

 private:
  uint32_t k_, run_ = 0, n_ = 0;
  double rise_, floor_, good_ = 0, knee_ = 0, prev_p_ = 0;
  bool last_pass_ = false;
  const char *why_ = "";
};

}  // namespace loadgen

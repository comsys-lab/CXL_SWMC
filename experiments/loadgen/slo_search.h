// Confirm phase of the max-throughput-under-SLO search (loadgen --mode slo, README "Max throughput under SLO").
// Kept apart from the engine so test/slo_search_test.cc drives it with a synthetic confirm oracle (no server).
//
// Input: `good` = the best ramp/bisect pass (one short step), `passes` = every ramp/bisect pass (unconfirmed), and a
// confirm callback (one confirm = confirm_reps x confirm_s, majority rule; 1 pass, 0 fail, -1 streams exhausted).
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

}  // namespace loadgen

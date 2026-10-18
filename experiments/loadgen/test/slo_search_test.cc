// Unit test of the confirm phase (slo_search.h) with a synthetic oracle: a confirm passes iff x <= knee.
// build + run (Host, no server): c++ -std=c++17 -O2 -Wall -Wextra -I.. slo_search_test.cc -o /tmp/t && /tmp/t
// Prints "SLO SEARCH TEST PASS" or the first failing check (exit 1).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "slo_search.h"

using loadgen::ConfirmOutcome;
using loadgen::confirm_search;

static int fails = 0;
static void check(bool ok, const std::string &what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
  fails += !ok;
}

struct Oracle {
  explicit Oracle(double k) : knee(k) {}
  double knee;
  std::vector<std::string> log;
  int operator()(double x, const char *role) {
    log.push_back(std::string(role) + "@" + std::to_string(int(std::lround(x))));
    return x <= knee ? 1 : 0;
  }
};

// defaults = loadgen's (H1 v0.6.5): --max-confirm-probes 6, --confirm-step-down 0.05, --confirm-precision 0.01
static ConfirmOutcome go(Oracle &o, double good, std::vector<double> passes, uint32_t max_probes = 6,
                         double step_down = 0.05, double cp = 0.01) {
  return confirm_search(good, passes, step_down, cp, max_probes, [&](double x, const char *r) { return o(x, r); });
}

// v0.6.5 rule: while nothing is confirmed, every candidate after a failed confirm f lies at or above f / (1 + sd)
// (a ramp/bisect pass is taken only if it is that close); returns false on the first violation
static bool steps_bounded(const ConfirmOutcome &r, double sd) {
  double f = 0;
  for (auto &p : r.probes) {
    if (f > 0 && p.role != "bisect" && p.offered < f / (1 + sd) * (1 - 1e-12)) return false;
    if (p.pass) break;
    f = p.offered;
  }
  return true;
}

static std::string br(const ConfirmOutcome &r) {
  return "[" + std::to_string(int(std::lround(r.best))) + ", " + std::to_string(int(std::lround(r.lo_fail))) +
         "] rel " + std::to_string(r.best > 0 ? r.lo_fail / r.best - 1 : -1) + ", " +
         std::to_string(r.probes.size() - 1) + " probes";
}

int main() {
  {  // 1. the first confirm passes: no probes, result = good
    Oracle o(100000);
    auto r = go(o, 92500, {40000, 60000, 84000, 92500});
    check(r.confirmed && r.best == 92500 && r.probes.size() == 1 && r.finish == "first confirm passed",
          "first confirm passes -> result good, 1 confirm");
  }
  {  // 2. mg-u50 r1 shape: good 92.5k fails its confirm, knee 90k; lower pass 88.1k confirmed, then bisect to 1 %
    Oracle o(90000);
    auto r = go(o, 92500, {40000, 60000, 84000, 88100, 92500});
    double hi = r.lo_fail;
    check(r.confirmed && r.best <= 90000 && hi > 90000 && hi / r.best <= 1.01 + 1e-12,
          "knee 90k between 88.1k and 92.5k -> bracket [" + std::to_string(r.best) + ", " + std::to_string(hi) +
              "] within 1 %");
    check(r.probes.size() >= 3 && r.probes[1].role == "lower" && r.probes[1].offered == 88100 &&
              r.probes[2].role == "bisect",
          "probe order first, lower@88100, bisect...");
    check(r.finish == "bracket within confirm precision", "finish = " + r.finish);
    check(r.best > 88100, "result above the old step-down rate 88.1k (" + std::to_string(r.best) + ")");
  }
  {  // 3. the nearest lower candidate also fails: step down from it by 5 % (not to the far pass 76k), then bisect
    Oracle o(80000);
    auto r = go(o, 92500, {40000, 60000, 76000, 88100, 92500});
    check(r.confirmed && r.probes[1].offered == 88100 && !r.probes[1].pass && r.probes[2].role == "step-down" &&
              std::fabs(r.probes[2].offered - 88100 / 1.05) < 1e-6 && !r.probes[2].pass &&
              r.probes[3].role == "step-down" && r.probes[3].pass && r.best <= 80000 && r.lo_fail > 80000 &&
              r.lo_fail / r.best <= 1.02 && steps_bounded(r, 0.05),
          "lower 88.1k fails -> step-downs 83.9k (fail), 79.9k (pass), bracket around 80k " + br(r));
  }
  {  // 4. no candidates below good: step-down by --confirm-step-down, then bisect
    Oracle o(91000);
    auto r = go(o, 92500, {92500});
    check(r.probes.size() >= 2 && r.probes[1].role == "step-down" &&
              std::fabs(r.probes[1].offered - 92500 / 1.05) < 1e-6 && r.confirmed && r.best <= 91000,
          "no lower pass -> step-down 92500/1.05 confirmed (" + std::to_string(r.best) + ")");
    Oracle o2(91000);
    auto r2 = go(o2, 92500, {92500}, 6, 0.02);
    check(r2.probes.size() >= 2 && std::fabs(r2.probes[1].offered - 92500 / 1.02) < 1e-6 && r2.confirmed &&
              r2.best <= 91000 && r2.lo_fail / r2.best <= 1.01 + 1e-12,
          "--confirm-step-down 0.02 -> step-down 92500/1.02 " + br(r2));
  }
  {  // 5. probe limit: a confirmed result, bracket wider than 1 %
    Oracle o(90000);
    auto r = go(o, 92500, {40000, 60000, 84000, 92500}, 2);
    check(r.confirmed && r.probes.size() == 3 && r.finish.rfind("probe limit", 0) == 0 && r.best >= 84000 &&
              r.lo_fail / r.best > 1.01,
          "max 2 probes -> confirmed result, finish '" + r.finish + "'");
  }
  {  // 6. nothing confirms: no confirmed pass, every probe failed at a distinct lower rate (>= 3 rates)
    Oracle o(1000);
    auto r = go(o, 92500, {40000, 60000, 84000, 92500}, 5);
    bool distinct = true;
    for (size_t k = 1; k < r.probes.size(); k++) distinct &= r.probes[k].offered < r.probes[k - 1].offered;
    check(!r.confirmed && r.best == 0 && r.probes.size() == 6 && distinct && r.lo_fail == r.probes.back().offered &&
              r.finish == "no confirmed pass in 5 probes",
          "no pass -> 6 failed confirms at falling rates, lowest " + std::to_string(r.lo_fail) + ", finish '" +
              r.finish + "'");
  }
  {  // 8. LMDB hw-u50 r1 shape (H1-main-v1): ramp passes up to 146.0k and 160.6k, bisect fails 162.5k+, first confirm
     // 160.6k fails, 146.0k fails (2/3). v0.6.3 then jumped to the ramp pass 64.9k and ended at the probe limit with
     // bracket [131.9k, 146.0k] (10.7 %). v0.6.5: 152.9k (step-down), 146.0k (nearest pass), 139.0k, ... The true
     // knee is unknown (131.9k passed, 146.0k failed): try 133k, 140k, 145k.
    const std::vector<double> ramp = {500, 1125, 2531.2, 5695.3, 12814.5, 28832.5, 64873.2, 145964.6, 160561.1};
    for (double knee : {133000.0, 140000.0, 145000.0}) {
      Oracle o(knee);
      auto r = go(o, 160561.1, ramp);
      bool far = false;
      for (auto &p : r.probes) far |= p.offered < 100000;
      check(r.confirmed && r.best <= knee && r.lo_fail > knee && r.lo_fail / r.best <= 1.02 && r.probes.size() <= 7 &&
                r.probes[1].role == "step-down" && r.probes[2].offered == 145964.6 && !far && steps_bounded(r, 0.05),
            "LMDB hw-u50 shape, knee " + std::to_string(int(knee)) + " -> " + br(r) + ", no probe near 64.9k");
    }
  }
  {  // 9. KV mg-u50 r1 shape: first confirm 92.5k fails; knee 91.9k (KV-MG-U50-GAP: 91.4k 3/3, 92.5k 0/3)
    Oracle o(91900);
    auto r = go(o, 92500.7, {500, 1125, 2531.2, 5695.3, 12814.5, 28832.5, 64873.2, 88095.9, 92500.7});
    check(r.confirmed && r.best <= 91900 && r.best >= 91000 && r.lo_fail / r.best <= 1.01 + 1e-12 &&
              r.probes.size() <= 7 && r.finish == "bracket within confirm precision" && steps_bounded(r, 0.05),
          "KV mg-u50 shape, knee 91.9k -> " + br(r));
  }
  {  // 10. sweep: LMDB shape with knees from 0.5 x to 1 x good: the step bound always holds; a knee within three
      // 5 % steps of the first fail (>= good / 1.05^3) is always confirmed to <= 2 % inside the 6 probes
    const std::vector<double> ramp = {500, 1125, 2531.2, 5695.3, 12814.5, 28832.5, 64873.2, 145964.6, 160561.1};
    bool ok = true;
    std::string first_bad;
    for (int i = 0; i <= 500; i++) {
      double knee = 160561.1 * (0.5 + 0.5 * i / 500.0) - 0.5;
      Oracle o(knee);
      auto r = go(o, 160561.1, ramp);
      bool good = steps_bounded(r, 0.05) && r.probes.size() <= 7;
      if (knee >= 160561.1 / std::pow(1.05, 3)) good &= r.confirmed && r.lo_fail / r.best <= 1.02;
      if (r.confirmed) good &= r.best <= knee && (r.lo_fail == 0 || r.lo_fail > knee);
      if (!good && first_bad.empty()) first_bad = std::to_string(int(knee)) + " " + br(r);
      ok &= good;
    }
    check(ok, "knee sweep 80k..160k: step bound, <= 6 probes, <= 2 % when knee >= good/1.05^3" +
                  (first_bad.empty() ? std::string() : " (first bad knee " + first_bad + ")"));
  }
  {  // 7. exhausted streams stop the search
    int n = 0;
    auto r = confirm_search(92500, {84000}, 0.02, 0.01, 5, [&](double, const char *) { return n++ ? -1 : 0; });
    check(r.exhausted && r.probes.size() == 1, "exhausted during the second confirm -> exhausted, 1 probe recorded");
  }
  {  // 8. KneeRamp (--ramp-knee 2, rise 1.2): low-rate failures do not end the ramp; bracket = final failing run
    struct St { double x; bool pass, hard, behind; double p; };
    auto feed = [](std::vector<St> v, double *good, double *knee, std::string *why) {
      loadgen::KneeRamp kr(2, 1.2, 150);  // floor 1.5 x SLO 100 ms (user decision (c))
      int at = -1;
      for (size_t i = 0; i < v.size(); i++)
        if (kr.add(v[i].x, v[i].pass, v[i].hard, v[i].behind, v[i].p)) { at = int(i); break; }
      *good = kr.good(), *knee = kr.knee(), *why = kr.why();
      return at;
    };
    double g, kn;
    std::string why;
    // H2 pattern (verifier HIGH-1): pass at 1, flat/noisy low-rate fails, passes, then the real knee
    int at = feed({{1, 1, 0, 0, 90}, {1.5, 0, 0, 0, 130}, {2.25, 0, 0, 0, 131}, {3.4, 0, 0, 0, 128}, {5.1, 0, 0, 0, 120},
                   {7.6, 0, 0, 0, 104}, {11.4, 1, 0, 0, 95}, {17, 1, 0, 0, 70}, {25.6, 1, 0, 0, 80}, {38, 1, 0, 0, 92},
                   {42, 0, 0, 0, 125}, {63, 0, 0, 0, 400}}, &g, &kn, &why);
    check(at == 11 && g == 38 && kn == 42 && why == "percentile rising",
          "H2 pattern: flat low-rate fails (130, 131, 128) do not stop; knee 42 after rises 92->125->400 (good 38)");
    at = feed({{1, 0, 0, 0, 130}, {1.5, 0, 0, 0, 160}, {2.25, 0, 0, 0, 200}, {3.4, 1, 0, 0, 90}, {5, 0, 0, 0, 150}, {7.5, 0, 0, 0, 300}}, &g, &kn, &why);
    check(at == 5 && g == 3.4 && kn == 5, "rising fails before the first pass never stop; after a pass they do");
    at = feed({{1, 1, 0, 0, 50}, {2, 0, 1, 0, 500}}, &g, &kn, &why);
    check(at == 1 && g == 1 && kn == 2 && why == "saturated (queue cap)", "queue-cap abort ends the ramp at once");
    at = feed({{1, 0, 0, 1, 500}, {1.5, 1, 0, 0, 80}, {2.25, 0, 0, 1, 90}}, &g, &kn, &why);
    check(at == 2 && g == 1.5 && kn == 2.25, "falling behind ends the ramp only after a pass");
    at = feed({{1, 0, 1, 0, 500}}, &g, &kn, &why);
    check(at == 0 && g == 0, "queue-cap abort before any pass: stop, no pass below the knee");
    at = feed({{1, 1, 0, 0, 50}, {1.5, 0, 0, 0, 101}, {2.25, 0, 0, 0, 100}, {3.4, 1, 0, 0, 80}, {5, 0, 0, 0, 120},
               {7.5, 0, 0, 0, 1.0 / 0.0}}, &g, &kn, &why);
    check(at == 5 && g == 3.4 && kn == 5, "a pass resets the run; inf percentile counts as rising");
    at = feed({{1, 1, 0, 0, 50}, {1.5, 0, 0, 0, 110}, {2.25, 0, 0, 0, 115}, {3.4, 0, 0, 0, 112}}, &g, &kn, &why);
    check(at == -1 && g == 1 && kn == 1.5, "no stop yet: bracket = last pass 1 / first fail of the final run 1.5");
    // verifier MED-2 probe: one marginal pass, two chance rises of low-rate fails (115, 140 ms <= 150): no stop;
    // the ramp goes on to the real knee (rises 90 -> 130 -> 220 ms > 150)
    at = feed({{1, 1, 0, 0, 95}, {1.5, 0, 0, 0, 115}, {2.25, 0, 0, 0, 140}, {3.4, 0, 0, 0, 120}, {5.1, 1, 0, 0, 85},
               {11, 1, 0, 0, 70}, {25, 1, 0, 0, 90}, {30, 0, 0, 0, 130}, {36, 0, 0, 0, 220}}, &g, &kn, &why);
    check(at == 8 && g == 25 && kn == 30 && why == "percentile rising",
          "MED-2 probe: rises 95->115->140 below 1.5 x SLO do not stop; knee 30 after 90->130->220 (good 25)");
    at = feed({{1, 1, 0, 0, 80}, {2, 0, 0, 0, 110}, {3, 0, 0, 0, 140}, {4, 0, 0, 0, 170}}, &g, &kn, &why);
    check(at == 3 && kn == 2, "rising run continues past the floor: stop at the first step above 150 ms, knee 2");
  }
  std::printf(fails ? "SLO SEARCH TEST FAIL (%d)\n" : "SLO SEARCH TEST PASS\n", fails);
  return fails ? 1 : 0;
}

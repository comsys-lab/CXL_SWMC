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

static ConfirmOutcome go(Oracle &o, double good, std::vector<double> passes, uint32_t max_probes = 5,
                         double prec = 0.02, double cp = 0.01) {
  return confirm_search(good, passes, prec, cp, max_probes, [&](double x, const char *r) { return o(x, r); });
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
  {  // 3. the highest lower candidate also fails: next candidate down, then bisect
    Oracle o(80000);
    auto r = go(o, 92500, {40000, 60000, 76000, 88100, 92500});
    check(r.confirmed && r.probes[1].offered == 88100 && !r.probes[1].pass && r.probes[2].offered == 76000 &&
              r.probes[2].pass && r.best <= 80000 && r.lo_fail > 80000,
          "lower candidate 88.1k fails -> 76k confirmed, bracket around 80k (" + std::to_string(r.best) + ", " +
              std::to_string(r.lo_fail) + ")");
  }
  {  // 4. no candidates below good: step-down by the bisect precision, then bisect
    Oracle o(91000);
    auto r = go(o, 92500, {92500});
    check(r.probes.size() >= 2 && r.probes[1].role == "step-down" &&
              std::fabs(r.probes[1].offered - 92500 / 1.02) < 1e-6 && r.confirmed && r.best <= 91000,
          "no lower pass -> step-down 92500/1.02 confirmed (" + std::to_string(r.best) + ")");
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
  {  // 7. exhausted streams stop the search
    int n = 0;
    auto r = confirm_search(92500, {84000}, 0.02, 0.01, 5, [&](double, const char *) { return n++ ? -1 : 0; });
    check(r.exhausted && r.probes.size() == 1, "exhausted during the second confirm -> exhausted, 1 probe recorded");
  }
  std::printf(fails ? "SLO SEARCH TEST FAIL (%d)\n" : "SLO SEARCH TEST PASS\n", fails);
  return fails ? 1 : 0;
}

// Unit test of the confirm rules (slo_search.h judge_probe, replay_rule; loadgen --confirm-rule, 2026-10-21).
// build + run (Host, no server): c++ -std=c++17 -O2 -Wall -Wextra -I.. confirm_rule_test.cc -o /tmp/t && /tmp/t
// Prints "CONFIRM RULE TEST PASS" or the failing checks (exit 1).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "slo_search.h"

using namespace loadgen;

static int fails = 0;
static void check(bool ok, const std::string &what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
  fails += !ok;
}

// n latencies whose nearest-rank p99 is exactly p99: the top (n - ceil(0.99 n)) values = tail, `over` body values in
// (slo, p99) when p99 > slo (else none), the rest below min(p99, slo); body max = p99
static std::vector<double> rep_lat(size_t n, double p99, double tail, size_t over, double slo = 100) {
  const size_t k = size_t(std::ceil(0.99 * double(n)));  // rank of the p99 (1-based)
  std::vector<double> v;
  for (size_t i = 0; i + 1 < k; i++) {
    if (p99 > slo && i < over) v.push_back(slo + (p99 - slo) * double(i + 1) / double(over + 1));
    else v.push_back(std::min(p99, slo) * 0.5 * (1 + double(i % 97) / 97.0));
  }
  v.push_back(p99);
  while (v.size() < n) v.push_back(tail);
  std::reverse(v.begin(), v.end());  // order must not matter
  return v;
}

static double sorted_rank(std::vector<double> v, double p) {  // independent nearest rank: full sort
  std::sort(v.begin(), v.end());
  size_t k = size_t(std::ceil(p / 100 * double(v.size())));
  return v[std::max<size_t>(k, 1) - 1];
}

static RepeatInput rep(std::vector<double> lat, double slo = 100, bool nonlat = false) {
  RepeatInput r;
  r.lat = std::move(lat);
  r.pass = !nonlat && nearest_rank(r.lat, 99) <= slo;
  r.nonlatency_fail = nonlat;
  return r;
}

int main() {
  {  // 1. crafted case from the task: repeats p99 93 / 85 / 171 ms, counts 6144 / 6101 / 951 (third stopped early)
    std::vector<RepeatInput> in = {rep(rep_lat(6144, 93, 97, 0)), rep(rep_lat(6101, 85, 99, 0)),
                                   rep(rep_lat(951, 171, 400, 40))};
    check(nearest_rank(in[0].lat, 99) == 93 && nearest_rank(in[1].lat, 99) == 85 && nearest_rank(in[2].lat, 99) == 171,
          "crafted repeats have p99 93 / 85 / 171");
    auto j = judge_probe(in, 99, 100, 0);
    std::vector<double> all;
    for (auto &r : in) all.insert(all.end(), r.lat.begin(), r.lat.end());
    const double want = sorted_rank(all, 99);
    // above 100 ms: 9 tail + 40 body of rep 3 = 49 < 13196 - ceil(0.99 x 13196) + 1 = 132 -> pooled p99 <= 100
    check(j.n == 13196 && j.pooled_pslo == want && j.pooled_p99 == want && want <= 100,
          "pooled n 13196, pooled p99 " + std::to_string(j.pooled_pslo) + " == full-sort p99 " + std::to_string(want));
    check(j.fails == 1 && j.majority == kVerdictPass && j.pooled == kVerdictPass,
          "93/85/171: majority pass (1 fail of 3), pooled pass");
    auto k = judge_probe(in, 99, 100, 20000);
    check(k.majority == kVerdictInsufficient && k.pooled == kVerdictInsufficient &&
              std::string(verdict_name(k.pooled)) == "insufficient samples",
          "--confirm-min-samples 20000 > 13196 -> insufficient samples under both rules");
    auto k2 = judge_probe(in, 99, 100, 13196);
    check(k2.majority == kVerdictPass && k2.pooled == kVerdictPass, "--confirm-min-samples 13196 == n -> judged");
  }
  {  // 2. majority fail, pooled pass: 93 / 105 / 171 with few samples above the SLO overall
    std::vector<RepeatInput> in = {rep(rep_lat(6144, 93, 97, 0)), rep(rep_lat(6101, 105, 106, 3)),
                                   rep(rep_lat(951, 171, 400, 40))};
    auto j = judge_probe(in, 99, 100, 0);
    std::vector<double> all;
    for (auto &r : in) all.insert(all.end(), r.lat.begin(), r.lat.end());
    check(j.fails == 2 && j.majority == kVerdictFail && j.pooled == kVerdictPass && j.pooled_pslo == sorted_rank(all, 99),
          "93/105/171: majority fail (2 of 3), pooled pass (p99 " + std::to_string(j.pooled_pslo) + ")");
  }
  {  // 3. majority pass, pooled fail: one long repeat with 5 % of its requests above the SLO
    std::vector<RepeatInput> in = {rep(rep_lat(951, 50, 60, 0)), rep(rep_lat(6000, 99, 99.5, 0)),
                                   rep(rep_lat(6000, 300, 500, 300))};
    auto j = judge_probe(in, 99, 100, 0);
    check(j.fails == 1 && j.majority == kVerdictPass && j.pooled == kVerdictFail && j.pooled_pslo > 100,
          "50/99/300: majority pass, pooled fail (p99 " + std::to_string(j.pooled_pslo) + ")");
  }
  {  // 4. a non-latency failure (falling behind, saturation, errors) fails the pooled verdict whatever the latencies
    std::vector<RepeatInput> in = {rep(rep_lat(6000, 50, 60, 0)), rep(rep_lat(6000, 50, 60, 0)),
                                   rep(rep_lat(6000, 50, 60, 0), 100, true)};
    auto j = judge_probe(in, 99, 100, 0);
    check(j.majority == kVerdictPass && j.pooled == kVerdictFail && j.nonlatency_fails == 1,
          "low latencies + one falling-behind repeat: majority pass, pooled fail");
    std::vector<double> to(1000, 50.0);
    std::fill(to.begin(), to.begin() + 30, INFINITY);  // 30 timeouts: 1.5 % of the merged 2000
    std::vector<RepeatInput> inf = {rep(rep_lat(1000, 50, 60, 0)), rep(to)};
    auto ji = judge_probe(inf, 99, 100, 0);
    check(ji.pooled == kVerdictFail && std::isinf(ji.pooled_pslo), "timeouts (inf) above 1 % -> pooled p99 inf, fail");
    auto je = judge_probe({}, 99, 100, 0);
    check(je.pooled == kVerdictFail, "no samples -> pooled fail");
  }
  {  // 5. majority unchanged: with --confirm-min-samples 0, pass iff 2 * fails <= reps, for every pattern up to 7 reps
    bool ok = true;
    for (uint32_t reps = 1; reps <= 7; reps++)
      for (uint32_t mask = 0; mask < (1u << reps); mask++) {
        std::vector<RepeatInput> in;
        uint32_t f = 0;
        for (uint32_t q = 0; q < reps; q++) {
          bool bad = mask >> q & 1;
          f += bad;
          RepeatInput r;
          r.pass = !bad, r.lat = {bad ? 150.0 : 50.0};
          in.push_back(r);
        }
        auto j = judge_probe(in, 99, 100, 0);
        ok &= (j.majority == kVerdictPass) == (2 * f <= reps) && j.fails == f;
      }
    check(ok, "majority verdict == (2 x fails <= reps) for all 254 fail patterns of 1..7 repeats");
  }
  {  // 6. replay of the other rule on the probes a majority search ran
    // majority search with knee 92.5: record its probes, then give them pooled verdicts (pass iff x <= 97)
    std::vector<double> passes = {50, 90, 100};
    std::vector<std::pair<double, int>> maj;
    auto o = confirm_search(100, passes, 0.05, 0.01, 6, [&](double x, const char *) {
      int v = x <= 92.5 ? 1 : 0;
      maj.push_back({x, v});
      return v;
    });
    auto same = replay_rule(100, passes, 0.05, 0.01, 6, maj);
    bool eq = same.complete && same.o.best == o.best && same.o.lo_fail == o.lo_fail && same.o.finish == o.finish &&
              same.o.probes.size() == o.probes.size();
    check(eq, "replaying the followed rule's own verdicts reproduces the search (best " + std::to_string(o.best) + ")");
    std::vector<std::pair<double, int>> pooled;
    for (auto &p : maj) pooled.push_back({p.first, p.first <= 97 ? kVerdictPass : kVerdictFail});
    auto rp = replay_rule(100, passes, 0.05, 0.01, 6, pooled);
    // majority ran 100 F, 95.24 F (step-down 100/1.05), 90.70 P (step-down), bisects ...; pooled: 100 fail,
    // 95.24 pass (recorded), next bisect sqrt(95.24 x 100) = 97.59 was never run
    check(!rp.complete && std::fabs(rp.unrun_offered - std::sqrt(100 / 1.05 * 100)) < 1e-9 &&
              rp.unrun_role == "bisect" && rp.o.exhausted && rp.o.probes.size() == 2,
          "pooled replay needs the unrun probe " + std::to_string(rp.unrun_offered) + " (" + rp.unrun_role + ")");
    std::vector<std::pair<double, int>> first = pooled;
    first[0].second = kVerdictPass;
    auto rf = replay_rule(100, passes, 0.05, 0.01, 6, first);
    check(rf.complete && rf.o.confirmed && rf.o.best == 100 && rf.o.finish == "first confirm passed",
          "other rule passes the first probe -> complete, result 100");
    std::vector<std::pair<double, int>> ins = maj;
    for (auto &p : ins) p.second = p.second == 1 ? kVerdictInsufficient : 0;
    auto ri = replay_rule(100, passes, 0.05, 0.01, 6, ins);
    check(!ri.o.confirmed, "insufficient samples never confirm a rate (replay treats them as not passing)");
  }
  std::printf(fails ? "CONFIRM RULE TEST FAIL (%d)\n" : "CONFIRM RULE TEST PASS\n", fails);
  return fails ? 1 : 0;
}

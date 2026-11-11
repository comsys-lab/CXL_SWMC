// Unit test of the step drain and clean-start rule (drain.h, loadgen --drain-full-s) with a fake clock and a fake
// server backlog (no server, no network).
// build + run (Host): c++ -std=c++17 -O2 -Wall -Wextra -I.. drain_test.cc -o /tmp/t && /tmp/t
// Prints "DRAIN TEST PASS" or lists the failing checks (exit 1).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "drain.h"
#include "slo_search.h"

using namespace loadgen;

static int fails = 0, checks = 0;
static void check(bool ok, const std::string &what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
  fails += !ok, checks++;
}

// fake server: `backlog` requests outstanding, served at mu per second; nap() = 1 ms of fake time
struct Server {
  uint64_t t = 0;  // ns
  double backlog = 0, mu = 0;
  uint64_t naps = 0;
  uint64_t out() const { return uint64_t(std::ceil(backlog - 1e-6)); }
  void nap() {
    t += 1000000, naps++;
    backlog = std::max(0.0, backlog - mu * 1e-3);
  }
};

// the drain loop of loadgen.cc at fda627089 (before --drain-full-s), verbatim apart from the fake clock
static void old_drain(Server &s, uint64_t send_end, double drain_s, uint64_t out_base) {
  const uint64_t drain_until = send_end + uint64_t(drain_s * 1e9);
  while (s.out() > out_base && s.t < drain_until) s.nap();
}

static DrainResult new_drain(Server &s, uint64_t send_end, double drain_s, double full, uint64_t out_base) {
  return drain_step(send_end, drain_s, full, out_base, [&] { return s.out(); }, [&] { return s.t; }, [&] { s.nap(); });
}

// fake engine step for the search test: offered rate x for 15 s; the server keeps up iff x <= mu; a step passes iff
// x <= knee and nothing was outstanding at its start (a backlog of an earlier step makes its latencies inf: the bug)
struct Res {
  bool pass = false, judged = true, exhausted = false, contaminated = false, drain_fail = false;
  double x = 0, wait_s = 0;
  int64_t rerun_of = -1;
  uint64_t at_start = 0, after = 0;
  int step_no = 0;
};
struct Sim {
  Server s;
  double knee, drain_s, full;
  double fail_s = 0;  // --drain-fail-s
  int step_no = 0;
  std::vector<Res> log;
  Res once(double x, bool rerun, int64_t rerun_of) {
    Res r;
    r.x = x, r.step_no = step_no++, r.rerun_of = rerun_of;
    const uint64_t out_base = s.out();
    r.at_start = out_base;
    r.judged = step_judged(full, out_base, rerun, true);
    r.contaminated = full > 0 && out_base > 0;
    s.t += 18000000000ull;  // 3 s warmup + 15 s measure
    s.backlog = std::max(0.0, s.backlog + (x - s.mu) * 18);
    // latency judgement only (the fake server's latency is fine up to the knee); the drain check below as loadgen.cc
    r.pass = r.judged && out_base == 0 && x <= knee;
    DrainResult dr = new_drain(s, s.t, drain_s, full, out_base);
    r.after = dr.outstanding_after, r.wait_s = dr.wait_s;
    r.drain_fail = drain_failed(full, fail_s, dr.wait_s, true);
    if (r.drain_fail) r.pass = false;
    log.push_back(r);
    return r;
  }
  Res step(double x) {  // mirrors Engine::step
    int64_t first = -1;
    return clean_step([&](bool rerun) {
      Res r = once(x, rerun, rerun ? first : -1);
      if (!rerun) first = r.step_no;
      return r;
    });
  }
  // ramp x2 until a fail, then geometric bisection to 5 % (the engine's ramp/bisect skeleton)
  std::vector<std::pair<double, bool>> search(double start) {
    std::vector<std::pair<double, bool>> d;  // decisions the search saw
    double good = 0, bad = 0, r = start;
    for (int n = 0; n < 20; n++) {
      Res q = step(r);
      d.push_back({r, q.pass});
      if (!q.pass) { bad = r; break; }
      good = r, r *= 2;
    }
    while (good > 0 && bad > 0 && bad / good > 1.05) {
      double m = std::sqrt(good * bad);
      Res q = step(m);
      d.push_back({m, q.pass});
      (q.pass ? good : bad) = m;
    }
    return d;
  }
};

int main() {
  {  // 1. default off (--drain-full-s 0): drain_step is the old loop (same end time, same naps) on random cases
    std::mt19937_64 g(20261112);
    bool same = true;
    for (int k = 0; k < 2000 && same; k++) {
      Server a, b;
      a.t = b.t = 1000000000ull + g() % 1000000000ull;
      a.mu = b.mu = double(g() % 400);
      a.backlog = b.backlog = double(g() % 3000);
      const uint64_t base = g() % 2 ? 0 : g() % 2000;
      const double ds = double(g() % 8);
      const uint64_t se = a.t;
      old_drain(a, se, ds, base);
      DrainResult r = new_drain(b, se, ds, 0, base);
      same = a.t == b.t && a.naps == b.naps && a.out() == b.out() && r.outstanding_after == b.out() &&
             std::fabs(r.wait_s - double(b.t - se) / 1e9) < 1e-12;
    }
    check(same, "default off: drain_step == the fda627089 drain loop on 2000 random cases");
  }
  {  // 2. full drain waits for every outstanding request (also leftovers below out_base), capped
    Server s;
    s.t = 5000000000ull, s.mu = 10, s.backlog = 500;  // 50 s of work
    DrainResult r = new_drain(s, s.t, 5, 120, 0);
    check(r.outstanding_after == 0 && std::fabs(r.wait_s - 50) < 0.01,
          "full drain (cap 120 s): waits 50 s until outstanding 0 (wait " + std::to_string(r.wait_s) + " s)");
    Server o;
    o.t = 5000000000ull, o.mu = 10, o.backlog = 500;
    DrainResult ro = new_drain(o, o.t, 5, 0, 0);
    check(ro.outstanding_after == 450 && std::fabs(ro.wait_s - 5) < 0.01,
          "default drain: stops at --drain-s 5 s with 450 outstanding (the bug)");
    Server c;
    c.t = 5000000000ull, c.mu = 10, c.backlog = 500;
    DrainResult rc = new_drain(c, c.t, 5, 20, 0);
    check(rc.outstanding_after == 300 && std::fabs(rc.wait_s - 20) < 0.01, "full drain: the cap (20 s) holds, 300 left");
    Server l;  // leftovers of earlier steps (out_base 100): the default ignores them, the full drain does not
    l.t = 5000000000ull, l.mu = 10, l.backlog = 150;
    DrainResult rl = new_drain(l, l.t, 30, 0, 100);
    Server f;
    f.t = 5000000000ull, f.mu = 10, f.backlog = 150;
    DrainResult rf = new_drain(f, f.t, 30, 120, 100);
    check(rl.outstanding_after == 100 && rf.outstanding_after == 0,
          "out_base leftovers: default stops at out_base, full drain waits to 0");
    Server z;
    z.t = 5000000000ull, z.mu = 10, z.backlog = 0;
    DrainResult rz = new_drain(z, z.t, 5, 120, 0);
    check(rz.wait_s == 0 && rz.outstanding_after == 0 && z.naps == 0, "full drain: nothing outstanding -> no wait");
  }
  {  // 3. step_judged
    check(step_judged(0, 0, false, true) && step_judged(0, 1000, false, true) && step_judged(0, 1000, true, true),
          "default off: every step judged, backlog or not");
    check(!step_judged(120, 1, false, true), "full on: first attempt with outstanding > 0 at start -> not judged");
    check(step_judged(120, 0, false, true), "full on: clean start -> judged");
    check(step_judged(120, 7, true, true), "full on: re-run judged even if contaminated");
    check(step_judged(120, 7, false, false), "full on: unmeasured warmup never re-run");
  }
  {  // 4. clean_step: number of attempts
    int calls = 0;
    auto mk = [&](bool judged_first, bool exhausted) {
      calls = 0;
      return [&calls, judged_first, exhausted](bool rerun) {
        calls++;
        Res r;
        r.judged = rerun || judged_first, r.exhausted = exhausted, r.pass = rerun;
        return r;
      };
    };
    Res a = clean_step(mk(true, false));
    check(calls == 1 && !a.pass, "clean_step: judged first attempt -> 1 call, its result");
    Res b = clean_step(mk(false, false));
    check(calls == 2 && b.pass && b.judged, "clean_step: unjudged first attempt -> re-run once, re-run's result");
    clean_step(mk(false, true));
    check(calls == 1, "clean_step: exhausted first attempt -> no re-run");
  }
  {  // 5. contaminated step re-run, with the fake engine (mu 6/s, knee 6/s)
    Sim m{Server{}, 6, 5, 120};
    m.s.mu = 6, m.s.backlog = 30, m.s.t = 1;  // 5 s of earlier work still queued
    Res r = m.step(4);
    check(m.log.size() == 2 && !m.log[0].judged && m.log[0].contaminated && m.log[0].at_start == 30 &&
              m.log[1].judged && !m.log[1].contaminated && m.log[1].rerun_of == m.log[0].step_no && r.pass,
          "contaminated start: attempt not judged, its drain empties the queue, re-run clean and judged (pass)");
    Sim p{Server{}, 6, 5, 2};  // cap 2 s: the attempt's drain cannot empty a 5 s backlog grown by x=7
    p.s.mu = 6, p.s.backlog = 30, p.s.t = 1;
    Res q = p.step(7);
    check(p.log.size() == 2 && !p.log[0].judged && p.log[1].judged && p.log[1].contaminated && !q.pass &&
              q.contaminated,
          "still contaminated after the cap: re-run judged as before, flag kept, no third attempt");
    Sim o{Server{}, 6, 5, 0};  // default off: no re-run even with a backlog
    o.s.mu = 6, o.s.backlog = 30, o.s.t = 1;
    Res w = o.step(4);
    check(o.log.size() == 1 && o.log[0].judged && !o.log[0].contaminated && !w.pass,
          "default off: one attempt, judged (fails on the backlog, as today)");
  }
  {  // 6. search decisions: default off reproduces the false fail after an overloaded ramp step; full drain does not
    Sim off{Server{}, 6, 5, 0};
    off.s.mu = 6, off.s.t = 1;
    auto d0 = off.search(1);
    Sim on{Server{}, 6, 5, 120};
    on.s.mu = 6, on.s.t = 1;
    auto d1 = on.search(1);
    auto str = [](const std::vector<std::pair<double, bool>> &d) {
      std::string s;
      for (auto &p : d) s += std::to_string(p.first).substr(0, 5) + (p.second ? "P " : "F ");
      return s;
    };
    std::printf("     off: %s\n     on : %s\n", str(d0).c_str(), str(d1).c_str());
    // off: ramp 1 2 4 pass, 8 fails and leaves (8-6)*18 = 36 requests minus 5 s x 6 = 6 queued -> the bisect step
    // sqrt(32) = 5.66 (below the knee) starts contaminated and fails: the bracket ends below the knee
    bool off_false_fail = d0.size() > 4 && d0[4].first < 6 && !d0[4].second;
    double good_on = 0;
    for (auto &p : d1) if (p.second) good_on = std::max(good_on, p.first);
    double good_off = 0;
    for (auto &p : d0) if (p.second) good_off = std::max(good_off, p.first);
    check(off_false_fail, "default off: bisect step below the knee after the overloaded ramp step fails (the bug)");
    check(good_on > 6 / 1.05 && good_on <= 6 && good_off < good_on,
          "full drain: best pass " + std::to_string(good_on) + " within 5 % below the knee 6 (off: " +
              std::to_string(good_off) + ")");
    bool none = true;
    for (auto &r : on.log) none &= !r.contaminated;
    check(none, "full drain (cap 120 s): no step starts contaminated, so no decision point is contaminated");
    // the search never saw an unjudged attempt: decisions = judged steps only
    size_t judged = 0;
    for (auto &r : on.log) judged += r.judged;
    check(judged == d1.size(), "full drain: decisions == judged steps");
  }
  {  // 7. --drain-fail-s: drain longer than D fails the step (non-latency), only with the full drain on
    check(!drain_failed(0, 1.0, 50, true), "drain-fail: off without --drain-full-s");
    check(!drain_failed(120, 0, 50, true), "drain-fail: off with D = 0 (default)");
    check(drain_failed(120, 1.0, 1.5, true) && !drain_failed(120, 1.0, 1.0, true) && !drain_failed(120, 1.0, 0.3, true),
          "drain-fail: wait 1.5 s > D 1 s fails; 1.0 s and 0.3 s do not");
    check(!drain_failed(120, 1.0, 5, false), "drain-fail: unmeasured warmup never fails");
    // fake engine, mu 6/s, knee 7 (latency fine up to 7): x = 6.5 leaves (0.5 x 18) = 9 queued -> 1.5 s drain > 1 s
    Sim a{Server{}, 7, 5, 120};
    a.fail_s = 1.0, a.s.mu = 6, a.s.t = 1;
    Res r = a.step(6.5);
    check(r.judged && r.drain_fail && !r.pass && std::fabs(r.wait_s - 1.5) < 0.01,
          "drain-fail: a step whose latency passes but leaves a 1.5 s backlog fails (drain " + std::to_string(r.wait_s) +
              " s)");
    Res ok = a.step(5);
    check(ok.pass && !ok.drain_fail && !ok.contaminated && ok.wait_s == 0, "drain-fail: next step starts clean, passes");
    Sim b{Server{}, 7, 5, 120};  // same step without --drain-fail-s: passes (today's verdict)
    b.s.mu = 6, b.s.t = 1;
    check(b.step(6.5).pass, "drain-fail off: the same step passes");
  }
  {  // 8. confirm repeats (6 x 15 s, pooled): every repeat starts clean; pooled fails on a drain-failing repeat
    Sim c{Server{}, 7, 5, 120};
    c.fail_s = 1.0, c.s.mu = 6, c.s.t = 1, c.s.backlog = 40;  // a backlog left by an earlier overload step
    std::vector<RepeatInput> in;
    for (int k = 0; k < 6; k++) {
      Res r = c.step(k == 2 ? 6.5 : 5);  // repeat 2 leaves a backlog (a slower phase of the stream)
      RepeatInput ri;
      ri.pass = r.pass, ri.nonlatency_fail = r.drain_fail, ri.lat.assign(100, 50.0);  // latencies all within SLO
      in.push_back(ri);
    }
    bool clean = true;
    for (auto &r : c.log) clean &= r.judged ? r.at_start == 0 || r.rerun_of >= 0 : true;
    check(c.log.size() == 7 && !c.log[0].judged && clean,
          "confirm repeats: the contaminated first repeat is re-run, every judged repeat starts clean");
    ProbeJudgement j = judge_probe(in, 95, 400, 0);
    check(j.reps == 6 && j.fails == 1 && j.nonlatency_fails == 1 && j.pooled_pslo <= 400 && j.pooled == kVerdictFail &&
              j.majority == kVerdictPass,
          "pooled (6 reps): pooled p95 50 <= 400 but one repeat failed the drain -> FAIL; majority 1/6 -> pass");
    for (auto &r : in) r.nonlatency_fail = false, r.pass = true;
    ProbeJudgement k = judge_probe(in, 95, 400, 0);
    check(k.pooled == kVerdictPass && k.majority == kVerdictPass, "pooled (6 reps): no drain failure -> pass");
    in[4].lat.assign(100, INFINITY), in[4].pass = false;  // latency-only failure of one repeat
    ProbeJudgement l = judge_probe(in, 95, 400, 0);
    check(l.pooled == kVerdictFail && l.nonlatency_fails == 0 && l.pooled_pslo > 400,
          "pooled (6 reps): pooled p95 over the merged set decides latency (1/6 inf at p95 -> fail)");
  }
  if (fails) {
    std::printf("DRAIN TEST FAIL (%d of %d checks)\n", fails, checks);
    return 1;
  }
  std::printf("DRAIN TEST PASS (%d checks)\n", checks);
  return 0;
}

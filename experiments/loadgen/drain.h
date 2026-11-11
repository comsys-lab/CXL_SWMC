// Step drain and clean-start rule of the load generator (loadgen --drain-full-s, README "Full drain").
// Kept apart from the engine so test/drain_test.cc drives it with a fake clock and a fake backlog (no server).
//
// Default (--drain-full-s 0, the behaviour of every run before 2026-11-12): after a step stops sending, wait while
// more requests are outstanding than at the step's start (out_base), at most --drain-s; the next step then starts
// even if the server still holds requests of this one (they count as timeouts = inf here, and load the next step).
// --drain-full-s S > 0:
//   1. drain: wait while ANY request (every stream, every earlier step) is outstanding, at most S seconds;
//   2. clean start: a step that starts with outstanding > 0 is "contaminated"; its first attempt is not judged (the
//      search never sees it: it is neither a pass nor a fail) and its own drain is the wait; the same step is then run
//      once more ("re-run"); a re-run is judged as before even if it is contaminated again (the flag stays).
#pragma once
#include <cstdint>

namespace loadgen {

struct DrainResult {
  double wait_s = 0;               // send end -> drain end
  uint64_t outstanding_after = 0;  // all outstanding requests when the drain ended
};

// out() -> current outstanding count, now() -> monotonic ns, nap() -> sleep about 1 ms
template <class Out, class Now, class Nap>
DrainResult drain_step(uint64_t send_end, double drain_s, double drain_full_s, uint64_t out_base, Out out, Now now,
                       Nap nap) {
  const bool full = drain_full_s > 0;
  const uint64_t base = full ? 0 : out_base;
  const uint64_t until = send_end + uint64_t((full ? drain_full_s : drain_s) * 1e9);
  while (out() > base && now() < until) nap();  // default: the loop of loadgen.cc before 2026-11-12, unchanged
  DrainResult r;
  const uint64_t t = now();
  r.wait_s = t > send_end ? double(t - send_end) / 1e9 : 0;
  r.outstanding_after = out();
  return r;
}

// a step is judged unless --drain-full-s is on, it starts with requests outstanding, it is the first attempt, and it
// is a measured step (an unmeasured warmup is never judged anyway)
inline bool step_judged(double drain_full_s, uint64_t outstanding_at_start, bool rerun, bool measured) {
  return !(drain_full_s > 0 && outstanding_at_start > 0 && !rerun && measured);
}

// step(rerun) -> result with .judged and .exhausted; an unjudged first attempt is run once more
template <class StepFn>
auto clean_step(StepFn step) -> decltype(step(false)) {
  auto r = step(false);
  if (r.judged || r.exhausted) return r;
  return step(true);
}

}  // namespace loadgen

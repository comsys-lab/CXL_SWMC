# loadgen — open-loop load generator with max throughput under SLO

One engine for every workload (vectordb now; LMDB, PageRank, recommendation later). The engine owns time and
statistics; a workload is a plugin (`workload.h`) that only makes requests and reads responses. Servers speak
`frame.h` (length-prefixed binary frames over TCP, responses matched by req_id); `python/frame.py` is the
asyncio peer (e.g. for a LangChain VectorStore client).

## Model
- **Streams.** A workload declares streams (vectordb: `update`, `search`; runs before 2026-10-16: `write`). Each stream is an open-loop arrival
  process (Poisson by default, seeded) at its own rate; requests are made in global schedule order, so a plugin
  can stamp "everything scheduled before me" (vectordb E1: ref_w = last write made). `ordered` streams use one
  connection per target, so the server sees them in schedule order.
- **Rates.** `--mix s=w,...` streams scale together with the swept rate x (x = their total); `--fixed s=r`
  streams keep a fixed rate. Sweep (a) "fixed updates, rising searches": `--fixed update=1000 --mix search=1`;
  sweep (b) "fixed mix, rising total": `--mix update=1,search=19` (95:5).
- **Latency** is measured from the scheduled time (no coordinated omission): it includes send lag and queueing.
  Requests still outstanding after the drain time count as +inf (they fail the percentile). Throughput =
  completions inside the measurement window / window.
- **Step** = `--step-warmup-s` at the new rate (not measured) + `--step-measure-s` measured; then sending stops
  and the engine drains (`--drain-s`). A run starts with `--warmup-s` (not measured).
- **SLO percentile.** `--slo s:pct:ms`, any pct in (0, 100), nearest rank: MOT1 v6 uses p99 (KV, LMDB, vector DB)
  and p95 (DLRM, `--slo query:95:100`). The percentile drives pass/fail, the early abort (slow requests > (1 − pct/100)
  × requests), the ramp step size and the confirm statistics; `export_csv.py` adds `slo_stream/slo_pct/slo_ms/p95_ms`.
- **Pass** (per step): SLO percentile of the SLO stream ≤ SLO; every stream keeps up (completions in the window
  ≥ (1 − tol) × requests sent in it); errors + timeouts ≤ max-err. A step is aborted early (fail) when the
  outstanding count exceeds rate × `--abort-queue-s` (saturated) or the SLO stream already has more slow
  requests than the percentile allows. Passing steps whose send-lag p99 exceeds `--lag-limit-us` are flagged
  (loadgen-bound; summary `passing_steps_with_send_lag` must be 0).

## Max throughput under SLO (`--mode slo`), minimal time
1. Ramp from `--start` with an adaptive step (factor f, default 1.5): × f² while the SLO percentile is below SLO/4,
   × f below SLO/2, × (1 + 0.4(f-1)) = 1.2 below 0.8·SLO, × (1 + 0.2(f-1)) = 1.1 above, and also × 1.1 whenever the
   percentile grew more than 1.5× in the last step (the curve bends) — denser points around the knee — until a
   step fails.
2. Bisect geometrically between the last pass and the first fail until fail/pass ≤ 1 + precision (5%).
3. Confirm the best passing rate with `--confirm-reps` × `--confirm-s` (3 × 30 s; a confirm passes when at most
   half of its repeats fail). If it fails (since 2026-10-18, decision "A+C"; before: step down by the precision and
   confirm again, at most twice, which left up to one precision step between the result and the knee unmeasured):
   first find a confirmed lower bound, then bisect geometrically with full confirms between the highest confirmed
   pass and the lowest confirm-failed rate until hi/lo ≤ 1 + `--confirm-precision` (1 %), at most
   `--max-confirm-probes` (6) confirms after the first. Lower bound (H1 v0.6.5, 2026-10-18; v0.6.3 took the next
   lower ramp/bisect pass however far below, e.g. LMDB hw-u50 r1 160.6k fail -> 146.0k fail -> 64.9k): after a failed
   confirm at f the next candidate is max(highest ramp/bisect pass below f, f / (1 + `--confirm-step-down`)), default
   0.05, allowed 0.02-0.05, so the search never jumps more than one geometric step below the last failed confirm
   unless a known pass lies closer; repeated until a confirm passes. Code: `slo_search.h` (unit test
   `test/slo_search_test.cc`). Reported: confirm mean/sd of x and of the SLO percentile at the highest confirmed
   pass; `summary.json` adds `confirmed`, `bracket` {lo_offered = the result, hi_offered = the lowest failed rate
   above it (ramp/bisect step or failed confirm; also `min_offered_x_fail`), hi_phase, hi_x, rel_width},
   `confirm_search` {finish, precision, confirm_precision, max_probes, step_down, probes} and `confirm_probes` (every confirm:
   offered_x, role first|lower|step-down|bisect, reps, fails, pass, x_mean, pslo_mean_ms). No confirmed pass within
   the probes: note "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" (unchanged text; harness
   scripts match it), result = the lowest probed rate, `confirmed` false. Cost of a failed first confirm: one confirm
   (`--confirm-reps` × (`--step-warmup-s` + `--confirm-s` + `--drain-s`), ≈ 2 min at 3 × (3 + 30 + 5) s) per probe,
   typically 2-6 probes (H1 r1 shapes replayed offline: mean 4.5, worst case 6 = ≈ 12 min).
Confirm rule (2026-10-21, exploratory; defaults keep the rule above, its decisions, steps.jsonl and every older
summary/manifest key unchanged (new keys are appended, one new file); code `slo_search.h` judge_probe/replay_rule, unit test `test/confirm_rule_test.cc`):
- `--confirm-rule majority|pooled` (majority): pooled = a confirm passes iff the nearest-rank SLO percentile of the
  merged SLO-stream latencies of all its repeats (exact: every measured request, timeouts = inf) <= SLO and no repeat
  failed for a non-latency reason (queue-cap saturation, falling behind, errors/timeouts).
- `--confirm-full`: confirm repeats never stop early (no "SLO percentile already exceeded" abort; queue cap stays).
- `--confirm-min-samples K` (0 = off): a confirm whose merged SLO-stream count (measured requests) is < K gets the
  verdict "insufficient samples" under both rules; the search treats it as not passing.
- Always recorded: `confirm_probes[]` appends rep_pslo_ms, rep_p99_ms, rep_n, rep_pass, rep_aborted, nonlatency_fails,
  pooled_n, pooled_pslo_ms, pooled_p99_ms, verdict_majority, verdict_pooled; summary.json appends `confirm_rule`
  {rule, full, min_samples}, `result_majority` and `result_pooled` {followed, complete, confirmed, max_offered_x_pass,
  lo_fail_offered, finish, probes_used, needs_offered, needs_role}: the followed rule = the search; the other rule =
  confirm_search replayed on the recorded verdicts, complete=false when it would have needed a probe that was not run
  (needs_offered/needs_role; its other fields are then its state at that point). New file `confirm_probes.csv`: one
  row per confirm repeat. Manifest key `confirm_rule= confirm_full= confirm_min_samples=` only when set.
Past-the-knee rule (de-stijl-motivation-isca27 §3, user 2026-10-21 23:5x; opt-in, defaults keep the old behaviour,
manifest key `overload_base= start_fail_steps=` only when set; builds/vdb-loadgen/12):
- `--overload-base first-fail|result` (first-fail): the `--overload` points are at the first failed rate above the
  result x f (default) or at the result (max_offered_x_pass: the confirmed offered rate) x f. The eval2 runs use
  `--overload-base result --overload 1.1,1.25,1.5,2.0`.
- `--start-fail-steps f1,f2,...|none` (none): when the start rate already violates the SLO, steps at start x f are
  measured in full (phase "overload", like the overload points: no SLO early abort, the queue-cap abort stays; an
  aborted step is kept in steps.jsonl with aborted=true) before the search ends with the unchanged note "the start
  rate already violates the SLO; lower --start". eval2: `--start-fail-steps 1.5,2.25`. Not with `--ramp-knee`.
Opt-in for workloads whose tail latency can be worst at LOW load (RecSys: updates at an absolute rate, so a query
at a low rate absorbs every invalidation since the previous one; user decisions 2026-10-19; defaults 0 = off, every
other caller unchanged, manifest key `min_step_queries= ramp_knee=` only when set):
- `--min-step-queries N`: every measured step (ramp, bisect, confirm, fill, overload) lasts at least N / (SLO-stream
  rate) s, so a nearest-rank p95 is not the slowest of a handful of queries (RecSys: 100 -> 100 s at 1 query/s).
- `--ramp-knee K` (`--ramp-knee-rise X`, 1.2; `--ramp-knee-floor F`, 1.5): a failed ramp step does not end the ramp; after a failed step the
  rate grows by f (after a pass: the adaptive step above). The ramp stops (a) at once when the queue cap aborts a
  step, (b) after a pass, when the SLO stream falls behind, or (c) after a pass, after K consecutive failed steps
  whose SLO percentile rose >= X x the previous step's (queueing past the knee; low-rate failures have a flat or
  falling percentile) and the stopping step's percentile is > F x SLO (user decision 2026-10-19 (c): chance rises of
  low-rate failures just above the SLO never stop the ramp). Knee = the first step of the final run of failed ramp steps (every ramp step at or above it
  failed); bisect (own budget of 12 steps, `ramp_policy.bisect_cut` if it ends above the precision) and confirm work
  between the highest pass below the knee and the knee (result = definition (가)). Ramp steps run without the early
  "SLO already exceeded" abort, so every low-rate p95 is complete. `summary.json` adds `ramp_policy` {knee_k,
  knee_rise, min_step_queries, knee_offered, ramp_end, bisect_cut} and `low_rate_violations` (failed ramp/bisect
  steps below the result: phase, offered_x, x, pslo_ms, n, reason). Code: `slo_search.h` KneeRamp (unit test in
  `test/slo_search_test.cc`). Notes (no result): "no passing ramp step below the knee (<why>)", "max steps reached
  before the knee was confirmed (<why>); raise --max-steps" (a failing run the stop rule did not confirm may be
  low-rate failures).
Every ramp/bisect step is a (throughput, tail latency) point; the ramp gives the low-load part of the curve,
the bisection the knee, the first failing ramp step a point past it; afterwards `fill` points at the result x
0.7/0.8/0.9 (the bend) and `overload` points at the first-fail rate x 1.05/1.1/1.2 (past the knee), both measured
in full and never changing the result. Typical cost: about 8-12 steps × ~20 s +
confirm ≈ 4-6 min per (system, configuration). `--mode fixed --rates r1,r2,...` measures given rates.

## Full drain and clean start (`--drain-full-s S`, default 0 = off)
Default (every run before 2026-11-12): after a step stops sending, the engine waits at most `--drain-s` (5 s) for
the step's own requests; the next step then starts while the server may still work through the backlog, and that
step measures the backlog, not its own rate (e.g. a 7.65 q/s bisect step after a 28.3 q/s ramp step: sent 13,
done 0, p95 inf). With `--drain-full-s S` (S > 0; recommended 120 for RecSys stream searches):
- drain: after every step the engine waits until no request of any stream (including leftovers of earlier steps) is
  outstanding, at most S seconds (`--drain-s` is then not used);
- clean start: a step that starts with requests outstanding (the previous drain hit the cap) is "contaminated".
  Its first attempt is logged with phase `contaminated` (the original phase in `reason`), `pass` false, `judged`
  false, and is never seen by the search (neither a pass nor a fail; not in the knee bracket, not plotted); its own
  drain is the wait. The same step (phase, rate, lengths) is then run once more; this re-run is judged as before even
  if it is contaminated again (`contaminated` true, `judged` true, `rerun_of` = step of the attempt).
- records, only with the option (earlier outputs stay byte-for-byte the same in layout): steps.jsonl keys after
  `streams`: `contaminated`, `judged`, `rerun_of` (null if not a re-run), `outstanding_at_start`, `drain_wait_s`
  (send end -> drain end), `outstanding_after_drain`; manifest line `drain_full_s=S`; summary.json `drain_full`
  {`cap_s`, `contaminated_steps`, `reruns`}. `export_csv.py` appends the six steps.jsonl keys as the last columns
  (empty for runs without the option).
- `--drain-fail-s D` (needs `--drain-full-s`, D < S; default 0 = off; RecSys target 2.0 (user 2026-11-12, conservative; passing
  steps' max query latency <= 826 ms, overloaded steps >= 864 ms): a measured step of any phase (ramp, bisect, each confirm
  repeat, fill, overload) whose drain took longer than D seconds left a backlog and fails with reason
  `drain > D s (backlog)`, a non-latency failure like a stream falling behind (in the knee ramp it ends the ramp
  like "SLO stream falls behind"; under `--confirm-rule pooled` a probe passes iff the pooled SLO percentile <= SLO
  and no repeat failed a non-latency check, this one included). Recorded: steps.jsonl `drain_fail`, summary
  `drain_full.fail_s`/`drain_fails`, confirm_probes.csv `rep_drain_wait_s, rep_drain_fail, rep_nonlatency_fail,
  rep_contaminated` (appended, only with `--drain-full-s`), summary `confirm_probes[].rep_drain_wait_s/rep_drain_fail`.
- confirm repeats are separate steps: each one is followed by the full drain and checked for a clean start, so every
  judged repeat starts with nothing outstanding (or is a flagged re-run). Target RecSys setting (user 2026-11-12):
  `--drain-full-s 120 --drain-fail-s 2.0 --confirm-rule pooled --confirm-reps 6 --confirm-s 15`.
- requests that complete during the longer drain count with their real latency (with the default they would be
  +inf after `--drain-s`); a step whose drain hits the cap still counts the rest as +inf.
- code `drain.h` (drain_step, step_judged, clean_step); unit test `test/drain_test.cc` (default-off identity with the
  old drain loop, full drain, contaminated re-run, search decisions on a fake backlog).

## Outputs (`--out DIR`, must not exist)
`manifest.txt` (all parameters, workload description), `steps.jsonl` (one JSON per step: offered/achieved,
p50/p90/p95/p99/p99.9/SLO percentile (`pslo_ms`)/max, errors, timeouts, send lag, pass/abort reason, per stream;
`p95_ms` since 2026-10-16), `summary.json` (`slo` = stream/pct/ms in every run with `--slo`, since 2026-10-16 also
fixed mode and SLO runs without a passing step), optional `raw-step<N>.bin` (`--raw`: one 32 B row per request of the
step, 4 x u64: sched ns, send ns, done ns (0 = never completed), stream << 32 | status | measured << 40) with, since
2026-10-16, `rawid-step<N>.bin` beside it (one u64 per raw row, same order: the request id = the frame `req_id` the
server echoes, so per-request server records can be matched by id instead of by time; a sidecar file keeps the raw
rows unchanged for existing readers; runs before 2026-10-16 have no rawid file), optional
`stats/` (`--stats-op`, below), plus the
workload's own files (e.g. vectordb search results for offline recall).
Plot: `plot_slo.py --out fig.pdf runA=all-HWcc runB=Megalon ...` (x = throughput, y = tail latency).

## Server counter snapshots (`--stats-op N`, default off)
With `--stats-op N` the engine opens one extra connection per target and, for every measured step (not the run
warm-up), sends a frame with op N (empty payload) and stores the text reply: once from a helper thread at the
window start (end of the step warm-up) and once right after sending stops (= window end; in-flight requests drain
afterwards). Files: `<out>/stats/step<NNN>-{begin,end}-t<k>.txt` (NNN = `step` in steps.jsonl, k = target index),
first line `# when= phase= step= offered_x= target= addr= status= wall_ns= mono_ns= rtt_us=`, then the reply
(vdb-server: `key=value` lines incl. `systems/common/proc_stats.h` keys). A step that stops before its window starts
has no snapshots. Requests and replies on that connection are synchronous; the measured connections are untouched.
- `stats_delta.py <out> [--out stats-steps.csv]`: one row per (step, target) with both snapshots; end − begin for
  every numeric key (gauges: `node`, `write_queue`, `search_queue`, `megt.sample`, `*.n`, `*max_ns` keep the end
  value), `window_s` (loadgen clock) and `srv_window_s` (server `t_mono_ns`).
- `export_csv.py` adds step-level and per-node derived columns from these deltas (column list in its docstring):
  rates (search/s, update/s, total ops/s; an update is one operation), search/update p50/p99, worker busy
  fractions, CPU and run-queue wait per thread role, coherence stall estimates (Popcorn per-thread fault time,
  Megalon section timers), coherence background CPU (`cxl_recv*` kernel threads, library threads), TLB/call IPIs,
  traffic (Megalon flush bytes; Popcorn (remote write-backs + acquire flushes) × 4 KiB). Existing columns keep their order; new columns are
  appended.
- Unit test (Host): `python3 test/stats_delta_test.py <scratch dir>`.

## Build and self-test (Host)
`build.sh <out dir> [plugin.cc ...]` (out dir outside the repo, e.g. builds/loadgen/<n>; pin builds to node1).
Self-test against the echo server (capacity = workers / service time), Host loopback, node1 CPUs:
```
taskset -c 16-19 <out>/echo_server 19091 2 500 &      # capacity 4000 req/s
taskset -c 20-23 <out>/loadgen --workload echo --target 127.0.0.1:19091 --out /tmp/x --slo req:99:5 \
  --start 500 --fixed bg=100 --warmup-s 2 --step-warmup-s 1 --step-measure-s 4 --confirm-s 5
```
2026-10-15 (obs): max under SLO ≈ 3200-3350 req/s (p99 ≤ 5 ms), first fail 3431-3461; 49-60 s per search.

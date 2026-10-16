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
3. Confirm the best passing rate with `--confirm-reps` × `--confirm-s` (3 × 30 s); if most repeats fail, step
   down by the precision and confirm again (at most twice). Reported: confirm mean/sd of x and of the SLO
   percentile.
Every ramp/bisect step is a (throughput, tail latency) point; the ramp gives the low-load part of the curve,
the bisection the knee, the first failing ramp step a point past it; afterwards `fill` points at the result x
0.7/0.8/0.9 (the bend) and `overload` points at the first-fail rate x 1.05/1.1/1.2 (past the knee), both measured
in full and never changing the result. Typical cost: about 8-12 steps × ~20 s +
confirm ≈ 4-6 min per (system, configuration). `--mode fixed --rates r1,r2,...` measures given rates.

## Outputs (`--out DIR`, must not exist)
`manifest.txt` (all parameters, workload description), `steps.jsonl` (one JSON per step: offered/achieved,
p50/p90/p95/p99/p99.9/SLO percentile (`pslo_ms`)/max, errors, timeouts, send lag, pass/abort reason, per stream;
`p95_ms` since 2026-10-16), `summary.json` (`slo` = stream/pct/ms in every run with `--slo`, since 2026-10-16 also
fixed mode and SLO runs without a passing step), optional `raw-step<N>.bin` (`--raw`: sched/send/done ns, stream/status per request), optional
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

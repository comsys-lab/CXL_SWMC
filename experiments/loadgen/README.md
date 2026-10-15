# loadgen — open-loop load generator with max throughput under SLO

One engine for every workload (vectordb now; LMDB, PageRank, recommendation later). The engine owns time and
statistics; a workload is a plugin (`workload.h`) that only makes requests and reads responses. Servers speak
`frame.h` (length-prefixed binary frames over TCP, responses matched by req_id); `python/frame.py` is the
asyncio peer (e.g. for a LangChain VectorStore client).

## Model
- **Streams.** A workload declares streams (vectordb: `write`, `search`). Each stream is an open-loop arrival
  process (Poisson by default, seeded) at its own rate; requests are made in global schedule order, so a plugin
  can stamp "everything scheduled before me" (vectordb E1: ref_w = last write made). `ordered` streams use one
  connection per target, so the server sees them in schedule order.
- **Rates.** `--mix s=w,...` streams scale together with the swept rate x (x = their total); `--fixed s=r`
  streams keep a fixed rate. Sweep (a) "fixed writes, rising searches": `--fixed write=2000 --mix search=1`;
  sweep (b) "fixed mix, rising total": `--mix write=1,search=4`.
- **Latency** is measured from the scheduled time (no coordinated omission): it includes send lag and queueing.
  Requests still outstanding after the drain time count as +inf (they fail the percentile). Throughput =
  completions inside the measurement window / window.
- **Step** = `--step-warmup-s` at the new rate (not measured) + `--step-measure-s` measured; then sending stops
  and the engine drains (`--drain-s`). A run starts with `--warmup-s` (not measured).
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
p50/p90/p99/p99.9/SLO percentile/max, errors, timeouts, send lag, pass/abort reason, per stream),
`summary.json`, optional `raw-step<N>.bin` (`--raw`: sched/send/done ns, stream/status per request), plus the
workload's own files (e.g. vectordb search results for offline recall).
Plot: `plot_slo.py --out fig.pdf runA=all-HWcc runB=Megalon ...` (x = throughput, y = tail latency).

## Build and self-test (Host)
`build.sh <out dir> [plugin.cc ...]` (out dir outside the repo, e.g. builds/loadgen/<n>; pin builds to node1).
Self-test against the echo server (capacity = workers / service time), Host loopback, node1 CPUs:
```
taskset -c 16-19 <out>/echo_server 19091 2 500 &      # capacity 4000 req/s
taskset -c 20-23 <out>/loadgen --workload echo --target 127.0.0.1:19091 --out /tmp/x --slo req:99:5 \
  --start 500 --fixed bg=100 --warmup-s 2 --step-warmup-s 1 --step-measure-s 4 --confirm-s 5
```
2026-10-15 (obs): max under SLO ≈ 3200-3350 req/s (p99 ≤ 5 ms), first fail 3431-3461; 49-60 s per search.

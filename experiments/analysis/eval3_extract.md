# eval3_extract.py — statistics extractor for the De Stijl evaluation run (eval3)

Turns result dirs into one CSV per figure of reports/experiments/"4. Evaluation_outline.tex" and
reports/experiments/de-stijl-evaluation-run1-schedule.md §2-§4. Host only, offline, inputs are only read.

```
python3 -B experiments/analysis/eval3_extract.py RESULT_DIR [RESULT_DIR ...] --out OUT_DIR \
    [--systems hw,pop,mg,mgoff,ds] [--l1 u10=108,u50=21.6]
python3 -B experiments/analysis/test/eval3_extract_test.py -v     # unit test on a synthetic fixture
```

## Input
- A **part** = any directory below a RESULT_DIR with `steps.csv` (or `loadgen/steps.jsonl`) and `stats-steps.csv`
  (per-step, per-target counter deltas of experiments/loadgen/stats_delta.py; recomputed in memory from
  `loadgen/stats/` when the CSV is missing). Works for the vector DB h2n blocks (`block/<sys>-<mix>-n<N>/slo`), the
  fixed-window parts (`.../fix`), RocksDB (`S-<sys>-<mix>`) and RecSys (`block/<sys>-u<rate>/slo`).
- Cell = nearest path component `<sys>-<mix>[-n<N>]`, sys in hw / pop / mg / mgoff / ds. N falls back to the number
  of stats targets. `run` = basename of the RESULT_DIR (distinguishes e.g. ds T = 0 and T = 5 s runs).
- Workload from the stream names: search -> vectordb, query -> recsys, get / mixed -> rocksdb. SLO stream /
  percentile / bound from steps.csv `slo_stream, slo_pct, slo_ms` (defaults search p99 100 ms, query p95 100 ms,
  mixed p99 1 ms).
- Counters are summed over targets (VMs); per-thread keys `thr.<thread>.swmc.<k>` are summed over all threads
  (thread groups are disjoint) unless a formula names a thread (vdb-search).

## Step selection (column `sel`; pooled rows have `step` = L1 / MAX / FLOOR)
- **L1**: a step with loadgen phase `fixed` (or `l1`) in the part (the appended L1 step, doc §2 decision 9; with
  several fixed steps the highest offered rate). Without one: the measured step nearest to the L1 rate of the group
  (workload, mix, N) = `--l1` override, else the lowest max under SLO (total offered req/s) among the group's
  systems, else, when some system has no max under SLO, the lowest measured rate (outline "Motivation": all violate
  -> lowest request rate). `l1_src` says which.
- **MAX**: passing `confirm` steps at the highest passing offered rate (rates within 3 % pooled: counters and windows
  add up). No confirm phase: highest passing non-overload step. Nothing passes: **FLOOR** = the lowest-rate step.
  Pass = loadgen pass, not aborted and SLO percentile latency <= slo_ms.

## Output files and columns
Common identity columns: `run, workload, system, mix, N, lifetime, part`. Durations per fault in us, per operation
in ms, rates per second over the step window (max of the targets' loadgen windows; pooled = sum of windows).

| File | Figure | Columns |
| --- | --- | --- |
| cells.csv | index | slo_stream, slo_pct, slo_ms, n_steps, stats_steps, l1_steps, l1_src, l1_rate, max_steps, max_src, source_dir |
| fig-latency-vs-rps.csv | §2 latency vs RPS (vdb p99, RocksDB p99, RecSys p95), H1 curves | step, phase, sel, measure_s, offered_total (req/s, all streams), achieved_total, slo_offered, slo_achieved, slo_p50/p95/p99/pslo_ms (SLO stream), slo_pct, slo_ms, within_slo, pass, aborted, other_stream, other_achieved, other_p99_ms |
| fig-max-under-slo.csv | §2 / §4 max RPS under SLO | max_slo_stream_s (SLO-stream ops/s: h2n confirm_x_mean or steps.csv max_under_slo), max_offered_total (total req/s: h2n max_offered_x_pass or result_pooled_offered or the MAX step rate), max_src, confirmed, floor, floor_rate, floor_slo_pslo_ms, max_steps, note |
| fig-flushed-lines-l1.csv | motivation H1: flushed cache lines per search at L1 | step, l1_src, l1_rate, offered_total, lines_per_search, srv_searches, search_is_faults, search_is_per_search, mg_search_events, mg_events_per_search, mg_rflush_bytes, mg_rflushes, mg_rflush_bytes_per_flush, window_s |
| fig-fault-breakdown.csv | §3 read / write fault latency in 5 categories (+ H2) | step, sel, offered_total, class, mode, faults, F_us, cat1_comm_us, cat2_unmap_tlb_us, cat3_flush_us, cat4_metadata_us, cat5_others_us, norm_F_to_pop, W_us, H_us, xport_us, comm_xport_us, comm_owner_rest_us, last_revoke_us, last_wb_us, last_meta_us, acquire_flush_us, local_meta_us, pte_install_us, local_wait_us, residual_us, owner_h_us, fetch_wait_us, rest_us, async_served_faults, sync_faults, owner_h_rounds, nontrans_faults, breakdown_faults, sum_check_us |
| fig-coherence-rates.csv | §4 messages/s, H2 Page SWcc faults/s | step, sel, offered_total, window_s, read_faults_s, write_faults_s, nontrans_faults_s, coh_msgs_s, pop_rounds_s, pop_requests_s, pop_msgs_s, ds_fetch_s, ds_inv_s, ds_ack_s, ds_msgs_s, searches_s |
| fig-search-breakdown.csv | §4 / H2 search latency breakdown | step, sel, offered_total, op, ops, t_ms, wait_ms, c_ms, pop_is_ms, pop_sm_ms, pop_wp_ms, pop_ipi_ms, pop_nontrans_ms, pop_sum_ms, rest_ms |
| fig-ds-staleness.csv | §5 fallback: measured staleness | step, sel, offered_total, read_faults, async_issued, async_installed, async_completed, async_superseded_write, async_superseded_inv, async_fallback, ss_read_share, ss_residence_p95_us_max, ss_residence_p95_us_mean, ss_residence_max_us, lambda_per_s_mean, tx_timeout, protocol_error |

## Formulas
**Flushed cache lines per search** (workspaces/figs-54m/fig23/export_fixed.py, applied to the L1 step):
Megalon = (opt.search.meg.stale_cnt + concur_cnt) / searches x (read-side flush bytes / read-side flushes) / 64,
read-side = megalon.flush_bytes - opt.{search,update}.meg.wflush_bytes and megalon.flushes - wflush_cnt;
Popcorn and De Stijl = thr.vdb-search.swmc.is_faults / searches x 4096 / 64; All-HWcc = 0; searches = server
`searches`. (De Stijl uses the Popcorn page formula: one fetched page = 64 lines.)

**Fault classes**: read = I->S faults (`is_faults`, F = `is_fault_ns`, full exception duration); write = I/S->M
not-present writes + write-protect upgrades (`sm_* + wpu_*`). W = `<class>_msg_wait_ns`, H = `<class>_owner_h_ns`.
De Stijl build 8 sub-classes `read_sync`, `read_async` (and write_*) get their own rows when keys
`thr.*.swmc.<class>_{faults,fault_ns,msg_wait_ns,...}` exist (assumed names, to be confirmed by the ds-breakdown port).

**Five categories** (`mode = b13`: Popcorn build 13 or De Stijl build 8 keys present and breakdown_faults > 0;
reports/design/P-popcorn-build13-fault-breakdown.md §2; sums over threads, targets and pooled steps, then / faults):
1 communication = W - (last_revoke + last_wb + last_meta) = comm_xport (W - H) + comm_owner_rest (H - phases: owner
dequeue/reply send); 2 unmap + TLB = last_revoke; 3 flush = last_wb + acquire_flush; 4 metadata = last_meta +
local_meta; 5 others = F - (1 + 2 + 3 + 4) = pte_install + local_wait + residual. 1..5 sum to F exactly
(`sum_check_us` = 0). Note: the task brief wrote "1 = W - H_last"; the design doc's definition (owner reply/rest
counted as communication) is used so that the categories add up to F; `comm_xport_us` is the W - H part.
`mode = b12` (Popcorn build 12): cat1 = W - H (xport), owner_h_us = H unsplit, rest_us = F - W; categories 2-5
empty. `mode = ds-2part` (De Stijl build 7, no owner phases in the ring ACK): fetch_wait_us = W, rest_us = F - W;
read rows also carry async_served_faults (sys.swmc.destijl.async_installed) and sync_faults = faults - async.
`norm_F_to_pop` (pooled rows only) = F / F of Popcorn at the same (workload, mix, N, class, L1/MAX).
Faults without a transition (`nontrans_faults`) are not in F but their rounds are in W (reported; small).

**Rates**: read_faults_s = Σ is_faults / window; write_faults_s = Σ (sm + wpu) / window. Popcorn messages:
pop_requests_s = Σ sys.swmc.instr.serve_{fetch,invalidate}.reply_count / window (requests handled = requests
received), pop_msgs_s = 2 x that (request + response), pop_rounds_s = Σ tx_{fetch,invalidate}.wait_count. De Stijl:
ds_msgs_s = Σ (fetch_sent + inv_sent + ack_sent) / window. coh_msgs_s = pop_msgs_s (pop), ds_msgs_s (ds), 0 (hw),
empty (mg).

**Search breakdown**: opt.<op>.{t_ns, wait_ns, c_ns, pop.{is,sm,wp,ipi,nontrans}_ns} / opt.<op>.ops in ms;
rest_ms = t_ms - Σ pop_*. (RecSys uses op.<op>.* names: no rows.)

**Staleness (De Stijl)**: ss_read_share = async_installed / Σ read_faults = share of read faults served from a
possibly stale SS mapping (no counter of reads that actually returned stale data exists); SS residence p95 =
gauge sys.swmc.destijl.p95_us (max and mean over targets), ss_residence_max_us = max gauge.

## Validation (2026-11-01)
- Unit test: 8 tests on the synthetic fixture (build-13 keys, ds build-7 keys, pooled confirm steps), all PASS.
- recovery/h1-54m-fixed-run1-v1 (fixed windows): lines_per_search at L1 equals fixed-run1.csv `fig3_lines_per_rop`
  for all 12 cells (hw / pop / mg / mgoff x u10 / u50 / u90) to 6 decimals.

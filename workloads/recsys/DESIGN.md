# recsys workload — DLRMv2-based recommendation system (design)

Status 2026-10-16: MOT1 v6 (user decisions 2026-10-16, reports/MOT1-v6-redesign-draft.md) implemented and tested on
the Host (file region, 2 processes); not run in the VMs. v6 evidence: reports/RECSYS-design.md §10.
Spec: reports/MOT1-motivation-plan.md §4.2 "Workload 2: recommendation system", H1 (T = 1 s), H3 (T sweep).
Report with the inputs audit, deviations and the draft VM packet: reports/RECSYS-design.md.

Limitation (as for every workload here): the two VMs share physically coherent memory, so a run proves the use of
each system's API and measures its coherence actions; it cannot prove a coherence protocol correct.

## 1. Roles
- Node 0 = updater: replays the update trace in time order (loadgen stream `update`, ordered), Monolith-style
  touched-row publication every T = 60 s at an Ekko operating point (§5). No training.
- Node 1 = serving: MLPerf DLRMv2 server queries (loadgen stream `query`): N consecutive samples (user-item pairs) of
  the query pool, N from `tools/dist_quantile.txt` (100..700, mean 270); embedding lookups + DLRMv2 dense part.
- Both nodes run the same binary and accept both ops; only the harness decides who gets what.
- SLO (v6): query p95 <= 100 ms (DeepRecSys ISCA'20; reports/MOT1-v6-sources.md §1): loadgen `--slo query:95:100`.
  Throughput = serving queries/s; updates/s reported next to it.

## 2. Tables (SWcc)
- Addressing (user decision 2026-10-18, reports/H1-workload-porting.md Q11/Q12; replaces v5/v6 open addressing with
  linear probing): every system addresses rows directly. Row r of table k is record (k, r). Plain: SWcc offset
  (row_base[k] + r) x 576 B. Megalon: row r of table k lives in object (k, r / n) at byte (r mod n) x 576, n = rows
  per object (`--mg-rows-per-object`, §7.1). A lookup reads exactly one record (`probes` =
  `lookups`). The updater writes rows without resolving a slot. Reason: Megalon finds an object by its id through its
  own index. With the app hash table kept only on plain, hw would read ~2.7 slots per lookup plus probe in the
  updater while mg reads one, which biases C_diff = T(mgoff) - T(hw).
- 26 sparse features, one directly addressed table each. Rows per table = min(MLPerf rows, 26M) (5 tables capped: raw
  id mod 26M; recorded deviation D1), 134,184,588 rows in total. No empty records.
- Record (576 B, 9 whole cache lines): `key u64 | emb fp32[128] | seq u64 | csum u32 | pad`. key = (table + 1) << 56 |
  row (0 = never written); seq = update sequence that wrote the row (0 = initial); csum = FNV over key, seq and emb.
- 134,184,588 x 576 B = 77,290,322,688 B = 71.98 GiB of the 95.73 GiB SWcc (was 167,731,776 slots, 89.98 GiB). Tables
  are contiguous, table k after table k-1 (plain backend); Megalon places them as objects (§7).
- Initial image (prepare, node 0, unmeasured): every row written once with seq 0, deterministic. Values are synthetic
  (§5). Warm-up reads every record and checks its key and csum.
- No deletes and no new ids during a run: every id of the trace maps to a preloaded row (raw id mod rows), as in
  MLPerf's dense tables indexed by id (D3 resolved).

## 3. Samples and queries (inputs)
- Sample record v2 (proto.h `Sample`, 908 B; samples.h version 2): 13 dense fp32 as preprocessed by MLPerf/torchrec (log(x + 3):
  observed on day 23, exp of every value is an integer >= 2, i.e. raw values shifted by the global minimum -1 plus 2;
  torchrec source not checked locally) + the 214 multi-hot ids of the 26 features in table order (MLPerf sizes
  3,2,1,2,6,1,1,1,1,7,3,8,1,6,9,5,1,1,1,12,100,27,10,3,1,1), uncapped. The server uses them as is (row = id mod rows,
  D1); version-1 files (26 one-hot ids) are rejected.
- Real data (v6 default): `tools/mlperf_npz_to_samples.py` copies records of the MLCommons preprocessed day 23
  (`day_23_dense.npy`, `day_23_sparse_multi_hot.npz`, members memory-mapped, stored uncompressed) unchanged. Converted
  slices (builds/recsys-inputs/1): updates = day-23 records [0, 2M), queries = [89,137,318, +1M) (second half of day 23).
  File order = time order is not verified for day 23 (inf; recorded in the file's source string).
- Synthetic (`tools/gen_samples.cc`; bring-up and Host tests): zipf/uniform one-hot id per table, expanded to the
  MLPerf sizes by a hash (layout.h `synth_multi_hot`, same uniform distribution as MLPerf's table; D2 applies to
  synthetic inputs only).

## 4. Atomicity of a row copy: each system's own mechanism
- A row is 9 cache lines. HWcc and Popcorn give coherence, not atomicity of a multi-line copy. The plain backend
  therefore keeps the application's MemC3 striped version table. Megalon's read/write sections already validate and
  lock the object, so the Megalon backend does not use the table (it is still allocated; layout unchanged).
- `versions` (HWcc app; v6, MemC3 NSDI'13 §3.2.1): S = 2^16 u32 counters (`--ver-stripes`, power of two; libcuckoo
  kMaxNumLocks), 256 KiB; row key -> counter `mix64(key ^ seed ^ salt) & (S - 1)` (the key carries the table). App
  layout 266,240 B at full size; the layout hash includes S. `stripe % U` is also the update-worker shard on every
  backend, so workers never share a row.
- Plain writer (per row): CAS even -> odd on the row's counter, write the record, release-store +2.
- Plain reader (MemC3 optimistic): v1 = acquire-load of the key's counter (spin while odd: `seq_spins`), copy the row,
  acquire fence, v2 == v1 else re-read the row (`seq_retries`).
- False retries (`false_retries`, per query and in stats): a retry where the row itself was not rewritten = the
  discarded copy was consistent (csum) and the re-read has the same seq. Approximation: a writer of the same row that
  completed between v1 and the discarded copy is also counted false (window: one 576 B copy).
- Megalon: a lookup is one read section, repeated by the backend until `read_end` accepts it (`megalon_time.*.read_fail`,
  `megalon.read_retry_*`); an update is one write section. `seq_retries`, `seq_spins`, `lock_spins` are 0.
- `--verify-rows 1` recomputes csum per hit (`torn_rows`, must be 0) in every system. Host evidence: 0 torn rows in
  every run; `--test-no-seqlock` (negative, plain) 177 torn rows with probing (v6), 59 with direct addressing
  (2026-10-18, T = 0, builds/recsys/11; workspaces/recsys-meg-native/host-test-2/plain-neg-T0).

## 5. Updater, publication interval T and the Ekko operating points (v6)
- One `update` request = one sample (seq 1..). U workers (`--update-threads`, 4); every worker receives every sample
  and keeps the rows it owns in a private map key -> latest seq (latest wins); owner = stripe % U on plain, Megalon
  object index % U on Megalon (one writer per object, §7.1). Nothing in shared
  memory is read or written per sample; with T > 0 the sample is acknowledged on acceptance (workers independent, no
  all-worker completion per sample).
- Every T (`--publish-ms`, 60 s in the main runs) each worker publishes its touched rows once (Monolith §2.2.3):
  sort its rows by address, write each row (plain: under its counter; Megalon: one write section per owned object
  holding all of its touched rows, §7.1); then `published_seq`
  (HWcc node line, min over workers). A round longer than T is an overrun: `flush_overruns`, `update_rate_sustained=0`
  ("update rate not sustained"), logged per round (`recsys-server: round ... OVERRUN`); the next round starts at the
  next multiple of T (never bursted). T = 0 (diagnostic): every sample's rows are written before the reply.
- Operating point = fraction F of all rows published per T (`--publish-frac F`, reported as `rows_per_round_target`
  next to `round_rows` / `publish_rounds`): Ekko OSDI'22 average 3.08% of rows/hour -> F = 0.0308/60 per 60 s;
  peak 4.3%/10 min -> F = 0.043/10. The loadgen sample rate is computed by `recsys-rate` (tools/rate_calib.cc), which
  replays the trace like the updater and counts samples until one interval's distinct rows reach F x rows.
  The mapping is a lower bound: Ekko counts distinct rows over the hour (or 10 min), so the distinct rows of one
  60 s interval are at least that fraction / intervals (re-touches across intervals would raise it). Full size,
  day-23 trace [0, 2M), T = 60 s, 20 windows: average 68,881 rows/T -> 883.4 samples/T = 14.72 samples/s; peak
  576,994 rows/T -> 11,325.6 samples/T = 188.76 samples/s (builds/recsys-inputs/1/rate-frac*.txt).
- Operating-point check (experiments/recsys/v1_check.py, RECSYS-V1 v1.2.7+): rows per full round = d(round_rows) /
  (d(published_seq) / (R x T)) over the window (the server's round clock is not aligned to a measurement window, so
  a plain per-round mean includes partly fed rounds), target F x rows, +-15 %. Known bias (verifier LOW 16): a
  partly fed round de-duplicates less (v1.2.6 hw: 53.9 rows/sample in the partial round vs 50.0 in the full one),
  so the normalised estimate leans high, about +1-3 % (v1.2.6: hw +1.3 %, pop +2.7 %). Small against +-15 %, but it
  is upward: it can hide a shortfall of that size, never invent one. H1 SLO runs check it on the passing,
  non-overload steps only (v1_check --h1).
- Row values are synthetic: emb = f(key, seq, seed) in [-0.05, 0.05) (D5).

### 5.1 Streaming updates (RecSys methodology, user decisions 2026-10-19; state/PROJECT.md "RecSys experiment methodology")
Every RecSys experiment from 2026-10-19 on uses this mode; H1 results and the H1 harness (§5, T = 1 s) are unchanged.
- Server: `--update-mode stream` (requires `--publish-ms 0`). An update request is acknowledged on acceptance (frame
  read), then every update worker writes the rows it owns of that sample right away: deduplicated within the sample,
  address order, plain = one stripe hold per row (§4), Megalon = one write section per touched object (§7.1). No
  publication period and no coalescing across samples: a writer that cannot keep up shows as queue depth and lag, not
  as fewer rows written. `published_seq` (min over workers of the last sample fully written) still marks visibility.
  The default (`--update-mode batch`) is the §5 behaviour, byte for byte.
- Threads (main-block.sh BLOCK=stream): node 0 (updater) `--update-threads 14 --serve-threads 1`, node 1 (serving)
  `--update-threads 1 --serve-threads 14`, so update threads = serving threads (14) and threads never limit the update
  rate; Megalon registrations 1 + 8 + 14 + 1 = 24 <= 32 per node.
- Stats (stream mode only): `update_mode`, `stats_mono_ns` (server clock of the snapshot), `update_accepted_seq`,
  `update_lag_samples` (accepted - published_seq = backlog), `update_lag_ns_{sum,n}` (acceptance to the owning
  worker's rows written, per sample and worker), `update_lag_ns_max` (max since the previous stats read),
  `update_queue.w<i>` (current queue depth per worker), with `rows_written`, `update_queue_max` as before.
- Validity (experiments/recsys/stream_check.py, per measured step from the node-0 stats snapshots): samples fully
  written >= 0.98 x samples accepted in the window (d published_seq / d update_accepted_seq; accepted = sent, the
  arrivals are Poisson, so the nominal rate is not the reference) and backlog growth <= max(50 samples, 1 s of
  updates) and backlog at the window end <= max(50, 5 s of updates). A result whose
  steps at or below it are not all valid is reported "update rate not sustained" (STREAMCHECK NOTE).
- Rate: trace samples/s (Criteo 1TB day 23, MLPerf DLRMv2 multi-hot, samples [0, 2M) in file order; the loadgen
  replays it at a fixed rate and wraps), multiples of 50. Basis (Ekko OSDI'22 §6.2.1 + Fig. 9, §4.4): R such that
  the distinct rows touched in an interval reach Ekko's fraction, computed by recsys-rate on this trace
  (workspaces/recsys-mid/ekko10min, 2026-10-19): average 3.08 % of rows per 3600 s -> 41.47 samples/s -> 50; peak
  (update-intensive model, busiest 480 min) 4.3 % of rows per 600 s -> 393.27 samples/s -> 400. Rounding: to the
  nearest multiple of 50. Points: 50, 100, 200, 400 (Ekko peak), 600 and 800 (stress, above Ekko peak; labelled).
  Command (frac = 0.043 at t = 600 s, 8 windows; 0.0308 at 3600 s): `recsys-rate --samples
  builds/recsys-inputs/1/updates-day23-0-2M.smp --frac F --t-ms T --windows W` -> rate_samples_per_s. At 400
  samples/s this trace touches 0.77 % of rows per 60 s and 14.9 % per 3600 s (Ekko: ~10 %; this trace re-touches
  less within an hour). The §5 mapping (F per 60 s = fraction / intervals) understated both points by 2-3x.
- SLO search (loadgen `--min-step-queries 100 --ramp-knee 2`, RecSys only; defaults keep every other workload's
  search unchanged): ramp from 1 query/s, every measured step >= 100 queries (step length scaled), a failed step at a
  low rate is recorded and the ramp goes on (tail latency can be worst at low load: each query absorbs every
  invalidation since the previous one; after a failed step the rate grows by x1.5). The ramp stops past the knee:
  after a pass, 2 consecutive failed steps whose p95 rose >= 1.2x each (queueing; low-rate p95 is flat or falling),
  or the query stream falls behind; or at once when the queue cap aborts a step. Knee = the first step of the final
  run of failed ramp steps; max under SLO = the highest pass below it (bisect, own budget of 12 steps, then
  confirm as before);
  summary.json `low_rate_violations` lists the failed steps below the result with their p95.

## 6. Serving (DLRMv2 dense part, CPU, fp32)
- Model = torchrec DLRM_DCN as in MLPerf DLRMv2: bottom MLP 13-512-256-128 (ReLU); x0 = [dense_out, sum-pooled
  embeddings of 26 features] = 3456; LowRankCrossNet 3 layers rank 512; top MLP 1024-1024-512-256 (ReLU) + 1, sigmoid.
  32.08 MFLOP per pair, 61.2 MiB weights per node (process DRAM).
- Weights: deterministic random (Xavier uniform from the seed) (deviation D4: trained weights not available). Compute
  cost does not depend on weight values.
- GEMM: weights packed in 32-column panels, AVX-512 8x32 micro-kernel (guests expose avx512f/bw/vl; no AMX). Host:
  79-91 GFLOP/s per thread (tests/model_test.cc; 14 threads 1.27 TFLOP/s total at 64-pair chunks).
- A query is split into chunks of pairs (`--chunk-pairs 0` = adaptive max(16, ceil(pairs / serve threads))); serving
  workers claim chunks (intra-query parallelism, like vectordb's segments); a chunk does bottom MLP, lookups, cross
  net, top MLP. The response carries per-query lookup/MLP times, lookups, probes, seqlock retries, misses, max seq.

### 6.1 Per-operation time split (MOT1 v6 Fig 2; server/optime.h)
- Operations: query (serving node; N = queries) and row update (updater node; N = rows written).
- T_o = server processing from dispatch to response ready, socket send excluded (definition common to all workloads),
  summed over threads, plain rdtsc (TSC rate calibrated at start, `tsc_khz`). Query: each thread's chunk task from
  claiming the chunk (bottom MLP, lookups, top MLP) to its result; the last chunk also assembles the response; queue
  wait before the first chunk and the reply send are excluded. Row update: each worker's publication round from its
  start (row writes) to published_seq raised (rows visible); no per-row reply exists
  (samples are acknowledged on acceptance, outside T).
- C_o = delta of the thread's coherence accounting over the same intervals: Popcorn swmc_acct (fault_ns[3] + ipi_ns,
  measured; registered per serving/update thread, zeros before build 9; read with swmc_acct_snapshot(), which uses
  the build-12 update sequence in reserved[2] and is a plain copy before build 12; build 10's faults without an MSI transition,
  reserved[0..1], are exported as `op.<o>.pc.nontrans_{ns,cnt}` and are NOT part of C); Megalon shim v2 CohSnap: section checks by the
  ratio estimator [sampled x N]. DLRM's all-HWcc is the plain backend, so every Megalon call counts as C (M2 §16,
  "all-HWcc without Megalon"): C_read = (check_ns_sampled + anchor.read_lookup_ns_sampled + anchor.read_nr_ns_sampled)
  x read_sections / check_sampled; C_write = wstart + anchor.write_lookup + anchor.write_nr + wflush; plus stale,
  concur, meta, spin. Nothing is subtracted (rseq/wseq/wseq_end are inside check/wstart/wflush; no probe correction,
  M2 §19). Megalon >= 76 (lean sampling, CohSnap.reserved[1] bit 1, exported as `op.<o>.mg.flags`): every duration is
  a sum over timed sections only, so stale+concur+meta+spin are scaled by read_sections / check_sampled and C_write by
  write_sections / write_sampled (AnchorSnap.reserved[0], `op.<o>.mg.anchor.write_sampled`), per the shim contract;
  with MEGALON_COH_EVENTS=always (bit 2) those sums are full and not scaled (`op.<o>.mg.{event,write}_est_ns`;
  breakdown.py recomputes them from window deltas). The AnchorSnap
  fields (shim v3, Megalon >= 75; zeros with a v2 shim) are exported as `op.<o>.mg.anchor.<field>`, CohSnap.reserved[7]
  as `op.<o>.mg.lookup_ns_sampled` (raw). The server accepts shim API v2..v3. No separate validation copy: the row copy inside the section is the application's
  own copy, as in all-HWcc + stale, concur, meta, spin, wstart,
  wflush ns [measured] (switch_rw and reclaim are inside wstart, exported raw only).
- Stats keys: `op.<query|row_update>.{n,t_ns,c_ns,pc.c_ns,mg.check_est_ns,mg.event_est_ns,mg.write_est_ns}` and every raw field `op.<o>.pc.*`,
  `op.<o>.mg.*`; `op.coh_src` (threads with each source live), `op.tags` (measured / sampled / derived).
- Megalon background threads are not in CohSnap: their CPU is exported as `thr.nr-log-sync.*` and `thr.mg-bg.*`
  (threads Megalon spawns from the main thread during start-up inherit the name mg-bg).

## 7. Backends (`--backend plain|megalon`)
- plain (all-HWcc, Popcorn): records at fixed SWcc offsets (§2), direct loads/stores, MemC3 stripes (§4). Popcorn
  init_state=shared: `--preload-only` (node 0, plain mapping, no HWcc, before coherence is enabled) then `--preloaded`
  in the server run.
- megalon (Megalon-native, 2026-10-18; object granularity §7.1): objects of contiguous rows, created by node 0 at
  prepare, found by Megalon's index. Each row read is one read section on its object; write sections write whole
  rows (whole lines); `write_end` flushes the whole object. No application version table around the sections (§4).
  Every node checks every 4096th object id/size by ObjectLookup (`--check-stride`; vectordb checks all).
- Shim: the shared object-API shim `systems/megalon/shim` (`megalon_objapi.h`, `megalon_objapi.cc`, `build-shim.sh`
  -> `lib/libmegalon-objapi.so`, symbol `megalon_object_api`), generalised from vectordb's copy (which vectordb keeps);
  dlopen only for `--backend megalon`.
- v6: built on Megalon 75 (CohSnap + AnchorSnap, shim API v3); `build-megalon.sh <out> builds/megalon/75`. The legacy
  app-level timers (MegThr, clock_gettime 1 in N) are off by default (`--megalon-time-sample 0`); breakdown.py /
  check_breakdown.py use the CohSnap columns and add the legacy split only when N > 0.
- Stop: SIGTERM while waiting for the peer at start-up exits ("stopped (signal) ..."); a wait inside
  cxl::hwcc::app_init (systems/common) is not interruptible (known issue).
- Records: Megalon build >= 69 (deviation R1): with objects the record pool is logical_scr_size / 4 B, independent of
  the kv `slots` (systems/megalon/recsys-2vm.yaml: 245MB = 64.2M records at full size).
- Megalon thread registrations are never freed (max 32 per process): prepare work runs on a persistent pool
  (`--load-threads`, registered once); budget 1 + load + update + serve <= 32 (default 1 + 8 + 4 + 14 = 27).

### 7.1 Megalon object granularity (`--mg-rows-per-object N`; user decision 2026-10-18, reports/PAPER-direction-2026-10-18.md §3.2-§3.3, §5.5-§5.6)
- N = 0: one object per embedding table (MAIN configuration: the natural DLRM layout, one EmbeddingBag/TBE weight
  tensor per table). 26 objects; largest 26M x 576 B = 14,976,000,000 B, total 77,290,322,688 B at full size.
- N = 1: one object per row ("restructured best case": Megalon optimised by restructuring the application to its
  object unit). Same objects, ids, sizes and sections as 9819e1180/3ef27d8b6 (134,184,588 objects of 576 B).
- N > 1: objects of N contiguous rows (the last object of a table holds the rest). Sweep values: open (user).
- Object (k, c) = rows [c n, c n + n) of table k contiguously, n = N (N > 0, capped at rows[k]) or rows[k] (N = 0);
  id = `"RS"<<48 | k<<40 | c` (k < 26, c < 2^40, so no two (table, chunk) pairs collide; N = 1: c = row, the old id).
  Object bytes = rows in it x 576 (whole lines). `--print-layout --mg-rows-per-object N` prints the object count and
  the largest object.
- Prepare (node 0): ObjectCreate of every object (threads claim batches of global object indices), then the initial
  image in ONE write section per object: write_start, every row written in place through the section pointer (the API
  maps the whole object, so no chunking is needed), write_end (= whole-object flush + unlock). Objects >= 1 GiB log
  their fill and write_end times (`initial object table k chunk c: ...`).
- Serving: each row lookup = one read section on the containing object (read_start, copy the 576 B row, read_end,
  redo on failure). No MemC3 on the Megalon path, no application-level table lock.
- Updater: Megalon allows one writer per object (C3PO log), so ownership is the global object index (table-major)
  % U, not stripe % U. Each round (and each sample with T = 0), per owned object, ONE write section writes all
  touched rows of that object in address order; write_end flushes the whole object (paper semantics, D3 of M2). This
  is the application's own publication batch (Monolith touched-key push, §5), not an added optimisation.
  `update_sections` (stats) counts these sections (N = 1: = rows written; plain: 0). It is added after
  rows_written, not atomically, so a stats snapshot during a round can show sections > rows (host_test.sh checks
  the bound only on an idle stop snapshot).
- N = 0 limits: at most 26 owners (one per table), so U > 26 adds nothing, and with U = 4 the owners are k % 4
  (worker 0: tables 0, 4, 8, ..., 24 incl. the 26M-row tables 0 and 20; worker 1: 9 and 21; worker 3: 19; worker 2:
  none of the 26M-row tables). Every round each owner writes its tables' touched rows and flushes each whole table
  (up to 15.0 GB per table), so round time ~ sum of its tables' flush times: with whole-table flushes of seconds the
  Ekko rows/round are reached only if the round fits T, else `flush_overruns` and `update_rate_sustained=0`. A reader
  whose table changed waits while the writer holds the object (odd counter) and then flushes the whole object itself
  on the counter change (read_start/read_end PAGE_INCOHERENT). This is the expected collapse of the table
  configuration (Host measurements: §7.2).
- Capacity (Megalon ac0d92a, checked in source): object size is a size_t in ObjectCreate/the handle and an isize in
  the NR index entry (types.rs obj_entry, cn_array_[1]); the arena offset is in 64 B units under bit 62; the
  allocation is a bump pointer over object_arena_size (91 GiB in recsys-2vm.yaml >= 77.29 GB; objects are 576 B
  multiples, so object_align 64 adds nothing);
  the create log entry has a fixed size (CheckPut); cache_flush (helper.cc) and the replay flush (replica.rs
  flush_mem_region) loop over size_t/usize lines without chunk limits; write sections do not log. No per-object
  limit applies to a 15 GB object. Records: 26 objects need 26 records (pool 64.2M), so no reclaim/switch_rw after
  the first write of each table (N = 0). The first write of each object (RO -> RW, switch_rw) is a log event; in
  source its replay can flush the object on the peer (replica.rs obj_span), but flush-15GB showed node 1
  replay_flushes 0 (the counter is only kept with MEGALON_COH_DETAIL=1 in build >= 76, so 0 does not prove none
  happened; not measured). The recurring costs are the writer's write_end flush and the reader's flush on a
  changed counter.
- Layout hash: N != 1 appends ` rows_per_object=N` to the Megalon layout tag (both nodes must agree); N = 1 keeps
  the 3ef27d8b6 tag. The option is required with `--backend megalon` (no silent default) and rejected with plain.
- Deviations (this change): (a) N = 1 ownership is now global row % U instead of stripe(key) % U (both: one writer
  per row; sections, ids, sizes and data unchanged; only the row -> worker map differs); (b) the initial image of an
  object is written in one write section (one per row for N = 1, as before).

### 7.2 Host measurements (2026-10-18, builds/recsys-megalon/14 at 77ba0fa69, file region, CPUs 20-23 only)
Evidence: workspaces/recsys-table/host-test-1 (control dir). Host numbers only; the VM cost is not measured.
- Whole-object flush of one full-size largest table (14,976,000,000 B, tools/mg_flush_time.cc, 2 processes): initial
  write_end 0.480 s; per round (1000 rows written) write_end 0.474-0.499 s (mean 0.491 s), i.e. ~30 GB/s of
  clflushopt over lines that are mostly not cached. Node 1's one-row read sections: 0.51 us mean, but one read per
  round took 0.985-1.009 s = the writer holding the object during its write_end (~0.5 s) plus node 1's own
  whole-object flush on the counter change (~0.5 s; read_retry_incoherent 3 = rounds, flush_bytes 3 x 14.976 GB).
- recsys at ROW_DIV 6 (26 objects, five of 2.50 GB, 12.88 GB total), T = 1 s, 2000 samples/s: initial write_end of a
  2.32 GiB table 0.08-0.27 s; ~21.7 tables written per round (update_sections 390 / 18 rounds), round max 0.42 s, no
  overrun at this scale; node 1 read_retry_incoherent 415 (~ one whole-table flush per changed table per round per
  node); serving C = 55 % of query T (100.8 of 183.4 s), achieved 3.8 queries/s with p50 571 ms on 2 serving CPUs.
- Expected full-size behaviour (inferred, not measured): a 26M-row table costs ~0.5 s per whole-object flush on the
  Host, twice per round for a reader (writer hold + own flush), and each owner flushes all of its tables per round
  (with U = 4: worker 0 owns two 15 GB tables plus five smaller ones), so rounds take ~1-2 s on the Host and serving
  stalls ~1 s per changed table per round; on the VMs flush throughput may differ. This is the reason for the
  expected collapse of the table configuration, not a defect of the port.

## 8. Load generation and results
- loadgen plugin `recsys` (loadgen/recsys_plugin.cc): `--fixed update=<rate>` (v6: recsys-rate output), `--mix query=1`,
  `--slo query:95:100`, `--opt samples= queries= quantiles=` (or `pairs=N`), update_target 0, query_target 1,
  `--stats-op 10` (server stats incl. cxl::proc counters and VmRSS/VmHWM).
- Outputs: loadgen dir + `queries.bin` (88 B per query: pairs, status, times, lookups, probes, retries, misses,
  max_row_seq, mean score) + `recsys.txt` (counts, max published seq).
- 2-VM harness: CXL_SWMC/experiments/recsys/run.sh (Host) + scripts/guest/recsys-node.sh (guest), Megalon config
  systems/megalon/recsys-2vm.yaml; same structure as experiments/vectordb/run.sh.
- Main runs (reports/RECSYS-main-packet.md): experiments/recsys/session.sh keeps one server lifetime per system and
  runs several loadgen measurements against it (tables prepared once; recorded exception to "every run starts from
  the initial image"). The plugin's `seq_base=N` continues the update seqs (and the trace position) after the
  previous measurement's last seq, `wrap=1` wraps the trace instead of ending the stream; `recsys.txt` then reports
  `updates_made` for this run, `seq_base`, `last_update_seq`, `trace_samples`, `trace_wraps`.
  Host tests: tests/session_host_test.sh (SESSION_LOCAL=1), tests/check_breakdown_test.sh.

## 9. Deviations (from MOT1 §4.2 / MLPerf DLRMv2)
- D1 Tables capped at 26M rows (5 tables), raw id mod 26M (MOT1 decision; folds MLPerf rows together).
- D2 Synthetic inputs only: multi-hot expansion by hash (same distribution as MLPerf's table). Real day-23 data is used as is (v6).
- D3 (resolved 2026-10-18) v5/v6 used hash tables with linear probing instead of MLPerf's dense tables indexed by id;
  every system now addresses rows directly as MLPerf does (§2).
- D4 Random model weights (trained MLPerf weights not downloaded; compute cost unchanged).
- D5 Embedding values synthetic per (key, seq) (MOT1: synthetic values in the motivation study).
- D6 Inputs (v6): MLPerf day 23 multi-hot as is; time order of day 23 not verified.
- D7 Dense features are not used by the updater (no training); the serving bottom MLP uses them.

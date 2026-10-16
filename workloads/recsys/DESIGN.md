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
- 26 sparse features, one open-addressing linear-probing hash table each. Rows per table = min(MLPerf rows, 26M)
  (5 tables capped: raw id mod 26M; recorded deviation D1), 134,184,588 rows in total.
- Slots per table = ceil(rows / 0.8) rounded up to a multiple of 64: 167,731,776 slots in total.
- Slot (576 B, 9 whole cache lines): `key u64 | emb fp32[128] | seq u64 | csum u32 | pad`. key = (table + 1) << 56 |
  row (0 = empty slot); seq = update sequence that wrote the row (0 = initial); csum = FNV over key, seq and emb.
- 167,731,776 x 576 B = 96,613,502,976 B = 89.98 GiB of the 95.73 GiB SWcc. Tables are contiguous, table k after
  table k-1 (plain backend); Megalon places them as objects (§7).
- Slot count rounding (`slot_round` 64) is kept from v5 so the SWcc layout is unchanged (it no longer relates to
  version words, §4).
- Hash: home slot = splitmix64(key ^ seed) mod slots; linear probing; lookups stop at the key or an empty slot. Host
  test: 2.65 probes per lookup at load factor 0.8 (theory 3.0 for hits).
- Initial image (prepare, node 0, unmeasured): every row 0..rows-1 inserted in row order (placement computed in DRAM,
  deterministic), every slot (empty ones as zeros) written once with seq 0. Values are synthetic (§5).
- No deletes and no new ids during a run: every id of the trace maps to a preloaded row (raw id mod rows). The table
  is a hash table so that new ids could be inserted (MOT1 §1.3); this setup does not exercise inserts.

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

## 4. Atomicity: striped version table (HWcc app; v6, MemC3 NSDI'13 §3.2.1)
- `versions`: S = 2^16 u32 counters (`--ver-stripes`, power of two; libcuckoo kMaxNumLocks), 256 KiB; row key ->
  counter `mix64(key ^ seed ^ salt) & (S - 1)` (the key carries the table). App layout 266,240 B at full size. Replaces
  v5's one word per 64 slots; SWcc layout unchanged. Same layout in every system; the layout hash includes S.
- Writer (per row): CAS even -> odd on the row's counter, write the slot through the backend (Megalon: one write
  section), release-store +2. Update workers own rows by `stripe % U`, so they never share a counter.
- Reader (MemC3 optimistic): v1 = acquire-load of the looked-up key's counter (spin while odd: `seq_spins`), probe,
  copy the matching row, acquire fence, v2 == v1 else re-read that slot (`seq_retries`). Slots passed while probing
  need no check: keys never move and a key field is only rewritten with the same value (no inserts/deletes in a run).
- False retries (`false_retries`, per query and in stats): a retry where the row itself was not rewritten = the
  discarded copy was consistent (csum) and the re-read has the same seq. Approximation: a writer of the same row that
  completed between v1 and the discarded copy is also counted false (window: one 576 B copy).
- `--verify-rows 1` recomputes csum per hit (`torn_rows`, must be 0). Host evidence (v6): 0 torn rows in every run;
  `--test-no-seqlock` (negative) 177 torn rows in the hot T = 0 setting.

## 5. Updater, publication interval T and the Ekko operating points (v6)
- One `update` request = one sample (seq 1..). U workers (`--update-threads`, 4); every worker receives every sample
  and keeps the rows it owns (stripe % U == w) in a private map key -> latest seq (latest wins). Nothing in shared
  memory is read or written per sample; with T > 0 the sample is acknowledged on acceptance (workers independent, no
  all-worker completion per sample).
- Every T (`--publish-ms`, 60 s in the main runs) each worker publishes its touched rows once (Monolith §2.2.3):
  resolve the slot by probing SWcc, sort by address, write each row under its counter (§4); then `published_seq`
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
- Row values are synthetic: emb = f(key, seq, seed) in [-0.05, 0.05) (D5).

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
  start (slot resolve, writes under the stripes) to published_seq raised (rows visible); no per-row reply exists
  (samples are acknowledged on acceptance, outside T).
- C_o = delta of the thread's coherence accounting over the same intervals: Popcorn swmc_acct (fault_ns[3] + ipi_ns,
  measured; registered per serving/update thread, zeros before build 9; build 10's faults without an MSI transition,
  reserved[0..1], are exported as `op.<o>.pc.nontrans_{ns,cnt}` and are NOT part of C); Megalon shim v2 CohSnap: section checks by the
  ratio estimator [sampled x N]. DLRM's all-HWcc is the plain backend, so every Megalon call counts as C (M2 §16,
  "all-HWcc without Megalon"): C_read = (check_ns_sampled + anchor.read_lookup_ns_sampled + anchor.read_nr_ns_sampled)
  x read_sections / check_sampled; C_write = wstart + anchor.write_lookup + anchor.write_nr + wflush; plus stale,
  concur, meta, spin. Nothing is subtracted (rseq/wseq/wseq_end are inside check/wstart/wflush). The AnchorSnap
  fields (shim v3, Megalon >= 75; zeros with a v2 shim) are exported as `op.<o>.mg.anchor.<field>`, CohSnap.reserved[7]
  as `op.<o>.mg.lookup_ns_sampled` (raw). The server accepts shim API v2..v3. No separate validation copy: the row copy inside the section is the application's
  own copy, as in all-HWcc + stale, concur, meta, spin, wstart,
  wflush ns [measured] (switch_rw and reclaim are inside wstart, exported raw only).
- Stats keys: `op.<query|row_update>.{n,t_ns,c_ns,pc.c_ns,mg.check_est_ns}` and every raw field `op.<o>.pc.*`,
  `op.<o>.mg.*`; `op.coh_src` (threads with each source live), `op.tags` (measured / sampled / derived).
- Megalon background threads are not in CohSnap: their CPU is exported as `thr.nr-log-sync.*` and `thr.mg-bg.*`
  (threads Megalon spawns from the main thread during start-up inherit the name mg-bg).

## 7. Backends (`--backend plain|megalon`)
- plain (all-HWcc, Popcorn): slots at fixed SWcc offsets, direct loads/stores. Popcorn init_state=shared:
  `--preload-only` (node 0, plain mapping, no HWcc, before coherence is enabled) then `--preloaded` in the server run.
- megalon: one Megalon object per slot (id `"RS"<<48 | table<<40 | slot`, 576 B), created by node 0 at prepare (all
  167.7M, empty slots included), each slot access one read or write section; write sections write the whole slot
  (D3); `write_end` flushes the whole object (576 B). Version words stay in the app range (§4) around the sections.
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
- D3 Hash tables with linear probing instead of MLPerf's dense tables indexed by id (MOT1 decision).
- D4 Random model weights (trained MLPerf weights not downloaded; compute cost unchanged).
- D5 Embedding values synthetic per (key, seq) (MOT1: synthetic values in the motivation study).
- D6 Inputs (v6): MLPerf day 23 multi-hot as is; time order of day 23 not verified.
- D7 Dense features are not used by the updater (no training); the serving bottom MLP uses them.

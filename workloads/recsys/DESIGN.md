# recsys workload — DLRMv2-based recommendation system (design)

Status 2026-10-16: implemented and tested on the Host (file region, 2 processes); not run in the VMs.
Spec: reports/MOT1-motivation-plan.md §4.2 "Workload 2: recommendation system", H1 (T = 1 s), H3 (T sweep).
Report with the inputs audit, deviations and the draft VM packet: reports/RECSYS-design.md.

Limitation (as for every workload here): the two VMs share physically coherent memory, so a run proves the use of
each system's API and measures its coherence actions; it cannot prove a coherence protocol correct.

## 1. Roles
- Node 0 = updater: replays samples in time order at a fixed rate (loadgen stream `update`, ordered); every sample
  overwrites the rows of all its sparse ids (214 rows with the MLPerf multi-hot sizes). No training.
- Node 1 = serving: MLPerf DLRMv2 server queries (loadgen stream `query`): N consecutive samples (user-item pairs) of
  the query pool, N from `tools/dist_quantile.txt` (100..700, mean 270); embedding lookups + DLRMv2 dense part.
- Both nodes run the same binary and accept both ops; only the harness decides who gets what.
- SLO: query p99 <= 60 ms (MLPerf DLRMv2 server). Throughput = serving queries/s; updates/s reported next to it.

## 2. Tables (SWcc)
- 26 sparse features, one open-addressing linear-probing hash table each. Rows per table = min(MLPerf rows, 26M)
  (5 tables capped: raw id mod 26M; recorded deviation D1), 134,184,588 rows in total.
- Slots per table = ceil(rows / 0.8) rounded up to whole groups of 64: 167,731,776 slots in total.
- Slot (576 B, 9 whole cache lines): `key u64 | emb fp32[128] | seq u64 | csum u32 | pad`. key = (table + 1) << 56 |
  row (0 = empty slot); seq = update sequence that wrote the row (0 = initial); csum = FNV over key, seq and emb.
- 167,731,776 x 576 B = 96,613,502,976 B = 89.98 GiB of the 95.73 GiB SWcc. Tables are contiguous, table k after
  table k-1 (plain backend); Megalon places them as objects (§7).
- Hash: home slot = splitmix64(key ^ seed) mod slots; linear probing; lookups stop at the key or an empty slot. Host
  test: 2.65 probes per lookup at load factor 0.8 (theory 3.0 for hits).
- Initial image (prepare, node 0, unmeasured): every row 0..rows-1 inserted in row order (placement computed in DRAM,
  deterministic), every slot (empty ones as zeros) written once with seq 0. Values are synthetic (§5).
- No deletes and no new ids during a run: every id of the trace maps to a preloaded row (raw id mod rows). The table
  is a hash table so that new ids could be inserted (MOT1 §1.3); this setup does not exercise inserts.

## 3. Samples and queries (inputs)
- Sample record (proto.h `Sample`, 156 B): 13 dense fp32 (log(1+x) as in MLPerf preprocessing) + 26 raw one-hot
  sparse ids (uncapped). Files: `samples.h` header + records, time order.
- Multi-hot expansion (server, both nodes identically): element 0 = the id (mod rows), elements 1..h-1 uniform over the
  rows by a hash of (seed, table, id, j). MLPerf uses a fixed numpy-seeded lookup table of the same distribution
  (uniform); values differ (deviation D2). Sizes 3,2,1,2,6,1,1,1,1,7,3,8,1,6,9,5,1,1,1,12,100,27,10,3,1,1 (214).
  Consequence: 188 of 214 rows per sample are uniform random regardless of the id source, so the source of the
  one-hot ids (synthetic vs real Criteo) changes only 26 of 214 accesses per sample.
- Sources: `tools/gen_samples.cc` (synthetic; zipf or uniform per table; bring-up and Host tests only) and
  `tools/criteo_to_samples.py` (MLPerf/torchrec preprocessed Criteo 1TB day files, one-hot npy; untested on real data:
  no copy exists, see the report's inputs audit). Updates and queries should come from different time ranges
  (MLPerf evaluates on day 23).

## 4. Atomicity: one version word per 64 slots (HWcc app)
- `versions`: u32 per group of 64 consecutive slots of a table (2,620,809 words, 10.5 MB; app layout 10,485,760 B
  with header and node lines). Same layout in every system (docs/hwcc-contract.md); the layout hash includes every
  parameter.
- Writer: CAS even -> odd (several update workers may meet in one group), write the slot(s) in SWcc through the
  backend (Megalon: one write section per slot), release-store +2. Rows of one group in one publication round are
  written under one lock hold.
- Reader: acquire-load v1 (odd: spin), read the slot through the backend (Megalon: read section, may re-run), acquire
  fence, reload; v1 != v2 -> re-read (counted as `seq_retries`). Torn rows are therefore impossible by construction;
  `--verify-rows 1` recomputes csum per hit and counts mismatches (`torn_rows`, must be 0).
- Host evidence (file region): with the seqlock 0 torn rows in every run (13,877 retries in the hot test); with
  `--test-no-seqlock` (negative test) 3,963 torn rows detected in the same hot setting.

## 5. Updater and publication interval T
- One `update` request = one sample (seq 1..). U workers (`--update-threads`, 4); a sample is given to every worker;
  worker w owns the keys whose home group % U == w (per-key order kept, little lock sharing).
- T = 0 (`--publish-ms 0`): every row of the sample is written before the reply (rows sorted by slot, one lock hold
  per group). T > 0: the worker records touched keys (latest seq wins) and writes each touched row once per T
  (Monolith's touched-key push); the reply is sent on acceptance. `published_seq` (HWcc node line, min over workers)
  = every row of samples <= it is written. Overruns (a round longer than T) are counted (`flush_overruns`), never
  bursted.
- Row values are synthetic: emb = f(key, seq, seed) in [-0.05, 0.05) (MOT1: synthetic values, real id sequence).
  Accuracy experiments (MOT1 §6.1) would replace f by a recorded update trace; the write path stays the same.

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
- Records: Megalon build >= 69 (deviation R1): with objects the record pool is logical_scr_size / 4 B, independent of
  the kv `slots` (systems/megalon/recsys-2vm.yaml: 245MB = 64.2M records at full size).
- Megalon thread registrations are never freed (max 32 per process): prepare work runs on a persistent pool
  (`--load-threads`, registered once); budget 1 + load + update + serve <= 32 (default 1 + 8 + 4 + 14 = 27).

## 8. Load generation and results
- loadgen plugin `recsys` (loadgen/recsys_plugin.cc): `--fixed update=<rate>` (e.g. 2100), `--mix query=1`,
  `--slo query:99:60`, `--opt samples= queries= quantiles=` (or `pairs=N`), update_target 0, query_target 1,
  `--stats-op 10` (server stats incl. cxl::proc counters and VmRSS/VmHWM).
- Outputs: loadgen dir + `queries.bin` (88 B per query: pairs, status, times, lookups, probes, retries, misses,
  max_row_seq, mean score) + `recsys.txt` (counts, max published seq).
- 2-VM harness: CXL_SWMC/experiments/recsys/run.sh (Host) + scripts/guest/recsys-node.sh (guest), Megalon config
  systems/megalon/recsys-2vm.yaml; same structure as experiments/vectordb/run.sh.

## 9. Deviations (from MOT1 §4.2 / MLPerf DLRMv2)
- D1 Tables capped at 26M rows (5 tables), raw id mod 26M (MOT1 decision; folds MLPerf rows together).
- D2 Multi-hot expansion by hash, same distribution as MLPerf's numpy table, different values.
- D3 Hash tables with linear probing instead of MLPerf's dense tables indexed by id (MOT1 decision).
- D4 Random model weights (trained MLPerf weights not downloaded; compute cost unchanged).
- D5 Embedding values synthetic per (key, seq) (MOT1: synthetic values in the motivation study).
- D6 Inputs: until a Criteo copy exists the id sequence is synthetic (gen_samples); see the report's options.
- D7 Dense features are not used by the updater (no training); the serving bottom MLP uses them.

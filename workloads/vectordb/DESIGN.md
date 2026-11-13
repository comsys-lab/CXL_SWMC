# vectordb workload — design (E1)

Status: Step 1 of the approved plan (2026-10-14). Sections marked TBD are
fixed after the Megalon/Knowhere/Popcorn audits (reports/M2-*.md).

Goal: run one VectorDB workload unchanged on all-HWcc, Megalon and Popcorn and
compare coherence cost as throughput and latency under the same freshness
requirement (E1). Recall checks search quality on the same data state; no
policy is added to create recall differences.

Scope: 2 VMs, insert/delete/search, finite runs with a memory cap.
Out of scope: upsert, compaction/reclamation, failure recovery, heartbeats,
N>2 VMs, E2 behaviour, query-biased deletion, a new HNSW implementation.

Limitation: the VMs share physically HW-coherent memory, so tests here cannot
prove a SW coherence protocol correct; a missing flush can be masked by HW.

## 1. Region layout (shared by all systems, no hard-coded offsets)

One region config (`config/cxl_region.yaml`, overridable per run) is parsed
into a single `cxl_region` struct; nothing else defines offsets.

| key | default |
| --- | --- |
| device | /dev/dax0.0 |
| device_size | read from /sys/bus/dax/devices/<dev>/size (observed 103060340736) |
| hwcc_offset | 0 |
| hwcc_size | 268435456 (256 MiB) |
| swcc_offset | align_up(hwcc_offset + hwcc_size, align) |
| swcc_size | device end − swcc_offset (minus reserved ranges) |
| align | 2 MiB (min 4 KiB) |
| reserved | [] (ranges excluded from all systems, e.g. cxl_shm rings if Popcorn needs them) |

- Startup validation: no overlap, aligned, inside the device, no reserved
  conflict; otherwise refuse to run.
- HWcc use follows docs/hwcc-contract.md (2026-10-15): the vectordb control
  state (segment descriptors, counters, `applied` bitmap, P) lives in the
  `app` range below msg_ring, sized exactly by the layout computed from W,
  MAXSEG and nr_nodes (`CXL_APP_HWCC_BYTES`); the system (Megalon SCR) gets the
  rest of the 256 MiB. If it does not fit, fail at startup. Usage goes to the manifest.
- If Megalon fixes SCR size/base at compile time, values are generated from
  the same config and injected into its build; the mapping is recorded (TBD).
- In all-HWcc the SWcc area is also treated as HW coherent (baseline). Here
  `hwcc_size` is a logically enforced budget; it may be swept later.
- Shared-log body placement follows original Megalon (TBD), not forced into HWcc.

## 2. Operations and data

- Insert(id, vec): new id, never reused. Delete(id): exclude an existing id
  from search; no physical reclamation. Search(q, k=10).
- Main workload (user 2026-10-16): searches run while records are replaced
  by Update requests. Update(del_id, ins_id, vec) = delete one live record
  (chosen uniformly) + insert the next pool B record, one request to one node,
  applied and published by that node's writer in that order (two w_seq:
  w_del, w_ins = w_del + 1; not atomic: a snapshot s = w_del sees neither
  record), one response after both (WriteResp.w_seq = w_ins). Throughput and
  latency are per update (an update is one operation in total ops/s).
  Earlier runs (before 2026-10-16) sent independent Insert/Delete requests.
- Delete targets: uniform over the live set at trace time, fixed seed.
- Data: PubMed BGE 768-d (`binbin10/PubMed_bge`), split into disjoint
  pool A (initial N, e.g. 1M) and pool B (inserts). Replacements are between
  different documents. Queries: BioASQ question embeddings (BGE, precomputed).
- Insert-only traces are for bring-up; formats always include deletes.
- Index parameters (M, efConstruction, ef, metric) are fixed per run and
  identical across systems.

## 3. Trace

Generated once per experiment, deterministic seed, shared by all systems.
Since 2026-10-15 only the writes are pre-generated (tools/gen_writes.py: op, target, w_seq, id, vec_ref);
searches, their sched_t and ref_w are made at run time by the loadgen plugin (§9). The table below is the
logical request model.

| field | meaning |
| --- | --- |
| op_seq | global request order |
| op | INSERT / DELETE / SEARCH |
| id | record id (writes) |
| vec_ref | row in pool B (insert) or query set (search) |
| sched_t | scheduled arrival offset (ns) |
| target_vm | 0 or 1, the server that receives the request |
| w_seq | writes only: global write order, 1..W (generator-assigned, acts as TSO) |
| ref_w | searches only: last w_seq scheduled at or before sched_t |

- The generator tracks the live set, so each delete targets an id live at its w_seq.
- W is fixed per trace; a trace whose W exceeds the bitmap budget is rejected.
- Vectors travel in the request body (servers never read the pools directly).

## 4. Visibility and the E1 rule

- Each record stores ins_seq; each deleted id gets del_seq (∞ if never deleted).
  Snapshot s sees `ins_seq ≤ s < del_seq`. This is only what the fixed-snapshot
  rule needs; it is not a general MVCC/transaction system.
- E1: a search uses s = ref_w after the reader is ready for s (§5). This is a
  benchmark fixed-snapshot rule inspired by Milvus's wait-for-updates notion;
  it is not claimed to equal Milvus GuaranteeTs.

## 5. Publication vs reader readiness

Publication tracking: HWcc bitmap `applied[1..W]` (1 bit/write, no ring, no
wrap-around) and watermark P = max p such that all w_seq ≤ p are set. After
setting its bit a writer advances P with a CAS loop over contiguous set bits.

Writer completion for write w (one writer thread per VM, common to all systems):
1. write payload (vec, id, ins_seq) or delete-log entry (id, del_seq) to SWcc;
2. backend coherence write end (Megalon) / nothing (all-HWcc, Popcorn);
3. release-store the segment or delete-log `published_count` (HWcc);
4. set applied[w]; 5. try to advance P.
No barrier waits for other VMs' replay.

Reader readiness for snapshot s on VM r:
1. observe P ≥ s (acquire; wait otherwise);
2. take the segment list (§6);
3. replay both delete logs up to the `published_count` read after step 1 into
   the local `del_seq[]` (one cursor per log per VM, advanced under a mutex;
   a query waits or helps until the cursor reaches its count). Every delete
   with del_seq ≤ s was published before P ≥ s, so it is covered;
4. payload/index reads go through the backend coherence read (§7).

Visibility latency of write w at VM r: time when r has observed P ≥ w and,
for a delete, its replay cursor has passed the entry, minus w's arrival time.
A per-VM observer thread records P/replay progress timestamps; cross-VM clock
offset is measured at run start/end and recorded.

## 6. Segments (superseded by §11)

- Descriptor table in HWcc; VM v only uses slots [v·MAXSEG, (v+1)·MAXSEG).
  Fields: state (GROWING → SEALED → INDEXED), published_count, raw base ptr,
  index_ptr. A new segment's descriptor is fully initialised before
  `seg_count[v]` is release-incremented. Descriptors are never removed.
- Growing: only the owner VM's writer appends; readers flat-scan
  [0, published_count) with the snapshot filter.
- Seal at capacity C: owner sets SEALED and opens a new growing segment.
  SEALED segments are still raw-scanned.
- Background build (owner VM, fixed thread count): HNSW over all records of
  the sealed segment into a SWcc object → backend write end → store
  index_ptr → release-store state = INDEXED.
- Reader: after P ≥ s, acquire `seg_count[0..1]`; per segment read state once
  (acquire) and fix the path: INDEXED → index (with snapshot filter), else raw.
  A started query finishes on its chosen path; raw data and indexes are never
  freed. Raw and index paths cover the same id set under the filter.
- A record with ins_seq ≤ s lives in a segment published before P ≥ s, so it
  cannot be missing from the list; each segment is searched on one path only.
- Per query, record: raw-scanned records, indexed segments, build backlog
  (#SEALED). Path-mix differences are not coherence errors.
- Memory: no reclamation; runs stop before the SWcc cap; usage in manifest.
- Initial N records are loaded as sealed+indexed segments in prepare, outside
  the measured window, identically for all systems.

## 7. Backend adapter

- Allocation is real in every system (Megalon allocator; a bump allocator
  stub only for early bring-up).
- Coherence-only calls (no-op in all-HWcc and Popcorn):
  `vdb_coh_read(obj, body)`: begin → body → end; on validation failure the
  body (payload read + distance computation) re-runs. The body writes only a
  per-attempt local result, merged into the query top-k after success. Retry
  unit = one Megalon object read section, never the whole query.
  `vdb_coh_write(obj, body)` likewise.
- Common synchronisation (one writer per VM, HWcc atomics, release/acquire,
  P advance) is never compiled out.
- Megalon object granularity: one object per chunk (§12).
- Audit facts (reports/M2-megalon-audit.md): the all-HWcc Megalon flavor is
  FULL_COHERENCE (NO_COHERENCE means nothing is coherent). Artifact objects are
  fixed 1 KiB/4 KiB slots with copy-out Put/Get only; Knowhere needs contiguous
  in-place index memory (reports/M2-knowhere-audit.md). Popcorn's coherence
  hook covers only fsdax/FamFS faults, not devdax (reports/M2-popcorn-audit.md).

### 7.1 Atomicity vs coherence (agreed 2026-10-15)

Atomicity and coherence are separate problems.
- **HW coherence** gives a current value per cache line.
- **Atomicity of a multi-line update** (a 1 KiB value, a vector, an index node) needs object-level
  synchronisation, for example a seqlock (an optimistic reader-writer lock), in every system:
  all-HWcc, Megalon and Popcorn alike.
- **Placement.** These locks and other metadata live in the HWcc region in all three systems; Popcorn manages
  only SWcc data pages.

| | all-HWcc | Megalon | Popcorn |
|---|---|---|---|
| object atomicity | same mechanism in all three (seqlock or the publish protocol below) | same | same |
| coherence actions | none | tail check (index sync); write flush; pre/post-read checks (seq + log events); dynamic records | page faults and invalidation (kernel), 4 KiB granularity |
| read-only objects | — | no seqlock; mode changes detected through log events (post-read tail check) | — |

- **kv-store** (reports/M2-first-runs.md): one 1 KiB record = one seqlock. Megalon allocates the record only for
  read-write-shared objects. The hwcc flavor keeps a seqlock on every object and drops only the coherence
  actions.
- **vectordb (this design):**
  - Atomicity comes from the publish protocol: payload written beyond `published_count`, then a release store;
    readers acquire and read only up to that point. Sealed segments and index blobs are immutable. So all-HWcc
    needs no per-object lock.
  - Megalon's per-object records (append chunk / index blob / delete-log chunk; phase B extent chunks,
    reports/M2-phaseB-extents.md) serve coherence detection only.
  - The comparison therefore isolates coherence cost on top of identical synchronisation.
- **Read-only correctness.** Sealed data is read on Megalon's RO path. Its correctness depends on:
  - the post-read tail check (megalon fix 5acf086/e806494, reports/M2-first-runs.md attempts 9-11);
  - the RO first-read flush ([C2], port design §6).

## 8. Ground truth and metrics

- GT: exact top-10 of the ref_w snapshot of the common trace, computed offline
  (top-K' per query over all pools, filter by (ins_seq, del_seq), brute-force
  fallback when < 10 remain). Never computed during measurement.
- Metrics: search QPS, p50/p99 (from scheduled time), update/s (earlier runs: insert/s and delete/s
  separately), visibility latency, recall@10 (timeouts/unserved count as
  misses; success-only value also reported), write backlog over time, timeouts,
  cost counters (Megalon: flushes/bytes, read retries, log replays; Popcorn:
  faults, invalidations).
- Minimal profiling: per query, snapshot-mask build time vs search time. If the
  O(N) mask dominates, consider reusing a segment's mask as s grows; nothing more.
- Pilot: how much the exact top-10 changes over the uniform trace (reported
  only; does not change the deletion policy).
- Sweeps: (a) fixed write rate, rising search rate; (b) fixed mix
  (9:1, 8:2, 2:1), rising total rate. ≥3 repeats; immutable result dirs with
  manifest (CLAUDE.md "Experiments").

## 9. Load generation (implemented 2026-10-15)

- Generic engine: CXL_SWMC/experiments/loadgen (open-loop, latency from the scheduled time, warmup, steps,
  max throughput under SLO by ramp + bisection + confirm repeats; README there). Binary frames over TCP
  (frame.h; python/frame.py for Python callers such as a LangChain VectorStore).
- vectordb plugin (loadgen/vectordb_plugin.cc): stream `update` (ordered; writes file from
  `tools/gen_writes.py --mode update` = DELETE w, INSERT w+1 pairs with one target, checked at init; each pair is
  one kOpUpdate request) and stream `search` (query row and target drawn with the seed). Searches are made at run
  time, in global schedule order, so ref_w = the last write made before the search = the insert w_seq of the last
  update scheduled at or before it (E1, §4). The trace therefore holds only the write order; rates come from the
  loadgen step. (Until 2026-10-16 the stream was `write`: one request per INSERT/DELETE record.)
- GT/recall: tools/compute_gt.py after the run from writes + searches.bin (also counts E1 violations:
  returned ids not visible at the snapshot).
- Loadgen pinned to Host node1 CPUs; requests go straight to target VMs (no coordinator).

## 11. Shared HNSW segments (implemented 2026-10-15; replaces §6 growing/sealed segments)

User decisions 2026-10-15: incremental HNSW updated in place in shared memory; one shared index written by all
VMs (no per-VM graphs); Qdrant-style segments, count = CPUs of the VM socket (host node0: 32 logical CPUs =
2 VMs x 16 vCPUs; stays 32 with 8 VMs); every node writes every segment under an HWcc reader-writer lock.
- Segment s holds records with id % S == s; one HNSW graph per segment (server/shm_hnsw.h: port of hnswlib,
  same level/search/heuristic/connect algorithm and parameters M 16, efConstruction 128, query ef 64).
- HWcc (region.app): per segment a writer-preferring rwlock line (hwcc_app.h) and the graph meta line (entry
  point/max level, element count, upper-arena cursor); plus P, applied bitmap, per-node lines.
- SWcc: per segment level-0 slots (header line + level-0 links + vector, whole lines) and upper-level links.
- Insert (owner = receiving VM's writer): write lock of segment id % S, hnswlib addPoint, unlock, then applied/P.
- Search: wait P >= s, replay delete logs, then each segment under its read lock: hnswlib searchKnn with a
  result filter (ins_seq <= s < del_seq), merge top-k. One query fans out over its segments like Qdrant
  (SegmentsSearcher::search, one task per segment): the starting worker does the P wait and the delete replay, then
  publishes one task per segment (server.cc QueryCtx, since 68e8b22d9); idle workers claim them, running queries first.
- Initial pool A: tools/build_index.cc builds the 32 segment images offline (one thread per segment, seed + s,
  deterministic); node 0 copies them into SWcc at prepare.
- Why (Host pilot 2026-10-15): the growing/sealed design drifted (brute-force growing segments: search cost 9 ->
  25 ms within one SLO search, confirm failed); the shared graph keeps per-query cost nearly constant (distance
  computations +3% over 105k writes) and puts fine-grained shared writes where the coherence systems differ.
- Host pilot (node1, 2 processes x 12 search threads, shm file, 1M records, writes 500/s, search p99 <= 50 ms):
  max under SLO 521 +- 2 search/s (3/3 confirm), p99 30 +- 1 ms, recall@10 0.997, E1 violations 0, ~6 min.

## 12. Megalon backend (implemented 2026-10-15)

User decisions 2026-10-15: follow the paper as is (no coherence optimisations of our own); one Megalon object per
indexing unit; Megalon flushes the whole object at write end (no dirty-line tracking); D3 write contract.
- Selection: `vdb-server --backend plain|megalon`; `Server<Backend>` and `HnswT<Accessor>` are compiled once per
  backend, so the plain path is the old code with direct pointers (tools/build_index output byte-identical).
- Objects (server/megalon_backend.h, deterministic ids `0x5644<<48 | kind<<44 | a<<24 | b`): per segment s and group g
  a vector chunk (kind 1, `vchunk_bytes`) and a link chunk (kind 2, `lchunk_bytes`); per node u the delete log in
  chunks of `dlog_chunk` 64 B entries (kind 3). Node 0 creates all objects at prepare (before it publishes `loaded`);
  every node checks every id and size by ObjectLookup before warm-up. Production size (2M ids, 32 segments, 32 MiB
  chunks, 2 x 8M deletes): 7.43 GiB of objects (`object_arena_size` 8GB, systems/megalon/vectordb-2vm.yaml).
- Sections (one per chunk access, never nested): distance = read section over the vector (dot product inside,
  result kept only if ObjectReadEnd accepts); header / vector / link block reads copy into per-attempt scratch;
  a link update reads the block in a read section, then writes the whole block (3 or 2 lines) in a write section;
  an insert writes header + vector (49 lines) in one write section on the vector chunk and zeroes its level-0 and
  upper blocks in one write section on the link chunk; a delete writes one 64 B entry in a write section; replay
  copies the published entries chunk by chunk in read sections and applies them after the section. Initial images
  are copied by node 0 in one write section per chunk; warm-up reads every populated chunk in read sections.
- HWcc: unchanged (segment rwlocks, graph meta, P, applied, node lines in region.app). Megalon maps the whole device
  at map_va when its library initialises; the server checks that mapping in /proc/self/maps and never maps the device.
  The layout hash includes ` backend=megalon` (plain hash unchanged), so both nodes must run the same backend.
- Packaging: the server does not link libmegalon (its static constructor maps the device and waits in the start
  barrier at load). `lib/libvdb-megalon.so` (server/megalon_shim.cc, linked against libmegalon) is dlopen()ed only for
  `--backend megalon`; build with server/build-megalon.sh <out> builds/megalon/<n> (flavor megalon, `--wmeta packed4`).
- Run: `RACKOBJ_CONFIG` (object_arena_size > 0), `CXL_APP_HWCC_BYTES` (also carves Megalon's hwcc_alloc), node 0 with
  `MEGALON_REINIT=1` unless the control block is empty; MEGALON_NODE_ID / MEGALON_RUN_ID / CXL_REGION_CONFIG default to
  --node / --run-id / --region (a contradicting value is refused). At most 32 registered threads per node: main,
  writer and the search workers (`--search-threads` <= 30). The server exits with _Exit (no Megalon teardown
  barrier), so the next run's node 0 needs MEGALON_REINIT=1. Server stats add `megalon.*` object counters
  (sections, retries, flushes, replay flushes).
- Deviations / notes: segment atomicity stays with the HWcc rwlock (§7.1), Megalon only provides coherence; the
  per-access section granularity follows "one section per object access" and is not batched. Host functional test
  (2026-10-15, /dev/shm file region, 20k + 50k subset, 1 MiB chunks, 2 x 4 search threads): recall@10 0.9998,
  invisible_returned 0, timeouts 0 (also with 256-entry delete-log chunks and inserts crossing into new groups);
  read retries (incoherent) occurred and were re-run. A file region is HW coherent, so this proves the API usage,
  not the coherence protocol (see Limitation above).

## 13. Measurement (implemented 2026-10-16; MOT1 v4 H1 "Instrumentation", §4.3; coherence behaviour unchanged)

- Stats request (kOpStats = 10, text): server counters (`updates`, `inserts`, `deletes`, `searches`, `P`,
  `search_busy_ns` = worker time on query/segment tasks, `writer_busy_ns`, `update_ns`, `*_ns_total` times), the
  backend's counters (Megalon `megalon.*` object counters and `megt.*` wrapper timers) and
  `systems/common/proc_stats.h`: per thread role (threads named `vdb-search`, `vdb-writer`, `vdb-conn`,
  `vdb-listen`; main = `vdb-server`; threads Megalon starts while it initialises inherit `megalon-lib`, its log
  thread names itself `nr-log-sync`) CPU ticks and schedstat run/run-queue-wait ns, per-thread Popcorn counters
  (`/proc/self/task/<tid>/swmc`, Popcorn build >= 8) summed per role, `cxl_recv*` kernel-thread CPU, `/proc/interrupts`
  TLB/CAL/RES/LOC, `/proc/stat` cpu, page faults, sysfs counters of `/sys/kernel/swmc/page_coherence`,
  `/sys/kernel/swmc/instr`, `/sys/kernel/cxl_shm` and `/sys/kernel/cxl_shm/instr` (keys `sys.swmc.page_coherence.*`,
  `sys.swmc.instr.<file>.<name>`, `sys.cxl_shm.*`, `sys.cxl_shm.instr.<file>.<name>`). A snapshot reads /proc and sysfs
  (Host test: ~15 ms; it runs on the connection's reader thread).
- Per measured step: loadgen `--stats-op 10` takes a snapshot per node at the window start and end; offline
  `experiments/loadgen/stats_delta.py` (deltas) and `export_csv.py` (derived columns) — experiments/vectordb/README.md.
- Megalon wrapper timers (server/megalon_backend.h): 1 in 64 read sections (random per section) timed as
  read_start / body / read_end; failed attempts of timed sections timed in full; every write section timed
  (write_start, body, write_end incl. flush). `rd_retries` counts every failed ObjectReadEnd. ObjectReadStart's
  internal "incoherent" flush-and-retry (`megalon.read_retry_incoherent`) is inside read_start time, not a retry.
- (vdb builds <= 9; replaced by §16 in builds >= 10.) False-sharing log (`--trace-dir`, Megalon only; run.sh TRACE=1, fixed-load runs only, MOT1 v4 H2 step 2). HWcc
  lines in the app layout of every backend (plain never touches them; Megalon only with --trace-dir): `wsec`
  (write sections completed by all nodes) and `objseq[o]`, one u64 per Megalon object (vector and link chunk per
  segment group, delete-log chunks per node; `Params::trace_objects()`), = wsec seq of the object's last write
  section. The node's cache (node-wide array) mirrors Megalon's per-node local seq (src/core/c3.cc): 0 = none
  (never seen here; Megalon's local seq is nullopt and its first read does not flush), set by an accepted read and,
  unconditionally, by this node's own write_end (write_seq_end sets the local seq); after a failed read_end
  (Megalon resets the local seq) the accepted re-read sets it to the objseq loaded before that attempt. Per write
  section (after write_end): wsec fetch-add, objseq[o] = seq (inside the segment write lock or the node's own
  delete log, so one writer per object), cache = seq, log (seq, object, written ranges). Per read section: one HWcc
  load of objseq[o]; first sight (cache 0) only initialises the cache (megt.trace_first_sight); past a non-zero
  cache (CAS: one thread per transition) a write section completed on o since this node last saw it, so
  ObjectReadStart flushes and re-reads o (Megalon's "incoherent" retry): refetch log (object, read range, old seq,
  new seq). Unit test: tests/megalon_trace_test.cc (fake object API). Per read attempt: wsec load before read_start; a
  failed read_end logs a retry (object, read range, s0, s1 = wsec after the failure). Dumped at stop as
  `node<K>.megalon-{wsec,retry,refetch}.bin`. `tools/classify_retries.py`: peer write sections with seq in (s0, s1]
  on the same object: overlapping range = true sharing, disjoint = false sharing, none = unexplained (refetch with
  only own writes = local_only, excluded); retries, refetches and combined; with `--stats --step` per-node window
  counts next to megalon.read_retry_incoherent (counts ObjectReadStart's incoherent retries and incoherent failed
  read_ends) as a sanity check. Limits: a refetch carries the range of the first read after the change; a write
  between the objseq load and read_start is attributed to the next read; concurrent readers on one node may make
  Megalon flush more than once per transition (logged once).
- Where the flush time lands: a refetch's flush and re-read are inside ObjectReadStart, i.e. in rd_start_ns
  (export column meg_rd_check_s); a failed read_end's flush is inside the failed attempt (meg_reexec_s).
- Cost. Wrapper counters are thread-local blocks summed at stats time (no shared writes); without a trace: per read
  section an xorshift + branch, 1 in 64 sections 4 clock_gettime; per write section 4 clock_gettime. TRACE=1 adds per
  read section one HWcc load (objseq) + a node-local cache load (CAS on a change), per attempt one HWcc load (wsec),
  per write section one HWcc fetch-add + CAS, and log appends under one mutex (writes: writer thread; retries and
  refetches: any thread) - fixed-load runs only.
- Host smoke test: tests/host_smoke.sh (2 processes on a scratch file, plain or Megalon); unit tests
  tests/plugin_pairs_test.cc, tests/classify_retries_test.py, experiments/loadgen/test/stats_delta_test.py.

## 14. Per-query coherence time (vdb build 9; superseded by §15 in vdb builds >= 10, kept for earlier runs)

- Every search response carries its own coherence time: `SearchResp.flags & kRespCoh` and a `SearchCoh` block
  (proto.h) after ids/scores (old clients ignore the trailing bytes). Search-serving threads only; the writer is
  reported separately by the window counters (thr.vdb-writer.swmc.*, megt.writer.*). The window time-share
  (stats deltas / searches) stays.
- Attribution (server/qcoh.h, server.cc qc_*): a query = its start section (E1 wait + delete-log replay) + one task
  per segment, run by any search thread. Between sections a search thread touches no shared memory (queues, merge,
  reply are process-local), so each search thread reads its own counters once at the end of every section and adds
  the change since its previous section end to the query (under QueryCtx::mu, before done.fetch_add, so the
  finishing thread sees all sections). A search whose E1 wait times out gets no response: its section delta is
  counted in `qcoh.unattributed_*`, not carried into the next query.
  - page MSI: `/proc/thread-self/swmc` (Popcorn build >= 8), one fd per search thread, `pread` at offset 0 and parse
    (`qcoh.swmc_read_ns` = median read cost at start). Read on every system whose kernel has the file (H1 runs all
    three systems on build 8: identical overhead; all-HWcc and Megalon read zeros with cxl_shm unloaded). Fields:
    fault handler time, message wait, local wait, faults, transactions (read + write).
  - Megalon: deltas of the thread's own MegTimers block (owner-only writes). Estimate per query: checks =
    max(0, read_start + read_end - 2 clock_ns x sampled) x 64; re-executed work = retries x mean failed attempt
    (timed failed attempts minus 3 clock_ns each: the t3 - t0 interval holds three clock reads; none timed: mean
    sampled section minus 3 clock_ns). Raw sums travel in the block. Known deviation (vdb build 9, not rebuilt):
    the server's mg_reexec_est_ns and coh_ns subtract only 1 clock_ns per timed failed attempt (overstate by ~2
    clock_ns per retry); experiments/vectordb/qcoh.py recomputes re-executed work and coh from the raw sums and
    never uses those two fields. Per-query Megalon p50/p99 are distributions of sampled (1 in 64) estimates; means
    are the robust quantity.
- Timer fix (Megalon): `clock_ns` = median of back-to-back CLOCK_MONOTONIC reads at server start (`megt.clock_ns`,
  `qcoh.clock_ns`); every timed interval contains about one read's cost, subtracted in the estimates (the counters
  stay raw). Wrapper blocks carry their thread's role (thread_init: 0 main, 1 writer, >= 2 search): stats print
  `megt.<name>` (all, as before) and `megt.{main,writer,search,other}.<name>`.
- `busy_ns` = thread time of the query's sections. Segment tasks run in parallel, so coh_ns and busy_ns are sums of
  thread time and can exceed the latency; `experiments/vectordb/qcoh.py` reports both, coh/busy, and coh/busy x the
  server time (wall-equivalent).
- Output: loadgen plugin `search-coh.bin` (CohLog: seq, recv_ns, measured, target, status + SearchCoh);
  `experiments/vectordb/qcoh.py RUN` -> `qcoh-steps.csv` (per measured step: per-query mean/p50/p99 and parts,
  window time-share of search threads, writer per update, matched by the request's done time to the raw-step
  records). `--query-coh off` disables reads and the block.
- Tests (Host): tests/build_qcoh_test.sh (reader on fixture files in the kernel's format, estimate rule, clock),
  tests/host_smoke.sh + tests/qcoh_check.py: `VDB_QCOH_FAKE=1` (plain; fake source = a segment's distance count:
  per query fault_ns = dists exactly), BACKEND=megalon (sum of per-query sampled sums = megt.search totals; role
  blocks sum to megt.*), plain without the swmc file (source none, coh 0).

## 15. Per-operation time split (vdb build >= 10; MOT1 v6 Fig 2 and 3b, reports/MOT1-v6-redesign-draft.md §3, §4.2)

- Operation = search or update (delete + insert pair). Sections: search = start section (E1 wait + delete-log replay)
  + one per segment task, on any search thread; update = one section on the writer (delete, publish, insert, publish).
  Per section, on the thread that runs it: plain rdtsc at start and end (no fences; T) and the thread's coherence
  counters at start and end (C). Sums over the operation's sections (server/opcoh.h OpAcc).
- C sources: Popcorn `struct swmc_acct` registered per worker thread (systems/popcorn_new/include/swmc_acct.h,
  build >= 9), read with `swmc_acct_snapshot()` (build 12 update sequence in reserved[2]); only if registration
  fails, /proc/thread-self/swmc at the section end (delta since the thread's previous section end) with the
  transition-fault keys is_/sm_/wpu_fault_ns + nontrans_* (build >= 9; read_/write_fault_ns read 0 on build 12
  without instr/detail=1) or, on build 8, read_/write_fault_ns (no IPI); else none; Host tests `VDB_OPCOH_FAKE=1`
  (the server adds dists of a segment task as I->S ns, dists/8 as IPI ns, 1000 ns S->M per update). Megalon:
  `mshim::CohSnap` via the shared shim (systems/megalon/shim, libmegalon-objapi.so; API v2 `thread_coh`). Megalon <= 70
  has no per-thread accounting: build-megalon.sh then builds server/megalon_objapi_fallback.cc (thread_coh = nullptr,
  compiled against the build's own rackobj.h) and Megalon C is 0 (`opt.meg_coh=0`). C = Popcorn fault_ns[0..2] +
  ipi_ns + Megalon checks (ratio estimator check_ns_sampled x read_sections / check_sampled, read sections only;
  CXL_SWMC 2015a31f3; per operation with its own counts, step means with the step's sums) + stale + concur + meta +
  spin (incl. NR combiner / replica read-lock waits) + wstart + wflush + validation copies (user decision
  2026-10-16, MOT1 v6 §3.1: C = only work all-HWcc does not do; the Megalon accessor's copies of header / vector /
  link block / delete-log entries into per-attempt scratch, which the plain backend reads in place; every copy
  counted, 1 in 64 timed with rdtsc, ratio estimator; shm_hnsw.h validation_copy, opt.<op>.meg.vcopy_{ns_sampled,
  sampled,cnt}; in-place distance computations are not copies) + Megalon anchor work (shim API v3 AnchorSnap, Megalon >= 75;
  reports/M2-megalon-port-changes.md §16): vector DB's all-HWcc has no Megalon, so every Megalon call is C: read
  lookup + read NR (sampled, ratio estimator x read_sections / check_sampled) and write lookup + write NR, which
  Megalon excludes from check / wstart, are added; rseq (inside check), wseq (inside wstart), wseq_end (inside wflush)
  are exported only. Stats `opt.<op>.meg.anchor.<AnchorSnap field>`, `opt.meg_anchor`; opsplit `mg_an_*`. Shim
  versions >= 1 are accepted (fields are appended; thread_coh from v2, thread_anchor from v3) (switch_rw and reclaim are inside wstart;
  reports/M2-megalon-port-changes.md §13). Megalon background threads (nr-log-sync replay,
  WriteMetadataManager reclaim) are not in CohSnap: their CPU stays in the window counters (thr.megalon-lib.*,
  thr.nr-log-sync.*; Popcorn kthr.cxl_recv*), exported next to the split.
- Megalon >= 76 lean sampling (vdb build >= 15; megalon_objapi.h, reports/M2-megalon-port-changes.md §18): counts
  stay exact, but every Megalon duration is a sum over timed sections only (a jittered 1 in check_sample of the read
  sections and, separately, of the write sections). OpCoh src bit 4 = lean (CohSnap.reserved[1] bit 1), bit 5 =
  MEGALON_COH_EVENTS=always (bit 2); `mg_write_sampled` (former pad2) = AnchorSnap.reserved[0] delta. C then uses
  read-side events (stale + concur + meta + spin) x read_sections / check_sampled (full sums with events_always) and
  write side (wstart + wflush, write lookup + write NR) x write_sections / write_sampled (proto.h RD / EV / WR; per
  operation with its own counts, step means with the step's sums; opsplit tags ev / wr columns sampled×N /
  sampled-write×N for such runs). Window keys `opt.<op>.meg.anchor.write_sampled`, `opt.<op>.meg.flags` (bits 1-2).
  Megalon <= 75 records (bit 4 clear) keep the plain sums. No probe correction (build 77 probe cost, M2 §19; user
  decision 2026-10-17: keep raw). Raw probe data only in the server stats dump, not in OpCoh:
  `opt.<op>.meg.anchor.{timed_a,timed_bc,timed_d}` (sums of AnchorSnap.reserved[3..5] deltas) and
  `opt.<op>.meg.anchor.probe_ps_{min,max}` (reserved[2] over the threads seen; values, not counters).
- Modified bytes (Fig 3b reference line): thread-local `t_mod_bytes` (shm_hnsw.h) counts the whole lines the
  application stores: vector record + zeroed level-0/upper link blocks (write_elem), each committed link block,
  each 64 B delete-log entry. Written back (Fig 3b): Megalon CohSnap wflush_bytes; Popcorn (S->M + wp faults) x 4 KiB.
- T = server processing from the worker's dequeue of the request to the response being ready (search: start
  section, segment tasks and the final merge on the finishing thread; update: the writer section); queueing before
  the dequeue and the socket send of the reply are outside T (the copy of the few-hundred-byte reply into its buffer
  after the block is built is not counted). Popcorn no-transition coherence faults (swmc_acct reserved[0..1], build
  10) are exported as their own component (`pop_nontrans_*`, `opt.<op>.pop.nontrans_{ns,cnt}`), NOT part of C.
- Transport: proto.h `OpCoh` v2 (312 B; carries the frame req_id) after the search results (SearchResp.flags kRespCoh) and after WriteResp on
  update responses; the loadgen plugin writes `op-coh.bin` (OpLog 336 B). Window counters in the stats text in the
  KV convention (workloads/kv/server/opsplit.h): `opt.version`, `opt.tsc_hz`, `opt.meg_coh`, `opt.meg_check_sample`,
  `opt.<search|update>.{ops,sections,t_ns,c_ns,mod_bytes}`, `opt.<op>.pop.{is,sm,wp}_{ns,cnt}`, `.pop.ipi_{ns,cnt}`,
  `opt.<op>.meg.<CohSnap field>`; `opcoh.*` = source, errors, timed-out search sections (unattributed).
- Offline: `experiments/vectordb/opsplit.py RUN` -> `opsplit-steps.csv` (one row per measured step and operation
  type) + `opsplit-steps.columns.csv` (tag per column: measured / sampled×N / derived, unit, formula). Op records are joined to
  loadgen raw rows by the frame req_id (OpCoh.req_id = loadgen rawid-step<N>.bin, loadgen >= dd934dbd9); runs without
  the sidecar fall back to the response time window (column `match` = time). No proportional
  wall-equivalent columns; no per-operation C percentiles or window C (the per-operation ratio estimate of Megalon's
  checks is biased; C means use the step's sums). A run whose records carry more than one coherence source is
  refused; pop_source / mg_cohsnap are exported per step. Search E1 wait (polling P) is a separate column `wait_ms`
  inside T (OpCoh.wait_ns, `opt.<op>.wait_ns`). Fig 3b Popcorn written-back bytes per update = window delta of
  `sys.swmc.page_coherence.remote_writeback_count` (nodes summed) x 4 KiB / opt.update.ops; (S->M + wp) x 4 KiB is
  exported only as `m_acq_bytes_pop` ("M acquisitions x 4 KiB"). m4-run.sh requires OPCOH_EXPECT for measurement
  runs, bound to the system (Popcorn swmc_acct, Megalon cohsnap, all-HWcc none). `--op-coh off` disables reads and
  blocks.
- Cost per section: two rdtsc, two reads of the thread's area (Popcorn: plain loads; Megalon: two thread_coh calls).

## 16. Sharing trace (vdb build >= 10; MOT1 v6 Fig 3c, draft §4.3; dedicated runs only, off by default)

- `--trace-dir DIR` (Megalon backend; run.sh TRACE=1): per section one 32 B `TraceRec` (megalon_backend.h) in the
  thread's own buffer (2 MiB chunks, cap `--trace-max-mb`, default 4096 per node; overflow counted as dropped),
  dumped at stop as `node<K>.vdbtrace.bin` (TraceFileHdr, then per thread TraceThreadHdr + records).
  - write section: object (dense index), element, units, seq = global write-section number (HWcc `wsec` fetch-add
    inside the section, after the body and before ObjectWriteEnd: an accepted reader that loads wsec after its
    ObjectReadStart has seen exactly the writes on the object with seq <= its value);
  - read section: object, element, units, seq = wsec loaded after the accepted attempt's ObjectReadStart, flags =
    (A) CohSnap.stale_cnt delta | (B) CohSnap.concur_cnt delta << 4 (without CohSnap: failed read_ends), ev_ns =
    stale_ns + concur_ns delta, tsc. Identical consecutive flagless reads of a thread are kept once.
  - elements: vector chunk slot, delete-log entry, link block (slot | level << 24); units = consecutive elements
    (link: levels); 0 = whole object (initial copy, warm-up).
- `tools/classify_sharing.py DIR` -> sharing.csv/.txt: an event of node n on object O is true sharing if n reads an
  element modified by the causing writes (peer writes on O with seq in (seq_prev, seq_seen], seq_prev = n's latest
  refresh point on O: previous event, own write, or first read) before n's next event on O; counts per role and
  (A)/(B), time shares (ev_ns), events per search. `--a6-dir` writes the CSV input of
  experiments/analysis/v6_fig3_megalon.py c. HWcc `objseq` lines are no longer used (stay 0). numpy implementation:
  1.6M records in 1.0 s, ~130 B per record peak (two nodes at the 4096 MiB default cap ~35 GB; use --trace-max-mb
  <= 2048 or run it pinned to node 1).
- Overhead (Host, tiny dataset, 10/90 mix, load average ~38, single runs): Megalon 70 (no CohSnap): search T p50
  +9-14 %, update +4-14 %; Megalon 71 (two thread_coh calls per read section): search T p50 +31-86 %, update +27 %;
  server-measured per-read-section cost 12-22 ns (70) / 211-474 ns (71). Trace runs therefore never feed Fig 1/2.
- Tests: tests/megalon_trace_test.cc (fake API v2 with thread_coh) + tests/classify_sharing_test.py (constructed
  true/false/no-prior-copy events); host_smoke.sh BACKEND=megalon TRACE=1.

## 17. Update-rate sweep: absolute update stream, several writer threads (vdb build >= 16; user 2026-10-19)

Brief: reports/VDB-update-rate-axis-brief.md; packet reports/VDB-urate-packet.v1.md; harness
experiments/vectordb/urate-block.sh (m4-run.sh KIND=urate). H1 (YCSB-style mixes, builds vdb/15) is unchanged.
- Load: an absolute update stream of R updates/s (loadgen `--fixed update=R`), independent of the search rate
  (`--mix search=1`, the swept x); the SLO search uses the RecSys knee ramp (state/PROJECT.md "RecSys experiment
  methodology": start low, >= 100 searches per step, low-rate failures recorded, `--ramp-knee 2 --ramp-knee-floor 1.5`).
  Updates go to the VM named in the writes file (uniform per update pair, gen_writes.py seed), identical for every
  system and rate.
- Writer threads (`--writer-threads N`, default 1 = every earlier build; N > 1 plain backend only): N threads per node
  pop the node's single write queue. Correctness:
  - segment writes (hnswlib addPoint, graph meta, the segment's Graph object scratch) stay serialised by the segment's
    HWcc writer-preferring rwlock (id % S), across threads and nodes, exactly as across nodes before;
  - an update's DELETE and INSERT are one job, run by one thread in that order (w_del published before w_ins);
  - the node's delete log: index allocation, entry write and the release of `dlog_count` run under a node-local mutex,
    so `dlog_count` never covers an unwritten entry (readers replay [cursor, dlog_count)); with N = 1 no lock is taken;
  - applied bitmap and P: unchanged (fetch_or of the bit, CAS loop over contiguous set bits); writes of one node may now
    complete out of w_seq order, as writes of different nodes always could; E1 (P >= s) still covers every write <= s;
  - visibility does not depend on the physical order of a delete and the insert of the same id (ins_seq / del_seq
    filter; deleted elements stay in the graph);
  - HNSW levels: writer 0 keeps the node's generator (seed as before); writer w > 0 owns one seeded from (seed, node,
    w). With N > 1 the level of a given record depends on scheduling (not reproducible record by record).
  - `writes_applied` (diagnostic HWcc line) is incremented atomically when N > 1.
- Write-path counters (every build >= 16, also with N = 1; stats text): `writer_threads`, `write_jobs_accepted`
  (queued by a connection reader), `write_jobs_done` (finished by a writer, incl. bad requests), `write_backlog` =
  accepted - done, `write_lag_ns_sum` / `write_lag_n` (queue-to-finish time per job), `write_lag_max_ns` (window max,
  reset by every stats read). experiments/vectordb/urate_check.py judges each measured step (done >= 0.98 x accepted,
  backlog growth <= max(50, 1 s of updates), end backlog <= max(50, 5 s of updates)).
- Deviations from the RecSys streaming block (state/PROJECT.md "RecSys experiment methodology"), each with its reason:
  - `--drain-s 60` in the SLO part (RecSys: loadgen default 5 s). A drain ends as soon as every response is in, so
    it costs time only after a step that left a backlog. Reasons: (1) a write backlog left by a saturated step is served
    before the next step starts, so a step is not judged on its predecessor's backlog; (2) responses that arrive after
    loadgen's drain are lost to loadgen but counted by the server, which breaks the per-lifetime opcoh closure
    (observed on the Host with 5 s at queue-cap steps, workspaces/vdb-urate/pilot16-w8).
  - `--min-step-queries 300` (RecSys 100; user 2026-10-20): the VDB SLO is p99, and with 100 searches the nearest-rank
    p99 is the second-slowest search.
  - SLO p99 <= 100 ms (H1 VDB SLO) instead of RecSys p95.
- Reproducibility: with N > 1 writer threads the HNSW graph is not reproducible record by record (level draws and
  insert order inside a segment depend on scheduling), so two lifetimes of the same rung differ in graph shape;
  recall@10 is measured per system and rung from that lifetime's own searches (e1_check.py sample of 500 measured
  searches -> experiments/vectordb/urate-recall.sh -> tools/compute_gt.py, offline after the block).
- Update budget per lifetime (every lifetime starts from the initial image; no reclamation): inserts are bounded by
  the free ids / segment capacity and by the writes file. experiments/vectordb/urate_budget.py bounds the update
  consumption from the KIND=urate loadgen parameters (scenario: ramp growth >= 1.2 up to a 400 search/s knee, SLO
  result >= 10 search/s); urate-block.sh refuses rates above the budget unless the user lists them in
  URATE_PARTIAL_OK, and an exhausted stream in the SLO part is a NOTE (steps before it kept). Device limit (28M image,
  96 GiB NVDIMM): at most 89 groups per segment with --max-deletes <= 1,835,008 (88 with 2,097,152) -> capacity
  952,211, i.e. about 3.48 M inserts per lifetime (3,363 B of SWcc per record). Longer traces: `DATASET=28m-x` in m4-run.sh
  (X_DATA, X_WRITES, X_NB, X_MAXIDS, X_MAXW, X_MAXD, X_INIT_CAP).
- `--init-capacity C` (build >= 17): accept an init dir built for C <= capacity elements per segment; chunk images are
  chunk-relative and per_chunk / lchunk_bytes do not depend on the capacity, so a larger capacity only adds groups.
- Longer update trace for the sweep (user 2026-10-20): pool B extended with FRESH PubMed_bge rows (no vector reuse):
  prepare_data.py had used all 28,000,000 rows of raw28m (binbin10/PubMed_bge@29f9db47, chunk_id 0 .. 27,999,999), so
  tools/extend_pool_b.py takes upstream rows with chunk_id >= 28,000,000 from upstream shards 196.. of the same revision
  (shard and row order; upstream rows are not in chunk_id order), skipping chunk_id / document / embedding duplicates
  of the 28M and of earlier fresh rows; pool B = the old 1,000,000 rows followed by 2,400,000 fresh rows; pool A and
  queries unchanged (symlinks). gen_writes.py over the 3.4 M pool B (seed 20261015, no reuse): 3,400,000 updates,
  the cap per lifetime (device: 89 groups per segment -> capacity 952,211, `--max-ids 30470752 --max-deletes 1835008
  --max-writes 6815744 --init-capacity 875000`). At 3200 updates/s the cap is about 1,060 s of streaming, below the
  worst-case lifetime: the SLO search at 3200 (and, by the worst-case bound, at 1600) may run out of updates in
  bisect / confirm / fill / overload; loadgen then ends with "streams exhausted" and the rung keeps the steps before it
  (user decision 2026-10-20, option (a)). Fallback on hold: gen_writes.py `--pool-b-rows R` (reuse pool B vectors under
  new ids; builds/vdb-inputs/1, HOLD.txt); compute_gt.py maps ids to rows from the writes file in both cases and
  adds a tie-aware recall for duplicate vectors.
- Host test: tests/urate_pilot.sh (two servers on a scratch file, 1M image; per-rate fixed invocations, optional
  knee-ramp SLO part; E1 per invocation; final consistency: P = writes, elements = NA + updates, delete-log entries =
  updates, bad_records 0, backlog 0).

## 18. SQ8 vector storage (branch vdb-sq8; user decision 2026-10-21, vdb-vm-scaling)
- Why: the fp32 vector DB is CXL-bandwidth-bound already at 2 VMs x 4 vCPU (~86 MB CXL read per search). SQ8 stores
  one uint8 per dimension: vector record 64 + 768 = 832 B (13 lines) instead of 3136 B; links unchanged.
- `--vec-format fp32|sq8` (default fp32: layout, layout hash, init images byte-identical to earlier builds). sq8 adds
  " vec=sq8" to Params::describe (layout hash) and one HWcc field `sq8` (Sq8Line + min[dim], scale[dim] float32).
- Quantizer: per-dimension min / max over every indexed pool A row (tools/build_index.cc, arg 11 `sq8`; sq8.bin and
  manifest lines `vec_format sq8`, `sq8 ...`); code = clamp(round((x - min) / scale), 0, 255), scale = (max - min) / 255.
  Node 0 publishes sq8.bin in HWcc at prepare (also with --preloaded); every node copies it to private memory after the
  start barrier and checks dim and FNV-1a. Pool B inserts are quantized with it (out-of-range values clamp).
- Distance: the same inner product against the decoded vector (min + scale x code), computed in registers; no fp32
  rescoring, no fp32 vectors in shared memory. insert() quantizes the new vector and uses its decoded form for every
  distance, so the offline build and run-time inserts build the same kind of graph. Megalon reads the 768 B in its read
  section; its validation copy for dist_ids decodes into the scratch vector.
- Host checks: tools/search_index.cc (static searches over an init dir: recall@k vs tools/static_gt.py exact GT,
  distances, link blocks and bytes per query), tests/host_smoke.sh VEC_FORMAT=sq8.

## 19. Writer lock split (branch popcorn-lock-split; experiment popcorn-writer-lock-split, approved 2026-10-23)
- `VDB_LOCK_SPLIT=1` in the server environment (default off: nothing sampled, no `lock_split.*` key printed). Per
  insert, after the segment write lock is acquired and before it is released, the writer reads its swmc_acct
  coherence counters (OpCohSrc::pop_now: the same snapshot as a section boundary), its run-queue delay
  (/proc/thread-self/schedstat field 2, one fd per thread, pread at 0) and CLOCK_THREAD_CPUTIME_ID.
- Stats keys (cumulative; server.cc LockSplit): lock_split.inserts, hold_ns, hold_coh_ns (I->S + S->M + wp faults +
  coherence IPIs inside the hold = C), hold_rq_ns, hold_cpu_ns, hold_{is,sm,wp}_{ns,cnt}, hold_ipi_{ns,cnt},
  hold_nt_{ns,cnt} (no-transition faults, not in C), hold_overlap_cnt (coh + rq > hold: a fault that slept for its ACKs
  then waited on the run queue), hold_max_ns (since the previous stats read), sample_ns (cost of the samples, inside
  the hold), coh_unavailable, rq_errors; per search: searches, search_lock_ns, search_e1_ns, seg_tasks; log2
  histograms hold_hist / search_lock_hist (per search) / seg_lock_hist (per segment task) / e1_hist, keys .b00-.b39
  (b<k> = [2^k, 2^(k+1)) ns).
- Host test: tests/lock_split_test.sh (host_smoke.sh with VDB_OPCOH_FAKE=1 VDB_LOCK_SPLIT_FAKE_NS=N: every insert
  adds an N ns wp fault inside its hold, so hold_wp_ns = N x inserts exactly; checks hold_coh + hold_rq <= hold, the
  histogram sums, and that a run without VDB_LOCK_SPLIT prints no lock_split key).

## 20. Stale-snapshot copies (experiment vector-db-staleness-recall, approved 2026-11-13; loadgen only, server unchanged)
Design doc reports/experiments/vector-db-staleness-recall.md. The server already applies any requested snapshot
exactly (E1, §4: `ins_seq <= s < del_seq`; for s below P the readiness wait is already met), so only the client
changes (builds/vdb-loadgen >= 13; plain server builds/vdb/24 unchanged).
- Engine (experiments/loadgen/workload.h): `Workload::burst(stream)` = requests per arrival (default 1); with B > 1
  the engine makes B requests back to back for one scheduled arrival, all with the same scheduled time
  (`Request::sched_ns`, now passed to every make()). Each copy is its own request in the statistics (latency from the
  shared scheduled time; sent / done / achieved count requests). Manifest line `burst.<stream>=B` only when B > 1.
- Plugin options (default off; without them every output is byte-for-byte the format before):
  - `--opt stale_ms=T0,T1,...` (integer ms, distinct, <= 16 values; the experiment: 0,1,10,100,1000,10000): every
    search arrival ("group": one query row, one target) becomes len(LIST) requests in LIST order. Copy i asks for
    s_i = the insert w_seq of the last update SCHEDULED at or before t - T_i (t = the group's scheduled time; binary
    search over the (scheduled time, w_seq) history of the updates made by this invocation; history older than the
    largest T is dropped except the last entry before the oldest cutoff). T = 0 is the usual E1 ref_w (last update
    made). Before the first update of the invocation (or t < T) s_i = the initial snapshot (w_seq of record w_start-1,
    0 at w_start 0). Rates: the search stream's rate counts GROUPS (query/s); search requests/s = rate x len(LIST)
    (steps.jsonl `offered` = groups/s, `achieved` = responses/s). Copy order is LIST order: copy i is queued behind
    copies 0..i-1 on the server, so per-T latency includes that queueing (reported, not a staleness effect).
  - `--opt search_target=N`: every search to target N; the target draw still consumes the seeded generator, so the
    query rows equal those of the same seed without the option.
- Records: searches.bin keeps its format; `ref_w` = the snapshot SENT (s_i), so e1_check.py / compute_gt.py check
  and score each copy at its own snapshot. New `stale.bin` (40 B per search MADE, seq order, written at the end, also
  for searches without a response): u64 seq (= searches.bin seq), u64 sched_ns, u32 group, u32 t_ms, u32 fresh (ref_w
  of T = 0 at the same time), u32 sent, u32 lat_us (response - scheduled, 0 without a response), u16 status, u8 flags
  (bit 0 responded, bit 1 measured), u8 t_idx. vectordb.txt adds stale_ms / stale_copies / stale_groups /
  stale_records / stale_record_bytes / stale_answered and search_target (only with the options).
- Analysis: experiments/vectordb/staleness_recall.py (searches.bin + stale.bin + writes file + exact top-K' npz ->
  steps.csv per T: recall@10 vs the exact top-10 of the FRESH snapshot, paired loss vs T = 0 of the same group with a
  bootstrap CI over groups, exact (no-ANN) loss, latency percentiles; measured groups only, a copy without an OK
  response counts as 0 hits). Harness: experiments/vectordb/staleness-block.sh (parts pilot / measure; h2n-block.sh
  fixed-window hw lifetime, keys H2N_PLAIN_SERVER_EXTRA / H2N_WRITES_TARGETS / H2N_LG_STREAMS / H2N_FIXED_UPDATE /
  H2N_FIXED_SKIP_CMD; conf experiments/eval/vector-db-staleness-recall.conf). Pilot: update steps 1000, 2000, 3000,
  4000, 6000, 8000 /s (15 s warmup + 60 s each) in one lifetime, stopping at the first step urate_check.py judges not
  sustained; result = the highest clean step. Measure at R: 25 s (15 s warmup + 10 s lookback) + W = min(600,
  floor(1,835,008 / R) - 35) s (update budget = node 0's --max-deletes), W in the manifest and steps.csv window_s.
- Tests: tests/plugin_stale_test.cc (snapshot rule, pruning, w_start, records); tests/stale_recall_test.sh (two
  servers on a scratch file, tiny SQ8 image, 4 writer threads on node 0, searches to node 1, stale_ms 0..10000).

## 10. Future reference: E2 (not implemented)

- No-wait: s_used = min(P, ref_w); no staleness bound.
- Bounded: wait until P ≥ L, choose L ≤ s_used ≤ ref_w; L = ref_w − δ
  (δ in writes) or the last w_seq scheduled at or before t_q − Δ (time).
- Publication batching period is a separate parameter.
- Distinguish delaying P / picking older snapshots (same coherence work, only
  less waiting) from merging write sections (fewer/smaller flushes and fewer
  metadata publications). Measure what changes; a recall drop with no cost
  reduction is a valid result.

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
- HWcc internal layout (Megalon control area, segment descriptors, counters,
  `applied` bitmap, P) is computed from `hwcc_size`, W and MAXSEG. If it does
  not fit, fail at startup. Actual usage goes to the manifest.
- If Megalon fixes SCR size/base at compile time, values are generated from
  the same config and injected into its build; the mapping is recorded (TBD).
- In all-HWcc the SWcc area is also treated as HW coherent (baseline). Here
  `hwcc_size` is a logically enforced budget; it may be swept later.
- Shared-log body placement follows original Megalon (TBD), not forced into HWcc.

## 2. Operations and data

- Insert(id, vec): new id, never reused. Delete(id): exclude an existing id
  from search; no physical reclamation. Search(q, k=10).
- Main workload: searches run while data is replaced by independent
  Delete(old) and Insert(new) requests (not an atomic replacement). Counts
  are reported per operation; "one replacement" = 1 delete + 1 insert.
- Delete targets: uniform over the live set at trace time, fixed seed.
- Data: PubMed BGE 768-d (`binbin10/PubMed_bge`), split into disjoint
  pool A (initial N, e.g. 1M) and pool B (inserts). Replacements are between
  different documents. Queries: BioASQ question embeddings (BGE, precomputed).
- Insert-only traces are for bring-up; formats always include deletes.
- Index parameters (M, efConstruction, ef, metric) are fixed per run and
  identical across systems.

## 3. Trace

Generated once per experiment, deterministic seed, shared by all systems.

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

## 6. Segments

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
- Megalon object granularity (append chunk, index object, delete-log chunk) TBD.
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
- Metrics: search QPS, p50/p99 (from scheduled time), insert/s and delete/s
  separately, visibility latency, recall@10 (timeouts/unserved count as
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

## 9. Load generation

- Existing tools checked (2026-10-14): `workloads/rag/reqgen/*.py` is
  closed-loop (each client awaits its response) and sends text to the
  LangChain `/chat` endpoint; LMDB open-loop generation lives inside db_bench
  (`readopen`) and is not reusable for HTTP requests.
- Plan: reuse the reqgen aiohttp session/statistics code; replace only the
  client loop with an open-loop trace replayer that fires each request at
  sched_t without awaiting earlier ones, sharded over several processes pinned
  to Host node1 CPUs (16-31,48-63). It records send lag vs sched_t, completion,
  timeouts and outstanding requests. Rewrite in C++ only if send lag shows the
  Python replayer is the bottleneck at target rates.
- Requests go straight to trace target_vm; no coordinator (global order comes
  from w_seq). Rationale vs Megalon's client setup: TBD (audit).

## 10. Future reference: E2 (not implemented)

- No-wait: s_used = min(P, ref_w); no staleness bound.
- Bounded: wait until P ≥ L, choose L ≤ s_used ≤ ref_w; L = ref_w − δ
  (δ in writes) or the last w_seq scheduled at or before t_q − Δ (time).
- Publication batching period is a separate parameter.
- Distinguish delaying P / picking older snapshots (same coherence work, only
  less waiting) from merging write sections (fewer/smaller flushes and fewer
  metadata publications). Measure what changes; a recall drop with no cost
  reduction is a valid result.

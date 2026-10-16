# lmdb workload — design (MOT1 H2 control)

Status: implemented and Host-tested 2026-10-16 (reports/LMDB-port.md); not yet run in the VMs.
Role (reports/MOT1-motivation-plan.md §4.4 "Workload 3"): a key-value store whose indexing unit is the 4 KiB B+tree
page, so Megalon's object (one page) and Popcorn's coherence unit (one 4 KiB page) coincide. One lmdb-server process
per node runs unchanged on all-HWcc and Popcorn (`--backend plain`) and on Megalon (`--backend megalon`).
The older scripts in this directory (db_bench, OPTION_B_WORKLOG.md, run_*.sh) are the previous FamFS-based setup and
are not used here.

Limitation (as vectordb): both VMs share physically HW-coherent memory, and the Host tests use a file; a missing flush
can be masked by hardware. Tests prove the protocol logic and API use, not a SW coherence protocol.

## 1. Code
| path | role |
| --- | --- |
| `server/liblmdb/` | liblmdb 0.9.70 (copied from `third_party/LMDB/libraries/liblmdb`, sha256 in every build manifest) with the CXL mode added to `mdb.c` (every change marked `CXL`), new `lmdb_cxl.h` |
| `server/layout.h` | parameters, HWcc app layout (systems/common/hwcc_app.h) |
| `server/backend.h` | page access per system: `PlainBackend`, `MegalonBackend` |
| `server/node.h` | one node: region, app layout, backend, env, initial image, readiness, warm-up (server and stress tool share it) |
| `server/server.cc` | `lmdb-server` (frame.h protocol, proto.h ops) |
| `proto.h` | ops, payloads, key/value format and check, YCSB scrambled Zipfian |
| `loadgen/lmdb_plugin.cc` | loadgen plugin `lmdb` (streams `get`, `update`) |
| `tools/lmdb_image.cc` | initial image builder (MDB_APPEND) |
| `tools/lmdb_stress.cc` | cross-node MVCC stress test (no network) |
| `tools/megalon_bench.cc` | Megalon op cost bench (create / write / read sections, threads, background readers) |
| `tools/check_log.py`, `tools/lmdb_ctl.py` | exact MVCC check of a logged run; stats/verify requests |
| `tests/host_test.sh`, `tests/build_negative.sh` | Host functional test; negative-control build |
| `server/build.sh` | builds everything; with a Megalon build dir also the dlopen shim `lib/libmegalon-objapi.so` (systems/megalon/shim via workloads/kv/server/objapi-shim.sh: API v2 with thread_coh on Megalon >= 71, v1 fallback on <= 70) |
| `../kv/server/opsplit.h`, `../kv/tools/opsplit.py` | per-operation time split (MOT1 v6 Fig 2), shared with kv |
| `../../experiments/lmdb/` | VM harness: `run.sh` (one run), `pilot-run.sh` (MOT1 v6 mixes, SLO, post checks), `install.sh`, `lmdb-node.sh` (guest node script) |

## 2. Shared state (docs/hwcc-contract.md)
LMDB's lock file and meta pages move to the HWcc `app` range; B+tree pages (including the freeDB) stay in SWcc.
| field (app) | size | writers | replaces |
| --- | --- | --- | --- |
| `wlock` | 2 lines: next ticket, now serving | all (fetch_add on next); holder (serving) | robust `mti_wmutex` |
| `committed` | 8 B | writer-lock holder (release) | `mti_txnid` |
| `meta[2]` | 2 x 128 B seqlock slots {seq, txnid, last_pg, FREE_DBI/MAIN_DBI MDB_db} | writer-lock holder | meta pages 0/1 |
| `readers` | nr_nodes x readers x 64 B, value = snapshot txnid + 1 (0 free) | slot owner thread | `mti_readers[]` |
| `nodes` | nr_nodes x 64 B {loaded run_id, updates} | node v | — |
Sizes depend only on `--nodes`, `--readers` (per node, default 32) and the parameters in the layout hash
(`--max-pages`, `--records`): 2,176 B used for 2 nodes x 8 readers, 5,248 B for 2 x 32 (`--print-app-bytes`).
Same layout on every system (the backend only enters the hash).

## 3. Page access per system
- **plain (all-HWcc, Popcorn):** page p at `swcc.offset + p * 4096`; LMDB reads pages in place (as with its read-only
  mmap) and commit copies each dirty page into place (LMDB's default non-WRITEMAP path with `pwrite` replaced by a
  copy). Popcorn sees ordinary loads/stores to SWcc pages.
- **megalon:** one Megalon object (4 KiB, id `0x4c4d << 48 | pgno`) per page 2..max_pages-1, created by node 0 at
  prepare and looked up by every node. Read: `mdb_page_get` copies the page out in one read section
  (`do { ObjectReadStart; memcpy 4 KiB } while (!ObjectReadEnd)`) into the transaction's private copy; LMDB then works
  on the copy (cursor stacks, MDB_val results) until the transaction ends. Write: commit writes every dirty page whole in
  one write section (whole lines, no read of prior contents, D3); `ObjectWriteEnd` flushes the whole object.
- **Why copies (Megalon read sections must not be nested or held across LMDB calls):** LMDB keeps page pointers across
  calls (cursor `mc_pg[]` stack root..leaf, `MDB_val` pointing into a leaf, freeDB cursor in `mdb_page_alloc`). In-place
  sections would have to stay open from the root to the end of the operation, one per level (nested, long-held),
  which the Megalon contract forbids (one open section per thread). Each copy is one complete section, so no section
  outlives the copy. The copy is valid for the whole transaction because LMDB never modifies a page of a live
  snapshot (copy-on-write + the reader table, §4), so re-reading the same pgno within the transaction returns the
  earlier copy (per-transaction cache; reset at transaction end). This is also the artifact's own access style
  (copy-out Get), at the paper's object granularity (page).
- Overflow pages (values > 2,038 B) are copied page by page into one contiguous buffer; unused by the YCSB records.

## 4. Correctness across nodes
1. **One writer at a time:** ticket lock in HWcc taken in `mdb_txn_begin` (write) and released in `mdb_txn_end` after
   the commit published (release store), polling only (no futex across VMs).
2. **Publication order (commit):** (a) every dirty page written to SWcc (Megalon: write section, whole-object flush at
   write end); (b) meta slot `txnid & 1` written under its seqlock; (c) `committed = txnid` (release); (d) unlock.
   A reader acquires `committed`, then reads the slot, then pages, so it never sees a meta newer than its pages.
3. **Cross-node MVCC (oldest reader before page reuse):** LMDB reuses a page freed by txn X only when
   `mdb_find_oldest` > X. In CXL mode `mdb_find_oldest` scans every node's reader slots in HWcc. Reader registration
   is LMDB's ITS#7970 loop made cross-node: `T = committed`; store `T+1` into the slot (seq_cst); re-load `committed`
   (seq_cst); retry unless still T; then read meta slot T under the seqlock (retry if a writer already reuses it). If a
   writer's scan missed the slot, that writer read `committed` before it moved past T, so it can only reuse pages
   freed before T, which snapshot T does not reference. The per-process cache `me_pgoldest` stays a valid lower bound
   because new readers always start at the current `committed`.
4. **Meta torn reads:** the seqlock re-check (and txnid match) rejects a slot being rewritten by txn T+2.
5. **Per-process LMDB state** carried between write txns (`me_pghead`, `me_pglast`) is reset at every txn end, and a
   write txn derives `mt_dbs`/`mt_next_pgno` from the shared meta, so alternating writers on two nodes are consistent.

## 5. Records, image, parameters
- YCSB core defaults: key 24 B (`"user"` + 20 digits = YCSB `insertorder=ordered` naming), value 1,000 B (a header
  {key, version, writer} + deterministic filler, checkable), request distribution = YCSB ScrambledZipfian (theta 0.99
  over 10^10 items, FNV-64 mod records).
- Leaf node 8 + 24 + 1,000 B → 3 records per 4 KiB leaf (observed: 100k records = 33,334 leaves + 285 branches, depth 4).
- Initial image (`lmdb-image`, Host, unmeasured): records in key order with `MDB_APPEND`, `--batch` per write txn
  (default 100k; avoids LMDB dirty-list spills), by the same patched library over a file. Output `pages.bin` +
  `meta.txt`; node 0 copies it into SWcc at prepare (or `--preload-only` before Popcorn enables coherence, then
  `--preloaded`, as vectordb). Every node then reads every page once (warm-up), through read sections on Megalon.
- Node 0 prepare threads (`--prepare-threads T`, default 1): T threads each create the page objects of interleaved
  1,024-page batches and write the batch's image pages (Megalon tids 1..T; NR allows 32 thread registrations per
  process lifetime, so T + 2 + get threads ≤ 32). T = 1 creates in pgno order (deterministic arena placement, §9).
- Size parameters (methodology decisions, not fixed here): `--records` (MOT1: 60M ≈ 76.3 GiB of leaves) and
  `--max-pages` (LMDB map size; copy-on-write headroom; Megalon creates one object per page up to it).

## 6. Tests (Host)
- `lmdb-stress`: per node one updater (`--keys-per-txn` overwrites per txn) and reader threads that hold a snapshot
  for `--hold-us`, re-read the same keys and require identical bytes; integrity, monotonic snapshots; final full scan.
  A small `--max-pages` forces freelist reuse. Negative control: `tests/build_negative.sh` + `MDB_CXL_TEST_SCAN=0:32`
  on node 0 (its writer ignores node 1's readers) must FAIL.
- Server path: loadgen with `--opt log=1`, then `tools/check_log.py` (every get's value = the last acknowledged update
  of that key at or below its snapshot txnid), `verify` op on both nodes, `stats` op.

## 7. Requests and metrics
- `get` = one read-only txn (`mdb_txn_renew`, `mdb_get`, reply with the value, `mdb_txn_reset`) on a get worker
  (reader slot i of this node); `update` = one write txn overwriting an existing key (`mdb_put`; refused with
  not-found if the key did not exist) on the node's single writer thread, in arrival order. One request = one op.
- Loadgen streams `get`, `update` and `mixed` (MOT1 v6 main runs): each `mixed` request is an update with probability
  `--opt update_ratio=R`, else a get; mixes get/update 95/5 (R 0.05, YCSB B), 50/50 (0.5, YCSB A), 20/80 (0.8, Twitter
  OSDI'20). SLO (user decision 2026-10-16): request p99 < 1 ms over both kinds (`--mix mixed=1 --slo mixed:99:1`), as
  the kv store. Throughput = completed requests/s (one request = one op).
- Per-operation split (MOT1 v6 Fig 2; `opsplit.h`): every get/update is one operation; T = rdtsc (no fences) from the
  start of its transaction to the end of its thread's work on it (get: renew .. mdb_get .. reply .. reset; update:
  txn_begin incl. the cross-node writer-lock wait .. put .. commit .. reply); C = the thread's coherence time inside it
  (plain: Popcorn swmc_acct; megalon: CohSnap via thread_coh). Stats keys `opt.get.*`, `opt.update.*` ({ops, t_ns,
  t_max_ns, c_ns, mod_bytes, pop.*, meg.*}; mod_bytes = 1,000 B per committed update), gauges `opt.tsc_hz`,
  `opt.pop_threads`, `opt.meg_coh`, `opt.meg_check_sample`; per-step CSV by `workloads/kv/tools/opsplit.py`.
- Stats op 10 (key=value, cumulative; loadgen `--stats-op 10`): gets/updates/not-found/errors and their ns, writer
  lock wait, commit time, page writes, oldest-reader lag, reader retries, Megalon object counters, and
  `cxl::proc::text` (threads lmdb-get / lmdb-writer / lmdb-conn / megalon-lib..., kernel cxl_recv threads, IRQs,
  Popcorn sysfs counters). Verify op 11: full scan of the latest snapshot.

## 8. Deviations (summary; details in reports/LMDB-port.md)
- From YCSB (user decision 2026-10-16): update = overwrite of the whole 1,000 B value with no read first (YCSB's
  default updates one field, writeallfields=false, and KV bindings read-merge-write).

From LMDB:
- No data/lock files: pages in SWcc, lock-file state and meta in HWcc; `MDB_NOLOCK|MDB_NOSYNC|MDB_NOTLS` implied.
- Writer lock: polling ticket lock instead of a robust process-shared mutex (no owner-death recovery).
- Reader slots are assigned by the caller per thread (no slot allocator, no stale-reader cleanup).
- Commit: copy into the region instead of `pwrite`, no fsync; meta in a seqlock slot instead of a meta page.
- Megalon: pages read through per-transaction copies (§3).
- `mdb_env_copy`, nested txns across nodes, WRITEMAP, resizing are not supported in CXL mode.

## 9. Restoring the initial state (reports/LMDB-port.md §10)
- plain (all-HWcc, Popcorn): restoring = copying the image pages into SWcc (`load_initial`, or `--preload-only`);
  HWcc `app` is re-initialised by every run.
- megalon: the artifact cannot attach to an existing initialised device (node 0 always re-initialises the control
  block, SCR, NR log and the object allocator; the object index lives only in each process's DRAM and is rebuilt only
  from the 64 MB log ring). Restore without Megalon changes: copy back a device image taken right after a prepare
  with `--prepare-threads 1`, start node 0 with `MEGALON_REINIT=1 --preloaded`: node 0 re-creates the page objects in
  pgno order (the bump allocator puts each at its old arena position), checks every page's position, writes no page.
  Placement check fails (refuses to run) if the image was prepared in another order.

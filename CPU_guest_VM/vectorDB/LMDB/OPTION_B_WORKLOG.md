# LMDB Option B Worklog

This file tracks the current LMDB/dbbench baseline and the Option B design work.
Keep it updated at each checkpoint so later changes can be compared against a known state.

## Goal

Implement Option B for the DSM experiment:

- Keep using `MDB_NOLOCK` for the cross-node experiment.
- Add DSM-aware writer serialization and reader epoch tracking.
- Connect reader epochs to LMDB page-reuse correctness, especially the `mdb_find_oldest()` path.
- Preserve the current dbbench read/write workload paths while making the LMDB correctness layer explicit.

## Current Baseline

Repository root:

```text
/home/comsys/CXLSharedMemVM
```

The worktree already had unrelated dirty changes outside LMDB when this baseline was captured:

- `KnowhereVectorDB/...`
- `damo_yamls/...`
- `mount_famfs.sh`
- `start_damon.sh`

Those are intentionally not part of the LMDB Option B baseline.

## Stage 1: Current Code Survey

Relevant LMDB/readopen changes currently in the worktree:

- `LMDB/third_party/LMDB/dbbench/main.c`
  - `readopen` supports comma-separated `--arrival_rates`.
  - `readopen` supports `--warmup_sec`.
  - `readopen` supports `--generator_cpu` and `--generator_rt_prio`.
  - `readopen` prints one result block per phase.
- `LMDB/lmdb_common.sh`
  - readopen uses `ARRIVAL_RATES` instead of a single `ARRIVAL_RATE`.
- `LMDB/run_readopen_lmdb.sh`
  - passes `--arrival_rates`, `--warmup_sec`, and generator scheduling options.
- `start_LMDB_readopen.sh`
  - configures the current FAMFS readopen experiment rates.

Important dbbench behavior:

- `--benchmarks=<name>` must be the last option.
- The `benchmarks` argument is parsed through `arg_magic`, and parsing stops when it is processed.
- If options are placed after `--benchmarks`, they may be ignored.

Important writer behavior:

- `overwrite` supports `--writes_per_second`.
- `DBB_done()` checks duration only every roughly 1000 operations.
- Low `WRITES_PER_SECOND` values can make short writer smoke tests run much longer than expected.

## Stage 2: Smoke Testbench

Added:

```text
LMDB/testbench_smoke_lmdb.sh
```

Purpose:

- Build dbbench if needed.
- Create a small temporary LMDB database under `/tmp`.
- Verify `fillseq`.
- Verify multi-rate `readopen`.
- Verify `overwrite` with write-rate limiting.

Default smoke command:

```bash
LMDB/testbench_smoke_lmdb.sh
```

Optional debugging:

```bash
LMDB_SMOKE_KEEP=1 LMDB/testbench_smoke_lmdb.sh
```

Baseline verification result:

```text
PASS
```

Observed smoke output included:

- `fillseq` summary line.
- `readopen` phase 1 and phase 2 output.
- `readopen` sent/dropped/processed counts.
- `readopen` p50/p99/p99.9/p99.99 latency output.
- `overwrite` summary line with ops/sec.

## Next Checkpoint

Before implementation, review the Option B design below and resolve the open
questions.

## Stage 3: Option B Design

### Summary

Option B keeps `MDB_NOLOCK` for the cross-node DSM experiment, but adds a
separate DSM-aware metadata region for the correctness piece that LMDB loses
when `MDB_NOLOCK` disables `lock.mdb`:

- reader txnid tracking for old-page reuse

Single-writer serialization is not implemented with DSM atomics in the first
version. The DSM layer guarantees coherent explicit page writes and prevents
stale pages, but it does not guarantee cross-node atomic read-modify-write
operations. Because of that, a shared-memory writer lock would be unsafe.

Instead, the first implementation treats this as an experiment invariant:

```text
exactly one writer process is allowed to run for a DB at a time
```

The important point is that the DSM reader table must be connected to LMDB's
page reuse path. A wrapper around dbbench or `t_lmdb.c` is not enough for full
MVCC correctness, because page reuse is decided inside `mdb_page_alloc()` via
`mdb_find_oldest()`.

### Non-Goals For The First Implementation

- Do not implement general multi-writer scaling.
- Do not implement a cross-node writer lock with DSM shared memory.
- Do not replace all of LMDB's original lock manager.
- Do not support arbitrary LMDB applications perfectly on day one.
- Do not auto-clear remote stale readers in the first implementation.
- Do not change dbbench workload semantics in this stage.

The first target remains:

```text
one writer node + one or more reader nodes + MDB_NOLOCK + DSM metadata
```

### Required DSM Assumptions

The design depends only on these DSM properties:

- The metadata region is mapped by all participating nodes.
- Explicit writes to the metadata file mapping become visible to other nodes.
- Visibility is page-granular and stale pages are not returned.
- The writer process is unique by experiment setup, not by a DSM lock.
- Reader slot ownership is partitioned so two nodes do not write the same
  metadata page.

The design explicitly avoids cross-node atomic RMW operations such as:

```text
compare-and-swap
fetch-add
test-and-set
atomic exchange
```

Those operations are what a shared-memory lock would normally need. Without
cross-node atomic RMW, code like this is not safe across nodes:

```text
if writer_lock == 0:
    writer_lock = 1
```

Two nodes could both observe `0` and both believe they acquired the lock.

For this reason:

- no DSM writer lock is part of the first implementation
- no shared dynamic reader-slot allocator is part of the first implementation
- slot ranges must be assigned so independent nodes never write the same
  metadata page

If future DSM support adds coherent cross-node atomic RMW, a DSM writer lock and
dynamic slot allocator can be added later.

### Activation Model

Use an opt-in mode so ordinary LMDB/dbbench behavior remains unchanged.

Suggested environment variables:

```text
LMDB_DSM_META_PATH=/mnt/famfs/lmdb_7M_4KB.dsm_meta
LMDB_DSM_NODE_ID=<small integer unique per node>
LMDB_DSM_SLOT_BASE=<first reader slot owned by this process/node>
LMDB_DSM_SLOT_COUNT=<number of reader slots owned by this process/node>
```

Rules:

- If `LMDB_DSM_META_PATH` is unset, behavior is unchanged.
- `LMDB_DSM_META_PATH` must be explicit. Do not silently place the metadata file
  inside `DB_PATH`.
- If `LMDB_DSM_META_PATH` is set, require `MDB_NOLOCK`; otherwise fail early.
- `LMDB_DSM_NODE_ID` is required in DSM mode because Linux PIDs are not globally
  meaningful across nodes.
- `LMDB_DSM_SLOT_BASE` and `LMDB_DSM_SLOT_COUNT` define the slot range this
  process may write.
- The operator must guarantee non-overlapping, page-disjoint slot ranges across
  nodes and processes.

The metadata file may need to be pre-sized if the DSM filesystem does not
support `ftruncate()`. The implementation should document the expected size and
fail clearly if the file is too small.

Why not default to `DB_PATH/dsm_meta`:

- A non-patched LMDB will usually ignore an extra file, but fresh-db cleanup can
  remove the DB directory.
- Keeping metadata outside `DB_PATH` makes accidental deletion less likely.
- If a non-patched writer runs concurrently on the same DB, correctness is
  broken regardless of where the metadata file lives, because that writer does
  not honor DSM reader epochs.

Example:

```text
DB_PATH=/mnt/famfs/lmdb_7M_4KB
LMDB_DSM_META_PATH=/mnt/famfs/lmdb_7M_4KB.dsm_meta
```

### DSM Metadata Layout

The metadata region should be a fixed-size shared structure, cacheline-aligned
where slots are frequently updated.

Because the DSM write visibility guarantee is page-granular, reader slots from
different nodes must not share one metadata page. Otherwise a node that writes
its own slot can overwrite another node's slot in the same page.

The safest first implementation is:

```text
one reader slot = one metadata page
```

This is larger than LMDB's cacheline-sized reader slots, but it avoids
cross-node false sharing at the DSM page granularity. A denser layout can be
considered later only if the DSM layer supports sub-page merge semantics or
cross-node atomic RMW.

Draft layout:

```c
struct lmdb_dsm_meta {
    uint32_t magic;
    uint32_t version;
    uint32_t header_size;
    uint32_t slot_size;
    uint32_t max_readers;
    uint32_t flags;

    uint64_t committed_txnid;
    uint64_t generation;

    uint32_t init_state;
    uint32_t total_slots;
    uint32_t reserved0;
    uint32_t reserved1;

    struct lmdb_dsm_reader_slot slots[];
};

struct lmdb_dsm_reader_slot {
    uint32_t magic;
    uint32_t active;
    uint32_t node_id;
    uint32_t pid;
    uint32_t tid_hash;
    uint64_t txnid;
    uint64_t generation;
    uint64_t heartbeat;
    uint8_t  padding_to_page_size[...];
};
```

Important fields:

- `committed_txnid`: DSM-visible equivalent of LMDB lockfile `mti_txnid`.
- `total_slots`: total number of reader slots in the metadata file.
- `active`: set after `txnid` and owner fields are written.
- `magic`: helps detect an uninitialized or corrupted slot page.
- `txnid`: the snapshot txnid that the reader is protecting.
- `node_id + pid + tid_hash`: identifies the owner for debug and cleanup.
- `heartbeat`: useful for diagnostics and optional stale handling.

Writer-side scanning must treat an active slot conservatively. If it observes
`active != 0`, it should use that slot's `txnid` when computing the oldest
reader. Because there is no cross-node atomic publication protocol, the
implementation should write fields in this order:

```text
reader enter:
    write owner fields
    write txnid
    write heartbeat/generation
    write active=1 last

reader exit:
    write active=0 first
```

This avoids the common failure mode where a writer sees an active slot before a
valid txnid has been written.

### Reader Lifecycle

Patch point:

```text
mdb_txn_renew0()
```

Current `MDB_NOLOCK` path:

```text
if read txn and env->me_txns == NULL:
    meta = mdb_env_pick_meta(env)
    txn->mt_txnid = meta->mm_txnid
    txn->mt_u.reader = NULL
```

DSM mode should instead:

```text
if read txn and DSM mode:
    txnid = dsm_reader_enter(env)
    txn->mt_txnid = txnid
    meta = env->me_metas[txnid & 1]
    remember reader slot index in MDB_txn
```

`dsm_reader_enter(env)`:

```text
1. Pick this reader's local slot from the configured non-overlapping range.
2. Read DSM committed_txnid.
3. If committed_txnid is zero or behind data meta, reconcile from mdb_env_pick_meta().
4. Write owner fields and txnid.
5. Publish active=1 last.
6. Return txnid.
```

Slot selection:

- No cross-node slot allocator is used.
- The process may only use `[LMDB_DSM_SLOT_BASE, LMDB_DSM_SLOT_BASE +
  LMDB_DSM_SLOT_COUNT)`.
- Slot ranges must be page-disjoint across nodes. With one slot per metadata
  page, this is equivalent to non-overlapping slot indexes.
- Within one process, a normal process-local mutex or thread-local assignment is
  enough to map dbbench worker threads to slots.
- First implementation target: one LMDB process per node, or explicitly
  non-overlapping slot ranges if multiple processes are used.

Why use DSM `committed_txnid` instead of directly picking the newest data meta
every time:

- It mirrors LMDB's original lockfile `mti_txnid` behavior.
- It prevents a reader from accidentally publishing an unexpectedly old snapshot
  after a newer commit has already been globally acknowledged.
- If it lags because a previous writer crashed after data meta publish but
  before DSM update, reconciliation can safely advance it.

### Reader Exit Lifecycle

Patch points:

```text
mdb_txn_end()
mdb_txn_reset()
mdb_txn_abort()
```

`mdb_txn_reset()` and `mdb_txn_abort()` already flow through `mdb_txn_end()`, so
the implementation should ideally release the DSM reader slot in one place.

DSM mode should:

```text
if read txn and DSM slot is active:
    store active=0
    clear txn's remembered slot index
```

This must happen for every read transaction reset/abort. It is especially
important for dbbench `readopen`, because each `db_read_one_key()` renews and
resets a read-only transaction.

### Writer Lifecycle

Patch points:

```text
mdb_txn_renew0()
mdb_txn_end()
mdb_txn_abort()
mdb_txn_commit()
```

Current non-`NOLOCK` writer path:

```text
if env->me_txns:
    LOCK_MUTEX(env->me_wmutex)
    txn->mt_txnid = ti->mti_txnid
else:
    meta = mdb_env_pick_meta(env)
    txn->mt_txnid = meta->mm_txnid
txn->mt_txnid++
```

DSM mode should:

```text
if write txn and DSM mode:
    assert single-writer experiment invariant
    dsm_reconcile_committed_txnid(env)
    txn->mt_txnid = dsm_committed_txnid + 1
    meta = env->me_metas[(txn->mt_txnid - 1) & 1]
```

Commit publish:

```text
if write txn committed successfully:
    after mdb_env_write_meta(), publish committed_txnid=txn->mt_txnid
```

The commit publish order must remain:

```text
dirty pages
optional sync
LMDB meta page
DSM committed_txnid
```

`DSM committed_txnid` must not advance before LMDB's meta page is visible,
because readers may use it to select `env->me_metas[txnid & 1]`.

There is no DSM writer unlock step because the first implementation does not
claim a shared writer lock. Running two writers is outside the supported
contract and can corrupt correctness.

### Oldest Reader / Page Reuse

Patch point:

```text
mdb_find_oldest()
```

Current behavior:

```text
oldest = txn->mt_txnid - 1
if env->me_txns:
    scan LMDB lockfile reader table
return oldest
```

DSM mode should:

```text
oldest = txn->mt_txnid - 1
if DSM mode:
    for each active DSM reader slot:
        oldest = min(oldest, slot.txnid)
else if env->me_txns:
    scan original LMDB reader table
return oldest
```

This is the central correctness hook. `mdb_page_alloc()` calls
`mdb_find_oldest()` before consuming freeDB records. If this hook sees remote
reader epochs, pages needed by old remote snapshots will not be reused.

### Difference From Native LMDB MVCC

Native LMDB MVCC has two pieces:

```text
data.mdb:
    B+tree pages
    freeDB
    two meta pages
    copy-on-write updates

lock.mdb:
    writer mutex
    reader table
    committed txnid cache
```

The data-file side remains mostly unchanged in Option B:

- keep LMDB's two meta pages
- keep copy-on-write B+tree updates
- keep the freeDB
- keep the commit order where dirty pages are published before the meta page

The lock-file side is what changes:

```text
native LMDB:
    lock.mdb writer mutex
    lock.mdb reader table
    mdb_find_oldest() scans lock.mdb readers

DSM Option B:
    no DSM writer lock in the first implementation
    single writer is an experiment invariant
    DSM metadata reader table
    mdb_find_oldest() scans DSM reader slots
```

Why this difference is necessary:

- LMDB's `lock.mdb` assumes one OS kernel can coordinate process-shared mutexes,
  PIDs, TIDs, and reader cleanup.
- In the two-node DSM setup, the nodes have separate kernels and PID namespaces.
- The DSM layer provides coherent page visibility, but not cross-node atomic
  read-modify-write operations.
- Therefore the native LMDB writer mutex cannot simply be reused across nodes,
  and a new DSM shared-memory writer lock would also be unsafe.
- The missing correctness state that must be restored is remote reader epoch
  visibility, because page reuse depends on `mdb_find_oldest()`.

In short:

```text
Option B does not replace LMDB's snapshot/COW MVCC.
It restores the cross-node reader epoch information that MDB_NOLOCK removes.
```

### Stale Reader Policy

Default policy:

```text
do not auto-clear remote readers
```

Reason:

- Node-local PID checks do not work across nodes.
- Wall-clock timeout is risky if clocks differ or a reader is paused.
- Clearing a live reader slot is a correctness bug.

For the first implementation, stale reader handling should be explicit:

- Provide debug output or a small helper later to list active slots.
- Allow manual metadata reset only when the experiment operator knows no readers
  are alive.
- Timeout-based cleanup is not part of the first implementation.

### LMDB Struct Changes

Likely internal additions:

```text
MDB_env:
    dsm metadata pointer
    dsm metadata fd/size
    dsm node id
    dsm enabled flag
    dsm slot base/count

MDB_txn:
    dsm reader slot index
```

No writer-lock ownership flag is needed in the first implementation because DSM
mode does not acquire a cross-node writer lock.

### Integration With dbbench

dbbench should not need to understand reader epochs. It only needs to pass the
environment variables that activate DSM mode.

Expected test commands remain the same except for DSM env vars:

```bash
LMDB_DSM_META_PATH=/mnt/famfs/lmdb_7M_4KB.dsm_meta \
LMDB_DSM_NODE_ID=0 \
LMDB_DSM_SLOT_BASE=0 \
LMDB_DSM_SLOT_COUNT=64 \
NOLOCK=1 \
./run_overwrite_lmdb.sh
```

```bash
LMDB_DSM_META_PATH=/mnt/famfs/lmdb_7M_4KB.dsm_meta \
LMDB_DSM_NODE_ID=1 \
LMDB_DSM_SLOT_BASE=64 \
LMDB_DSM_SLOT_COUNT=64 \
NOLOCK=1 \
./run_readopen_lmdb.sh
```

Existing non-DSM smoke test should keep passing without those env vars:

```bash
LMDB/testbench_smoke_lmdb.sh
```

### Test Strategy

Keep three layers of checks:

1. Baseline regression:

```bash
LMDB/testbench_smoke_lmdb.sh
```

2. Local DSM-mode smoke:

```text
single machine, two processes, shared metadata file, MDB_NOLOCK=1
writer process runs overwrite
reader process runs readopen
assert no crashes and metadata counters/slots behave as expected
```

3. Real DSM/FAMFS run:

```text
node 0 writer
node 1 reader
same DB_PATH
same LMDB_DSM_META_PATH
different LMDB_DSM_NODE_ID
non-overlapping LMDB_DSM_SLOT_BASE/COUNT
compare achieved read/write rates and watch active slots
```

### Main Risks

- If two writers run at the same time, there is no DSM writer lock to protect
  the DB.
- If slot ranges overlap, readers can overwrite each other's epoch records.
- If a reader slot is not released on every reset/abort path, writers will stop
  reclaiming old pages and the DB can grow until map full.
- If a writer publishes `committed_txnid` before the LMDB meta page is visible,
  readers can choose a snapshot whose root pages are not safely published.
- If stale readers are manually cleared incorrectly, readers can observe reused
  pages.
- If `MDB_PREVSNAPSHOT` or read-only env modes are used, they need separate
  review before claiming support.

### Resolved Questions From Review

- Metadata path should be explicit via `LMDB_DSM_META_PATH`, not silently inside
  `DB_PATH`.
- DSM does not provide cross-node atomic RMW, so do not implement a DSM writer
  lock in the first version.
- Single writer is an experiment invariant.
- Reader slots are assigned with explicit non-overlapping ranges.
- Stale reader cleanup is manual for the first implementation.
- DSM mode is allowed only with `MDB_NOLOCK=1`.

### Remaining Open Questions

- What exact metadata file size should be required for the initial slot count?
- Should the metadata initializer create the file when missing, or should setup
  scripts pre-create and pre-size it?
- Do we want a tiny metadata dump/reset helper before the two-node run, or is
  debug logging enough for the first implementation?

## Stage 4 TODO Draft Input

After this design is reviewed, convert it into an implementation TODO. The TODO
should be written before touching `mdb.c`.

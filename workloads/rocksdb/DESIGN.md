# rocksdb workload — design (v0.2: plain backend implemented, Megalon backend open)

Status 2026-10-18: plain backend (all-HWcc, Popcorn) built and Host-tested (builds/rocksdb/<n>, tests/host_test.sh,
tests/stress_test.sh); verifier review v1 FAIL (HIGH-1) -> fixes in v0.2 (§9). Megalon backend not implemented (§7).
Decisions (user, 2026-10-18; state/TASKS.md): LSM workload = RocksDB; option (c) per-node memtables (each node writes
only its own memtable, other nodes read it, SSTs shared read-only, cross-node synchronisation only through HWcc, no
CAS on SWcc: docs/hwcc-contract.md); visibility model "A: CXL mode patch" (LMDB-port style: arena blocks and SSTs in
shared memory, a remote node reads the other node's memtable skiplist directly, publication through HWcc; an
acknowledged write is visible at once, as in kv/lmdb); Megalon object = one 1 MiB RocksDB arena block, no application
change; motivation without code restructuring; dataset 54M keys (24 B key, 1,000 B value), mixes u5/u50/u80 (put
ratio 0.05/0.5/0.8, as kv), YCSB scrambled Zipf 0.99, request p99 < 1 ms.

Limitation (as every workload): both VMs share physically HW-coherent memory; a missing flush or a cross-node CAS on
SWcc can be masked by hardware. Tests prove protocol logic and API use, not a SW coherence protocol.

## 1. Source
- RocksDB v11.8.1 (GitHub release 2026-08-07), tarball `rocksdb-v11.8.1.tar.gz` sha256
  618d9726a7cb1cf4ce034f4cdca49de98aa64867dda06b91371a791ae8921aff (downloaded 2026-10-18, user approval).
  Pristine tree outside the repo (workspaces/rocksdb/src/rocksdb-11.8.1); the repo keeps a patch series
  `workloads/rocksdb/patches/*.patch` (every change marked `CXL`) and a fetch/verify script.
- Build: static librocksdb per backend (plain, megalon), no compression libraries, no gflags, WAL disabled at run time.

## 2. Structure: one RocksDB DB per node, read by every node
```
node v (writer of everything below except the global stamp)          node u (reader of node v's state)
 HWcc app: v's descriptor (seqlock) {gen, memtables[K]: head node VA, state}   reads it (acquire)
           v's FS directory + extent map (name -> extents, size)               reads it (acquire)
           v's retire epochs; u's reader epochs (written by u)                 writes only its own reader slot
 SWcc  : v's arena pool (1 MiB blocks)  <- memtable skiplist nodes             traverses v's skiplist read-only
         v's file pool  (1 MiB extents) <- SST, MANIFEST, OPTIONS              opens v's DB as a secondary instance
                                                                              (TryCatchUpWithPrimary on gen change)
```
- Get(k) on any node = lookup in its own DB + lookup in every other node's DB (memtables direct, SSTs via the
  secondary view); the answer is the value with the highest global stamp (value header {key, stamp, writer}, as lmdb).
- Put(k) on node v = stamp = fetch_add(global_stamp) in HWcc, then v's own db->Put (WAL off). The reply is sent after
  the memtable insert, so the write is visible to every later Get on any node.
- Remote SST view (user, 2026-10-18): RocksDB's own `DB::OpenAsSecondary` / `TryCatchUpWithPrimary`, used ONLY for
  the immutable SST/MANIFEST side. With the WAL off the secondary has no memtable content; memtables are always read
  directly (model A). This is not the rejected model B (secondary replaying a WAL into private memtables, stale
  reads). Freshness: node v drops a memtable from its descriptor only after the SST holding its content is in the
  MANIFEST and the new gen is published; a remote Get whose descriptor snapshot has flush_gen > applied first
  catches the secondary up (synchronously); other gen changes (compaction installs) are caught up by the view's
  background thread, and the files the secondary still refers to are kept by the view's persistent pin (§9).
- Get retry (§9, MED-3): a get is repeated while any node's descriptor gen moved during its reads.
- Visibility detail: a remote reader sees a memtable entry as soon as it is linked, which can be before the
  writer's RocksDB sequence is published (and before its reply): a write may become visible early, never late;
  per key the highest stamp wins. Freshness is read-after-ack per key (loadgen plugin, tools/check_log.py).
- Raw pointers in shared memory: the descriptor holds skiplist head VAs and skiplist links are absolute VAs, valid
  because every node maps the device at the same `map_va` (config/cxl_region.yaml; docs/hwcc-contract.md §3 asks for
  offsets: recorded deviation, RocksDB's skiplist cannot store offsets without restructuring).
- Expected cost (recorded): the global stamp is one HWcc line hit by every Put on every node (cross-node hot line,
  one fetch_add per Put); it is the same on every system and appears in all-HWcc too.

## 3. Who writes what (answer to the LMDB lesson: no structure on the write path is written by two nodes)
| structure | location | writers | access |
| --- | --- | --- | --- |
| global stamp | HWcc, 1 line | every node | fetch_add per Put (the only multi-writer word on the write path) |
| memtable skiplist nodes (key, value, next pointers) | SWcc, v's arena blocks | node v only (its write threads; CAS among v's own threads stays inside one node) | other nodes: loads only |
| memtable descriptor {gen, heads} | HWcc, v's lines | node v | seqlock write on memtable switch/flush; readers acquire |
| SST, MANIFEST, OPTIONS, CURRENT files | SWcc, v's file extents | node v (flush, compaction) | write once, then read-only for every node |
| FS directory/extent map | HWcc, v's lines | node v | release store of size after the data |
| reader epochs | HWcc, one line per (reader node, target node) | the reader node | v frees a retired memtable arena or file only when every reader epoch passed its retire gen |
| WAL | none | — | disabled (no durability, as kv) |
No cross-node lock exists on the Put path: each node's writes contend only with its own threads (RocksDB's normal
write path). Flush and compaction of node v's DB run on node v only.

## 4. RocksDB changes (patch series; everything else uses public APIs)
1. `memory/arena.*`: a memtable arena takes its blocks from the node's shared arena pool (1 MiB blocks; the inline
   2 KiB block is disabled for such arenas because it lives in the process heap); `~Arena` retires the blocks with the
   current gen instead of freeing them.
2. Memtable publication: accessor for the skiplist head node of the memtable and range-del table; publication of the
   node's memtable list into the HWcc descriptor whenever the SuperVersion changes (memtable switch, flush install).
3. Remote memtable lookup (new file): read-only search of a foreign InlineSkipList from its head node (same node
   layout, same internal-key order), decoding the memtable entry format.
4. Megalon build only: skiplist node reads and the stores of an insert go through Megalon sections on the containing
   1 MiB block object (read: read_start, copy, read_end, retry; insert: one write section for the new node's block,
   then one per predecessor block whose next pointer changes; write_end flushes the whole object per the paper).
Public-API parts (not patches): FileSystem plugin over the file pool; secondary instance for the remote SST view;
CompactionFilter (§5); server, loadgen plugin, image builder.

## 5. Stale copies across the per-node DBs (space) — decided G1 (user, 2026-10-18)
A key updated on node u while its latest version lives in node v's DB leaves the old version in v's DB; v's own
compaction never sees u's newer version. Without cleanup each DB tends to hold every key it ever wrote: worst case
2 x 54M x ~1.05 KB ≈ 115 GB > 95.7 GiB SWcc.
Options:
- (G1) CompactionFilter (RocksDB plugin API): while compacting entry (k, stamp s), drop it if another node's DB holds
  k with a higher stamp (remote Get, bloom filters keep misses cheap). Safe (two DBs cannot both be newer); keeps the
  total near 1 x dataset plus compaction lag. Cost: extra remote reads inside compaction, on every system.
- (G2) No cleanup; restore the initial image per run and refuse to run when a node's pools fill. Simple, but the
  space bound depends on the run length and the update rate.
- (G3) Key ownership (updates forwarded to the key's owner node). Rejected: violates "each node writes its own
  memtable" for received requests and adds a hop.
Decision: G1 (user, 2026-10-18).

## 6. Initial image, sizes, options (as implemented, plain backend)
- 54M keys split by key index (key i on node i mod nr_nodes; 27M each). Each node builds its share at prepare as SST
  files of disjoint key ranges (SstFileWriter, `--prepare-threads`, ~60 MiB each) written straight into its own file
  pool and ingested with `move_files` (FS LinkFile shares the extents) into the bottom level; values stamp 0,
  writer 0xffff; unmeasured. Per node ≈ 28.4 GB + space amplification; SWcc split in equal 1 MiB-aligned shares
  (≈ 47.8 GiB per node): `--arena-blocks` (512 = 512 MiB) + file extents (the rest).
- Stored value = 8 B global stamp + the 1,000 B request value (1,008 B; deviation from kv/lmdb's 1,000 B: the
  stamp orders versions across the per-node DBs). Get returns the 1,000 B value and the stamp.
- Per-node ordering: a Put takes a process-local key stripe (4,096 mutexes) around stamp fetch_add + db->Put, so
  one node's DB never holds a lower stamp above a higher one for the same key (concurrent RocksDB writers).
- RocksDB options (non-defaults): WAL off per write (`disableWAL`), WAL dir local (empty); compression none (all
  levels); `max_open_files` -1; bloom filter 10 bits/key (BlockBasedTable; RocksDB's default has no filter, but a
  get here probes every node's DB, and the other DB rarely holds the key); `arena_block_size` 1 MiB (= the default
  for 64 MiB write buffers, set explicitly to pin the object unit); `max_manifest_file_size` = max_ext/2 MiB (a
  MANIFEST must fit one directory slot); info LOG local. Everything else default (write_buffer_size 64 MiB,
  max_write_buffer_number 2, leveled compaction, block cache default). `--write-buffer-mb` exists for Host tests only.
- HWcc app bytes (2 nodes, defaults): stamp, node lines, descriptors, directory (2,048 slots x (128 B head + 768 B
  extent list) per node), epochs (64 slots per node); `rocksdb-server --print-app-bytes`.
- Threads per node: `--threads` request workers (one FIFO queue for gets and updates), RocksDB flush/compaction
  threads (default `max_background_jobs`), one catch-up thread per remote view, one reclaim thread. Every thread
  that reads another node's state owns one epoch slot.

## 7. Megalon (paper first, artifact where it matches)
- Objects: every 1 MiB arena block and every 1 MiB file extent of both nodes, created by node 0 at prepare
  (no ObjectCreate during the run; pools are fixed).
- File extents are written once by flush/compaction (one write section per extent fill), then read on Megalon's
  read-only path (one read section per RandomAccessFile::Read span inside an extent).
- Deviation candidates (to document): the extent unit for files (follows the arena unit); every memtable node access
  (local and remote) goes through sections.

## 8. Requests, metrics (as kv/lmdb)
- Ops `get`, `update` (put of an existing key, whole 1,000 B value), `mixed` with put ratio 0.05/0.5/0.8; SLO request
  p99 < 1 ms; per-op split T/C via opsplit.h (Popcorn swmc_acct, Megalon CohSnap); stats of RocksDB (flush,
  compaction bytes/time, stall), pools usage, remote lookups, filter drops.

## 9. Verifier review v1 (2026-10-18) and changes in v0.2
- HIGH-1 (fixed): the secondary's current SuperVersion refers to SSTs/MANIFEST between gets, but the reader epoch
  was held only during a get, so a compaction-deleted file could be reclaimed and its extents/slot reused while the
  secondary still referred to it. Fix: each RemoteView owns a persistent epoch slot (not thread-local) pinned at
  the gen the secondary is caught up to; set before OpenAsSecondary, raised only after a catch-up installed the
  newer state, cleared when the view closes. A file in the state caught up at gen a was removed by an edit
  published at R > a, so its tag T >= R > a and it is not freed.
- MED-2 (added): tests/stress_test.sh: tiny pools (12 arena blocks, 200 extents, 160 directory slots, 8 MiB files),
  64 KiB MANIFEST limit (rollovers), update-only phases between mixed phases (no reader epochs while compactions
  delete files); requires reuse of blocks, extents and slots and >= 2 MANIFESTs per node.
- MED-3 (fixed): G1 can drop the version a get would have found in one DB while the successor version appears in
  another DB after the get read it. Every drop becomes visible only through an install (gen++), so Node::get repeats
  while any node's gen changed during its reads (stats get_retries, get_retry_limit after 1,000 attempts).
- MED-4 (VM pass criteria): a get that finds a value on one node but gets an error from another still answers;
  every run must require remote_errors = get_errors = update_errors = remoteN.errors = remoteN.catchup_errors = 0
  (host_test.sh / stress_test.sh do; the VM packet must too).
- MED-5 (packet): space is not bounded by construction (image ~28.6 GB per node in a ~47.8 GiB share; L0-L5,
  compaction transients and cross-node stale copies until G1 reaches them). Stats export pools.extents_free and
  pools.blocks_free; exhaustion gives NoSpace (files) or abort (arena). The VM packet needs a stop rule on
  pools.extents_free, a fresh image per run and a bounded run length per mix.
- LOW: retired-name fallback now takes the newest retired slot (per-slot creation serial); raw VAs documented (§2);
  tools/check_log.py = offline exact check of log=1 runs; early visibility documented (§2); each DB instance
  (primary and every secondary) has its own DRAM block cache (RocksDB default, 32 MiB), to record in the manifest.
- User confirmations (2026-10-18): bloom filter 10 bits/key and the 1,008 B stored value stay.

# HWcc usage contract (all systems, all workloads)

Agreed with the user 2026-10-15. Applies to every workload (vectordb, LMDB, distributed PageRank, recommendation
with embedding updates, ...) on every system (all-HWcc, Megalon, Popcorn).

## 1. One budget, three owners
The HW-coherent range (`hwcc_size`, 256 MiB) is the whole hardware-coherent budget. System, workload and the
kernel message ring all share it; nothing HW-coherent exists outside it.

```
hwcc  [hwcc_offset, +hwcc_size)
├─ system    hwcc_alloc = everything else, from hwcc_offset (Megalon: control block + SCR; unused by
│            all-HWcc and Popcorn)
├─ app       workload control state, directly below msg_ring; size = the workload's computed need
└─ msg_ring  Popcorn cxl_shm rings, the last bytes of hwcc (config/cxl_region.yaml)
```

- Each owner touches only its own range. Systems allocate only from `hwcc_alloc`; Popcorn's MSI protocol tracks
  only SWcc data pages; the workload uses only `app`.
- No allocator. Every consumer's need is fixed at startup from the run parameters, and nothing is freed while a
  run is live, so there is no fragmentation to manage:
  - the workload computes its layout (`systems/common/hwcc_app.h` `layout`) and the harness passes
    `CXL_APP_HWCC_BYTES = layout.bytes()` to every node; `cxl_region.h` carves `app` and shrinks `hwcc_alloc`;
  - the system takes the rest (Megalon's SCR is its own startup bump arena; its record pool and reclaim are
    Megalon's own mechanism, per the paper);
  - a run whose parts do not fit refuses to start (cxl_region.h, Megalon's SCR footprint check, `app_init`).
- `app` is not a tuned knob: same trace and parameters give the same size and offset on every system. The
  more a workload keeps in HWcc, the less the system has (e.g. Megalon records); that is a fair cost, recorded
  in the manifest.

## 2. What may live in `app`
- Allowed: small, bounded control state shared between nodes: atomic counters and watermarks, bitmaps,
  version words / seqlocks, locks, barriers, flags, descriptors (SWcc offset, size, state).
- Not allowed: bulk data (vectors, graphs, DB pages, rank vectors, embedding rows), and anything whose size is
  not bounded at startup. Growing structures (e.g. vectordb segments) get a maximum computed from the run
  parameters; exceeding it fails the run.
- Per-item metadata (e.g. one version word per embedding row) only if its total, computed from the parameters,
  fits; otherwise group it (per shard / page).
- Identical in every system: the layout code does not depend on the system. all-HWcc must not keep extra state
  in HWcc just because everything is coherent there; that would make the baseline unfair.

## 3. How `app` is accessed
- Shared mutable words only through aligned atomics of at most 8 bytes with explicit ordering
  (`hwcc_app.h` `load_acquire` / `store_release` / `fetch_add` / `cas` ...). No plain loads or stores of words
  another node writes.
- Publication pattern (all systems): write data in SWcc → the system's write-end coherence step (Megalon
  write section end; nothing in all-HWcc/Popcorn) → release store in `app`. Reader: acquire load in `app` → the
  system's read section on SWcc → read.
- Store offsets (from the region base), not pointers; no process-local objects (pthread/std mutexes,
  condition variables, std containers) in shared memory.
- No futex waits across nodes: a futex wakes threads of one kernel only. Cross-VM waiting is polling
  (`poll_until`: pause, then yield; UMWAIT allowed).
- Document each field's writer set. A field written by one node sits in that node's own cache line
  (`layout.add` aligns to 64 B by default); fields written by several nodes change only via atomic RMW.
- Per-node arrays are sized by `nr_nodes` (2 now, up to 8 later), never by a constant.

## 4. Startup and run identity
- The first 64 B + `joined[]` of `app` is a header (`hwcc_app.h`): magic, version, nr_nodes, layout hash,
  size, run_id, state.
- Node 0 zeroes `app`, writes the header, release-stores run_id and then READY. Every other node polls for its
  run_id and READY, checks magic/version/hash/size/nr_nodes, then marks itself joined. Mismatch = refuse.
- run_id is fresh per run (as for Megalon), so a previous run's READY is never taken.

## 5. Records
Every run manifest records `hwcc_alloc`, `app` and `msg_ring` sizes, the app layout bytes and hash, and the
system's actual HWcc use (e.g. Megalon "SCR used").

## 6. Workload sketches (not binding)
| workload | in `app` | in SWcc |
|---|---|---|
| vectordb | P, applied bitmap (W bits), seg_count[nr_nodes], segment descriptors (nr_nodes × MAXSEG), delete-log published counts | vectors, HNSW index blobs, delete-log bodies |
| LMDB | writer lock (polling spinlock replacing the pthread robust mutex), reader table, meta (txnid, root) | B+tree pages |
| PageRank | per-iteration barrier, per-node progress, convergence flag | graph, rank vectors |
| recommendation | per-shard version words, update counters | embedding table |

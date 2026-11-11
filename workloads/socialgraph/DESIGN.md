# socialgraph workload — design

Experiment: reports/experiments/socialgraph-serving.md (§2 workload, systems, metrics). TAO / LinkBench object-
association graph served from the shared region; graph = SNAP com-Orkut, operation mix / payload sizes / skews from
LinkBench (tools/linkbench_params.h, tools/LINKBENCH_PARAMS.md). Structure follows workloads/vectordb.

## 1. Graph image (server/layout.h)
Built on the Host as a regular file (tools/sg_image_gen.cc via tools/make_image.sh), copied into the SWcc range of
the region in the guest like the vector DB index image. Same bytes for every system.

| array | content | record |
| --- | --- | --- |
| header | ImageHeader (page 0): counts, array offsets, caps, seed, layout hash | - |
| adj_index | uint64 per node slot: offset of the primary adjacency block (read-only) | - |
| nodes | one 128 B NodeSlot per Orkut node + node_slack free slots (addnode) | node slot |
| adj | one primary block per node: 64 B AdjHeader + inline 32 B EdgeSlots, packed in node order | adjacency block |
| ovf | 4 KiB overflow blocks (64 B header + 126 slots): built blocks of high-degree nodes, then a free pool (addlink) | ovf block |

- Arrays start on 4 KiB pages; every record starts on a 64 B line and covers whole lines (no two records share a
  line). Primary blocks are packed, so a block may straddle a page (fraction in the image manifest).
- NodeSlot: id, version (1 at load), commit_ns (writer commit time, 0 in the image), type, time_s, flags, data_len,
  data capped at 88 B (LinkBench node payload LogNormal median 128 B; capped fraction in the manifest).
- EdgeSlot: id2, assoc_type (0 = friend), flags (live), data_len, time (ms), version (0 at load), data capped at 12 B
  (LinkBench link payload LogNormal median 8 B).
- AdjHeader: id1, list version, commit_ns, count (live), used, head / next segment, inline start / cap, ovf count.
- Adjacency list = chain of segments, newest first. Within a segment the used slots are [start, cap), newest at
  start; slack lies in front. Built: newest min(deg, 120) links inline + slack max(2, ceil(e/8)) (even, <= 126 slots,
  primary block <= 4 KiB), older links in full ovf blocks (oldest block partial). addlink: write slot start-1 of the
  head segment; when the inline segment is full, take a pool block, fill it from the end, link next = old head and
  publish it as head. deletelink clears the live flag (no compaction). Feed limit 50 is always served inline at build.
- Link times are synthetic and deterministic: one time per undirected edge, time = base_ms - 2^31 + 1 +
  splitmix64(seed, min id, max id) mod 2^31 (LinkBench load uses the same ~50 day window); ties ordered by id2 desc.
  Payload sizes and bytes: LinkBench LogNormal / byte ranges, hashed from (seed, id) — no RNG stream state.
- Slack slots and pool blocks are owned by writer w = index mod N (one writer per VM), so allocation needs no
  shared counter (layout.h owned_by).

## 2. Coherence objects (part 5, Megalon)
- Record granularity: one object per node slot, primary adjacency block, ovf block (built + pool):
  `for_each_record_object`, `record_objects()`.
- Data structure granularity: 36 MiB chunks of each array, each array chunked from its own start:
  `for_each_chunk`, `chunk_of`.

## 3. Requests (proto.h)
Feed query (getlinklist id1 limit 50 newest first + multiget of the neighbour nodes; the SLO operation), getnode,
countlink, getlink (multiget of id2s), addlink / updatelink / deletelink / addnode / updatenode / deletenode.
Responses carry RespHead (status, server time, records touched) and, optionally, the vectordb OpCoh block.

## 4. Server (part 3: server/{backend.h, mmap_backend.h, graph_ops.h, stale_log.h, opwin.h, server.cc})
- Process per VM, frame.h transport; connection threads queue reads to the query threads (online CPUs - 1, i.e. 3 at
  4 vCPU) and writes to the VM's single writer thread (arrival order); stats answered inline (key=value text: op.<op>.*
  counts / server ns, seq.* retries, write lag, alloc.*, stale.*, opt.<op>.* window counters, proc_stats.h counters).
- Backend seam (backend.h): Server<Be> / GraphOps<Be> call be.read(kind, idx, f) / be.write(kind, idx, f) /
  write_range per record (node slot, primary adjacency block, ovf block); plain = MmapBackend (All HWcc, Popcorn,
  De Stijl: same code, region config + kernel differ; De Stijl T applied to the whole image). Megalon (part 5) adds a
  class with read / write sections per record object or per 36 MiB chunk (layout.h for_each_record_object / chunk_of).
- Record protocol (graph_ops.h): seqlock on the record version word (node: NodeSlot.version; list: AdjHeader.version
  covers the primary block and its ovf segments). Writer: atomic fetch_or of bit 63 (= "odd" writing state, also the
  write-ownership access), write, commit_ns, release store of version + 1. Versions keep the LinkBench meaning (node 1
  at load, list 0, +1 per write). Reader: acquire load, retry on bit 63, copy, acquire fence, re-load, retry on change.
  Extra guards against a page replica mixing ages: node check word in NodeSlot.pad (0 = image record, only with
  commit_ns 0); adjacency bounds / ovf owner id1 checks. 64 spins, then yields, give-up after --retry-ms (2000) with
  kStatusBusy. Writers of different VMs exclude each other with HWcc stripe locks (app range); slack slots and pool
  blocks by index mod N (owned_by), private cursors.
- Staleness logs (stale_log.h): 1 in --stale-every (1000) record reads -> stale-reads-n<k>.bin, every commit ->
  stale-commits-n<k>.bin (rid, version, CLOCK_REALTIME ns) under --stale-dir; joined by tools/sg_stale_join.py with the
  Host clock-offset log of the RecSys T-sweep (workspaces/clock-offset-log-v1.py format).
- Image: --copy-image FILE (node 0, plain mapping, no HWcc access; header page written last), --verify [--image FILE]
  (header, layout hash, sampled records, byte comparison with the file). Serving attaches to the copied image.

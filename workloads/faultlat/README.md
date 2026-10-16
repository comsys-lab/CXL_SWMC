# workloads/faultlat — coherence fault-latency microbenchmark

Measures the latency of single user accesses that each take one page fault on
a coherence-managed device-DAX mapping, end to end as the application sees it
(exception, coherence protocol including the inter-VM message round trip, PTE
install, re-executed access). Per-access samples, percentiles and a
log-linear histogram (8 buckets per power of two) per pass. Works on any
system that coherence-manages devdax mmaps (Popcorn kernels; other systems can
run it unchanged, the kernel counters are then just absent).

Plugin layout: `setup.sh` (build), `run.sh` (one step on this node),
`parse.py` (CSV summary), `scenarios.sh` (two-node step sequence, from the
Host), `faultlat.cc` (the tool), `contend.h` / `contend_test.cc` (contend data
invariant + unit tests, `make test`), `stress_summary.py` + `stress/*.txt`
(contend scenario matrices; driver `scripts/deploy/p-popcorn-stress.sh`).

## Build

    workloads/faultlat/setup.sh [outdir]        # g++ -O2, C++17; prints sha256

Needs `systems/common/cxl_region.h` (included by relative path). Copy the
binary plus `run.sh` to the guests (e.g. `/home/comsys/faultlat/`).

## Region

All offsets come from the region config (`config/cxl_region.yaml`, path in
`CXL_REGION_CONFIG`). The tool maps windows of the swcc range only:
`--page-offset P` is the first page relative to `swcc_offset`.

`faultlat params [--nodes N]` prints the cxl_shm module parameters derived
from the same config (N = 2 by default): `nr_nodes=N`, `managed_offset/size`
= exactly the swcc range (the MSI-managed range; never hwcc), `ring_offset/size`
= the `msg_ring: [offset, size]` key (tail of hwcc, so `ring_coherent=1`).
It refuses a ring that is too small for N nodes (cxl_shm v7 sizing: N=2 needs
69632 B, N=8 1851392 B). `--device-size B` replaces the sysfs device size, for
a dry run on the Host (dax0.0 exists only in the guests). With the current
config and the guests' dax0.0 (103060340736 B) it prints

    dax_name=dax0.0 nr_nodes=2 ring_offset=268300288 ring_size=135168 ring_coherent=1 managed_offset=268435456 managed_size=102791905280 init_state=invalid

`--init-state shared` selects cxl_shm's "all Shared" initial state (v7;
reports/P-popcorn-init-shared.md). It must be the same on all nodes; the
guest tooling recomputes the string and refuses a difference.

Example for the Popcorn kernel (root; grant-gated):

    insmod cxl_shm.ko node_id=<0|1> $(faultlat params)

## Preconditions on both guests (grant-gated, not done by these scripts)

1. Popcorn kernel booted; cxl_shm loaded on both nodes with identical
   parameters (including `nr_nodes`) and different node ids. Each node only writes its own ring
   lines; the link comes up when both are loaded (dmesg "link to node N up").
2. Coherence enabled before the first mmap (syscall 470,
   `enable_page_coherence`, root; returns EAGAIN until the link is up).
   A devdax mapping created before that is not write-notify and gets SIGBUS
   on managed pages; while managed mappings exist, disabling returns EBUSY
   and cxl_shm cannot be unloaded.
3. `/dev/dax0.0` readable/writable by the user running the tool, device align
   4096.

## Steps

    run.sh <outdir> <step> access --op read|write|rw --pages N --page-offset P \
           [--stride S] [--passes K] [--shuffle] [--cpu C] [--pattern X] [--expect X]
    run.sh <outdir> <step> pingpong --role 0|1 --nonce X --iters N --page-offset P [--cpu C]

- `access`: one 8-byte load or store per page; pass 0 faults on every page
  that is not mapped with the needed permission, later passes show the
  no-fault access cost. `rw` reads all pages then writes all pages in the same
  process (the writes take the write-protect / pfn_mkwrite fault on S pages).
  `<step>_minflt` confirms one fault per page.
- `--pattern X` (writes) stores X ^ page index in the first and last word of
  every page; `--expect X` (reads) checks both words and exits 2 on any
  mismatch (`verify` in the JSON). Page index = swcc page number.
- `pingpong`: two nodes hand a turn back and forth on one managed page; each
  hand-off is a write on a page the peer holds and a read fault on I at the
  peer. Role 0 records the round trip (2 hand-offs). Start role 1 first;
  `--nonce` must be the same on both and new per run. Every turn checks
  that all earlier increments are visible (`seq_errors`, exit 2).
- Each step writes `<step>.json` (summary, histogram, kernel counter deltas
  from `/sys/kernel/swmc/page_coherence`), `<step>.csv` (raw samples) and
  `<step>.env` (kernel release, protocol, knobs, cxl_shm parameters, binary
  and config hashes, load average).

## Instrumentation overhead check (faultlat-4, Popcorn build 9)

`access` and `pingpong` register the measuring thread's `swmc_acct` area
(systems/popcorn_new/include/swmc_acct.h; `--acct 0` skips it) and add an
`instr` object to the step JSON: `/sys/kernel/swmc/instr/enabled` before and
after the step, whether the registration succeeded, the area's deltas
(`acct_{is,sm,wpu}_fault_ns/_faults`, `acct_ipi_ns/_count`) and the deltas of
every `/proc/thread-self/swmc` counter of that thread (`thread_delta`; names
ending in `_ns` are durations, the rest counts; `instr_clock_reads` /
`is_faults` = clock reads per counted fault). On kernels without build 9 the
registration fails (`acct_registered 0`) and the deltas are absent or zero.
Overhead comparison (a later VM packet; writing `enabled` needs root): the
same step with `instr/enabled` 1 and 0 (and 1 with `--acct 0`), comparing
the latency percentiles; `parse.py` exports `instr_enabled`,
`acct_registered` and the main build-9 deltas as CSV columns.

## Correctness smoke test (smoke.sh)

`smoke.sh <run-id> <base-page> [--execute]` (same env as scenarios.sh, PAGES
default 1024): c1 node1 writes / node0 reads and checks; c2 node0 overwrites
the shared pages (S->M) / node1 checks; c3 both nodes write disjoint halves at
once, then check each other's half at once; c4 both nodes write the same pages
at once (conflicts), then node0 writes a pattern and node1 checks it; c5
ping-pong with a per-turn sequence check (every turn must see all earlier
increments). Any data mismatch or sequence error makes the step exit 2 and
stops the sequence. Uses 5 windows from `<base-page>`.

## Scenarios (scenarios.sh)

| Step | Node | What is measured | Local transition | Peer work |
| --- | --- | --- | --- | --- |
| s1_read_I_peerI | 0 | read-on-I | I->S | none (peer I) |
| s2_read_I_peerM | 0 | read-on-I | I->S | M->S: write-protect, write back |
| s3_write_I_peerM | 0 | write-on-I | I->M | M->I: unmap, write back |
| s4_write_I_peerS | 0 | write-on-I | I->M | S->I: unmap |
| s5_rw_peerS (pass0_write) | 0 | write-on-S | S->M | S->I: unmap |
| s6_rw_peerI (pass0_write) | 0 | write-on-S | S->M | none |
| s7_pingpong_r0 | 0+1 | round trip | alternating | alternating |

`scenarios.sh <run-id> <base-page>` prints the ssh commands; `--execute` runs
them (needs the shared-memory grant). Page states persist across runs, so
every run needs a fresh `<base-page>` (the script prints the next one) or a
reboot of both guests. Then collect the guest output dirs and run
`parse.py <dir>... > summary.csv`.

## N-node scenarios (Popcorn broadcast MSI, popcorn-msi-n)

With `NODES="<ssh0> <ssh1> ... <sshN-1>"` (N > 2) `scenarios.sh` also runs,
on windows of `PPAGES` pages (default 256):

| Step | What is measured |
| --- | --- |
| s8_writer, s8_reader_k | one writer (node 0), then readers 1..N-1 in turn: the first read-on-I makes the writer downgrade M->S, later readers find only S sharers (each fault still waits for N-1 ACKs) |
| s9_rr_writer_k | round-robin writers: node k writes after node k-1 (write-on-I, previous writer M->I, N-1 INVALIDATEs per fault) |
| s10_conc_writer_k | all N nodes write the same pages at once (write-write conflicts; NACK/abort/retry counters show the priority rule at work) |
| s11_ring_rk | token ring over all N nodes on one page (`pingpong --nodes N`); role 0 records one lap (N hand-offs) |

`pingpong --nodes N --role r` works for any N >= 2 (N = 2 is the old
ping-pong).

## Knobs worth sweeping (Popcorn kernels; root, so grant-gated)

- `/sys/kernel/swmc/page_coherence/acquire_flush` (1/0): requester flush on
  I->S/M.
- `/sys/kernel/swmc/page_coherence/downgrade_flush` (1 revoke-then-flush,
  2 flush-then-revoke, 0 none).
- `/sys/kernel/swmc/page_coherence/wait_spin_ns`: ACK spin budget.
- `/sys/module/swmc_kmsg/parameters/inline_dispatch` (Y/N).
- cxl_shm `idle_spin_us`, `idle_sleep_us` (runtime), `recv_cpu` (load time).

Flush knobs at 0 are only correct on the hardware-coherent testbed and exist to
measure their cost.

## High-contention stress (`contend`)

`faultlat contend` runs T threads per node (1..1024, nodes*T < 4095) on a hot
set of H SWcc pages (`--pages H --page-offset P`) for D seconds; each op picks a
page (`--dist uniform|zipf|partition`) and reads it (read ratio `--read-pct`,
may differ per node) or writes it. All nodes run the same command with their
`--node k`, the same `--run-id` (new per run) and `CXL_APP_HWCC_BYTES` =
`faultlat contend --app-bytes --nodes N --threads T --pages H`.

Data invariant (details in `contend.h`): a write stores one 8-byte stamp
(writer, per-writer seq, 16 check bits) XOR a page/word mask in every word, in
ascending order; a read loads the words in descending order and checks, with
per-thread floors per (page, writer): no word older than a newer word of the
same writer above it in the same scan (`stale_intra`), no regression below
seqs seen in earlier scans or written by the thread itself (`stale_cross`),
every word decodes for this page and offset (`corrupt`). After all writers
stopped, every node checks that every word holds its writer's LAST write to
that page (`final_stale`, `final_init_left`; last seqs exchanged through
HWcc). Torn pages from concurrent writers are legal and not reported. With
T = 1 and reads, the SWMR probe compares each fault-free scan with the
thread's previous fault-free scan of that page (a faulted scan or an own write
drops the reference): a change by another node's writer without any fault in
between (RUSAGE_THREAD) means a missing invalidation
(`unfaulted_remote_change`). On a hardware-coherent testbed the data checks
can only see protocol bugs that change data (wrong pfn, copies, stale
write-back); the probe also sees a PTE left mapped after a remote write.

Liveness: per-thread progress sampled every `--interval-ms` (100):
`starvation_samples` (thread did nothing while others progressed),
`node_stall_samples`, `global_stall_samples` (node 0: nobody progressed),
`max_thread_zero_ms`, per-thread op counts with min/max and Jain fairness,
worker faults per op, read/write latency histograms (p50/p99/p99.9/max).
Watchdog (`--watchdog-s`, default 10): no progress on this node, or one op in
flight, for that long -> per-thread dump (in-flight page/op/age, state, wchan,
peer threads' in-flight ops) in JSON and stderr, exit 3. After the run a
post-run guard bounds every later step (worker drain: watchdog; each barrier:
barrier timeout + watchdog; final scan: watchdog + 1 ms per page) with the same
dump and exit 3, so the process never hangs in a join. All nodes create their
threads, then pass a cross-node start barrier, then release them together. SIGBUS -> stderr line,
exit 4 (no JSON). Violation -> exit 2 (both nodes stop via the abort word;
the peer exits 6). Coordination timeout (`--barrier-timeout-s`, 120) -> 5.

Coordination uses only the HWcc app range below msg_ring (`hwcc_app.h`
header/run_id handshake, phases, abort word, per-thread progress lines, last
seq table); the hot set is the only SWcc memory touched. Node 0 writes the
init stamp on the hot set unless `--skip-init` (init_state=shared: preload it
before enable with `contend --init-only --pages H --page-offset P --salt S`
through a plain mapping, then run with `--skip-init --salt S`).

Other options: `--max-ops M` (per thread; with `partition`, every writer
walks its own H/(N*T) pages once, so ops hit fresh pages: request-slot
exhaustion test), `--churn-us U` (extra thread: MADV_DONTNEED of a random
hot-set page every U us, every 8th time map it through a fresh VMA, check,
unmap), `--think-ns`, `--cpu-list`, `--no-abort`, `--no-swmr-probe`,
`--inject stale|corrupt|lost|stall|sigbus:N` (Host tests only).

Matrices: `stress/main-v1.txt` (Part S), `stress/shared-v1.txt` (Part T),
`stress/idle-v1.txt` (optional recv_mode idle/sleep). Driver and evidence
layout: `scripts/deploy/p-popcorn-stress.sh`; packet
`reports/P-popcorn-stress-packet.md`.

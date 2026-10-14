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
Host), `faultlat.cc` (the tool).

## Build

    workloads/faultlat/setup.sh [outdir]        # g++ -O2, C++17; prints sha256

Needs `systems/common/cxl_region.h` (included by relative path). Copy the
binary plus `run.sh` to the guests (e.g. `/home/comsys/faultlat/`).

## Region

All offsets come from the region config (`config/cxl_region.yaml`, path in
`CXL_REGION_CONFIG`). The tool maps windows of the swcc range only:
`--page-offset P` is the first page relative to `swcc_offset`.

`faultlat params` prints the cxl_shm module parameters derived from the same
config: `managed_offset/size` = the swcc range, `ring_offset/size` = the
`msg_ring: [offset, size]` key, which must lie inside the hwcc range (so
`ring_coherent=1`). Until systems/common/cxl_region.h knows `msg_ring`, the
tool strips that key before loading the rest of the config; other users of
cxl_region.h reject the key, and HWcc users must not allocate over the ring.
Proposed config addition (last 132 KiB of the default 256 MiB HWcc range,
512 slots per window = 1024 per direction):

    msg_ring: [268300288, 135168]   # inside hwcc; cxl_shm message rings

Example for the Popcorn kernel:

    eval "$(faultlat params)"     # sets dax_name ring_offset ... as shell vars
    insmod cxl_shm.ko dax_name=$dax_name node_id=<0|1> ring_offset=$ring_offset \
        ring_size=$ring_size ring_coherent=$ring_coherent \
        managed_offset=$managed_offset managed_size=$managed_size

## Preconditions on both guests (grant-gated, not done by these scripts)

1. Popcorn kernel booted; cxl_shm loaded on both nodes with identical
   parameters and different node ids. Each node only writes its own ring
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
           [--stride S] [--passes K] [--shuffle] [--cpu C]
    run.sh <outdir> <step> pingpong --role 0|1 --nonce X --iters N --page-offset P [--cpu C]

- `access`: one 8-byte load or store per page; pass 0 faults on every page
  that is not mapped with the needed permission, later passes show the
  no-fault access cost. `rw` reads all pages then writes all pages in the same
  process (the writes take the write-protect / pfn_mkwrite fault on S pages).
  `<step>_minflt` confirms one fault per page.
- `pingpong`: two nodes hand a turn back and forth on one managed page; each
  hand-off is a write on a page the peer holds and a read fault on I at the
  peer. Role 0 records the round trip (2 hand-offs). Start role 1 first;
  `--nonce` must be the same on both and new per run.
- Each step writes `<step>.json` (summary, histogram, kernel counter deltas
  from `/sys/kernel/swmc/page_coherence`), `<step>.csv` (raw samples) and
  `<step>.env` (kernel release, protocol, knobs, cxl_shm parameters, binary
  and config hashes, load average).

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

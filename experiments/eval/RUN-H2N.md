# New H2 = vector DB VM-count scaling (run sets h2n-n2, h2n-n4, h2n-n8) — how to run

Design: user decisions 2026-10-20 22:3x (state/PROJECT.md, last entry). Claim: aggregate throughput should scale about
linearly with N; with coherence it scales less than all-HWcc and the gap widens with N.
- N = 2, 4, 8 VMs, EVERY VM 4 vCPU / 24 GB: the VM8 topology (vmN-chain-v2.sh VMN_TOPO=8; vmN-xml.py --n 8 --vcpus 4
  --ram-gib 24 = the VM8 XMLs), starting cxl_vm0..N-1. N = 2 is measured on 2 x 4 vCPU (not the 16-vCPU 2-VM run).
- Mixes u5, u50, u90 at every N; systems hw (all-HWcc), mg (Megalon, LOGICAL_NODE_NUM = N), pop (Popcorn build 12
  N-node bundle, recv_mode=sleep). Threads per VM: 3 search + 1 writer (threads = vCPUs).
- Per (N, mix, system) ONE aggregate SLO search (search p99 <= 100 ms; the H1 SLO part arguments, h2n.conf
  H2N_SLO_PART); the offered total rate is split evenly over the N VMs. No fixed-load windows, no CDF pass, no mgoff
  (C_diff needs fixed windows; `mgoff` is accepted by the block if H2N_SYSTEMS lists it).
- Per step: stats snapshots of every VM (Popcorn fault counters, Megalon object counters), Host CXL.mem bandwidth
  (cxl-bw-sampler.sh, started after the block's lock, stops itself at the unlock).

Files: h2n.conf (EVAL_CONF; config_sha256 = vdb keys + H2N_*), runset-h2n.sh (driver per N), h2n-block.sh (block),
h2n_layout.py (delete-log layout per N), export_h2n.py (CSVs), cxl-bw-sampler.sh + cxl_bw.py (copies of
workspaces/cxl-bw), test/test_export_h2n.py. Chain: workspaces/h2n/h2n-chain-v1.sh (one run k: install, switch,
N = 2 / 4 / 8 blocks, restore, export; `--dry-run`, `--start` resume points).

## Delete-log layout per N (h2n_layout.py; backend.h:34-35 allocates one delete log per node)
Total delete-log capacity is kept at the 2-VM total (2 x 1835008 entries); each VM's share of the 3,400,000 deletes
of the N-target writes file must fit its node log. Device 103060340736 B, SWcc from 268435456 B, 89 groups/segment.
| N | max_deletes/node | dlog/node (B) | dlog total (B) | swcc_used_end (B) | headroom (B) | largest per-VM deletes | margin |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 1835008 | 117440512 | 234881024 | 103045660672 | 14680064 | 1700590 | 134418 |
| 4 | 917504 | 58720256 | 234881024 | 103045660672 | 14680064 | 850736 | 66768 |
| 8 | 458752 | 29360128 | 234881024 | 103045660672 | 14680064 | 425750 | 33002 |
Megalon (28M capacity, VDB_MG_CAPACITY=h1): --max-deletes per node 1048576 / 524288 / 262144 (same total).
Writes files: N = 2 builds/vdb-inputs/3/writes-a27m-b3400k-u3400k.bin, N = 4 / 8 builds/vdb-inputs/4/*-vms4.bin,
*-vms8.bin (same seed, ids and order; targets over N VMs; already built 2026-10-20 16:05).

## Megalon per N (placeholders in h2n.conf until the megalon-n agent delivers)
H2N_MG_LIB_N<N> (builds/megalon/<n>, manifest constants_h_LOGICAL_NODE_NUM = constants_rs_LOGICAL_NODE_NUM = N),
H2N_MG_BUILD_N<N> (vdb-megalon build on it, shim_kind=shared), H2N_VMEG_N<N> (guest dir, installed on vm0 BEFORE the
topology freeze: the chain's install step), H2N_MG_CFG_N<N> (Megalon config). N = 2: builds/megalon/77 +
builds/vdb-megalon/14 + /home/comsys/vdbm14r2m + systems/megalon/vectordb-2vm.yaml. The driver refuses a real run with
a placeholder for an N whose lifetime list contains mg (`--only` runs the other systems).

## Run (main session, after merging branch h2n into the live tree)
```
P=/home/comsys/sungsu/destijl-control
bash $P/workspaces/h2n/h2n-chain-v1.sh --run 1 --dry-run          # every command + estimate (H2N_DRY_CHECK=1: + runset dry starts)
setsid nohup bash $P/workspaces/h2n/h2n-chain-v1.sh --run 1 > $P/workspaces/h2n/h2n-chain-v1-run1.log 2>&1 &
# resume after a stop: --start N:<sys>:<mix> (e.g. 4:mg:u50), N (block from its first lifetime), N:up, restore, export
```
Wall time per run (2-VM run 1 lifetimes: hw 9-12.5 min, pop 8.5-9.5 min + ~2 min cxl_shm cycle, mg SLO part ~10-15 min):
N = 2 ~2.3 h (incl. switch 0.5 h), N = 4 ~2.1 h, N = 8 ~2.2 h, restore ~0.3 h: ~7 h.
Acceptance per N: E/block/h2n-results.tsv (9 rows), block.log (BLOCK DONE, NOTE lines), rollback.out (no ROLLBACK FAIL),
then `EVAL_REGISTRY=$P/workspaces/eval-derived/h2n-runs.tsv python3 .../registry.py accept h2n-n<N> <k> <E>`.

## Outputs (DERIVED_ROOT = workspaces/eval-derived-h2n)
vdb/h2n-n<N>/run<k>[-all]/: steps.csv (aggregate steps), steps-n<N>-<mix>-<sys>.csv (latency-throughput per
lifetime), steps-vm.csv (per-VM counters), summary.csv; vdb/h2n/run<k>/summary.csv, steps.csv (all N).
summary.csv first columns: nodes, mix, system, max_under_slo_search_s (confirm x_mean, achieved searches/s over all
VMs), faults_read, faults_write (Popcorn page faults/s, summed over VMs, mean of the confirm steps at the result),
mg_fetch (megalon.read_retry_incoherent/s: stale copy flushed and the object re-read), mg_inval (megalon.flushes/s:
reader stale-copy flushes + writer write-end flushes), cxl_rd_MBs, cxl_wr_MBs; then *_per_op and raw counters.

## Known limits
- opcoh_check.py now reads N nodes (OPCOH_NODES); its closure has only been exercised on 2-node evidence; a FAIL is a
  NOTE (H2N_OPCOH_STRICT=0) until the first N > 2 block shows it passes.
- A resumed N has several evidence dirs; the registry accepts one per (run set, k): accept the completing dir, the
  chain's export step merges every dir of the N (later dir wins per lifetime).
- The CXL sampler needs kernel.perf_event_paranoid <= 0 (user set 0 at runtime; a Host reboot restores 2): the block
  records a refusal and runs without it (cxl columns empty).

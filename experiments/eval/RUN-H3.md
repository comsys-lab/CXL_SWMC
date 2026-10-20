# H3 run sets (vector DB and RecSys on N = 2 / 4 / 8 VMs) — how to run

Design: reports/design/evaluation-pipeline.md rev 3 §2.3, §6.1, with the user's H3 revision of 2026-10-20:
- 32 vCPU / 192 GB split over N VMs (N = 2: 16 / 96, N = 4: 8 / 48, N = 8: 4 / 24); threads = vCPUs per VM
  (vector DB: VCPU-1 search threads + 1 writer on every VM; RecSys: node 0 VCPU update threads, nodes 1..N-1 VCPU
  serving threads each); 2 MiB Popcorn ring (REGION); same SLO, ramp, confirm and overload rules as the 2-VM run sets.
- Per N and system ONE aggregate SLO search: the offered TOTAL read-op rate is split evenly over the serving VMs
  (vector DB: loadgen draws each search's target uniformly over the N VMs, the update stream's targets cover the N VMs
  (writes file per N); RecSys: queries round robin over nodes 1..N-1, `--opt query_spread=rr`). Result = aggregate
  max under the SLO. No constant-total-load windows.
- Fault figure: per-step Popcorn counters of every VM at the result (confirm repeats, `at_result`); latency curve per N
  from the same steps. CDF: one Popcorn lifetime at the N = 8 Popcorn max-under-SLO rate, kprobe hist, run 1 only.
- Operating points: vector DB u50 (H3_VDB_POINT); RecSys H3_RS_RATE (200, pending user); systems H3_SYSTEMS
  ("hw pop"; Megalon pending user, see "Megalon").
- N = 2 is not measured again: its points are the u50 lifetimes of run set vdb and the H3_RS_RATE lifetimes of run set
  rs-main of the same run k (same sizing, threads, SLO rules); export below.

Parameters: eval.conf section "H3" (H3_* keys: part of config_sha256 of h3-vdb / h3-recsys only, never of the 2-VM
hashes). Run set names `h3-vdb-n<N>`, `h3-rs-n<N>`; evidence `recovery/two-workload-eval-run<k>-h3-<vdb|rs>-n<N>-v<V>`
(N is in the name because N = 4 and N = 8 are measured in different topology windows; v<V> = attempt).

## Pending (lock-free window, before the first H3 run; then commit the build dirs' manifests)
```
P=/home/comsys/sungsu/destijl-control WT=<the merged live tree, or workspaces/eval-h3/wt at a committed tip>
# 1. RecSys loadgen with query_spread (plugin change of branch eval-h3; clean tree so the manifest records dirty=0)
nice -n 19 numactl --cpunodebind=1 --membind=1 bash $WT/experiments/loadgen/build.sh $P/builds/recsys-loadgen/13 \
  $WT/workloads/recsys/loadgen/recsys_plugin.cc
# 2. vector DB writes files with targets over N VMs (same seed, ids and order as builds/vdb-inputs/3; only targets differ)
mkdir -p $P/builds/vdb-inputs/4
for n in 4 8; do
  nice -n 19 numactl --cpunodebind=1 --membind=1 python3 -I $WT/workloads/vectordb/tools/gen_writes.py \
    --out $P/builds/vdb-inputs/4/writes-a27m-b3400k-u3400k-vms$n.bin --pool-a 26990000 --pool-b 3400000 \
    --writes 6800000 --mode update --vms $n --seed 20261015
done
# check: identical to the 2-VM file except the target column, targets exactly 0..n-1
nice -n 19 python3 -I -c 'import sys, numpy as np
d=np.dtype([("op","u1"),("target","u1"),("p0","<u2"),("w","<u4"),("id","<u8"),("v","<u4"),("p1","<u4")])
a=np.fromfile(sys.argv[1],d)
for n in (4,8):
    b=np.fromfile(sys.argv[2]%n,d)
    assert all((a[k]==b[k]).all() for k in ("op","w","id","v")) and sorted(set(b["target"].tolist()))==list(range(n)), n
print("WRITES CHECK PASS")' $P/builds/vdb-inputs/3/writes-a27m-b3400k-u3400k.bin $P/builds/vdb-inputs/4/writes-a27m-b3400k-u3400k-vms%d.bin
(cd $P/builds/vdb-inputs/4 && sha256sum *.bin *.manifest.txt > SHA256SUMS)
```
Then: recsys-loadgen/13 Host check = `grep -c query_spread loadgen` and the N = 4 smoke in the topology window
(below: dry start + first lifetime). The eval.conf hashes of h3-vdb / h3-recsys change once these files exist (they
are file keys): record the hash at the first H3 run, not before.

## Order (main session; one H3 chain, after the 2-VM runs of run k)
Topology chain: workspaces/vmN/vmN-chain-v2.sh (sha256 c5f65be03f0700c6ad24f0ff0cbfea6eefb99a04e4221272ff85eb88dfdcd929,
after its verifier review; v1 is superseded). Run it ONLY after the 2-VM chain (and any other eval chain or block) has
ended: v2 refuses live phases while any eval chain / *-chain-v*.sh / second vmN-chain runs (`nochain-check` phase shows
it), so the topology switches and restores are separate steps between the H3 driver chains, never inside one. Live
phases other than `pre` / `r-down` need the chain's own `PRE PASS (topo N)` (switch) or `R-DOWN PASS (topo N` (restore)
line in VMN_E/steps.log: `pre` and `r-down` create a NEW evidence dir, every later phase uses the same VMN_E.
| Step | What | Command / note | Time (estimate) |
| --- | --- | --- | --- |
| 0 | N = 2 export (2-VM run k accepted) | see "N = 2" | Host only |
| 1 | switch 2 -> 4 VMs | `VMN_TOPO=4 VMN_LIVE=1 VMN_E=$P/recovery/VM8-v3-n4 bash $P/workspaces/vmN/vmN-chain-v2.sh <phase>`: `nochain-check`, `dry` (2-VM state, mandatory), then `pre` (creates VMN_E, PRE PASS (topo 4)) `gen down freeze overlays net define`, `start 0 1 2 3`, `pretouch-par 0 1 2 3`, `envcheck` | ~30 min |
| 2 | gates and dry start | `export PRETOUCH_DIR=$P/recovery/VM8-v3-n4 MEASURE_ENV_DIR=<base> MEASURE_PART_DIR=<apply>`; `bash $C/experiments/eval/runset-h3-vdb.sh 4 <k> --dry`, `runset-h3-rs.sh 4 <k> --dry` -> `DRY START OK` | 1 min |
| 3 | vector DB N = 4 | `bash $C/experiments/eval/runset-h3-vdb.sh 4 <k>` (hw + pop HSLO) | ~45 min |
| 4 | RecSys N = 4 | `bash $C/experiments/eval/runset-h3-rs.sh 4 <k>` | ~50 min |
| 5 | restore to 2 VMs | after the H3 driver chain has ended: `VMN_TOPO=4 VMN_LIVE=1 VMN_SRC=$P/recovery/VM8-v3-n4 VMN_E=$P/recovery/VM8-v3-n4-restore bash $P/workspaces/vmN/vmN-chain-v2.sh <phase>`: `nochain-check`, `dry-restore`, then `r-down` (creates VMN_E, R-DOWN PASS (topo 4)) `r-undefine r-net r-unfreeze r-define r-start`, `pretouch-par 0 1`, `envcheck`, `r-delete` | ~15 min |
| 6 | switch 2 -> 8 VMs | as 1 with `VMN_TOPO=8 VMN_E=$P/recovery/VM8-v3-n8`, `start 0 1 2 3 4 5 6 7`, `pretouch-par 0 1 2 3 4 5 6 7` | ~30 min |
| 7 | vector DB N = 8 | `runset-h3-vdb.sh 8 <k>` (run 1: + CDF lifetime at the Popcorn max rate) | ~45 min (+10 min CDF) |
| 8 | RecSys N = 8 | `runset-h3-rs.sh 8 <k>` (run 1: + CDF) | ~50 min (+10 min CDF) |
| 9 | restore to 2 VMs | as 5 with `VMN_TOPO=8` and the n8 dirs; then the 2-VM pretouch is the new PRETOUCH_DIR | ~15 min |
Each driver is launched as the 2-VM drivers are: from the clean live tree, `setsid nohup bash ... > <log> 2>&1 &`,
inside a workspaces/*-chain-*.sh wrapper that contains no topology phase (steps 3-4 and 7-8 each one such chain).
Guests 2..N-1 are overlays of vm0's frozen disk: the installs
(/home/comsys/vdb17r2m, /home/comsys/rs13r2m, /home/comsys/popcorn-12n, /home/comsys/vdb/init/seg32c32m-a27m on vm0)
must exist on vm0 before the freeze; the block's precheck compares every VM's install sha256 with the Host builds and
stops otherwise ("install needed").

## N = 2 (export only)
```
C=$P/CXL_SWMC
S=$(python3 $C/experiments/eval/evalconf.py sha h3-vdb)
python3 $C/experiments/eval/export_h3.py --run <k> --runset h3-vdb-n2 --config-sha256 $S --source 2vm --point u50 \
  --round <1 in run 1; k in cont runs> --out $P/workspaces/eval-derived/vdb/h3-vdb-n2/run<k> <accepted vdb run k dir>
S=$(python3 $C/experiments/eval/evalconf.py sha h3-recsys)
python3 $C/experiments/eval/export_h3.py --run <k> --runset h3-rs-n2 --config-sha256 $S --source 2vm --point 200 \
  --out $P/workspaces/eval-derived/recsys/h3-rs-n2/run<k> <accepted rs-main run k dir>
```

## Outputs (DERIVED_ROOT/<vdb|recsys>/h3-<vdb|rs>-n<N>/run<k>/)
- hslo.csv: one row per (system, nodes, measured SLO step, vm); vm = all: latency (p50/p95/p99/pslo) + aggregate
  counters; vm = 0..N-1: that VM's counters. at_result = confirm repeat at the result rate.
- hosts-at-max.csv: per (system, nodes, vm) the mean over the at_result steps (faults by kind per s and per read op,
  per-thread fault time thr_*_fault_ns_per_s, coherence IPIs, cxl_recv CPU s/s) + result_x.
- cdf.csv: per-page I->S read-fault CDF of the CDF lifetime (complete = Dropped 0).

## Stop and rollback
As the 2-VM drivers: `kill -TERM -- -<pgid>`; h3-block.sh's EXIT trap stops this block's servers on every VM, removes
the kprobe event, tears down every cxl_shm load without "teardown PASS", sets /dev/dax0.0 root:root 600 on every VM
and releases the lock. Check `E/block/rollback.out` (ROLLBACK FAIL lines) and `E/block/cleanup.out`.

## Megalon (H3_SYSTEMS, pending user)
Megalon is compiled for two nodes: builds/megalon/77 manifest `constants_rs_LOGICAL_NODE_NUM=2`,
`constants_h_LOGICAL_NODE_NUM=2` (systems/megalon/src: src/common/constants.h `#define LOGICAL_NODE_NUM 2`,
third-party/nr_rust/ffi/constants.rs; config.cc refuses node_id >= LOGICAL_NODE_NUM; NR log tails and the start
barrier are sized by it). The vector DB and RecSys Megalon backends themselves take --nodes N. Megalon in H3 needs:
per N a Megalon build with LOGICAL_NODE_NUM = N (C and Rust constants), vdb-megalon / recsys-megalon builds on it,
the HWcc budget check (SCR + NR logs at N nodes inside 256 MiB with the 2 MiB ring), Megalon configs per N, the
Megalon port tests, a smoke per N, and a run-set extension (mg + mgoff lifetimes). The drivers refuse mg until then.

## Known limits
- vector DB opcoh_check.py reads node0/node1 only: not run at N > 2 (the per-node opcoh error counters, the response
  coherence blocks and opsplit.py are checked); RecSys check_breakdown.py reads node 1 only (a FAIL is a NOTE here).
- CDF hist map: 2^17 pages per VM; Dropped > 0 makes the CDF incomplete (cdf.csv complete = False). The hist covers the
  CDF part's whole run (10 s ramp-in + CDF_S + drain; vector DB also the server stop).
- RecSys at N VMs keeps node 0 as updater only: serving vCPUs 16 / 24 / 28 at N = 2 / 4 / 8 (the plot states it).
- Private memory of vdb-server / recsys-server at 48 / 24 GB guests not measured before (first lifetime = smoke).

# Evaluation run sets, 2-VM part (H1 + H2 on the vector DB and RecSys) — how to run

Experiment: reports/experiments/two-workload-evaluation-2vm.md. Design: reports/design/evaluation-pipeline.md rev 3.
Parameters: `eval.conf` only (`evalconf.py shell` shows the resolved values and both config_sha256). Run k of a run set
= one driver call. Main session only (VM, sudo, lock); drivers never ask anything.

## Before run 1 (once per QEMU lifetime / per build set)
1. Merge branch eval-run1 into live CXL_SWMC (real runs refuse any other tree and a dirty tree); verifier review first.
2. Guest installs with the 2 MiB-ring region (standing grant A1; new dirs, nothing overwritten):
   ```
   C=/home/comsys/sungsu/destijl-control/CXL_SWMC P=/home/comsys/sungsu/destijl-control R=$C/config/cxl_region-ring2m.yaml
   REGION=$R VPLAIN=/home/comsys/vdb17r2m PLAIN_BUILD=$P/builds/vdb/17 bash $C/experiments/vectordb/m4-install.sh <log> plain
   REGION=$R VMEG=/home/comsys/vdbm14r2m MEG_BUILD=$P/builds/vdb-megalon/14 MEG_CFG=$C/systems/megalon/vectordb-2vm.yaml \
     bash $C/experiments/vectordb/m4-install.sh <log> megalon
   REGION=$R PLAIN_DIR=/home/comsys/rs13r2m PLAIN_BUILD=$P/builds/recsys/13 VM_MEG=/home/comsys/rsm14r2m \
     MEG_BUILD=$P/builds/recsys-megalon/14 MEGALON_BASE=$P/builds/megalon/77 MEG_CFG=$C/systems/megalon/recsys-2vm.yaml \
     bash $C/experiments/recsys/install.sh <log>
   ```
   and check that /home/comsys/popcorn-12n (2 MiB-ring guest tools of workspaces/popcorn-n/bundle-n-v2) exists on both
   guests with its tools.sha256 (`p-popcorn-shm.sh precheck` of that bundle).
3. Pretouch after the last QEMU start; Host measurement dirs: export `PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR`.
4. Dry start (Host only, stops before the lock; also runs each block on a scratch dir up to its evidence-dir check):
   `bash $C/experiments/eval/runset-{vdb,rs-main,rs-h1}.sh <k> --dry` -> last line `DRY START OK`.

## Runs (one at a time; each driver logs to E/eval-state.txt and runs.tsv)
| Run set | Command (from live CXL_SWMC, inside a `workspaces/*-chain-*.sh` wrapper with `setsid nohup`) | Lifetimes | Time (estimate) |
| --- | --- | --- | --- |
| vdb run 1 | `bash experiments/eval/runset-vdb.sh 1` | 21: per mix hw/pop SLO-only, mg SLO+fix, mgoff fix, hw/pop fix | ~3.3 h (H1 r1: 3 h 16 min) |
| vdb runs 2, 3 | `bash experiments/eval/runset-vdb.sh 2` (then 3); needs run 1 accepted | 12: hw/pop/mg SLO+fix, mgoff fix | ~2.2 h each (inference) |
| rs-main run k | `bash experiments/eval/runset-rs-main.sh <k>` | per rate (50 100 200 400): hw, pop SLO; then hw, pop fix-only lifetimes (L1, L2, [1 q/s at 50 / 200], fallback 1 q/s) | ~4 h run 1 (3.0 h SLO + ~1 h fix-only lifetimes, inference) |
| rs-h1 run k | `bash experiments/eval/runset-rs-h1.sh <k>`; run 1 after rs-main run 1 | run 1: Megalon probe 1 q/s at 50, 200; SLO(mg) only where the probe p95 <= 100 ms and valid; mg/mgoff fix-only | ~0.6 h without SLO(mg) (inference) |
Evidence: `recovery/two-workload-eval-run<k>-<vdb|rs-main|rs-h1>-v<N>` (new N per attempt, never reused).
Canonical CSVs: `workspaces/eval-derived/<vdb|recsys>/<runset>/run<k>/` (written by the driver; rerun by hand:
`python3 experiments/{vectordb,recsys}/export.py --run k --runset R --config-sha256 S --out DIR E`).
Merged spread: `python3 experiments/eval/merge.py --root workspaces/eval-derived --workload vdb --runset vdb --out DIR`.

## Acceptance and later runs
- vdb: review `E/vdb/r<n>/check.txt` (H1 check.py: H1CHECK PASS; REPORT lines from run 2 on go to the user).
- RecSys: review `E/block/rs-check.txt` (rs-main) / `E/{probe,slo,fix}/rs-check.txt` + `E/mg-decision.tsv` (rs-h1).
- Then `python3 experiments/eval/registry.py accept <runset> <k> <E>`. Runs >= 2 take levels (vdb, rs-main) and Megalon
  decisions (rs-h1) from the accepted run LEVELS_FROM_RUN (cut Q8); an unusable run: `registry.py invalid ... "<reason>"`.

## Stop and rollback
- Stop: `kill -TERM -- -<pgid>` of the driver (setsid). Every block rolls back in its EXIT trap (servers stopped,
  cxl_shm teardown, dax0.0 root:root 600) and the lock is released (vdb: the driver's trap; RecSys: the block's).
- After a stop: check `rollback.out` (ROLLBACK FAIL lines), `cat workspaces/MEASUREMENT.lock` (must be absent),
  `registry.py list` (status stopped); rerun = the same command (new v<N>). Never reuse or edit an evidence dir.
- A block STOP is a harness or system fault: no automatic retry; RecSys fixed windows that are not valid are recorded
  (valid=0), not stops.

## Vector DB LEVELS stop (verifier L9)
The vector DB has no fallback window: in run 1 a mix where a system's SLO search ends without a confirmed max (loadgen
note) makes levels-cb.sh fail inside the Megalon lifetime ("LEVELS STOP"): the block stops, rolls back, the run set is
"stopped" in the registry, and the remaining mixes are not measured. Main then: report the mix and system to the user
(no automatic retry; Q4 rule), keep the evidence dir, and rerun only after the user's decision (same command, new
v<N>; or a changed VDB_POINTS = a new config_sha256).

## Known limits (see PROGRESS / report)
- Megalon vector DB uses the 28M capacity (VDB_MG_CAPACITY=h1): the 28m-x capacity (89 groups/segment, ~95.6 GiB of
  objects, inference) exceeds Megalon's object_arena_size 90GB. Pending user confirmation.
- RS_LOW_RAMP_FACTOR (cut Q8: factor 3 below 10 q/s) needs a loadgen option + build; the drivers refuse it until then.
- vdb cont mode supports runs 2-3 (H1 hook); RUNS > 3 needs VDB_LATER_RUNS=r1.

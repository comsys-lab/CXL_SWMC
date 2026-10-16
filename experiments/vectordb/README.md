# vectordb experiments: how to run and where the results are

## One run
`experiments/vectordb/run.sh <name> <out_root> -- <loadgen args>` (env: SYSTEM, V, HOST_SERVER, LOADGEN, SERVER_ARGS,
INIT; see the header of run.sh). It starts one vdb-server per VM, drives them from the Host with
`experiments/loadgen` (vectordb plugin), stops the servers and collects everything into `<out_root>/<name>/`.
VM runs go through an approved packet (reports/M3-vdb-packet.md); `<out_root>` is then the packet's evidence dir
`recovery/<id>-vN/` and the run dirs are `r1/`, `r2/`, ...
Streams (vectordb plugin): `search` and `update` (one request = delete a live record + insert the next pool B
record on one node; writes file from `tools/gen_writes.py --mode update`). Mix 95:5 = `--mix update=1,search=19`.
By default run.sh passes `--stats-op 10` to loadgen (server stats snapshot per node at the start and end of every
measured step; `STATS_OP=0` turns it off). `TRACE=1` (default 0; MOT1 v4 H2 step 2: fixed-load runs only) adds
`--trace-dir <guest run dir>` to vdb-server (Megalon false-sharing logs; HWcc trace lines are touched only then;
nothing for plain). Both are recorded in the manifest (`trace= stats_op=`).

## Result layout (immutable; run.sh refuses to overwrite)
```
recovery/M3-vdb-runs-vN/                 packet evidence dir (one approved attempt)
├── precheck-<ip>.out, chown-<ip>.out    guest pre-check and device ownership change
├── port-check.txt                       guest listen state + Host TCP connect after READY
├── sequence.sh, precheck.sh, sequence.log   the exact scripts used and their log
├── rollback.out                         rollback evidence (no server left, root:root 600)
├── r2-gt.recall.txt, r2-gt.*            offline recall / E1 check of a run (compute_gt.py, after the sequence)
└── r<k>/                                one run (run.sh result dir)
    ├── steps.csv        <- spreadsheet: one row per (step, stream); columns label, step, phase, pass, stream,
    │                       offered, achieved, p50/p90/p99/p999/max (ms), errors, timeouts, max_under_slo, then
    │                       step-level search_per_s, update_per_s, total_ops_per_s, search/update p50/p99,
    │                       traffic_bytes, traffic_per_update, and per node n<k>_* (busy, CPU, coherence stall,
    │                       background CPU, IPIs, traffic; list in experiments/loadgen/export_csv.py)
    ├── stats-steps.csv  per (step, node): end - begin of every server counter (stats_delta.py)
    ├── slo.png, slo-points.txt   throughput (x) vs tail latency (y) plot and its points
    ├── manifest.txt     system, run_id, guest run dir, commits, binary/region/dataset sha256, kernels, VM XML sha256,
    │                    server and loadgen arguments, app HWcc bytes, start/end, loadgen rc
    ├── host-check.txt   Host build check before/after (a build during a measurement invalidates it)
    ├── guest-cpu.txt    guest /proc/stat cpu line before/after the load (CPU busy fraction)
    ├── loadgen.log      step-by-step console output
    ├── node<k>.{log,env,pid}   server log (incl. final stats: updates, inserts, deletes, searches, timeouts,
    │                           bad_records, lock/search times, proc/sysfs counters) and start environment per VM
    ├── node<k>.megalon-{wsec,retry,refetch}.bin   Megalon only (TRACE=1): write-section, failed-read and
    │                           refetch logs for tools/classify_retries.py (false / true sharing)
    └── loadgen/
        ├── steps.jsonl, summary.json   per-step statistics and the SLO-search result (max_offered_x_pass, confirm)
        ├── manifest.txt               loadgen parameters
        ├── searches.bin, vectordb.txt  every search response (query row, E1 snapshot, ids, server time split)
        ├── search-coh.bin             vdb build >= 9: per-query coherence block of every OK search response
        │                              (DESIGN.md §14); qcoh.py -> <run>/qcoh-steps.csv (m4-run.sh QCOH_EXPECT)
        ├── stats/step<NNN>-{begin,end}-t<k>.txt   server stats snapshots per measured step (--stats-op)
        └── raw-step<N>.bin             per-request sched/send/done ns (--raw)
```
SLO-search phases in steps.csv: `ramp` (adaptive: x2.25 far below the SLO, x1.5, x1.2, x1.1 near the SLO or where
the tail latency jumped), `bisect` (knee), `confirm` (3 repeats at the result; "confirm fails k/3" = k repeats had the
SLO percentile above the SLO; a majority of fails steps the rate down 5% and confirms again), `fill` (result x
0.7/0.8/0.9: the bend), `overload` (first-fail rate x 1.05/1.1/1.2, measured in full: the curve past the knee).
From loadgen build 3 (CXL_SWMC commit with "adaptive ramp"); earlier runs have no fill points.
For a throughput/p99 chart: filter `stream = search`, x = `achieved` (= `search_per_s`), y = `p99_ms`, colour by
`pass`. Per-step server-side values (n<k>_*) are window deltas between the two snapshots of that step; they are the
same on every stream row of the step.

## Combining runs (e.g. systems) for a spreadsheet or a plot
```
python3 experiments/loadgen/export_csv.py --out all.csv runA/loadgen=all-HWcc runB/loadgen=Megalon runC/loadgen=Popcorn
python3 experiments/loadgen/plot_slo.py --out all.png runA/loadgen=all-HWcc runB/loadgen=Megalon runC/loadgen=Popcorn
```
False-sharing classification of a Megalon run (offline), optionally limited to one step's window:
`python3 workloads/vectordb/tools/classify_retries.py --trace r<k> --out r<k>-fs [--stats r<k>/loadgen --step N]`
Recall / E1 check of a run (offline, never during a measurement):
`python3 workloads/vectordb/tools/compute_gt.py --data <dataset dir> --writes <writes.bin> --searches r<k>/loadgen/searches.bin --out r<k>-gt`
Per-operation time split (vdb build >= 10; MOT1 v6 Fig 2/3b; workloads/vectordb/DESIGN.md §15; run.sh runs it when
loadgen/op-coh.bin exists): `python3 experiments/vectordb/opsplit.py r<k>` -> `r<k>/opsplit-steps.csv` and
`r<k>/opsplit-steps.columns.csv` (tag per column: measured / sampled×N / derived). Mixes: m4-run.sh U = 5 / 50 / 90
(search/update 95/5, 50/50, 10/90; H2 shares U = 0/5/10/20/50); SLO search p99 <= 100 ms. m4-run.sh OPCOH_EXPECT checks
the blocks (builds >= 10; QCOH_EXPECT only for builds <= 9). Sharing trace (Fig 3c, TRACE=1, dedicated runs only):
node<k>.vdbtrace.bin, classified by `workloads/vectordb/tools/classify_sharing.py r<k>` -> sharing.csv (run.sh does it).
Coherence time per search query (vdb build 9 only; search threads only, writer per update separately; offline):
`python3 experiments/vectordb/qcoh.py r<k> [--queries r<k>/qcoh-queries.csv]` -> `r<k>/qcoh-steps.csv`.
H1 main block (reports/M4-vdb-packet.md v2.0): `experiments/vectordb/h1-block.sh <evidence dir>`.

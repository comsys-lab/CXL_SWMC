# vectordb experiments: how to run and where the results are

## One run
`experiments/vectordb/run.sh <name> <out_root> -- <loadgen args>` (env: SYSTEM, V, HOST_SERVER, LOADGEN, SERVER_ARGS,
INIT; see the header of run.sh). It starts one vdb-server per VM, drives them from the Host with
`experiments/loadgen` (vectordb plugin), stops the servers and collects everything into `<out_root>/<name>/`.
VM runs go through an approved packet (reports/M3-vdb-packet.md); `<out_root>` is then the packet's evidence dir
`recovery/<id>-vN/` and the run dirs are `r1/`, `r2/`, ...

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
    │                       offered, achieved, p50/p90/p99/p999/max (ms), errors, timeouts, max_under_slo, ...
    ├── slo.png, slo-points.txt   throughput (x) vs tail latency (y) plot and its points
    ├── manifest.txt     system, run_id, guest run dir, commits, binary/region/dataset sha256, kernels, VM XML sha256,
    │                    server and loadgen arguments, app HWcc bytes, start/end, loadgen rc
    ├── host-check.txt   Host build check before/after (a build during a measurement invalidates it)
    ├── guest-cpu.txt    guest /proc/stat cpu line before/after the load (CPU busy fraction)
    ├── loadgen.log      step-by-step console output
    ├── node<k>.{log,env,pid}   server log (incl. final stats: inserts, deletes, searches, timeouts, bad_records,
    │                           lock/search times) and start environment per VM
    └── loadgen/
        ├── steps.jsonl, summary.json   per-step statistics and the SLO-search result (max_offered_x_pass, confirm)
        ├── manifest.txt               loadgen parameters
        ├── searches.bin, vectordb.txt  every search response (query row, E1 snapshot, ids, server time split)
        └── raw-step<N>.bin             per-request sched/send/done ns (--raw)
```
SLO-search phases in steps.csv: `ramp` (adaptive: x2.25 far below the SLO, x1.5, x1.2, x1.1 near the SLO or where
the tail latency jumped), `bisect` (knee), `confirm` (3 repeats at the result; "confirm fails k/3" = k repeats had the
SLO percentile above the SLO; a majority of fails steps the rate down 5% and confirms again), `fill` (result x
0.7/0.8/0.9: the bend), `overload` (first-fail rate x 1.05/1.1/1.2, measured in full: the curve past the knee).
From loadgen build 3 (CXL_SWMC commit with "adaptive ramp"); earlier runs have no fill points.
For a throughput/p99 chart: filter `stream = search`, x = `achieved`, y = `p99_ms`, colour by `pass`.

## Combining runs (e.g. systems) for a spreadsheet or a plot
```
python3 experiments/loadgen/export_csv.py --out all.csv runA/loadgen=all-HWcc runB/loadgen=Megalon runC/loadgen=Popcorn
python3 experiments/loadgen/plot_slo.py --out all.png runA/loadgen=all-HWcc runB/loadgen=Megalon runC/loadgen=Popcorn
```
Recall / E1 check of a run (offline, never during a measurement):
`python3 workloads/vectordb/tools/compute_gt.py --data <dataset dir> --writes <writes.bin> --searches r<k>/loadgen/searches.bin --out r<k>-gt`

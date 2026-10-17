# experiments/h1 — H1 main orchestration (MOT1 v6 Fig 1 / Fig 2)

Packet: reports/H1-main-packet.md (v0 draft). Design: reports/MOT1-v6-redesign-draft.md §1-§3 as decided.
Orchestration only. Every VM action (install check, cxl_shm cycle, dax0.0 chown/rollback, servers, loadgen) stays in
the workload's own block, reached through its H1 hook. One block runs at a time, so there is one VM writer.

## Files
| File | Role |
| --- | --- |
| h1-plan.tsv | workload x mix rows: mix parameter, x -> rate factor, rate decimals, SLO, label (MOT1 v6 §1 mixes and SLOs) |
| h1-main.sh | sequencer: lock `H1-main`; per workload: gates, SLO phase (rounds), levels.py, fixed phase (reps), gates, collect.py |
| hook.sh | runs one phase of one workload through `plugins/pins-<W>.sh`. It refuses FILL_ tokens, a missing hook marker and pin hash mismatches. Afterwards it checks `SEQUENCE DONE` and `h1-runs.tsv` (one run per mix x system) |
| levels.py | L1 = the weakest system's confirm x_mean per mix, L2 = 0.5 x L1. It refuses noted or SLO-mismatched runs. Writes levels.tsv |
| collect.py | writes runs-index.csv, steps-all.csv (export_csv.py), slo-summary.csv, fix-steps.csv (L1/L2 windows + coherence CPU), fig/ (v6_fig1_curves.py, v6_fig2_split.py) and notes.txt |
| plugins/pins-*.sh | per-workload pins: block command + environment, hook file, sha256 pins. FILL_ tokens are filled after that workload's validation packet passes |
| test/stub-block.sh, test/selftest.sh | Host self-test (no VM): a stub block with the hook contract, plus 5 cases |

## Evidence layout (one immutable root per H1 main attempt, recovery/H1-main-vN/)
```
<E>/h1-manifest.txt h1-state.txt gate-*.txt pretouch-gate.txt sequence.log
<E>/<W>/slo-r<r>/   block evidence dir of SLO round r: sequence.{cmd,log}, h1-runs.tsv, order.txt, run dirs <sys>-<mix>-slo-r<r>/
<E>/<W>/levels.tsv levels.log
<E>/<W>/fix-r<k>/   block evidence dir of fixed rep k: run dirs <sys>-<mix>-fix-r<k>/ (one lifetime, windows L2 then L1)
<E>/<W>/collect/    runs-index.csv steps-all.csv slo-summary.csv fix-steps.csv fig/ notes.txt
```

## Hook contract H1-HOOK v1 (what each workload block must add; owner = that workload's agent)
The block file carries the literal marker `H1-HOOK v1`. It is called by hook.sh as
`env <BLOCK_ENV> H1MODE=slo|fix H1_N=<round|rep> H1_SEED=<n> H1_PARENT_LOCK=H1-main PRETOUCH_DIR=.. MEASURE_ENV_DIR=..`
`[H1_MIXES="<mix>=<param> ..."] [H1_LEVELS=<levels.tsv>] <BLOCK_CMD> <dir>`. It must:
1. Lock: with H1_PARENT_LOCK set, check that the lock file names `owner=H1-main`. It must not lock or unlock itself.
   All other rollback steps stay in its EXIT trap: this block's servers, cxl_shm teardown, dax0.0 root:root 600 with
   a fresh stat check.
2. Gates: run the pretouch check at block start and end (experiments/vectordb/pretouch-gate.sh or
   experiments/kv/pretouch-check.sh, unchanged). Run the Host gate before every run, with the measure-env check
   against MEASURE_ENV_DIR. Run the precheck: kernel = Popcorn build 12, dax0.0 uuid, and installed guest files =
   pinned builds.
3. `H1MODE=slo`: for every mix in H1_MIXES and every system hw, pop, mg, run one full SLO search. Use the workload's
   MOT1 §3.3 profile with ramp, bisect, confirm 3 x, fill 0.7/0.8/0.9 and overload 1.05/1.1/1.2 past the first
   failure. Run name `<sys>-<mix>-slo-r<N>`; loadgen seed H1_SEED, the same for every system of the round.
   - Order: systems shuffled with seed `H1-<W>-r<N>` (rotated Latin square when N > 1); mixes shuffled per system
     with the same seed. Write order.txt before the first run.
   - Per-run checks = the validation packet's checks for that system (OPCOH_EXPECT / opcoh_check, v1-check.py,
     check_breakdown.py, clean stop, bad records 0, dmesg rule), without timer-off or trace runs.
   - A "confirm failed at three rates" outcome is recorded as a NOTE and the block continues; levels.py then stops
     the sequence.
4. `H1MODE=fix`: for every row of H1_LEVELS and every system, use one server lifetime with the workload's normal
   start (initial image, prepare, Popcorn preload). It holds two fixed-load windows: first at L2_rate, then at
   L1_rate (the rate argument of the block). Each window is the workload's existing fixed-window kind, with no SLO
   abort. Run name `<sys>-<mix>-fix-r<N>`, seed H1_SEED, the same checks as in item 3.
5. Write `<dir>/h1-runs.tsv`, one line per run: `name<TAB>system(hw|pop|mg)<TAB>mix<TAB>phase(slo|fix)<TAB>N<TAB>run_dir`.
   run_dir is relative to <dir> or absolute and holds loadgen/{summary.json,steps.jsonl}, the run manifest and the
   workload's split output (vector DB opsplit-steps.csv, KV/LMDB opsplit.csv, DLRM breakdown.csv). The last line of
   stdout is `SEQUENCE DONE ...`.
6. Systems: all-HWcc = the workload's all-HWcc build. For KV this is kv on Megalon 77-hwcc; vector DB, LMDB and
   DLRM use the plain backend (MOT1 v6 §3.1). Popcorn = the plain build with cxl_shm of build 12 (init_state=shared,
   recv_mode poll, instr_enabled=1). Megalon = the build on Megalon 77, timers on with the library default sampling.
   All runs use kernel build 12; cxl_shm is unloaded for all-HWcc and Megalon.

## Self-test
`bash experiments/h1/test/selftest.sh /home/comsys/sungsu/destijl-control/workspaces/h1-main/selftest-<n>` must print
`SELFTEST PASS`. Case E reads recovery/KV-main-h1-v2 read-only.

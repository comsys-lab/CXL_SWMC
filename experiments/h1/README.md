# experiments/h1 — H1 main orchestration (MOT1 v6 Fig 1 / Fig 2)

Packet: reports/H1-main-packet.md (v0 draft). Design: reports/MOT1-v6-redesign-draft.md §1-§3 as decided.
Orchestration only. Every VM action (install check, cxl_shm cycle, dax0.0 chown/rollback, servers, loadgen) stays in
the workload's own block, reached through its H1 hook. One block runs at a time, so there is one VM writer.

## Files
| File | Role |
| --- | --- |
| h1-plan.tsv | workload x mix rows: mix parameter, x -> rate factor, rate decimals, SLO, label (MOT1 v6 §1 mixes and SLOs) |
| levels-cb.sh | r1 callback inside the mg lifetime: levels.py --mix for that mix (appended to levels.tsv), prints `<L2_rate> <L1_rate>` |
| h1-main.sh | one stage per call (`r1-kv`, `r1-lmdb`, `r1-vdb`, `r1-recsys`, `r2`, `r3`; user decision 2026-10-17; `r2`/`r3` take `--workloads w1,w2` for a user-chosen subset, plan change 2026-10-18). Every stage ends with `<W>/collect-all-r<n>` (rounds 1..n). Takes the lock `H1-main`. Per workload: gates, SLO phase, levels.py (r1 only), fixed phase, gates, collect.py, check.py. Refuses a stage until the previous stage is checked PASS and accepted |
| check.py | per workload x round acceptance checks F1-F9 (FAIL) and W1-W6 (WARN, judged by the main session) -> `r<n>/check.txt` |
| h1-accept.sh | main session records its acceptance of a checked stage (`accept/r<n>-<W>.txt` with the check.txt sha256) |
| hook.sh | runs one round of one workload (H1MODE r1 or cont) through `plugins/pins-<W>.sh`. It refuses FILL_ tokens, a missing hook marker and pin hash mismatches. Afterwards it checks `SEQUENCE DONE` and `h1-runs.tsv` (one run per mix x system) |
| levels.py | L1 = the weakest system's confirm x_mean per mix, L2 = 0.5 x L1. It refuses noted or SLO-mismatched runs. Writes levels.tsv |
| collect.py | writes cdiff.csv (an extraction of the analysis Fig 2 CSV, v6_fig2_split.py --megalon-c diff, CXL_SWMC 5b650ab4f: C_diff_ns of the "Megalon (timers off)" rows, C_sampled_ns, T_mg_on_ns, Popcorn pop_T_minus_hw_ns), runs-index.csv, steps-all.csv (export_csv.py), slo-summary.csv, fix-steps.csv (L1/L2 windows + coherence CPU), fig/ (v6_fig1_curves.py, v6_fig2_split.py) and notes.txt |
| plugins/pins-*.sh | per-workload pins: block command + environment, hook file, sha256 pins. FILL_ tokens are filled after that workload's validation packet passes |
| test/stub-block.sh, test/selftest.sh | Host self-test (no VM): a stub block with the hook contract, plus 5 cases |

## Evidence layout (one immutable root per H1 main attempt, recovery/H1-main-vN/)
```
<E>/h1-manifest.txt (one block per stage) h1-state.txt gate-*.txt pretouch-gate.txt sequence-<stage>.log
<E>/accept/r<n>-<W>.txt   main-session acceptance records (user_ack= when check.txt had REPORT lines)
<E>/<W>/levels.tsv levels-<mix>.log   written by levels-cb.sh inside each r1 mg lifetime, reused by rounds 2 and 3
<E>/<W>/r<n>/run/   the block's evidence dir of round n: sequence.{cmd,log}, h1-runs.tsv (v2), order.txt and one dir per
                    server lifetime <lifetime>/ (manifest.txt, h1-runcheck.txt, node logs) with one part per loadgen
                    invocation: <lifetime>/slo/ and/or <lifetime>/fix/ (loadgen/, steps.csv, the workload split file)
<E>/<W>/r<n>/collect/  runs-index.csv steps-all.csv slo-summary.csv fix-steps.csv cdiff.csv fig/ notes.txt; r<n>/check.txt
<E>/<W>/collect-all-r<n>/  after each stage: rounds 1..n of W (slo-summary.csv rounds_note: single round, or mean / sd;
                       fig/<W>-<mix>-r<k>-* per round, with <tag>-windows.txt naming each window's lifetime)
```

## Hook contract H1-HOOK v2 (user decision 2026-10-18 "H1 lifetime 구성 변경"; owner = each workload's agent)
The block file carries the literal marker `H1-HOOK v2` (hook.sh refuses v1). It is called once per workload and round:
`env <BLOCK_ENV> H1MODE=r1|cont H1_N=<n> H1_SEED=<n> H1_MIXES="<mix>=<param> ..." H1_SETTLE_S=<s> H1_PARENT_LOCK=H1-main`
`PRETOUCH_DIR=.. MEASURE_ENV_DIR=.. [r1: H1_LEVELS_CMD H1_PLAN H1_W H1_LEVELS_OUT H1_STAGE_DIR] [cont: H1_LEVELS] <BLOCK_CMD> <dir>`.
1. Lock and gates as v1: with H1_PARENT_LOCK check `owner=H1-main` and never lock/unlock; pretouch check at block start
   and end; Host gate before every lifetime; precheck (kernel build 12, dax0.0 uuid, installed files = pinned builds);
   rollback in the EXIT trap (servers, cxl_shm teardown, dax0.0 root:root 600).
2. One server lifetime may hold several loadgen invocations ("parts"), each with its own `<lifetime>/<part>/loadgen/`
   (stats snapshots per step) and steps.csv: `slo` = the full SLO search (ramp, bisect, confirm 3 x, fill, overload past
   the first failure; no fixed steps), `fix` = settle + L2 window + L1 window. **Settle** = H1_SETTLE_S seconds at the
   L2 rate, discarded: loadgen `--warmup-s H1_SETTLE_S` with `--rates <L2>,<L1>` (the warm-up runs at the first rate)
   or a separate unmeasured step; the L2 and L1 windows keep the workload's window length (dec Q5).
3. `H1MODE=r1` (round 1, levels unknown), per mix in a seeded mix order:
   a. hw and pop SLO-only lifetimes (part `slo`), order between them seeded `H1-<W>-r1-<mix>`;
   b. mg lifetime: part `slo`; append its slo line to h1-runs.tsv; run `"$H1_LEVELS_CMD" <mix>` (prints `<L2_rate>
      <L1_rate>`; non-zero = LEVELS STOP: stop the block, no fixed windows, roll back); then part `fix` at those rates
      in the same lifetime;
   c. mgoff lifetime right after mg (MEGALON_COH_TIMERS=0 on both nodes; Megalon 77, no runtime switch, user decision
      2026-10-18): part `fix` only (READY -> settle -> L2 -> L1, no SLO search);
   d. hw and pop separate fixed lifetimes (part `fix` only), order seeded `H1-<W>-r1-<mix>-fix`.
4. `H1MODE=cont` (rounds 2, 3; rates from H1_LEVELS columns L2_rate / L1_rate of the mix), per mix: hw, pop, mg in a
   rotated Latin-square order (seed `H1-<W>-latin`, rotated by n), each one lifetime with parts `slo` then `fix`; the
   mgoff lifetime (part `fix` only) right after the mg lifetime.
5. Per-run checks = the validation packet's checks for that system (opcoh_check / v1-check.py / v1_check +
   check_breakdown; mgoff in the timers-off mode), written to `<lifetime>/h1-runcheck.txt` (last line
   `RUNCHECK PASS[ (NOTE: ...)]`; a failed check stops the block). A loadgen "confirm failed at three rates" note in an
   SLO part is a NOTE (the block continues; levels-cb.sh or check.py F2 then stops the workload, dec Q4).
6. `<dir>/h1-runs.tsv`, 8 columns: `name system mix phase round run_dir steps lifetime` — run_dir = the part dir
   (relative to <dir>); steps = `-` for slo, `<L2 step>,<L1 step>` (measured fixed steps of that part) for fix;
   lifetime = `sep` (r1 hw/pop SLO-only and fixed lifetimes, every mgoff lifetime) or `cont` (mg in every round; all
   systems in r2/r3). Lines are appended as parts finish (the r1 callback reads them). Last stdout line `SEQUENCE DONE`.
7. Systems as v1: all-HWcc = the workload's all-HWcc build (KV: kv on Megalon 77-hwcc; others plain), Popcorn =
   plain + cxl_shm build 12 (init_state=shared, recv_mode poll, instr_enabled=1), Megalon = Megalon 77 timers on,
   mgoff = the same Megalon build with MEGALON_COH_TIMERS=0.

## Self-test
`bash experiments/h1/test/selftest.sh /home/comsys/sungsu/destijl-control/workspaces/h1-main/selftest-<n>` must print
`SELFTEST PASS` (never while a VM measurement holds workspaces/MEASUREMENT.lock). Case E reads recovery/KV-main-h1-v2
read-only.

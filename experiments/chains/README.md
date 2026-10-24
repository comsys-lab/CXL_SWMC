# experiments/chains: measurement run chains

The chains that ran the de-stijl-motivation-isca27 measurements (eval2 runs 1-3, knee sweep + addendum, Popcorn
writer lock split) and the VM topology tooling they call. They were written and run from the control workspace
(`<DESTIJL_ROOT>/workspaces/`); the files here are copies of those scripts with only their paths parameterised. The
workspaces/ originals stay as the record of what ran. The artifact (`artifact/figures/stages/*.sh`) calls the chains here.

| Here | Original (as run) | Role |
| --- | --- | --- |
| run-chain-v1.sh | workspaces/runs123/run-chain-v1.sh | eval2 run k: H1 (2-VM), H2 (h2n-chain-v4.sh), export |
| h2n-chain-v4.sh | workspaces/runs123/h2n-chain-v4.sh | eval2 H2: install, VM8 switch, N = 2/4/8 blocks, restore, export |
| eval2.env | workspaces/runs123/eval2.env | EVAL2_H1_FIXED switch read by run-chain-v1.sh |
| knee-sweep-chain-v1.sh | workspaces/knee-sweep-chain-v1.sh | knee sweep: H1 2-VM + H2 N = 2/4/8 |
| knee-sweep-chain-v2.sh | workspaces/knee-sweep-chain-v2.sh | knee-sweep addendum: Popcorn H2 u90 N = 4/8 |
| popcorn-writer-lock-split-chain-v1.sh | workspaces/popcorn-writer-lock-split-chain-v1.sh | lock-split exploratory run + knee pilot |
| de-stijl-motivation-isca27-chain-v1.sh | workspaces/de-stijl-motivation-isca27-chain-v1.sh | detached launch of one run-chain-v1.sh run |
| vmN/vmN-chain-v2.sh | workspaces/vmN/vmN-chain-v2.sh | VM topology phases (dry, switch, start, pretouch, restore) |
| vmN/vmN-xml.py | workspaces/vmN/vmN-xml.py (byte-identical) | VM XML generator |

## Paths (environment, defaults = the locations the originals used, so behaviour is identical)

| Variable | Default | Used by |
| --- | --- | --- |
| `DESTIJL_ROOT` | /home/comsys/sungsu/destijl-control | all: P (recovery/, workspaces/MEASUREMENT.lock, the live tree P/CXL_SWMC) |
| `EVAL2_RUN_DIR` | $P/workspaces/runs123 | run-chain-v1.sh, h2n-chain-v4.sh, the isca27 wrapper: run<k>.log, live-head.txt, run<k>-*.log, run<k>-exports.txt, h2n-chain-v4-* |
| `EVAL2_ENV` | <this dir>/eval2.env | run-chain-v1.sh |
| `KNEE_SWEEP_RUN_DIR` | $P/workspaces/knee-sweep | knee-sweep-chain-v{1,2}.sh: chain-v<N>.state, install logs, derived/ (the artifact's KNEE_DERIVED) |
| `LOCK_SPLIT_RUN_DIR` | $P/workspaces/popcorn-lock-split | lock-split chain: chain-v1.state, install logs |
| `MOTIVATION_LAUNCH_LOG` | $P/workspaces/de-stijl-motivation-isca27-chain.log | the isca27 wrapper |
| `VMN_STATE_DIR` | $P/workspaces/vmN | vmN-chain-v2.sh: dry-n<N>/, dry-restore-n<N>/ (DRY-PASS), lg-root/ |

Sibling chains are found next to the calling script (run-chain -> h2n-chain-v4.sh -> vmN/vmN-chain-v2.sh ->
vmN-xml.py), never through workspaces/. Code trees, evidence dirs and confs are unchanged (LS_TREE / H2N_TREE /
--tree, VMN_E, EVAL_CONF; real runs still refuse any tree but the live P/CXL_SWMC). The confs' DERIVED_ROOT /
REGISTRY / POP_C and the data dirs they name stay in workspaces/ (data, not code).

vmN DRY-PASS binds the sha256 of the chain file that ran the dry phase. Every chain runs `dry` / `dry-restore`
before its live phases, so a chain from this directory writes a DRY-PASS of this copy; a live phase of this copy
after a dry of the workspaces/ original (or the reverse) is refused (fail-closed), as for any edited chain.

## Launching (main session)

Real launches by the main session are pre-allowed only for `workspaces/*-chain-*.sh`. Thin launchers there exec the
copies in the live tree (`CHAINS_REPO` [$DESTIJL_ROOT/CXL_SWMC]; another checkout is accepted for dry runs only):

| Launcher | Runs |
| --- | --- |
| workspaces/eval2-chain-v2.sh | run-chain-v1.sh |
| workspaces/h2n-chain-v5.sh | h2n-chain-v4.sh (direct resume) |
| workspaces/knee-sweep-chain-v3.sh | knee-sweep-chain-v1.sh |
| workspaces/knee-sweep-chain-v4.sh | knee-sweep-chain-v2.sh (addendum) |
| workspaces/popcorn-writer-lock-split-chain-v2.sh | popcorn-writer-lock-split-chain-v1.sh |
| workspaces/de-stijl-motivation-isca27-chain-v2.sh | de-stijl-motivation-isca27-chain-v1.sh |
| workspaces/vmN-chain-v3.sh | vmN/vmN-chain-v2.sh |
| workspaces/artifact-figures-chain-v1.sh | artifact/figures/<figN\|all\|stages/...>.sh |

Example: `setsid nohup bash $P/workspaces/eval2-chain-v2.sh --run 1 > /dev/null 2>&1 < /dev/null &` (log
$EVAL2_RUN_DIR/run1.log), `bash $P/workspaces/knee-sweep-chain-v3.sh --dry-run`.

## Concurrency guard (vmN nochain)

vmN-chain-v2.sh refuses its prechecks (dry, pre, dry-restore, r-down, nochain-check) while another process's command
line matches (pgrep -f)

    [p]3c-deploy\.sh|[l]-vanilla-deploy|[k]ernel-switch\.sh|[p]-popcorn-(deploy|shm|stress)\.sh|[e]xperiments/[a-z0-9]+/run\.sh|
    [s]equence[0-9]*\.sh|[h]1-chain|[r]ecsysv1-chain|[v]m8-chain|[e]val-run[0-9]*-chain|[e]xperiments/eval/|[m]ain-block\.sh|
    [r]ecsys/session\.sh|[n]-smoke-chain|[a-zA-Z0-9]-chain[-a-z0-9.]*\.sh

excluding itself, its ancestors (the chain that called it) and its own subshells. The generic last term matches every
file here and every launcher by name (`<x>-chain<...>.sh`), wherever it lives, so a running repo chain blocks a second
chain exactly as the workspaces/ originals did; the launchers `exec`, so the running process's command line names the
repo chain. The term needs `.sh` right after the chain name: log monitors (`tail -f .../run1.log`,
`grep ... chain-v1.state`, `.../h2n-chain-v4-run1.state`, `...-chain.log`) do not match. Do not name a chain script
file (`*-chain*.sh`) in a monitor's or helper's command line (e.g. `pgrep -f knee-sweep-chain-v1.sh` inside `bash -c`,
`less run-chain-v1.sh`) while a chain is about to call vmN: that process counts as a running chain. The artifact
scripts (all.sh, figN.sh, stages/*.sh) do not match; the chains they start do. Checked 2026-10-24 with fake
processes for every copy and launcher (workspaces/chains-in-repo/guard-test.sh: 11 HIT, 7 CLEAR, ancestor excluded).

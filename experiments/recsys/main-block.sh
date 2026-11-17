#!/bin/bash
# The recommendation-system H1 MAIN block (reports/RECSYS-main-packet.md): full-size tables (26 tables, 26M cap,
# 167,731,776 slots x 576 B = 89.98 GiB), T = 60 s, serving on node 1, MOT1 v6 (user 2026-10-16):
#   SLO query p95 <= 100 ms (DeepRecSys ISCA'20; reports/MOT1-v6-sources.md §1), fixed for every system (<E>/slo.txt);
#   updater on node 0 replays the real MLPerf day-23 multi-hot trace at the Ekko operating point EKKO=avg (3.08% of
#   rows/hour -> PUBLISH_FRAC 0.0308/60 per T) or EKKO=peak (4.3%/10 min -> 0.043/10 per T); the sample rate is
#   computed on the Host by recsys-rate from the trace (<E>/update-rate.txt) so that one T publishes that fraction.
#   (v5 rule "SLO = 5 x all-HWcc p99 at the lowest load" and the fixed 2,100 samples/s are superseded.) Every system on the Popcorn build POP_BUILD (>= 10) kernel (K8): all-HWcc and Megalon with cxl_shm unloaded, page MSI
# with cxl_shm loaded once for its whole server lifetime (init_state=shared + preload, recv_mode RECV_MODE).
# usage: main-block.sh <evidence dir (exists; only sequence* files)>
# env (required): C8 (Popcorn deploy bundle dir, = builds/popcorn_new/10/deploy-v1), K8, GT8 (names kept from v5),
#   RECV_MODE, optional POP_BUILD (10, >= 10), POP_BUNDLE_SHA (build-10 deploy-v1 packet hash), D (inputs dir with MANIFEST.txt),
#   VM_PLAIN (guest dir: build-3 server, all-HWcc + page MSI), VM_MEG (guest dir: Megalon build + recsys-2vm.yaml),
#   MEG_BUILD (recsys-megalon build on MEGALON_BASE, default builds/megalon/75), PLAIN_BUILD (v6 recsys build dir), EKKO
#   (avg | peak | f087 | f149 | f253 (v0.6.10) | f330 (v0.6.11) | f350 | f370 | f400 (v0.6.12) | f385 (v0.6.13) | f392 (v0.6.14)), LOADGEN; optional SEED (20261016), UPD_FILE / QRY_FILE (names in D; default the day-23 slices of
#   builds/recsys-inputs/1),
#   ROUNDS (3), FIXED (1; 0 = no fixed-load window), XT (server lifetime bound, s, default 28800),
#   SYSTEMS (subset of "hw pop mg", seeded order kept), L_FROM (fixed-load-L.txt; needed when hw is not in SYSTEMS
#   and FIXED=1).
# Load once per system (recorded exception to "every run starts from the initial image"): per system one server
# lifetime (session.sh) with, in this order,
#   warmup 1 query/s + the updater, 10 s + 70 s, unmeasured (results kept, never used): after the server's own read of
#          every slot (both nodes, before READY; page MSI read first-touch faults happen there), the first T = 60 s
#          publication round (updater write faults / page MSI invalidations) and the query path's first use
#   gate   1 query/s, 60 s, no SLO abort: the lowest-load window. VALID = one step, keeps up, no errors/timeouts,
#          >= 1 query (main_util.py gate, within_slo by p95). all-HWcc: INVALID STOPs the block. page MSI / Megalon:
#          recorded with within_slo (block continues)
#   slo-r1, slo-r2, slo-r3   full MOT1 §3.3 SLO searches (PROFILE=main: warm-up 10 s, steps 3 s + 15 s, bisect 5%,
#          confirm 3 x 30 s with step-down, fill 0.7/0.8/0.9, overload 1.05/1.1/1.2), loadgen seed SEED + round
#   fixed  60 s at L = 0.5 x all-HWcc slo-r1 confirm mean (no SLO abort: the whole window is measured); breakdown.csv
#          must have the system's coherence columns (check_breakdown.py)
# System order: all-HWcc first (its gate sets the block's SLO and its slo-r1 gives every system's L),
#   then page MSI and Megalon in an order shuffled with seed = the block owner (recorded in order.txt).
# /dev/dax0.0: comsys for all-HWcc / Megalon, root:root 600 before page MSI (p-popcorn-shm.sh precheck; its teardown
# restores it). Holds workspaces/MEASUREMENT.lock; Host gate before every measurement; stops at the first MAIN STOP.
# On every exit (finish, not interruptible): stop this block's servers (session dirs and a running --preload-only via its pid file),
# tear down page MSI if loaded without "teardown PASS" (instr-on retry), /dev/dax0.0 back to root:root 600
# UNCONDITIONALLY on both VMs ("ROLLBACK FAIL" if a stat line is not root:root 600 or a recsys-server survived), unlock.
# A measurement whose stats key/file is missing stops the block with "STATS MISSING <key>" (session.sh rc 5).
# BLOCK=v1 (reports/RECSYS-V1-packet.md): validation block instead of the H1 measurements: per system one lifetime
#   with the warm-up and one fixed-load window at V1_RATE (1) query/s for V1_WINDOW_S (130 s, >= 2 rounds of T = 60 s),
#   then v1_check.py (FAIL stops) and check_breakdown.py; systems hw pop mg mgoff (mgoff = Megalon with
#   MEGALON_COH_TIMERS=0, same load, for the timer on/off comparison); no SLO search, no gate, no fixed-L window.
#   After the last lifetime (hw and mgoff present): v1_cdiff.py -> <E>/cdiff.{txt,csv}, Megalon Fig 2 C by the
#   difference method C_diff = T(mgoff) - T(hw) per op (user decision 2026-10-17); CDIFF FAIL (offered rates differ)
#   stops the block; C_diff < 0 and C_sampled > T / > C_diff are WARNs only.
#   v1.4 (reports/RECSYS-V1-packet.v1.4.md): Megalon object granularity. MG_RPO_OPT (server option name, e.g.
#   --mg-rows-per-object; empty = not passed, builds before recsys-megalon/14) is passed with MG_TABLE_N (default 0 =
#   one object per embedding table, the main configuration) to mg and mgoff, and with MG_ROW_N (default 1 = one object
#   per row, the "restructured best case" variant) to the extra system mgrow (BLOCK=v1 only; needs MG_RPO_OPT). The
#   checkers see mgrow as mg (same Megalon checks). v1 order with mgrow: hw pop mgrow mg mgoff. V1_OPFAIL_CONTINUE
#   ("<sys> ...", default empty = the user rule: every V1CHECK FAIL stops): for a listed system, a window that fails
#   ONLY operating-point checks (v1_check.py --oppoint-report rc 3: updater behind, flush overruns,
#   update_rate_sustained, rows per full round) is recorded as "V1CHECK OPFAIL" in <E>/v1-checks.txt and
#   <E>/v1-opfail.txt and the block continues; correctness / system checks still stop. Only with a user decision.
#   MG_COH_SAMPLE (default empty = Megalon's 1 in 64): MEGALON_COH_CHECK_SAMPLE for every Megalon lifetime (mg, mgoff,
#   mgrow; BLOCK v1 and h1) and v1_check.py --mg-sample (the value must reach both servers). v1.4: 1 (user decision
#   2026-10-18: time every section of the table objects, about 26 write sections per round).
# RS_T_MS / RATE_T_DIR (H1 v0.6.9, RECSYS-V1 v1.5): publication period T in ms (default 60000 = every block before
#   v0.6.9) and, for T != 60 s, the T-specific calibration dir (rate-T<ms>-<point>.txt; see ekko_set below).
#   BLOCK=h1 needs RS_T_MS explicitly (H1 RecSys: 1000, user decision 2026-10-18). The update sample rate is the Ekko
#   rate at T = 60 s in every case; the window lengths (warm-up 70 s, V1 130 s, H1 settle / L2 / L1 60 s, SLO steps
#   15 s) are unchanged in seconds, i.e. they hold about 70 / 130 / 60 / 15 rounds at T = 1 s.
# BLOCK=h1 — H1-HOOK v2 (experiments/h1/README.md "Hook contract H1-HOOK v2", reports/H1-main-packet.md v0.3 §2-§3;
#   user decisions 2026-10-18; called once per round by experiments/h1/hook.sh):
#   env H1MODE r1|cont, H1_N, H1_SEED (loadgen seed of every part), H1_MIXES "<mix>=EKKO=<avg|peak|f087|f149|f253|f330|f350|f370|f400|f385|f392> ...", H1_SETTLE_S
#   (60 s = one publication period T), H1_PARENT_LOCK=H1-main (the lock must name owner=H1-main; never lock/unlock),
#   PRETOUCH_DIR (pretouch-gate.sh at block start and end), MEASURE_ENV_DIR (Host gate before every loadgen part),
#   EXPECT_DAX_UUID (guest precheck); r1: H1_LEVELS_CMD (prints "<L2_rate> <L1_rate>" for a mix); cont: H1_LEVELS.
#   One server lifetime holds one or two loadgen parts: <lifetime>/slo = warm-up (1 query/s, unmeasured) + the full SLO
#   search (query p95 <= 100 ms; PROFILE=main ramp/bisect, confirm 3 x 30 s, fill, overload past the knee; --start 1
#   --factor 1.5 --precision 0.05 --max-steps 20); <lifetime>/fix = settle (loadgen --warmup-s H1_SETTLE_S at the
#   L2 rate, discarded, no stats snapshot) + L2 window + L1 window (60 s each, no SLO abort). A fix-only lifetime starts
#   with the settle right after READY (no extra warm-up). The Ekko point (publish_frac, update rate) is per mix.
#   H1_SYSTEMS (from hook.sh / experiments/h1/h1sys.py; required): "hw pop" (H1 v0.6.7, user decision 2026-10-18 "그냥
#   recsys는 megalon 측정 하지마": no Megalon lifetime in H1 RecSys) or "hw pop mg" (the earlier flow below).
#   "hw pop": r1 per mix: hw and pop SLO-only lifetimes (order seed H1-recsys-r1-<mix>), then "$H1_LEVELS_CMD" <mix>
#     outside any lifetime (non-zero = LEVELS STOP), then hw and pop fix-only lifetimes (order seed H1-recsys-r1-<mix>-fix);
#     cont: hw, pop in the order shuffle(seed H1-recsys-latin) rotated left by n mod 2, each slo -> fix; no mgoff.
#   "hw pop mg":
#   r1, per mix (mix order: shuffle seed H1-recsys-r1): hw and pop SLO-only lifetimes (order seed H1-recsys-r1-<mix>);
#     mg lifetime: slo -> "$H1_LEVELS_CMD" <mix> (non-zero = LEVELS STOP: stop, roll back) -> fix at those rates;
#     mgoff lifetime (MEGALON_COH_TIMERS=0) right after mg: fix only; hw and pop fix-only lifetimes (order seed
#     H1-recsys-r1-<mix>-fix).
#   cont (rounds 2, 3; rates = H1_LEVELS L2_rate / L1_rate of the mix), per mix (order: shuffle seed H1-recsys-r<n>):
#     hw, pop, mg in the order shuffle(seed H1-recsys-latin) rotated left by n, each one lifetime slo -> fix; the mgoff
#     lifetime (fix only) right after mg.
#   Checks per part: v1_check.py <part> <sys> --h1 (SLO part: update/operating-point checks on the passing,
#   non-overload steps only, violations elsewhere NOTE; fix part: every check over the L2+L1 span, FAIL; the settle
#   has no stats snapshot, so it is outside the window, and the v1.2.7 normalisation removes partly fed rounds) and
#   check_breakdown.py -> <lifetime>/h1-runcheck.txt (last line RUNCHECK PASS[ (NOTE: ...)]; a failed check stops).
#   <E>/h1-runs.tsv (8 columns: name system mix phase round run_dir steps lifetime), appended as parts finish;
#   <E>/order.txt before the first lifetime. Lifetime names: r1 <sys>-<mix>-slo-r1 / <sys>-<mix>-fix-r1 (hw, pop),
#   mg-<mix>-r1 (entries -slo / -fix), mgoff-<mix>-fix-r<n>; cont <sys>-<mix>-r<n> (entries -slo / -fix).
# BLOCK=stream — RecSys streaming block (user decisions 2026-10-19, state/PROJECT.md "RecSys experiment methodology";
#   workloads/recsys/DESIGN.md §5.1; every RecSys experiment from then on; BLOCK=h1 and the other blocks unchanged):
#   env STREAM_RATES (update rates in trace samples/s, multiples of 50 in [50, 2000]; Ekko avg 41.47 -> 50, peak
#   393.27 -> 400; > 400 = stress, labelled), PRETOUCH_DIR (pretouch-gate.sh at block start and end), optional SYSTEMS
#   (subset of "hw pop mg", default "hw pop"); EKKO and RS_T_MS are refused. Servers: --publish-ms 0 --update-mode stream,
#   node 0 --update-threads 14 --serve-threads 1, node 1 --update-threads 1 --serve-threads 14 (N0X below). Per rate
#   (in STREAM_RATES order), per system (order shuffle(seed recsys-stream-<rate>), <E>/order.txt) one lifetime
#   <sys>-u<rate>: warmup (1 query/s + the update stream, 10 + 50 s, unmeasured) -> slo (query p95 <= 100 ms or EVAL STREAM_SLO_MS, start 1,
#   factor 1.5, precision 0.02, confirm 3 x 30 s as H1, --tol 0.02, --max-steps 40, --min-step-queries 100,
#   --ramp-knee 2, rise 1.2 default) -> stream_check.py (FAIL stops; NOTE "update rate not sustained" recorded) -> check_breakdown.py.
#   loadgen rc 1 with a note is recorded (MAIN NOTE), not a stop. <E>/stream-results.tsv (one row per lifetime),
#   <E>/rate-basis.txt (formula and rounding).
# STREAM_PMAX=1 (run 2, EVAL_RUN only; user 2026-11-03 Q9: fault breakdown of Popcorn and De Stijl at the SAME load =
#   Popcorn's max under the SLO of the rate): every pop / ds lifetime appends ONE fixed-load part "pmax" after its slo
#   (and same-lifetime fix) part: loadgen --mode fixed --rates <rate> --warmup-s STREAM_PMAX_SETTLE_S (30, discarded)
#   --step-warmup-s 5 --step-measure-s STREAM_PMAX_S (60) --drain-s 10, seed SEED + 2, no SLO abort. Rate (query/s) =
#   experiments/eval/pmax_decide.py --workload recsys over the pop-u<rate> row: a pop lifetime its own slo row in
#   <E>/stream-results.tsv (written right before), a ds lifetime the rows of STREAM_PMAX_FROM (space-separated
#   stream-results.tsv files of the rs-main block of the same run, later files win). No confirmed valid pop max = no
#   step (NOTE). Checks: stream_check.py + check_breakdown.py recorded (a failed check is a NOTE, the slo row stands).
#   <E>/stream-pmax.tsv: name system rate_sps pmax_q_s appended status source; <lifetime>/pmax/ = part dir.
# STREAM_AUC="<rate>=<query/s> ..." (run 2 T sweep, user 2026-11-05: fixed-rate AUC, EVAL_RUN and V7=1 only): after the
#   rate's SLO lifetimes (and fix-only lifetimes), every system of the block gets ONE more lifetime <sys>-u<rate>-auc:
#   the SLO lifetimes' warm-up part (same command; the update stream is open-loop, so every system enters the next part
#   at the same update position seq_base, e.g. 11964 at 200 / 23931 at 400 samples/s in run 1), then part auc: loadgen
#   --mode fixed --rates <query/s> --warmup-s STREAM_AUC_SETTLE_S (30, discarded) --step-warmup-s 5 --step-measure-s
#   STREAM_AUC_S (300) --drain-s 10, seed SEED + 3 (same seed, rate, seq_base and timing for every system and T = the
#   same query draws: start = update position at make time + offset, both a function of the schedule and the seed).
#   Checks: a workload finish other than ok, loadgen rc > 1 or rc 1 without a note = stop (the chain retries the block);
#   loadgen rc 1 with a note, stream_check.py and check_breakdown.py are recorded (status, not a stop). v7_post with the AUC row into <E>/auc_part.csv (per-part AUC over
#   the measured step: auc, logloss, auc_frozen on the same multiset of samples). <E>/stream-auc.tsv: name system
#   rate_sps auc_q_s seq_base status. STREAM_AUC_ONLY=1: no SLO lifetimes in the block (AUC lifetimes only).
# De Stijl replica_mode (run 2 widening 2026-11-06, T = 1000 ms accuracy + staleness): DS_REPLICA_MODE off | all,
#   DS_REPLICA_POOL_BYTES (cap); see the De Stijl block below and ds-replica.sh. Unset / off = no replica step.
#   Torn rows (user 2026-11-07): every ds lifetime passes TORN_POLICY "system=ds T_us=<T> replica_mode=<m>" to
#   session.sh; torn rows are allowed (reported, torn_rows.py) only with T > 0 and replica_mode on.
# Serving split (reports/experiments/recsys-serving-split.md): CHUNK_PAIRS N (BLOCK=stream; lib.sh rs_env from the conf's
#   RS_CHUNK_PAIRS) appends --chunk-pairs N to the server args of every node; unset / empty = not passed = the server's
#   adaptive split (every earlier run, args byte for byte). BLOCK=stream prints "BLOCK PLAN: server args: <args>".
#   2-way split (user 2026-11-13): SPLIT_WAYS K / MIN_CHUNK M (lib.sh rs_env from RS_SPLIT_WAYS / RS_MIN_CHUNK) append
#   --split-ways K / --min-chunk M (server chunk = max(M, ceil(pairs / K)); recsys builds >= 18); not with CHUNK_PAIRS.
#   recsys-amx-2way: MLP amx (lib.sh rs_env from RS_MLP) appends --mlp amx (recsys builds >= 21); unset = not passed.
# De Stijl wait assist (build >= 13, kernel switch /sys/kernel/swmc/destijl/wait_assist): DS_WAIT_ASSIST 0 | 1
#   (runset-rs-ds.sh RS_DS_WAIT_ASSIST); unset / empty = no step (every earlier run). See the De Stijl block below.
# STREAM_ONE_LIFETIME=1 (user 2026-11-11, Megalon only; runset-rs-h1.sh RS_MG_ONE_LIFETIME): ONE mg server lifetime (one
#   load) for every rate of STREAM_RATES, in order; unset / 0 = one lifetime per rate (every earlier run, unchanged).
#   Needs BLOCK=stream, EVAL_RUN, SYSTEMS=mg, V7=1, PUBLISH_WINDOW_S W > 0 with PUBLISH_WARMUP=1, no fixed / AUC
#   windows, and STREAM_SETTLE_S (>= 2 W; 1200 s at W = 600 s). First rate r1: the per-lifetime sequence as above
#   (life_start = session start + pubtrain, then stream_slo = warmup + pub_after + slo) in session dir <E>/mg-u<r1>.
#   Each later rate r: continuation dir <E>/mg-u<r> (session.env, session-manifest.txt and seq_base copied: the same
#   servers, seqs continue), part "settle" = the update stream alone at the new rate (loadgen --fixed update=<r>
#   --rates 0, no queries) for STREAM_SETTLE_S s (one window at r + its publication), then stream_slo as today. The
#   update rate is the loadgen's (--fixed update=<r>, --opt update_rate=<r>; the trainer consumes what arrives), so
#   the switch needs no server restart. Rate check: the settle part's stream_check accepted_per_s within 10 % of r
#   (else stop); publisher check at the settle end (node 0: publish_window advanced >= 2 since the switch,
#   publish_backlog <= 16): failing = one more settle part "settle2" of W s, failing again = "NOTE one-lifetime:
#   publisher behind at u<r>" in the rate's stream-results.tsv note and one-lifetime.tsv (never a stop); <E>/one-lifetime.tsv: per rate the switch counters (node 0 after the previous part: publish_window,
#   published_rows, window_distinct, publish_backlog, update_accepted_seq, seq_base), settle start / end, accepted
#   rates. After the last rate: life_stop of <E>/mg-u<r1> (node logs / final checks there, for the whole lifetime;
#   torn_rows.py block counts a continuation dir by its measurements). A stop in a later rate ends the block as a
#   failed lifetime does (the finish trap stops the servers); earlier rates' rows and part dirs stay.
# U0 (recsys-amx-2way widening 2026-11-17): STREAM_RATES entry 0 = serving with no update samples, see "---- U0" below
#   (STREAM_U0_QWIN_SAMPLES, idle pubtrain, zero-row-write checks); no 0 entry = every earlier run unchanged.
set -uo pipefail
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control X=$(cd "$(dirname "$0")" && pwd)
G=$(cd "$X/../vectordb" && pwd)/host-gate.sh PTG=$(cd "$X/../vectordb" && pwd)/pretouch-gate.sh
# Host gate before every loadgen part: H1 main (H1_MEASURE_RUN=1, experiments/h1/README.md item 8) uses
# experiments/h1/h1-gate.sh (partition check with MEASURE_PART_DIR, builds, node1 measurement CPU sets) and session.sh
# starts loadgen through scripts/host/measure-run.sh; otherwise (validation packets) host-gate.sh as before.
GATE=$G
if [ "${H1_MEASURE_RUN:-0}" = 1 ]; then
  GATE=$(cd "$X/../h1" && pwd)/h1-gate.sh
  [ -f "$GATE" ] && [ -d "${MEASURE_PART_DIR:-}" ] || { echo "SEQUENCE STOP: H1_MEASURE_RUN=1 needs experiments/h1/h1-gate.sh and MEASURE_PART_DIR"; exit 2; }
  export H1_MEASURE_RUN MEASURE_PART_DIR
fi
: "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}" "${D:?}" "${VM_PLAIN:?}" "${VM_MEG:?}" "${MEG_BUILD:?}" "${LOADGEN:?}"
: "${PLAIN_BUILD:?}"
MB=$MEG_BUILD SEED=${SEED:-20261016} ROUNDS=${ROUNDS:-3} FIXED=${FIXED:-1} XT=${XT:-28800}
BLOCK=${BLOCK:-main} V1_RATE=${V1_RATE:-1} V1_WINDOW_S=${V1_WINDOW_S:-130}
case $BLOCK in main|v1|h1|stream) ;; *) echo "SEQUENCE STOP: BLOCK must be main, v1, h1 or stream"; exit 2;; esac
if [ $BLOCK = h1 ]; then  # H1-HOOK v2 inputs (see the header)
  [ "${H1_PARENT_LOCK:-}" = H1-main ] || { echo "SEQUENCE STOP: BLOCK=h1 needs H1_PARENT_LOCK=H1-main"; exit 2; }
  [[ "${H1_N:-}" =~ ^[1-9]$ ]] && [[ "${H1_SEED:-}" =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: H1_N / H1_SEED"; exit 2; }
  [[ "${H1_SETTLE_S:-}" =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad H1_SETTLE_S"; exit 2; }
  : "${H1_MIXES:?}"
  case "${H1MODE:-}" in
    r1) [ "$H1_N" = 1 ] && [ -n "${H1_LEVELS_CMD:-}" ] || { echo "SEQUENCE STOP: r1 needs H1_N=1 and H1_LEVELS_CMD"; exit 2; };;
    cont) [ -f "${H1_LEVELS:-}" ] || { echo "SEQUENCE STOP: no H1_LEVELS"; exit 2; };;
    *) echo "SEQUENCE STOP: bad H1MODE (r1|cont)"; exit 2;; esac
  [ -d "${PRETOUCH_DIR:-}" ] && [ -n "${MEASURE_ENV_DIR:-}" ] && [ -n "${EXPECT_DAX_UUID:-}" ] \
    || { echo "SEQUENCE STOP: BLOCK=h1 needs PRETOUCH_DIR, MEASURE_ENV_DIR and EXPECT_DAX_UUID"; exit 2; }
  [ -z "${SYSTEMS:-}" ] || { echo "SEQUENCE STOP: SYSTEMS is not used with BLOCK=h1"; exit 2; }
  case "${H1_SYSTEMS:-}" in "hw pop"|"hw pop mg") ;; *) echo "SEQUENCE STOP: BLOCK=h1 needs H1_SYSTEMS 'hw pop' or 'hw pop mg' (got '${H1_SYSTEMS:-}')"; exit 2;; esac
  H1MG=0; [ "$H1_SYSTEMS" = "hw pop mg" ] && H1MG=1
  [ "${H1_MEASURE_RUN:-0}" = 1 ] || { echo "SEQUENCE STOP: BLOCK=h1 needs H1_MEASURE_RUN=1 (h1-gate.sh + measure-run.sh, README item 8)"; exit 2; }
  SEED=$H1_SEED EKKO=${EKKO:-per-mix}
elif [ $BLOCK = stream ]; then  # RecSys streaming block (header "BLOCK=stream")
  [ -z "${EKKO:-}" ] && [ -z "${RS_T_MS:-}" ] || { echo "SEQUENCE STOP: BLOCK=stream takes STREAM_RATES, not EKKO / RS_T_MS"; exit 2; }
  : "${STREAM_RATES:?}"
  for r in $STREAM_RATES; do
    [ "$r" = 0 ] && continue   # u0 (header "U0"): its own checks after the v7 keys
    [[ $r =~ ^[1-9][0-9]*$ ]] && [ $((r % 50)) = 0 ] && [ $r -le 2000 ] || { echo "SEQUENCE STOP: STREAM_RATES entry $r is not a multiple of 50 in [50, 2000] samples/s"; exit 2; }; done
  [ -d "${PRETOUCH_DIR:-}" ] || { echo "SEQUENCE STOP: BLOCK=stream needs PRETOUCH_DIR"; exit 2; }
  if [ -z "${EVAL_RUN:-}" ]; then
    case " ${SYSTEMS:-hw pop} " in *" mgoff "*|*" mgrow "*) echo "SEQUENCE STOP: BLOCK=stream systems are hw, pop, mg"; exit 2;; esac
    [ -z "${RS_THREADS:-}${REGION:-}${STREAM_FIX_LEVELS:-}${STREAM_FIXONLY:-}${STREAM_LEVELS:-}${STREAM_FIX_LEVELS_MAP:-}${STREAM_FIX_FALLBACK:-}${STREAM_FIX_SEP:-}" ] \
      || { echo "SEQUENCE STOP: RS_THREADS / REGION / STREAM_FIX_LEVELS / STREAM_FIXONLY / STREAM_LEVELS need EVAL_RUN"; exit 2; }
  else  # evaluation run sets (experiments/eval/runset-rs-*.sh; header "EVAL")
    [[ $EVAL_RUN =~ ^[1-9]$ ]] || { echo "SEQUENCE STOP: bad EVAL_RUN"; exit 2; }
    [ -f "${REGION:-}" ] || { echo "SEQUENCE STOP: EVAL_RUN needs REGION (region file of every lifetime)"; exit 2; }
    [[ ${RS_THREADS:-} =~ ^[1-9][0-9]?$ ]] || { echo "SEQUENCE STOP: EVAL_RUN needs RS_THREADS"; exit 2; }
    for s in ${SYSTEMS:-hw pop}; do case $s in hw|pop|ds|mg|mgoff) ;; *) echo "SEQUENCE STOP: eval stream systems are hw, pop, ds, mg, mgoff"; exit 2;; esac; done
    for s in ${STREAM_FIXONLY:-}; do [[ " ${SYSTEMS:-hw pop} " == *" $s "* ]] || { echo "SEQUENCE STOP: STREAM_FIXONLY $s not in SYSTEMS"; exit 2; }; done
    [[ " ${SYSTEMS:-} " != *" mgoff "* ]] || [[ " ${STREAM_FIXONLY:-} " == *" mgoff "* ]] || { echo "SEQUENCE STOP: mgoff is fix-only (STREAM_FIXONLY)"; exit 2; }
    for t in ${STREAM_FIX_LEVELS:-} $(for m in ${STREAM_FIX_LEVELS_MAP:-}; do [[ ${m%%=*} =~ ^[1-9][0-9]*$ ]] || echo BAD; echo "${m#*=}" | tr ',' ' '; done); do
      [[ $t =~ ^(L1|L2|[0-9]+(\.[0-9]+)?)$ ]] || { echo "SEQUENCE STOP: bad STREAM_FIX_LEVELS(_MAP) token $t"; exit 2; }; done
    [[ -z "${STREAM_FIX_FALLBACK:-}" || $STREAM_FIX_FALLBACK =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ ${STREAM_FIX_SEP:-1} =~ ^[01]$ ]] \
      || { echo "SEQUENCE STOP: bad STREAM_FIX_FALLBACK / STREAM_FIX_SEP"; exit 2; }
    [ -n "${STREAM_FIX_LEVELS:-}${STREAM_FIX_LEVELS_MAP:-}" ] || [ -z "${STREAM_FIXONLY:-}" ] || { echo "SEQUENCE STOP: STREAM_FIXONLY needs STREAM_FIX_LEVELS"; exit 2; }
    [ -z "${STREAM_LEVELS:-}" ] || [ -f "$STREAM_LEVELS" ] || { echo "SEQUENCE STOP: STREAM_LEVELS file missing"; exit 2; }
    [[ ${STREAM_FIX_S:-60} =~ ^[1-9][0-9]*$ && ${STREAM_FIX_SETTLE_S:-60} =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad STREAM_FIX_S / STREAM_FIX_SETTLE_S"; exit 2; }
    # run-2 pmax step (header "STREAM_PMAX")
    [[ ${STREAM_PMAX:-0} =~ ^[01]$ && ${STREAM_PMAX_S:-60} =~ ^[1-9][0-9]*$ && ${STREAM_PMAX_SETTLE_S:-30} =~ ^[1-9][0-9]*$ ]] \
      || { echo "SEQUENCE STOP: bad STREAM_PMAX / STREAM_PMAX_S / STREAM_PMAX_SETTLE_S"; exit 2; }
    [ -z "${STREAM_PMAX_FROM:-}" ] || [ "${STREAM_PMAX:-0}" = 1 ] || { echo "SEQUENCE STOP: STREAM_PMAX_FROM without STREAM_PMAX=1"; exit 2; }
    [ "${STREAM_PMAX:-0}" = 0 ] || [ -f "$X/../eval/pmax_decide.py" ] || { echo "SEQUENCE STOP: missing experiments/eval/pmax_decide.py"; exit 2; }
    # run-2 fixed-rate AUC lifetimes (header "STREAM_AUC")
    for m in ${STREAM_AUC:-}; do
      [[ $m =~ ^(0|[1-9][0-9]*)=[0-9]+(\.[0-9]+)?$ ]] && [[ " $STREAM_RATES " == *" ${m%%=*} "* ]] || { echo "SEQUENCE STOP: bad STREAM_AUC entry $m (<rate in STREAM_RATES>=<query/s>)"; exit 2; }
    done
    [[ ${STREAM_AUC_S:-300} =~ ^[1-9][0-9]*$ && ${STREAM_AUC_SETTLE_S:-30} =~ ^[1-9][0-9]*$ && ${STREAM_AUC_ONLY:-0} =~ ^[01]$ ]] \
      || { echo "SEQUENCE STOP: bad STREAM_AUC_S / STREAM_AUC_SETTLE_S / STREAM_AUC_ONLY"; exit 2; }
    [ -n "${STREAM_AUC:-}" ] || [ "${STREAM_AUC_ONLY:-0}" = 0 ] || { echo "SEQUENCE STOP: STREAM_AUC_ONLY=1 without STREAM_AUC"; exit 2; }
    # extra fixed-rate parts in the AUC lifetimes (header "STREAM_AUC2"); unset = none
    for m in ${STREAM_AUC2:-}; do
      [[ $m =~ ^(0|[1-9][0-9]*)=[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*$ ]] && [[ " ${STREAM_AUC:-} " == *" ${m%%=*}="* ]] \
        || { echo "SEQUENCE STOP: bad STREAM_AUC2 entry $m (<rate with a STREAM_AUC entry>=<q/s>,<q/s>,..)"; exit 2; }
    done
    [[ ${STREAM_AUC2_S:-120} =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad STREAM_AUC2_S"; exit 2; }
    [ -n "${STREAM_AUC2:-}" ] || [ -z "${STREAM_AUC2_S:-}" ] || { echo "SEQUENCE STOP: STREAM_AUC2_S without STREAM_AUC2"; exit 2; }
  fi
  [ -n "${EVAL_RUN:-}" ] || [ -z "${STREAM_AUC2:-}${STREAM_AUC2_S:-}" ] || { echo "SEQUENCE STOP: STREAM_AUC2 needs EVAL_RUN"; exit 2; }
  [[ ${STREAM_AUC2_V7POST:-0} =~ ^[01]$ ]] && { [ "${STREAM_AUC2_V7POST:-0}" = 0 ] || [ -n "${STREAM_AUC2:-}" ]; } \
    || { echo "SEQUENCE STOP: STREAM_AUC2_V7POST must be 0 / 1 and needs STREAM_AUC2"; exit 2; }
  [ -n "${EVAL_RUN:-}" ] || [ -z "${STREAM_PMAX:-}${STREAM_PMAX_FROM:-}" ] || { echo "SEQUENCE STOP: STREAM_PMAX needs EVAL_RUN"; exit 2; }
  [ -n "${EVAL_RUN:-}" ] || [ -z "${STREAM_AUC:-}${STREAM_AUC_ONLY:-}" ] || { echo "SEQUENCE STOP: STREAM_AUC needs EVAL_RUN"; exit 2; }
  EKKO=stream
else
  : "${EKKO:?}"
fi
MEGALON_BASE=${MEGALON_BASE:-$P/builds/megalon/75}
UPD_FILE=${UPD_FILE:-updates-day23-0-2M.smp} QRY_FILE=${QRY_FILE:-queries-day23-89137318-1M.smp}
SLO_PCT=95 SLO_MS=100 SLO_SRC="MOT1 v6, user 2026-10-16"
# EVAL stream options (experiments/eval/lib.sh rs_env; BLOCK=stream with EVAL_RUN only; unset = the values above):
#   STREAM_SLO_MS 100 | 400: query p95 SLO in ms (400 = user decision 2026-11-02 for 4 vCPU guests: 100 ms x 16 / 4 vCPU,
#     DeepRecSys DLRM-RMC targets "hundreds of ms")
#   STREAM_CONFIRM_PROBES 6 | 3: loadgen --max-confirm-probes of the SLO search (3 = the lean cut, schedule §1 "cap 3";
#     the RecSys overload ladder is loadgen's default 3 points 1.05 / 1.1 / 1.2, already below the cap of 7)
if [ -n "${STREAM_SLO_MS:-}${STREAM_CONFIRM_PROBES:-}" ]; then
  [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: STREAM_SLO_MS / STREAM_CONFIRM_PROBES need BLOCK=stream and EVAL_RUN"; exit 2; }
  case ${STREAM_SLO_MS:-100} in 100) ;; 400) SLO_MS=400 SLO_SRC="4 vCPU guests, user 2026-11-02";;
    *) echo "SEQUENCE STOP: STREAM_SLO_MS must be 100 or 400 (got ${STREAM_SLO_MS})"; exit 2;; esac
  case ${STREAM_CONFIRM_PROBES:-6} in 3|6) ;; *) echo "SEQUENCE STOP: STREAM_CONFIRM_PROBES must be 3 or 6"; exit 2;; esac
fi
STREAM_CONFIRM_PROBES=${STREAM_CONFIRM_PROBES:-6}
#   STREAM_SLO_TOL (user 2026-11-11; lib.sh rs_env from the conf's RS_SLO_TOL): loadgen --tol of the BLOCK=stream SLO
#     search (stream_slo) only, a number in (0, 0.2]; unset = 0.02 (every earlier run). 0.05: a step whose queries all
#     completed but ~3-6 % finished after the 15 s window no longer fails as "not keeping up". H1_SLO_TOL is separate.
SSTOL=0.02
if [ -n "${STREAM_SLO_TOL:-}" ]; then
  [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: STREAM_SLO_TOL needs BLOCK=stream and EVAL_RUN"; exit 2; }
  [[ $STREAM_SLO_TOL =~ ^0?\.[0-9]+$ ]] && awk -v t="$STREAM_SLO_TOL" 'BEGIN { exit !(t > 0 && t <= 0.2) }' \
    || { echo "SEQUENCE STOP: STREAM_SLO_TOL must be a number in (0, 0.2] (got $STREAM_SLO_TOL)"; exit 2; }
  SSTOL=$STREAM_SLO_TOL
  echo "BLOCK PLAN: slo search: --tol $SSTOL (STREAM_SLO_TOL; default 0.02)"
fi
#   STREAM_DRAIN_FULL_S (user 2026-11-12 "harness에 drain을 넣어야 할거같아"; lib.sh rs_env from the conf's RS_DRAIN_FULL_S):
#     loadgen --drain-full-s of the BLOCK=stream SLO search (stream_slo) only, whole seconds in [1, 600]; unset / empty
#     = not passed (every earlier run: a step drains at most --drain-s 5 s, the next step may start on a backlog).
#     Set: after each step loadgen waits until no request is outstanding (at most S s); a step that still starts on a
#     backlog is not judged and is run once more (experiments/loadgen/README.md "Full drain"). Recommended 120.
SSDRAIN=()
if [ -n "${STREAM_DRAIN_FULL_S:-}" ]; then
  [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: STREAM_DRAIN_FULL_S needs BLOCK=stream and EVAL_RUN"; exit 2; }
  [[ $STREAM_DRAIN_FULL_S =~ ^[1-9][0-9]*$ ]] && [ "$STREAM_DRAIN_FULL_S" -le 600 ] \
    || { echo "SEQUENCE STOP: STREAM_DRAIN_FULL_S must be whole seconds in [1, 600] (got $STREAM_DRAIN_FULL_S)"; exit 2; }
  SSDRAIN=(--drain-full-s "$STREAM_DRAIN_FULL_S")
  echo "BLOCK PLAN: slo search: --drain-full-s $STREAM_DRAIN_FULL_S (STREAM_DRAIN_FULL_S; default not passed)"
fi
#   More stream SLO-search loadgen options (user 2026-11-12; lib.sh rs_env from the conf's RS_<X>); each unset / empty =
#     not passed (every earlier run: no drain failure, --confirm-rule majority, session.sh main profile 3 x 30 s):
#   STREAM_DRAIN_FAIL_S   --drain-fail-s D, seconds in (0, STREAM_DRAIN_FULL_S) (needs it); a step whose full drain
#                         took > D s fails as a non-latency failure (target 2.0)
#   STREAM_CONFIRM_RULE   --confirm-rule majority | pooled (target pooled)
#   STREAM_CONFIRM_REPS   --confirm-reps N, 1..12 (target 6)
#   STREAM_CONFIRM_S      --confirm-s S, whole seconds 5..120 (target 15)
#   STREAM_CONFIRM_FULL   1 = --confirm-full (confirm repeats never stop early on the SLO; target 1)
for v in STREAM_DRAIN_FAIL_S STREAM_CONFIRM_RULE STREAM_CONFIRM_REPS STREAM_CONFIRM_S STREAM_CONFIRM_FULL; do
  [ -z "${!v:-}" ] || { [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ]; } || { echo "SEQUENCE STOP: $v needs BLOCK=stream and EVAL_RUN"; exit 2; }
done
if [ -n "${STREAM_DRAIN_FAIL_S:-}" ]; then
  [ -n "${STREAM_DRAIN_FULL_S:-}" ] || { echo "SEQUENCE STOP: STREAM_DRAIN_FAIL_S needs STREAM_DRAIN_FULL_S"; exit 2; }
  [[ $STREAM_DRAIN_FAIL_S =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v d="$STREAM_DRAIN_FAIL_S" -v f="$STREAM_DRAIN_FULL_S" 'BEGIN { exit !(d > 0 && d < f) }' \
    || { echo "SEQUENCE STOP: STREAM_DRAIN_FAIL_S must be a number in (0, STREAM_DRAIN_FULL_S) (got $STREAM_DRAIN_FAIL_S)"; exit 2; }
  SSDRAIN+=(--drain-fail-s "$STREAM_DRAIN_FAIL_S")
  echo "BLOCK PLAN: slo search: --drain-fail-s $STREAM_DRAIN_FAIL_S (STREAM_DRAIN_FAIL_S; default not passed)"
fi
if [ -n "${STREAM_CONFIRM_RULE:-}" ]; then
  case $STREAM_CONFIRM_RULE in majority|pooled) ;; *) echo "SEQUENCE STOP: STREAM_CONFIRM_RULE must be majority or pooled (got $STREAM_CONFIRM_RULE)"; exit 2;; esac
  SSDRAIN+=(--confirm-rule "$STREAM_CONFIRM_RULE")
  echo "BLOCK PLAN: slo search: --confirm-rule $STREAM_CONFIRM_RULE (STREAM_CONFIRM_RULE; default majority)"
fi
if [ -n "${STREAM_CONFIRM_REPS:-}" ]; then
  [[ $STREAM_CONFIRM_REPS =~ ^[1-9][0-9]*$ ]] && [ "$STREAM_CONFIRM_REPS" -le 12 ] \
    || { echo "SEQUENCE STOP: STREAM_CONFIRM_REPS must be 1..12 (got $STREAM_CONFIRM_REPS)"; exit 2; }
  SSDRAIN+=(--confirm-reps "$STREAM_CONFIRM_REPS")
  echo "BLOCK PLAN: slo search: --confirm-reps $STREAM_CONFIRM_REPS (STREAM_CONFIRM_REPS; default 3)"
fi
if [ -n "${STREAM_CONFIRM_S:-}" ]; then
  [[ $STREAM_CONFIRM_S =~ ^[1-9][0-9]*$ ]] && [ "$STREAM_CONFIRM_S" -ge 5 ] && [ "$STREAM_CONFIRM_S" -le 120 ] \
    || { echo "SEQUENCE STOP: STREAM_CONFIRM_S must be whole seconds 5..120 (got $STREAM_CONFIRM_S)"; exit 2; }
  SSDRAIN+=(--confirm-s "$STREAM_CONFIRM_S")
  echo "BLOCK PLAN: slo search: --confirm-s $STREAM_CONFIRM_S (STREAM_CONFIRM_S; default 30)"
fi
if [ -n "${STREAM_CONFIRM_FULL:-}" ]; then
  [ "$STREAM_CONFIRM_FULL" = 1 ] || { echo "SEQUENCE STOP: STREAM_CONFIRM_FULL must be 1 or unset (got $STREAM_CONFIRM_FULL)"; exit 2; }
  SSDRAIN+=(--confirm-full)
  echo "BLOCK PLAN: slo search: --confirm-full (STREAM_CONFIRM_FULL; default not passed)"
fi
#   Knee-dense sweep (user 2026-11-13 "knee point 부근에서 RPS를 더 촘촘히"; lib.sh rs_env from the conf's RS_SLO_START /
#     RS_SLO_FILL / RS_SLO_OVERLOAD); each unset / empty = the stream_slo loadgen command line of every earlier run:
#   STREAM_SLO_START      --start X of the SLO search (q/s, a number in (0, 100]; unset = 1)
#   STREAM_SLO_FILL       --fill f1,f2,.. (each in (0, 1), at most 6; points at the result x f); unset = not passed
#                         (loadgen default 0.7,0.8,0.9)
#   STREAM_SLO_OVERLOAD   --overload-base result --overload f1,f2,.. (each in (1, 3], at most 7; points at the result
#                         x f); unset = not passed (loadgen default: first failed rate above the result x 1.05,1.1,1.2)
#   Fill and overload points run after the confirm phase, each a full step (min-step-queries, full drain when
#   STREAM_DRAIN_FULL_S is set); they never change the result (experiments/loadgen/README.md "Past-the-knee rule").
SSSTART=1 SSKNEE=()
for v in STREAM_SLO_START STREAM_SLO_FILL STREAM_SLO_OVERLOAD; do
  [ -z "${!v:-}" ] || { [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ]; } || { echo "SEQUENCE STOP: $v needs BLOCK=stream and EVAL_RUN"; exit 2; }
done
if [ -n "${STREAM_SLO_START:-}" ]; then
  [[ $STREAM_SLO_START =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v s="$STREAM_SLO_START" 'BEGIN { exit !(s > 0 && s <= 100) }' \
    || { echo "SEQUENCE STOP: STREAM_SLO_START must be a number in (0, 100] q/s (got $STREAM_SLO_START)"; exit 2; }
  SSSTART=$STREAM_SLO_START
  echo "BLOCK PLAN: slo search: --start $SSSTART (STREAM_SLO_START; default 1)"
fi
fac_list() {  # <list> <lo> <hi> <max n>: comma-separated numbers, each in (lo, hi], at most n, strictly increasing
  [[ $1 =~ ^[0-9]*\.?[0-9]+(,[0-9]*\.?[0-9]+)*$ ]] || return 1
  awk -v l="$1" -v lo="$2" -v hi="$3" -v m="$4" 'BEGIN { n = split(l, a, ","); if (n > m) exit 1
    for (i = 1; i <= n; i++) { if (!(a[i] + 0 > lo && a[i] + 0 <= hi)) exit 1; if (i > 1 && !(a[i] + 0 > a[i - 1] + 0)) exit 1 } }'; }
if [ -n "${STREAM_SLO_FILL:-}" ]; then
  fac_list "$STREAM_SLO_FILL" 0 0.999999 6 \
    || { echo "SEQUENCE STOP: STREAM_SLO_FILL must be increasing factors in (0, 1), at most 6, comma-separated (got $STREAM_SLO_FILL)"; exit 2; }
  SSKNEE+=(--fill "$STREAM_SLO_FILL")
  echo "BLOCK PLAN: slo search: --fill $STREAM_SLO_FILL (STREAM_SLO_FILL; default not passed)"
fi
if [ -n "${STREAM_SLO_OVERLOAD:-}" ]; then
  fac_list "$STREAM_SLO_OVERLOAD" 1 3 7 \
    || { echo "SEQUENCE STOP: STREAM_SLO_OVERLOAD must be increasing factors in (1, 3], at most 7, comma-separated (got $STREAM_SLO_OVERLOAD)"; exit 2; }
  SSKNEE+=(--overload-base result --overload "$STREAM_SLO_OVERLOAD")
  echo "BLOCK PLAN: slo search: --overload-base result --overload $STREAM_SLO_OVERLOAD (STREAM_SLO_OVERLOAD; default not passed)"
fi
# Publication period T (H1 v0.6.9, user decision 2026-10-18 "T=1로 바로 가는게 좋아보여"): RS_T_MS = the updater's
# --publish-ms. Default 60000 (every earlier block, unchanged). BLOCK=h1 requires it explicitly (pins-recsys.sh).
# The Ekko operating point is defined at the reference T = 60 s and is an UPDATE SAMPLE RATE: EKKO_FRAC60 of all rows
# published per 60 s round -> recsys-rate (--t-ms 60000, 20 windows, checked against D/rate-frac<EKKO_FRAC60>.txt)
# gives the loadgen update rate (avg 14.7233, peak 188.7608 samples/s). With RS_T_MS != 60000 the SAME sample rate is
# replayed and only the round length changes; the server's --publish-frac (rows_per_round_target, used by v1_check's
# +-15 % window check) is the T-specific calibration RATE_T_DIR/rate-T<RS_T_MS>-<point>.txt (recsys-rate at that T,
# integer target whose rate is closest to the T = 60 s rate; builds/recsys-calib/1 for T = 1 s). Shorter T coalesces
# fewer row updates: at T = 1 s peak publishes 19,192 rows per round (1.15 M rows / 60 s vs 0.58 M at T = 60 s).
T_MS=${RS_T_MS:-60000}
[[ $T_MS =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad RS_T_MS"; exit 2; }
[ $BLOCK != stream ] || T_MS=0   # streaming: no publication period (--publish-ms 0 --update-mode stream)
if [ $BLOCK = h1 ] && [ -z "${RS_T_MS:-}" ]; then echo "SEQUENCE STOP: BLOCK=h1 needs RS_T_MS (pins-recsys.sh)"; exit 2; fi
if [ "$T_MS" != 60000 ] && [ $BLOCK != stream ]; then
  [ $BLOCK != main ] || { echo "SEQUENCE STOP: RS_T_MS != 60000 only with BLOCK v1 or h1"; exit 2; }
  [ -d "${RATE_T_DIR:-}" ] || { echo "SEQUENCE STOP: RS_T_MS=$T_MS needs RATE_T_DIR (T-specific calibration dir)"; exit 2; }
fi
calv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }   # calv <file> <key>
# v0.6.10 (user decision 2026-10-18, "3점 등비"): three intermediate points between Ekko avg and peak, geometric in the
# rows fraction per 60 s (ratio (0.0043 / 0.000513333333)^(1/4) = 1.701, rounded to 3 significant digits):
# f087 = 0.000874, f149 = 0.00149, f253 = 0.00253. Same definition as avg/peak (update SAMPLE RATE calibrated at
# T = 60 s by recsys-rate); their T = 60 s reference files are in RATE_T_DIR (builds/recsys-calib/2), not in D.
# EKKO_REF = the T = 60 s reference file of the point (rate_for checks the computed rate against it, +-2 %).
ekko_set() {  # <avg|peak|f087|f149|f253|f330|f350|f370|f400|f385|f392>: EKKO_FRAC60, EKKO_REF, PUBLISH_FRAC (server; = EKKO_FRAC60 at T = 60 s), EKKO_RULE, SA
  local mid="geometric point between Ekko avg (0.0308/60) and peak (0.043/10) per T = 60 s (user 2026-10-18)"
  local v12="v0.6.12 (user 2026-10-19: update rate where Popcorn/All-HWcc max under SLO falls to 0.7-0.8): rows per T = 60 s between f330 and Ekko peak"
  case $1 in
    avg) EKKO_FRAC60=0.000513333333; EKKO_RULE="Ekko OSDI'22 average: 3.08% of rows per hour -> 0.0308/60 per T = 60 s";;
    peak) EKKO_FRAC60=0.0043; EKKO_RULE="Ekko OSDI'22 peak: 4.3% of rows per 10 min -> 0.043/10 per T = 60 s";;
    f087) EKKO_FRAC60=0.000874; EKKO_RULE="$mid: 1/4 -> 0.000874";;
    f149) EKKO_FRAC60=0.00149; EKKO_RULE="$mid: 2/4 -> 0.00149";;
    f253) EKKO_FRAC60=0.00253; EKKO_RULE="$mid: 3/4 -> 0.00253";;
    f330) EKKO_FRAC60=0.0033; EKKO_RULE="v0.6.11 (user 2026-10-18): geometric mean of f253 (0.00253) and Ekko peak (0.0043) per T = 60 s -> 0.0033";;
    f350) EKKO_FRAC60=0.0035; EKKO_RULE="$v12 -> 0.0035";;
    f370) EKKO_FRAC60=0.0037; EKKO_RULE="$v12 -> 0.0037";;
    f400) EKKO_FRAC60=0.004; EKKO_RULE="$v12 -> 0.004";;
    f385) EKKO_FRAC60=0.00385; EKKO_RULE="v0.6.13 (user 2026-10-19: update rate where Popcorn/All-HWcc max under SLO falls to 0.2-0.3): rows per T = 60 s between f370 and f400 -> 0.00385";;
    f392) EKKO_FRAC60=0.00392; EKKO_RULE="v0.6.14 (user 2026-10-19: update rate where Popcorn/All-HWcc max under SLO falls to 0.2-0.3): rows per T = 60 s between f385 and f400 -> 0.00392";;
    *) return 1;;
  esac
  case $1 in
    avg|peak) EKKO_REF=$D/rate-frac$EKKO_FRAC60.txt;;
    *) [ -d "${RATE_T_DIR:-}" ] || { echo "SEQUENCE STOP: Ekko point $1 needs RATE_T_DIR (its T = 60 s reference file)"; return 1; }
       EKKO_REF=$RATE_T_DIR/rate-frac$EKKO_FRAC60.txt;;
  esac
  PUBLISH_FRAC=$EKKO_FRAC60 RATE_TF=
  if [ "$T_MS" != 60000 ]; then
    RATE_TF=$RATE_T_DIR/rate-T$T_MS-$1.txt
    PUBLISH_FRAC=$(calv "$RATE_TF" publish_frac_arg)
    [ -n "$PUBLISH_FRAC" ] && [ "$(calv "$RATE_TF" ref_frac)" = "$EKKO_FRAC60" ] && [ "$(calv "$RATE_TF" t_ms)" = "$T_MS.000" ] \
      || { echo "SEQUENCE STOP: $RATE_TF missing or not the T = $T_MS ms calibration of Ekko $1"; return 1; }
    EKKO_RULE="$EKKO_RULE; same update sample rate at T = $T_MS ms (rows_per_round_target $(calv "$RATE_TF" rows_per_round_target), $RATE_TF)"
  fi
  SA="--nodes 2 --row-div 1 --serve-threads 14 --update-threads 4 --load-threads 8 --start-timeout-ms $((XT * 1000 / 2)) --publish-frac $PUBLISH_FRAC
 --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
  SA=$(echo $SA)
}
# BLOCK=stream: server arguments of every node (the updater node adds N0X: 14 update threads = node 1's serving
# threads, 1 serving thread, so 1 + 8 + 14 + 1 = 24 Megalon registrations on each node; node 1 has 1 update thread;
# EVAL_RUN with RS_THREADS=16: 1 + 8 + 16 + 1 = 26 per node, limit 32 per process (workloads/recsys/DESIGN.md))
N0X=""
if [ $BLOCK = stream ]; then
  SA="--nodes 2 --row-div 1 --serve-threads 14 --update-threads 1 --load-threads 8 --start-timeout-ms $((XT * 1000 / 2)) --update-mode stream
 --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
  SA=$(echo $SA) N0X="--update-threads 14 --serve-threads 1"
  if [ -n "${EVAL_RUN:-}" ]; then  # threads = vCPUs (user 2026-10-20): node 0 RS_THREADS update threads, node 1 RS_THREADS serving
    SA=${SA/--serve-threads 14/--serve-threads $RS_THREADS} N0X="--update-threads $RS_THREADS --serve-threads 1"
    # STREAM_PROC_CXL_SHM=1 (experiments/eval recv-sleep.conf RS_PROC_CXL_SHM): per-step snapshots also of the
    # cxl_shm receive counters (sleep_wakeups, tick_kicks, ...: /sys/kernel/cxl_shm, as the vector DB server always does)
    case ${STREAM_PROC_CXL_SHM:-0} in 0) ;; 1) SA="$SA --proc-sysfs /sys/kernel/cxl_shm";;
      *) echo "SEQUENCE STOP: bad STREAM_PROC_CXL_SHM"; exit 2;; esac
  elif [ -n "${STREAM_PROC_CXL_SHM:-}" ]; then echo "SEQUENCE STOP: STREAM_PROC_CXL_SHM needs EVAL_RUN"; exit 2
  fi
fi
# ---- RecSys v7 (V7=1, BLOCK=stream + EVAL_RUN only; workloads/recsys/DESIGN.md §10.6, experiment doc §R): trained
# checkpoint image + dense weights, node 0 trains online (--update-mode train, row-wise Adagrad, test-then-train),
# the loadgen draws queries from the update trace ahead of the update position (prequential=1, window V7_W_S x rate)
# and logs (score, label); both servers log sampled row reads/writes for the stale-read fraction / age.
# Keys (lib.sh rs_env from the conf's RS_V7_*): V7_IMAGE / V7_DENSE (guest paths), V7_LR, V7_ACC_INIT, V7_TRAIN_BATCH,
# V7_TRAIN_THREADS (0 = update threads), V7_W_S, V7_STALE_SAMPLE, V7_STALE_DIR (guest dir of the stale logs),
# V7_SAMPLES (Host v3 samples file with labels: updates and queries), V7_FROZEN (Host frozen scores of the same trace),
# V7_IMAGE_HOST / V7_DENSE_HOST (Host copies of V7_IMAGE / V7_DENSE, for the Host --print-app-bytes / --print-layout).
# The literal @USER@ in V7_LR / V7_ACC_INIT / V7_TRAIN_BATCH / V7_W_S = not decided by the user: a dry start plans with
# the server defaults and says so (BLOCK DRY NOTE); a real run stops.
V7=${V7:-0} V7PEND="" V7T=$(cd "$X/../../workloads/recsys/tools" && pwd)
case $V7 in 0) ;; 1)
  [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: V7=1 needs BLOCK=stream and EVAL_RUN"; exit 2; }
  for v in V7_IMAGE V7_DENSE V7_LR V7_ACC_INIT V7_TRAIN_BATCH V7_W_S V7_STALE_SAMPLE V7_STALE_DIR V7_SAMPLES V7_FROZEN; do
    [ -n "${!v:-}" ] || { echo "SEQUENCE STOP: V7=1 needs $v"; exit 2; }
  done
  for v in V7_LR V7_ACC_INIT V7_TRAIN_BATCH V7_W_S; do [ "${!v}" != @USER@ ] || V7PEND="$V7PEND $v"; done
  if [ -n "$V7PEND" ]; then
    echo "BLOCK DRY NOTE: v7 parameters not decided by the user:$V7PEND (dry start plans with the server defaults lr 0.004, acc_init image, batch 8, W 60 s)"
    [ "$V7_LR" != @USER@ ] || V7_LR=0.004; [ "$V7_ACC_INIT" != @USER@ ] || V7_ACC_INIT=-1
    [ "$V7_TRAIN_BATCH" != @USER@ ] || V7_TRAIN_BATCH=8; [ "$V7_W_S" != @USER@ ] || V7_W_S=60
  fi
  [[ $V7_TRAIN_BATCH =~ ^[1-9][0-9]*$ && $V7_STALE_SAMPLE =~ ^[1-9][0-9]*$ && ${V7_TRAIN_THREADS:-0} =~ ^[0-9]+$ ]] \
    || { echo "SEQUENCE STOP: bad V7_TRAIN_BATCH / V7_STALE_SAMPLE / V7_TRAIN_THREADS"; exit 2; }
  [[ $V7_STALE_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "SEQUENCE STOP: bad V7_STALE_DIR"; exit 2; }
  [ -f "$V7_SAMPLES" ] && [ -f "$V7_FROZEN" ] || { echo "SEQUENCE STOP: V7_SAMPLES / V7_FROZEN missing on the Host"; exit 2; }
  # Host copies of the guest image / dense files: session.sh runs the Host recsys-server (--print-app-bytes /
  # --print-layout read the image header) with these paths substituted for the guest paths (HOST_PATH_MAP)
  for v in V7_IMAGE_HOST V7_DENSE_HOST; do
    [ -n "${!v:-}" ] || { echo "SEQUENCE STOP: V7=1 needs $v"; exit 2; }
    [ -f "${!v}" ] || { echo "SEQUENCE STOP: $v ${!v} missing on the Host"; exit 2; }
  done
  [[ "$V7_IMAGE $V7_DENSE $V7_IMAGE_HOST $V7_DENSE_HOST" =~ ^[A-Za-z0-9._/-]+\ [A-Za-z0-9._/-]+\ [A-Za-z0-9._/-]+\ [A-Za-z0-9._/-]+$ ]] \
    || { echo "SEQUENCE STOP: V7 image / dense paths must not contain spaces or '='"; exit 2; }
  V7_HOST_PATH_MAP="$V7_IMAGE=$V7_IMAGE_HOST $V7_DENSE=$V7_DENSE_HOST"
  SA="${SA/--update-mode stream/--update-mode train} --image $V7_IMAGE --model-dense $V7_DENSE --lr $V7_LR --acc-init $V7_ACC_INIT --train-batch $V7_TRAIN_BATCH --train-threads ${V7_TRAIN_THREADS:-0} --stale-sample $V7_STALE_SAMPLE"
  # recsys-training-auc: V7_STORE rn | sr (lib.sh RS_V7_STORE) = server --store; unset = not passed (rn, every earlier run)
  if [ -n "${V7_STORE:-}" ]; then
    [[ $V7_STORE =~ ^(rn|sr)$ ]] || { echo "SEQUENCE STOP: bad V7_STORE ($V7_STORE: rn | sr)"; exit 2; }
    SA="$SA --store $V7_STORE"
    echo "BLOCK PLAN: v7 row store: --store $V7_STORE on every node (fp16 $([ "$V7_STORE" = sr ] && echo "stochastic rounding" || echo "round-to-nearest"))"
  fi
  ;; *) echo "SEQUENCE STOP: bad V7 ($V7)"; exit 2;; esac
[ "$V7" = 1 ] || [ -z "${V7_STORE:-}" ] || { echo "SEQUENCE STOP: V7_STORE needs V7=1"; exit 2; }
# ---- windowed update publication (reports/experiments/recsys-windowed-update.md; V7=1 only; lib.sh rs_env from the
# conf's RS_PUBLISH_*): PUBLISH_WINDOW_S = W (server --publish-window-s, both nodes; the server enables it on node 0
# only; unset / 0 = off = per-batch write-through, every earlier run), PUBLISH_DRAM_ROWS (optional, server
# --publish-dram-rows), PUBLISH_WARMUP 1 (default with W > 0) | 0: every lifetime starts with part "pubtrain" = the
# update stream alone (loadgen --rates 0: no queries) for W + PUBLISH_TRAIN_SLACK_S (5) s, so the first window is
# training only; node 0's post-part snapshot must show publish_started=1 (else stop). Every later part keeps the update
# stream running (seq_base continues), so training goes on while the publisher writes. PUBLISH_AFTER_S (60): the SLO
# search starts no earlier than this many seconds (server clock: stats_mono_ns - publish_start_mono_ns of node 0's
# snapshot after the 1 q/s warm-up part) after publishing started; the warm-up part (60 s with updates) normally covers
# it, a shortfall is slept (logged).
PUBW=${PUBLISH_WINDOW_S:-0} PUBWU=${PUBLISH_WARMUP:-1} PUBAFT=${PUBLISH_AFTER_S:-60} PUBSL=${PUBLISH_TRAIN_SLACK_S:-5}
[[ $PUBW =~ ^(0|[1-9][0-9]*)$ && $PUBWU =~ ^[01]$ && $PUBAFT =~ ^(0|[1-9][0-9]*)$ && $PUBSL =~ ^[1-9][0-9]*$ ]] \
  || { echo "SEQUENCE STOP: bad PUBLISH_WINDOW_S / PUBLISH_WARMUP / PUBLISH_AFTER_S / PUBLISH_TRAIN_SLACK_S"; exit 2; }
if [ "$PUBW" != 0 ]; then
  [ "$V7" = 1 ] || { echo "SEQUENCE STOP: PUBLISH_WINDOW_S needs V7=1 (train mode)"; exit 2; }
  SA="$SA --publish-window-s $PUBW"
  if [ -n "${PUBLISH_DRAM_ROWS:-}" ]; then
    [[ $PUBLISH_DRAM_ROWS =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad PUBLISH_DRAM_ROWS"; exit 2; }
    SA="$SA --publish-dram-rows $PUBLISH_DRAM_ROWS"
  fi
  echo "BLOCK PLAN: windowed publication W=$PUBW s (dram rows ${PUBLISH_DRAM_ROWS:-default}); warmup=$PUBWU: part pubtrain = updates only $((PUBW + PUBSL)) s, then publish_started=1, SLO search >= $PUBAFT s after publishing started"
elif [ -n "${PUBLISH_DRAM_ROWS:-}" ]; then echo "SEQUENCE STOP: PUBLISH_DRAM_ROWS without PUBLISH_WINDOW_S"; exit 2
fi
# ---- U0 (recsys-amx-2way widening 2026-11-17, "u0로 hw, pop, ds 측정해봐"): STREAM_RATES entry 0 = serving with NO
# update samples: same servers and args (train mode, windowed publication W, split, mlp), loadgen --fixed update=0 (the
# loadgen never schedules a stream of rate 0). Prequential queries need a window size that does not come from the rate:
# STREAM_U0_QWIN_SAMPLES N (required with a 0 entry; --opt query_window_samples=N instead of update_rate; the update
# position stays at seq_base 0, so queries draw from trace positions [0, N)). The server's window 0 starts at the first
# update sample, so at u0 the publisher never starts: part pubtrain is replaced by an idle wait of the same length
# (W + PUBLISH_TRAIN_SLACK_S; no loadgen: a step with every rate 0 ends at once) and the PUBLISH_AFTER_S wait is skipped.
# Zero row writes: stream_check.py rates a step with update offered 0 valid only if node 0 accepted, wrote and
# published nothing (update_accepted_seq, published_seq, rows_written, published_rows deltas 0), and life_stop checks
# node 0's final counters samples=0 rows_written=0 published_rows=0 (u0-check-<name>.txt; else stop). Unset / no 0
# entry = nothing here is used (every earlier run unchanged). Not with STREAM_ONE_LIFETIME or STREAM_PMAX.
U0QW=${STREAM_U0_QWIN_SAMPLES:-} U0=0
if [[ " ${STREAM_RATES:-} " == *" 0 "* ]]; then
  [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] && [ "$V7" = 1 ] || { echo "SEQUENCE STOP: STREAM_RATES 0 (u0) needs BLOCK=stream, EVAL_RUN and V7=1"; exit 2; }
  [[ $U0QW =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: STREAM_RATES 0 (u0) needs STREAM_U0_QWIN_SAMPLES (query window in samples, >= 1; got '$U0QW')"; exit 2; }
  [ "${STREAM_ONE_LIFETIME:-0}" = 0 ] && [ "${STREAM_PMAX:-0}" = 0 ] || { echo "SEQUENCE STOP: STREAM_RATES 0 (u0) takes no STREAM_ONE_LIFETIME / STREAM_PMAX"; exit 2; }
  echo "BLOCK PLAN: u0: no update samples (loadgen --fixed update=0), prequential query window $U0QW samples from trace position 0 (STREAM_U0_QWIN_SAMPLES); $([ "$PUBW" != 0 ] && [ "$PUBWU" = 1 ] && echo "pubtrain = idle wait $((PUBW + PUBSL)) s (publisher never starts), no PUBLISH_AFTER_S wait; ")zero row writes checked per step (stream_check.py) and per lifetime (node 0 samples=0 rows_written=0 published_rows=0)"
elif [ -n "$U0QW" ]; then echo "SEQUENCE STOP: STREAM_U0_QWIN_SAMPLES without a STREAM_RATES entry 0"; exit 2
fi
# ---- one mg lifetime for all rates (header "STREAM_ONE_LIFETIME"); 0 / unset = nothing below is used
ONEL=${STREAM_ONE_LIFETIME:-0} OLSET=${STREAM_SETTLE_S:-} OL_STALE= OL_N=0 OL_S0= OL_NAME0= OL_T0=0 OL_DIRS=
case $ONEL in
  0) [ -z "$OLSET" ] || { echo "SEQUENCE STOP: STREAM_SETTLE_S without STREAM_ONE_LIFETIME=1"; exit 2; };;
  1) [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: STREAM_ONE_LIFETIME=1 needs BLOCK=stream and EVAL_RUN"; exit 2; }
     [ "${SYSTEMS:-}" = mg ] || { echo "SEQUENCE STOP: STREAM_ONE_LIFETIME=1 is for SYSTEMS=mg only (got '${SYSTEMS:-}')"; exit 2; }
     [ -z "${STREAM_FIXONLY:-}${STREAM_FIX_LEVELS:-}${STREAM_FIX_LEVELS_MAP:-}${STREAM_LEVELS:-}${STREAM_AUC:-}" ] \
       || { echo "SEQUENCE STOP: STREAM_ONE_LIFETIME=1 takes no fixed-load / AUC windows (SLO parts only)"; exit 2; }
     [ "$V7" = 1 ] && [ "$PUBW" != 0 ] && [ "$PUBWU" = 1 ] || { echo "SEQUENCE STOP: STREAM_ONE_LIFETIME=1 needs V7=1, PUBLISH_WINDOW_S > 0 and PUBLISH_WARMUP=1"; exit 2; }
     [[ $OLSET =~ ^[1-9][0-9]*$ ]] && [ "$OLSET" -ge $((2 * PUBW)) ] || { echo "SEQUENCE STOP: STREAM_ONE_LIFETIME=1 needs STREAM_SETTLE_S >= 2 x PUBLISH_WINDOW_S = $((2 * PUBW)) s (got '$OLSET')"; exit 2; }
     echo "BLOCK PLAN: one lifetime: rates [$STREAM_RATES] in one mg server lifetime (one load, XT $XT s); first rate: pubtrain $((PUBW + PUBSL)) s + warmup + slo; each later rate: settle $OLSET s at the new rate (update stream only, no queries; accepted rate checked) + warmup + slo";;
  *) echo "SEQUENCE STOP: bad STREAM_ONE_LIFETIME ($ONEL: 0 | 1)"; exit 2;;
esac
# ---- serving split (reports/experiments/recsys-serving-split.md): CHUNK_PAIRS N = server --chunk-pairs N on every node
# (700 = the largest query of tools/dist_quantile.txt: one serving thread per query); unset / empty = not passed
CHUNKP=${CHUNK_PAIRS:-}
if [ -n "$CHUNKP" ]; then
  [ $BLOCK = stream ] || { echo "SEQUENCE STOP: CHUNK_PAIRS needs BLOCK=stream"; exit 2; }
  [[ $CHUNKP =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad CHUNK_PAIRS ($CHUNKP: pairs per serving task, >= 1)"; exit 2; }
  SA="$SA --chunk-pairs $CHUNKP"
  echo "BLOCK PLAN: serving split: --chunk-pairs $CHUNKP on every node (queries of up to $CHUNKP pairs = one serving thread each)"
fi
# 2-way split (user 2026-11-13): SPLIT_WAYS K = server --split-ways K, MIN_CHUNK M = server --min-chunk M on every node
# (adaptive chunk = max(M, ceil(pairs / K)); K unset = divide by --serve-threads); unset / empty = not passed
SPLITW=${SPLIT_WAYS:-} MINCH=${MIN_CHUNK:-}
if [ -n "$SPLITW$MINCH" ]; then
  [ $BLOCK = stream ] || { echo "SEQUENCE STOP: SPLIT_WAYS / MIN_CHUNK need BLOCK=stream"; exit 2; }
  [ -z "$CHUNKP" ] || { echo "SEQUENCE STOP: SPLIT_WAYS / MIN_CHUNK with CHUNK_PAIRS (a fixed chunk ignores the adaptive split)"; exit 2; }
  if [ -n "$SPLITW" ]; then
    [[ $SPLITW =~ ^[1-9][0-9]*$ ]] && [ "$SPLITW" -le 32 ] || { echo "SEQUENCE STOP: bad SPLIT_WAYS ($SPLITW: ways per query, 1..32)"; exit 2; }
    SA="$SA --split-ways $SPLITW"
  fi
  if [ -n "$MINCH" ]; then
    [[ $MINCH =~ ^[1-9][0-9]*$ ]] && [ "$MINCH" -le 100000 ] || { echo "SEQUENCE STOP: bad MIN_CHUNK ($MINCH: pairs, 1..100000)"; exit 2; }
    SA="$SA --min-chunk $MINCH"
  fi
  echo "BLOCK PLAN: serving split: ${SPLITW:+--split-ways $SPLITW }${MINCH:+--min-chunk $MINCH }on every node (chunk = max(${MINCH:-16}, ceil(pairs / ${SPLITW:-serve threads})))"
fi
# recsys-amx-2way: MLP amx (lib.sh rs_env from RS_MLP) = server --mlp amx on every node of every system (bf16 AMX
# tiles, fp32 accumulate; serving forward only); unset / empty = not passed (avx512, every earlier run byte for byte)
case ${MLP:-} in
  "") ;;
  amx) [ $BLOCK = stream ] || { echo "SEQUENCE STOP: MLP needs BLOCK=stream"; exit 2; }
    SA="$SA --mlp amx"
    echo "BLOCK PLAN: serving mlp: --mlp amx on every node (bf16 AMX tiles, fp32 accumulate; serving forward only)";;
  *) echo "SEQUENCE STOP: bad MLP (${MLP}: amx or unset)"; exit 2;; esac
[ $BLOCK != stream ] || echo "BLOCK PLAN: server args: $SA"
pub_train() {  # every lifetime (life_start, BLOCK=stream): first window = training only (no queries, no publish)
  [ "$PUBW" != 0 ] && [ "$PUBWU" = 1 ] || return 0
  local rc ps
  if [ "$U0" = 1 ]; then  # u0 (header "U0"): no update sample, so no window and no loadgen part; same wall time idle
    echo "$(date -Is) $NAME: u0: idle $((PUBW + PUBSL)) s in place of part pubtrain (no update samples: the publisher does not start)"
    sleep $((PUBW + PUBSL)); return 0
  fi
  measure "$LS" pubtrain "${LGC[@]}" --opt seed=$((SEED + 101)) --seed $((SEED + 101)) --mode fixed --rates 0 \
    --warmup-s 0 --step-warmup-s 0 --step-measure-s $((PUBW + PUBSL)) --drain-s 2
  rc=$?; [ $rc = 0 ] || stop "$NAME pubtrain rc $rc"
  ps=$(sed -n 's/^publish_started=//p' "$LS/pubtrain/post-t0.txt" 2>/dev/null | tail -1)
  [ "$ps" = 1 ] || stop "$NAME pubtrain: node 0 publish_started=${ps:-missing} after $((PUBW + PUBSL)) s of updates"
  echo "$(date -Is) $NAME: publishing started (window $PUBW s; $(grep -m1 '^window_distinct=' "$LS/pubtrain/post-t0.txt"))"
}
pub_after() {  # <part dir with post-t0.txt>: sleep until PUBLISH_AFTER_S have passed since publishing started
  [ "$PUBW" != 0 ] && [ "$PUBWU" = 1 ] || return 0
  [ "$U0" = 0 ] || return 0   # u0: publishing never starts (no update sample)
  local m s since
  m=$(sed -n 's/^stats_mono_ns=//p' "$1/post-t0.txt" | tail -1); s=$(sed -n 's/^publish_start_mono_ns=//p' "$1/post-t0.txt" | tail -1)
  [[ $m =~ ^[0-9]+$ && $s =~ ^[1-9][0-9]*$ ]] || stop "$NAME: node 0 stats_mono_ns / publish_start_mono_ns missing in $1/post-t0.txt"
  since=$(( (m - s) / 1000000000 ))
  if [ $since -lt "$PUBAFT" ]; then
    echo "$(date -Is) $NAME: publishing started ${since} s ago (< $PUBAFT s): sleeping $((PUBAFT - since)) s before the SLO search"
    sleep $((PUBAFT - since))
  fi
}
v7_lgc() {  # <rate>: v7 loadgen options (appended to LGC; later --opt values win)
  [ "$V7" = 1 ] || return 0
  # no --opt seq_base / wrap here: session.sh measure appends seq_base=<last update seq> and wrap=1 itself and refuses
  # both from the caller (exit 2, "seq_base/wrap are set by session.sh"; same fix as 4447b2f53 for the v6 LGC)
  LGC=(--opt samples=$V7_SAMPLES --opt queries=$V7_SAMPLES --opt quantiles=$D/dist_quantile.txt --fixed update=$1 --mix query=1
       --x-stream query --opt prequential=1 --opt update_rate=$1 --opt query_window_s=$V7_W_S)
  # u0 (header "U0"): window size from STREAM_U0_QWIN_SAMPLES (query_window_s x 0 = 0 samples is refused by the plugin)
  [ "$1" != 0 ] || LGC=(--opt samples=$V7_SAMPLES --opt queries=$V7_SAMPLES --opt quantiles=$D/dist_quantile.txt --fixed update=0 --mix query=1
       --x-stream query --opt prequential=1 --opt query_window_samples=$U0QW)
}
u0_check() {  # u0 lifetime end (life_stop): node 0 accepted / wrote / published no row over the whole lifetime
  [ "$U0" = 1 ] || return 0
  local f=$E/u0-check-$NAME.txt k v bad=
  for k in samples rows_written published_rows; do
    v=$(sed -n "s/^$k=//p" "$LS/node0.log" 2>/dev/null | tail -1)
    echo "node0 $k=${v:-missing}" >> "$f"
    [ "$v" = 0 ] || bad+=" $k=${v:-missing}"
  done
  v=$(sed -n 's/^rows_written=//p' "$LS/node1.log" 2>/dev/null | tail -1); echo "node1 rows_written=${v:-missing}" >> "$f"
  [ "$v" = 0 ] || bad+=" node1.rows_written=${v:-missing}"
  [ -z "$bad" ] || stop "$NAME: u0 lifetime wrote rows:$bad ($f)"
  echo "U0 CHECK PASS $NAME: node 0 samples=0 rows_written=0 published_rows=0, node 1 rows_written=0" | tee -a "$f"
}
# <lifetime name> <node>: guest path, unique per evidence dir: the server creates it exclusively (FATAL "cannot create
# (exists?)"), and basename E alone ("block", "probe") repeats over retries (v<N>) and runs (rs-h1 v4: probe-mg-u50-fix-n0)
v7_stale() { echo "$V7_STALE_DIR/$(basename "$(dirname "$E")")-$(basename "$E")-$1-n$2.stl"; }
v7_post() {  # <sys> <rate> <part dir> [AUC csv, default <E>/auc_run.csv]: fetch both stale logs (guest v7_stale paths), then v7_metrics.py
  [ "$V7" = 1 ] || return 0
  local k f
  for k in 0 1; do
    f=$(v7_stale ${OL_STALE:-$NAME} $k)   # OL_STALE: the lifetime's name (STREAM_ONE_LIFETIME=1 only; else empty)
    if [ "${SESSION_LOCAL:-0}" = 1 ]; then cp "$f" "$3/stale-n$k.stl"
    else $SSH comsys@${IPS[$k]} "cat $f" < /dev/null > "$3/stale-n$k.stl"; fi || stop "$NAME: stale log n$k"
  done
  python3 -I -B $V7T/v7_metrics.py "$3" --stale0 "$3/stale-n0.stl" --stale1 "$3/stale-n1.stl" --frozen "$V7_FROZEN" \
    --trace-n "$(sed -n 's/^trace_samples=//p' "$3/loadgen/recsys.txt")" --steps-out "$3/v7-steps.csv" \
    --auc-run "${4:-$E/auc_run.csv}" --system "$1" --update-rate "$2" --T "${DST:-0}" --run "${EVAL_RUN:-1}" > "$3/v7-metrics.txt" 2>&1 \
    || stop "$NAME: v7_metrics.py ($(tail -1 "$3/v7-metrics.txt"))"
  [ ! -f "$3/steps.csv" ] || python3 -I -B $V7T/v7_metrics.py "$3" --stale0 "$3/stale-n0.stl" --stale1 "$3/stale-n1.stl" \
    --merge-steps "$3/steps.csv" > /dev/null 2>&1 || stop "$NAME: v7 steps.csv merge"
}
if [ $BLOCK != h1 ] && [ $BLOCK != stream ]; then ekko_set "$EKKO" || { echo "SEQUENCE STOP: EKKO must be avg, peak, f087, f149, f253, f330, f350, f370, f400, f385 or f392"; exit 2; }; fi
export SLO_MS SLO_RULE="DeepRecSys ISCA'20: query p${SLO_PCT} <= ${SLO_MS} ms ($SLO_SRC)"
HOST_PLAIN=$PLAIN_BUILD/bin/recsys-server
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="RECSYS-$BLOCK-$(basename "$E")"; [ $BLOCK = h1 ] && OWNER="H1-recsys-$H1MODE-r$H1_N"
# receiver (run 2, experiments/eval/recv-mode.sh): RECV_MODE poll | idle | sleep | adaptive (ds: no idle), POP_RECV_MODE
# (Popcorn lifetimes, default RECV_MODE), POP_ADAPT_KO (Popcorn adaptive module, sha256 = the bundle's KO_SHA),
# RECV_IPOLL (0 | 1, adaptive: ipoll written after the enable), RECV_WATCH_US / RECV_S_MAX_US (adaptive watch_us /
# s_max_us written after ipoll, read back; unset = 200 / 200); adaptive lifetimes add --proc-sysfs /sys/kernel/cxl_shm
# --proc-kthread cxl_ipoll (per-step adaptive counters, idle-poller CPU apart from cxl_recv) and write recv-post-<name>.txt
. "$X/../eval/recv-mode.sh"
. "$X/ds-replica.sh"   # replica_set / replica_post (De Stijl replica_mode all lifetimes only)
[[ $RECV_MODE =~ ^(poll|idle|sleep|adaptive)$ ]] || { echo "SEQUENCE STOP: bad RECV_MODE"; exit 2; }
PRM=${POP_RECV_MODE:-$RECV_MODE} IPOLL=${RECV_IPOLL:-} POPSV=- DSFP=0
[[ $IPOLL =~ ^[01]?$ ]] || { echo "SEQUENCE STOP: bad RECV_IPOLL"; exit 2; }
if [[ " ${SYSTEMS:-hw pop mg} " == *" pop "* ]]; then
  why=$(recv_rules pop "$PRM" "$C8" 2) || { echo "SEQUENCE STOP: Popcorn receiver: $why"; exit 2; }
  [ "$PRM" != adaptive ] && { [ "$PRM" != sleep ] || [ -z "${POP_ADAPT_KO:-}" ]; } || POPSV=$(recv_pop_srcversion)   # run 2 sleep 20/50: same module
fi
# RECV_WATCH_US / RECV_S_MAX_US (recv-mode.sh recv_wsm_check): bad values stop here; a non-adaptive pop / ds lifetime
# refuses them in recv_apply (the lifetime start; dry starts with a RECV_MODE=sleep stand-in conf stay possible)
why=$(recv_wsm_check); [ $? != 1 ] || { echo "SEQUENCE STOP: $why"; exit 2; }
[[ $ROUNDS =~ ^[1-9]$ ]] || { echo "SEQUENCE STOP: bad ROUNDS"; exit 2; }
# SYSTEMS (subset of "hw pop mg", default all): a rerun of some systems (the SLO is fixed; L for the fixed window
# comes from L_FROM). SLO_MS_FROM (v5) is not used: refused if set.
[ -z "${SLO_MS_FROM:-}" ] || { echo "SEQUENCE STOP: SLO_MS_FROM is a v5 option (v6 SLO is fixed)"; exit 2; }
for s in ${SYSTEMS:-hw pop mg}; do case $s in hw|pop|mg) ;; ds) [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ] || { echo "SEQUENCE STOP: ds only with BLOCK=stream and EVAL_RUN"; exit 2; };; mgoff|mgrow) [ $BLOCK = v1 ] || { [ $s = mgoff ] && [ $BLOCK = stream ] && [ -n "${EVAL_RUN:-}" ]; } || { echo "SEQUENCE STOP: $s only with BLOCK=v1 (mgoff also with BLOCK=stream and EVAL_RUN)"; exit 2; };; *) echo "SEQUENCE STOP: bad SYSTEMS entry $s"; exit 2;; esac; done
# Megalon object granularity (v1.4): MG_RPO_OPT N per Megalon system; mgrow needs the option
MG_RPO_OPT=${MG_RPO_OPT:-} MG_TABLE_N=${MG_TABLE_N:-0} MG_ROW_N=${MG_ROW_N:-1} V1_OPFAIL_CONTINUE=${V1_OPFAIL_CONTINUE:-}
[[ -z "$MG_RPO_OPT" || "$MG_RPO_OPT" =~ ^--[a-z][a-z0-9-]*$ ]] || { echo "SEQUENCE STOP: bad MG_RPO_OPT"; exit 2; }
[[ "$MG_TABLE_N" =~ ^[0-9]+$ && "$MG_ROW_N" =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: bad MG_TABLE_N / MG_ROW_N"; exit 2; }
MG_COH_SAMPLE=${MG_COH_SAMPLE:-}
[[ -z "$MG_COH_SAMPLE" || "$MG_COH_SAMPLE" =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad MG_COH_SAMPLE"; exit 2; }
MGSE=${MG_COH_SAMPLE:+ ENV:MEGALON_COH_CHECK_SAMPLE=$MG_COH_SAMPLE}      # Megalon node env addition
chk_args() { case $1 in mg|mgoff|mgrow) [ -z "$MG_COH_SAMPLE" ] || echo "--mg-sample $MG_COH_SAMPLE";; esac; }   # v1_check.py extra args
[[ " ${SYSTEMS:-} " != *" mgrow "* ]] || [ -n "$MG_RPO_OPT" ] || { echo "SEQUENCE STOP: mgrow needs MG_RPO_OPT"; exit 2; }
for s in $V1_OPFAIL_CONTINUE; do case $s in hw|pop|mg|mgoff|mgrow) ;; *) echo "SEQUENCE STOP: bad V1_OPFAIL_CONTINUE entry $s"; exit 2;; esac; done
[ -z "$V1_OPFAIL_CONTINUE" ] || [ $BLOCK = v1 ] || { echo "SEQUENCE STOP: V1_OPFAIL_CONTINUE only with BLOCK=v1"; exit 2; }
mg_rpo() { [ -z "$MG_RPO_OPT" ] || echo " $MG_RPO_OPT $1"; }   # <N> -> " <opt> N" or nothing
chk_sys() { case $1 in mgrow) echo mg;; *) echo $1;; esac; }   # system name for v1_check.py
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  [ "${FIXED:-1}" = 0 ] || [ -f "${L_FROM:-}" ] || { echo "SEQUENCE STOP: SYSTEMS without hw and FIXED=1 needs L_FROM=<fixed-load-L.txt>"; exit 2; }
fi
case $FIXED in 0|1) ;; *) echo "SEQUENCE STOP: bad FIXED"; exit 2;; esac
grep -q "^megalon_build=$MEGALON_BASE$" $MB/manifest.txt || { echo "SEQUENCE STOP: $MB is not on $MEGALON_BASE"; exit 2; }
[ -x "$HOST_PLAIN" ] && [ -x "$PLAIN_BUILD/bin/recsys-rate" ] || { echo "SEQUENCE STOP: $PLAIN_BUILD is not a v6 recsys build"; exit 2; }
# Popcorn deploy bundle (v6: build >= 10, swmc_acct per-thread accounting; path and packet hash from the Popcorn
# agent's verified bundle): POP_BUILD, POP_BUNDLE_SHA (sha256 of C8/packet.sha256). Build-8 bundles are refused.
POP_BUILD=${POP_BUILD:-10} POP_BUNDLE_SHA=${POP_BUNDLE_SHA:-626f6a0eb265553aaa6efb2d67c185497121e77b8ab0ece2243a461bd4f291c6}
# default: Popcorn build 10, builds/popcorn_new/10/deploy-v1 (release 6.14.0-famfs-de-stijl+-ds-popcorn-new-10;
# sha256 of its packet.sha256 recorded 2026-10-16)
[[ $POP_BUILD =~ ^[0-9]+$ ]] && [ "$POP_BUILD" -ge 10 ] || { echo "SEQUENCE STOP: POP_BUILD must be >= 10 (Fig 2 needs swmc_acct)"; exit 2; }
[ -d "$C8" ] && [ ! -e $C8/SUPERSEDED.txt ] \
  && [ "$(sha256sum < $C8/packet.sha256 | cut -d' ' -f1)" = "$POP_BUNDLE_SHA" ] \
  && (cd $C8 && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: C8 is not the verified Popcorn build-$POP_BUILD bundle"; exit 2; }
# De Stijl v2 (SYSTEMS entry ds, BLOCK=stream + EVAL_RUN only; same keys and rules as experiments/eval/h2n-block.sh):
# DS_C (bundle dir: p-destijl-shm.sh, packet.sha256), DS_BUNDLE_SHA, DS_K (guest release -ds-destijl-<n>: both VMs run
# it, so hw / mg lifetimes of a ds block run on the De Stijl kernel without cxl_shm; pop and ds never share a block),
# DS_GT (guest tools dir), RS_DS_T_US (staleness bound T in us, default 0 = synchronous; servers get
# ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=<T>). REGION must be the De Stijl region config (config/cxl_region-destijl.yaml;
# the guest copies are checked against DS_GT/cxl_region.yaml at every load). L1 / L2 fix tokens need confirmed hw and
# pop results (eval_levels_compute): a ds block uses numeric STREAM_FIX_LEVELS.
KEXP=$K8 DST=0 HASDS=0 REPL=off RPOOL= REPL_SET=0 WA= WA_SET=0
[[ " ${SYSTEMS:-} " != *" ds "* ]] || HASDS=1
if [ $HASDS = 1 ]; then
  [[ " ${SYSTEMS:-} " != *" pop "* ]] || { echo "SEQUENCE STOP: pop and ds need different guest kernels: separate blocks"; exit 2; }
  : "${DS_C:?}" "${DS_BUNDLE_SHA:?}" "${DS_K:?}" "${DS_GT:?}"
  [[ $DS_K == *-ds-destijl-* ]] || { echo "SEQUENCE STOP: DS_K=$DS_K is not a De Stijl release"; exit 2; }
  why=$(recv_rules ds "$RECV_MODE" "$DS_C" 2) || { echo "SEQUENCE STOP: De Stijl receiver: $why"; exit 2; }
  DST=${RS_DS_T_US:-0}
  [[ $DST =~ ^(0|[1-9][0-9]*)$ ]] || { echo "SEQUENCE STOP: bad RS_DS_T_US ($DST)"; exit 2; }
  # DS_RECV_EXTRA (optional, runset-rs-ds.sh RS_DS_RECV_EXTRA): "idle_sleep_us=<n> idle_spin_us=<n>" appended to the
  # cxl_shm load of every ds lifetime, read back after the enable (recv-mode-<name>.txt), mismatch = stop
  [[ ${DS_RECV_EXTRA:-} =~ ^(((idle_sleep_us|idle_spin_us)=[0-9]+|fault_poll=[01])( |$))*$ ]] || { echo "SEQUENCE STOP: bad DS_RECV_EXTRA (${DS_RECV_EXTRA:-})"; exit 2; }
  [[ " ${DS_RECV_EXTRA:-} " != *" fault_poll=1 "* ]] || DSFP=1
  # DS_REPLICA_MODE off | all (optional, runset-rs-ds.sh RS_DS_REPLICA_MODE; unset / off = no replica step at all, as
  # before) and DS_REPLICA_POOL_BYTES (pool cap, required with all): ds-replica.sh replica_set after the cxl_shm load and
  # before the preload (the kernel refuses a change once a managed VMA exists), replica counters before the teardown,
  # back to off + the previous pool after the teardown (and in the EXIT trap after a cleanup teardown)
  REPL=${DS_REPLICA_MODE:-off} RPOOL=${DS_REPLICA_POOL_BYTES:-}
  [[ $REPL =~ ^(off|all)$ ]] || { echo "SEQUENCE STOP: bad DS_REPLICA_MODE ($REPL: off | all)"; exit 2; }
  [ "$REPL" != all ] || { [[ $RPOOL =~ ^[1-9][0-9]*$ ]] && [ "$RPOOL" -ge 1073741824 ]; } \
    || { echo "SEQUENCE STOP: DS_REPLICA_MODE=all needs DS_REPLICA_POOL_BYTES >= 1073741824 (got '$RPOOL')"; exit 2; }
  [ -z "$RPOOL" ] || [ "$REPL" = all ] || { echo "SEQUENCE STOP: DS_REPLICA_POOL_BYTES without DS_REPLICA_MODE=all"; exit 2; }
  # torn rows (user 2026-11-07, option a; session.sh TORN_POLICY, torn_rows.py): allowed only with T > 0 and replica on
  if [ "$DST" != 0 ] && [ "$REPL" != off ]; then
    echo "BLOCK PLAN: torn rows: allowed in the ds lifetimes (T = $DST us, replica_mode $REPL): reported per step / measurement / lifetime (torn.txt, torn-steps.csv, torn-lifetime.txt, <E>/torn-rows.csv via rs_check.py INFO), not an invariant"
  else echo "BLOCK PLAN: torn rows: zero-torn invariant in the ds lifetimes (T = $DST us, replica_mode $REPL)"; fi
  [ "$REPL" = off ] || echo "BLOCK PLAN: replica: De Stijl replica_mode $REPL on both VMs, pool per VM = min($RPOOL, MemAvailable - 4 GiB) (1 MiB floor, >= 1 GiB) at every ds lifetime start, after the cxl_shm load and before the preload; read back (ds-replica-<name>.txt); counters before the teardown (replica_pool_full must stay 0); back to off + previous pool after the teardown"
  # DS_WAIT_ASSIST 0 | 1 (optional, runset-rs-ds.sh RS_DS_WAIT_ASSIST; unset / empty = no step at all, as before): the
  # De Stijl build-13 kernel switch /sys/kernel/swmc/destijl/wait_assist, written on both VMs after the enable (recv_apply)
  # and read back (ds-wait-assist-<name>.txt; mismatch or a missing switch = stop), read back again before the teardown,
  # back to 0 + read back after the teardown (and in the EXIT trap after a stopped lifetime)
  WA=${DS_WAIT_ASSIST:-}
  [[ $WA =~ ^[01]?$ ]] || { echo "SEQUENCE STOP: bad DS_WAIT_ASSIST ($WA: 0 | 1)"; exit 2; }
  [ -z "$WA" ] || echo "BLOCK PLAN: wait assist: /sys/kernel/swmc/destijl/wait_assist=$WA on both VMs at every ds lifetime, written after the enable, read back after the enable and before the teardown (ds-wait-assist-<name>.txt); back to 0 after the teardown"
  [ -f "$DS_C/p-destijl-shm.sh" ] && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -d' ' -f1)" = "$DS_BUNDLE_SHA" ] \
    && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: DS_C is not the verified De Stijl bundle"; exit 2; }
  cmp -s "$REGION" "$DS_C/tools/cxl_region.yaml" || { echo "SEQUENCE STOP: REGION differs from the De Stijl bundle's region config"; exit 2; }
  KEXP=$DS_K
fi
if [ "${STREAM_PMAX:-0}" = 1 ]; then  # run-2 pmax step plan (shown by lib.sh block_dry)
  for s in ${SYSTEMS:-hw pop}; do
    case $s in
      pop) echo "BLOCK PLAN: pmax $s: rate = own slo row (pmax_decide.py --workload recsys --from <E>/stream-results.tsv), part pmax '--mode fixed --rates <rate> --warmup-s ${STREAM_PMAX_SETTLE_S:-30} --step-warmup-s 5 --step-measure-s ${STREAM_PMAX_S:-60} --drain-s 10'";;
      ds) for r in $STREAM_RATES; do
            echo "BLOCK PLAN: pmax ds-u$r: $(python3 -I -B "$X/../eval/pmax_decide.py" --workload recsys --mix u$r $(for f in ${STREAM_PMAX_FROM:-}; do echo "--from $f"; done) | tr '\t' ' ')"
          done;;
    esac
  done
fi
if [ -n "${STREAM_AUC:-}" ]; then  # run-2 fixed-rate AUC plan (shown by lib.sh block_dry)
  [ "$V7" = 1 ] || { echo "SEQUENCE STOP: STREAM_AUC needs V7=1"; exit 2; }
  echo "BLOCK PLAN: auc lifetimes [$STREAM_AUC] systems [${SYSTEMS:-hw pop}] only=${STREAM_AUC_ONLY:-0}: warm-up then part auc '--mode fixed --rates <q> --warmup-s ${STREAM_AUC_SETTLE_S:-30} --step-warmup-s 5 --step-measure-s ${STREAM_AUC_S:-300} --drain-s 10' seed $((SEED + 3)), AUC rows -> <E>/auc_part.csv"
  [ -z "${STREAM_AUC2:-}" ] || echo "BLOCK PLAN: auc fix2 parts [$STREAM_AUC2] after part auc of the rate's AUC lifetime: one part fix2-<k> per rate '--raw --mode fixed --rates <q> --warmup-s 0 --step-warmup-s 5 --step-measure-s ${STREAM_AUC2_S:-120} --drain-s 10${STREAM_DRAIN_FULL_S:+ --drain-full-s $STREAM_DRAIN_FULL_S}' seed $((SEED + 10)) + k, rows -> <E>/stream-fix2.tsv"
  [ "${STREAM_AUC2_V7POST:-0}" = 0 ] || echo "BLOCK PLAN: auc fix2 parts: v7 post-processing per part (stale logs, v7-steps.csv, rows -> <E>/auc_fix2.csv)"
fi
# receiver keys: modes of the pop / ds lifetimes of this block; a non-adaptive one refuses RECV_WATCH_US /
# RECV_S_MAX_US (dry: BLOCK NOTE, then the evidence-dir check ends the dry start; real: stop below)
RMODES=; [[ " ${SYSTEMS:-hw pop mg} " != *" pop "* ]] || RMODES+="$PRM"; [[ " ${SYSTEMS:-hw pop mg} " != *" ds "* ]] || RMODES+="${RMODES:+ }$RECV_MODE"
WSMWHY=
if [ -n "${RECV_WATCH_US:-}${RECV_S_MAX_US:-}" ]; then
  # shellcheck disable=SC2086
  WSMWHY=$(recv_wsm_check $RMODES) || echo "BLOCK NOTE: $WSMWHY (a real run stops here)"
  [ -n "$RMODES" ] || echo "BLOCK NOTE: $(recv_wsm_desc) not applied: no pop / ds lifetime in this block"
fi
echo "BLOCK PLAN: receiver modes=[${RMODES:-none}] ipoll=${IPOLL:-default} $(recv_wsm_desc)"
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
[ -z "$WSMWHY" ] || { echo "SEQUENCE STOP: $WSMWHY"; exit 2; }
[ -z "$V7PEND" ] ||{ echo "SEQUENCE STOP: v7 parameters not decided by the user:$V7PEND (@USER@ in the conf)"; exit 2; }
LOCKF=${LOCK:-$P/workspaces/MEASUREMENT.lock}
if [ $BLOCK = h1 ]; then  # parent lock rule: H1 main holds the lock; this block never locks or unlocks
  grep -q "^owner=H1-main " "$LOCKF" 2>/dev/null || { echo "SEQUENCE STOP: lock $LOCKF not held by H1-main ($(cat "$LOCKF" 2>/dev/null))"; exit 2; }
else
  bash $G lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
fi
export LOADGEN PROFILE=main RUN_KIND=measurement STATS_OP=10 READY_TIMEOUT=$((XT / 2)) IDLE_WAIT_S=2400  # idle: an overrunning T = 60 s round may take > 10 min (Megalon); at T = 1 s the last round ends within ~1 s
SHMR=$E/shm-pop; PS=(K=$K8 GT=$GT8 C=$C8 R=$SHMR INIT_STATE=shared)   # per page MSI lifetime (system(): shm-<name>)
SHMS=$C8/p-popcorn-shm.sh   # the shm script of the current load (De Stijl lifetimes: $DS_C/p-destijl-shm.sh)
CHOWNED=0
stop_servers() {  # this block's servers only: every session dir's guest run dir + the preload pid dir
  local ip g
  for ip in "${IPS[@]}"; do
    for g in $(sed -n "s/^GRUN='\(.*\)'$/\1/p" "$E"/*/session.env 2>/dev/null) $(cat "$E"/preload-*.dir 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && $VM_PLAIN/bin/recsys-node.sh stop $g \$k; done; true" < /dev/null 2>&1 \
        | sed "s|^|$ip $g |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip "echo procs=\$($PCOUNT)" < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
# Count our servers by command line, not by comm: Megalon renames threads (e.g. "megalon-lib") and pgrep -x matches
# the main thread's comm, so a renamed server would count 0. Every server we start runs "<dir>/bin/recsys-server"
# (session nodes via recsys-node.sh under timeout, and the pop preload); the timeout wrapper matches too. The bracket
# keeps the remote shell's own command line from matching.
PCOUNT="pgrep -c -f -- '[/]bin/recsys-server( |\$)'"
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip "$PCOUNT" < /dev/null)" = 0 ] || return 1; done; }
# dax_free <tag>: no process holds /dev/dax0.0 on either VM (sudo -n fuser: rc 1 and no output = free; anything else,
# incl. sudo denied or ssh failure, counts as not free: fail closed). Output kept in <E>/fuser-<tag>-<ip>.out
dax_free() { local ip f rc ok=0
  for ip in "${IPS[@]}"; do
    f="$E/fuser-$1-$ip.out"
    $SSH comsys@$ip 'sudo -n fuser /dev/dax0.0' < /dev/null > "$f" 2>&1; rc=$?
    echo "rc=$rc" >> "$f"
    [ $rc = 1 ] && [ "$(wc -l < "$f")" = 1 ] || ok=1
  done
  return $ok; }
shm_cleanup() {  # page MSI loaded (load attempted) and no "teardown PASS" (the current page MSI lifetime's dir)
  local r=$SHMR
  [ -f "$r/load-vm0.txt" ] || return 0
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && return 0
  dax_free cleanup || { echo "CLEANUP FAILED: /dev/dax0.0 still in use or fuser not clean on a VM (see $E/fuser-cleanup-*.out); teardown not attempted (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"; return 0; }
  echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
  if ! env "${PS[@]}" bash $SHMS teardown >> "$E/cleanup.out" 2>&1; then
    if [ "$SHMS" = $C8/p-popcorn-shm.sh ] && grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null; then
      env "${PS[@]}" bash $SHMS instr-on >> "$E/cleanup.out" 2>&1 \
        && env "${PS[@]}" bash $SHMS teardown >> "$E/cleanup.out" 2>&1
    fi
  fi
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
}
dax_root_all() {  # both VMs, always; fresh per-check file per VM; DAXOK=1 only if every stat line is root:root 600
  local ip f=$E/dax-root-$(date +%s%N).out
  DAXOK=1
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
      < /dev/null 2>&1 | sed "s/^/$ip /" | tee -a "$E/rollback.out" > "$f.$ip"
    [ "$(grep -o 'stat=.*' "$f.$ip")" = "stat=root:root 600" ] || DAXOK=0
  done
}
finish() {
  trap '' INT TERM HUP  # the rollback itself is not interruptible
  stop_servers; shm_cleanup
  if [ "$REPL_SET" = 1 ]; then  # a stopped replica_mode all lifetime: off + previous pool, only after a teardown PASS
    if grep -q "teardown PASS" "$SHMR/steps.log" 2>/dev/null; then
      replica_set "${NAME:-cleanup}" off || echo "$(date -Is) ROLLBACK FAIL: replica_mode not off / pool not restored on a VM (see ds-replica-${NAME:-cleanup}.txt)" | tee -a "$E/rollback.out"
    else echo "$(date -Is) ROLLBACK NOTE: replica_mode left as set (cxl_shm not torn down; the De Stijl rollback reboot clears it)" | tee -a "$E/rollback.out"; fi
  fi
  if [ "$WA_SET" = 1 ]; then  # a stopped wait-assist lifetime: the kernel switch back to 0 (runtime switch, any module state)
    wa_write "${NAME:-cleanup}" 0 exit-trap && echo "$(date -Is) rollback: wait_assist 0 on both VMs" | tee -a "$E/rollback.out" \
      || echo "$(date -Is) ROLLBACK FAIL: wait_assist not back to 0 on a VM (see ds-wait-assist-${NAME:-cleanup}.txt; the De Stijl rollback reboot clears it)" | tee -a "$E/rollback.out"
  fi
  local procs_ok=1
  servers_gone || procs_ok=0
  [ $procs_ok = 1 ] || echo "$(date -Is) ROLLBACK FAIL: a recsys-server process survived on a VM (procs != 0; see $E/rollback.out)" | tee -a "$E/rollback.out"
  dax_free rollback || echo "$(date -Is) ROLLBACK FAIL: /dev/dax0.0 in use (or fuser not clean) on a VM (see $E/fuser-rollback-*.out)" | tee -a "$E/rollback.out"
  dax_root_all
  [ $DAXOK = 1 ] && echo "$(date -Is) rollback: dax0.0 root:root 600 on both VMs" | tee -a "$E/rollback.out" \
    || echo "$(date -Is) ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see $E/rollback.out)" | tee -a "$E/rollback.out"
  [ $BLOCK = h1 ] || bash $G unlock "$OWNER"
}
trap finish EXIT
trap 'echo "$(date -Is) SEQUENCE STOP: interrupted"; exit 130' INT TERM HUP
stop() { echo "$(date -Is) MAIN STOP $*"; exit 1; }
dax_comsys() {  # before an all-HWcc / Megalon session
  local ip
  if [ $CHOWNED = 1 ]; then  # already chowned by this block: fresh stat on both VMs before the next lifetime
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/dax-stat-$ip-$(date +%s%N).out" 2>&1
      grep -qx "comsys:root 600" "$(ls -t "$E"/dax-stat-$ip-*.out | head -1)" || stop "dax0.0 on $ip is not comsys:root 600"
    done
    return 0
  fi
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip-$(date +%s).out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$(ls -t "$E"/chown-$ip-*.out | head -1)" || stop "chown $ip"
  done
}
dax_root() {  # before the page MSI lifetime (no server of ours runs then)
  servers_gone || stop "a recsys-server runs before page MSI"
  dax_free pre-shm-load || stop "/dev/dax0.0 in use before the cxl_shm load"
  [ $CHOWNED = 1 ] || return 0
  dax_root_all; CHOWNED=0
  [ $DAXOK = 1 ] || stop "dax0.0 not back to root:root 600 before page MSI"
}
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_half() { python3 $X/main_util.py half "$1"; }        # 0.5 x confirm mean of an SLO search without a note
gatechk() { python3 $X/main_util.py gate "$1" "$SLO_MS" "$SLO_PCT"; }  # validity + within the SLO (p95)
precheck() {
  local i f h files="${VM_PLAIN#/home/comsys/}/bin/recsys-server ${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh ${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml ${VM_MEG#/home/comsys/}/bin/recsys-server ${VM_MEG#/home/comsys/}/bin/recsys-node.sh ${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so ${VM_MEG#/home/comsys/}/lib/libmegalon.so ${VM_MEG#/home/comsys/}/cfg/megalon.yaml ${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml"
  # a De Stijl block without a Megalon lifetime (eval3 rs-ds: SYSTEMS=ds, REGION = the De Stijl region) does not compare
  # the Megalon install's region (ring2m) with REGION; every other block is unchanged
  local megr="${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml ${REGION:-$P/CXL_SWMC/config/cxl_region.yaml}"
  case " ${SYSTEMS:-hw pop mg} " in *" mg "*|*" mgoff "*|*" mgrow "*) ;; *) [ $HASDS = 0 ] || megr="";; esac
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$KEXP MEM_MIN=60 EXPECT_DAX_UUID='${EXPECT_DAX_UUID:-}' INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || stop "precheck ${IPS[$i]}"
    for f in "${VM_PLAIN#/home/comsys/}/bin/recsys-server $HOST_PLAIN" "${VM_MEG#/home/comsys/}/bin/recsys-server $MB/bin/recsys-server" \
             "${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so $MB/lib/libmegalon-objapi.so" "${VM_MEG#/home/comsys/}/lib/libmegalon.so $MB/lib/libmegalon.so" \
             "${VM_MEG#/home/comsys/}/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/recsys-2vm.yaml" \
             "${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml ${REGION:-$P/CXL_SWMC/config/cxl_region.yaml}" "$megr" \
             "${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh" "${VM_MEG#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh"; do
      [ -n "$f" ] || continue
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" || stop "${IPS[$i]} /home/comsys/$1 != $2"
    done
  done
  (cd "$D" && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  ' MANIFEST.txt)) > "$E/inputs-check.out" 2>&1 || stop "inputs differ from $D/MANIFEST.txt"
  for f in "$UPD_FILE" "$QRY_FILE" dist_quantile.txt; do  # the inputs this block uses: listed and sha256-verified
    h=$(sed -n "s/^\([0-9a-f]\{64\}\)  $f\$/\1/p" "$D/MANIFEST.txt")
    [ -n "$h" ] || stop "$f not in $D/MANIFEST.txt"
    [ "$(sha256sum "$D/$f" | cut -d' ' -f1)" = "$h" ] || stop "$D/$f sha256 != MANIFEST"
  done
}
measure() {  # session dir, name, loadgen args... -> rc of session.sh measure
  local S=$1 n=$2; shift 2
  bash $GATE check "$E/gate-$(basename "$S")-$n.txt" || stop "host gate before $(basename "$S")/$n"
  bash $X/session.sh measure "$S" "$n" -- "$@" > "$S.$n.out" 2>&1
  local rc=$?
  tail -2 "$S.$n.out" | sed "s|^|  $(basename "$S")/$n: |"
  [ $rc = 5 ] && stop "$(basename "$S")/$n: $(grep -m1 '^STATS MISSING' "$S.$n.out") (session.sh rc 5)"
  return $rc
}
pop_setup() {  # P-popcorn-deploy §6a cycle with build POP_BUILD (init_state=shared), as pilot-run.sh, once per lifetime
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  local ip m i t
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one
    [ "$($SSH comsys@$ip "test -f $VM_PLAIN/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $VM_PLAIN/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)  # node 0 writes the initial tables through a plain mapping before coherence is enabled (no HWcc access)
  local PD=$VM_PLAIN/runs/preload-main-$(date +%s)
  echo "$PD" > "$E/preload-$NAME.dir"
  $SSH comsys@${IPS[0]} "mkdir -p $PD && CXL_REGION_CONFIG=$VM_PLAIN/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $PD/node0.pid; exec timeout $XT $VM_PLAIN/bin/recsys-server --node 0 --preload-only $SA --publish-ms $T_MS'" \
    < /dev/null > "$E/preload-$NAME.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$NAME.log"
  { grep -q "PRELOAD DONE" "$E/preload-$NAME.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || stop "enable gate"
  recv_apply pop "$NAME" "$PRM"   # recv-mode.sh: mode, readback (+ ipoll / srcversion for adaptive), instr enabled
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || stop "status pre"
}
ds_setup() {  # De Stijl v2 cycle (protocol=destijl, init_state=shared; as pop_setup and h2n-block.sh ds_up), once per lifetime
  env "${PS[@]}" bash $SHMS precheck || stop "ds shm precheck"
  local ip m p i t ph
  for ph in load chown; do env "${PS[@]}" bash $SHMS $ph || stop "ds shm $ph"; done
  if [ "$REPL" != off ]; then  # before the preload / enable: no managed VMA may exist (EBUSY otherwise)
    REPL_SET=1; replica_set "$NAME" $REPL || stop "replica_mode $REPL / pool on a VM (see ds-replica-$NAME.txt)"
    echo "$(date -Is) $NAME: replica_mode $REPL, pool vm0 $(cat "$E/ds-replica-pool-$NAME-vm0") vm1 $(cat "$E/ds-replica-pool-$NAME-vm1") bytes (cap $RPOOL)"
  fi
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one
    [ "$($SSH comsys@$ip "test -f $VM_PLAIN/cfg/cxl_region.yaml && test -f $DS_GT/cxl_region.yaml && sha256sum $VM_PLAIN/cfg/cxl_region.yaml $DS_GT/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip (De Stijl tools)"
  done
  t=$(date +%s)
  local PD=$VM_PLAIN/runs/preload-main-$(date +%s)
  echo "$PD" > "$E/preload-$NAME.dir"
  $SSH comsys@${IPS[0]} "mkdir -p $PD && CXL_REGION_CONFIG=$VM_PLAIN/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $PD/node0.pid; exec timeout $XT $VM_PLAIN/bin/recsys-server --node 0 --preload-only $SA --publish-ms $T_MS'" \
    < /dev/null > "$E/preload-$NAME.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$NAME.log"
  { grep -q "PRELOAD DONE" "$E/preload-$NAME.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $SHMS enable || stop "ds enable gate"
  recv_apply ds "$NAME" "$RECV_MODE"   # recv-mode.sh: mode, protocol destijl, DSRX applied, adaptive checks
  if [ -n "$WA" ]; then  # build 13 wait assist: after the enable, before the status snapshot and the session start
    wa_read "$NAME" 0 before-write || stop "wait_assist is not 0 before the write on a VM (see ds-wait-assist-$NAME.txt)"
    WA_SET=1; wa_write "$NAME" "$WA" after-enable || stop "wait_assist=$WA not set / read back on a VM (see ds-wait-assist-$NAME.txt)"
    echo "$(date -Is) $NAME: wait_assist $WA on both VMs (read back)"
  fi
  env "${PS[@]}" STATUS_TAG=pre bash $SHMS status || stop "ds status pre"
}
WAF=/sys/kernel/swmc/destijl/wait_assist
wa_read() {  # <name> <want> <tag>: both VMs read back wait_assist == want (one line per VM in ds-wait-assist-<name>.txt)
  local ip v rc=0
  for ip in "${IPS[@]}"; do
    v=$($SSH comsys@$ip "cat $WAF" < /dev/null 2>/dev/null)
    echo "$(date -Is) $3 $ip wait_assist=${v:-missing} want=$2" >> "$E/ds-wait-assist-$1.txt"
    [ "$v" = "$2" ] || rc=1
  done
  return $rc; }
wa_write() {  # <name> <0|1> <tag>: write the switch on both VMs (guest sudo tee), then wa_read
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip "test -e $WAF && echo $2 | sudo -n tee $WAF > /dev/null" < /dev/null >> "$E/ds-wait-assist-$1.txt" 2>&1 \
      || { echo "$(date -Is) $3 $ip write wait_assist=$2 FAILED (switch missing or sudo refused)" >> "$E/ds-wait-assist-$1.txt"; return 1; }
  done
  wa_read "$1" "$2" "$3"; }
h1_lockchk() {  # BLOCK=h1: the parent lock must still name owner=H1-main (checked at block start and before every lifetime)
  [ $BLOCK = h1 ] || return 0
  grep -q "^owner=H1-main " "$LOCKF" 2>/dev/null || stop "lock $LOCKF not held by H1-main ($(cat "$LOCKF" 2>/dev/null))"
}
life_start() {  # <sys> <name>: prepare + session start of one server lifetime -> LS (session dir), NAME
  local s=$1 SE t0 SA0=$SA V7N0=""
  h1_lockchk
  NAME=$2 LS=$E/$2
  # v7: per-lifetime stale logs on each guest (node 1 via SERVER_ARGS, node 0 overrides it in NODE0_ARGS; later wins)
  [ "$V7" != 1 ] || { SA="$SA --stale-log $(v7_stale $2 1)"; V7N0=" --stale-log $(v7_stale $2 0)"; }
  # adaptive receiver (run 2): per-step /sys/kernel/cxl_shm counters + idle-poller CPU (kthreads cxl_ipoll/<cpu>)
  local lrm=-; case $s in pop) lrm=$PRM;; ds) lrm=$RECV_MODE;; esac
  if [ "$lrm" = adaptive ]; then
    [[ " $SA " == *" --proc-sysfs /sys/kernel/cxl_shm "* ]] || SA="$SA --proc-sysfs /sys/kernel/cxl_shm"
    SA="$SA --proc-kthread cxl_ipoll"
  fi
  local S=$LS
  if [ $s = pop ]; then SHMR=$E/shm-$NAME; PS=(K=$K8 GT=$GT8 C=$C8 R=$SHMR INIT_STATE=shared) SHMS=$C8/p-popcorn-shm.sh; fi
  if [ $s = ds ]; then SHMR=$E/dsshm-$NAME; DSRX=${DS_RECV_EXTRA:-}; PS=(K=$DS_K GT=$DS_GT C=$DS_C R=$SHMR INIT_STATE=shared "LOAD_EXTRA=recv_mode=$RECV_MODE${DSRX:+ ${DSRX% }}") SHMS=$DS_C/p-destijl-shm.sh; fi
  t0=$(date +%s)
  echo "$(date -Is) system $s start"
  case $s in
    hw) dax_comsys; SE=(SYSTEM=all-HWcc V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=$XT");;
    mg) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_TABLE_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    mgrow) dax_comsys; SE=(SYSTEM=Megalon-row V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_ROW_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    mgoff) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon$(mg_rpo $MG_TABLE_N) $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0 ENV:XTIMEOUT=$XT$MGSE" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    pop) dax_root; pop_setup
         SE=(SYSTEM=Popcorn-$PRM V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" NODE0_ARGS=--preloaded "NODE_ENV=ENV:XTIMEOUT=$XT");;
    ds) dax_root; ds_setup
        SE=(SYSTEM=DeStijl-$RECV_MODE-T$DST V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" NODE0_ARGS=--preloaded
            "NODE_ENV=ENV:XTIMEOUT=$XT ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=$DST" "TORN_POLICY=system=ds T_us=$DST replica_mode=$REPL");;
  esac
  [ -z "$N0X" ] || SE+=("NODE0_ARGS=$(case $s in pop|ds) echo "--preloaded ";; esac)$N0X$V7N0")   # BLOCK=stream (later value wins in env)
  [ "$V7" != 1 ] || SE+=("HOST_PATH_MAP=$V7_HOST_PATH_MAP")   # Host-side server calls read the Host image copy
  SA=$SA0
  servers_gone || stop "a recsys-server runs before $s"
  env "${SE[@]}" T_MS=$T_MS bash $X/session.sh start "$S" > "$S.start.out" 2>&1 || { tail -3 "$S.start.out"; stop "$s session start"; }
  tail -1 "$S.start.out"
  echo "$NAME prepare_wall_s=$(( $(date +%s) - t0 )) (incl. page MSI shm load + preload)" >> "$E/load-times.txt"
  sed "s/^/$NAME /" "$S/load-times.txt" >> "$E/load-times.txt"
  [ $BLOCK != stream ] || pub_train   # windowed publication: training-only first window (PUBLISH_WINDOW_S > 0)
}
life_stop() {  # <sys>: session stop, final checks, page MSI teardown (pop)
  local s=$1 S=$LS
  bash $X/session.sh stop "$S" > "$S.stop.out" 2>&1 || { tail -5 "$S.stop.out"; stop "$s session stop / final checks"; }
  tail -1 "$S.stop.out"
  u0_check   # u0 only (header "U0")
  if [ $s = ds ] && [ "$DST" != 0 ]; then local k
    for k in 0 1; do grep -q "^recsys-server: de stijl staleness T=$DST us on " "$S/node$k.log" || stop "node$k: staleness T=$DST not applied"; done
  fi
  if [ $s = pop ] || [ $s = ds ]; then
    recv_post "$NAME"   # receiver / idle-poller CPU after the run (recv-post-<name>.txt; recv-mode.sh)
    env "${PS[@]}" STATUS_TAG=post bash $SHMS status
    if [ $s = ds ] && [ "$REPL" != off ]; then  # a full pool maps CXL directly (mixed run; recv_check fails it too)
      replica_post "$NAME" || echo "MAIN NOTE $NAME: replica pool full or counters unreadable on a VM (ds-replica-$NAME.txt)"
    fi
    if [ $s = ds ] && [ -n "$WA" ]; then  # the switch held for the whole lifetime
      wa_read "$NAME" "$WA" pre-teardown || stop "wait_assist is not $WA before the teardown on a VM (see ds-wait-assist-$NAME.txt)"
    fi
    servers_gone || stop "servers left (page MSI teardown not attempted)"
    dax_free pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm teardown"
    env "${PS[@]}" bash $SHMS teardown || stop "shm teardown"
    grep -q "teardown PASS" "$SHMR/steps.log" || stop "no teardown PASS"
    if [ $s = ds ] && [ -n "$WA" ]; then
      wa_write "$NAME" 0 post-teardown || stop "wait_assist back to 0 (see ds-wait-assist-$NAME.txt)"; WA_SET=0
    fi
    if [ $s = ds ] && [ "$REPL" != off ]; then
      replica_set "$NAME" off || stop "replica_mode back to off / pool restore (see ds-replica-$NAME.txt)"; REPL_SET=0
    fi
  fi
  servers_gone || stop "servers left after $NAME"
}
system() {  # one server lifetime (BLOCK main / v1): <hw|pop|mg|mgoff|mgrow> [<name>]
  local s=$1 S rc g L t0 r
  t0=$(date +%s)
  life_start $s ${2:-$1}; S=$LS
  # 1) warm-up (unmeasured): 1 query/s with the updater for 70 s (>= one T = 60 s publication round)
  measure "$S" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 70 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s warm-up rc $rc"
  if [ $BLOCK = v1 ]; then  # validation window (reports/RECSYS-V1-packet.md §3)
    measure "$S" val "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$V1_RATE" \
      --step-warmup-s 5 --step-measure-s "$V1_WINDOW_S" --drain-s 10
    rc=$?
    [ $rc = 0 ] || stop "$s val rc $rc"
    if [[ " $V1_OPFAIL_CONTINUE " == *" $s "* ]]; then  # user decision only: operating-point-only FAIL -> OPFAIL, continue
      python3 $X/v1_check.py "$S/val" $(chk_sys $s) $(chk_args $s) --oppoint-report | sed "s/^\(V1CHECK [A-Z]*\) mg /\1 $s /" | tee "$S/val/v1-check.txt" | tee -a "$E/v1-checks.txt"
      if grep -q "^V1CHECK OPFAIL" "$S/val/v1-check.txt"; then
        echo "$(date -Is) MAIN NOTE $s: operating point not met (V1_OPFAIL_CONTINUE): $(cut -c1-400 "$S/val/v1-check.txt")" | tee -a "$E/v1-opfail.txt"
      else
        grep -q "^V1CHECK PASS" "$S/val/v1-check.txt" || stop "$s: $(cat "$S/val/v1-check.txt")"
      fi
    else
      python3 $X/v1_check.py "$S/val" $(chk_sys $s) $(chk_args $s) | sed "s/^\(V1CHECK [A-Z]*\) mg /\1 $s /" | tee "$S/val/v1-check.txt" | tee -a "$E/v1-checks.txt"
      grep -q "^V1CHECK PASS" "$S/val/v1-check.txt" || stop "$s: $(cat "$S/val/v1-check.txt")"
    fi
    python3 $X/check_breakdown.py "$S/val" | tee "$S/val/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s val: $(cat "$S/val/breakdown-check.txt")"
  else
  # 2) lowest load: 1 query/s, 60 s, no SLO abort
  measure "$S" gate "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates 1 \
    --step-warmup-s 3 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s gate measurement rc $rc"
  g=$(gatechk "$S/gate/loadgen/steps.jsonl")
  echo "$s gate 1 query/s: $g" | tee -a "$E/gate.txt"
  if [ $s = hw ]; then
    case "$g" in VALID*) ;; *) stop "all-HWcc lowest-load window invalid ($g)";; esac
    { echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE"; echo "all-HWcc lowest-load window: $g"; } | tee "$E/slo.txt"
  else
    case "$g" in VALID*) ;; *) echo "MAIN NOTE $s lowest-load window invalid (recorded; the block continues): $g";; esac
  fi
  [ -n "$SLO_MS" ] || stop "no block SLO"
  # 3) SLO searches (block SLO)
  for r in $(seq 1 $ROUNDS); do
    measure "$S" slo-r$r "${LGC[@]}" --opt seed=$((SEED + r)) --seed $((SEED + r)) --slo query:$SLO_PCT:$SLO_MS --raw \
      --mode slo --start 1 --factor 1.5 --precision 0.05 --max-steps 20
    rc=$?
    grep -q 'workload_finish":"ok' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null || stop "$s slo-r$r: loadgen workload finish (rc $rc)"
    if [ $rc = 1 ]; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null)
      [ -n "$note" ] || stop "$s slo-r$r: loadgen rc 1 without a note"
      echo "MAIN NOTE $s slo-r$r: $note"
    elif [ $rc != 0 ]; then stop "$s slo-r$r rc $rc"; fi
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); print(sys.argv[2], "note=%r" % s.get("note",""), "confirm_x_mean=%s sd=%s" % (c.get("x_mean"), c.get("x_sd")))' \
      "$S/slo-r$r/loadgen/summary.json" "$s slo-r$r" | tee -a "$E/slo-results.txt"
    if [ $s = hw ] && [ $r = 1 ] && [ "$FIXED" = 1 ]; then
      L=$(confirm_half "$S/slo-r1/loadgen/summary.json") || stop "no all-HWcc slo-r1 confirm result for L"
      echo "L = 0.5 x all-HWcc slo-r1 confirm mean (this block, Popcorn build $POP_BUILD, T = 60 s) = $L query/s" > "$E/fixed-load-L.txt"
    fi
  done
  # 4) fixed load L, 60 s, whole window (no SLO abort); FIXED=0 skips it (user 2026-10-16: the breakdown is taken
  #    from the SLO-search steps at the highest rate all systems ran; every step has its own stats window)
  if [ "$FIXED" = 1 ]; then
  L=$(sed -n 's/.* = \([0-9.]*\) query\/s$/\1/p' "$E/fixed-load-L.txt")
  [ -n "$L" ] || stop "no L"
  measure "$S" fixed "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$L" \
    --step-warmup-s 5 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s fixed rc $rc"
  python3 $X/check_breakdown.py "$S/fixed" | tee "$S/fixed/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s fixed: $(cat "$S/fixed/breakdown-check.txt")"
  else
  [ -s "$S/slo-r1/stats-steps.csv" ] || stop "$s slo-r1: no per-step stats (stats-steps.csv)"
  fi
  fi  # BLOCK
  life_stop $s
  echo "$(date -Is) MAIN $NAME DONE ($(( $(date +%s) - t0 )) s)"
}
# ---- H1-HOOK v2 parts (see the header) ----
h1_warmup() {  # unmeasured warm-up before an SLO part (as every earlier lifetime): 1 query/s with the updater, 70 s
  measure "$LS" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 70 --drain-s 10
  local rc=$?; [ $rc = 0 ] || stop "$NAME warm-up rc $rc"
}
# v0.6.8 (user 2026-10-18 "응 그렇게 진행해"): the SLO search runs with loadgen --tol 0.02, so a step whose update
# completions in the window fall below 98 % of the updates SENT in it fails inside the search (ramp stops there, bisect
# and confirm count it as a failed probe). loadgen applies --tol to every stream with >= 100 sent, so the query stream
# is judged by the same rule. Fixed parts keep loadgen's default --tol (0.05; a fixed run never stops on it, the
# operating point is judged by v1_check.py --h1 over the L2+L1 span: update completions >= 0.98 x sent).
H1_SLO_TOL=0.02
h1_slo() {  # <sys>: warm-up + full SLO search -> $LS/slo
  local s=$1 rc RD=$LS/slo note="" st=1
  [ $s != pop ] || st=${POPST[$H1_MIX]:-1}   # v0.6.16: ",POPSTART=<n>" mix parameter (Popcorn only)
  h1_warmup
  echo "$NAME slo: search start rate $st" >> "$E/seeds.txt"
  measure "$LS" slo "${LGC[@]}" --opt seed=$SEED --seed $SEED --slo query:$SLO_PCT:$SLO_MS --raw --tol $H1_SLO_TOL \
    --mode slo --start $st --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 20
  rc=$?
  echo "$NAME slo: loadgen seed $SEED" >> "$E/seeds.txt"
  grep -q 'workload_finish":"ok' "$RD/loadgen/summary.json" 2>/dev/null || stop "$NAME slo: loadgen workload finish (rc $rc)"
  if [ $rc = 1 ]; then
    note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$RD/loadgen/summary.json" 2>/dev/null)
    [ -n "$note" ] || stop "$NAME slo: loadgen rc 1 without a note"
    case "$note" in "confirm failed at three rates"*) ;; *) stop "$NAME slo: loadgen note '$note' (only 'confirm failed at three rates' is a NOTE)";; esac
    echo "MAIN NOTE $NAME slo: $note"
  elif [ $rc != 0 ]; then stop "$NAME slo rc $rc"; fi
  h1_check $s slo "$note"
}
h1_fix() {  # <sys> <L2 rate> <L1 rate>: settle (H1_SETTLE_S at L2, discarded) + L2 + L1 windows -> $LS/fix; H1STEPS
  local s=$1 rc RD=$LS/fix fs=$((SEED + 1))   # fix part seed = SEED + 1 (as the vector DB hook); in loadgen_args
  echo "$NAME fix: loadgen seed $fs (SLO part seed $SEED), settle $H1_SETTLE_S s at L2=$2, L1=$3" >> "$E/seeds.txt"
  measure "$LS" fix "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$2,$3" \
    --warmup-s "$H1_SETTLE_S" --step-warmup-s 5 --step-measure-s 60 --drain-s 10
  rc=$?; [ $rc = 0 ] || stop "$NAME fix rc $rc"
  H1STEPS=$(python3 -I -c 'import json,sys
st=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
m=[d for d in st if d.get("measure_s",0) > 0 and d.get("phase") == "fixed"]
r=[float(sys.argv[2]), float(sys.argv[3])]
assert len(m) == 2 and all(abs(d["offered_x"] - x) <= 1e-6 * max(1, x) for d, x in zip(m, r)), "fixed steps %s != L2,L1 %s" % ([(d["step"], d["offered_x"]) for d in m], r)
print("%d,%d" % (m[0]["step"], m[1]["step"]))' "$RD/loadgen/steps.jsonl" "$2" "$3" 2>&1) || stop "$NAME fix: $H1STEPS"
  h1_check $s fix ""
}
h1_check() {  # <sys> <part> <note>: v1_check --h1 + check_breakdown of <part>; <lifetime>/h1-runcheck.txt ends in RUNCHECK PASS
  local s=$1 r=$LS/$2 f=$LS/h1-runcheck.txt
  python3 $X/v1_check.py "$r" $s $(chk_args $s) --h1 > "$r/v1-check.txt" 2>&1
  python3 $X/check_breakdown.py "$r" > "$r/breakdown-check.txt" 2>&1
  [ -f "$f" ] || echo "# H1 per-run checks of lifetime $NAME (system $s, mix $H1_MIX, round $H1_N, seed $SEED; main-block.sh BLOCK=h1, H1-HOOK v2)" > "$f"
  sed -i '/^RUNCHECK PASS/d' "$f"
  { echo "[$2] v1_check: $(cat "$r/v1-check.txt")"; echo "[$2] check_breakdown: $(cat "$r/breakdown-check.txt")"
    echo "[$2] summary: $(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("mode=%s note=%r workload_finish=%s confirm=%s" % (s.get("mode"), s.get("note",""), s.get("workload_finish"), s.get("confirm",{}).get("x_mean")))' "$r/loadgen/summary.json" 2>&1)"
    [ -z "$3" ] || echo "[$2] NOTE: $3"
    grep -q " NOTES: " "$r/v1-check.txt" && echo "[$2] NOTE: v1_check: $(sed -n 's/.* NOTES: //p' "$r/v1-check.txt" | head -1)"
  } >> "$f"
  grep -q "^V1CHECK PASS" "$r/v1-check.txt" || stop "$NAME $2: $(cat "$r/v1-check.txt")"
  grep -q "^BREAKDOWN PASS" "$r/breakdown-check.txt" || stop "$NAME $2: $(cat "$r/breakdown-check.txt")"
  [ -s "$r/breakdown.csv" ] || stop "$NAME $2: no breakdown.csv"
  local notes; notes=$(sed -n 's/^\[[a-z]*\] NOTE: //p' "$f" | tr '\n' ';' | sed 's/;$//')
  if [ -n "$notes" ]; then echo "RUNCHECK PASS (NOTE: $notes)" >> "$f"; else echo "RUNCHECK PASS" >> "$f"; fi
}
# BLOCK=stream part (RecSys methodology 2026-10-19): warm-up 60 s (1 query/s + the update stream) then the SLO search
# from 1 q/s with >= 100 queries per step and the knee ramp (loadgen --min-step-queries 100 --ramp-knee 2), then
# stream_check.py (update validity; FAIL stops, NOTE = update rate not sustained, recorded) and check_breakdown.py.
stream_slo() {  # <sys> <rate>
  local s=$1 r=$2 rc RD=$LS/slo note="" sc
  measure "$LS" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 50 --drain-s 10
  rc=$?; [ $rc = 0 ] || stop "$NAME warm-up rc $rc"
  pub_after "$LS/warmup"   # windowed publication: SLO search >= PUBLISH_AFTER_S after publishing started
  measure "$LS" slo "${LGC[@]}" --opt seed=$SEED --seed $SEED --slo query:$SLO_PCT:$SLO_MS --raw --tol $SSTOL \
    --mode slo --start $SSSTART --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes $STREAM_CONFIRM_PROBES --confirm-step-down 0.05 \
    --max-steps 40 --min-step-queries 100 --ramp-knee 2 ${SSDRAIN[@]+"${SSDRAIN[@]}"} ${SSKNEE[@]+"${SSKNEE[@]}"}
  rc=$?
  grep -q 'workload_finish":"ok' "$RD/loadgen/summary.json" 2>/dev/null || stop "$NAME slo: loadgen workload finish (rc $rc)"
  if [ $rc = 1 ]; then
    note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$RD/loadgen/summary.json" 2>/dev/null)
    [ -n "$note" ] || stop "$NAME slo: loadgen rc 1 without a note"
    echo "MAIN NOTE $NAME slo: $note"
  elif [ $rc != 0 ]; then stop "$NAME slo rc $rc"; fi
  python3 $X/stream_check.py "$RD" > "$RD/stream-check.txt" 2>&1
  sc=$(grep -m1 '^STREAMCHECK' "$RD/stream-check.txt")
  case "$sc" in "STREAMCHECK PASS"*|"STREAMCHECK NOTE"*) ;; *) stop "$NAME: ${sc:-stream_check.py failed}";; esac
  python3 $X/check_breakdown.py "$RD" > "$RD/breakdown-check.txt" 2>&1
  # same tolerance as stream_fix: an SLO search in which no query completed in any step has no breakdown row; it is a
  # result (recorded, valid=0 via stream_check) when stream_check.py marks every step invalid (Megalon below 1 q/s)
  # verifier MED-1 (2026-11-10): also when update steps stay valid but no query completed (Megalon below 1 q/s at this rate)
  if ! grep -q "^BREAKDOWN PASS" "$RD/breakdown-check.txt"; then
    grep -q "no breakdown row with queries > 0" "$RD/breakdown-check.txt" && [ -s "$RD/stream-check.csv" ] \
      || stop "$NAME: $(cat "$RD/breakdown-check.txt")"
    if awk -F, 'NR > 1 && $5 == "True"' "$RD/stream-check.csv" | grep -q .; then
      echo "$NAME slo: no query completed in any step (update steps valid): recorded, not a stop" | tee -a "$RD/breakdown-check.txt"
    else
      echo "$NAME slo: no completed query in any step, all steps invalid: recorded, not a stop" | tee -a "$RD/breakdown-check.txt"
    fi
  fi
  v7_post "$s" "$r" "$RD"
  python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{})
f=lambda v: "" if v is None else str(v)
print("\t".join([sys.argv[2], sys.argv[3], sys.argv[4], f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")),
  str(len(s.get("low_rate_violations",[]))), sys.argv[5].split(" ")[1], "1" if sys.argv[5].startswith("STREAMCHECK PASS") else "0",
  s.get("ramp_policy",{}).get("ramp_end",""), f(s.get("ramp_policy",{}).get("knee_offered")), s.get("note","")]))' \
    "$RD/loadgen/summary.json" "$NAME" "$s" "$r" "$sc" >> "$E/stream-results.tsv" || stop "$NAME: results row"
  echo "$NAME: $sc"
}
# ---- EVAL (EVAL_RUN set; experiments/eval/runset-rs-main.sh, runset-rs-h1.sh; evaluation-pipeline rev 3 §6.3) ----
# Fixed-load windows (user decision 2026-10-20): per rate the level tokens are STREAM_FIX_LEVELS, or the rate's entry of
# STREAM_FIX_LEVELS_MAP ("<rate>=<t1>,<t2>,.." e.g. "50=L1,L2,1": the extra 1 q/s window for the Megalon comparison at
# the Megalon rates). A token is a query rate or L1 / L2: L1 = the lower confirmed max under the SLO of hw and pop at
# that rate (confirm_x_mean, stream-results.tsv; confirmed True), L2 = L1 / 2. L levels come from STREAM_LEVELS (tsv
# "rate L1 L2 source", e.g. run 1's stream-levels.tsv: cut Q8) when given, else they are computed after the rate's SLO
# lifetimes. A rate without a confirmed hw AND pop result has no L levels ("-" row); its L tokens are then replaced by
# STREAM_FIX_FALLBACK (e.g. 1 q/s; empty = no window). STREAM_FIX_SEP=1 (user 2026-10-20: measured per system after
# both SLO lifetimes of the rate): every system gets a fix-only lifetime after the rate's SLO lifetimes; STREAM_FIX_SEP=0:
# the part fix follows the SLO part in the same lifetime whenever the levels are known before it. Fix-only systems
# (STREAM_FIXONLY: mgoff always, mg for the Megalon probe / no-SLO case) never get an SLO part. Part fix: loadgen
# --warmup-s STREAM_FIX_SETTLE_S (60, discarded; right after READY in a fix-only lifetime) then one STREAM_FIX_S (60) s
# window per level, seed SEED + 1. Validity of every window = stream_check.py's per-step rule (stream-check.csv);
# invalid windows are recorded (fix-check.txt, stream-fix.tsv valid=0), not a stop; check_breakdown.py must PASS.
eval_tokens() {  # <rate> -> level tokens of the rate (space separated)
  local m
  for m in ${STREAM_FIX_LEVELS_MAP:-}; do [ "${m%%=*}" = "$1" ] && { echo "${m#*=}" | tr ',' ' '; return 0; }; done
  echo "${STREAM_FIX_LEVELS:-}"
}
eval_levels_known() {  # <rate> -> FIXTOKS, FIXRATES (comma lists) and 0; 1 when an L level is not known yet
  local r=$1 t v l1 l2 row rates="" toks=""
  row=$(awk -v r="$r" '!/^#/ && $1 == r' "$E/stream-levels.tsv" 2>/dev/null | tail -1)
  l1=$(echo "$row" | cut -f2) l2=$(echo "$row" | cut -f3)
  for t in $(eval_tokens $r); do
    case $t in
      L1|L2) [ -n "$row" ] || return 1
             v=$l1; [ $t = L2 ] && v=$l2
             if [ "$v" = - ]; then  # no confirmed hw and pop result at this rate: fallback window
               [ -n "${STREAM_FIX_FALLBACK:-}" ] || continue
               t=Q$STREAM_FIX_FALLBACK v=$STREAM_FIX_FALLBACK; fi;;
      *) v=$t t=Q$t;;
    esac
    [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    [[ ",$toks," == *",$t,"* ]] && continue   # a fallback equal to an extra window is measured once
    rates="$rates${rates:+,}$v" toks="$toks${toks:+,}$t"
  done
  FIXRATES=$rates FIXTOKS=$toks
}
eval_levels_compute() {  # <rate>: L1 = min(confirmed hw, pop confirm_x_mean) from stream-results.tsv, L2 = L1 / 2
  local r=$1 v
  v=$(python3 -I - "$E/stream-results.tsv" "$r" <<'PY'
import csv, sys
rows = [x for x in csv.reader(open(sys.argv[1]), delimiter="\t") if x and not x[0].startswith("#")]
x, excl = {}, []
for f in rows:  # a result counts only if confirmed AND valid (update stream sustained, stream_check; verifier M2)
    if f[2] == sys.argv[2] and f[1] in ("hw", "pop") and f[5] == "True" and f[4]:
        if f[8] == "1":
            x[f[1]] = float(f[4])
        else:
            excl.append(f"{f[1]} {f[4]} excluded: update stream not sustained")
if set(x) != {"hw", "pop"}:
    print("NONE no confirmed valid hw and pop result (" + ",".join(sorted(x)) + ")" + "".join("; " + e for e in excl))
else:
    l1 = round(min(x.values()), 3)
    print(f"{l1} {round(l1 / 2, 3)} min(hw {x['hw']}, pop {x['pop']})")
PY
)
  if [[ $v == NONE* ]]; then printf '%s\t-\t-\t%s\n' "$r" "NOTE ${v#NONE }" >> "$E/stream-levels.tsv"; return 1; fi
  read -r l1 l2 src <<< "$v"
  printf '%s\t%s\t%s\t%s\n' "$r" "$l1" "$l2" "computed: $src" >> "$E/stream-levels.tsv"
}
stream_fix() {  # <sys> <rate>: part fix in the current lifetime at FIXRATES (labels FIXTOKS)
  local s=$1 r=$2 rates=$FIXRATES RD=$LS/fix rc fs=$((SEED + 1))
  [ -n "$rates" ] || { echo "$NAME fix: no window (no levels)"; return 0; }
  measure "$LS" fix "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$rates" \
    --warmup-s "${STREAM_FIX_SETTLE_S:-60}" --step-warmup-s 5 --step-measure-s "${STREAM_FIX_S:-60}" --drain-s 10
  rc=$?; [ $rc = 0 ] || stop "$NAME fix rc $rc"
  python3 $X/stream_check.py "$RD" > "$RD/stream-check.txt" 2>&1
  python3 $X/check_breakdown.py "$RD" > "$RD/breakdown-check.txt" 2>&1
  # a window in which no query completed has no breakdown row: it is a result (recorded with valid=0) when
  # stream_check.py marks every window invalid (2026-10-20, rs-h1-v2: Megalon 50 samples/s, all queries timed out)
  if ! grep -q "^BREAKDOWN PASS" "$RD/breakdown-check.txt"; then
    grep -q "no breakdown row with queries > 0" "$RD/breakdown-check.txt" && [ -s "$RD/stream-check.csv" ] \
      && ! awk -F, 'NR > 1 && $5 == "True"' "$RD/stream-check.csv" | grep -q . \
      || stop "$NAME fix: $(cat "$RD/breakdown-check.txt")"
    echo "$NAME fix: no completed query in any window, all windows invalid: recorded, not a stop" | tee -a "$RD/breakdown-check.txt"
  fi
  python3 -I - "$RD" "$NAME" "$s" "$r" "$rates" "$FIXTOKS" >> "$E/stream-fix.tsv" 2> "$RD/fix-check.txt" <<'PY' || stop "$NAME fix: $(cat "$RD/fix-check.txt")"
import csv, json, os, sys
rd, name, s, r, rates, toks = sys.argv[1:7]
rates, toks = rates.split(","), toks.split(",")
st = [json.loads(l) for l in open(os.path.join(rd, "loadgen", "steps.jsonl")) if l.strip()]
m = [d for d in st if d.get("measure_s", 0) > 0 and d.get("phase") == "fixed"]
assert len(m) == len(rates) == len(toks), f"{len(m)} measured fixed steps for levels {toks} = {rates}"
v = {}
p = os.path.join(rd, "stream-check.csv")
if os.path.isfile(p):
    v = {int(x["step"]): x["valid"] == "True" for x in csv.DictReader(open(p))}
for d, t, x in zip(m, toks, rates):
    ok = v.get(d["step"])
    print("\t".join([name, s, r, t, x, str(d["step"]), "" if ok is None else ("1" if ok else "0")]))
    print(f"FIX {name} level {t} rate {x} step {d['step']} valid {ok}", file=sys.stderr)
PY
  echo "$NAME fix: $(tr '\n' ';' < "$RD/fix-check.txt")"
}
stream_pmax() {  # <sys> <rate>: run-2 pmax part in the current lifetime (header "STREAM_PMAX"); never a stop on its result
  local s=$1 r=$2 RD=$LS/pmax rc fs=$((SEED + 2)) src=() f v st=ok out
  [ "${STREAM_PMAX:-0}" = 1 ] && [[ $s =~ ^(pop|ds)$ ]] || return 0
  if [ $s = pop ]; then src=(--from "$E/stream-results.tsv"); else for f in ${STREAM_PMAX_FROM:-}; do src+=(--from "$f"); done; fi
  [ -s "$E/stream-pmax.tsv" ] || printf '# name\tsystem\trate_sps\tpmax_q_s\tappended\tstatus\tsource\n' > "$E/stream-pmax.tsv"
  out=$(python3 -I -B "$X/../eval/pmax_decide.py" --workload recsys --mix u$r "${src[@]}" --log "$E/pmax-$NAME.txt" 2>&1) \
    || { echo "MAIN NOTE $NAME pmax: pmax_decide.py failed ($out)"; printf '%s\t%s\t%s\t-\t0\tdecide-failed\t%s\n' "$NAME" $s $r "$out" >> "$E/stream-pmax.tsv"; return 0; }
  IFS=$'\t' read -r v _ f <<< "$out"
  if [ "$v" = none ]; then
    echo "MAIN NOTE $NAME: no pmax step ($f)"
    printf '%s\t%s\t%s\t-\t0\tskipped\t%s\n' "$NAME" $s $r "$f" >> "$E/stream-pmax.tsv"; return 0
  fi
  echo "$NAME pmax: loadgen seed $fs, $v query/s ($f)" >> "$E/seeds.txt"
  measure "$LS" pmax "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$v" \
    --warmup-s "${STREAM_PMAX_SETTLE_S:-30}" --step-warmup-s 5 --step-measure-s "${STREAM_PMAX_S:-60}" --drain-s 10
  rc=$?
  if [ $rc != 0 ]; then st="loadgen-rc$rc"
  else
    python3 $X/stream_check.py "$RD" > "$RD/stream-check.txt" 2>&1
    python3 $X/check_breakdown.py "$RD" > "$RD/breakdown-check.txt" 2>&1
    grep -qE '^STREAMCHECK (PASS|NOTE)' "$RD/stream-check.txt" || st="streamcheck:$(grep -m1 '^STREAMCHECK' "$RD/stream-check.txt" | cut -d' ' -f2)"
    grep -q '^BREAKDOWN PASS' "$RD/breakdown-check.txt" || st="$st,breakdown-fail"
  fi
  [ "$st" = ok ] || echo "MAIN NOTE $NAME pmax: $st (the slo row stands; see $RD)"
  printf '%s\t%s\t%s\t%s\t1\t%s\t%s\n' "$NAME" $s $r "$v" "$st" "$f" >> "$E/stream-pmax.tsv"
  echo "$NAME pmax: $v query/s status $st"
}
auc_q() {  # <rate>: query rate of the rate's STREAM_AUC entry (empty = no AUC lifetime at this rate)
  local m
  for m in ${STREAM_AUC:-}; do [ "${m%%=*}" = "$1" ] && { echo "${m#*=}"; return 0; }; done
}
stream_auc() {  # <sys> <rate> <query/s>: AUC lifetime body (header "STREAM_AUC"): warm-up as stream_slo, then part auc
  local s=$1 r=$2 q=$3 RD=$LS/auc rc fs=$((SEED + 3)) st=ok sb
  measure "$LS" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 50 --drain-s 10
  rc=$?; [ $rc = 0 ] || stop "$NAME warm-up rc $rc"
  pub_after "$LS/warmup"
  sb=$(cat "$LS/seq_base")
  [ -s "$E/stream-auc.tsv" ] || printf '# name\tsystem\trate_sps\tauc_q_s\tseq_base\tstatus\n' > "$E/stream-auc.tsv"
  echo "$NAME auc: loadgen seed $fs, $q query/s, seq_base $sb" >> "$E/seeds.txt"
  measure "$LS" auc "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$q" \
    --warmup-s "${STREAM_AUC_SETTLE_S:-30}" --step-warmup-s 5 --step-measure-s "${STREAM_AUC_S:-300}" --drain-s 10
  rc=$?
  grep -q 'workload_finish":"ok' "$RD/loadgen/summary.json" 2>/dev/null || stop "$NAME auc: loadgen workload finish (rc $rc)"
  if [ $rc = 1 ]; then  # as stream_slo: loadgen rc 1 with a note is a recorded result (status), not a stop
    local note
    note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$RD/loadgen/summary.json" 2>/dev/null)
    [ -n "$note" ] || stop "$NAME auc: loadgen rc 1 without a note"
    st="loadgen-rc1"; echo "MAIN NOTE $NAME auc: $note"
  elif [ $rc != 0 ]; then stop "$NAME auc rc $rc"; fi
  python3 $X/stream_check.py "$RD" > "$RD/stream-check.txt" 2>&1
  python3 $X/check_breakdown.py "$RD" > "$RD/breakdown-check.txt" 2>&1
  grep -qE '^STREAMCHECK (PASS|NOTE)' "$RD/stream-check.txt" || st="$st,streamcheck:$(grep -m1 '^STREAMCHECK' "$RD/stream-check.txt" | cut -d' ' -f2)"
  grep -q '^BREAKDOWN PASS' "$RD/breakdown-check.txt" || st="$st,breakdown-fail"
  st=${st#ok,}
  v7_post "$s" "$r" "$RD" "$E/auc_part.csv"
  [ "$st" = ok ] || echo "MAIN NOTE $NAME auc: $st (see $RD)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NAME" $s $r "$q" "$sb" "$st" >> "$E/stream-auc.tsv"
  echo "$NAME auc: $q query/s seq_base $sb status $st"
  stream_auc2 $s $r
}
# STREAM_AUC2="<rate>=<q1>,<q2>,.. ..." (header "STREAM_AUC2"; recsys-windowed-update chain v8, user 2026-11-13: equal
#   samples near the knee): after part auc of the rate's AUC lifetime, one part fix2-<k> per listed query rate (same
#   absolute rates for every system of the block): loadgen --raw --mode fixed --rates <q_k> --warmup-s 0 --step-warmup-s 5
#   --step-measure-s STREAM_AUC2_S (120) --drain-s 10 (+ --drain-full-s STREAM_DRAIN_FULL_S when set), seed SEED + 10 + k.
#   One part per rate = own pre/post snapshots (De Stijl SS-residence histogram per rate, session.sh ss_snap). Checks as
#   part auc (workload finish other than ok, rc > 1 or rc 1 without a note = stop; stream_check / check_breakdown
#   recorded); rows <E>/stream-fix2.tsv: name system rate_sps part q_s status. Unset = no fix2 part (every earlier run).
stream_auc2() {  # <sys> <rate>
  local s=$1 r=$2 m qs="" q k=0 RD rc st fs note dr=()
  for m in ${STREAM_AUC2:-}; do [ "${m%%=*}" = "$r" ] && qs=${m#*=}; done
  [ -n "$qs" ] || return 0
  [ -z "${STREAM_DRAIN_FULL_S:-}" ] || dr=(--drain-full-s "$STREAM_DRAIN_FULL_S")
  [ -s "$E/stream-fix2.tsv" ] || printf '# name\tsystem\trate_sps\tpart\tq_s\tstatus\n' > "$E/stream-fix2.tsv"
  for q in ${qs//,/ }; do
    k=$((k + 1)) RD=$LS/fix2-$k st=ok fs=$((SEED + 10 + k))
    echo "$NAME fix2-$k: loadgen seed $fs, $q query/s" >> "$E/seeds.txt"
    measure "$LS" fix2-$k "${LGC[@]}" --opt seed=$fs --seed $fs --raw --mode fixed --rates "$q" \
      --warmup-s 0 --step-warmup-s 5 --step-measure-s "${STREAM_AUC2_S:-120}" --drain-s 10 ${dr[@]+"${dr[@]}"}
    rc=$?
    grep -q 'workload_finish":"ok' "$RD/loadgen/summary.json" 2>/dev/null || stop "$NAME fix2-$k: loadgen workload finish (rc $rc)"
    if [ $rc = 1 ]; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$RD/loadgen/summary.json" 2>/dev/null)
      [ -n "$note" ] || stop "$NAME fix2-$k: loadgen rc 1 without a note"
      st="loadgen-rc1"; echo "MAIN NOTE $NAME fix2-$k: $note"
    elif [ $rc != 0 ]; then stop "$NAME fix2-$k rc $rc"; fi
    python3 $X/stream_check.py "$RD" > "$RD/stream-check.txt" 2>&1
    python3 $X/check_breakdown.py "$RD" > "$RD/breakdown-check.txt" 2>&1
    grep -qE '^STREAMCHECK (PASS|NOTE)' "$RD/stream-check.txt" || st="$st,streamcheck:$(grep -m1 '^STREAMCHECK' "$RD/stream-check.txt" | cut -d' ' -f2)"
    grep -q '^BREAKDOWN PASS' "$RD/breakdown-check.txt" || st="$st,breakdown-fail"
    st=${st#ok,}
    # recsys-training-auc (STREAM_AUC2_V7POST=1): stale logs + v7_metrics.py per part, rows in <E>/auc_fix2.csv
    [ "${STREAM_AUC2_V7POST:-0}" = 0 ] || v7_post "$s" "$r" "$RD" "$E/auc_fix2.csv"
    [ "$st" = ok ] || echo "MAIN NOTE $NAME fix2-$k: $st (see $RD)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NAME" $s $r "fix2-$k" "$q" "$st" >> "$E/stream-fix2.tsv"
    echo "$NAME fix2-$k: $q query/s status $st"
  done
}
eval_stream_rate() {  # <rate>
  local r=$1 s ord="" defer=0 fixonly=" ${STREAM_FIXONLY:-} "
  for s in $(h1shuffle recsys-stream-$r $(for x in ${SYSTEMS:-hw pop}; do [ $x = mgoff ] || echo $x; done)); do
    ord="$ord $s"; [ $s = mg ] && [[ " ${SYSTEMS:-} " == *" mgoff "* ]] && ord="$ord mgoff"
  done
  # mgoff without mg (rs-h1 fix block when mg's windows came from the probe): mgoff alone, last (rs-h1-v4 measured nothing)
  [[ " ${SYSTEMS:-} " == *" mgoff "* && " ${SYSTEMS:-} " != *" mg "* ]] && ord="$ord mgoff"
  echo "u$r eval order:$ord (fix-only:${STREAM_FIXONLY:-none}; levels: $(eval_tokens $r | tr ' ' ',') fallback ${STREAM_FIX_FALLBACK:-none} sep ${STREAM_FIX_SEP:-1})" | tee -a "$E/order.txt"
  if [ -n "${STREAM_LEVELS:-}" ] && ! grep -q "^$r	" "$E/stream-levels.tsv" 2>/dev/null; then
    awk -v r="$r" -v f="$STREAM_LEVELS" -F'\t' '!/^#/ && $1 == r { printf "%s\t%s\t%s\tfrom %s (%s)\n", $1, $2, $3, f, $4 }' "$STREAM_LEVELS" | tail -1 >> "$E/stream-levels.tsv"
  fi
  local toks; toks=$(eval_tokens $r)
  FIXRATES= FIXTOKS=
  if [ -n "$toks" ]; then
    eval_levels_known $r || defer=1
    [ "${STREAM_FIX_SEP:-1}" = 0 ] || defer=1
  fi
  for s in $ord; do
    [ "${STREAM_AUC_ONLY:-0}" = 0 ] || [[ $fixonly == *" $s "* ]] || continue   # AUC lifetimes only (stream_auc_rate)
    echo "$(date -Is) stream u$r system $s"
    if [[ $fixonly == *" $s "* ]]; then
      [ $defer = 1 ] && continue
      life_start $s $s-u$r-fix; stream_fix $s $r; life_stop $s
    else
      life_start $s $s-u$r; stream_slo $s $r
      [ -z "$toks" ] || [ $defer = 1 ] || stream_fix $s $r
      stream_pmax $s $r   # run 2 (STREAM_PMAX=1, pop / ds only): one appended fixed step at Popcorn's max
      life_stop $s
    fi
  done
  [ $defer = 1 ] || return 0
  if ! eval_levels_known $r; then
    eval_levels_compute $r
    eval_levels_known $r || stop "u$r: fixed-load levels unresolved ($(tail -1 "$E/stream-levels.tsv"))"
  fi
  [ -n "$FIXRATES" ] || { echo "MAIN NOTE u$r: no fixed-load window ($(tail -1 "$E/stream-levels.tsv"); no fallback)"; return 0; }
  for s in $ord; do life_start $s $s-u$r-fix; stream_fix $s $r; life_stop $s; done
}
stream_auc_rate() {  # <rate>: the rate's AUC lifetimes (STREAM_AUC), after every SLO / fix lifetime of the rate
  local r=$1 q s fixonly=" ${STREAM_FIXONLY:-} "
  q=$(auc_q $r)
  [ -n "$q" ] || return 0
  for s in $(h1shuffle recsys-stream-$r $(for x in ${SYSTEMS:-hw pop}; do [ $x = mgoff ] || echo $x; done)); do
    [[ $fixonly == *" $s "* ]] && continue
    echo "$(date -Is) stream u$r system $s auc ($q query/s)"
    life_start $s $s-u$r-auc; stream_auc $s $r $q; life_stop $s
  done
}
# ---- STREAM_ONE_LIFETIME=1 (header): every rate in one mg lifetime; called only when ONEL=1
ol_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }   # <snapshot file> <key>
ol_acc() {  # <part dir> <rate>: "<accepted_per_s weighted by window_s> <PASS|FAIL>" from stream-check.csv (10 % band)
  python3 -I - "$1/stream-check.csv" "$2" <<'PY'
import csv, sys
r = float(sys.argv[2])
try:
    rows = list(csv.DictReader(open(sys.argv[1])))
except OSError:
    rows = []
w = [(float(x["accepted_per_s"]), float(x["window_s"])) for x in rows if x.get("accepted_per_s") and x.get("window_s")]
off = all(abs(float(x["update_offered"]) - r) <= 1e-6 * r for x in rows) and bool(rows)
t = sum(b for _, b in w)
a = sum(x * b for x, b in w) / t if t > 0 else 0.0
print(f"{a:.3f} {'PASS' if off and t > 0 and 0.9 * r <= a <= 1.1 * r else 'FAIL'}")
PY
}
ol_rate() {  # <rate>: the rate's parts in the one mg lifetime (first rate: life_start; later: continuation dir + settle)
  local r=$1 d prev sw sb t0 t1 rc acc0 accs c pw1
  OL_N=$((OL_N + 1))
  echo "u$r eval order: mg (one lifetime: rate $OL_N of [$STREAM_RATES]$([ $OL_N = 1 ] || echo ", session $OL_NAME0, settle $OLSET s"))" | tee -a "$E/order.txt"
  [ -s "$E/one-lifetime.tsv" ] || printf '# name\trate_sps\tsession\tswitch_from\tseq_base_at_switch\tpublish_window_at_switch\tpublished_rows_at_switch\twindow_distinct_at_switch\tpublish_backlog_at_switch\tupdate_accepted_seq_at_switch\tsettle_start\tsettle_end\tsettle_s\tpublish_window_after_settle\tsettle_accepted_per_s\tslo_accepted_per_s\trate_check\tpublish_backlog_after_settle\tsettle_extended_s\tpublisher_check\n' > "$E/one-lifetime.tsv"
  echo "$(date -Is) stream u$r system mg (one lifetime, rate $OL_N)"
  if [ $OL_N = 1 ]; then   # exactly the per-lifetime sequence of eval_stream_rate (life_start includes pubtrain)
    OL_T0=$(date +%s)
    life_start mg mg-u$r
    OL_S0=$LS OL_NAME0=$NAME OL_STALE=$NAME
    stream_slo mg $r
    accs=$(ol_acc "$LS/slo" $r)
    printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\t-\t-\t-\n' "$NAME" $r "$OL_NAME0" "${accs% *}" "first rate (pubtrain; slo accepted ${accs#* })" >> "$E/one-lifetime.tsv"
    return 0
  fi
  # the server lifetime bound (timeout XT on every node): stop before a rate that cannot finish (settle + W + 30 min)
  [ $(( $(date +%s) - OL_T0 + OLSET + PUBW + 1800 )) -le "$XT" ] || stop "one lifetime: $(( $(date +%s) - OL_T0 )) s of XT $XT s used; no room for u$r (settle $OLSET s + $PUBW s + 1800 s)"
  prev=$LS d=$E/mg-u$r sw=$LS/slo/post-t0.txt
  [ ! -e "$d" ] || stop "one lifetime: $d exists"
  mkdir "$d" && cp "$OL_S0/session.env" "$OL_S0/session-manifest.txt" "$d/" && cp "$prev/seq_base" "$d/seq_base" || stop "one lifetime: continuation dir $d"
  sb=$(cat "$d/seq_base")
  { echo "# continuation of server lifetime $OL_NAME0 (main-block.sh STREAM_ONE_LIFETIME=1): same servers, no new load"
    echo "session=$OL_S0"; echo "previous_rate_dir=$prev"; echo "rate_sps=$r"; echo "settle_s=$OLSET"
    echo "copied=session.env session-manifest.txt (snapshot at the switch) seq_base=$sb"
    echo "lifetime_files=node logs, final-check, torn-lifetime.txt, stopped: in $OL_S0 after the last rate"
    for c in publish_window published_rows window_distinct publish_backlog publish_queued update_accepted_seq published_seq samples; do
      echo "switch_$c=$(ol_kv "$sw" $c)"; done; } > "$d/one-lifetime.txt"
  OL_DIRS="$OL_DIRS $d"
  LS=$d NAME=mg-u$r
  t0=$(date -Is)
  echo "$(date -Is) $NAME: update stream switched to $r samples/s (seq_base $sb, node 0 publish_window $(ol_kv "$sw" publish_window)); settle $OLSET s, no queries"
  measure "$LS" settle "${LGC[@]}" --opt seed=$((SEED + 101)) --seed $((SEED + 101)) --mode fixed --rates 0 \
    --warmup-s 0 --step-warmup-s 0 --step-measure-s $OLSET --drain-s 2
  rc=$?; [ $rc = 0 ] || stop "$NAME settle rc $rc"
  t1=$(date -Is) pw1=$(ol_kv "$LS/settle/post-t0.txt" publish_window)
  python3 $X/stream_check.py "$LS/settle" > "$LS/settle/stream-check.txt" 2>&1
  acc0=$(ol_acc "$LS/settle" $r)
  { echo "settle_start=$t0"; echo "settle_end=$t1"; echo "settle_publish_window_after=$pw1"; echo "settle_accepted_per_s=${acc0% *} check=${acc0#* }"; } >> "$d/one-lifetime.txt"
  echo "$(date -Is) $NAME: settle done (publish_window $(ol_kv "$sw" publish_window) -> $pw1, accepted ${acc0% *} samples/s, rate check ${acc0#* })"
  if [ "${acc0#* }" != PASS ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\tFAIL settle\t-\t-\t-\n' "$NAME" $r "$OL_NAME0" "$(basename "$prev")" "$sb" \
      "$(ol_kv "$sw" publish_window)" "$(ol_kv "$sw" published_rows)" "$(ol_kv "$sw" window_distinct)" "$(ol_kv "$sw" publish_backlog)" \
      "$(ol_kv "$sw" update_accepted_seq)" "$t0" "$t1" $OLSET "$pw1" "${acc0% *}" >> "$E/one-lifetime.tsv"
    stop "$NAME: the update stream is not at $r samples/s after the switch (settle accepted ${acc0% *}/s; $LS/settle/stream-check.csv)"
  fi
  # publisher check (verifier MED-2): node 0 at the settle end has published >= 2 windows since the switch and its
  # publish_backlog (rows due but not yet written) is <= OL_BACKLOG_MAX. Never a stop (a stop costs the reload):
  # failing once = one more settle part "settle2" of W s, then re-check; failing again = NOTE in this rate's
  # stream-results.tsv note column and one-lifetime.tsv, and the rate goes on
  local pw0 bl1 ext=0 pch
  pw0=$(ol_kv "$sw" publish_window) bl1=$(ol_kv "$LS/settle/post-t0.txt" publish_backlog)
  if ! ol_pubok "$pw0" "$pw1" "$bl1"; then
    echo "$(date -Is) $NAME: publisher check failed after the settle (publish_window $pw0 -> $pw1, publish_backlog $bl1): settle extended by $PUBW s"
    measure "$LS" settle2 "${LGC[@]}" --opt seed=$((SEED + 102)) --seed $((SEED + 102)) --mode fixed --rates 0 \
      --warmup-s 0 --step-warmup-s 0 --step-measure-s $PUBW --drain-s 2
    rc=$?; [ $rc = 0 ] || stop "$NAME settle2 rc $rc"
    ext=$PUBW t1=$(date -Is) pw1=$(ol_kv "$LS/settle2/post-t0.txt" publish_window) bl1=$(ol_kv "$LS/settle2/post-t0.txt" publish_backlog)
  fi
  if ol_pubok "$pw0" "$pw1" "$bl1"; then pch=PASS; else pch="NOTE one-lifetime: publisher behind at u$r (publish_window $pw0 -> $pw1, publish_backlog $bl1 > $OL_BACKLOG_MAX or < 2 windows, settle $OLSET + $ext s)"; fi
  { echo "settle_extended_s=$ext"; echo "settle_end_final=$t1"; echo "publish_window_after_settle_final=$pw1"; echo "publish_backlog_after_settle=$bl1"; echo "publisher_check=$pch"; } >> "$d/one-lifetime.txt"
  [ "$pch" = PASS ] || echo "MAIN NOTE $NAME: $pch"
  stream_slo mg $r   # warmup + pub_after (publishing started long before) + slo, as every lifetime
  if [ "$pch" != PASS ]; then   # this rate's results row (written by stream_slo): append the NOTE to column 12 (note)
    awk -F'\t' -v OFS='\t' -v n="$NAME" -v t="$pch" '!/^#/ && $1 == n { $12 = ($12 == "" ? t : $12 "; " t) } { print }' \
      "$E/stream-results.tsv" > "$E/stream-results.tsv.ol" && mv "$E/stream-results.tsv.ol" "$E/stream-results.tsv" || stop "$NAME: results note"
  fi
  accs=$(ol_acc "$LS/slo" $r)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NAME" $r "$OL_NAME0" "$(basename "$prev")" "$sb" \
    "$pw0" "$(ol_kv "$sw" published_rows)" "$(ol_kv "$sw" window_distinct)" "$(ol_kv "$sw" publish_backlog)" \
    "$(ol_kv "$sw" update_accepted_seq)" "$t0" "$t1" $OLSET "$pw1" "${acc0% *}" "${accs% *}" "PASS settle (slo accepted ${accs#* })" \
    "$bl1" "$ext" "$pch" >> "$E/one-lifetime.tsv"
}
# publisher check bound: publish_backlog <= 16 rows (conf-free constant; normal lifetimes keep the publisher on its even
# schedule, the gauge then holds at most a few rows due within one stats read)
OL_BACKLOG_MAX=16
ol_pubok() {  # <publish_window at the switch> <at the settle end> <publish_backlog at the settle end>: 0 = publisher keeps up
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] && [ $(( $2 - $1 )) -ge 2 ] && [ "$3" -le $OL_BACKLOG_MAX ]; }
ol_end() {  # after the last rate: stop the one lifetime (session dir of the first rate)
  local d
  [ -n "$OL_S0" ] || return 0
  LS=$OL_S0 NAME=$OL_NAME0
  life_stop mg
  for d in $OL_DIRS; do echo "lifetime_stopped=$(cat "$OL_S0/stopped" 2>/dev/null) (session.sh stop of $OL_S0)" >> "$d/one-lifetime.txt"; done
  echo "$(date -Is) MAIN one lifetime $OL_NAME0 DONE (rates [$STREAM_RATES], $(( $(date +%s) - OL_T0 )) s)"
}
h1_entry() {  # <name> <sys> <phase> <part> <steps> <lifetime kind>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$H1_MIX" "$3" "$H1_N" "${LS#$E/}/$4" "$5" "$6" >> "$E/h1-runs.tsv"
}

echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD)) K8=$K8 RECV_MODE=$RECV_MODE POP_RECV_MODE=$PRM POP_ADAPT_KO=${POP_ADAPT_KO:-} POP_SRCVERSION=$POPSV RECV_IPOLL=${IPOLL:-} RECV_WATCH_US=${RECV_WATCH_US:-} RECV_S_MAX_US=${RECV_S_MAX_US:-} MEG_BUILD=$MB VM_PLAIN=$VM_PLAIN VM_MEG=$VM_MEG D=$D SEED=$SEED ROUNDS=$ROUNDS FIXED=$FIXED XT=$XT MG_RPO_OPT='$MG_RPO_OPT' MG_TABLE_N=$MG_TABLE_N MG_ROW_N=$MG_ROW_N V1_OPFAIL_CONTINUE='$V1_OPFAIL_CONTINUE' MG_COH_SAMPLE='$MG_COH_SAMPLE'"
[ $BLOCK = h1 ] && { bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block start"; }
precheck
# update rate for the Ekko operating point (Host compute, after the lock check and the input sha256 check in
# precheck): samples per T so that one round publishes PUBLISH_FRAC of all rows; checked against the calibration
# file EKKO_REF (avg/peak: builds/recsys-inputs/1/rate-frac<frac>.txt; v0.6.10 points: RATE_T_DIR) (+-2 %) when
# V1_EXPECT_RATE is set or BLOCK=h1
declare -A TCHK   # RS_T_MS != 60000: the T-specific recsys-rate check, once per Ekko point per block (about 30 s)
rate_for() {  # <ekko> <out file>: sets UPD_RATE and LGC for that operating point
  ekko_set "$1" || stop "bad Ekko point $1"
  nice -n 19 numactl --cpunodebind=1 --membind=1 "$PLAIN_BUILD/bin/recsys-rate" --samples "$D/$UPD_FILE" --frac $EKKO_FRAC60 \
    --t-ms 60000 --windows 20 > "$2" || stop "recsys-rate"
  UPD_RATE=$(sed -n 's/^rate_samples_per_s=//p' "$2")
  awk -v x="$UPD_RATE" 'BEGIN{exit !(x > 0)}' || stop "bad update rate $UPD_RATE"
  local ex=${V1_EXPECT_RATE:-}
  [ $BLOCK = h1 ] && ex=$(sed -n 's/^rate_samples_per_s=//p' "$EKKO_REF" 2>/dev/null)
  if [ $BLOCK = h1 ] || [ -n "$ex" ]; then
    [ -n "$ex" ] || stop "no calibration file $EKKO_REF"
    awk -v x="$UPD_RATE" -v y="$ex" 'BEGIN{exit !(x >= 0.98 * y && x <= 1.02 * y)}' \
      || stop "update rate $UPD_RATE differs from the expected $ex by more than 2%"
  fi
  if [ "$T_MS" != 60000 ]; then  # v0.6.9: the T-specific target must be the calibration of THIS sample rate at T
    [ "$(calv "$RATE_TF" ref_rate_samples_per_s)" = "$UPD_RATE" ] || stop "$RATE_TF ref_rate_samples_per_s != the Ekko $1 rate $UPD_RATE"
    if [ -z "${TCHK[$1]:-}" ]; then
      nice -n 19 numactl --cpunodebind=1 --membind=1 "$PLAIN_BUILD/bin/recsys-rate" --samples "$D/$UPD_FILE" --frac $PUBLISH_FRAC \
        --t-ms $T_MS --windows "$(calv "$RATE_TF" windows)" > "$E/update-rate-T$T_MS-$1.txt" || stop "recsys-rate T=$T_MS"
      local k
      for k in rows_per_round_target windows rate_samples_per_s; do
        [ "$(calv "$E/update-rate-T$T_MS-$1.txt" $k)" = "$(calv "$RATE_TF" $k)" ] || stop "T = $T_MS ms recsys-rate $k differs from $RATE_TF"
      done
      awk -v x="$(calv "$RATE_TF" rate_samples_per_s)" -v y="$UPD_RATE" 'BEGIN{exit !(x >= 0.99 * y && x <= 1.01 * y)}' \
        || stop "T = $T_MS ms calibration rate differs from the Ekko $1 rate $UPD_RATE by more than 1%"
      TCHK[$1]=ok
    fi
    cp "$E/update-rate-T$T_MS-$1.txt" "$2.T$T_MS" || stop "copy T check"
  fi
  echo "EKKO=$1 publish_frac=$PUBLISH_FRAC update_rate=$UPD_RATE samples/s T_ms=$T_MS ($EKKO_RULE; $2)"
  # seq_base and wrap=1 are appended by session.sh measure (it refuses them from the caller)
  LGC=(--opt samples=$D/$UPD_FILE --opt queries=$D/$QRY_FILE
       --opt quantiles=$D/dist_quantile.txt --fixed update=$UPD_RATE --mix query=1 --x-stream query)
}
h1shuffle() { local seed=$1; shift; python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$seed" "$@"; }
h1_ekko() { case $1 in EKKO=avg|EKKO=peak|EKKO=f087|EKKO=f149|EKKO=f253|EKKO=f330|EKKO=f350|EKKO=f370|EKKO=f400|EKKO=f385|EKKO=f392) echo ${1#EKKO=};; *) return 1;; esac; }
# v0.6.16 (user 2026-10-19, choice (A): one confirmation run): a mix parameter may end in ",POPSTART=<n>" = the start
# rate of the Popcorn SLO search of that mix (loadgen --start n instead of 1); every other system and every other
# setting unchanged. Without the suffix (every h1-plan.tsv row) the search starts at 1 as before.
h1_mixparse() {  # <mix parameter> -> "<ekko point> <pop start rate>"; rc 1 on a bad parameter
  local p=$1 ps=1 ek
  if [[ $p == *,POPSTART=* ]]; then ps=${p##*,POPSTART=}; p=${p%,POPSTART=*}; [[ $ps =~ ^[1-9][0-9]*$ ]] || return 1; fi
  ek=$(h1_ekko "$p") || return 1
  echo "$ek $ps"
}
if [ $BLOCK = h1 ]; then  # H1-HOOK v2 driver (header)
  printf '# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n' > "$E/h1-runs.tsv"
  declare -A EK POPST
  for spec in $H1_MIXES; do
    mp=$(h1_mixparse "${spec#*=}") || stop "bad mix parameter $spec"
    EK[${spec%%=*}]=${mp% *} POPST[${spec%%=*}]=${mp#* }
  done
  mixes=$(h1shuffle H1-recsys-r$H1_N $(printf "%s\n" "${!EK[@]}" | sort))
  lv_rates() {  # <mix>: "<L2_rate> <L1_rate>" from H1_LEVELS (cont)
    awk -F'\t' -v m="$1" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
      $1 == m { print $(c["L2_rate"]), $(c["L1_rate"]); f = 1 } END { exit f ? 0 : 1 }' "$H1_LEVELS"; }
  if [ $H1MODE = cont ] && [ $H1MG = 0 ]; then  # v0.6.7: hw, pop only
    base=($(h1shuffle H1-recsys-latin hw pop)); rot=$(( H1_N % 2 ))
    ord="${base[*]:$rot} ${base[*]:0:$rot}"; ord=$(echo $ord)
  elif [ $H1MODE = cont ]; then
    base=($(h1shuffle H1-recsys-latin hw pop mg)); rot=$(( H1_N % 3 ))
    ord="${base[*]:$rot} ${base[*]:0:$rot}"; ord=$(echo $ord)
  fi
  { echo "# H1 DLRM recsys $H1MODE round $H1_N (H1-HOOK v2; systems $H1_SYSTEMS; loadgen seed $SEED; settle $H1_SETTLE_S s at L2; mixes: shuffle seed H1-recsys-r$H1_N)"
    echo "mixes: $mixes"; echo "H1_MIXES: $H1_MIXES"
    for m in $mixes; do
      if [ $H1MODE = r1 ] && [ $H1MG = 0 ]; then
        echo "$m: slo-only $(h1shuffle H1-recsys-r1-$m hw pop); levels; fix-only $(h1shuffle H1-recsys-r1-$m-fix hw pop)"
      elif [ $H1MODE = r1 ]; then
        echo "$m: slo-only $(h1shuffle H1-recsys-r1-$m hw pop); mg (slo -> levels -> fix); mgoff (fix); fix-only $(h1shuffle H1-recsys-r1-$m-fix hw pop)"
      else
        echo "$m: $ord (each slo -> fix$([ $H1MG = 1 ] && echo "; mgoff fix right after mg"); latin seed H1-recsys-latin rotated left by $rot); levels $(lv_rates $m || echo MISSING)"
      fi
    done; } | tee "$E/order.txt"
  for m in $mixes; do
    H1_MIX=$m
    if [ $H1MODE = r1 ]; then
      for s in $(h1shuffle H1-recsys-r1-$m hw pop); do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-slo-r1.txt"
        life_start $s $s-$m-slo-r1; h1_slo $s; h1_entry $NAME $s slo slo - sep; life_stop $s
      done
      if [ $H1MG = 1 ]; then
      rate_for ${EK[$m]} "$E/update-rate-mg-$m-r1.txt"
      life_start mg mg-$m-r1; h1_slo mg; h1_entry $NAME-slo mg slo slo - cont
      fi
      # levels of the mix: inside the mg lifetime (hw pop mg) or after the hw/pop SLO-only lifetimes (hw pop, v0.6.7)
      lv=$("$H1_LEVELS_CMD" $m 2> "$E/levels-cb-$m.err") || stop "LEVELS STOP $m: $(cat "$E/levels-cb-$m.err")"
      read -r l2 l1 <<< "$lv"
      awk -v a="$l2" -v b="$l1" 'BEGIN { exit !(a > 0 && b > a) }' || stop "LEVELS STOP $m: bad rates '$lv'"
      echo "levels $m: L2=$l2 L1=$l1" | tee -a "$E/levels-used.txt"
      if [ $H1MG = 1 ]; then
      h1_fix mg $l2 $l1; h1_entry $NAME-fix mg fix fix $H1STEPS cont; life_stop mg
      rate_for ${EK[$m]} "$E/update-rate-mgoff-$m-fix-r1.txt"
      life_start mgoff mgoff-$m-fix-r1; h1_fix mgoff $l2 $l1; h1_entry $NAME mgoff fix fix $H1STEPS sep; life_stop mgoff
      fi
      for s in $(h1shuffle H1-recsys-r1-$m-fix hw pop); do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-fix-r1.txt"
        life_start $s $s-$m-fix-r1; h1_fix $s $l2 $l1; h1_entry $NAME $s fix fix $H1STEPS sep; life_stop $s
      done
    else
      lv=$(lv_rates $m) || stop "no levels for $m in $H1_LEVELS"
      read -r l2 l1 <<< "$lv"
      awk -v a="$l2" -v b="$l1" 'BEGIN { exit !(a > 0 && b > a) }' || stop "bad levels for $m: '$lv'"
      echo "levels $m: L2=$l2 L1=$l1" | tee -a "$E/levels-used.txt"
      for s in $ord; do
        rate_for ${EK[$m]} "$E/update-rate-$s-$m-r$H1_N.txt"
        life_start $s $s-$m-r$H1_N; h1_slo $s; h1_entry $NAME-slo $s slo slo - cont
        h1_fix $s $l2 $l1; h1_entry $NAME-fix $s fix fix $H1STEPS cont; life_stop $s
        if [ $s = mg ]; then
          rate_for ${EK[$m]} "$E/update-rate-mgoff-$m-fix-r$H1_N.txt"
          life_start mgoff mgoff-$m-fix-r$H1_N; h1_fix mgoff $l2 $l1; h1_entry $NAME mgoff fix fix $H1STEPS sep; life_stop mgoff
        fi
      done
    fi
  done
  bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block end"
  echo "$(date -Is) SEQUENCE DONE H1-recsys $H1MODE r$H1_N ($(($(wc -l < "$E/h1-runs.tsv") - 1)) entries)"
  exit 0
fi
if [ $BLOCK = stream ]; then  # RecSys streaming driver (header "BLOCK=stream")
  bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block start"
  { echo "# update rate basis (RecSys methodology, user 2026-10-19; workloads/recsys/DESIGN.md §5.1): rates in trace samples/s, multiples of 50"
    echo "ekko_avg: 3.08% distinct rows per 3600 s -> 41.47 samples/s -> 50; ekko_peak: 4.3% distinct rows per 600 s -> 393.27 samples/s -> 400 (recsys-rate, workspaces/recsys-mid/ekko10min)"
    echo "rates: $STREAM_RATES (> 400 = stress)"; } > "$E/rate-basis.txt"
  printf '# name\tsystem\trate_sps\tresult_q_s\tconfirm_x_mean\tconfirmed\tlow_rate_violations\tstreamcheck\tvalid\tramp_end\tknee_q_s\tnote\n' > "$E/stream-results.tsv"
  if [ -n "${EVAL_RUN:-}" ]; then
    printf '# name\tsystem\trate_sps\tlevel\toffered_q_s\tstep\tvalid\n' > "$E/stream-fix.tsv"
    printf '# rate_sps\tL1_q_s\tL2_q_s\tsource\n' > "$E/stream-levels.tsv"
    { echo "EVAL_RUN=$EVAL_RUN RS_THREADS=$RS_THREADS REGION=$REGION sha256=$(sha256sum < "$REGION" | cut -c1-64)"
      echo "SYSTEMS=${SYSTEMS:-hw pop} STREAM_FIXONLY=${STREAM_FIXONLY:-} STREAM_FIX_LEVELS=${STREAM_FIX_LEVELS:-} STREAM_FIX_LEVELS_MAP=${STREAM_FIX_LEVELS_MAP:-} STREAM_FIX_FALLBACK=${STREAM_FIX_FALLBACK:-} STREAM_FIX_SEP=${STREAM_FIX_SEP:-1} STREAM_LEVELS=${STREAM_LEVELS:-}"
      echo "STREAM_FIX_S=${STREAM_FIX_S:-60} STREAM_FIX_SETTLE_S=${STREAM_FIX_SETTLE_S:-60} server_args=[$SA] node0_extra=[$N0X]"
      echo "slo=query:$SLO_PCT:$SLO_MS ($SLO_RULE) max_confirm_probes=$STREAM_CONFIRM_PROBES"
      [ -z "${STREAM_AUC:-}" ] || echo "STREAM_AUC=[$STREAM_AUC] STREAM_AUC_S=${STREAM_AUC_S:-300} STREAM_AUC_SETTLE_S=${STREAM_AUC_SETTLE_S:-30} STREAM_AUC_ONLY=${STREAM_AUC_ONLY:-0} seed=$((SEED + 3))"
      [ -z "${STREAM_AUC2:-}" ] || echo "STREAM_AUC2=[$STREAM_AUC2] STREAM_AUC2_S=${STREAM_AUC2_S:-120} drain_full_s=${STREAM_DRAIN_FULL_S:-none} seed=$((SEED + 10))+k"
      [ -z "${STREAM_SLO_TOL:-}" ] || echo "slo_tol=$SSTOL (STREAM_SLO_TOL: loadgen --tol of the SLO search; unset = 0.02)"
      [ -z "${STREAM_DRAIN_FULL_S:-}" ] || echo "slo_drain_full_s=$STREAM_DRAIN_FULL_S (STREAM_DRAIN_FULL_S: loadgen --drain-full-s of the SLO search; unset = not passed)"
      [ -z "${STREAM_DRAIN_FAIL_S:-}" ] || echo "slo_drain_fail_s=$STREAM_DRAIN_FAIL_S (STREAM_DRAIN_FAIL_S: loadgen --drain-fail-s; unset = not passed)"
      [ -z "${STREAM_CONFIRM_RULE:-}" ] || echo "slo_confirm_rule=$STREAM_CONFIRM_RULE (STREAM_CONFIRM_RULE: loadgen --confirm-rule; unset = majority)"
      [ -z "${STREAM_CONFIRM_REPS:-}" ] || echo "slo_confirm_reps=$STREAM_CONFIRM_REPS (STREAM_CONFIRM_REPS: loadgen --confirm-reps; unset = 3)"
      [ -z "${STREAM_CONFIRM_S:-}" ] || echo "slo_confirm_s=$STREAM_CONFIRM_S (STREAM_CONFIRM_S: loadgen --confirm-s; unset = 30)"
      [ -z "${STREAM_CONFIRM_FULL:-}" ] || echo "slo_confirm_full=1 (STREAM_CONFIRM_FULL: loadgen --confirm-full; unset = not passed)"
      [ -z "${STREAM_SLO_START:-}" ] || echo "slo_start=$SSSTART (STREAM_SLO_START: loadgen --start of the SLO search; unset = 1)"
      [ -z "${STREAM_SLO_FILL:-}" ] || echo "slo_fill=$STREAM_SLO_FILL (STREAM_SLO_FILL: loadgen --fill; unset = not passed)"
      [ -z "${STREAM_SLO_OVERLOAD:-}" ] || echo "slo_overload=$STREAM_SLO_OVERLOAD base result (STREAM_SLO_OVERLOAD: loadgen --overload-base result --overload; unset = not passed)"
      [ "$ONEL" = 0 ] || echo "one_lifetime=1 settle_s=$OLSET (STREAM_ONE_LIFETIME: rates [$STREAM_RATES] in one mg lifetime; later rates: settle part seed $((SEED + 101)), XT $XT s)"; } | tee "$E/eval-params.txt"
  fi
  { echo "# RecSys streaming block: per rate (in STREAM_RATES order) one lifetime per system, order shuffle(seed recsys-stream-<rate>)"
    for r in $STREAM_RATES; do echo "u$r: $(h1shuffle recsys-stream-$r ${SYSTEMS:-hw pop})"; done; } | tee "$E/order.txt"
  for r in $STREAM_RATES; do
    lab=""; [ $r -le 400 ] || lab=" (stress, above Ekko peak)"
    LGC=(--opt samples=$D/$UPD_FILE --opt queries=$D/$QRY_FILE
         --opt quantiles=$D/dist_quantile.txt --fixed update=$r --mix query=1 --x-stream query)
    v7_lgc $r
    U0=0; [ "$r" != 0 ] || U0=1   # header "U0"
    if [ "$ONEL" = 1 ]; then ol_rate $r; continue; fi   # STREAM_ONE_LIFETIME=1 only
    if [ -n "${EVAL_RUN:-}" ]; then eval_stream_rate $r; stream_auc_rate $r; continue; fi
    for s in $(h1shuffle recsys-stream-$r ${SYSTEMS:-hw pop}); do
      echo "$(date -Is) stream u$r$lab system $s"
      life_start $s $s-u$r; stream_slo $s $r; life_stop $s
    done
  done
  [ "$ONEL" = 0 ] || ol_end   # STREAM_ONE_LIFETIME=1: stop the one lifetime after the last rate
  bash $PTG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" || stop "pretouch gate at block end"
  echo "$(date -Is) SEQUENCE DONE $OWNER (stream rates $STREAM_RATES)"
  exit 0
fi
RATEF=$E/sequence-update-rate.txt
rate_for "$EKKO" "$RATEF"
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE (fixed; no all-HWcc in this block)" | tee "$E/slo.txt"
  [ -z "${L_FROM:-}" ] || { cp "$L_FROM" "$E/fixed-load-L.txt" && echo "L imported from $L_FROM: $(cat "$E/fixed-load-L.txt")"; }
fi
if [ $BLOCK = v1 ]; then ORDER="hw pop mg mgoff"; [[ " ${SYSTEMS:-} " == *" mgrow "* ]] && ORDER="hw pop mgrow mg mgoff"; else ORDER="hw $(shuffle pop mg)"; fi
echo "system order: $ORDER (all-HWcc first; page MSI / Megalon shuffled with seed $OWNER)" | tee "$E/order.txt"
if [ -n "${SYSTEMS:-}" ]; then  # subset rerun: keep the seeded order, drop the others
  O2=""; for s in $ORDER; do [[ " $SYSTEMS " == *" $s "* ]] && O2="$O2 $s"; done; ORDER=${O2# }
  echo "SYSTEMS=\"$SYSTEMS\" -> run: $ORDER" | tee -a "$E/order.txt"
fi
for s in $ORDER; do system $s; done
if [ $BLOCK = v1 ] && [ -d "$E/hw/val" ] && [ -d "$E/mgoff/val" ]; then  # Megalon C_diff = T(mgoff) - T(hw) (user 2026-10-17)
  python3 $X/v1_cdiff.py "$E" | tee "$E/cdiff.txt" | tee -a "$E/v1-checks.txt"
  grep -q "^CDIFF DONE" "$E/cdiff.txt" || stop "C_diff: $(cat "$E/cdiff.txt")"
fi
echo "$(date -Is) SEQUENCE DONE $OWNER"

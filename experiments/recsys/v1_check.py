#!/usr/bin/env python3
"""RECSYS-V1 validation checks of one measurement window (reports/RECSYS-V1-packet.md §3).

usage: v1_check.py <measurement dir> <hw|pop|mg|mgoff> [--h1] [--oppoint-report] [--mg-sample N]
--mg-sample N (RECSYS-V1 v1.4, user decision 2026-10-18: time every Megalon section for the table objects, N = 1):
  mg / mgoff only: FAIL unless op.query.mg.check_sample (node 1) and op.row_update.mg.check_sample (node 0) at the
  window end equal N (MEGALON_COH_CHECK_SAMPLE reached the server). Every estimator is a ratio x * sections / timed
  sections (breakdown.py), so N = 1 means scale factor 1; the flags check (lean sampling, not events_always) is
  unchanged. Without the option nothing about the sample rate is checked (as before).
--oppoint-report (RECSYS-V1 v1.4, main-block.sh V1_OPFAIL_CONTINUE; only with a user decision): if every failed
  check is an operating-point check (updater behind / aborted-saturated step, < 2 publication rounds, flush overruns,
  update_rate_sustained, round guard, rows per full round incl. "cannot normalise" for 0 samples published), print
  "V1CHECK OPFAIL <system> ..." and exit 3 instead of FAIL / 1. Any other failure (torn rows, misses, queries, system
  checks) keeps FAIL / 1. Without the flag the behaviour is unchanged.
--h1 (H1 main runs, reports/H1-main-packet.md §8.1 "DLRM: v1_check-style invariants (torn rows 0, updater sustained
  +-2 %, flush_overruns 0)"; coordinator 2026-10-17): updater limit 0.98 x updates sent in the step (v0.6.8, user
  2026-10-18; was 0.98 x the nominal offered rate, which flagged Poisson-low steps). SLO searches (summary mode slo)
  include points past the knee on purpose: the update checks (updater, flush_overruns 0, round guard, rows per full
  round +-15 %) use only the steps that passed the SLO, outside the overload phase, at offered x <=
  max_offered_x_pass, each over its own node-0 snapshots; violations on other steps are NOTEs, never a stop. Fixed
  runs (L2/L1 <= the weakest max) keep every check over the whole span as FAIL. Torn rows / misses and the system
  checks are whole-span FAILs in every mode.
Round accounting guard (verifier LOW 15): flushes = update_threads x publish_rounds at both window snapshots of
  node 0 (update_threads from the manifest's server_args); else FAIL (a snapshot inside a round edge).
A missing rows_per_round_target (0) is a FAIL (verifier LOW 18).
Reads <dir>/loadgen/stats/step<N>-{begin,end}-t{0,1}.txt of the measured step(s) (t0 = updater node 0, t1 = serving
node 1; window deltas) and <dir>/breakdown.csv. Checks (FAIL = stop the block):
  all   torn_rows delta 0, misses 0, update_misses 0; >= 1 query; >= 2 publication rounds in the window;
        flush_overruns delta 0 and update_rate_sustained=1 (no round longer than T); the updater keeps up: every
        measured loadgen step has update completions in the window (achieved x measure_s) >= 0.95 x updates sent in
        the step (v0.6.8; loadgen's own keep-up rule; >= 100 sent, else FAIL; achieved/offered is printed as
        information only), no saturated/aborted step (steps.jsonl); rows
        published per round within +-15% of rows_per_round_target (when a target is set), normalised by the samples
        published in the window (v1.2.7, user 2026-10-17): rows_per_full_round = d(round_rows) / (d(published_seq) /
        (R x T)), R = the configured update rate (manifest loadgen_args "--fixed update=R"), T = publish_us / 1e6 of
        the t0 end snapshot; d(published_seq) on t0 = samples made visible by the rounds that fired in the window.
        The plain window mean d(round_rows) / d(publish_rounds) is reported (rows_per_round_window_mean), not
        checked: the server's round clock is not aligned to the window, so the first round may be partly fed
        (known bias, verifier LOW 16: a partly fed round de-duplicates less, so the normalised value leans about
        +1-3 % high; it can hide a shortfall of that size, never invent one; workloads/recsys/DESIGN.md §5)
  hw    op.query.c_ns and op.row_update.c_ns deltas = 0 (all-HWcc has no coherence actions)
  pop   op.coh_src pc_threads > 0 on both nodes (swmc_acct live) and row_update C > 0
  mg    op.coh_src mg_threads > 0 on both nodes, query C > 0, row_update C > 0, anchor read parts > 0;
        op.<o>.mg.flags of both ops: timers on (bit 0), lean sampling (bit 1, Megalon >= 76), not events_always
        (bit 2); timed write sections (op.row_update.mg.anchor.write_sampled delta) > 0 (write-side estimator defined)
  mgoff mg_threads > 0, Megalon read sections > 0, op.<o>.mg.flags present with bit 0 (timers) = 0 for both ops,
        every Megalon duration field of both ops = 0 and present
        (CohSnap *_ns incl. wstart/wflush/switch_rw/reclaim/check_ns_sampled, mg.anchor.*; MEGALON_COH_TIMERS=0)
NOTEs (recorded, no stop): Popcorn query C = 0; WARN mg C_sampled > T per op (Fig 2 Megalon C = C_diff, v1_cdiff.py).
Prints "V1CHECK PASS|FAIL <system> ..." with the values and exits 0 / 1.
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from breakdown import op_c_window  # noqa: E402  (window C incl. the Megalon ratio estimate from window deltas)


def kv(path):
    d = {}
    for line in open(path):
        mm = re.match(r'^([^=\s#]+)=(-?\d+)\s*$', line)
        if mm:
            d[mm.group(1)] = int(mm.group(2))
    return d


def coh_src(path):
    pc = mg = -1
    for line in open(path):
        if line.startswith('op.coh_src='):
            x = dict(t.split(':', 1) for t in line.strip().split('=', 1)[1].split(',') if ':' in t)
            pc, mg = int(x.get('pc_threads', 0)), int(x.get('mg_threads', 0))
    return pc, mg


def main():
    flags, msample = [], None
    a = sys.argv[3:]
    while a:
        f = a.pop(0)
        if f == '--mg-sample' and a and a[0].isdigit() and int(a[0]) >= 1 and msample is None:
            msample = int(a.pop(0))
        elif f in ('--h1', '--oppoint-report') and f not in flags:
            flags.append(f)
        else:
            sys.exit(__doc__)
    h1, opr = '--h1' in flags, '--oppoint-report' in flags
    if len(sys.argv) < 3 or sys.argv[2] not in ('hw', 'pop', 'mg', 'mgoff') or (msample and sys.argv[2] not in ('mg', 'mgoff')):
        sys.exit(__doc__)
    m, s = sys.argv[1], sys.argv[2]
    st = os.path.join(m, 'loadgen', 'stats')
    stepno = lambda p: int(re.search(r'step(\d+)-', os.path.basename(p)).group(1))  # noqa: E731
    begins = sorted(glob.glob(os.path.join(st, 'step*-begin-t1.txt')), key=stepno)
    if not begins:
        print(f'V1CHECK FAIL {s} no stats snapshots in {st}')
        sys.exit(1)
    fails, notes, vals = [], [], {}
    opf = []  # operating-point failures (also in fails); --oppoint-report

    def opfail(t):
        fails.append(t)
        opf.append(t)
    # the whole measured span: first step's begin .. last step's end
    b1p, e1p = begins[0], sorted(glob.glob(os.path.join(st, 'step*-end-t1.txt')), key=stepno)[-1]
    b0p, e0p = b1p.replace('-t1.txt', '-t0.txt'), e1p.replace('-t1.txt', '-t0.txt')
    b1, e1, b0, e0 = kv(b1p), kv(e1p), kv(b0p), kv(e0p)
    d1 = lambda k: e1.get(k, 0) - b1.get(k, 0)  # noqa: E731
    d0 = lambda k: e0.get(k, 0) - b0.get(k, 0)  # noqa: E731
    for k in ('torn_rows', 'misses'):
        if d1(k) != 0:
            fails.append(f'{k} delta {d1(k)}')
    if d0('update_misses') != 0:
        fails.append(f'update_misses delta {d0("update_misses")}')
    vals['queries'] = d1('queries')
    if vals['queries'] <= 0:
        fails.append('no query in the window')
    # manifest: configured update rate R (loadgen_args "--fixed update=R") and update threads (server_args)
    rate, ut = None, None
    try:
        for line in open(os.path.join(m, 'manifest.txt')):
            a = line.split()
            if line.startswith('loadgen_args='):
                for i, x in enumerate(a[:-1]):
                    if x == '--fixed':
                        for tok in a[i + 1].split(','):
                            if tok.startswith('update='):
                                rate = float(tok.split('=', 1)[1])
            if line.startswith('server_args='):
                for i, x in enumerate(a[:-1]):
                    if x == '--update-threads':
                        ut = int(a[i + 1])
    except (OSError, ValueError):
        pass
    try:
        steps = [json.loads(re.sub(r'(?<![A-Za-z"])-?(inf|nan)(?![A-Za-z"])', 'NaN', l))
                 for l in open(os.path.join(m, 'loadgen', 'steps.jsonl')) if l.strip()]
    except (OSError, ValueError) as ex:
        steps = []
        fails.append(f'steps.jsonl unreadable: {ex}')
    meas = [d for d in steps if d.get('measure_s', 0) > 0]
    if not meas:
        fails.append('no measured loadgen step')
    try:
        summ = json.load(open(os.path.join(m, 'loadgen', 'summary.json')))
    except (OSError, ValueError):
        summ = {}
    # H1 SLO search (--h1 and summary mode slo; coordinator 2026-10-17): the update checks (updater +-2 %,
    # flush_overruns 0, round guard, rows per full round +-15 %) apply to the steps that passed the SLO, outside the
    # overload phase, at offered x <= max_offered_x_pass; violations on the other steps are NOTEs. Otherwise (v1, H1
    # fixed runs) they apply to the whole measured span (first begin .. last end) and every measured step.
    h1slo = h1 and summ.get('mode') == 'slo'
    xmax = float(summ.get('max_offered_x_pass', 0) or 0)
    def checked(d):
        if not h1slo:
            return True
        return bool(d.get('pass')) and d.get('phase') != 'overload' and not d.get('aborted') \
            and float(d.get('offered_x', 0)) <= xmax * (1 + 1e-9)
    bad = opfail
    lim = 0.98 if h1 else 0.95
    for d in meas:
        u = d.get('streams', {}).get('update', {})
        off, ach = float(u.get('offered', 0)), float(u.get('achieved', 0))
        sent, win = int(u.get('sent', 0) or 0), float(d.get('measure_s', 0))
        # completions inside the window: loadgen sets achieved = completions in [ws, we_eff) / win with win = we_eff - ws
        # <= measure_s (we_eff = min(we, last send)); steps.jsonl has no win, so achieved x measure_s over-counts by
        # at most one inter-arrival gap / measure_s (< 0.1 % at >= 188 updates/s; aborted steps fail separately)
        comp = ach * win
        vals[f'update_achieved_offered.step{d.get("step")}'] = f'{ach:.2f}/{off:.2f}'  # nominal rate: information only
        vals[f'update_completed_sent.step{d.get("step")}'] = f'{comp:.0f}/{sent}'
        bad_step = d.get('aborted') or 'saturated' in str(d.get('reason', ''))
        rec = bad if checked(d) else (lambda t: notes.append(t + ' [not a checked step]'))
        # v0.6.8 (user 2026-10-18 "응 그렇게 진행해"): the updater keeps up when its completions in the window reach
        # lim x the updates SENT in the step (loadgen.cc keep-up rule `achieved * win < (1 - tol) * sent`), not lim x the
        # nominal offered rate (a Poisson count over a 15 s step is itself noisy, sd ~1.9 % at 2,830 updates)
        if off <= 0 or sent < 100:
            rec(f'step {d.get("step")} ({d.get("phase")}): updater not judgeable (offered {off}, updates sent {sent} < 100)')
        elif comp < lim * sent:
            rec(f'step {d.get("step")} ({d.get("phase")}): updater behind (update completions {comp:.0f} < {lim} x sent {sent}; '
                f'achieved {ach} /s, offered {off} /s)')
        if bad_step:
            rec(f'step {d.get("step")} ({d.get("phase")}): aborted/saturated ({d.get("reason", "")})')
    # windows for the round accounting: whole span, or the checked steps' own snapshots (H1 SLO)
    if h1slo:
        wins, other = [], []
        for d in meas:
            n = int(d.get('step', 0))
            bp, ep = os.path.join(st, f'step{n:03d}-begin-t0.txt'), os.path.join(st, f'step{n:03d}-end-t0.txt')
            if not (os.path.isfile(bp) and os.path.isfile(ep)):
                (wins if checked(d) else other).append(None)
                continue
            (wins if checked(d) else other).append((n, kv(bp), kv(ep)))
        if None in wins:
            fails.append('a checked step has no node-0 stats snapshots')
        wins = [w for w in wins if w]
        other = [w for w in other if w]
        vals['checked_steps'] = ','.join(str(w[0]) for w in wins)
        if not wins:
            fails.append('H1 SLO run: no checked (passing, non-overload) step')
    else:
        wins, other = [(0, b0, e0)], []
    dd = lambda b, e, k: e.get(k, 0) - b.get(k, 0)  # noqa: E731
    vals['publish_rounds'] = d0('publish_rounds')
    if vals['publish_rounds'] < 2:
        opfail(f'{vals["publish_rounds"]} publication rounds in the whole span (need >= 2)')
    rr = sum(dd(b, e, 'round_rows') for _, b, e in wins)
    pub = sum(dd(b, e, 'published_seq') for _, b, e in wins)
    pr = sum(dd(b, e, 'publish_rounds') for _, b, e in wins)
    vals['round_rows'] = rr
    vals['flush_overruns'] = sum(dd(b, e, 'flush_overruns') for _, b, e in wins)
    if vals['flush_overruns'] != 0:
        opfail(f'update rate not sustained (flush overruns {vals["flush_overruns"]} in the checked span)')
    if not h1slo:
        vals['update_rate_sustained'] = e0.get('update_rate_sustained', -1)
        if vals['update_rate_sustained'] != 1:
            opfail(f'update_rate_sustained={vals["update_rate_sustained"]}')
    for n, b, e in other:
        o = dd(b, e, 'flush_overruns')
        if o:
            notes.append(f'step {n} (not checked): {o} flush overruns')
    # round accounting guard (LOW 15): every worker finished the same rounds at each snapshot used
    if not ut or ut <= 0:
        fails.append('round guard: --update-threads not found in the manifest server_args')
    else:
        for n, b, e in wins:
            for tag, snap in (('begin', b), ('end', e)):
                fl, prr = snap.get('flushes', -1), snap.get('publish_rounds', -1)
                if fl != ut * prr:
                    opfail(f'round guard: step {n} {tag} snapshot flushes {fl} != {ut} x publish_rounds {prr} (snapshot inside a round edge)')
    tgt = e0.get('rows_per_round_target', 0)
    if tgt <= 0:
        fails.append('no rows_per_round_target in the node-0 end snapshot (Ekko operating point not checkable)')
    else:
        vals['rows_per_round_target'] = tgt
        if pr > 0:
            vals['rows_per_round_window_mean'] = round(rr / pr)
        t_s = e0.get('publish_us', 0) / 1e6
        vals['samples_published'] = pub
        if not rate or rate <= 0 or t_s <= 0:
            fails.append(f'rows per round: cannot normalise (update rate {rate}, T {t_s} s)')
        elif pub <= 0:
            if h1slo:  # short passing windows can contain no round edge; recorded
                notes.append('rows per full round not checkable: no round fired inside the checked steps')
            else:
                opfail(f'rows per round: cannot normalise (samples published {pub})')
        else:
            per_t = rate * t_s
            per = rr / (pub / per_t)
            vals['samples_per_T'] = round(per_t, 1)
            vals['full_round_equiv'] = round(pub / per_t, 3)
            vals['rows_per_full_round'] = round(per)
            vals['rows_per_full_round_vs_target_pct'] = round((per / tgt - 1) * 100, 1)
            if abs(per - tgt) > 0.15 * tgt:
                opfail(f'rows per full round {per:.0f} vs target {tgt} (> 15% off: Ekko operating point not met)')
    cq, cu = op_c_window(b1, e1, 'query'), op_c_window(b0, e0, 'row_update')
    vals['query_C_ms_per_q'] = round(cq / vals['queries'] / 1e6, 4) if vals['queries'] > 0 else ''
    vals['row_update_C_ns_total'] = round(cu)
    vals['query_T_ms_per_q'] = round(d1('op.query.t_ns') / vals['queries'] / 1e6, 4) if vals['queries'] > 0 else ''
    pc1, mg1 = coh_src(e1p)
    pc0, mg0 = coh_src(e0p)
    vals['pc_threads'] = f'{pc0}/{pc1}'
    vals['mg_threads'] = f'{mg0}/{mg1}'
    for k in ('thr.nr-log-sync.run_ns', 'thr.mg-bg.run_ns'):
        vals['bg_cpu_ms.' + k.split('.')[1]] = f'{d0(k) / 1e6:.1f}/{d1(k) / 1e6:.1f}'
    if s == 'hw':
        if cq != 0 or cu != 0:
            fails.append(f'all-HWcc C != 0 (query {cq} ns, row_update {cu} ns)')
    elif s == 'pop':
        if pc0 <= 0 or pc1 <= 0:
            fails.append(f'swmc_acct not live (pc_threads {pc0}/{pc1})')
        if cu <= 0:
            fails.append('Popcorn row_update C = 0')
        if cq <= 0:
            notes.append('Popcorn query C = 0 in this window')
        vals['query_nontrans_ns'] = d1('op.query.pc.nontrans_ns')
    elif s == 'mg':
        if mg0 <= 0 or mg1 <= 0:
            fails.append(f'CohSnap not live (mg_threads {mg0}/{mg1})')
        if cq <= 0 or cu <= 0:
            fails.append(f'Megalon C = 0 (query {cq}, row_update {cu})')
        # C_sampled <= T per op is a sanity relation only (user 2026-10-17: Fig 2 C = C_diff, v1_cdiff.py): WARN
        for op, c, b, e in (('query', cq, b1, e1), ('row_update', cu, b0, e0)):
            t = e.get(f'op.{op}.t_ns', 0) - b.get(f'op.{op}.t_ns', 0)
            if c > t:
                notes.append(f'WARN {op}: C_sampled {c:.0f} ns > T {t} ns')
        an = d1('op.query.mg.anchor.read_lookup_ns_sampled') + d1('op.query.mg.anchor.read_nr_ns_sampled')
        if an <= 0:
            fails.append('AnchorSnap read parts = 0 (shim v3 / Megalon 75 not live)')
        for op, e in (('query', e1), ('row_update', e0)):
            f = e.get(f'op.{op}.mg.flags', -1)
            vals[f'mg_flags.{op}'] = f
            if f < 0 or (f & 3) != 3 or (f & 4):
                fails.append(f'{op}: mg.flags {f} (need timers on + lean sampling, Megalon >= 76; no events_always)')
        vals['row_update_write_sampled'] = d0('op.row_update.mg.anchor.write_sampled')
        if vals['row_update_write_sampled'] <= 0:
            fails.append('no timed Megalon write section on the updater (write-side estimator undefined)')
    else:  # mgoff
        if mg0 <= 0 or mg1 <= 0:
            fails.append(f'CohSnap not registered (mg_threads {mg0}/{mg1})')
        if d1('op.query.mg.read_sections') <= 0:
            fails.append('no Megalon read sections counted')
        for op, e in (('query', e1), ('row_update', e0)):
            f = e.get(f'op.{op}.mg.flags', -1)
            vals[f'mg_flags.{op}'] = f
            if f < 0 or (f & 1):
                fails.append(f'{op}: mg.flags {f} (need present with timers off)')
        durk = ['check_ns_sampled', 'stale_ns', 'concur_ns', 'meta_ns', 'spin_ns', 'wstart_ns', 'switch_rw_ns',
                'reclaim_ns', 'wflush_ns', 'lookup_ns_sampled', 'anchor.read_lookup_ns_sampled',
                'anchor.read_nr_ns_sampled', 'anchor.rseq_ns_sampled', 'anchor.write_lookup_ns', 'anchor.write_nr_ns',
                'anchor.wseq_ns', 'anchor.wseq_end_ns']
        for op, b, e in (('query', b1, e1), ('row_update', b0, e0)):
            miss = [k for k in durk if f'op.{op}.mg.{k}' not in e]
            if miss:
                fails.append(f'{op}: duration keys missing: {" ".join(miss)}')
            nz = {k: e.get(f'op.{op}.mg.{k}', 0) - b.get(f'op.{op}.mg.{k}', 0) for k in durk}
            nz = {k: v for k, v in nz.items() if v != 0}
            if nz:
                fails.append(f'Megalon timers not off ({op}: {nz})')
        if d0('op.row_update.mg.write_sections') <= 0:
            fails.append('no Megalon write sections counted on the updater')
    if msample is not None:  # RECSYS-V1 v1.4: the configured Megalon sample rate reached both nodes' servers
        cs1, cs0 = e1.get('op.query.mg.check_sample', -1), e0.get('op.row_update.mg.check_sample', -1)
        vals['mg_check_sample'] = f'{cs0}/{cs1}'
        if cs1 != msample or cs0 != msample:
            fails.append(f'mg check_sample {cs0}/{cs1} (node0 row_update / node1 query) != --mg-sample {msample}')
    txt = ' '.join(f'{k}={v}' for k, v in vals.items())
    if notes:
        txt += ' NOTES: ' + '; '.join(notes)
    if fails and opr and len(opf) == len(fails):
        print(f'V1CHECK OPFAIL {s} ' + '; '.join(fails) + ' | ' + txt)
        sys.exit(3)
    if fails:
        print(f'V1CHECK FAIL {s} ' + '; '.join(fails) + ' | ' + txt)
        sys.exit(1)
    print(f'V1CHECK PASS {s} ' + txt)


if __name__ == '__main__':
    main()

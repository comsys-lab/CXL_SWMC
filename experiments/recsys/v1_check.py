#!/usr/bin/env python3
"""RECSYS-V1 validation checks of one measurement window (reports/RECSYS-V1-packet.md §3).

usage: v1_check.py <measurement dir> <hw|pop|mg|mgoff>
Reads <dir>/loadgen/stats/step<N>-{begin,end}-t{0,1}.txt of the measured step(s) (t0 = updater node 0, t1 = serving
node 1; window deltas) and <dir>/breakdown.csv. Checks (FAIL = stop the block):
  all   torn_rows delta 0, misses 0, update_misses 0; >= 1 query; >= 2 publication rounds in the window;
        flush_overruns delta 0 and update_rate_sustained=1 (no round longer than T); the updater keeps up: every
        measured loadgen step has update achieved/offered >= 0.95, no saturated/aborted step (steps.jsonl); rows
        published per round within +-15% of rows_per_round_target (when a target is set)
  hw    op.query.c_ns and op.row_update.c_ns deltas = 0 (all-HWcc has no coherence actions)
  pop   op.coh_src pc_threads > 0 on both nodes (swmc_acct live) and row_update C > 0
  mg    op.coh_src mg_threads > 0 on both nodes, query C > 0, row_update C > 0, anchor read parts > 0;
        op.<o>.mg.flags of both ops: timers on (bit 0), lean sampling (bit 1, Megalon >= 76), not events_always
        (bit 2); timed write sections (op.row_update.mg.anchor.write_sampled delta) > 0 (write-side estimator defined)
  mgoff mg_threads > 0, Megalon read sections > 0, op.<o>.mg.flags present with bit 0 (timers) = 0 for both ops,
        every Megalon duration field of both ops = 0 and present
        (CohSnap *_ns incl. wstart/wflush/switch_rw/reclaim/check_ns_sampled, mg.anchor.*; MEGALON_COH_TIMERS=0)
NOTEs (recorded, no stop): Popcorn query C = 0.
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
    if len(sys.argv) != 3 or sys.argv[2] not in ('hw', 'pop', 'mg', 'mgoff'):
        sys.exit(__doc__)
    m, s = sys.argv[1], sys.argv[2]
    st = os.path.join(m, 'loadgen', 'stats')
    stepno = lambda p: int(re.search(r'step(\d+)-', os.path.basename(p)).group(1))  # noqa: E731
    begins = sorted(glob.glob(os.path.join(st, 'step*-begin-t1.txt')), key=stepno)
    if not begins:
        print(f'V1CHECK FAIL {s} no stats snapshots in {st}')
        sys.exit(1)
    fails, notes, vals = [], [], {}
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
    vals['publish_rounds'] = d0('publish_rounds')
    vals['round_rows'] = d0('round_rows')
    vals['flush_overruns'] = d0('flush_overruns')
    vals['update_rate_sustained'] = e0.get('update_rate_sustained', -1)
    if vals['publish_rounds'] < 2:
        fails.append(f'{vals["publish_rounds"]} publication rounds in the window (need >= 2)')
    # updater keeps up (loadgen side): achieved/offered of the update stream, no saturated or aborted step
    try:
        steps = [json.loads(re.sub(r'(?<![A-Za-z"])-?(inf|nan)(?![A-Za-z"])', 'NaN', l))
                 for l in open(os.path.join(m, 'loadgen', 'steps.jsonl')) if l.strip()]
    except (OSError, ValueError) as ex:
        steps = None
        fails.append(f'steps.jsonl unreadable: {ex}')
    if steps is not None:
        meas = [d for d in steps if d.get('measure_s', 0) > 0]
        if not meas:
            fails.append('no measured loadgen step')
        for d in meas:
            u = d.get('streams', {}).get('update', {})
            off, ach = float(u.get('offered', 0)), float(u.get('achieved', 0))
            vals[f'update_achieved_offered.step{d.get("step")}'] = f'{ach:.2f}/{off:.2f}'
            if off <= 0 or not ach >= 0.95 * off:
                fails.append(f'step {d.get("step")}: updater behind (update achieved {ach} < 0.95 x offered {off})')
            if d.get('aborted') or 'saturated' in str(d.get('reason', '')):
                fails.append(f'step {d.get("step")}: aborted/saturated ({d.get("reason", "")})')
    if vals['flush_overruns'] != 0 or vals['update_rate_sustained'] != 1:
        fails.append(f'update rate not sustained (overruns {vals["flush_overruns"]}, '
                     f'update_rate_sustained={vals["update_rate_sustained"]})')
    tgt = e0.get('rows_per_round_target', 0)
    if vals['publish_rounds'] > 0 and tgt > 0:
        per = vals['round_rows'] / vals['publish_rounds']
        vals['rows_per_round'] = round(per)
        vals['rows_per_round_target'] = tgt
        if abs(per - tgt) > 0.15 * tgt:
            fails.append(f'rows per round {per:.0f} vs target {tgt} (> 15% off: Ekko operating point not met)')
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
    txt = ' '.join(f'{k}={v}' for k, v in vals.items())
    if notes:
        txt += ' NOTES: ' + '; '.join(notes)
    if fails:
        print(f'V1CHECK FAIL {s} ' + '; '.join(fails) + ' | ' + txt)
        sys.exit(1)
    print(f'V1CHECK PASS {s} ' + txt)


if __name__ == '__main__':
    main()

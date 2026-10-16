#!/usr/bin/env python3
"""RECSYS-V1 validation checks of one measurement window (reports/RECSYS-V1-packet.md §3).

usage: v1_check.py <measurement dir> <hw|pop|mg|mgoff>
Reads <dir>/loadgen/stats/step<N>-{begin,end}-t{0,1}.txt of the measured step(s) (t0 = updater node 0, t1 = serving
node 1; window deltas) and <dir>/breakdown.csv. Checks (FAIL = stop the block):
  all   torn_rows delta 0, misses 0, update_misses 0; >= 1 query; >= 1 publication round in the window;
        flush_overruns delta 0 and update_rate_sustained=1 (no round longer than T)
  hw    op.query.c_ns and op.row_update.c_ns deltas = 0 (all-HWcc has no coherence actions)
  pop   op.coh_src pc_threads > 0 on both nodes (swmc_acct live) and row_update C > 0
  mg    op.coh_src mg_threads > 0 on both nodes, query C > 0, row_update C > 0, anchor read parts > 0
  mgoff mg_threads > 0, Megalon read sections > 0, Megalon duration fields = 0 (MEGALON_COH_TIMERS=0)
NOTEs (recorded, no stop): rows published per round vs rows_per_round_target outside +-15%; Popcorn query C = 0.
Prints "V1CHECK PASS|FAIL <system> ..." with the values and exits 0 / 1.
"""
import glob
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
    begins = sorted(glob.glob(os.path.join(st, 'step*-begin-t1.txt')))
    if not begins:
        print(f'V1CHECK FAIL {s} no stats snapshots in {st}')
        sys.exit(1)
    fails, notes, vals = [], [], {}
    # the whole measured span: first step's begin .. last step's end
    b1p, e1p = begins[0], sorted(glob.glob(os.path.join(st, 'step*-end-t1.txt')))[-1]
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
    if vals['publish_rounds'] <= 0:
        fails.append('no publication round in the window')
    if vals['flush_overruns'] != 0 or vals['update_rate_sustained'] != 1:
        fails.append(f'update rate not sustained (overruns {vals["flush_overruns"]}, '
                     f'update_rate_sustained={vals["update_rate_sustained"]})')
    tgt = e0.get('rows_per_round_target', 0)
    if vals['publish_rounds'] > 0 and tgt > 0:
        per = vals['round_rows'] / vals['publish_rounds']
        vals['rows_per_round'] = round(per)
        vals['rows_per_round_target'] = tgt
        if abs(per - tgt) > 0.15 * tgt:
            notes.append(f'rows per round {per:.0f} vs target {tgt} (> 15% off)')
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
    else:  # mgoff
        if mg0 <= 0 or mg1 <= 0:
            fails.append(f'CohSnap not registered (mg_threads {mg0}/{mg1})')
        if d1('op.query.mg.read_sections') <= 0:
            fails.append('no Megalon read sections counted')
        dur = sum(d1(f'op.query.mg.{k}') for k in ('check_ns_sampled', 'stale_ns', 'concur_ns', 'spin_ns'))
        if dur != 0:
            fails.append(f'Megalon timers not off (query durations {dur} ns)')
    txt = ' '.join(f'{k}={v}' for k, v in vals.items())
    if notes:
        txt += ' NOTES: ' + '; '.join(notes)
    if fails:
        print(f'V1CHECK FAIL {s} ' + '; '.join(fails) + ' | ' + txt)
        sys.exit(1)
    print(f'V1CHECK PASS {s} ' + txt)


if __name__ == '__main__':
    main()

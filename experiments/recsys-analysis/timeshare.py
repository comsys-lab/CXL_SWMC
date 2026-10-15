#!/usr/bin/env python3
"""Time-share coherence time per request for recsys runs (user methodology update 2026-10-16; reports/RECSYS-design.md §8.4).

  coh_req = (C_serving / B_serving) x S
    C_serving  serving-thread coherence time in the window (breakdown.py serve_coherence_ms_per_query x queries;
               page MSI: fault time of rs-serve threads; Megalon: serve-role section/flush/re-exec estimates; all-HWcc 0)
    B_serving  serving-thread busy time = task wall time, server lookup_ns + mlp_ns
    S          mean server-side query time = window delta of the server's query_ns / queries (arrival -> reply)
Updater/writer coherence is not part of it (breakdown.py upd_* columns stay separate).
Flag: C_serving per query > busy-time increase per query over all-HWcc at the same T (--hwcc <all-HWcc run dir>,
matched by step; if the all-HWcc run has fewer steps, its last step is used) -> flag_coh_exceeds_busy_increase=1.
Kept outside the pinned harness paths (experiments/recsys) on purpose; it only reads run dirs and calls breakdown.py.
usage: timeshare.py <run dir> [--hwcc <all-HWcc run dir>] [--out file.csv]
"""
import csv
import glob
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BREAKDOWN = os.path.join(HERE, '..', 'recsys', 'breakdown.py')


def kv(path):
    d = {}
    for line in open(path):
        m = re.match(r'^([^=\s]+)=(-?\d+)\s*$', line)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def breakdown(run):
    out = subprocess.run([sys.executable, BREAKDOWN, run], check=True, capture_output=True, text=True).stdout
    return {int(r['step']): r for r in csv.DictReader(io.StringIO(out))}


def query_time(run):  # step -> S (ms), from node 1 stats snapshots
    lg = os.path.join(run, 'loadgen') if os.path.isdir(os.path.join(run, 'loadgen')) else os.path.join(run, 'lg')
    s = {}
    for b in glob.glob(os.path.join(lg, 'stats', 'step*-begin-t1.txt')):
        step = int(re.search(r'step(\d+)-begin', b).group(1))
        e = b.replace('-begin-', '-end-')
        if not os.path.exists(e):
            continue
        b1, e1 = kv(b), kv(e)
        q = e1.get('queries', 0) - b1.get('queries', 0)
        if q:
            s[step] = (e1.get('query_ns', 0) - b1.get('query_ns', 0)) / q / 1e6
    return s


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def main():
    run = sys.argv[1]
    hw = sys.argv[sys.argv.index('--hwcc') + 1] if '--hwcc' in sys.argv else None
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
    rows, S = breakdown(run), query_time(run)
    hrows = breakdown(hw) if hw else {}
    res = []
    for step, r in sorted(rows.items()):
        c, b = f(r.get('serve_coherence_ms_per_query')), f(r.get('serve_task_wall_ms_per_query'))
        s = S.get(step)
        o = {'run': r['run'], 'system': r['system'], 'publish_ms': r['publish_ms'], 'step': step, 'queries': r['queries'],
             'C_serving_ms_per_query': c, 'B_serving_ms_per_query': b, 'S_query_ms': round(s, 4) if s else '',
             'coh_share': round(c / b, 6) if c is not None and b else '',
             'coh_req_ms': round(c / b * s, 4) if c is not None and b and s else ''}
        if hrows:
            h = hrows.get(step) or hrows[max(hrows)]
            hb = f(h.get('serve_task_wall_ms_per_query'))
            if hb is not None and b is not None and c is not None:
                o['hwcc_B_serving_ms_per_query'] = hb
                o['busy_increase_ms_per_query'] = round(b - hb, 4)
                o['flag_coh_exceeds_busy_increase'] = int(c > b - hb)
        res.append(o)
    keys = []
    for o in res:
        keys += [k for k in o if k not in keys]
    fh = open(out, 'w', newline='') if out else sys.stdout
    w = csv.DictWriter(fh, fieldnames=keys)
    w.writeheader()
    w.writerows(res)


if __name__ == '__main__':
    main()

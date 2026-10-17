#!/usr/bin/env python3
"""RECSYS-V1 difference-method Megalon C (user decision 2026-10-17, state/TASKS.md "(a) difference method").

usage: v1_cdiff.py <block evidence dir>   (needs <E>/hw/val and <E>/mgoff/val; <E>/mg/val and <E>/pop/val optional)
Per operation o (query on node 1 = t1, row_update on node 0 = t0), from the val windows (first begin .. last end
stats snapshot, the same window as v1_check.py):
  T_o(s)  = d(op.<o>.t_ns) / d(op.<o>.n)   per system s, ns per operation
  C_diff  = T_o(mgoff) - T_o(hw)           Megalon C for Fig 2 (upper bound: any other backend difference is in it);
            C_diff < 0 is reported as is with a WARN (no clamp)
  split   part_i = C_diff x sampled_i / sum(sampled) with the sampled parts of the timers-on Megalon window (mg):
            check (mg.check_est window), events + write (mg_scaled_window parts); raw sampled values kept
  checks  C_sampled(mg) per op vs T_o(mg): WARN if C_sampled > T (no FAIL); Popcorn cross-check T(pop) - T(hw) next to
            the swmc_acct C (recorded)
The comparison needs the same offered rates in every window: the configured query and update rates (loadgen
steps.jsonl 'offered' of the measured steps) must agree within 1% across hw, mgoff (and mg, pop if present), else
CDIFF FAIL (exit 1). Writes <E>/cdiff.csv; prints "CDIFF DONE ..." (exit 0, WARNs inline) or "CDIFF FAIL ...".
"""
import csv
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from breakdown import delta, kv, mg_check_window, op_c_window  # noqa: E402

STEPNO = re.compile(r'step(\d+)-')


def window(m):
    st = os.path.join(m, 'loadgen', 'stats')
    key = lambda p: int(STEPNO.search(os.path.basename(p)).group(1))  # noqa: E731
    b1 = sorted(glob.glob(os.path.join(st, 'step*-begin-t1.txt')), key=key)
    e1 = sorted(glob.glob(os.path.join(st, 'step*-end-t1.txt')), key=key)
    if not b1 or not e1:
        return None
    b1p, e1p = b1[0], e1[-1]
    return {'t1': (kv(b1p), kv(e1p)),
            't0': (kv(b1p.replace('-t1.txt', '-t0.txt')), kv(e1p.replace('-t1.txt', '-t0.txt')))}


def offered(m):
    rates = {}
    for line in open(os.path.join(m, 'loadgen', 'steps.jsonl')):
        if not line.strip():
            continue
        d = json.loads(re.sub(r'(?<![A-Za-z"])-?(inf|nan)(?![A-Za-z"])', 'NaN', line))
        if d.get('measure_s', 0) > 0:
            for s, v in d.get('streams', {}).items():
                rates.setdefault(s, []).append(float(v.get('offered', 0)))
    return {s: sum(v) / len(v) for s, v in rates.items() if v}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    E = sys.argv[1]
    present = [s for s in ('hw', 'pop', 'mg', 'mgoff') if os.path.isdir(os.path.join(E, s, 'val'))]
    if 'hw' not in present or 'mgoff' not in present:
        print(f'CDIFF FAIL need hw/val and mgoff/val (present: {present})')
        sys.exit(1)
    W, R = {}, {}
    for s in present:
        m = os.path.join(E, s, 'val')
        W[s] = window(m)
        if W[s] is None:
            print(f'CDIFF FAIL {s}: no stats snapshots')
            sys.exit(1)
        try:
            R[s] = offered(m)
        except (OSError, ValueError) as ex:
            print(f'CDIFF FAIL {s}: steps.jsonl unreadable: {ex}')
            sys.exit(1)
    fails, warns, out = [], [], []
    for stream in ('query', 'update'):
        ref = R['hw'].get(stream, 0)
        for s in present:
            x = R[s].get(stream, 0)
            if ref <= 0 or abs(x - ref) > 0.01 * ref:
                fails.append(f'offered {stream} rate {s} {x} vs hw {ref}')
    rows = []
    for o, node in (('query', 't1'), ('row_update', 't0')):
        T = {}
        for s in present:
            b, e = W[s][node]
            n = delta(b, e, f'op.{o}.n')
            T[s] = delta(b, e, f'op.{o}.t_ns') / n if n > 0 else None
        if T['hw'] is None or T['mgoff'] is None:
            fails.append(f'{o}: no operations in hw or mgoff window')
            continue
        cd = T['mgoff'] - T['hw']
        r = {'op': o, 'T_hw_ns': round(T['hw'], 1), 'T_mgoff_ns': round(T['mgoff'], 1), 'C_diff_ns': round(cd, 1)}
        if cd < 0:
            warns.append(f'{o}: C_diff {cd:.1f} ns < 0 (reported as is)')
        if 'mg' in present and T['mg'] is not None:
            b, e = W['mg'][node]
            n = delta(b, e, f'op.{o}.n')
            ck = mg_check_window(b, e, o)
            p = f'op.{o}.mg.'
            f = e.get(p + 'flags', 0)
            lean = (f & 2) and not (f & 4)
            ds, dw = delta(b, e, p + 'check_sampled'), delta(b, e, p + 'anchor.write_sampled')
            ev = sum(delta(b, e, p + k) for k in ('stale_ns', 'concur_ns', 'meta_ns', 'spin_ns'))
            wr = sum(delta(b, e, p + k) for k in ('wstart_ns', 'wflush_ns', 'anchor.write_lookup_ns', 'anchor.write_nr_ns'))
            if lean:  # same rule as breakdown.mg_scaled_window, kept per part for the split
                ev = ev * delta(b, e, p + 'read_sections') / ds if ds else 0.0
                wr = wr * delta(b, e, p + 'write_sections') / dw if dw else 0.0
            parts = {'check': ck / n, 'events': ev / n, 'write': wr / n}
            cs = op_c_window(b, e, o) / n
            tot = sum(parts.values())
            r.update({'T_mg_timers_on_ns': round(T['mg'], 1), 'C_sampled_ns': round(cs, 1),
                      'timer_overhead_ns(T_mg-T_mgoff)': round(T['mg'] - T['mgoff'], 1)})
            for k, v in parts.items():
                r[f'sampled_{k}_ns'] = round(v, 1)
                r[f'C_diff_part_{k}_ns'] = round(cd * v / tot, 1) if tot > 0 else ''
            if cs > T['mg']:
                warns.append(f'{o}: C_sampled {cs:.1f} ns > T(mg) {T["mg"]:.1f} ns')
            if cs > cd:
                warns.append(f'{o}: C_sampled {cs:.1f} ns > C_diff {cd:.1f} ns (sampled estimate above the difference bound)')
        if 'pop' in present and T['pop'] is not None:
            b, e = W['pop'][node]
            n = delta(b, e, f'op.{o}.n')
            r['T_pop_ns'] = round(T['pop'], 1)
            r['pop_T_diff_ns(T_pop-T_hw)'] = round(T['pop'] - T['hw'], 1)
            r['pop_C_swmc_acct_ns'] = round(op_c_window(b, e, o) / n, 1) if n > 0 else ''
        rows.append(r)
        out.append(' '.join(f'{k}={v}' for k, v in r.items()))
    if rows:
        keys = []
        for r in rows:
            keys += [k for k in r if k not in keys]
        with open(os.path.join(E, 'cdiff.csv'), 'w', newline='') as fh:
            w = csv.DictWriter(fh, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)
    rates = ' '.join(f'{s}:q={R[s].get("query", 0):.3f},u={R[s].get("update", 0):.2f}' for s in present)
    if fails:
        print('CDIFF FAIL ' + '; '.join(fails) + ' | ' + ' | '.join(out) + ' | rates ' + rates)
        sys.exit(1)
    print('CDIFF DONE ' + ' | '.join(out) + ' | rates ' + rates + (' | WARN ' + '; '.join(warns) if warns else ''))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Small checks of the recsys main block (reports/RECSYS-main-packet.md), kept here so Host tests run the same code.

  main_util.py gate60 <steps.jsonl> <limit ms>   the 1 query/s window: exactly one measured "fixed" step; PASS when
                                                 the step passed (keeps up, no errors) AND query p99 <= limit (explicit,
                                                 not only loadgen's pass flag) AND it completed >= 1 query.
                                                 Prints "PASS|MISS p99_ms=... ..." (exit 0 either way).
  main_util.py gate <steps.jsonl> [slo ms [pct]] the lowest-load window (pct default 95 = DLRM p95 SLO, MOT1 v6;
                                                 99 = the v5 p99 rule): exactly one measured "fixed" step; VALID when
                                                 the step passed (keeps up, no errors/timeouts; no SLO is set) and >= 1
                                                 query completed, no non-finite latency. Prints "VALID|INVALID" with the
                                                 query count, p50/p90/p95/p99/max (the tail of ~60 queries is the max), and whether
                                                 the updater wrote a publication round inside the window (node-0
                                                 rows_written delta from the loadgen stats snapshots) [+ within_slo].
  main_util.py slo <steps.jsonl> <factor> [pct] SLO ms = factor x the query p<pct> (default 95) of that window
                                                 (Host tests only; the v6 main block uses the fixed 100 ms) (rounded to 0.001 ms);
                                                 exit 1 unless the window is VALID.
  main_util.py half <summary.json>               0.5 x the SLO search's confirm mean (L); exit 1 if the search has a
                                                 note or no confirm result (a noted search is never used for L).
"""
import json
import math
import os
import re
import sys


def gate60(steps, limit):
    st = [json.loads(l) for l in open(steps) if l.strip()]
    st = [d for d in st if d.get('phase') == 'fixed']
    if len(st) != 1:
        print(f'MISS measured_steps={len(st)} (need exactly 1)')
        return
    d = st[0]
    q, u = d['streams']['query'], d['streams']['update']
    p = q['p99_ms']
    ok = bool(d['pass']) and q['done'] > 0 and p <= limit
    print(('PASS' if ok else 'MISS') + f' p99_ms={p} limit_ms={limit} pass={d["pass"]} reason={d.get("reason", "")!r} '
          f'query_sent={q["sent"]} query_done={q["done"]} query_max_ms={q["max_ms"]} achieved_q_s={q["achieved"]} '
          f'update_offered={u["offered"]} update_achieved={u["achieved"]}')


def _num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


def _kv(path):
    d = {}
    for line in open(path):
        m = re.match(r'^([^=\s#]+)=(-?\d+)\s*$', line)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def gate_window(steps, pct=95):
    """(valid, p99 or None, text). Never raises on bad input: unparsable lines, inf/NaN latencies (timeouts) and
    missing keys give INVALID with the reason."""
    try:
        st = []
        for l in open(steps):
            if l.strip():  # loadgen may print inf/nan for unanswered requests; read them as non-finite
                st.append(json.loads(re.sub(r'(?<![A-Za-z"])-?(inf|nan)(?![A-Za-z"])', 'NaN', l)))
    except (OSError, ValueError) as e:
        return False, None, f'unreadable steps file: {e}'
    st = [d for d in st if d.get('phase') == 'fixed']
    if len(st) != 1:
        return False, None, f'measured_steps={len(st)} (need exactly 1)'
    d = st[0]
    try:
        q, u = d['streams']['query'], d['streams']['update']
        lat = {k: _num(q.get(k)) for k in ('p50_ms', 'p90_ms', 'p99_ms', 'max_ms')}
        p95 = _num(q.get('p95_ms'))
        txt = (f'queries_done={q["done"]} query_sent={q["sent"]} p50_ms={q.get("p50_ms")} p90_ms={q.get("p90_ms")} '
               f'p95_ms={q.get("p95_ms")} '
               f'p99_ms={q.get("p99_ms")} max_ms={q.get("max_ms")} p99_is_max={lat["p99_ms"] == lat["max_ms"]} '
               f'pass={d["pass"]} reason={d.get("reason", "")!r} errors={q["errors"]} timeouts={q["timeouts"]} '
               f'achieved_q_s={q["achieved"]} update_offered={u["offered"]} update_achieved={u["achieved"]}')
        why = []
        if not d['pass']:
            why.append('step failed')
        if q['done'] <= 0:
            why.append('zero queries')
        if q['errors'] or q['timeouts']:
            why.append('errors/timeouts')
        if any(v is None for v in lat.values()):
            why.append('non-finite or missing latency')
        if pct != 99 and p95 is None:
            why.append('missing p95_ms (loadgen without the p95 column)')
    except (KeyError, TypeError) as e:
        return False, None, f'missing key in steps file: {e}'
    # publication round overlap: node-0 (updater) counter deltas over the measured window (loadgen stats snapshots)
    sd = os.path.join(os.path.dirname(steps), 'stats')
    b, e = (os.path.join(sd, f'step{int(d["step"]):03d}-{w}-t0.txt') for w in ('begin', 'end'))
    if os.path.isfile(b) and os.path.isfile(e):
        kb, ke = _kv(b), _kv(e)
        if all(k in kb and k in ke for k in ('rows_written', 'flushes')):
            rw, fl = ke['rows_written'] - kb['rows_written'], ke['flushes'] - kb['flushes']
            txt += f' window_rows_written={rw} window_flush_ticks={fl} publication_round_in_window={rw > 0}'
        else:
            txt += ' publication_round_in_window=unknown (rows_written/flushes missing in node-0 snapshots)'
    else:
        txt += ' publication_round_in_window=unknown (no node-0 snapshots)'
    if why:
        return False, None, txt + ' invalid=' + ','.join(why)
    return True, (lat['p99_ms'] if pct == 99 else p95), txt


def gate(steps, limit=None, pct=95):
    ok, p, txt = gate_window(steps, pct)
    extra = '' if limit is None or p is None else f' slo_ms={limit} slo_pct={pct:g} within_slo={p <= limit}'
    print(('VALID ' if ok else 'INVALID ') + txt + extra)


def slo(steps, factor, pct=95):
    ok, p, txt = gate_window(steps, pct)
    if not ok or not p or p <= 0:
        sys.exit('INVALID lowest-load window: ' + txt)
    print(round(factor * p, 3))


def half(summary):
    s = json.load(open(summary))
    if s.get('note'):
        sys.exit('note: ' + s['note'])
    x = s.get('confirm', {}).get('x_mean', 0)
    if not x > 0:
        sys.exit('no confirm result')
    print(round(0.5 * x, 3))


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'gate60':
        gate60(sys.argv[2], float(sys.argv[3]))
    elif sys.argv[1:2] == ['gate'] and len(sys.argv) in (3, 4, 5):
        gate(sys.argv[2], float(sys.argv[3]) if len(sys.argv) >= 4 else None,
             float(sys.argv[4]) if len(sys.argv) == 5 else 95)
    elif len(sys.argv) in (4, 5) and sys.argv[1] == 'slo':
        slo(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]) if len(sys.argv) == 5 else 95)
    elif len(sys.argv) == 3 and sys.argv[1] == 'half':
        half(sys.argv[2])
    else:
        sys.exit(__doc__)

#!/usr/bin/env python3
"""Small checks of the recsys main block (reports/RECSYS-main-packet.md), kept here so Host tests run the same code.

  main_util.py gate60 <steps.jsonl> <limit ms>   the 1 query/s window: exactly one measured "fixed" step; PASS when
                                                 the step passed (keeps up, no errors) AND query p99 <= limit (explicit,
                                                 not only loadgen's pass flag) AND it completed >= 1 query.
                                                 Prints "PASS|MISS p99_ms=... ..." (exit 0 either way).
  main_util.py half <summary.json>               0.5 x the SLO search's confirm mean (L); exit 1 if the search has a
                                                 note or no confirm result (a noted search is never used for L).
"""
import json
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
    elif len(sys.argv) == 3 and sys.argv[1] == 'half':
        half(sys.argv[2])
    else:
        sys.exit(__doc__)

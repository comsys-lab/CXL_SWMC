#!/usr/bin/env python3
"""Acceptance check of a fixed-load window's serving-time breakdown (reports/RECSYS-main-packet.md §4).

usage: check_breakdown.py <measurement dir>   (manifest.txt, breakdown.csv, loadgen/stats/)
PASS when breakdown.csv has at least one data row with queries > 0 and non-empty values in the common columns and in
the coherence columns of the manifest's system, and the raw counters those columns are computed from are present in
the serving node's end snapshot (breakdown.py reads a missing key as 0, so a missing counter would look like zero
coherence). all-HWcc: serving coherence must be exactly 0 (by definition). Prints "BREAKDOWN PASS ..." or
"BREAKDOWN FAIL <reason>" (exit 1).
"""
import csv
import glob
import os
import re
import sys

COMMON = ['serve_task_wall_ms_per_query', 'serve_coherence_ms_per_query', 'serve_app_ms_per_query',
          'upd_samples', 'upd_rows_written']
COLS = {
    'hwcc': [],
    'msi': ['serve_fetch_wait_ms_per_query', 'serve_read_local_wait_ms_per_query', 'serve_read_other_ms_per_query',
            'serve_write_fault_ms_per_query', 'node1_invalidate_handling_ms_per_query', 'h3_coherence_ms_per_query',
            'node1_tlb_irqs_per_query'],
    'megalon': ['serve_section_checks_ms_per_query', 'serve_flushes_ms_per_query', 'serve_reexec_ms_per_query',
                'serve_read_sections', 'upd_write_sections'],
}
RAW = {  # keys that must exist in the serving node's (t1) end snapshot
    'hwcc': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n'],
    'msi': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n', 'thr.rs-serve.swmc.read_fault_ns',
            'thr.rs-serve.swmc.read_msg_wait_ns', 'thr.rs-serve.swmc.read_local_wait_ns',
            'thr.rs-serve.swmc.write_fault_ns', 'sys.swmc.instr.serve.unmap_ns', 'sys.swmc.instr.serve.mkclean_ns'],
    'megalon': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n', 'megalon_time.serve.read_sections',
                'megalon_time.serve.read_sampled', 'megalon_time.serve.read_start_ns_sampled'],
}


def fail(msg):
    print(f'BREAKDOWN FAIL {msg}')
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    m = sys.argv[1]
    man = dict(l.rstrip('\n').split('=', 1) for l in open(os.path.join(m, 'manifest.txt')) if '=' in l and not l.startswith('#'))
    system = man.get('system', '')
    kind = 'hwcc' if system == 'all-HWcc' else 'msi' if system.startswith('Popcorn') else 'megalon' if system == 'Megalon' else None
    if kind is None:
        fail(f'unknown system {system!r}')
    p = os.path.join(m, 'breakdown.csv')
    if not os.path.isfile(p) or os.path.getsize(p) == 0:
        fail('breakdown.csv missing or empty')
    rows = list(csv.DictReader(open(p)))
    rows = [r for r in rows if r.get('queries', '') not in ('', '0')]
    if not rows:
        fail('no breakdown row with queries > 0')
    for r in rows:
        for c in COMMON + COLS[kind]:
            if r.get(c, '') == '':
                fail(f'step {r.get("step")}: column {c} missing or empty')
        if kind == 'hwcc' and float(r['serve_coherence_ms_per_query']) != 0.0:
            fail(f'step {r.get("step")}: all-HWcc coherence {r["serve_coherence_ms_per_query"]} != 0')
        end = glob.glob(os.path.join(m, 'loadgen', 'stats', f'step{int(r["step"]):03d}-end-t1.txt'))
        if not end:
            fail(f'step {r.get("step")}: no end snapshot of the serving node')
        keys = {mm.group(1) for mm in (re.match(r'^([^=\s]+)=', l) for l in open(end[0])) if mm}
        missing = [k for k in RAW[kind] if k not in keys]
        if missing:
            fail(f'step {r.get("step")}: raw counters missing in {os.path.basename(end[0])}: {" ".join(missing)}')
    r = rows[-1]
    print(f'BREAKDOWN PASS system={system} rows={len(rows)} step={r["step"]} queries={r["queries"]} '
          f'task_wall_ms/q={r["serve_task_wall_ms_per_query"]} coherence_ms/q={r["serve_coherence_ms_per_query"]}')


if __name__ == '__main__':
    main()

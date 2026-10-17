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
    # build >= 12: always-on keys only (read_fault_ns / write_fault_ns / local waits are instr/detail only)
    'msi': ['serve_read_msg_wait_ms_per_query', 'serve_is_fault_ms_per_query', 'serve_sm_fault_ms_per_query',
            'serve_wpu_fault_ms_per_query', 'node1_invalidate_handling_ms_per_query', 'h3_coherence_ms_per_query',
            'node1_tlb_irqs_per_query'],
    # v6: CohSnap-based Fig 2 columns (legacy app-timer columns only when --megalon-time-sample > 0)
    'megalon': ['fig2_query_T_ms[measured]', 'fig2_query_C_ms[derived]', 'fig2_query_C_check_ms[sampledxN]',
                'bg_cpu_ms_node1[measured]', 'serve_read_sections', 'upd_write_sections'],
}
MEGALON_LEGACY = ['serve_section_checks_ms_per_query', 'serve_flushes_ms_per_query', 'serve_reexec_ms_per_query']
RAW = {  # keys that must exist in the serving node's (t1) end snapshot
    'hwcc': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n'],
    'msi': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n', 'op.query.n', 'op.query.c_ns', 'op.query.pc.fault_ns.is',
            'thr.rs-serve.swmc.read_msg_wait_ns', 'thr.rs-serve.swmc.is_fault_ns', 'thr.rs-serve.swmc.sm_fault_ns',
            'thr.rs-serve.swmc.wpu_fault_ns', 'sys.swmc.instr.serve.unmap_ns', 'sys.swmc.instr.serve.mkclean_ns'],
    'megalon': ['lookup_ns', 'mlp_ns', 'queries', 'thr.rs-serve.n', 'megalon_time.serve.read_sections', 'op.query.n',
                'op.query.t_ns', 'op.query.c_ns', 'op.query.mg.read_sections', 'op.query.mg.check_sampled',
                'op.query.mg.flags', 'op.query.mg.anchor.write_sampled',  # Megalon >= 76 estimators (optime.h)
                'thr.nr-log-sync.run_ns'],
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
        legacy = kind == 'megalon' and r.get('megalon_legacy_timers', '0') not in ('', '0')
        for c in COMMON + COLS[kind] + (MEGALON_LEGACY if legacy else []):
            if r.get(c, '') == '':
                fail(f'step {r.get("step")}: column {c} missing or empty')
        if kind == 'hwcc' and float(r['serve_coherence_ms_per_query']) != 0.0:
            fail(f'step {r.get("step")}: all-HWcc coherence {r["serve_coherence_ms_per_query"]} != 0')
        end = glob.glob(os.path.join(m, 'loadgen', 'stats', f'step{int(r["step"]):03d}-end-t1.txt'))
        if not end:
            fail(f'step {r.get("step")}: no end snapshot of the serving node')
        keys = {mm.group(1) for mm in (re.match(r'^([^=\s]+)=', l) for l in open(end[0])) if mm}
        missing = [k for k in RAW[kind] if k not in keys]
        if kind == 'msi':  # v6 Fig 2: Popcorn C must come from swmc_acct (build >= 10); refuse C = 0 data
            src = [l for l in open(end[0]) if l.startswith('op.coh_src=')]
            if not src or 'pc_threads:0' in src[-1]:
                fail(f'step {r.get("step")}: Popcorn swmc_acct not live ({src[-1].strip() if src else "no op.coh_src"}); '
                     'Fig 2 C not available (needs Popcorn build >= 10)')
            if r.get('fig2_query_C_ms[measured]', '') == '':
                fail(f'step {r.get("step")}: column fig2_query_C_ms[measured] missing or empty')
        if kind == 'megalon' and 'op.coh_src' in keys:
            src = [l for l in open(end[0]) if l.startswith('op.coh_src=')][-1]
            if 'mg_threads:0' in src:
                fail(f'step {r.get("step")}: CohSnap not live ({src.strip()}; v1 shim?)')
        if missing:
            fail(f'step {r.get("step")}: raw counters missing in {os.path.basename(end[0])}: {" ".join(missing)}')
    r = rows[-1]
    print(f'BREAKDOWN PASS system={system} rows={len(rows)} step={r["step"]} queries={r["queries"]} '
          f'task_wall_ms/q={r["serve_task_wall_ms_per_query"]} coherence_ms/q={r["serve_coherence_ms_per_query"]}')


if __name__ == '__main__':
    main()

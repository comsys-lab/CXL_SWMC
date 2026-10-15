#!/usr/bin/env python3
"""Per-step coherence-time breakdown of a recsys run (reports/RECSYS-design.md §8.4; MOT1 v5 Figures 1b / 3b).

Reads <run>/manifest.txt (system=, publish_ms=) and the loadgen stats snapshots <run>/loadgen/stats/ (Host tests: <run>/lg/stats/)
step<NNN>-{begin,end}-t<k>.txt (t0 = node 0 = updater, t1 = node 1 = serving; recsys stats op = server counters +
cxl::proc::text). Every value is a window delta (end - begin).

The formula is selected by the run's system label, never by which keys exist (build 8 exposes /proc/<tid>/swmc, all
zeros, even without cxl_shm, so key presence says nothing about the system):
  all-HWcc   coherence = 0 by definition
  Popcorn-*  serving threads (rs-serve): FETCH wait = read_msg_wait_ns; read local wait = read_local_wait_ns;
             read other = read_fault_ns - read_msg_wait_ns - read_local_wait_ns; write faults = write_fault_ns;
             node-wide on the serving node (receive context, not serving threads): INVALIDATE handling =
             sys.swmc.instr.serve.unmap_ns + mkclean_ns, TLB IPIs = irq.TLB, receive thread CPU = kthr.cxl_recv*.cpu_ticks
  Megalon    serving role: section checks, flushes, re-executed work from the sampled counters (backend.h MegThr)
Serving application time = serving task wall time (server lookup_ns + mlp_ns, sum over a query's tasks) - serving
coherence time (both are wall times; waits may sleep, so CPU run_ns is reported but never used for the split).
H3 denominator (page MSI) = serving coherence + node-1 INVALIDATE handling, per query; TLB IPIs as counts per query.
Megalon estimates are computed from the window deltas of the raw sampled counters. The updater (node 0, rs-update
threads / Megalon role update) is reported in separate columns, never added to the serving time.
usage: breakdown.py <run dir> [--out file.csv]
"""
import csv
import glob
import os
import re
import sys


def kv(path):
    d = {}
    for line in open(path):
        m = re.match(r'^([^=\s]+)=(-?\d+)\s*$', line)
        if m:
            d[m.group(1)] = int(m.group(2))
    return d


def delta(b, e, key):
    return e.get(key, 0) - b.get(key, 0)


def sum_prefix(b, e, prefix, suffix):
    keys = {k for k in list(b) + list(e) if k.startswith(prefix) and k.endswith(suffix)}
    return sum(delta(b, e, k) for k in keys)


def main():
    run = sys.argv[1]
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
    man = dict(l.rstrip('\n').split('=', 1) for l in open(os.path.join(run, 'manifest.txt')) if '=' in l and not l.startswith('#'))
    system = man.get('system', '')
    if system == 'all-HWcc':
        kind = 'hwcc'
    elif system.startswith('Popcorn'):
        kind = 'msi'
    elif system == 'Megalon':
        kind = 'megalon'
    else:
        sys.exit(f'unknown system label {system!r}')
    rows = []
    lgdir = os.path.join(run, 'loadgen') if os.path.isdir(os.path.join(run, 'loadgen')) else os.path.join(run, 'lg')
    for bpath in sorted(glob.glob(os.path.join(lgdir, 'stats', 'step*-begin-t1.txt'))):
        step = re.search(r'step(\d+)-begin', bpath).group(1)
        epath = bpath.replace('-begin-', '-end-')
        b0p, e0p = bpath.replace('-t1.txt', '-t0.txt'), epath.replace('-t1.txt', '-t0.txt')
        if not (os.path.exists(epath) and os.path.exists(b0p) and os.path.exists(e0p)):
            continue
        b1, e1, b0, e0 = kv(bpath), kv(epath), kv(b0p), kv(e0p)
        q = delta(b1, e1, 'queries')
        win_s = delta(b1, e1, 't_mono_ns') / 1e9
        r = {'run': os.path.basename(run.rstrip('/')), 'system': system, 'publish_ms': man.get('publish_ms', ''),
             'step': int(step), 'window_s': round(win_s, 3), 'queries': q,
             'serve_threads': e1.get('thr.rs-serve.n', 0)}
        # serving task wall time (server lookup_ns + mlp_ns: sum over a query's parallel tasks, wall clock) is the
        # basis: fault and section times are wall times too (a wait may sleep), so app = task wall - coherence.
        # CPU time (schedstat run_ns) is reported separately and never used for the split.
        task_wall = delta(b1, e1, 'lookup_ns') + delta(b1, e1, 'mlp_ns')
        r['serve_cpu_ms_per_query'] = round(delta(b1, e1, 'thr.rs-serve.run_ns') / q / 1e6, 4) if q else ''
        coh, node_inval = {}, 0
        if kind == 'msi':
            p = 'thr.rs-serve.swmc.'
            rf, rw, rl = (delta(b1, e1, p + k) for k in ('read_fault_ns', 'read_msg_wait_ns', 'read_local_wait_ns'))
            coh = {'fetch_wait': rw, 'read_local_wait': rl, 'read_other': rf - rw - rl,
                   'write_fault': delta(b1, e1, p + 'write_fault_ns')}
            r['serve_read_faults'] = delta(b1, e1, p + 'read_faults')
            r['serve_read_transactions'] = delta(b1, e1, p + 'read_transactions')
            node_inval = delta(b1, e1, 'sys.swmc.instr.serve.unmap_ns') + delta(b1, e1, 'sys.swmc.instr.serve.mkclean_ns')
            r['node1_tlb_irqs_per_query'] = round(delta(b1, e1, 'irq.TLB') / q, 2) if q else ''
            r['node1_recv_cpu_ticks'] = sum_prefix(b1, e1, 'kthr.cxl_recv', '.cpu_ticks')
            u = 'thr.rs-update.swmc.'
            r['upd_write_fault_ms'] = round(delta(b0, e0, u + 'write_fault_ns') / 1e6, 3)
            r['upd_write_msg_wait_ms'] = round(delta(b0, e0, u + 'write_msg_wait_ns') / 1e6, 3)
            r['upd_read_fault_ms'] = round(delta(b0, e0, u + 'read_fault_ns') / 1e6, 3)
            r['node0_recv_cpu_ticks'] = sum_prefix(b0, e0, 'kthr.cxl_recv', '.cpu_ticks')
        elif kind == 'megalon':
            def est(b, e, role):  # estimates from window deltas of the raw counters (backend.h MegThr)
                p = f'megalon_time.{role}.'
                d = {k: delta(b, e, p + k) for k in ('read_sections', 'read_sampled', 'write_sections', 'write_sampled',
                                                      'read_start_ns_sampled', 'read_end_ns_sampled',
                                                      'write_start_ns_sampled', 'write_end_ns_sampled', 'reexec_ns_sampled',
                                                      'read_fail')}
                fr = d['read_sections'] / d['read_sampled'] if d['read_sampled'] else 0
                fw = d['write_sections'] / d['write_sampled'] if d['write_sampled'] else 0
                return d, {'section_checks': fr * (d['read_start_ns_sampled'] + d['read_end_ns_sampled']) +
                           fw * d['write_start_ns_sampled'],
                           'flushes': fw * d['write_end_ns_sampled'], 'reexec': fr * d['reexec_ns_sampled']}
            d, coh = est(b1, e1, 'serve')
            r['serve_read_sections'] = d['read_sections']
            r['serve_read_sampled'] = d['read_sampled']
            r['serve_read_fail'] = d['read_fail']
            du, cu = est(b0, e0, 'update')
            r['upd_check_ms'] = round(cu['section_checks'] / 1e6, 3)
            r['upd_flush_ms'] = round(cu['flushes'] / 1e6, 3)
            r['upd_write_sections'] = du['write_sections']
            r['megalon_switch_rw_node0'] = delta(b0, e0, 'megalon.switch_rw')
        total_coh = sum(coh.values())
        per_q = (lambda ns: round(ns / q / 1e6, 4)) if q else (lambda ns: '')
        r['serve_task_wall_ms_per_query'] = per_q(task_wall)
        r['serve_coherence_ms_per_query'] = per_q(total_coh)
        r['serve_app_ms_per_query'] = per_q(task_wall - total_coh)
        for k, v in coh.items():
            r[f'serve_{k}_ms_per_query'] = per_q(v)
        # H3 denominator (page MSI): serving-thread coherence + node-1 INVALIDATE handling (receive context)
        r['node1_invalidate_handling_ms_per_query'] = per_q(node_inval) if kind == 'msi' else ''
        r['h3_coherence_ms_per_query'] = per_q(total_coh + node_inval) if kind == 'msi' else ''
        r['upd_samples'] = delta(b0, e0, 'samples')
        r['upd_rows_written'] = delta(b0, e0, 'rows_written')
        r['upd_rows_per_s'] = round(r['upd_rows_written'] / win_s, 1) if win_s else ''
        r['upd_busy_ms'] = round(delta(b0, e0, 'thr.rs-update.run_ns') / 1e6, 3)
        r['upd_flush_overruns'] = delta(b0, e0, 'flush_overruns')
        rows.append(r)
    if not rows:
        sys.exit('no complete stats snapshot pairs')
    keys = []
    for r in rows:
        keys += [k for k in r if k not in keys]
    f = open(out, 'w', newline='') if out else sys.stdout
    w = csv.DictWriter(f, fieldnames=keys)
    w.writeheader()
    w.writerows(rows)


if __name__ == '__main__':
    main()

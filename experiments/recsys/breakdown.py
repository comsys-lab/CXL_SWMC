#!/usr/bin/env python3
"""Per-step coherence-time breakdown of a recsys run (reports/RECSYS-design.md §8.4; MOT1 v5 Figures 1b / 3b).

Reads <run>/manifest.txt (system=, publish_ms=) and the loadgen stats snapshots <run>/loadgen/stats/ (Host tests: <run>/lg/stats/)
step<NNN>-{begin,end}-t<k>.txt (t0 = node 0 = updater, t1 = node 1 = serving; recsys stats op = server counters +
cxl::proc::text). Every value is a window delta (end - begin).

The formula is selected by the run's system label, never by which keys exist (build 8 exposes /proc/<tid>/swmc, all
zeros, even without cxl_shm, so key presence says nothing about the system):
  all-HWcc   coherence = 0 by definition
  Popcorn-*  serving coherence = swmc_acct per-op C of the query op (op.query.c_ns window delta: transition faults
             + coherence IPIs, always on). Diagnostics from always-on per-thread keys (build 12: read_fault_ns /
             write_fault_ns / local waits are instr/detail only and read 0, so they are not used): FETCH wait =
             read_msg_wait_ns, transition-fault time is_/sm_/wpu_fault_ns, nontrans_fault_ns;
             node-wide on the serving node (receive context, not serving threads): INVALIDATE handling =
             sys.swmc.instr.serve.unmap_ns + mkclean_ns, TLB IPIs = irq.TLB, receive thread CPU = kthr.cxl_recv*.cpu_ticks
  Megalon    v6 default (legacy app timers off, megalon_time.sample=0): serving coherence = CohSnap op.query.c_ns
             (optime.h); with --megalon-time-sample N > 0 the legacy split (backend.h MegThr: section checks,
             flushes, re-executed work) is added as before
Serving application time = serving task wall time (server lookup_ns + mlp_ns, sum over a query's tasks) - serving
coherence time (both are wall times; waits may sleep, so CPU run_ns is reported but never used for the split).
H3 denominator (page MSI) = serving coherence + node-1 INVALIDATE handling, per query; TLB IPIs as counts per query.
Megalon estimates are computed from the window deltas of the raw sampled counters. The updater (node 0, rs-update
threads / Megalon role update) is reported in separate columns, never added to the serving time.
MOT1 v6 Fig 2 columns (server op.* keys, optime.h; tag in brackets): per operation o in {query (node 1), row_update
(node 0)}: fig2_<o>_n [count], fig2_<o>_T_ms [measured: rdtsc, summed over threads], fig2_<o>_C_ms [Popcorn:
measured swmc_acct; Megalon: derived = sampled x N check estimate + measured intervals (Megalon >= 76: event and
write-side sums of timed sections scaled by their ratio estimators, mg_scaled_window)], fig2_<o>_rest_ms [derived T-C],
per operation. Megalon background threads (not in CohSnap): bg_cpu_ms_node<k> = thr.nr-log-sync + thr.mg-bg run_ns.
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


def coh_src(path):
    """op.coh_src=pc_threads:N,mg_threads:M of a snapshot -> (pc, mg) thread counts ((0, 0) if absent)."""
    pc = mg = 0
    for line in open(path):
        if line.startswith('op.coh_src='):
            d = dict(x.split(':', 1) for x in line.strip().split('=', 1)[1].split(',') if ':' in x)
            pc, mg = int(d.get('pc_threads', 0)), int(d.get('mg_threads', 0))
    return pc, mg


def mg_check_window(b, e, o):
    """Megalon section-check estimate over the window: d(check_ns_sampled + anchor.read_lookup_ns_sampled +
    anchor.read_nr_ns_sampled) x d(read_sections) / d(check_sampled). DLRM all-HWcc = plain backend, so every Megalon
    call is C (M2 §16 "all-HWcc without Megalon"; anchor keys 0 before Megalon 75)."""
    p = f'op.{o}.mg.'
    ds = delta(b, e, p + 'check_sampled')
    ns = sum(delta(b, e, p + k) for k in ('check_ns_sampled', 'anchor.read_lookup_ns_sampled', 'anchor.read_nr_ns_sampled'))
    return ns * delta(b, e, p + 'read_sections') / ds if ds else 0.0


def mg_scaled_window(b, e, o):
    """Megalon >= 76 (op.<o>.mg.flags bit 1 = lean sampling, not bit 2 = events_always; optime.h, M2 §18): window
    estimates of the read-side events d(stale+concur+meta+spin ns) x d(read_sections) / d(check_sampled) and of the
    write side d(wstart+wflush+anchor.write_lookup+anchor.write_nr ns) x d(write_sections) / d(anchor.write_sampled)
    (a zero denominator gives 0). Returns None when the run has no mg.flags key (server built before this rule) or
    the flags say the sums are full (pre-76 or events_always): then c_ns deltas are additive as before."""
    p = f'op.{o}.mg.'
    if p + 'flags' not in e:
        return None
    f = e[p + 'flags']
    if not (f & 2) or (f & 4):
        return None
    ds, dw = delta(b, e, p + 'check_sampled'), delta(b, e, p + 'anchor.write_sampled')
    ev = sum(delta(b, e, p + k) for k in ('stale_ns', 'concur_ns', 'meta_ns', 'spin_ns'))
    wr = sum(delta(b, e, p + k) for k in ('wstart_ns', 'wflush_ns', 'anchor.write_lookup_ns', 'anchor.write_nr_ns'))
    return (ev * delta(b, e, p + 'read_sections') / ds if ds else 0.0) + \
        (wr * delta(b, e, p + 'write_sections') / dw if dw else 0.0)


def op_c_window(b, e, o):
    """C over the window. Pre-76 sums / no mg.flags: additive parts of c_ns (c_ns - cumulative check estimate) + the
    window check estimate. Megalon >= 76 lean sampling: Popcorn part (pc.c_ns delta, 0 for Megalon) + window check
    estimate + window event and write estimates (mg_scaled_window), all from window deltas of the raw counters."""
    sc = mg_scaled_window(b, e, o)
    if sc is None:
        return delta(b, e, f'op.{o}.c_ns') - delta(b, e, f'op.{o}.mg.check_est_ns') + mg_check_window(b, e, o)
    return delta(b, e, f'op.{o}.pc.c_ns') + mg_check_window(b, e, o) + sc


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
            coh = {'swmc_acct': op_c_window(b1, e1, 'query')}  # always-on per-op accounting (optime.h)
            per_qd = (lambda ns: round(ns / q / 1e6, 4)) if q else (lambda ns: '')
            for k in ('read_msg_wait_ns', 'is_fault_ns', 'sm_fault_ns', 'wpu_fault_ns', 'nontrans_fault_ns'):
                r[f'serve_{k[:-3]}_ms_per_query'] = per_qd(delta(b1, e1, p + k))
            r['serve_is_faults'] = delta(b1, e1, p + 'is_faults')
            r['serve_read_transactions'] = delta(b1, e1, p + 'read_transactions')
            node_inval = delta(b1, e1, 'sys.swmc.instr.serve.unmap_ns') + delta(b1, e1, 'sys.swmc.instr.serve.mkclean_ns')
            r['node1_tlb_irqs_per_query'] = round(delta(b1, e1, 'irq.TLB') / q, 2) if q else ''
            r['node1_recv_cpu_ticks'] = sum_prefix(b1, e1, 'kthr.cxl_recv', '.cpu_ticks')
            u = 'thr.rs-update.swmc.'
            r['upd_sm_wpu_fault_ms'] = round((delta(b0, e0, u + 'sm_fault_ns') + delta(b0, e0, u + 'wpu_fault_ns')) / 1e6, 3)
            r['upd_is_fault_ms'] = round(delta(b0, e0, u + 'is_fault_ns') / 1e6, 3)
            r['upd_row_update_C_ms'] = round(op_c_window(b0, e0, 'row_update') / 1e6, 3)
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
            r['megalon_legacy_timers'] = e1.get('megalon_time.sample', 0)
            if e1.get('megalon_time.sample', 0) > 0:  # legacy app-level timers explicitly enabled
                d, coh = est(b1, e1, 'serve')
                r['serve_read_sampled'] = d['read_sampled']
                r['serve_read_fail'] = d['read_fail']
                du, cu = est(b0, e0, 'update')
                r['upd_check_ms'] = round(cu['section_checks'] / 1e6, 3)
                r['upd_flush_ms'] = round(cu['flushes'] / 1e6, 3)
            else:  # CohSnap (shim v2): checks (ratio estimator) + stale/concur/meta/spin/wstart/wflush
                coh = {'cohsnap': op_c_window(b1, e1, 'query')}
            r['serve_read_sections'] = delta(b1, e1, 'megalon_time.serve.read_sections')  # exact counts either way
            r['upd_write_sections'] = delta(b0, e0, 'megalon_time.update.write_sections')
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
        for o, b, e, ep in (('query', b1, e1, epath), ('row_update', b0, e0, e0p)):  # MOT1 v6 Fig 2 (optime.h)
            n = delta(b, e, f'op.{o}.n')
            t, c = delta(b, e, f'op.{o}.t_ns'), op_c_window(b, e, o)
            pc_live = coh_src(ep)[0] > 0
            # Popcorn C needs swmc_acct (build >= 10, registered threads); without it the column is not-available
            ctag = {'hwcc': 'none', 'msi': 'measured' if pc_live else 'not-available', 'megalon': 'derived'}[kind]
            ok = n and ctag != 'not-available'
            r[f'fig2_{o}_n[count]'] = n
            r[f'fig2_{o}_T_ms[measured]'] = round(t / n / 1e6, 6) if n else ''
            r[f'fig2_{o}_C_ms[{ctag}]'] = round(c / n / 1e6, 6) if ok else ''
            r[f'fig2_{o}_rest_ms[derived]'] = round((t - c) / n / 1e6, 6) if ok else ''
            if kind == 'msi':
                r[f'fig2_{o}_pc_nontrans_ms[measured, not in C]'] = round(delta(b, e, f'op.{o}.pc.nontrans_ns') / n / 1e6, 6) if ok else ''
            if kind == 'megalon':
                r[f'fig2_{o}_C_check_ms[sampledxN]'] = round(mg_check_window(b, e, o) / n / 1e6, 6) if n else ''
        if kind == 'megalon':
            for k, b, e in ((0, b0, e0), (1, b1, e1)):
                r[f'bg_cpu_ms_node{k}[measured]'] = round((delta(b, e, 'thr.nr-log-sync.run_ns') +
                                                           delta(b, e, 'thr.mg-bg.run_ns')) / 1e6, 3)
        r['upd_publish_rounds'] = delta(b0, e0, 'publish_rounds')
        r['upd_round_rows'] = delta(b0, e0, 'round_rows')
        r['upd_rows_per_round_target'] = e0.get('rows_per_round_target', '')
        r['upd_rate_sustained'] = 0 if r['upd_flush_overruns'] else 1
        r['serve_seq_retries'] = delta(b1, e1, 'seq_retries')
        r['serve_false_retries'] = delta(b1, e1, 'false_retries')
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

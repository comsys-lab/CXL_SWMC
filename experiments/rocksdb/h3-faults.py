#!/usr/bin/env python3
"""H3 fault aggregates of Popcorn rocksdb runs (experiments/rocksdb/run.sh) on N = 2/4/8 VMs.

usage: h3-faults.py RUN_DIR [RUN_DIR ...] [--ref RUN_DIR[:STEP]] [--out h3-faults.csv]
Per run and fixed/measured step: the node-wide Popcorn counters of every VM (stats-steps.csv = per-step deltas of the
loadgen --stats-op snapshots; sys.* keys are node-wide, from /sys/kernel/swmc, always on, no sudo), summed over the
N VMs and turned into rates over the step window:
  read_faults   sys.swmc.page_coherence.fault_read_count   (every managed read fault, incl. ones without a transition)
  write_faults  sys.swmc.page_coherence.fault_write_count  (incl. write-protect faults)
  is_faults     sys.swmc.instr.fault_full_is.count          (exact I->S read faults through exc_page_fault)
  inv_commits   sys.swmc.instr.tx_invalidate.ack            (committed invalidation rounds = I->M + S->M upgrades)
  fetch_commits sys.swmc.instr.tx_fetch.ack                 (committed fetch rounds)
  unmaps        sys.swmc.instr.serve.unmap_count            (remote invalidations served: PTE unmap + TLB shootdown)
  coh_ipis      sys.swmc.instr.ipi.coh_count                (coherence IPIs received)
A missing counter is left empty (the page_coherence directory must be in the server's sysfs list; it is for
rocksdb-server). Normalisation (H3): write_faults_per_s / the reference's write_faults_per_s (default reference: the
2-VM row with the same per-VM offered rate; --ref RUN[:STEP] fixes one reference), likewise for reads; fault time
(per-thread swmc accounting of the server threads: I->S, S/I->M, WP-upgrade and non-transition faults with their
ns; node-wide coherence IPI time), cxl_recv kernel thread run time, and faults per request. Every VM of every step must report sys.swmc.instr.enabled = 1 (else exit 1).
Per-page read-fault CDF: not in these counters (node-wide only); see reports/ROCKSDB-V1-packet.md §H3 (kprobe + hist
trigger on swmc_fault_account, guest root, separate grant).
"""
import argparse
import csv
import json
import os
import sys

KEYS = {
    "read_faults": ["sys.swmc.page_coherence.fault_read_count"],
    "write_faults": ["sys.swmc.page_coherence.fault_write_count"],
    "is_faults": ["sys.swmc.instr.fault_full_is.count"],
    "inv_commits": ["sys.swmc.instr.tx_invalidate.ack"],
    "fetch_commits": ["sys.swmc.instr.tx_fetch.ack"],
    "unmaps": ["sys.swmc.instr.serve.unmap_count"],
    "coh_ipis": ["sys.swmc.instr.ipi.coh_count"],
    "coh_ipi_ns": ["sys.swmc.instr.ipi.coh_ns"],
}
# Node-wide fault-time histograms (instr fault_read/write/wp sum_ns, fault_full_sm/wpu sum_ns, tx_*.wait_sum_ns)
# fill only with instr/detail=1; the runs keep detail=0 (bundle), so fault time comes from the per-thread
# accounting of the server's own threads (always filled): thr.<comm>.swmc.<kind>_fault_ns / <kind>_faults
# (verifier re-review M-A). thr.* covers the rocksdb-server process only (RocksDB background threads included).
PREFIX_SUMS = {  # summed over every matching key (several kernel threads / rounds)
    "cxl_recv_run_ns": ("kthr.cxl_recv", ".run_ns"),
    "cxl_recv_cpu_ticks": ("kthr.cxl_recv", ".cpu_ticks"),
    "thr_is_faults": ("thr.", ".swmc.is_faults"),
    "thr_is_fault_ns": ("thr.", ".swmc.is_fault_ns"),
    "thr_sm_faults": ("thr.", ".swmc.sm_faults"),
    "thr_sm_fault_ns": ("thr.", ".swmc.sm_fault_ns"),
    "thr_wpu_faults": ("thr.", ".swmc.wpu_faults"),
    "thr_wpu_fault_ns": ("thr.", ".swmc.wpu_fault_ns"),
    "thr_nontrans_faults": ("thr.", ".swmc.nontrans_faults"),
    "thr_nontrans_fault_ns": ("thr.", ".swmc.nontrans_fault_ns"),
}


def manifest(run):
    m = {}
    for line in open(os.path.join(run, "manifest.txt"), errors="replace"):
        if "=" in line and not line.startswith("#"):
            k, v = line.rstrip("\n").split("=", 1)
            m.setdefault(k, v)
    return m


def steps_info(run):
    out = {}
    p = os.path.join(run, "loadgen", "steps.jsonl")
    if os.path.exists(p):
        for line in open(p):
            if line.strip():
                s = json.loads(line)
                m = s.get("streams", {}).get("mixed", {})
                out[str(s["step"])] = (s.get("phase"), s.get("offered_x"), m.get("achieved"), m.get("p99_ms"),
                                       s.get("measure_s", 0))
    return out


def rows(run):
    m = manifest(run)
    n = int(m.get("nodes", "2"))
    info = steps_info(run)
    by_step = {}
    for r in csv.DictReader(open(os.path.join(run, "stats-steps.csv"))):
        by_step.setdefault(r["step"], []).append(r)
    for step, rs in sorted(by_step.items(), key=lambda x: int(x[0])):
        phase, offered, achieved, p99, measure_s = info.get(step, (None, None, None, None, 0))
        if not measure_s:
            continue  # warm-up and drain steps carry no measurement window
        if len(rs) != n:
            sys.exit(f"{run} step {step}: {len(rs)} targets in stats-steps.csv != nodes {n}")
        win = max(float(r["window_s"] or 0) for r in rs)
        o = {"run": os.path.basename(run.rstrip("/")), "system": m.get("system"), "nodes": n, "step": step,
             "phase": phase, "offered_x": offered, "per_vm_x": (offered / n if offered else None), "achieved": achieved,
             "p99_ms": p99, "targets": len(rs), "window_s": win}
        enabled = [r.get("sys.swmc.instr.enabled") for r in rs]
        o["instr_enabled_all"] = all(e not in (None, "") and float(e) == 1 for e in enabled)
        for name, (pre, suf) in PREFIX_SUMS.items():
            tot = None
            for r in rs:
                for k, v in r.items():
                    if k.startswith(pre) and k.endswith(suf) and v not in (None, ""):
                        tot = (tot or 0) + float(v)
            o[name] = tot
            o[name + "_per_s"] = (tot / win if tot is not None and win else None)
        for name, keys in KEYS.items():
            tot = None
            for r in rs:
                v = next((r[k] for k in keys if r.get(k) not in (None, "")), None)
                if v is not None:
                    tot = (tot or 0) + float(v)
            o[name] = tot
            o[name + "_per_s"] = (tot / win if tot is not None and win else None)
            o[name + "_per_s_per_vm"] = (tot / win / n if tot is not None and win else None)
        yield o


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--ref")
    ap.add_argument("--out", default="h3-faults.csv")
    a = ap.parse_args()
    allr = [r for run in a.runs for r in rows(run)]
    if not allr:
        sys.exit("no measured steps")
    if not all(r["instr_enabled_all"] for r in allr):
        bad = [f"{r['run']}:{r['step']}" for r in allr if not r["instr_enabled_all"]]
        sys.exit(f"instr/enabled != 1 on some VM (sys.swmc.instr.enabled) in steps {bad}: counters incomplete")
    for r in allr:  # per request (achieved requests over the window, all VMs)
        req = r["achieved"] * r["window_s"] if r.get("achieved") and r.get("window_s") else None
        for k in ("read_faults", "write_faults", "is_faults", "inv_commits"):
            r[k + "_per_req"] = (r[k] / req if r.get(k) is not None and req else None)
    ref = None
    if a.ref:
        run, _, step = a.ref.partition(":")
        cand = [r for r in allr if r["run"] == os.path.basename(run.rstrip("/")) and (not step or r["step"] == step)]
        ref = cand[0] if cand else None
    if a.ref and ref is None:
        sys.exit("reference step not found")
    # normalisation: by default each row against the 2-VM row with the same per-VM offered rate (verifier M4);
    # --ref fixes one reference step for every row
    twos = [r for r in allr if r["nodes"] == 2]
    for r in allr:
        base_row = ref
        if base_row is None:
            m = [t for t in twos if t["per_vm_x"] and r["per_vm_x"] and abs(t["per_vm_x"] - r["per_vm_x"]) <= 0.005 * t["per_vm_x"]]
            base_row = m[0] if m else None
        r["norm_ref"] = f"{base_row['run']}:{base_row['step']}" if base_row else ""
        for k in ("write_faults", "read_faults", "is_faults"):
            base = base_row.get(k + "_per_s") if base_row else None
            r[k + "_norm"] = (r[k + "_per_s"] / base if r.get(k + "_per_s") is not None and base else None)
    cols = list(allr[0].keys())
    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(allr)
    print("reference: " + (f"{ref['run']} step {ref['step']} (fixed)" if ref else "2-VM row with the same per_vm_x"))
    for r in allr:
        print(f"{r['run']} N={r['nodes']} step={r['step']} per_vm_x={r['per_vm_x']} achieved={r['achieved']} "
              f"p99={r['p99_ms']} write/s={r['write_faults_per_s']} read/s={r['read_faults_per_s']} "
              f"is/s={r['is_faults_per_s']} write_norm={r['write_faults_norm']} read_norm={r['read_faults_norm']}")
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Per-operation time split per measured step (MOT1 v6 Fig 2; reports/MOT1-v6-redesign-draft.md §3).

usage: opsplit.py LOADGEN_DIR --system SYSTEM [--out CSV]
LOADGEN_DIR is a loadgen --out dir with stats/step<NNN>-{begin,end}-t<k>.txt (--stats-op snapshots) of a server that
emits the opsplit keys (workloads/kv/server/opsplit.h: kv-server, lmdb-server): opt.<op>.{ops,t_ns,c_ns,pop.*,meg.*}
plus gauges opt.tsc_hz, opt.pop_threads, opt.meg_coh, opt.meg_check_sample.

One row per (step, operation type), summed over every target (node) with both snapshots of the step:
  T  = sum of per-operation durations (rdtsc at both ends of each operation) / operations
  C  = coherence-management time inside those operations / operations, by the run's SYSTEM:
       Popcorn / page MSI: fault time (I->S + S->M + write-protect) + TLB-shootdown IPI handling (swmc_acct);
                           faults without a transition (pop_nontrans_*, build 10) are exported but NOT in C
       Megalon:            section checks (ratio estimate check_ns_sampled x read_sections / check_sampled, read
                           sections only; contract CXL_SWMC 2015a31f3) + stale copy (A) + concurrent write (B) + metadata (C)
                           + writer spin (D) + write start + write-end flush (CohSnap; switch_rw and reclaim are
                           parts of write start and shown separately) + the workload's validation copy (lmdb: 4 KiB
                           page copy of an accepted read section, which plain does not make; ratio estimate
                           vcopy_ns_sampled x vcopy_cnt / vcopy_sampled; user decision MOT1 v6 §3.1)
       all-HWcc:           0 by definition (no coherence actions)
  rest = T - C
  mod_bytes = bytes the application stored per operation (put / update value; 0 for reads)
Background coherence CPU (not inside any operation; same value on every op row of a step, summed over targets):
  lib_bg_cpu_s     run time of the server's thread groups not named kv-* / lmdb-* (Megalon: megalon-lib, nr-log-sync,
                   its reclaim thread; in the plain KV backend the same groups belong to the hwcc-flavor store)
  recv_cpu_s       kernel threads cxl_recv* (Popcorn message receive)
  coh_bg_cpu_s     by SYSTEM: Megalon lib_bg_cpu_s, Popcorn recv_cpu_s, all-HWcc 0;
  coh_bg_us_per_op coh_bg_cpu_s / all operations of the step
C is 0 with c_supported=0 when the source is not available (Popcorn kernel without swmc_acct, Megalon v1 shim).
Every column name carries its tag: [measured] (a recorded quantity, possibly averaged per operation), [sampled_xN]
(estimate from a 1-in-N sample of read sections, N in meg_check_sample), [derived] (formula of other columns).
"""
import argparse, csv, os, re, sys

FNAME = re.compile(r"^step(\d+)-(begin|end)-t(\d+)\.txt$")
POP = ["is_ns", "sm_ns", "wp_ns", "is_cnt", "sm_cnt", "wp_cnt", "ipi_ns", "ipi_cnt", "nontrans_ns", "nontrans_cnt"]
MEG_NS = ["stale_ns", "concur_ns", "meta_ns", "spin_ns", "wstart_ns", "switch_rw_ns", "reclaim_ns", "wflush_ns"]
MEG_CNT = ["read_sections", "write_sections", "check_sampled", "stale_cnt", "concur_cnt", "meta_cnt", "spin_cnt",
           "switch_rw_cnt", "reclaim_cnt", "wflush_cnt", "wflush_bytes", "tsc_backwards"]
MEG_IN_C = ["stale_ns", "concur_ns", "meta_ns", "spin_ns", "wstart_ns", "wflush_ns"]


def system_source(system):
    s = system.lower()
    if "megalon" in s:
        return "megalon"
    if "popcorn" in s or "msi" in s:
        return "popcorn"
    if "hwcc" in s:
        return "none"
    sys.exit(f"opsplit: unknown system label {system!r} (expected all-HWcc / Popcorn* / page-MSI / Megalon*)")


def parse(path):
    hdr, kv = {}, {}
    with open(path) as f:
        first = f.readline()
        if first.startswith("#"):
            for tok in first[1:].split():
                k, _, v = tok.partition("=")
                hdr[k] = v
        for line in f:
            k, sep, v = line.rstrip("\n").partition("=")
            if sep and k:
                kv[k] = v.strip()
    return hdr, kv


def num(kv, k):
    try:
        return float(kv[k])
    except (KeyError, ValueError):
        return None


def columns(ops_present):
    c = ["step", "phase", "offered_x", "system", "op", "targets", "c_source", "c_supported",
         "window_s[measured]", "ops[measured]", "ops_per_s[derived]",
         "T_us_per_op[measured]", "C_us_per_op[derived]", "rest_us_per_op[derived]", "C_share[derived]",
         "T_max_us[measured]", "mod_bytes_per_op[measured]"]
    c += [f"pop_{k[:-3]}_us_per_op[measured]" for k in POP if k.endswith("_ns")]
    c += [f"pop_{k[:-4]}_per_op[measured]" for k in POP if k.endswith("_cnt")]
    c += ["lib_bg_cpu_s[measured]", "recv_cpu_s[measured]", "coh_bg_cpu_s[derived]", "coh_bg_us_per_op[derived]"]
    c += ["meg_check_us_per_op[sampled_xN]", "meg_check_sample[measured]", "meg_vcopy_us_per_op[sampled_xN]",
          "meg_vcopy_per_op[measured]"]
    c += [f"meg_{k[:-3]}_us_per_op[measured]" for k in MEG_NS]
    c += [f"meg_{k}_per_op[measured]" for k in MEG_CNT]
    return c


def rows(run, system):
    src = system_source(system)
    d = os.path.join(run, "stats")
    snaps = {}
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        m = FNAME.match(name)
        if m:
            snaps.setdefault(int(m.group(1)), {}).setdefault(int(m.group(3)), {})[m.group(2)] = parse(os.path.join(d, name))
    out = []
    for step in sorted(snaps):
        pairs = [(p["begin"], p["end"]) for t, p in sorted(snaps[step].items()) if "begin" in p and "end" in p]
        if not pairs:
            continue
        ops = sorted({k.split(".")[1] for _, (_, e) in pairs for k in e if re.match(r"^opt\.[^.]+\.ops$", k)})
        if not ops:
            sys.exit(f"opsplit: step {step}: no opt.<op>.ops keys (server without the per-operation split)")
        he = pairs[0][1][0]
        win = [(int(e[0]["mono_ns"]) - int(b[0]["mono_ns"])) / 1e9 for b, e in pairs if "mono_ns" in b[0] and "mono_ns" in e[0]]
        window = sum(win) / len(win) if win else 0.0
        supported = 1
        if src == "popcorn":
            supported = int(all((num(e[1], "opt.pop_threads") or 0) > 0 for _, e in pairs))
        elif src == "megalon":
            supported = int(all((num(e[1], "opt.meg_coh") or 0) > 0 for _, e in pairs))
        csample = max((num(e[1], "opt.meg_check_sample") or 0) for _, e in pairs)
        def gsum(pred):
            s = 0.0
            for (_, b), (_, e) in pairs:
                for k, ve in e.items():
                    if pred(k) and k in b and num(e, k) is not None and num(b, k) is not None:
                        s += num(e, k) - num(b, k)
            return s
        lib_bg = gsum(lambda k: k.startswith("thr.") and k.endswith(".run_ns") and not k.startswith(("thr.kv-", "thr.lmdb-"))) / 1e9
        recv = gsum(lambda k: k.startswith("kthr.cxl_recv") and k.endswith(".run_ns")) / 1e9
        coh_bg = lib_bg if src == "megalon" else recv if src == "popcorn" else 0.0
        all_ops = sum(num(e, f"opt.{o}.ops") - num(b, f"opt.{o}.ops") for o in ops for (_, b), (_, e) in pairs
                      if num(e, f"opt.{o}.ops") is not None and num(b, f"opt.{o}.ops") is not None)
        for op in ops:
            def dsum(key):
                s = 0.0
                for (_, b), (_, e) in pairs:
                    vb, ve = num(b, key), num(e, key)
                    if vb is not None and ve is not None:
                        s += ve - vb
                return s
            p = f"opt.{op}."
            n = dsum(p + "ops")
            per = (lambda x: x / n / 1e3) if n else (lambda x: 0.0)   # ns sum -> us per op
            cnt = (lambda x: x / n) if n else (lambda x: 0.0)
            T = per(dsum(p + "t_ns"))
            pop = {k: dsum(p + "pop." + k) for k in POP}
            meg = {k: dsum(p + "meg." + k) for k in MEG_NS + MEG_CNT + ["check_ns_sampled", "vcopy_ns_sampled", "vcopy_sampled", "vcopy_cnt"]}
            vcopy_est = meg["vcopy_ns_sampled"] * meg["vcopy_cnt"] / meg["vcopy_sampled"] if meg["vcopy_sampled"] else 0.0
            check_est = meg["check_ns_sampled"] * meg["read_sections"] / meg["check_sampled"] if meg["check_sampled"] else 0.0
            if src == "popcorn":
                C = per(pop["is_ns"] + pop["sm_ns"] + pop["wp_ns"] + pop["ipi_ns"])
            elif src == "megalon":
                C = per(check_est + sum(meg[k] for k in MEG_IN_C) + vcopy_est)
            else:
                C = 0.0
            if not supported:
                C = 0.0
            tmax = max((num(e, p + "t_max_ns") or 0) for _, (_, e) in pairs) / 1e3
            r = [step, he.get("phase", ""), he.get("offered_x", ""), system, op, len(pairs), src, supported,
                 round(window, 6), int(n), round(n / window, 3) if window else "",
                 round(T, 4), round(C, 4), round(T - C, 4), round(C / T, 6) if T else "", round(tmax, 3),
                 round(cnt(dsum(p + "mod_bytes")), 3)]
            r += [round(per(pop[k]), 4) for k in POP if k.endswith("_ns")]
            r += [round(cnt(pop[k]), 6) for k in POP if k.endswith("_cnt")]
            r += [round(lib_bg, 6), round(recv, 6), round(coh_bg, 6), round(coh_bg * 1e6 / all_ops, 4) if all_ops else ""]
            r += [round(per(check_est), 4), int(csample), round(per(vcopy_est), 4), round(cnt(meg["vcopy_cnt"]), 6)]
            r += [round(per(meg[k]), 4) for k in MEG_NS]
            r += [round(cnt(meg[k]), 6) for k in MEG_CNT]
            out.append(r)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--system", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()
    rs = rows(a.run, a.system)
    if not rs:
        sys.exit(f"opsplit: no begin/end snapshot pairs in {a.run}/stats")
    out = a.out or os.path.join(a.run, "opsplit.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(columns(None))
        w.writerows(rs)
    print(f"-> {out} ({len(rs)} step/op rows)")


if __name__ == "__main__":
    main()

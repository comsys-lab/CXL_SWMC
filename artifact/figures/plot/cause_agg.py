"""Per-run Fig 8b terms: the workspaces/fig8-cause/agg.py formulas (only the columns Fig 8b uses), for any run.

Usage (library): terms(slo_dir, step) -> {W_ms, lock_ms, e1_ms, srch_rq_ms, C_ms, NT_ms, replay_ms, missing: [...]}
  slo_dir = <recovery>/eval2-run<k>-h2-n<N>-v*/block/<sys>-<mix>-n<N>/slo (the H2 summary.csv source_dir).
Formulas (agg.py, per search): W = sum search_busy_ns / searches; lock = search_lock_ns_total / searches;
  e1 = opsplit-steps.csv search wait_ms; rq = thr.vdb-search.wait_ns / searches; C = opsplit C_ms;
  NT = opsplit pop_nontrans_ms; replay = replay_ns_total / searches. Sums over the VM rows of stats-steps.csv.
A term whose counter column is absent in every VM row is reported in `missing` (agg.py silently used 0).
Self-test: python3 -I -B cause_agg.py <steps-cause.csv> <H2 run-1 summary.csv>  (the reference of the original
  analysis: <control>/workspaces/fig8-cause/steps-cause.csv and eval2-derived/h2/vdb/h2n/run1/summary.csv).
"""
import csv
import os

_cache = {}


def _load(slo_dir):
    if slo_dir not in _cache:
        ops = {(r["step"], r["op"]): r for r in csv.DictReader(open(f"{slo_dir}/opsplit-steps.csv"))}
        st = {}
        for r in csv.DictReader(open(f"{slo_dir}/stats-steps.csv")):
            st.setdefault(r["step"], []).append(r)
        _cache[slo_dir] = (ops, st)
    return _cache[slo_dir]


def _f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def terms(slo_dir, step):
    ops, st = _load(slo_dir)
    step = str(step)
    vr = st[step]
    s = ops.get((step, "search"), {})
    miss = []

    def S(k):
        v = [_f(r.get(k)) for r in vr]
        if all(x is None for x in v):
            miss.append(k)
        return sum(x or 0.0 for x in v)

    def O(k):
        v = _f(s.get(k))
        if v is None:
            miss.append(f"opsplit:{k}")
        return v or 0.0

    srch = S("searches")
    return dict(W_ms=S("search_busy_ns") / srch / 1e6, lock_ms=S("search_lock_ns_total") / srch / 1e6,
                e1_ms=O("wait_ms"), srch_rq_ms=S("thr.vdb-search.wait_ns") / srch / 1e6, C_ms=O("C_ms"),
                NT_ms=_f(s.get("pop_nontrans_ms")) or 0.0, replay_ms=S("replay_ns_total") / srch / 1e6, missing=miss)


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3:
        raise SystemExit("usage: cause_agg.py <steps-cause.csv> <H2 run-1 summary.csv>")
    ref = {(r["nodes"], r["mix"], r["system"], r["step"]): r for r in csv.DictReader(open(sys.argv[1]))}
    summ = {(r["nodes"], r["mix"], r["system"]): r["source_dir"]
            for r in csv.DictReader(open(sys.argv[2]))}
    worst = 0.0
    for (n, mix, s, step), r in ref.items():
        if s not in ("hw", "pop"):
            continue
        t = terms(summ[(n, mix, s)], step)
        for k in ("W_ms", "lock_ms", "e1_ms", "srch_rq_ms", "C_ms", "replay_ms"):
            worst = max(worst, abs(t[k] - float(r[k])))
    print(f"max abs diff vs steps-cause.csv over {len(ref)} steps: {worst:.5f} ms")

#!/usr/bin/env python3
"""eval3 statistics extractor: run result dirs -> one CSV per evaluation figure (Host only, offline, read-only).

usage: eval3_extract.py RESULT_DIR [RESULT_DIR ...] --out OUT_DIR [--l1 u50=21.6,u10=108] [--systems hw,pop,mg,ds]

Design doc: reports/experiments/de-stijl-evaluation-run1-schedule.md §2-§4 and reports/experiments/
"4. Evaluation_outline.tex". Column documentation and formulas: experiments/analysis/eval3_extract.md.

Input layout (every harness of the repo writes it): a "part" is any directory holding steps.csv (loadgen
summary per step and stream) or loadgen/steps.jsonl, plus per-step server counter deltas stats-steps.csv
(experiments/loadgen/stats_delta.py; recomputed in memory from loadgen/stats/ when the CSV is missing). The cell
(system, mix, N) comes from the nearest path component named like <sys>-<mix>[-n<N>] (sys in hw, pop, mg, mgoff,
ds; e.g. block/pop-u50-n2/slo, S-pop-u5, pop-u400/slo); N falls back to the number of stats targets.

Outputs in OUT_DIR (all CSV, one row per cell x step unless noted; pooled rows use step = L1 / MAX / PMAX):
  cells.csv                 one row per part: identity, workload, source dir, L1 / MAX / PMAX selection
  (run 2: a part named "pmax" = h2n-block.sh H2N_PMAX, the fixed step at Popcorn's max under SLO of the cell; its
   steps get sel / pooled step PMAX and never L1: select step == "PMAX" for the fault breakdown at Popcorn's max load)
  fig-latency-vs-rps.csv    per measured step: offered / achieved rates, p50/p95/p99/SLO-percentile latency
  fig-max-under-slo.csv     per cell: max rate under SLO (SLO stream /s and total offered req/s)
  fig-flushed-lines-l1.csv  per vector DB cell at the L1 step: average flushed cache lines per search
  fig-fault-breakdown.csv   per step x fault class: five latency categories in us per fault
  fig-coherence-rates.csv   per step: faults/s, coherence messages/s (Popcorn tx/serve, De Stijl fetch/inv/ack)
  fig-search-breakdown.csv  per step x operation: opt.<op>.pop.* time per operation (ms)
  fig-ds-staleness.csv      per De Stijl step: SS-served read share, SS residence p95 / max (us)
"""
import argparse
import csv
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "loadgen"))

CELL = re.compile(r"^(?:[A-Za-z]+-)?(hw|pop|mgoff|mg|ds)-(u\d+)(?:-n(\d+))?(?:-.*)?$")
SLO_DEFAULT = {"vectordb": ("search", 99.0, 100.0), "recsys": ("query", 95.0, 100.0), "rocksdb": ("mixed", 99.0, 1.0)}
FIXED_PHASES = ("fixed", "l1")


def warn(msg):
    print(f"eval3_extract WARNING: {msg}", file=sys.stderr)


def fl(v):
    try:
        x = float(v)
        return None if x != x else x
    except (TypeError, ValueError):
        return None


def tf(v):
    return str(v).strip().lower() in ("true", "1", "yes")


def div(a, b):
    return a / b if a is not None and b else None


def sub(a, *bs):
    if a is None:
        return None
    return a - sum(b or 0.0 for b in bs)


# ----------------------------------------------------------------------------------------------- discovery
def find_parts(roots):
    out = []
    for root in roots:
        root = os.path.abspath(root)
        for dp, dn, fn in os.walk(root):
            dn.sort()
            has_csv = "steps.csv" in fn
            has_jsonl = os.path.isfile(os.path.join(dp, "loadgen", "steps.jsonl"))
            if os.path.basename(dp) == "loadgen":
                continue
            if has_csv or has_jsonl:
                out.append((root, dp))
    return out


def cell_of(root, part):
    rel = os.path.relpath(part, root).split(os.sep)
    for i in range(len(rel) - 1, -1, -1):
        m = CELL.match(rel[i])
        if m:
            sub_part = "/".join(rel[i + 1:]) or "."
            return m.group(1), m.group(2), int(m.group(3)) if m.group(3) else None, rel[i], sub_part
    return None


# ----------------------------------------------------------------------------------------------- loading
def load_steps(part):
    """{step: {phase, measure_s, pass, aborted, offered_x, streams: {name: row}, meta: row}} (measured steps only)"""
    steps = {}
    p = os.path.join(part, "steps.csv")
    if os.path.isfile(p):
        with open(p) as f:
            srows = list(csv.DictReader(f))
        for r in srows:
            n = int(r["step"])
            s = steps.setdefault(n, {"phase": r.get("phase", ""), "measure_s": fl(r.get("measure_s")),
                                     "pass": tf(r.get("pass")), "aborted": tf(r.get("aborted")), "streams": {},
                                     "meta": r})
            s["streams"][r["stream"]] = r
    else:
        with open(os.path.join(part, "loadgen", "steps.jsonl")) as f:
            lines = f.read().splitlines()
        for line in lines:
            if not line.strip():
                continue
            d = json.loads(line)
            steps[int(d["step"])] = {"phase": d.get("phase", ""), "measure_s": fl(d.get("measure_s")),
                                     "pass": bool(d.get("pass")), "aborted": bool(d.get("aborted")),
                                     "streams": d.get("streams", {}), "meta": {}, "offered_x": fl(d.get("offered_x"))}
    steps = {n: s for n, s in steps.items() if (s["measure_s"] or 0) > 0}
    for s in steps.values():
        if s.get("offered_x") is None:
            s["offered_x"] = sum(fl(v.get("offered")) or 0.0 for v in s["streams"].values())
    return steps


THR = re.compile(r"^thr\.([^.]+)\.swmc\.(.+)$")
NODE_PREFIXES = ("sys.swmc.destijl.", "sys.swmc.instr.serve_")


def load_stats(part):
    """{step: {"n": targets, "win": max window_s, "offered_x", "sum": {key: sum over targets},
    "gmax": {key: max over targets}, "T": {swmc key: sum over threads and targets},
    "role": {(thread, key): sum over targets}}}"""
    rows = []
    p = os.path.join(part, "stats-steps.csv")
    if os.path.isfile(p):
        with open(p) as f:
            rows = list(csv.DictReader(f))
    elif os.path.isdir(os.path.join(part, "loadgen", "stats")):
        try:
            import stats_delta
            for fx, d in stats_delta.deltas(os.path.join(part, "loadgen")):
                r = {k: v for k, v in fx.items()}
                r.update(d)
                rows.append(r)
        except Exception as e:  # noqa: BLE001 (analysis only)
            warn(f"{part}: stats unreadable ({e!r})")
    acc = {}
    for r in rows:
        n = int(r["step"])
        t = acc.setdefault(n, {"n": 0, "win": 0.0, "offered_x": fl(r.get("offered_x")), "sum": {}, "gmax": {},
                               "T": {}, "role": {}, "tg": {}})
        t["n"] += 1
        t["win"] = max(t["win"], fl(r.get("window_s")) or 0.0)
        # per-target node counters (De Stijl owner phases are taken from the OTHER nodes of each requester)
        tg = t["tg"].setdefault(str(r.get("target")), {})
        for k, v in r.items():
            if k.startswith(NODE_PREFIXES):
                x = fl(v)
                if x is not None:
                    tg[k] = tg.get(k, 0.0) + x
        for k, v in r.items():
            if k in ("step", "phase", "offered_x", "target", "addr", "begin_wall_ns", "end_wall_ns", "window_s",
                     "srv_window_s"):
                continue
            x = fl(v)
            if x is None:
                continue
            t["sum"][k] = t["sum"].get(k, 0.0) + x
            t["gmax"][k] = max(t["gmax"].get(k, x), x)
            m = THR.match(k)
            if m:
                t["T"][m.group(2)] = t["T"].get(m.group(2), 0.0) + x
                t["role"][(m.group(1), m.group(2))] = t["role"].get((m.group(1), m.group(2)), 0.0) + x
    return acc


def pool(stats, steps_sel):
    """sum the counter dicts of several steps (windows add up); gauges keep the max"""
    out = {"n": 0, "k": 0, "win": 0.0, "offered_x": None, "sum": {}, "gmax": {}, "T": {}, "role": {}, "tg": {}}
    for n in steps_sel:
        t = stats.get(n)
        if not t:
            continue
        for tgt, d in t.get("tg", {}).items():
            o = out["tg"].setdefault(tgt, {})
            for k, v in d.items():
                o[k] = o.get(k, 0.0) + v
        out["k"] += 1
        out["n"] = max(out["n"], t["n"])
        out["win"] += t["win"]
        for f in ("sum", "T", "role"):
            for k, v in t[f].items():
                out[f][k] = out[f].get(k, 0.0) + v
        for k, v in t["gmax"].items():
            out["gmax"][k] = max(out["gmax"].get(k, v), v)
    return out


def workload_of(steps):
    names = set()
    for s in steps.values():
        names |= set(s["streams"])
    if "search" in names:
        return "vectordb"
    if "query" in names:
        return "recsys"
    if names & {"get", "mixed", "read"}:
        return "rocksdb"
    return "unknown"


def slo_of(steps, workload):
    for s in steps.values():
        m = s["meta"]
        if m.get("slo_stream"):
            return m["slo_stream"], fl(m.get("slo_pct")), fl(m.get("slo_ms"))
    return SLO_DEFAULT.get(workload, ("search", 99.0, 100.0))


# ----------------------------------------------------------------------------------------------- cells
class Cell:
    def __init__(self, root, part, system, mix, N, life, subpart):
        self.root, self.part, self.system, self.mix, self.life, self.subpart = root, part, system, mix, life, subpart
        self.steps = load_steps(part)
        self.stats = load_stats(part)
        self.workload = workload_of(self.steps)
        ns = {t["n"] for t in self.stats.values()}
        self.N = N if N is not None else (max(ns) if ns else None)
        self.slo_stream, self.slo_pct, self.slo_ms = slo_of(self.steps, self.workload)
        self.h2n = self.h2n_row()
        self.l1, self.l1_src, self.l1_rate = [], "", None
        # run 2 (h2n-block.sh H2N_PMAX): part "pmax" = the fixed step at Popcorn's max of the cell (fault breakdown
        # at high load); its steps are labelled PMAX, never L1
        self.is_pmax = self.subpart.split("/")[0] == "pmax"
        self.pm, self.pm_rate = [], None
        self.mx, self.mx_src = self.max_steps()
        self.ds_status, self.ds_status_note = None, ""

    @property
    def group(self):
        return (self.workload, self.mix, self.N)

    def h2n_row(self):
        d = self.part
        while len(d) >= len(self.root):
            p = os.path.join(d, "h2n-results.tsv")
            if os.path.isfile(p):
                with open(p) as f:
                    lines = f.read().splitlines()
                if lines and lines[0].startswith("#"):
                    lines[0] = lines[0].lstrip("# ")
                for r in csv.DictReader(lines, delimiter="\t"):
                    if r.get("name") == self.life:
                        return r
                return {}
            nd = os.path.dirname(d)
            if nd == d:
                break
            d = nd
        return {}

    def slo_row(self, n):
        return self.steps[n]["streams"].get(self.slo_stream, {})

    def step_ok(self, n):
        s = self.steps[n]
        r = self.slo_row(n)
        lat = fl(r.get("pslo_ms")) if r.get("pslo_ms") not in (None, "") else fl(r.get("p99_ms"))
        within = lat is not None and self.slo_ms is not None and lat <= self.slo_ms
        return s["pass"] and not s["aborted"] and within

    def max_steps(self):
        """steps at the max rate under SLO: passing confirm steps at the highest passing offered rate (pooled);
        no confirm phase -> highest passing step of any non-overload phase; nothing passes -> lowest-rate step"""
        if not any(s["phase"] not in FIXED_PHASES for s in self.steps.values()):
            return [], ""
        ok = [n for n in self.steps if self.step_ok(n) and self.steps[n]["phase"] not in FIXED_PHASES]
        conf = [n for n in ok if self.steps[n]["phase"] == "confirm"]
        cand, src = (conf, "confirm") if conf else ([n for n in ok if self.steps[n]["phase"] != "overload"], "pass")
        if cand:
            top = max(self.steps[n]["offered_x"] for n in cand)
            return sorted(n for n in cand if abs(self.steps[n]["offered_x"] - top) <= 0.03 * top), src
        lo = min((n for n in self.steps if self.steps[n]["phase"] not in FIXED_PHASES),
                 key=lambda n: (self.steps[n]["offered_x"], n))
        return [lo], "floor"

    def max_rate(self):
        """(max under SLO in SLO-stream ops/s, in total offered req/s, source)"""
        h = self.h2n
        if h.get("max_offered_x_pass"):
            return fl(h.get("confirm_x_mean")), fl(h.get("max_offered_x_pass")), "h2n-results.tsv"
        for s in self.steps.values():
            m = s["meta"]
            if m.get("max_under_slo") not in (None, ""):
                tot = fl(m.get("result_pooled_offered"))
                if tot is None and self.mx and self.mx_src != "floor":
                    tot = self.steps[self.mx[0]]["offered_x"]
                return fl(m["max_under_slo"]), tot, "steps.csv"
        if self.mx_src in ("confirm", "pass"):
            rows = [self.slo_row(n) for n in self.mx]
            ach = [fl(r.get("achieved")) for r in rows if fl(r.get("achieved")) is not None]
            return (sum(ach) / len(ach) if ach else None), self.steps[self.mx[0]]["offered_x"], f"steps:{self.mx_src}"
        return None, None, "none"


def choose_l1(cells, override):
    """L1 per (workload, mix, N): fixed-phase step of the cell if present; else the rate override (--l1) or
    the lowest max under SLO (total offered req/s) among the group's systems, falling back to the lowest measured
    rate when some system has none (doc §2, outline 'Motivation'); the cell's nearest measured step is used."""
    groups = {}
    for c in cells:
        groups.setdefault(c.group, []).append(c)
    for g, cs in groups.items():
        rate, src = override.get(g[1]), "override"
        if rate is None:
            maxes = []
            floor = False
            sweeps = [c for c in cs if c.mx and c.system != "mgoff"]
            for c in sweeps:
                _, tot, _ = c.max_rate()
                if tot is None or c.mx_src == "floor":
                    floor = True
                else:
                    maxes.append(tot)
            lows = [min(s["offered_x"] for s in c.steps.values() if s["phase"] not in FIXED_PHASES) for c in sweeps]
            if floor and lows:
                rate, src = min(lows), "lowest-rate (a system has no max under SLO)"
            elif maxes:
                rate, src = min(maxes), "min max-under-SLO"
        for c in cs:
            fx = [n for n in c.steps if c.steps[n]["phase"] in FIXED_PHASES]
            if c.is_pmax:  # run 2 pmax part: PMAX steps (fixed steps at the top rate), no L1
                if fx:
                    top = max(c.steps[n]["offered_x"] for n in fx)
                    c.pm, c.pm_rate = sorted(n for n in fx if c.steps[n]["offered_x"] == top), top
                continue
            if fx:
                top = max(c.steps[n]["offered_x"] for n in fx)
                c.l1 = sorted(n for n in fx if c.steps[n]["offered_x"] == top)
                c.l1_src, c.l1_rate = "fixed step", top
            elif rate is not None and c.steps:
                n = min(c.steps, key=lambda k: (abs(c.steps[k]["offered_x"] - rate), c.steps[k]["phase"] == "overload", k))
                c.l1, c.l1_src, c.l1_rate = [n], f"nearest step to {rate:g} ({src})", rate


# ----------------------------------------------------------------------------------------------- formulas
def flushed_lines(c, t):
    """average flushed cache lines per search (formula of workspaces/figs-54m/fig23/export_fixed.py)"""
    S = t["sum"]
    ns = S.get("searches")
    r = {"srv_searches": ns}
    if c.system in ("mg", "mgoff"):
        sev = sum(S.get(k, 0.0) for k in ("opt.search.meg.stale_cnt", "opt.search.meg.concur_cnt")) \
            if any(k in S for k in ("opt.search.meg.stale_cnt", "opt.search.meg.concur_cnt")) else None
        fb, fc = S.get("megalon.flush_bytes"), S.get("megalon.flushes")
        wb = sum(S.get(k, 0.0) for k in ("opt.search.meg.wflush_bytes", "opt.update.meg.wflush_bytes"))
        wc = sum(S.get(k, 0.0) for k in ("opt.search.meg.wflush_cnt", "opt.update.meg.wflush_cnt"))
        rb = fb - wb if fb is not None else None
        rf = fc - wc if fc is not None else None
        bpf = div(rb, rf)
        ev = div(sev, ns)
        lines = ev * bpf / 64 if ev is not None and bpf is not None else (0.0 if ev == 0 else None)
        r.update(mg_search_events=sev, mg_events_per_search=ev, mg_rflush_bytes=rb, mg_rflushes=rf,
                 mg_rflush_bytes_per_flush=bpf)
    elif c.system in ("pop", "ds"):
        isf = t["role"].get(("vdb-search", "is_faults"))
        ips = div(isf, ns)
        lines = ips * 4096 / 64 if ips is not None else None
        r.update(search_is_faults=isf, search_is_per_search=ips)
    else:
        lines = 0.0
    r["lines_per_search"] = lines
    return r


CAT_KEYS = ("msg_wait_ns", "owner_h_ns", "xport_ns", "owner_h_rounds", "last_revoke_ns", "last_wb_ns",
            "last_meta_ns", "acquire_flush_ns", "local_meta_ns", "pte_install_ns", "local_wait_ns")


def fault_classes(T):
    """[(class, prefix, F ns, n faults)]: read = I->S (is_*), write = I/S->M (sm_*) + write-protect upgrade
    (wpu_*). De Stijl build 8 sub-classes are built by ds8_classes()."""
    out = []
    if "is_faults" in T:
        out.append(("read", "read", T.get("is_fault_ns"), T.get("is_faults")))
    if "sm_faults" in T or "wpu_faults" in T:
        out.append(("write", "write", T.get("sm_fault_ns", 0.0) + T.get("wpu_fault_ns", 0.0),
                    T.get("sm_faults", 0.0) + T.get("wpu_faults", 0.0)))
    return out


DS8_LOCAL = ("msg_wait_ns", "acquire_flush_ns", "local_meta_ns", "local_wait_ns", "pte_install_ns")


def is_ds8(c, t):
    """De Stijl build 8 (workspaces/eval3/ds-breakdown DESIGN.md; review ds-breakdown-review H1): per-thread
    read_async_is_fault_ns or node srv_* keys present. Never falls into b13 (its *_last_* stay 0 on De Stijl)."""
    return c.system == "ds" and ("read_async_is_fault_ns" in t["T"] or
                                 any(k.startswith("sys.swmc.destijl.srv_") for k in t["sum"]))


D, I_ = "sys.swmc.destijl.", "sys.swmc.instr."
# owner request classes: (srv_* prefix, count key) preferred; fallback = instr serve_* (FETCH: sync + async + evict mixed)
OWN_SRV = {"fetch_sync": (D + "srv_fetch_sync_", "count"), "fetch_evict": (D + "srv_fetch_evict_", "count"),
           "inv": (D + "srv_inv_", "count")}
OWN_SERVE = {"fetch_sync": (I_ + "serve_fetch.", "reply_count"), "fetch_evict": (I_ + "serve_fetch.", "reply_count"),
             "inv": (I_ + "serve_invalidate.", "reply_count")}


def ds8_owner_src(t, c=None):
    """(owner_src, classes, per-node view used for the means): srv_* in stats-steps; else the lifetime's guest
    status pre/post delta (c.ds_status, valid only for one measurement step); else instr serve_* aggregates"""
    keys = set().union(*t["tg"].values()) if t["tg"] else set()
    if D + "srv_fetch_sync_count" in keys:
        return "srv", OWN_SRV, t["tg"]
    st = getattr(c, "ds_status", None)
    if st and set(st) == set(t["tg"]):
        return "status-delta", OWN_SRV, st
    if I_ + "serve_fetch.reply_count" in keys:
        return "serve-all-fetch", OWN_SERVE, t["tg"]
    return "none", None, t["tg"]


def other_means(tgv, me, prefix, cnt):
    """{revoke, wb, meta, h}: mean owner ns per request over the OTHER targets than `me` (sum ns / sum count);
    tgv = {target: {key: value}} (stats-steps node counters or the status delta)"""
    n = sum(d.get(prefix + cnt, 0.0) for k, d in tgv.items() if k != me)
    out = {}
    for x in ("revoke", "wb", "meta", "h"):
        s = sum(d.get(f"{prefix}{x}_ns", 0.0) for k, d in tgv.items() if k != me)
        if x == "meta" and not any(f"{prefix}meta_ns" in d for d in tgv.values()):
            # build-7 serve_* have no meta_ns: meta = pre_reply - revoke - wb (owner time to the completion CAS)
            pre = sum(d.get(f"{prefix}pre_reply_ns", 0.0) for k, d in tgv.items() if k != me)
            s = max(0.0, pre - out["revoke"] * n - out["wb"] * n) if n else 0.0
        out[x] = s / n if n else 0.0
    return out


STATUS_LINE = re.compile(r"^ds\.([a-z0-9_]+)=(-?\d+)\s*$")


def read_status(path):
    """{sys.swmc.destijl.<name>: int} from a p-destijl-guest.sh status dump ("ds.<name>=<int>" lines)"""
    out = {}
    with open(path) as f:
        for line in f:
            m = STATUS_LINE.match(line.strip())
            if m:
                out[D + m.group(1)] = float(m.group(2))
    return out


def ds_status_delta(c, n_measured):
    """(per-target srv_* deltas or None, note). Files: <block>/dsshm-<lifetime>/status-{pre,post}-vm<k>.txt
    (experiments/eval/h2n-block.sh ds_up / ds_down: pre after enable, before the server; post after the lifetime).
    The srv_* counters live in the built-in kernel (kernel/swmc/destijl.o) and persist across cxl_shm loads (reset
    only by a reset_counters write), so a post file alone is never used. Valid only when the lifetime has exactly one
    non-warm-up measurement step; the delta then also holds that lifetime's server preload and loadgen warm-up
    (owner means per request, not totals, are taken from it)."""
    d = c.part
    sdir = None
    while len(d) >= len(c.root):
        cand = os.path.join(d, f"dsshm-{c.life}")
        if os.path.isdir(cand):
            sdir = cand
            break
        d = os.path.dirname(d)
    if sdir is None:
        return None, ""
    pre = sorted(glob.glob(os.path.join(sdir, "status-pre-vm*.txt")))
    post = sorted(glob.glob(os.path.join(sdir, "status-post-vm*.txt")))
    if not post:
        return None, "status-delta: no status-post files"
    if not pre:
        return None, "status-delta: no status-pre (srv_* persist in the built-in kernel; post alone not usable)"
    if n_measured != 1:
        return None, f"status-delta not used: lifetime has {n_measured} measurement steps (needs exactly 1)"
    out = {}
    for p in post:
        k = re.search(r"-vm(\d+)\.txt$", p).group(1)
        q = os.path.join(sdir, f"status-pre-vm{k}.txt")
        if not os.path.isfile(q):
            return None, f"status-delta: status-pre-vm{k}.txt missing"
        a, b = read_status(q), read_status(p)
        if not any(x.startswith(D + "srv_") for x in b):
            return None, "status-delta: no ds.srv_* in the status files (build < 8)"
        out[k] = {x: b[x] - a.get(x, 0.0) for x in b if x.startswith(D + "srv_")}
        if any(v < 0 for v in out[k].values()):
            return None, f"status-delta: negative srv_* delta on vm{k} (counters reset during the lifetime)"
    return out, "status-delta used"


def ds8_owner(t, c=None):
    """owner phase totals (ns, summed over requester nodes) {"read": {revoke, wb, meta}, "write": {...}} plus the
    round counts. Per requester node i (target), from its node counters:
      sync FETCH rounds_i = fetch_sent - async_issued - eviction FETCHes  (FETCH-producing sync rounds only:
        MERGED_WAIT / WAIT_WRITE rounds send no FETCH; their wait stays in communication; review M1)
      eviction FETCHes_i = bpd_evict_m - evict_self_fetch (M victims owned elsewhere)
      read owner_i  = mean_{j != i}(srv_fetch_sync_x) x sync FETCH rounds_i
      write owner_i = mean_{j != i}(srv_inv_x) x inv_sent_i + mean_{j != i}(srv_fetch_evict_x) x eviction FETCHes_i
    (write msg_wait holds the eviction waits; at N > 2 srv_inv is the mean holder, not the slowest: review M2)."""
    src, cls, tgv = ds8_owner_src(t, c)
    tot = {"read": {"revoke": 0.0, "wb": 0.0, "meta": 0.0}, "write": {"revoke": 0.0, "wb": 0.0, "meta": 0.0},
           "src": src, "sync_fetch_rounds": 0.0, "evict_fetches": 0.0, "inv_sent": 0.0}
    if cls is None:
        return tot
    for me, d in t["tg"].items():
        ev = max(0.0, d.get(D + "bpd_evict_m", 0.0) - d.get(D + "evict_self_fetch", 0.0))
        sf = max(0.0, d.get(D + "fetch_sent", 0.0) - d.get(D + "async_issued", 0.0) - ev)
        inv = d.get(D + "inv_sent", 0.0)
        tot["sync_fetch_rounds"] += sf
        tot["evict_fetches"] += ev
        tot["inv_sent"] += inv
        ms, me_, mi = (other_means(tgv, me, *cls[k]) for k in ("fetch_sync", "fetch_evict", "inv"))
        for x in ("revoke", "wb", "meta"):
            tot["read"][x] += ms[x] * sf
            tot["write"][x] += mi[x] * inv + me_[x] * ev
    return tot


def ds8_classes(T):
    """[(class, {F, n, rounds key, msg_wait_ns, acquire_flush_ns, local_meta_ns, local_wait_ns, pte_install_ns},
    owner side)]: read_async = read_async_* (F = read_async_is_fault_ns); read_sync = class-less read - read_async
    (F = is_fault_ns - read_async_is_fault_ns, faults = is_faults - read_async_faults); read = both; write = all
    writes (always sync)."""
    g = lambda k: T.get(k) or 0.0  # noqa: E731
    asy = {"F": g("read_async_is_fault_ns"), "n": g("read_async_faults"), **{k: g(f"read_async_{k}") for k in DS8_LOCAL}}
    tot = {"F": g("is_fault_ns"), "n": g("is_faults"), **{k: g(f"read_{k}") for k in DS8_LOCAL}}
    syn = {k: tot[k] - asy[k] for k in tot}
    wr = {"F": g("sm_fault_ns") + g("wpu_fault_ns"), "n": g("sm_faults") + g("wpu_faults"),
          **{k: g(f"write_{k}") for k in DS8_LOCAL}}
    return [("read", tot, "read"), ("read_sync", syn, "read"), ("read_async", asy, None), ("write", wr, "write")]


def breakdown_ds8(c, t):
    """De Stijl build 8: requester parts per thread, owner parts = per-node mean per request x requester rounds.
    1 = W - owner(revoke + wb + meta); 2 = owner revoke; 3 = owner wb + acquire flush; 4 = owner meta + local
    meta; 5 = F - (1..4) = pte install + local wait + residual. Async reads carry no owner work."""
    T = t["T"]
    own = ds8_owner(t, c)
    N = c.N or t["n"]
    rows = []
    for cls, v, side in ds8_classes(T):
        if side is None or own["src"] == "none":
            rev = wb = meta = 0.0
            src = "none (async: no owner work on the fault path)" if side is None else "none (no owner counters)"
        else:
            rev, wb, meta = (own[side][x] for x in ("revoke", "wb", "meta"))
            src = own["src"]
            if src not in ("srv", "status-delta") and c.ds_status_note:
                src += f" ({c.ds_status_note})"
        R = {"read": own["sync_fetch_rounds"], "write": own["inv_sent"] + own["evict_fetches"]}.get(side, 0.0)
        W, F = v["msg_wait_ns"], v["F"]
        c1 = W - rev - wb - meta
        c2, c3, c4 = rev, wb + v["acquire_flush_ns"], meta + v["local_meta_ns"]
        c5 = F - c1 - c2 - c3 - c4  # may be slightly negative (review L4: F counts transition reads only)
        mode = "ds8-meanholder" if side == "write" and N and N > 2 else "ds8"
        r = {"class": cls, "faults": v["n"], "F_ns": F, "W_ns": W, "cat1_comm_ns": c1, "cat2_unmap_tlb_ns": c2,
             "cat3_flush_ns": c3, "cat4_metadata_ns": c4, "cat5_others_ns": c5,
             "owner_revoke_ns": rev, "owner_wb_ns": wb, "owner_meta_ns": meta, "owner_rounds": R, "owner_src": src,
             "acquire_flush_ns": v["acquire_flush_ns"], "local_meta_ns": v["local_meta_ns"],
             "pte_install_ns": v["pte_install_ns"], "local_wait_ns": v["local_wait_ns"],
             "residual_ns": c5 - v["pte_install_ns"] - v["local_wait_ns"],
             "breakdown_faults": T.get("read_async_breakdown_faults") if cls == "read_async" else T.get("breakdown_faults"),
             "nontrans_faults": T.get("nontrans_faults"), "mode": mode}
        if cls.startswith("read"):
            r["async_served_faults"] = T.get("read_async_faults")
            r["sync_faults"] = sub(T.get("is_faults"), T.get("read_async_faults"))
        rows.append(r)
    return rows


def breakdown(c, t):
    """rows of the five categories (doc §3, P-popcorn-build13-fault-breakdown.md §2), sums over threads/targets,
    per fault in us. Category 1 = W - (revoke + wb + meta)_last (= xport + owner reply/rest), so 1..5 sum to F."""
    T = t["T"]
    S = t["sum"]
    if is_ds8(c, t):
        return breakdown_ds8(c, t)
    rows = []
    b13 = c.system != "ds" and any(k.endswith("last_revoke_ns") for k in T) and (T.get("breakdown_faults") or 0) > 0
    for cls, p, F, n in fault_classes(T):
        g = {k: T.get(f"{p}_{k}") for k in CAT_KEYS}
        W, H = g["msg_wait_ns"], g["owner_h_ns"]
        r = {"class": cls, "faults": n, "F_ns": F, "W_ns": W, "H_ns": H, "xport_ns": g["xport_ns"],
             "owner_h_rounds": g["owner_h_rounds"], "nontrans_faults": T.get("nontrans_faults"),
             "breakdown_faults": T.get("breakdown_faults")}
        if b13 and g["last_revoke_ns"] is not None:
            mode = "b13"
            rev, wb, meta = g["last_revoke_ns"] or 0.0, g["last_wb_ns"] or 0.0, g["last_meta_ns"] or 0.0
            acq, lmeta = g["acquire_flush_ns"] or 0.0, g["local_meta_ns"] or 0.0
            pte, lw = g["pte_install_ns"] or 0.0, g["local_wait_ns"] or 0.0
            c1 = sub(W, rev, wb, meta)
            c2, c3, c4 = rev, wb + acq, meta + lmeta
            c5 = sub(F, c1, c2, c3, c4) if F is not None and c1 is not None else None
            r.update(cat1_comm_ns=c1, cat2_unmap_tlb_ns=c2, cat3_flush_ns=c3, cat4_metadata_ns=c4, cat5_others_ns=c5,
                     comm_xport_ns=sub(W, H) if H is not None else None,
                     comm_owner_rest_ns=sub(H, rev, wb, meta) if H is not None else None,
                     last_revoke_ns=rev, last_wb_ns=wb, last_meta_ns=meta, acquire_flush_ns=acq, local_meta_ns=lmeta,
                     pte_install_ns=pte, local_wait_ns=lw, residual_ns=sub(c5, pte, lw) if c5 is not None else None)
        elif c.system == "ds":
            # De Stijl build 7: no owner phases in the ring ACK -> two parts: fetch wait (W) vs the rest
            mode = "ds7-2part"  # build-7 write W includes the CCD acquire work: never pool with ds8 rows (M3)
            r.update(fetch_wait_ns=W, rest_ns=sub(F, W) if F is not None and W is not None else None,
                     acquire_flush_ns=g["acquire_flush_ns"], pte_install_ns=g["pte_install_ns"],
                     local_wait_ns=g["local_wait_ns"])
        else:
            # build 12: owner time H not split; communication = W - H (xport)
            mode = "b12"
            r.update(cat1_comm_ns=sub(W, H) if W is not None and H is not None else None, owner_h_ns=H,
                     rest_ns=sub(F, W) if F is not None and W is not None else None,
                     acquire_flush_ns=g["acquire_flush_ns"], pte_install_ns=g["pte_install_ns"],
                     local_wait_ns=g["local_wait_ns"])
        if c.system == "ds" and cls == "read":
            ai = S.get("sys.swmc.destijl.async_installed")
            r.update(async_served_faults=ai, sync_faults=sub(n, ai) if ai is not None and n is not None else None)
        r["mode"] = mode
        rows.append(r)
    return rows


def rates(c, t):
    S, T, w = t["sum"], t["T"], t["win"]
    pr = lambda v: v / w if v is not None and w else None  # noqa: E731
    rd = T.get("is_faults")
    wr = (T.get("sm_faults", 0.0) + T.get("wpu_faults", 0.0)) if ("sm_faults" in T or "wpu_faults" in T) else None
    rep = [S.get(f"sys.swmc.instr.serve_{x}.reply_count") for x in ("fetch", "invalidate")]
    rounds = [S.get(f"sys.swmc.instr.tx_{x}.wait_count") for x in ("fetch", "invalidate")]
    pop_req = sum(v for v in rep if v is not None) if any(v is not None for v in rep) else None
    dsk = {x: S.get(f"sys.swmc.destijl.{x}") for x in ("fetch_sent", "inv_sent", "ack_sent")}
    ds_msgs = sum(v for v in dsk.values() if v is not None) if any(v is not None for v in dsk.values()) else None
    pop_msgs = 2 * pop_req if pop_req is not None else None
    coh = {"hw": 0.0, "pop": pop_msgs, "ds": ds_msgs}.get(c.system)
    return {"window_s": w, "read_faults_s": pr(rd), "write_faults_s": pr(wr), "nontrans_faults_s": pr(T.get("nontrans_faults")),
            "pop_rounds_s": pr(sum(v for v in rounds if v is not None) if any(v is not None for v in rounds) else None),
            "pop_requests_s": pr(pop_req), "pop_msgs_s": pr(pop_msgs),
            "ds_fetch_s": pr(dsk["fetch_sent"]), "ds_inv_s": pr(dsk["inv_sent"]), "ds_ack_s": pr(dsk["ack_sent"]),
            "ds_msgs_s": pr(ds_msgs), "coh_msgs_s": pr(coh), "searches_s": pr(S.get("searches"))}


OPT = re.compile(r"^opt\.([^.]+)\.ops$")


def search_rows(c, t):
    S = t["sum"]
    out = []
    for k in sorted(S):
        m = OPT.match(k)
        if not m:
            continue
        op = m.group(1)
        ops = S[k]
        g = lambda x: div(S.get(f"opt.{op}.{x}"), ops * 1e6) if ops else None  # noqa: E731 (ns -> ms per op)
        pop = {x: g(f"pop.{x}_ns") for x in ("is", "sm", "wp", "ipi", "nontrans")}
        tms = g("t_ns")
        pop_sum = sum(v for v in pop.values() if v is not None) if any(v is not None for v in pop.values()) else None
        out.append({"op": op, "ops": ops, "t_ms": tms, "wait_ms": g("wait_ns"), "c_ms": g("c_ns"),
                    **{f"pop_{x}_ms": v for x, v in pop.items()}, "pop_sum_ms": pop_sum,
                    "rest_ms": sub(tms, pop_sum) if tms is not None and pop_sum is not None else None})
    return out


def staleness(c, t):
    S, T, G = t["sum"], t["T"], t["gmax"]
    if not any(k.startswith("sys.swmc.destijl.") for k in S):
        return None
    d = lambda x: S.get(f"sys.swmc.destijl.{x}")  # noqa: E731
    rf = T.get("read_faults")
    n = (t["n"] or 1) * (t.get("k") or 1)  # gauge mean over targets (and pooled steps)
    return {"read_faults": rf, "async_issued": d("async_issued"), "async_installed": d("async_installed"),
            "async_completed": d("async_completed"), "async_superseded_write": d("async_superseded_write"),
            "async_superseded_inv": d("async_superseded_inv"),
            "async_fallback": sum(d(x) or 0.0 for x in ("async_fallback_mean", "async_fallback_p95",
                                                         "async_fallback_write", "async_fallback_nomem")),
            "ss_read_share": div(d("async_installed"), rf),
            "ss_residence_p95_us_max": G.get("sys.swmc.destijl.p95_us"),
            "ss_residence_p95_us_mean": div(S.get("sys.swmc.destijl.p95_us"), n),
            "ss_residence_max_us": G.get("sys.swmc.destijl.ss_residence_max_us"),
            "lambda_per_s_mean": div(S.get("sys.swmc.destijl.lambda_per_s"), n),
            "tx_timeout": d("tx_timeout"), "protocol_error": d("protocol_error")}


# ----------------------------------------------------------------------------------------------- output
ID = ["run", "workload", "system", "mix", "N", "lifetime", "part"]
COLS = {
    "cells.csv": ID + ["slo_stream", "slo_pct", "slo_ms", "n_steps", "stats_steps", "l1_steps", "l1_src", "l1_rate",
                       "max_steps", "max_src", "pmax_steps", "pmax_rate", "source_dir"],
    "fig-latency-vs-rps.csv": ID + ["step", "phase", "sel", "measure_s", "offered_total", "achieved_total",
                                    "slo_offered", "slo_achieved", "slo_p50_ms", "slo_p95_ms", "slo_p99_ms",
                                    "slo_pslo_ms", "slo_pct", "slo_ms", "within_slo", "pass", "aborted",
                                    "other_stream", "other_achieved", "other_p99_ms"],
    "fig-max-under-slo.csv": ID + ["max_slo_stream_s", "max_offered_total", "max_src", "confirmed", "floor",
                                   "floor_rate", "floor_slo_pslo_ms", "max_steps", "note"],
    "fig-flushed-lines-l1.csv": ID + ["step", "l1_src", "l1_rate", "offered_total", "lines_per_search", "srv_searches",
                                      "search_is_faults", "search_is_per_search", "mg_search_events",
                                      "mg_events_per_search", "mg_rflush_bytes", "mg_rflushes",
                                      "mg_rflush_bytes_per_flush", "window_s"],
    "fig-fault-breakdown.csv": ID + ["step", "sel", "offered_total", "class", "mode", "faults",
                                     "F_us", "cat1_comm_us", "cat2_unmap_tlb_us", "cat3_flush_us", "cat4_metadata_us",
                                     "cat5_others_us", "norm_F_to_pop", "W_us", "H_us", "xport_us", "comm_xport_us",
                                     "comm_owner_rest_us", "last_revoke_us", "last_wb_us", "last_meta_us",
                                     "acquire_flush_us", "local_meta_us", "pte_install_us", "local_wait_us",
                                     "residual_us", "owner_h_us", "fetch_wait_us", "rest_us", "async_served_faults",
                                     "sync_faults", "owner_h_rounds", "nontrans_faults", "breakdown_faults",
                                     "sum_check_us", "owner_src", "owner_rounds", "owner_revoke_us", "owner_wb_us",
                                     "owner_meta_us", "instr_build"],
    "fig-coherence-rates.csv": ID + ["step", "sel", "offered_total", "window_s", "read_faults_s", "write_faults_s",
                                     "nontrans_faults_s", "coh_msgs_s", "pop_rounds_s", "pop_requests_s", "pop_msgs_s",
                                     "ds_fetch_s", "ds_inv_s", "ds_ack_s", "ds_msgs_s", "searches_s"],
    "fig-search-breakdown.csv": ID + ["step", "sel", "offered_total", "op", "ops", "t_ms", "wait_ms", "c_ms",
                                      "pop_is_ms", "pop_sm_ms", "pop_wp_ms", "pop_ipi_ms", "pop_nontrans_ms",
                                      "pop_sum_ms", "rest_ms"],
    "fig-ds-staleness.csv": ID + ["step", "sel", "offered_total", "read_faults", "async_issued", "async_installed",
                                  "async_completed", "async_superseded_write", "async_superseded_inv",
                                  "async_fallback", "ss_read_share", "ss_residence_p95_us_max",
                                  "ss_residence_p95_us_mean", "ss_residence_max_us", "lambda_per_s_mean",
                                  "tx_timeout", "protocol_error"],
}


def fmt(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, float):
        return f"{v:.6f}"
    return v


def write(out_dir, name, rows):
    with open(os.path.join(out_dir, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS[name], extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(r.get(k)) for k in COLS[name]})


def ident(c):
    return {"run": os.path.basename(c.root), "workload": c.workload, "system": c.system, "mix": c.mix, "N": c.N, "lifetime": c.life, "part": c.subpart}


def sel_of(c, n):
    s = []
    if n in c.l1:
        s.append("L1")
    if n in c.mx:
        s.append("MAX" if c.mx_src != "floor" else "FLOOR")
    if n in c.pm:
        s.append("PMAX")
    return ";".join(s)


def step_sets(c):
    """[(step label, [steps], sel)] per measured step with stats, plus pooled L1 / MAX rows"""
    out = [(n, [n], sel_of(c, n)) for n in sorted(c.steps) if n in c.stats]
    if c.l1 and all(n in c.stats for n in c.l1):
        out.append(("L1", c.l1, "L1"))
    if c.mx and all(n in c.stats for n in c.mx):
        out.append(("MAX" if c.mx_src != "floor" else "FLOOR", c.mx, "MAX" if c.mx_src != "floor" else "FLOOR"))
    if c.pm and all(n in c.stats for n in c.pm):
        out.append(("PMAX", c.pm, "PMAX"))
    return out


def us(v):
    return v / 1e3 if v is not None else None


def extract(roots, out_dir, systems, override):
    cells = []
    for root, part in find_parts(roots):
        ci = cell_of(root, part)
        if not ci or ci[0] not in systems:
            continue
        c = Cell(root, part, *ci)
        if not c.steps:
            warn(f"{part}: no measured steps")
            continue
        cells.append(c)
    if not cells:
        sys.exit("eval3_extract: no parts found")
    choose_l1(cells, override)
    nmeas = {}
    for c in cells:
        k = (c.root, c.life)
        nmeas[k] = nmeas.get(k, 0) + sum(1 for s in c.steps.values() if s["phase"] not in ("warmup", "warm-up"))
    for c in cells:
        if c.system == "ds":
            c.ds_status, c.ds_status_note = ds_status_delta(c, nmeas[(c.root, c.life)])
    os.makedirs(out_dir, exist_ok=True)
    R = {k: [] for k in COLS}
    for c in cells:
        I = ident(c)
        R["cells.csv"].append({**I, "slo_stream": c.slo_stream, "slo_pct": c.slo_pct, "slo_ms": c.slo_ms,
                               "n_steps": len(c.steps), "stats_steps": len(c.stats),
                               "l1_steps": " ".join(map(str, c.l1)), "l1_src": c.l1_src, "l1_rate": c.l1_rate,
                               "max_steps": " ".join(map(str, c.mx)), "max_src": c.mx_src,
                               "pmax_steps": " ".join(map(str, c.pm)), "pmax_rate": c.pm_rate, "source_dir": c.part})
        others = [s for s in sorted({k for st in c.steps.values() for k in st["streams"]}) if s != c.slo_stream]
        for n in sorted(c.steps):
            s = c.steps[n]
            r = c.slo_row(n)
            o = s["streams"].get(others[0], {}) if others else {}
            R["fig-latency-vs-rps.csv"].append({
                **I, "step": n, "phase": s["phase"], "sel": sel_of(c, n), "measure_s": s["measure_s"],
                "offered_total": s["offered_x"],
                "achieved_total": sum(fl(v.get("achieved")) or 0.0 for v in s["streams"].values()),
                "slo_offered": fl(r.get("offered")), "slo_achieved": fl(r.get("achieved")),
                "slo_p50_ms": fl(r.get("p50_ms")), "slo_p95_ms": fl(r.get("p95_ms")), "slo_p99_ms": fl(r.get("p99_ms")),
                "slo_pslo_ms": fl(r.get("pslo_ms")), "slo_pct": c.slo_pct, "slo_ms": c.slo_ms,
                "within_slo": c.step_ok(n), "pass": s["pass"], "aborted": s["aborted"],
                "other_stream": others[0] if others else "", "other_achieved": fl(o.get("achieved")),
                "other_p99_ms": fl(o.get("p99_ms"))})
        if any(s["phase"] not in FIXED_PHASES for s in c.steps.values()):
            ms, mt, src = c.max_rate()
            fl_ = c.mx_src == "floor"
            fr = c.steps[c.mx[0]] if fl_ else None
            R["fig-max-under-slo.csv"].append({
                **I, "max_slo_stream_s": ms, "max_offered_total": mt, "max_src": src,
                "confirmed": c.h2n.get("confirmed", ""), "floor": fl_,
                "floor_rate": fr["offered_x"] if fr else None,
                "floor_slo_pslo_ms": fl(c.slo_row(c.mx[0]).get("pslo_ms")) if fr else None,
                "max_steps": " ".join(map(str, c.mx)), "note": c.h2n.get("note", "")})
        if c.workload == "vectordb" and c.l1 and all(n in c.stats for n in c.l1):
            t = pool(c.stats, c.l1)
            R["fig-flushed-lines-l1.csv"].append({**I, "step": " ".join(map(str, c.l1)), "l1_src": c.l1_src,
                                                  "l1_rate": c.l1_rate, "offered_total": c.steps[c.l1[0]]["offered_x"],
                                                  "window_s": t["win"], **flushed_lines(c, t)})
        for lab, ns, sel in step_sets(c):
            t = pool(c.stats, ns)
            base = {**I, "step": lab, "sel": sel, "offered_total": c.steps[ns[0]]["offered_x"]}
            if c.system in ("pop", "ds"):
                for b in breakdown(c, t):
                    n_f = b["faults"]
                    pf = lambda k: us(div(b.get(k), n_f))  # noqa: E731 (us per fault)
                    row = {**base, "class": b["class"], "mode": b["mode"], "faults": n_f,
                           "async_served_faults": b.get("async_served_faults"), "sync_faults": b.get("sync_faults"),
                           "owner_h_rounds": b.get("owner_h_rounds"), "nontrans_faults": b.get("nontrans_faults"),
                           "breakdown_faults": b.get("breakdown_faults"), "owner_src": b.get("owner_src"),
                           "owner_rounds": b.get("owner_rounds"), "instr_build": t["gmax"].get("sys.swmc.instr.build")}
                    for k in ("F", "W", "H", "xport", "comm_xport", "comm_owner_rest", "last_revoke", "last_wb",
                              "last_meta", "acquire_flush", "local_meta", "pte_install", "local_wait", "residual",
                              "owner_h", "fetch_wait", "rest", "owner_revoke", "owner_wb", "owner_meta"):
                        row[f"{k}_us"] = pf(f"{k}_ns")
                    for k in ("cat1_comm", "cat2_unmap_tlb", "cat3_flush", "cat4_metadata", "cat5_others"):
                        row[f"{k}_us"] = pf(f"{k}_ns")
                    cats = [row[f"{k}_us"] for k in ("cat1_comm", "cat2_unmap_tlb", "cat3_flush", "cat4_metadata",
                                                     "cat5_others")]
                    if all(v is not None for v in cats) and row["F_us"] is not None:
                        row["sum_check_us"] = sum(cats) - row["F_us"]
                    R["fig-fault-breakdown.csv"].append(row)
            R["fig-coherence-rates.csv"].append({**base, **rates(c, t)})
            for s in search_rows(c, t):
                R["fig-search-breakdown.csv"].append({**base, **s})
            if c.system == "ds":
                st = staleness(c, t)
                if st:
                    R["fig-ds-staleness.csv"].append({**base, **st})
    # normalization of F to Page SWcc (same workload, mix, N, class, step label L1 / MAX)
    popF = {(r["workload"], r["mix"], r["N"], r["class"], r["step"]): r["F_us"]
            for r in R["fig-fault-breakdown.csv"] if r["system"] == "pop" and r["step"] in ("L1", "MAX", "FLOOR")}
    for r in R["fig-fault-breakdown.csv"]:
        if r["step"] in ("L1", "MAX", "FLOOR"):
            base = popF.get((r["workload"], r["mix"], r["N"], r["class"].split("_")[0], r["step"]))
            r["norm_F_to_pop"] = div(r["F_us"], base)
    for name, rows in R.items():
        write(out_dir, name, rows)
    print(f"eval3_extract: {len(cells)} parts -> {out_dir} (" +
          ", ".join(f"{k} {len(v)}" for k, v in R.items()) + ")")
    return R


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--systems", default="hw,pop,mg,mgoff,ds")
    ap.add_argument("--l1", default="", help="L1 total offered rate per mix, e.g. u50=21.6,u10=108 (overrides auto)")
    a = ap.parse_args()
    override = {}
    for tok in filter(None, a.l1.split(",")):
        k, _, v = tok.partition("=")
        override[k] = float(v)
    extract(a.dirs, a.out, set(a.systems.split(",")), override)


if __name__ == "__main__":
    main()

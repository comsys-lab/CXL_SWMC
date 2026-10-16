"""MOT1 v6 analysis input layer (reports/MOT1-v6-redesign-draft.md): run loading, the per-operation column mapping
table, per-step per-operation sums over nodes, and the CSV writer that states formula and source columns.

Run spec on every v6_fig*.py command line: SYS=DIR[:STEPS]
  SYS    hw (all-HWcc) | pop (Popcorn) | mg (Megalon); decides the coherence formula (never the counter presence)
  DIR    a loadgen --out dir (steps.jsonl, summary.json, manifest.txt, stats/) or a harness run dir with loadgen/
  STEPS  optional comma list of measured step numbers to sum (default: every measured step of phase "fixed"; for
         Fig 1 all non-warmup steps are used and STEPS is ignored)

Per-operation inputs are the server's --stats-op text keys, differenced per measured step by
experiments/loadgen/stats_delta.py (begin/end snapshots of the step window) and summed over nodes (targets).
Two naming conventions have landed (2026-10-16); OPKEYS maps both to one canonical name per quantity:
  "opt" workloads/kv/server/opsplit.h (KV, LMDB):  opt.<op>.{ops,t_ns,c_ns}, opt.<op>.pop.<f>, opt.<op>.meg.<f>,
                                                    opt.meg_check_sample (process-wide)
  "op"  workloads/recsys/server/optime.h (DLRM):    op.<op>.{n,t_ns,c_ns}, op.<op>.pc.<f>, op.<op>.mg.<f>
  The vector DB exporter (A3) had not landed; it is expected to use one of the two (add a row here otherwise).
Node-wide Popcorn kernel counters (sys.swmc.*) are mapped in NODEKEYS; build-9 names are PROVISIONAL until
reports/P-popcorn-build9.md exists, build-8 names are the fallback and the CSVs name the key actually used.
"""
import csv, json, math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loadgen"))
import paper_style as ps  # noqa: E402
import stats_delta  # noqa: E402

SYSTEMS = {"hw": "All HWcc", "pop": "Popcorn", "mg": "Megalon"}  # display names = paper_style.SERIES keys
ORDER = ["pop", "mg", "hw"]  # legend order of paper_style (worst = lightest ... All HWcc = black)
PAGE = 4096

# CohSnap fields (systems/megalon/shim/megalon_objapi.h v2 thread_coh), check_sample handled separately
MEG_F = ["read_sections", "write_sections", "check_ns_sampled", "check_sampled", "stale_cnt", "stale_ns", "concur_cnt",
         "concur_ns", "meta_cnt", "meta_ns", "spin_cnt", "spin_ns", "wstart_ns", "switch_rw_cnt", "switch_rw_ns",
         "reclaim_cnt", "reclaim_ns", "wflush_cnt", "wflush_ns", "wflush_bytes"]
# swmc_acct (systems/popcorn_new/include/swmc_acct.h): canonical -> (opt name, op name)
POP_F = {"is_ns": ("is_ns", "fault_ns.is"), "sm_ns": ("sm_ns", "fault_ns.sm"), "wp_ns": ("wp_ns", "fault_ns.wp"),
         "is_cnt": ("is_cnt", "fault_cnt.is"), "sm_cnt": ("sm_cnt", "fault_cnt.sm"), "wp_cnt": ("wp_cnt", "fault_cnt.wp"),
         "ipi_ns": ("ipi_ns", "ipi_ns"), "ipi_cnt": ("ipi_cnt", "ipi_cnt")}

# Canonical per-operation quantity -> stats keys tried in order ({op} = operation name). Mapping table (task A6).
OPKEYS = {
    "ops": ["opt.{op}.ops", "op.{op}.n", "op.{op}.ops"],          # N_o [count, measured]
    "t_ns": ["opt.{op}.t_ns", "op.{op}.t_ns"],                    # sum over ops and threads of (end - start) [rdtsc]
    "c_ns_exported": ["opt.{op}.c_ns", "op.{op}.c_ns"],           # the workload's own C sum (audit column only)
    "meg_check_sample": ["op.{op}.mg.check_sample", "opt.meg_check_sample"],  # sampling factor N (gauge)
    # Fig 3b reference line: bytes the application stored in the update. NOT EXPORTED by any workload yet.
    "mod_bytes": ["opt.{op}.mod_bytes", "op.{op}.mod_bytes", "opt.{op}.app_bytes", "op.{op}.app_bytes"],
}
OPKEYS.update({"pop_" + k: [f"opt.{{op}}.pop.{a}", f"op.{{op}}.pc.{b}"] for k, (a, b) in POP_F.items()})
# managed faults that committed no transition: own component, NOT in C (coordinator, build 9; swmc_acct has no slot
# yet, so no workload exports it per operation today)
OPKEYS["pop_nontrans_ns"] = ["opt.{op}.pop.nontrans_ns", "op.{op}.pc.nontrans_ns", "op.{op}.pc.nontrans_fault_ns"]
OPKEYS["pop_nontrans_cnt"] = ["opt.{op}.pop.nontrans_cnt", "op.{op}.pc.nontrans_faults"]
OPKEYS.update({"meg_" + f: [f"opt.{{op}}.meg.{f}", f"op.{{op}}.mg.{f}"] for f in MEG_F})
OP_DISCOVER = [re.compile(r"^opt\.([^.]+)\.ops$"), re.compile(r"^op\.([^.]+)\.n$"), re.compile(r"^op\.([^.]+)\.ops$")]

# Popcorn kernel counters (Fig 3b contrast, Fig 4a): Popcorn build 9 names, FINAL (reports/P-popcorn-build9.md §1,
# §1.5). thr.*.swmc.<key> = per-thread /proc/<pid>/task/<tid>/swmc summed over every thread group the server reports
# (systems/common/proc_stats.h); sys.swmc.instr.<file>.<key> = node-wide /sys/kernel/swmc/instr/<file>.
NODEKEYS = {
    "pop_remote_wb": ["sys.swmc.page_coherence.remote_writeback_count"],  # pages written back for a peer [count]
    # requester (per thread, server process): I->S faults, read request rounds
    "is_f_sum_ns": ["thr.*.swmc.is_fault_ns"],             # F: exc_page_fault entry .. handler end, committed I->S
    "is_f_cnt": ["thr.*.swmc.is_faults"],
    "rd_w_sum_ns": ["thr.*.swmc.read_msg_wait_ns"],        # W, all read rounds
    "rd_rounds": ["thr.*.swmc.read_transactions"],
    "rd_h_sum_ns": ["thr.*.swmc.read_owner_h_ns"],         # H returned in the reply (owner clock)
    "rd_h_rounds": ["thr.*.swmc.read_owner_h_rounds"],
    "rd_xport_ns": ["thr.*.swmc.read_xport_ns"],           # sum of (W - H) over the rounds with H
    "nontrans_faults": ["thr.*.swmc.nontrans_faults"],     # managed faults without a transition (reported, not in C)
    "nontrans_fault_ns": ["thr.*.swmc.nontrans_fault_ns"],
    # owner (node-wide), FETCH requests served
    "own_revoke_ns": ["sys.swmc.instr.serve_fetch.revoke_ns"],  # mkclean/unmap incl. TLB-shootdown send + wait
    "own_wb_ns": ["sys.swmc.instr.serve_fetch.wb_ns"],          # write-back flush on M downgrade
    "own_reply_ns": ["sys.swmc.instr.serve_fetch.reply_ns"],
    "own_reply_cnt": ["sys.swmc.instr.serve_fetch.reply_count"],
    "own_ack": ["sys.swmc.instr.serve_fetch.ack"],
    "own_nack": ["sys.swmc.instr.serve_fetch.nack"],
}
FIG4A_B9 = ["is_f_sum_ns", "is_f_cnt", "rd_w_sum_ns", "rd_rounds", "rd_h_sum_ns", "rd_h_rounds", "rd_xport_ns",
            "own_revoke_ns", "own_wb_ns", "own_reply_ns", "own_reply_cnt", "own_ack", "own_nack"]
IS_F_HIST = ["sys.swmc.instr.fault_full_is"]  # build 9 <prefix>.lt_<2^k> buckets of F (p99 marker)
# Build-8 approximation (v6_fig4_popcorn.py --approx-build8 only; refused otherwise): F = all read faults, W = FETCH
# waits, owner timers over all served requests, H = the owners' own handling sums.
NODEKEYS_B8 = {
    "is_f_sum_ns": ["sys.swmc.instr.fault_read.sum_ns"], "is_f_cnt": ["sys.swmc.instr.fault_read.count"],
    "is_w_sum_ns": ["sys.swmc.instr.tx_fetch.wait_sum_ns"],
    "own_h_sum_ns": ["sys.swmc.instr.serve_fetch.handle_sum_ns"], "own_cnt": ["sys.swmc.instr.serve_fetch.handle_count"],
    "own_mkclean_ns": ["sys.swmc.instr.serve.mkclean_ns"], "own_wbflush_ns": ["sys.swmc.instr.serve.wb_flush_ns"],
}
IS_F_HIST_B8 = ["sys.swmc.instr.fault_read"]


def loadgen_dir(d):
    d = d.rstrip("/")
    if os.path.exists(os.path.join(d, "steps.jsonl")):
        return d
    if os.path.exists(os.path.join(d, "loadgen", "steps.jsonl")):
        return os.path.join(d, "loadgen")
    sys.exit(f"{d}: no steps.jsonl (loadgen --out dir or harness run dir with loadgen/)")


def parse_spec(spec, allowed=SYSTEMS):
    """'SYS=DIR[:STEPS]' -> (sys, dir, [steps] or None)."""
    key, sep, rest = spec.partition("=")
    if not sep or key not in allowed:
        sys.exit(f"bad run spec {spec!r}: expected SYS=DIR[:STEPS], SYS in {sorted(allowed)}")
    path, _, st = rest.partition(":")
    return key, path, [int(x) for x in st.split(",")] if st else None


class Run:
    def __init__(self, path, system):
        self.path = loadgen_dir(path)
        self.system = system
        self.steps = [json.loads(line) for line in open(os.path.join(self.path, "steps.jsonl"))]
        sp = os.path.join(self.path, "summary.json")
        self.summary = json.load(open(sp)) if os.path.exists(sp) else {}
        self.manifest = {}
        mp = os.path.join(self.path, "manifest.txt")
        if os.path.exists(mp):
            for line in open(mp):
                k, s, v = line.rstrip("\n").partition("=")
                if s and k not in self.manifest:
                    self.manifest[k] = v
        st, pct, ms = (self.manifest.get("slo", "") + "::").split(":")[:3]
        slo = self.summary.get("slo", {})
        self.slo_stream = st or slo.get("stream", "")
        self.slo_pct = float(pct) if pct else slo.get("pct")
        self.slo_ms = float(ms) if ms else slo.get("ms")
        self.harness_system = None
        hp = os.path.join(os.path.dirname(self.path), "manifest.txt")
        if os.path.exists(hp):
            for line in open(hp):
                if line.startswith("system="):
                    self.harness_system = line.strip().split("=", 1)[1]
        self._deltas = None

    def measured(self):
        return [s for s in self.steps if s["phase"] != "warmup" and s["measure_s"] > 0]

    def select(self, steps):
        if steps:
            have = {s["step"] for s in self.measured()}
            miss = [s for s in steps if s not in have]
            if miss:
                sys.exit(f"{self.path}: steps {miss} not measured")
            return steps
        fixed = [s["step"] for s in self.measured() if s["phase"] == "fixed"]
        if not fixed:
            sys.exit(f"{self.path}: no fixed-phase step; give :STEPS in the run spec")
        return fixed

    def deltas(self):
        """{step: [(target, delta dict)]} from the stats/ snapshot pairs."""
        if self._deltas is None:
            self._deltas = {}
            for fx, d in stats_delta.deltas(self.path):
                self._deltas.setdefault(fx["step"], []).append((fx["target"], d))
        return self._deltas

    def ops(self, steps):
        names = set()
        for st in steps:
            for _, d in self.deltas().get(st, []):
                for k in d:
                    for rx in OP_DISCOVER:
                        m = rx.match(k)
                        if m:
                            names.add(m.group(1))
        return sorted(names)


def first_key(d, cands, op=None):
    for c in cands:
        k = c.format(op=op) if op is not None else c
        if k in d:
            return k
    return None


def op_sums(run, steps, op):
    """Sum over the steps and nodes of every canonical per-op quantity plus the v6 derived sums (all in ns or counts):
      meg_check_est_ns = meg_check_ns_sampled x meg_read_sections / meg_check_sampled   (ratio estimator, per node,
                         then summed; READ-section checks only; contract CXL_SWMC 2015a31f3: preferred over
                         x check_sample because each thread's first section is always sampled) [sampled, estimated]
      C_pop  = pop_is_ns + pop_sm_ns + pop_wp_ns + pop_ipi_ns                                  (draft §3, §6.1)
      C_meg  = meg_check_est_ns + meg_stale_ns + meg_concur_ns + meg_meta_ns + meg_spin_ns + meg_wstart_ns
               + meg_wflush_ns    (switch_rw/reclaim are inside wstart: not added; draft §3.1, §4.1)
      C      = C_pop (pop) | C_meg (mg) | 0 (hw: no coherence actions; measured values kept in the audit columns)
    Returns (sums dict, keys used dict canonical -> stats key, nodes counted)."""
    out, used, nodes = {}, {}, 0
    for st in steps:
        rows = run.deltas().get(st, [])
        if not rows:
            sys.exit(f"{run.path}: step {st} has no begin/end stats snapshots (run with --stats-op)")
        for _, d in rows:
            nodes += 1
            vals = {}
            for c, cands in OPKEYS.items():
                k = first_key(d, cands, op)
                if k is not None:
                    vals[c] = d[k]
                    used.setdefault(c, k.replace(f".{op}.", ".<op>."))
            if vals.get("meg_check_ns_sampled") and not (vals.get("meg_check_sampled") and "meg_read_sections" in vals):
                # sampled check time without the sample count / section count: the estimate is unknown, not 0
                out["check_est_missing_nodes"] = out.get("check_est_missing_nodes", 0) + 1
                print(f"WARNING {run.path} step {st}: op {op} has meg_check_ns_sampled but no check_sampled/"
                      "read_sections; section-check estimate counted as 0 (column check_est_missing_nodes)",
                      file=sys.stderr)
                vals["meg_check_est_ns"] = 0
            else:
                vals["meg_check_est_ns"] = (vals.get("meg_check_ns_sampled", 0) * vals.get("meg_read_sections", 0)
                                            / vals["meg_check_sampled"] if vals.get("meg_check_sampled") else 0)
            for c, v in vals.items():
                if c != "meg_check_sample":
                    out[c] = out.get(c, 0) + v
            out["meg_check_sample"] = vals.get("meg_check_sample", out.get("meg_check_sample", 0))
    g = lambda k: out.get(k, 0)  # noqa: E731
    out["C_pop"] = g("pop_is_ns") + g("pop_sm_ns") + g("pop_wp_ns") + g("pop_ipi_ns")
    out["C_meg"] = (g("meg_check_est_ns") + g("meg_stale_ns") + g("meg_concur_ns") + g("meg_meta_ns") + g("meg_spin_ns")
                    + g("meg_wstart_ns") + g("meg_wflush_ns"))
    out.setdefault("check_est_missing_nodes", 0)
    out["C"] = {"pop": out["C_pop"], "mg": out["C_meg"], "hw": 0}[run.system]
    if "ops" not in out or "t_ns" not in out:
        sys.exit(f"{run.path}: operation {op!r} has no count/time keys in steps {steps} (OPKEYS)")
    return out, used, nodes


def node_sums(run, steps, names, table=None):
    """Sum over steps and nodes of NODEKEYS (or table) quantities; a '*' in a key sums every matching key (thread
    groups). (sums, keys used)."""
    table = table or NODEKEYS
    out, used = {}, {}
    for st in steps:
        for _, d in run.deltas().get(st, []):
            for c in names:
                for cand in table[c]:
                    if "*" in cand:
                        rx = re.compile("^" + re.escape(cand).replace(r"\*", "[^.]+") + "$")
                        ks = [k for k in d if rx.match(k)]
                        if ks:
                            out[c] = out.get(c, 0) + sum(d[k] for k in ks)
                            used.setdefault(c, cand)
                            break
                    elif cand in d:
                        out[c] = out.get(c, 0) + d[cand]
                        used.setdefault(c, cand)
                        break
    return out, used


def hist_pct(run, steps, prefixes, pct):
    """Percentile of a power-of-two histogram (<prefix>.lt_<b> bucket counts, summed over steps and nodes): the upper
    bound b of the bucket holding the pct-th sample (resolution x2). (value ns or None, prefix used)."""
    for pre in prefixes:
        b = {}
        for st in steps:
            for _, d in run.deltas().get(st, []):
                for k, v in d.items():
                    if k.startswith(pre + ".lt_"):
                        ub = int(k.rsplit("_", 1)[1])
                        b[ub] = b.get(ub, 0) + v
        n = sum(b.values())
        if n:
            rank, acc = math.ceil(pct / 100 * n), 0
            for ub in sorted(b):
                acc += b[ub]
                if acc >= rank:
                    return ub, pre
    return None, None


def div(a, b):
    return a / b if b else None


def r(v, nd=4):
    return "" if v is None else round(v, nd)


def write_csv(path, meta, header, rows):
    """meta: ordered (key, text) pairs written as '# key: text' lines before the header (formula, source columns,
    column tags measured / sampled x N / derived, inputs)."""
    with open(path, "w", newline="") as f:
        for k, v in meta:
            f.write(f"# {k}: {v}\n")
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def inputs_line(runs):
    return "; ".join(f"{label}: {run.system} {run.path}" + (f" (harness system={run.harness_system})"
                                                              if run.harness_system else "") for label, run in runs)


def nice_ticks(vmax, n=5):
    """0 .. a round top >= vmax with about n intervals."""
    if vmax <= 0:
        return [0, 1]
    raw = vmax / n
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    k = math.ceil(vmax / step - 1e-9)
    return [round(i * step, 10) for i in range(k + 1)]


def stacked(path, groups, components, ylabel, hatch_from=None, ref=None, logy=False, xlabel=None, title=None):
    """Grouped stacked bars in paper_style (grayscale, thick black edges, font sizes of paper_style.breakdown).
    groups: [(group label, [(bar label, [values per component, legend order top -> bottom])])]; None values = no bar.
    components: legend names top -> bottom (gray levels of paper_style.STACK); hatch_from: component indices >= this
    are hatched (a second family in the same figure). ref: optional {(group, bar): y} drawn as a black dash marker
    with legend ref[None]."""
    from matplotlib.patches import Patch
    from matplotlib.lines import Line2D
    plt = ps.plt
    n = len(components)
    if n == 1:
        cols = ["#7f7f7f"]
    elif n <= 5:
        cols = ps.STACK[-n:]
    else:  # more components than paper_style gray levels: evenly spaced grays, white -> black
        cols = ["#%02x%02x%02x" % ((round(255 * (1 - i / (n - 1))),) * 3) for i in range(n)]
    import matplotlib.patheffects as pe
    halo = [pe.Stroke(linewidth=7, foreground="white"), pe.Normal()]  # reference marker visible on dark bars
    nb = sum(len(b) for _, b in groups)
    aw = 1.1 * nb + 0.4 * len(groups)
    fig = plt.figure(figsize=(1.3 + aw + 5.2, 5.0))
    ax = fig.add_axes([1.3 / (6.5 + aw), 0.18, aw / (6.5 + aw), 0.77])
    ax.yaxis.grid(True, color="#d9d9d9", linewidth=1.0)
    ax.set_axisbelow(True)
    x, ticks, labels, gcent, top = 0.0, [], [], [], 0.0
    for g, bars in groups:
        x0 = x
        for name, vals in bars:
            if vals is not None:
                b = 0.0
                for j in range(n - 1, -1, -1):
                    v = vals[j] or 0.0
                    if v > 0:
                        ax.bar(x, v, 0.8, bottom=b, color=cols[j], edgecolor="black", linewidth=2.5,
                               hatch="//" if hatch_from is not None and j >= hatch_from else None, log=logy)
                    b += v
                top = max(top, b)
                if ref and ref.get((g, name)) is not None:
                    ax.plot([x - 0.45, x + 0.45], [ref[(g, name)]] * 2, color="black", linewidth=4, path_effects=halo)
                    top = max(top, ref[(g, name)])
            ticks.append(x)
            labels.append(name)
            x += 1.0
        gcent.append(((x0 + x - 1) / 2, g))
        x += 0.4
    ax.set_xticks(ticks)
    ax.set_xticklabels(labels, fontsize=16)
    ax.set_xlim(-0.6, x - 0.8)
    if logy:
        ax.set_yscale("log")
    else:
        t = nice_ticks(top or 1)
        ax.set_ylim(0, t[-1])
        ax.set_yticks(t)
        ax.set_yticklabels(["%g" % v for v in t])
    for cx, g in gcent:
        ax.text(cx, -0.16, g, transform=ax.get_xaxis_transform(), ha="center", va="top", fontsize=18)
    if xlabel:
        ax.text(0.5, -0.3, xlabel, transform=ax.transAxes, ha="center", va="top", fontsize=20)
    ax.tick_params(axis="y", labelsize=18)
    ax.set_ylabel(ylabel, fontsize=20, linespacing=0.95)
    handles = [Patch(facecolor=c, edgecolor="black", linewidth=2,
                     hatch="//" if hatch_from is not None and j >= hatch_from else None) for j, c in enumerate(cols)]
    names = list(components)
    if ref and ref.get(None):
        handles.append(Line2D([0], [0], color="black", linewidth=4))
        names.append(ref[None])
    ax.legend(handles, names, loc="center left", bbox_to_anchor=(1.02, 0.5), fontsize=16, handlelength=0.9,
              handleheight=0.9, labelspacing=0.6)
    if title:
        ax.set_title(title, fontsize=16)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    ps.plt.close(fig)

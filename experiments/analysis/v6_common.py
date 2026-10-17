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
         "reclaim_cnt", "reclaim_ns", "wflush_cnt", "wflush_ns", "wflush_bytes",
         # MOT1 v6 §3.1 (user 2026-10-16): validation copy (vector DB, LMDB export it; KV/DLRM have none = 0 by
         # definition); index lookup (Megalon build 74 CohSnap.reserved[7], sampled with the checks, reported BESIDE
         # check_ns_sampled, which excludes it since build 74; used only as the read-lookup fallback before build 75)
         "vcopy_ns_sampled", "vcopy_sampled", "vcopy_cnt", "lookup_ns_sampled"]
# Megalon build 75 shim API v3 thread_anchor (AnchorSnap), exported as opt.<op>.meg.anchor.<f> / op.<op>.mg.anchor.<f>:
# *_sampled fields are sampled with the read-section checks (ratio estimator), the others are timed every time
# (systems/megalon/shim/megalon_objapi.h v3, CXL_SWMC 28749aee6; wseq_end_ns = WSeqEnd, inside wflush)
ANCHOR_F = ["read_sections", "write_sections", "check_sampled", "read_lookup_ns_sampled", "read_nr_ns_sampled",
            "rseq_ns_sampled", "write_lookup_ns", "write_nr_ns", "wseq_ns", "wseq_end_ns",
            # Megalon >= 76: timed write sections (AnchorSnap.reserved[0]; vector DB, KV/LMDB, recsys export it as
            # <op>.meg.anchor.write_sampled / <op>.mg.anchor.write_sampled; absent before = no lean scaling)
            "write_sampled"]
# Megalon >= 76 lean sampling (reports/M2-megalon-port-changes.md §18): every Megalon duration is a sum over TIMED
# sections only (counts stay exact). Flags = CohSnap.reserved[1] (bit 1 lean, bit 2 MEGALON_COH_EVENTS=always). They
# are gauges (stats_delta would difference them), so they are read from each node's END snapshot text, per workload:
#   vector DB opt.<op>.meg.flags (server.cc OpWin) | recsys op.<op>.mg.flags (optime.h) | KV/LMDB opt.meg_flags or
#   opt.meg_lean + opt.meg_events_always (opsplit.h, process-wide)
# Lean and not events_always: read-side events (stale/concur/meta/spin) x read_sections / check_sampled, write side
# (wstart, switch_rw, reclaim, wflush, anchor write_lookup / write_nr / wseq / wseq_end) x write_sections /
# write_sampled. events_always: events and write side are full sums (no scaling, as recsys optime.h). Checks, read
# anchor and vcopy keep their own estimators (unchanged). No probe correction (M2 §19; open question).
LEAN_EV = ["stale_ns", "concur_ns", "meta_ns", "spin_ns"]
LEAN_WR = ["wstart_ns", "switch_rw_ns", "reclaim_ns", "wflush_ns"]
LEAN_WR_ANCHOR = ["write_lookup_ns", "write_nr_ns", "wseq_ns", "wseq_end_ns"]
FLAG_KEYS = ["opt.{op}.meg.flags", "op.{op}.mg.flags", "opt.meg_flags"]
# Workload rule for Megalon C (user principle 2026-10-16: C = work the workload's own all-HWcc implementation does not
# do), keyed by the loadgen manifest workload= name:
#   hwcc_flavor  all-HWcc = Megalon hwcc flavor (same anchor + seqlock reads): anchor work NOT in C; the seqlock parts
#                all-HWcc also does are taken out: C_check = check_est - rseq_est, C_wstart = wstart - wseq,
#                C_wflush = wflush - wseq_end
#   plain        all-HWcc = a plain backend without Megalon: every Megalon call is C:
#                C_check = check_est + read anchor (lookup + NR) est, C_wstart = wstart + write anchor (lookup + NR)
MEG_RULE = {"kv": "hwcc_flavor", "vectordb": "plain", "lmdb": "plain", "recsys": "plain"}
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
    # Fig 3b reference line: bytes the application stored in the update (vector DB opt.update.mod_bytes, 03d2a5391)
    "mod_bytes": ["opt.{op}.mod_bytes", "op.{op}.mod_bytes", "opt.{op}.app_bytes", "op.{op}.app_bytes"],
}
OPKEYS.update({"pop_" + k: [f"opt.{{op}}.pop.{a}", f"op.{{op}}.pc.{b}"] for k, (a, b) in POP_F.items()})
# managed faults that committed no transition: own component, NOT in C (coordinator, build 9; swmc_acct has no slot
# yet, so no workload exports it per operation today)
OPKEYS["pop_nontrans_ns"] = ["opt.{op}.pop.nontrans_ns", "op.{op}.pc.nontrans_ns", "op.{op}.pc.nontrans_fault_ns"]
OPKEYS["pop_nontrans_cnt"] = ["opt.{op}.pop.nontrans_cnt", "op.{op}.pc.nontrans_faults"]
OPKEYS.update({"meg_" + f: [f"opt.{{op}}.meg.{f}", f"op.{{op}}.mg.{f}"] for f in MEG_F})
OPKEYS.update({"meg_anchor_" + f: [f"opt.{{op}}.meg.anchor.{f}", f"op.{{op}}.mg.anchor.{f}"] for f in ANCHOR_F})
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
        self.workload = self.manifest.get("workload", "")
        hp = os.path.join(os.path.dirname(self.path), "manifest.txt")
        trace = [v for k, v in self.manifest.items() if k in ("trace", "opt.trace")]
        if os.path.exists(hp):
            for line in open(hp):
                if line.startswith("system="):
                    self.harness_system = line.strip().split("=", 1)[1]
                trace += re.findall(r"(?:^|\s)trace=(\S+)", line)
        if any(t not in ("", "0") for t in trace):
            # trace runs (Fig 3c only) are perturbed by the trace buffers: never input of Fig 1/2/3a/3b/4
            sys.exit(f"{self.path}: trace run (manifest trace={','.join(trace)}): refused as figure input "
                     "(trace runs feed Fig 3c through classify_sharing.py only)")
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


def snapshot_text(run, step):
    """[(target, {key: raw string})] of the step's END snapshots (string keys such as opcoh.pop_source, which
    stats_delta drops)."""
    out = []
    d = os.path.join(run.path, "stats")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        m = re.match(r"^step(\d+)-end-t(\d+)\.txt$", name)
        if m and int(m.group(1)) == step:
            kv = {}
            for line in open(os.path.join(d, name)):
                k, sep, v = line.rstrip("\n").partition("=")
                if sep and not k.startswith("#"):
                    kv[k] = v.strip()
            out.append((int(m.group(2)), kv))
    return out


def coh_source(kv):
    """Coherence sources a node reports (per-op exporters): {'pop', 'mg'} subset.
      pop  vector DB opcoh.pop_source=swmc_acct | KV/LMDB opt.pop_threads > 0 | recsys op.coh_src pc_threads:N > 0
           (swmc_acct registered = build-9 per-thread area; swmc_file / fake / none are not accepted)
      mg   opt.meg_coh=1 (vector DB, KV/LMDB) | recsys op.coh_src mg_threads:N > 0 (shim v2 thread_coh live)"""
    src = set()
    num = lambda v: int(float(v)) if re.match(r"^-?[0-9.]+$", v or "") else 0  # noqa: E731
    cs = dict(p.split(":", 1) for p in kv.get("op.coh_src", "").split(",") if ":" in p)
    if kv.get("opcoh.pop_source") == "swmc_acct" or num(kv.get("opt.pop_threads")) > 0 or num(cs.get("pc_threads")) > 0:
        src.add("pop")
    if num(kv.get("opt.meg_coh")) == 1 or num(cs.get("mg_threads")) > 0:
        src.add("mg")
    return src


def lean_flags(kv, op):
    """(lean, events_always, key) of a node's end snapshot text for operation op (FLAG_KEYS, then opt.meg_lean /
    opt.meg_events_always); (False, False, None) when no key exists (Megalon <= 75, other systems)."""
    num = lambda v: int(float(v)) if re.match(r"^-?[0-9.]+$", v or "") else 0  # noqa: E731
    for c in FLAG_KEYS:
        k = c.format(op=op)
        if k in kv:
            f = num(kv[k])
            return bool(f & 2), bool(f & 4), c
    if "opt.meg_lean" in kv:
        return num(kv["opt.meg_lean"]) == 1, num(kv.get("opt.meg_events_always")) == 1, "opt.meg_lean"
    return False, False, None


POP_ACTIVITY = re.compile(r"^(opt\.[^.]+\.pop\.(is|sm|wp|ipi)_(ns|cnt)|op\.[^.]+\.pc\.(fault_ns|fault_cnt)\.(is|sm|wp)"
                          r"|op\.[^.]+\.pc\.ipi_(ns|cnt))$")


def pop_idle(kv):
    """True when a node's end snapshot has per-op Popcorn keys and all of them are 0 (cumulative: no Popcorn
    coherence activity in this server process)."""
    ks = [k for k in kv if POP_ACTIVITY.match(k)]
    return bool(ks) and all(re.match(r"^0+(\.0*)?$", kv[k] or "x") for k in ks)


def check_source(run, steps):
    """Refuse a pop/mg run unless every node of every step reports exactly the run's coherence source (no build-8
    file fallback, no fallback shim with C = 0, no mixed sources)."""
    if run.system == "hw":
        return
    for st in steps:
        snaps = snapshot_text(run, st)
        if not snaps:
            sys.exit(f"{run.path}: step {st} has no end snapshot")
        for t, kv in snaps:
            src = coh_source(kv)
            if run.system == "mg" and src == {"mg", "pop"} and pop_idle(kv):
                # Megalon on the common Popcorn kernel (build >= 12): swmc_acct is registered for every process but
                # no Popcorn coherence ever ran in it (every per-op Popcorn duration/count 0): Megalon only
                continue
            if src != {run.system}:
                sys.exit(f"{run.path}: step {st} node {t}: coherence source {sorted(src) or 'none'} "
                         f"(opcoh.pop_source={kv.get('opcoh.pop_source')}, opt.pop_threads={kv.get('opt.pop_threads')}, "
                         f"opt.meg_coh={kv.get('opt.meg_coh')}, op.coh_src={kv.get('op.coh_src')}); this {run.system} "
                         f"run needs exactly {{'{run.system}'}}: refused (no build-8 / fallback-shim / C = 0 data)")


def op_sums(run, steps, op):
    """Sum over the steps and nodes of every canonical per-op quantity plus the v6 derived sums (all in ns or counts):
      f = meg_read_sections / meg_check_sampled (ratio estimator, per node; READ-section checks only, 2015a31f3)
      meg_check_est_ns  = meg_check_ns_sampled x f   (build >= 74: excludes the index lookup and the NR anchor work)
      meg_anchor_rd_est_ns = (anchor.read_lookup_ns_sampled + anchor.read_nr_ns_sampled) x f   (build 74 without
                             AnchorSnap: lookup_ns_sampled x f, NR part missing)
      (anchor *_sampled fields scale with the AnchorSnap's own read_sections / check_sampled when exported, else f)
      meg_rseq_est_ns   = anchor.rseq_ns_sampled x f;  meg_anchor_wr_ns = anchor.write_lookup_ns + anchor.write_nr_ns;
      meg_wseq_ns       = anchor.wseq_ns;  meg_wseq_end_ns = anchor.wseq_end_ns (inside wflush)
      workload rule (MEG_RULE by the run's workload=):
        hwcc_flavor (KV)  meg_check_C_ns = meg_check_est_ns - meg_rseq_est_ns, meg_wstart_C_ns = wstart - wseq,
                          meg_wflush_C_ns = wflush - wseq_end
        plain (others)    meg_check_C_ns = meg_check_est_ns + meg_anchor_rd_est_ns, meg_wstart_C_ns = wstart + anchor_wr,
                          meg_wflush_C_ns = wflush
      a node without AnchorSnap fields (Megalon build < 75) counts in anchor_split_unavailable_nodes: KV C slightly
      high (seqlock parts not removed), others slightly low (anchor work not added)
      meg_vcopy_est_ns = meg_vcopy_ns_sampled x meg_vcopy_cnt / meg_vcopy_sampled   (validation copy, ratio estimator
                         per node; workloads without the keys (KV, DLRM) have no validation copy: 0 by definition;
                         vcopy_ns_sampled > 0 without vcopy_sampled/vcopy_cnt is marked: vcopy_est_missing_nodes)
      C_pop  = pop_is_ns + pop_sm_ns + pop_wp_ns + pop_ipi_ns                                  (draft §3, §6.1)
      C_meg  = meg_check_C_ns + meg_vcopy_est_ns + meg_stale_ns + meg_concur_ns + meg_meta_ns + meg_spin_ns
               + meg_wstart_C_ns + meg_wflush_C_ns    (switch_rw/reclaim are inside wstart: not added; draft §3.1, §4.1)
      C      = C_pop (pop) | C_meg (mg) | 0 (hw: no coherence actions; measured values kept in the audit columns)
      Megalon >= 76 lean sampling (node flags, lean_flags): BEFORE the terms above, per node, meg_{stale,concur,meta,
      spin}_ns x read_sections / check_sampled (not with events_always) and meg_{wstart,switch_rw,reclaim,wflush}_ns,
      anchor.{write_lookup,write_nr,wseq,wseq_end}_ns x write_sections / anchor.write_sampled (not with events_always);
      raw timed sums kept as <canonical>_timed; meg_lean_nodes / meg_events_always_nodes count the nodes;
      lean_est_missing_nodes counts nodes with timed durations but a zero denominator (estimate 0); a mg run whose
      nodes with sections disagree on (lean, events_always) is refused. Data without flag keys: unchanged.
    Refuses a pop/mg run whose nodes do not report exactly that coherence source (check_source).
    Returns (sums dict, keys used dict canonical -> stats key, nodes counted)."""
    check_source(run, steps)
    rule = MEG_RULE.get(run.workload)
    if run.system == "mg" and rule is None:
        sys.exit(f"{run.path}: workload {run.workload!r} has no Megalon C rule (MEG_RULE); refused")
    out, used, nodes = {}, {}, 0
    modes = set()  # (lean, events_always) of the nodes with Megalon sections (one mode per run, else refused)
    for st in steps:
        rows = run.deltas().get(st, [])
        if not rows:
            sys.exit(f"{run.path}: step {st} has no begin/end stats snapshots (run with --stats-op)")
        ends = dict(snapshot_text(run, st))
        for t, d in rows:
            nodes += 1
            vals = {}
            for c, cands in OPKEYS.items():
                k = first_key(d, cands, op)
                if k is not None:
                    vals[c] = d[k]
                    used.setdefault(c, k.replace(f".{op}.", ".<op>."))
            lean, always, fk = lean_flags(ends.get(t, {}), op)
            if fk is not None:
                used.setdefault("meg_flags", fk.replace(".{op}.", ".<op>."))
            if vals.get("meg_read_sections") or vals.get("meg_write_sections"):
                modes.add((lean, always))
            if lean:
                # Megalon >= 76: durations are timed-section sums; scale per side (LEAN_* comment). Raw sums are kept
                # as <canonical>_timed (audit).
                out["meg_lean_nodes"] = out.get("meg_lean_nodes", 0) + 1
                if always:
                    out["meg_events_always_nodes"] = out.get("meg_events_always_nodes", 0) + 1
                    ws = vals.get("meg_anchor_write_sampled")
                    if ws is not None and ws != vals.get("meg_write_sections", ws):
                        # events_always times every write section; a difference means the data is not what it claims
                        print(f"WARNING {run.path} step {st} node {t}: op {op} events_always but write_sampled={ws} != "
                              f"write_sections={vals.get('meg_write_sections')}; write side taken as full sums",
                              file=sys.stderr)
                else:
                    cs = vals.get("meg_check_sampled", 0)
                    fr = vals.get("meg_read_sections", 0) / cs if cs else 0
                    ws = vals.get("meg_anchor_write_sampled", 0)
                    wsec = vals.get("meg_write_sections", vals.get("meg_anchor_write_sections", 0))
                    fw = wsec / ws if ws else 0
                    ev = ["meg_" + k for k in LEAN_EV]
                    wr = ["meg_" + k for k in LEAN_WR] + ["meg_anchor_" + k for k in LEAN_WR_ANCHOR]
                    if (not cs and any(vals.get(k) for k in ev)) or (not ws and any(vals.get(k) for k in wr)):
                        # timed durations without their sample count: the estimate is unknown, not 0
                        out["lean_est_missing_nodes"] = out.get("lean_est_missing_nodes", 0) + 1
                        print(f"WARNING {run.path} step {st} node {t}: op {op} lean Megalon durations without "
                              f"check_sampled={cs} / write_sampled={ws}; those estimates counted as 0 (column "
                              "lean_est_missing_nodes)", file=sys.stderr)
                    for ks, fac in ((ev, fr), (wr, fw)):
                        for k in ks:
                            if k in vals:
                                vals[k + "_timed"] = vals[k]
                                vals[k] = vals[k] * fac
            if vals.get("meg_check_ns_sampled") and not (vals.get("meg_check_sampled") and "meg_read_sections" in vals):
                # sampled check time without the sample count / section count: the estimate is unknown, not 0
                out["check_est_missing_nodes"] = out.get("check_est_missing_nodes", 0) + 1
                print(f"WARNING {run.path} step {st}: op {op} has meg_check_ns_sampled but no check_sampled/"
                      "read_sections; section-check estimate counted as 0 (column check_est_missing_nodes)",
                      file=sys.stderr)
                vals["meg_check_est_ns"] = 0
            else:
                cs = vals.get("meg_check_sampled", 0)
                f = vals.get("meg_read_sections", 0) / cs if cs else 0
                vals["meg_check_est_ns"] = vals.get("meg_check_ns_sampled", 0) * f
            cs = vals.get("meg_check_sampled", 0)
            f = vals.get("meg_read_sections", 0) / cs if cs else 0
            av = lambda k: vals.get("meg_anchor_" + k, 0)  # noqa: E731
            has_anchor = any("meg_anchor_" + k in vals for k in ANCHOR_F)
            if av("check_sampled"):  # the AnchorSnap's own sample set
                f = av("read_sections") / av("check_sampled")
            rd_lookup = av("read_lookup_ns_sampled") if has_anchor else vals.get("meg_lookup_ns_sampled", 0)
            vals["meg_anchor_rd_est_ns"] = (rd_lookup + av("read_nr_ns_sampled")) * f
            vals["meg_rseq_est_ns"] = av("rseq_ns_sampled") * f
            vals["meg_anchor_wr_ns"] = av("write_lookup_ns") + av("write_nr_ns")
            vals["meg_wseq_ns"] = av("wseq_ns")
            vals["meg_wseq_end_ns"] = av("wseq_end_ns")
            if run.system == "mg" and not has_anchor and (vals.get("meg_read_sections") or vals.get("meg_write_sections")):
                out["anchor_split_unavailable_nodes"] = out.get("anchor_split_unavailable_nodes", 0) + 1
            if rule == "hwcc_flavor":
                vals["meg_check_C_ns"] = vals["meg_check_est_ns"] - vals["meg_rseq_est_ns"]
                vals["meg_wstart_C_ns"] = vals.get("meg_wstart_ns", 0) - vals["meg_wseq_ns"]
                vals["meg_wflush_C_ns"] = vals.get("meg_wflush_ns", 0) - vals["meg_wseq_end_ns"]
            else:
                vals["meg_check_C_ns"] = vals["meg_check_est_ns"] + vals["meg_anchor_rd_est_ns"]
                vals["meg_wstart_C_ns"] = vals.get("meg_wstart_ns", 0) + vals["meg_anchor_wr_ns"]
                vals["meg_wflush_C_ns"] = vals.get("meg_wflush_ns", 0)
            if vals.get("meg_vcopy_ns_sampled") and not (vals.get("meg_vcopy_sampled") and "meg_vcopy_cnt" in vals):
                out["vcopy_est_missing_nodes"] = out.get("vcopy_est_missing_nodes", 0) + 1
                print(f"WARNING {run.path} step {st}: op {op} has meg_vcopy_ns_sampled but no vcopy_sampled/vcopy_cnt;"
                      " validation-copy estimate counted as 0 (column vcopy_est_missing_nodes)", file=sys.stderr)
                vals["meg_vcopy_est_ns"] = 0
            else:
                vs = vals.get("meg_vcopy_sampled", 0)
                vals["meg_vcopy_est_ns"] = vals.get("meg_vcopy_ns_sampled", 0) * vals.get("meg_vcopy_cnt", 0) / vs if vs else 0
            for c, v in vals.items():
                if c != "meg_check_sample":
                    out[c] = out.get(c, 0) + v
            out["meg_check_sample"] = vals.get("meg_check_sample", out.get("meg_check_sample", 0))
    g = lambda k: out.get(k, 0)  # noqa: E731
    out["C_pop"] = g("pop_is_ns") + g("pop_sm_ns") + g("pop_wp_ns") + g("pop_ipi_ns")
    out["C_meg"] = (g("meg_check_C_ns") + g("meg_vcopy_est_ns") + g("meg_stale_ns") + g("meg_concur_ns")
                    + g("meg_meta_ns") + g("meg_spin_ns") + g("meg_wstart_C_ns") + g("meg_wflush_C_ns"))
    out["meg_rule"] = rule or ""
    if run.system == "mg" and len(modes) > 1:
        sys.exit(f"{run.path}: op {op} steps {steps}: nodes disagree on Megalon lean/events_always flags "
                 f"{sorted(modes)} (mixed builds or settings): refused")
    for k in ("check_est_missing_nodes", "vcopy_est_missing_nodes", "anchor_split_unavailable_nodes",
              "meg_lean_nodes", "meg_events_always_nodes", "lean_est_missing_nodes"):
        out.setdefault(k, 0)
    out["C"] = {"pop": out["C_pop"], "mg": out["C_meg"], "hw": 0}[run.system]
    if "ops" not in out or "t_ns" not in out:
        sys.exit(f"{run.path}: operation {op!r} has no count/time keys in steps {steps} (OPKEYS)")
    return out, used, nodes


# ---- Megalon C by the difference method (user decision 2026-10-17, state/TASKS.md "(a) 차분 방식으로 진행해") ----
# C_diff(W, mix, load, op) = T(Megalon, timers OFF) - T(all-HWcc), per operation type, same offered rate, mix and
# window. An UPPER BOUND (includes every other backend difference). C_diff < 0 is reported as is with a WARN (no
# clamp). The sampled-scaled Megalon terms of the timers-ON run only split C_diff (part_i = C_diff x sampled_i /
# sum sampled) and stay raw as diagnostics. Popcorn C stays from kernel counters; T(pop) - T(hw) is a cross-check.
# Timed sums that the Megalon timers produce (all 0 with MEGALON_COH_TIMERS=0); the vector DB validation copy is the
# workload's own timer and stays live, so it is not in this list.
MEG_TIMED = (["meg_check_ns_sampled", "meg_check_sampled", "meg_lookup_ns_sampled"] + ["meg_" + k for k in LEAN_EV + LEAN_WR]
             + ["meg_anchor_" + k for k in ("check_sampled", "read_lookup_ns_sampled", "read_nr_ns_sampled",
                                            "rseq_ns_sampled", "write_lookup_ns", "write_nr_ns", "wseq_ns",
                                            "wseq_end_ns", "write_sampled")])
# C_meg terms of op_sums (the split basis), CSV short names
MEG_PARTS = [("check", "meg_check_C_ns"), ("vcopy", "meg_vcopy_est_ns"), ("stale", "meg_stale_ns"),
             ("concur", "meg_concur_ns"), ("meta", "meg_meta_ns"), ("spin", "meg_spin_ns"),
             ("wstart", "meg_wstart_C_ns"), ("wflush", "meg_wflush_C_ns")]
RAW_FLAG_KEYS = ["op.{op}.mg.flags", "opt.meg_flags"]  # full CohSnap.reserved[1] words (bit 0 = timers on)


def check_timers_off(run, steps, ops):
    """Refuse unless run is a Megalon timers-off lifetime for these steps/ops: Megalon sections counted, every Megalon
    timed sum (MEG_TIMED) 0 on every node, and no raw flag word with bit 0 (timers on). Returns sections counted."""
    check_source(run, steps)
    sections = 0
    for st in steps:
        ends = dict(snapshot_text(run, st))
        for t, d in run.deltas().get(st, []):
            for op in ops:
                for c in ["meg_read_sections", "meg_write_sections"] + MEG_TIMED:
                    k = first_key(d, OPKEYS[c], op)
                    v = d.get(k, 0) if k else 0
                    if c in ("meg_read_sections", "meg_write_sections"):
                        sections += v
                    elif v:
                        sys.exit(f"{run.path}: step {st} node {t} op {op}: {k}={v} != 0: Megalon timers were ON; "
                                 "a timers-off lifetime (MEGALON_COH_TIMERS=0) is required for C_diff: refused")
                for c in RAW_FLAG_KEYS:
                    v = ends.get(t, {}).get(c.format(op=op))
                    if v is not None and re.match(r"^[0-9]+$", v) and int(v) & 1:
                        sys.exit(f"{run.path}: step {st} node {t}: {c.format(op=op)}={v} (bit 0 timers on): "
                                 "not a timers-off lifetime: refused")
    if not sections:
        sys.exit(f"{run.path}: steps {steps}: no Megalon sections counted: not a Megalon timers-off run: refused")
    return sections


def meg_diff(t_off, t_hw, s_on):
    """Per-operation C_diff and its split. t_off, t_hw: T per op (ns) of the Megalon timers-off and all-HWcc runs;
    s_on: op_sums of the Megalon timers-ON run (or None). Returns {C_diff, sampled_<p> (per op, raw diagnostics),
    sampled_sum, part_<p> = C_diff x sampled_<p> / sampled_sum (None when sampled_sum <= 0 or s_on is None),
    warn: list of WARN strings}."""
    out = {"C_diff": t_off - t_hw, "warn": []}
    if out["C_diff"] < 0:
        out["warn"].append(f"C_diff<0 ({out['C_diff']:.1f} ns): T(Megalon timers off) < T(all-HWcc); reported, not clamped")
    samp = {p: (s_on.get(k, 0) / s_on["ops"] if s_on and s_on.get("ops") else None) for p, k in MEG_PARTS}
    tot = sum(v for v in samp.values() if v is not None) if s_on and s_on.get("ops") else None
    out["sampled_sum"] = tot
    for p, _ in MEG_PARTS:
        out["sampled_" + p] = samp[p]
        out["part_" + p] = out["C_diff"] * samp[p] / tot if tot and tot > 0 else None
    if s_on and s_on.get("ops"):
        t_on = s_on["t_ns"] / s_on["ops"]
        if not tot or tot <= 0:
            out["warn"].append("sampled Megalon C <= 0 in the timers-on run (timing sanity check)")
        elif tot > t_on:
            out["warn"].append(f"sampled Megalon C {tot:.1f} > T {t_on:.1f} ns in the timers-on run (diagnostic only)")
    return out


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
    def grays(k, dark=0):  # k evenly spaced grays from white to the gray level `dark` (0 = black)
        return ["#%02x%02x%02x" % ((round(255 - (255 - dark) * i / max(k - 1, 1)),) * 3) for i in range(k)]
    if n == 1:
        cols = ["#7f7f7f"]
    elif hatch_from is not None:  # two families: plain grays, then hatched grays no darker than #595959 (hatch visible)
        cols = (ps.STACK[-hatch_from:] if hatch_from <= 5 else grays(hatch_from)) + grays(n - hatch_from, 0x59)
    elif n <= 5:
        cols = ps.STACK[-n:]
    else:  # more components than paper_style gray levels: evenly spaced grays, white -> black
        cols = grays(n)
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

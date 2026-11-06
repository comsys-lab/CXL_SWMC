#!/usr/bin/env python3
"""RecSys torn-row policy and torn-row reports (Host only; user decision 2026-11-07 "RecSys torn rows", option a).

A torn row is a serving lookup whose row checksum (--verify-rows) does not match its version (server counter
torn_rows). Policy:
  allowed  De Stijl lifetimes with staleness bound T > 0 AND replica_mode != off: per-page replicas refresh
           independently, so a 320 B row that straddles a 4 KiB page boundary can be read half old / half new. Torn
           rows are then a staleness metric (reported, never an invariant violation).
  zero     every other lifetime (All HWcc, Popcorn, Megalon, De Stijl T = 0, De Stijl replica_mode off): torn_rows
           delta = 0 stays an invariant (session.sh measure rc 4, session.sh stop rc 4, rs_check.py FAIL).
The policy token is "system=<s> T_us=<n> replica_mode=<m>" (main-block.sh passes it to session.sh start as TORN_POLICY
for De Stijl lifetimes; no token = zero). It is accepted only when it agrees with the lifetime's SYSTEM label
(DeStijl-<recv>-T<n>) and node environment (CXL_SYSTEM=ds CXL_DESTIJL_T_US=<n>).
Formulas: torn_frac = torn_rows / lookups (server counters torn_rows and lookups = serving lookups, train lookups
  excluded), summed over the nodes; per step from stats-steps.csv (end - begin snapshot deltas), per measurement from
  pre/post snapshots, per lifetime from the node logs' final counters.
usage:
  torn_rows.py allow --system <SYSTEM> --node-env <NODE_ENV> --policy <token>   rc 0 allowed, 1 zero, 2 inconsistent
  torn_rows.py window <measurement dir> --nodes <n> [--allow <token>]            invariants.txt + torn.txt;
                                                                                 rc 0 ok, 4 violated, 5 STATS MISSING
  torn_rows.py steps <measurement dir>                                           torn-steps.csv from stats-steps.csv
  torn_rows.py lifetime <session dir>                                            torn-lifetime.txt from node*.log
  torn_rows.py block <block dir>                                                 torn-rows.csv; rc 4 = torn rows in a
                                                                                 zero-policy lifetime
"""
import argparse
import csv
import glob
import os
import re
import sys

INV_KEYS = ("torn_rows", "misses", "update_misses", "bad_requests")
STEP_COLS = ["step", "phase", "offered_x", "torn_rows", "lookups", "torn_frac"]
BLOCK_COLS = ["lifetime", "policy", "measurement", "scope", "step", "phase", "torn_rows", "lookups", "torn_frac"]
TOK = re.compile(r"^system=(\w+) T_us=(\d+) replica_mode=(\w+)$")


def allowed(system, t_us, replica_mode):
    """the rule itself: De Stijl, T > 0, replica_mode on"""
    return system == "ds" and int(t_us) > 0 and replica_mode not in ("", "off", "-")


def check_policy(label, node_env, tok):
    """-> (rc, text): 0 allowed, 1 zero (invariant kept), 2 token inconsistent with the lifetime"""
    if not tok:
        return 1, "zero (no policy token)"
    m = TOK.match(tok.strip())
    if not m:
        return 2, f"bad policy token [{tok}] (want 'system=<s> T_us=<n> replica_mode=<m>')"
    s, t, rm = m.group(1), m.group(2), m.group(3)
    ds_label = label.startswith("DeStijl-")
    if (s == "ds") != ds_label:
        return 2, f"policy system={s} but SYSTEM={label}"
    if s == "ds":
        if not re.search(rf"-T{t}$", label):
            return 2, f"policy T_us={t} but SYSTEM={label}"
        envs = node_env.split()
        if f"ENV:CXL_DESTIJL_T_US={t}" not in envs or "ENV:CXL_SYSTEM=ds" not in envs:
            return 2, f"policy T_us={t} but NODE_ENV [{node_env}] lacks ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US={t}"
    if allowed(s, t, rm):
        return 0, f"allowed ({tok.strip()})"
    return 1, f"zero ({tok.strip()})"


def kv(path):
    d = {}
    for line in open(path):
        if "=" in line and not line.startswith("#"):
            k, v = line.rstrip("\n").split("=", 1)
            d[k] = v
    return d


def frac(t, n):
    return t / n if n else None


def fmt(v):
    return "" if v is None else f"{v:.6g}" if isinstance(v, float) else str(v)


def window(M, nodes, tok):
    pol_ok = bool(tok)   # the caller passes the token only when allow returned 0
    inv, lines, tt, tl, viol, nolk = [], [], 0, 0, False, False
    for k in range(nodes):
        a = os.path.join(M, f"pre-t{k}.txt")
        b = os.path.join(M, f"post-t{k}.txt")
        da = kv(a) if os.path.isfile(a) else {}
        db = kv(b) if os.path.isfile(b) else {}
        dl = {}
        for key in INV_KEYS + ("lookups",):
            for f, dd in ((a, da), (b, db)):
                if not re.fullmatch(r"-?\d+", dd.get(key, "")):
                    if key == "lookups":
                        nolk = True
                        break
                    print(f"STATS MISSING {key} in {f}")
                    return 5
            else:
                dl[key] = int(db[key]) - int(da[key])
        for key in INV_KEYS:
            d = dl[key]
            tag = " allowed" if key == "torn_rows" and d and pol_ok else ""
            inv.append(f"node{k} {key}_delta={d}{tag}")
            if d and not tag:
                viol = True
        lk = dl.get("lookups")
        tt += dl["torn_rows"]
        tl += lk or 0
        lines.append(f"node{k} torn_rows={dl['torn_rows']} lookups={fmt(lk)} torn_frac={fmt(frac(dl['torn_rows'], lk))}")
    with open(os.path.join(M, "invariants.txt"), "a") as f:
        f.write("\n".join(inv) + "\n")
    with open(os.path.join(M, "torn.txt"), "w") as f:
        f.write(f"# torn rows of measurement {os.path.basename(M)} (experiments/recsys/torn_rows.py window; server counter "
                "deltas post - pre; torn_frac = torn_rows / serving lookups)\n")
        f.write(f"policy={'allowed (' + tok + ')' if pol_ok else 'zero'}\n")
        f.write("\n".join(lines) + "\n")
        f.write(f"total torn_rows={tt} lookups={'' if nolk else tl} torn_frac={fmt(None if nolk else frac(tt, tl))}\n")
    print(f"TORN {'allowed' if pol_ok else 'zero'} torn_rows={tt} lookups={'' if nolk else tl} "
          f"torn_frac={fmt(None if nolk else frac(tt, tl))}" + (" INVARIANT VIOLATED" if viol else ""))
    return 4 if viol else 0


def step_rows(M):
    """per step of stats-steps.csv, summed over the targets: [dict(step, phase, offered_x, torn_rows, lookups, torn_frac)]"""
    p = os.path.join(M, "stats-steps.csv")
    if not os.path.isfile(p):
        return []
    acc = {}
    for r in csv.DictReader(open(p)):
        k = int(r["step"])
        a = acc.setdefault(k, dict(step=k, phase=r.get("phase", ""), offered_x=r.get("offered_x", ""), torn_rows=0, lookups=0))
        a["torn_rows"] += int(r.get("torn_rows") or 0)
        a["lookups"] += int(r.get("lookups") or 0)
    out = [acc[k] for k in sorted(acc)]
    for a in out:
        a["torn_frac"] = frac(a["torn_rows"], a["lookups"])
    return out


def part_torn(M):
    """measured steps (phase != warmup) of one measurement dir -> (torn_rows, lookups, torn_frac); (None,)*3 without data"""
    rs = [r for r in step_rows(M) if r["phase"] != "warmup"]
    if not rs:
        return None, None, None
    t, n = sum(r["torn_rows"] for r in rs), sum(r["lookups"] for r in rs)
    return t, n, frac(t, n)


def steps(M):
    rs = step_rows(M)
    with open(os.path.join(M, "torn-steps.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(STEP_COLS)
        for r in rs:
            w.writerow([fmt(r[c]) for c in STEP_COLS])
    return 0


def session_policy(S):
    p = os.path.join(S, "session.env")
    m = re.search(r"^TORN_ALLOW_S='(.*)'$", open(p).read(), re.M) if os.path.isfile(p) else None
    return m.group(1) if m else ""


def final_counters(log):
    """last 'recsys-server: stopping' block of a node log -> {key: int}"""
    if not os.path.isfile(log):
        return None
    txt = open(log, errors="replace").read()
    i = txt.rfind("recsys-server: stopping")
    if i < 0:
        return None
    d = {}
    for line in txt[i:].splitlines()[1:]:
        m = re.match(r"^(\w+)=(-?\d+)$", line)
        if m and m.group(1) not in d:
            d[m.group(1)] = int(m.group(2))
    return d


def lifetime_torn(S):
    """-> (torn_rows, lookups, torn_frac) over all node logs of a stopped lifetime; None without clean-stop logs"""
    logs = sorted(glob.glob(os.path.join(S, "node[0-9]*.log")))
    cs = [final_counters(x) for x in logs]
    if not cs or any(c is None or "torn_rows" not in c for c in cs):
        return None
    t = sum(c["torn_rows"] for c in cs)
    n = sum(c.get("lookups", 0) for c in cs)
    return t, n, frac(t, n)


def lifetime(S):
    tok = session_policy(S)
    lt = lifetime_torn(S)
    with open(os.path.join(S, "torn-lifetime.txt"), "w") as f:
        f.write("# torn rows over the server lifetime (experiments/recsys/torn_rows.py lifetime; node logs' final counters, "
                "summed over the nodes; torn_frac = torn_rows / serving lookups)\n")
        f.write(f"policy={'allowed (' + tok + ')' if tok else 'zero'}\n")
        f.write("total " + (f"torn_rows={lt[0]} lookups={lt[1]} torn_frac={fmt(lt[2])}" if lt else "unavailable (no clean stop)") + "\n")
    print(f"TORN LIFETIME {os.path.basename(S)} {'allowed' if tok else 'zero'} "
          + (f"torn_rows={lt[0]} lookups={lt[1]} torn_frac={fmt(lt[2])}" if lt else "unavailable"))
    return 4 if lt and lt[0] and not tok else 0


def block(B, write=True):
    """-> (rows, lifetimes [(name, policy, torn_rows or None, lookups, frac)]) over every session dir of a block"""
    rows, lts = [], []
    for env in sorted(glob.glob(os.path.join(B, "*", "session.env"))):
        S = os.path.dirname(env)
        name, tok = os.path.basename(S), session_policy(S)
        pol = "allowed" if tok else "zero"
        for mf in sorted(glob.glob(os.path.join(S, "*", "manifest.txt"))):
            M = os.path.dirname(mf)
            if not os.path.isfile(os.path.join(M, "stats-steps.csv")):
                continue
            for r in step_rows(M):
                rows.append(dict(r, lifetime=name, policy=pol, measurement=os.path.basename(M), scope="step"))
            t, n, f = part_torn(M)
            if t is not None:
                rows.append(dict(lifetime=name, policy=pol, measurement=os.path.basename(M), scope="measured",
                                 torn_rows=t, lookups=n, torn_frac=f))
        lt = lifetime_torn(S)
        if lt:
            rows.append(dict(lifetime=name, policy=pol, scope="lifetime", torn_rows=lt[0], lookups=lt[1], torn_frac=lt[2]))
        else:   # no clean stop (a stopped block): sum of the measurements' pre/post snapshot deltas
            t = n = 0
            for pre in glob.glob(os.path.join(S, "*", "pre-t[0-9]*.txt")):
                post = pre.replace(os.sep + "pre-t", os.sep + "post-t")
                if os.path.isfile(post):
                    a, b = kv(pre), kv(post)
                    t += int(b.get("torn_rows", 0)) - int(a.get("torn_rows", 0))
                    n += int(b.get("lookups", 0)) - int(a.get("lookups", 0))
            lt = (t, n, frac(t, n))
            rows.append(dict(lifetime=name, policy=pol, scope="lifetime-measurements", torn_rows=t, lookups=n, torn_frac=lt[2]))
        lts.append((name, pol, lt[0], lt[1], lt[2]))
    if write:
        p = os.path.join(B, "torn-rows.csv")
        with open(p + ".tmp", "w", newline="") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(BLOCK_COLS)
            for r in rows:
                w.writerow([fmt(r.get(c)) for c in BLOCK_COLS])
        os.replace(p + ".tmp", p)
    return rows, lts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["allow", "window", "steps", "lifetime", "block"])
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--system", default="")
    ap.add_argument("--node-env", default="")
    ap.add_argument("--policy", default="")
    ap.add_argument("--nodes", type=int, default=2)
    ap.add_argument("--allow", default="")
    a = ap.parse_args()
    if a.cmd == "allow":
        rc, txt = check_policy(a.system, a.node_env, a.policy)
        print(f"TORN POLICY {txt}" if rc < 2 else f"TORN POLICY REFUSED: {txt}")
        return rc
    if not a.dir or not os.path.isdir(a.dir):
        print(f"{a.cmd}: no dir {a.dir}")
        return 2
    if a.cmd == "window":
        return window(a.dir, a.nodes, a.allow)
    if a.cmd == "steps":
        return steps(a.dir)
    if a.cmd == "lifetime":
        return lifetime(a.dir)
    _, lts = block(a.dir)
    bad = 0
    for name, pol, t, n, f in lts:
        print(f"TORN {name} policy {pol} torn_rows={fmt(t)} lookups={fmt(n)} torn_frac={fmt(f)}")
        bad |= bool(t) and pol == "zero"
    return 4 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

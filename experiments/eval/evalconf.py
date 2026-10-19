#!/usr/bin/env python3
"""eval.conf loader for shell and Python (experiments/eval; evaluation-pipeline rev 3 §4.1).

  evalconf.py shell [--conf F]        KEY='value' lines for `eval` in the run-set drivers: every key of eval.conf
                                      (relative paths made absolute below the project root P), plus the derived
                                      VDB_SEARCH_THREADS (= VCPUS_PER_VM - 1, + 1 writer), RS_THREADS (= VCPUS_PER_VM),
                                      CONFIG_SHA256_VDB, CONFIG_SHA256_RECSYS, EVAL_CONF, EVAL_CONF_SHA256, P
  evalconf.py sha <vdb|recsys> [--conf F]   the config_sha256 of a workload
  evalconf.py dump <vdb|recsys> [--conf F]  the canonical text the sha256 is taken over

config_sha256(workload) = sha256 of the sorted "KEY=value" lines of the measurement keys of that workload (global keys
without the [run] mark, plus VDB_* or RS_*) followed by "sha256(KEY)=<file sha256>" for every such key whose value
is an existing file (region file, Megalon configs, loadgen binary), so a changed file changes the hash. [run] keys
(RUNS, RESULTS_ROOT, DERIVED_ROOT, EVIDENCE_PREFIX) are bookkeeping and never part of it.
"""
import hashlib
import os
import re
import shlex
import sys

P = "/home/comsys/sungsu/destijl-control"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = os.path.join(HERE, "eval.conf")
RUN_KEYS = {"RUNS", "RESULTS_ROOT", "DERIVED_ROOT", "EVIDENCE_PREFIX"}
PREFIX = {"vdb": "VDB_", "recsys": "RS_"}
LINE = re.compile(r'^([A-Z][A-Z0-9_]*)=(?:"([^"$`\\]*)"|([^\s"$`\\#]*))\s*(#.*)?$')
PATHISH = re.compile(r"^(CXL_SWMC|builds|workspaces|recovery)(/|$)")


def load(path=DEFAULT):
    conf = {}
    for n, line in enumerate(open(path), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = LINE.match(s)
        if not m:
            raise ValueError(f"{path}:{n}: not KEY=value: {s}")
        k, v = m.group(1), m.group(2) if m.group(2) is not None else m.group(3)
        if k in conf:
            raise ValueError(f"{path}:{n}: duplicate key {k}")
        conf[k] = v
    for k in ("RUNS", "VCPUS_PER_VM", "SEED_BASE", "LEVELS_FROM_RUN"):
        if not re.fullmatch(r"[1-9][0-9]*", conf.get(k, "")):
            raise ValueError(f"{path}: {k} must be a positive integer")
    return conf


def absolute(conf):
    return {k: (os.path.join(P, v) if PATHISH.match(v) else v) for k, v in conf.items()}


def measurement_keys(conf, workload):
    pre = PREFIX[workload]
    other = tuple(p for w, p in PREFIX.items() if w != workload)
    return sorted(k for k in conf if k not in RUN_KEYS and not k.startswith(other) and
                  (k.startswith(pre) or not any(k.startswith(p) for p in PREFIX.values())))


def dump(conf, workload):
    a = absolute(conf)
    out = [f"{k}={conf[k]}" for k in measurement_keys(conf, workload)]
    for k in measurement_keys(conf, workload):
        if a[k] != conf[k] and os.path.isfile(a[k]):
            out.append(f"sha256({k})={hashlib.sha256(open(a[k], 'rb').read()).hexdigest()}")
    return "\n".join(out) + "\n"


def config_sha256(conf, workload):
    return hashlib.sha256(dump(conf, workload).encode()).hexdigest()


def main(argv):
    if len(argv) < 2 or argv[1] not in ("shell", "sha", "dump"):
        sys.exit(__doc__)
    path = DEFAULT
    if "--conf" in argv:
        i = argv.index("--conf")
        path = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    conf = load(path)
    if argv[1] == "shell":
        a = absolute(conf)
        v = int(conf["VCPUS_PER_VM"])
        a["VDB_SEARCH_THREADS"], a["RS_THREADS"] = str(v - 1), str(v)
        a["CONFIG_SHA256_VDB"], a["CONFIG_SHA256_RECSYS"] = config_sha256(conf, "vdb"), config_sha256(conf, "recsys")
        a["P"] = P
        a["EVAL_CONF"] = os.path.abspath(path)
        a["EVAL_CONF_SHA256"] = hashlib.sha256(open(path, "rb").read()).hexdigest()
        for k in sorted(a):
            print(f"{k}={shlex.quote(a[k])}")
    elif argv[1] == "sha":
        print(config_sha256(conf, argv[2]))
    else:
        sys.stdout.write(dump(conf, argv[2]))


if __name__ == "__main__":
    main(sys.argv)

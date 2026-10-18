#!/usr/bin/env python3
"""H1 main: the systems measured per workload (reports/H1-main-packet.md v0.6.7 §1; single source for levels.py,
check.py, collect.py, hook.sh and, through hook.sh's H1_SYSTEMS, the workload blocks).

  default (kv, lmdb, vdb): SLO phase hw pop mg; fixed phase hw pop mg mgoff (mgoff = Megalon timers off, C_diff)
  recsys: hw pop only (user decision 2026-10-18, state/TASKS.md "그냥 recsys는 megalon 측정 하지마"): no Megalon
          lifetime in H1; the Megalon RecSys numbers come from RECSYS-V1 v1.4 (recovery/RECSYS-V1-v1.4/cdiff.txt).

usage: h1sys.py slo|fix <workload>   prints the space-separated system list
"""
import sys

DEFAULT_SLO = ("hw", "pop", "mg")
SLO = {"recsys": ("hw", "pop")}
NO_MEGALON_NOTE = {
    "recsys": "Megalon not measured in H1 for recsys (user decision 2026-10-18); Megalon RecSys numbers: "
              "RECSYS-V1 v1.4 (recovery/RECSYS-V1-v1.4/cdiff.txt: query T 4762 ms (timers on) vs all-HWcc 201 ms, "
              "C_diff 4577 ms per query at 1 query/s; measured at T = 60 s, while H1 RecSys runs at T = 1 s since v0.6.9)",
}


def slo_systems(w):
    """SLO-phase systems of workload w (Fig 1, levels)"""
    return SLO.get(w, DEFAULT_SLO)


def fix_systems(w):
    """fixed-phase systems of workload w (Fig 2): the SLO systems, plus mgoff when Megalon is measured"""
    s = slo_systems(w)
    return s + ("mgoff",) if "mg" in s else s


def has_megalon(w):
    return "mg" in slo_systems(w)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("slo", "fix"):
        sys.exit(__doc__)
    print(" ".join((slo_systems if sys.argv[1] == "slo" else fix_systems)(sys.argv[2])))

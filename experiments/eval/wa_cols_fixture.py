"""Fixture: copy of a passing rs-ds block with build-13 wait-assist keys added, to check recv_check.py / stats_delta-based
tools tolerate them. usage: python3 -I wa_cols_fixture.py <src block> <dst block>, then recv_check.py <dst> --mode adaptive,
stats_delta.py / breakdown.py / check_breakdown.py on a <dst>/<lifetime>/slo dir. Checked 2026-11-11 on
recovery/eval-run2-rs-v7-run2-rs-ds-v1/block: RECVCHECK PASS, breakdown.csv byte-identical, BREAKDOWN PASS unchanged.
Adds to every dsshm-*/status-*.txt: ds.wait_assist, ds.wait_assist_skip and the ds.wa_* counters (DESIGN.md "Counters");
to every stats-steps.csv: sys.swmc.destijl.wa_* columns (value = row index). Never touches the source."""
import csv, os, shutil, sys

WA = ["wa_waits", "wa_waits_handled", "wa_handled", "wa_handled_ns", "wa_handled_fetch", "wa_handled_inv",
      "wa_handled_ack", "wa_skip_fetch", "wa_skip_inv", "wa_skip_ack", "wa_nested"]
src, dst = sys.argv[1], sys.argv[2]
shutil.copytree(src, dst, ignore=shutil.ignore_patterns("*.stl", "auc_*.csv"))
ns = nc = 0
for root, _, files in os.walk(dst):
    for f in files:
        p = os.path.join(root, f)
        if os.path.basename(root).startswith("dsshm-") and f.startswith("status-") and f.endswith(".txt"):
            with open(p, "a") as o:
                o.write("ds.wait_assist=1\nds.wait_assist_skip=0\n" + "".join(f"ds.{k}={7 + i}\n" for i, k in enumerate(WA)))
            ns += 1
        elif os.path.basename(root) == "stats" and f.startswith("step") and f.endswith(".txt"):
            with open(p, "a") as o:   # raw loadgen snapshot: as if the server's fixed list grew by the wa_* counters
                o.write("".join(f"sys.swmc.destijl.{k}={100 * (i + 1) + (5 if '-end-' in f else 0)}\n" for i, k in enumerate(WA)))
        elif f == "stats-steps.csv":
            rows = list(csv.reader(open(p)))
            if not rows:
                continue
            rows[0] += ["sys.swmc.destijl." + k for k in WA]
            for i, r in enumerate(rows[1:], 1):
                r += [str(i)] * len(WA)
            csv.writer(open(p, "w", newline="")).writerows(rows)
            nc += 1
print(f"fixture {dst}: {ns} status files, {nc} stats-steps.csv with wa_* keys")

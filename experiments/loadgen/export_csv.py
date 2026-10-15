#!/usr/bin/env python3
"""Export loadgen runs to CSV for spreadsheets: one row per (run, step, stream).

usage: export_csv.py --out steps.csv RUN_DIR[=label] ...
RUN_DIR is a loadgen --out dir (steps.jsonl, summary.json). Columns: label, step, phase, measure_s, pass, aborted,
reason, stream, offered, achieved, sent, done, errors, timeouts, p50/p90/p99/p999/pslo/max (ms), lag_p99_us,
max_under_slo (the run's confirm mean, same on every row of the run).
"""
import argparse, csv, json, os


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    cols = ["label", "step", "phase", "measure_s", "pass", "aborted", "reason", "stream", "offered", "achieved", "sent",
            "done", "errors", "timeouts", "p50_ms", "p90_ms", "p99_ms", "p999_ms", "pslo_ms", "max_ms", "lag_p99_us",
            "max_under_slo"]
    with open(a.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for spec in a.runs:
            run, _, label = spec.partition("=")
            label = label or os.path.basename(run.rstrip("/"))
            summ = json.load(open(os.path.join(run, "summary.json")))
            best = summ.get("confirm", {}).get("x_mean", "")
            for line in open(os.path.join(run, "steps.jsonl")):
                s = json.loads(line)
                if s["phase"] == "warmup":
                    continue
                for name, st in s["streams"].items():
                    w.writerow([label, s["step"], s["phase"], s["measure_s"], s["pass"], s["aborted"], s["reason"], name,
                                st["offered"], st["achieved"], st["sent"], st["done"], st["errors"], st["timeouts"],
                                st["p50_ms"], st["p90_ms"], st["p99_ms"], st["p999_ms"], st["pslo_ms"], st["max_ms"],
                                st["lag_p99_us"], best])
    print(f"-> {a.out}")


if __name__ == "__main__":
    main()

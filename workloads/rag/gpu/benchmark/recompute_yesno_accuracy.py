#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Recompute yes/no accuracy from a saved benchmark JSON file."
    )
    parser.add_argument("--run-json", required=True, help="Path to saved run JSON")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    run_path = Path(args.run_json).resolve()

    with run_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    records = data.get("records", [])
    valid = 0
    correct = 0
    invalid = 0

    for rec in records:
        pred = rec.get("prediction")
        gold = rec.get("gold_answer")
        if pred in ("yes", "no") and gold in ("yes", "no"):
            valid += 1
            if pred == gold:
                correct += 1
        else:
            invalid += 1

    accuracy = (correct / valid) if valid else 0.0

    print(f"run_json: {run_path}")
    print(f"records: {len(records)}")
    print(f"valid_predictions: {valid}")
    print(f"invalid_predictions: {invalid}")
    print(f"correct: {correct}")
    print(f"accuracy: {accuracy:.6f}")


if __name__ == "__main__":
    main()

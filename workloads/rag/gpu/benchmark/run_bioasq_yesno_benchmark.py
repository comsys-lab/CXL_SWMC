#!/usr/bin/env python3
import argparse
import asyncio
import datetime as dt
import json
import re
from pathlib import Path
from typing import Any

import aiohttp


LATENCY_TAIL_PATTERN = re.compile(r"\n__LATENCIES__.*__END__\s*$", re.DOTALL)
YES_NO_PATTERN = re.compile(r"\b(yes|no)\b", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run BioASQ yes/no benchmark against /chat (client_id=0) and save JSON logs."
    )
    parser.add_argument(
        "--client_id",
        default=0,
        type=int,
        help="Client ID to use for the benchmark. Default is 0.",
    )
    parser.add_argument(
        "--dataset",
        default="../Dataset/bioasq/bioasq_questions.json",
        help="Path to BioASQ JSONL file",
    )
    parser.add_argument(
        "--chat-url",
        default="http://127.0.0.1:9000/chat",
        help="/chat endpoint URL",
    )
    parser.add_argument(
        "--output-dir",
        default="./runs",
        help="Directory for run JSON output",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=180,
        help="Per-request timeout in seconds",
    )
    parser.add_argument(
        "--max-questions",
        type=int,
        default=0,
        help="Limit number of yes/no questions. 0 means all.",
    )
    return parser.parse_args()


def load_yesno_questions(path: Path) -> list[dict[str, Any]]:
    questions: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSON at line {line_no}: {exc}") from exc

            if str(item.get("question_type", "")).lower() != "yesno":
                continue

            gold = extract_gold_yesno(item)
            if gold is None:
                continue

            questions.append(
                {
                    "id": item.get("id", ""),
                    "question": item.get("input", ""),
                    "gold_answer": gold,
                }
            )
    return questions


def extract_gold_yesno(item: dict[str, Any]) -> str | None:
    outputs = item.get("output", [])
    if isinstance(outputs, list):
        for out in outputs:
            if not isinstance(out, dict):
                continue
            answer = out.get("answer")
            if isinstance(answer, str):
                norm = normalize_yesno(answer)
                if norm in ("yes", "no"):
                    return norm
    return None


def normalize_yesno(text: str) -> str | None:
    match = YES_NO_PATTERN.search(text.strip())
    if not match:
        return None
    return match.group(1).lower()


def build_forced_yesno_prompt(question: str) -> str:
    return (
        "Answer this question with exactly one token: yes or no. "
        "Do not output any other words, punctuation, or explanation.\n\n"
        f"Question: {question}"
    )


def strip_latency_tail(raw: str) -> str:
    return LATENCY_TAIL_PATTERN.sub("", raw).strip()


async def send_chat(
    session: aiohttp.ClientSession,
    chat_url: str,
    prompt: str,
    timeout_seconds: int,
    client_id: int = 0,
) -> tuple[str, int]:
    payload = {
        "user_input": prompt,
        "client_id": client_id,
    }
    timeout = aiohttp.ClientTimeout(total=timeout_seconds)

    async with session.post(chat_url, json=payload, timeout=timeout) as resp:
        status = resp.status
        text = await resp.text()
        return text, status


async def run_benchmark(args: argparse.Namespace) -> dict[str, Any]:
    dataset_path = Path(args.dataset).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    questions = load_yesno_questions(dataset_path)
    if args.max_questions and args.max_questions > 0:
        questions = questions[: args.max_questions]

    started_at = dt.datetime.now(dt.timezone.utc)

    records: list[dict[str, Any]] = []
    correct = 0
    total = 0
    invalid = 0

    async with aiohttp.ClientSession() as session:
        for idx, q in enumerate(questions, start=1):
            prompt = build_forced_yesno_prompt(q["question"])
            request_started = dt.datetime.now(dt.timezone.utc)

            raw_response = ""
            status_code = -1
            error = None
            pred = None

            try:
                raw_response, status_code = await send_chat(
                    session=session,
                    chat_url=args.chat_url,
                    prompt=prompt,
                    timeout_seconds=args.timeout_seconds,
                    client_id=args.client_id,
                )
                clean_response = strip_latency_tail(raw_response)
                pred = normalize_yesno(clean_response)
            except Exception as exc:
                clean_response = ""
                error = f"{type(exc).__name__}: {exc}"

            request_finished = dt.datetime.now(dt.timezone.utc)

            is_correct = False
            if pred in ("yes", "no"):
                total += 1
                is_correct = pred == q["gold_answer"]
                if is_correct:
                    correct += 1
            else:
                invalid += 1

            record = {
                "index": idx,
                "id": q["id"],
                "question": q["question"],
                "forced_prompt": prompt,
                "gold_answer": q["gold_answer"],
                "prediction": pred,
                "is_correct": is_correct,
                "raw_response": raw_response,
                "clean_response": clean_response,
                "http_status": status_code,
                "error": error,
                "request_started_at": request_started.isoformat(),
                "request_finished_at": request_finished.isoformat(),
            }
            records.append(record)

            if idx % 20 == 0 or idx == len(questions):
                print(
                    f"Progress: {idx}/{len(questions)} | "
                    f"valid={total}, correct={correct}, invalid={invalid}"
                )

    ended_at = dt.datetime.now(dt.timezone.utc)
    accuracy = (correct / total) if total > 0 else 0.0

    result = {
        "meta": {
            "started_at": started_at.isoformat(),
            "ended_at": ended_at.isoformat(),
            "dataset_path": str(dataset_path),
            "chat_url": args.chat_url,
            "timeout_seconds": args.timeout_seconds,
            "max_questions": args.max_questions,
            "prompt_policy": "force yes/no only",
            "client_id": args.client_id,
        },
        "summary": {
            "num_yesno_questions": len(questions),
            "num_valid_predictions": total,
            "num_invalid_predictions": invalid,
            "num_correct": correct,
            "accuracy": accuracy,
        },
        "records": records,
    }

    timestamp = started_at.strftime("%Y%m%d_%H%M%S")
    output_file = output_dir / f"bioasq_yesno_run_{timestamp}.json"
    with output_file.open("w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print("Saved run:", output_file)
    print(
        f"Accuracy={accuracy:.4f} | "
        f"correct={correct} / valid={total} | invalid={invalid}"
    )
    result["output_file"] = str(output_file)
    return result


def main() -> None:
    args = parse_args()
    asyncio.run(run_benchmark(args))


if __name__ == "__main__":
    main()

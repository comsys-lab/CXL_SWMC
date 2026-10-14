#!/usr/bin/env python3
import argparse
import asyncio
import datetime as dt
import json
import re
import string
from pathlib import Path
from typing import Any

import aiohttp


LATENCY_TAIL_PATTERN = re.compile(r"\n__LATENCIES__.*__END__\s*$", re.DOTALL)
NUMBERED_ANSWER_PATTERN = re.compile(r"^\s*(?:\d+[\.)]|[-*])\s*(.+?)\s*$")
PARENS_CONTENT_PATTERN = re.compile(r"\s*\([^)]*\)\s*")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run BioASQ factoid benchmark against /chat and save JSON logs "
            "with SAcc/LAcc/MRR metrics."
        )
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
        help="Limit number of factoid questions. 0 means all.",
    )
    parser.add_argument(
        "--top-k",
        type=int,
        default=5,
        help="Number of ranked predictions to evaluate (default: 5)",
    )
    return parser.parse_args()


def load_factoid_questions(path: Path) -> list[dict[str, Any]]:
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

            if str(item.get("question_type", "")).lower() != "factoid":
                continue

            gold_answers = extract_gold_factoid_answers(item)
            if not gold_answers:
                continue

            questions.append(
                {
                    "id": item.get("id", ""),
                    "question": item.get("input", ""),
                    "gold_answers": sorted(gold_answers),
                }
            )
    return questions


def _iter_answer_strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for element in value:
            yield from _iter_answer_strings(element)


def extract_gold_factoid_answers(item: dict[str, Any]) -> set[str]:
    answers: set[str] = set()

    outputs = item.get("output", [])
    if isinstance(outputs, list):
        for out in outputs:
            if not isinstance(out, dict):
                continue
            raw_answer = out.get("answer")
            for answer_text in _iter_answer_strings(raw_answer):
                norm = normalize_answer(answer_text)
                if norm:
                    answers.add(norm)

    # Fallback for BioASQ variants that use exact_answer.
    raw_exact = item.get("exact_answer")
    for answer_text in _iter_answer_strings(raw_exact):
        norm = normalize_answer(answer_text)
        if norm:
            answers.add(norm)

    return answers


def normalize_answer(text: str) -> str:
    normalized = text.strip().lower()
    if not normalized:
        return ""

    # Remove parenthetical aliases so "aspirin (ASA)" and "aspirin" can match.
    normalized = PARENS_CONTENT_PATTERN.sub(" ", normalized)

    # Drop punctuation to reduce formatting-related mismatches.
    punctuation_table = str.maketrans({ch: " " for ch in string.punctuation})
    normalized = normalized.translate(punctuation_table)

    normalized = " ".join(normalized.split())
    return normalized


def build_forced_factoid_prompt(question: str, top_k: int) -> str:
    return (
        f"Answer this biomedical factoid question with exactly {top_k} ranked short answers. "
        "Return only the answer list in this format:\n"
        "1. <answer>\n"
        "2. <answer>\n"
        "...\n"
        f"{top_k}. <answer>\n"
        "No explanation.\n\n"
        f"Question: {question}"
    )


def strip_latency_tail(raw: str) -> str:
    return LATENCY_TAIL_PATTERN.sub("", raw).strip()


def parse_ranked_predictions(text: str, top_k: int) -> list[str]:
    candidates: list[str] = []

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        match = NUMBERED_ANSWER_PATTERN.match(line)
        candidate = match.group(1).strip() if match else line
        norm = normalize_answer(candidate)
        if norm and norm not in candidates:
            candidates.append(norm)
        if len(candidates) >= top_k:
            return candidates

    # Fallback for one-line outputs with separators.
    if not candidates:
        pieces = re.split(r"[;,|]", text)
        for piece in pieces:
            norm = normalize_answer(piece)
            if norm and norm not in candidates:
                candidates.append(norm)
            if len(candidates) >= top_k:
                return candidates

    return candidates


def score_predictions(predictions: list[str], gold_answers: set[str], top_k: int) -> dict[str, Any]:
    ranked = predictions[:top_k]

    strict_hit = 1 if ranked and ranked[0] in gold_answers else 0
    lenient_hit = 1 if any(pred in gold_answers for pred in ranked) else 0

    first_correct_rank = None
    for idx, pred in enumerate(ranked, start=1):
        if pred in gold_answers:
            first_correct_rank = idx
            break

    reciprocal_rank = (1.0 / first_correct_rank) if first_correct_rank else 0.0

    return {
        "strict_hit": strict_hit,
        "lenient_hit": lenient_hit,
        "first_correct_rank": first_correct_rank,
        "reciprocal_rank": reciprocal_rank,
    }


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
    if args.top_k <= 0:
        raise ValueError("--top-k must be a positive integer")

    dataset_path = Path(args.dataset).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    questions = load_factoid_questions(dataset_path)
    if args.max_questions and args.max_questions > 0:
        questions = questions[: args.max_questions]

    started_at = dt.datetime.now(dt.timezone.utc)

    records: list[dict[str, Any]] = []
    num_evaluated = 0
    strict_correct = 0
    lenient_correct = 0
    mrr_sum = 0.0
    parse_invalid = 0
    request_errors = 0

    async with aiohttp.ClientSession() as session:
        for idx, q in enumerate(questions, start=1):
            prompt = build_forced_factoid_prompt(q["question"], args.top_k)
            request_started = dt.datetime.now(dt.timezone.utc)

            raw_response = ""
            status_code = -1
            error = None
            clean_response = ""
            predictions: list[str] = []

            try:
                raw_response, status_code = await send_chat(
                    session=session,
                    chat_url=args.chat_url,
                    prompt=prompt,
                    timeout_seconds=args.timeout_seconds,
                    client_id=args.client_id,
                )
                clean_response = strip_latency_tail(raw_response)
                predictions = parse_ranked_predictions(clean_response, args.top_k)
            except Exception as exc:
                error = f"{type(exc).__name__}: {exc!r}"
                request_errors += 1

            request_finished = dt.datetime.now(dt.timezone.utc)

            gold_set = set(q["gold_answers"])
            scores = score_predictions(predictions, gold_set, args.top_k)

            num_evaluated += 1
            strict_correct += scores["strict_hit"]
            lenient_correct += scores["lenient_hit"]
            mrr_sum += scores["reciprocal_rank"]

            if not predictions:
                parse_invalid += 1

            record = {
                "index": idx,
                "id": q["id"],
                "question": q["question"],
                "forced_prompt": prompt,
                "gold_answers": q["gold_answers"],
                "predictions": predictions,
                "strict_hit": bool(scores["strict_hit"]),
                "lenient_hit": bool(scores["lenient_hit"]),
                "first_correct_rank": scores["first_correct_rank"],
                "reciprocal_rank": scores["reciprocal_rank"],
                "raw_response": raw_response,
                "clean_response": clean_response,
                "http_status": status_code,
                "error": error,
                "request_started_at": request_started.isoformat(),
                "request_finished_at": request_finished.isoformat(),
            }
            records.append(record)

            if idx % 20 == 0 or idx == len(questions):
                partial_sacc = (strict_correct / num_evaluated) if num_evaluated else 0.0
                partial_lacc = (lenient_correct / num_evaluated) if num_evaluated else 0.0
                partial_mrr = (mrr_sum / num_evaluated) if num_evaluated else 0.0
                print(
                    f"Progress: {idx}/{len(questions)} | "
                    f"SAcc={partial_sacc:.4f}, LAcc={partial_lacc:.4f}, MRR={partial_mrr:.4f} | "
                    f"empty_pred={parse_invalid}, request_errors={request_errors}"
                )

    ended_at = dt.datetime.now(dt.timezone.utc)

    strict_accuracy = (strict_correct / num_evaluated) if num_evaluated else 0.0
    lenient_accuracy = (lenient_correct / num_evaluated) if num_evaluated else 0.0
    mrr = (mrr_sum / num_evaluated) if num_evaluated else 0.0

    result = {
        "meta": {
            "started_at": started_at.isoformat(),
            "ended_at": ended_at.isoformat(),
            "dataset_path": str(dataset_path),
            "chat_url": args.chat_url,
            "timeout_seconds": args.timeout_seconds,
            "max_questions": args.max_questions,
            "top_k": args.top_k,
            "prompt_policy": f"force ranked top-{args.top_k} short answers",
            "client_id": args.client_id,
        },
        "summary": {
            "num_factoid_questions": len(questions),
            "num_evaluated": num_evaluated,
            "num_empty_predictions": parse_invalid,
            "num_request_errors": request_errors,
            "num_strict_correct": strict_correct,
            "num_lenient_correct": lenient_correct,
            "strict_accuracy": strict_accuracy,
            "lenient_accuracy": lenient_accuracy,
            "mrr": mrr,
        },
        "records": records,
    }

    timestamp = started_at.strftime("%Y%m%d_%H%M%S")
    output_file = output_dir / f"bioasq_factoid_run_{timestamp}.json"
    with output_file.open("w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print("Saved run:", output_file)
    print(
        f"SAcc={strict_accuracy:.4f} | "
        f"LAcc={lenient_accuracy:.4f} | "
        f"MRR={mrr:.4f} | "
        f"empty_pred={parse_invalid} | request_errors={request_errors}"
    )

    result["output_file"] = str(output_file)
    return result


def main() -> None:
    args = parse_args()
    asyncio.run(run_benchmark(args))


if __name__ == "__main__":
    main()

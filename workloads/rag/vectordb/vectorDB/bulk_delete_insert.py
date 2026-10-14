#!/usr/bin/env python3
"""
Bulk soft-delete + bulk insert driver for VectorDB REST API.

Default behavior matches the requested scenario:
- Soft-delete 260,000 random global IDs in [0, 26,020,203)
- Insert 260,000 vectors from Arrow shards starting at data-00188-of-00198.arrow

Requirements:
- Python 3.8+
- pyarrow

Example:
python3 bulk_delete_insert.py \
  --base-url http://127.0.0.1:8080 \
  --delete-count 260000 \
  --delete-max-id 26020203 \
  --dataset-dir /home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_sorted \
  --start-file data-00188-of-00198.arrow \
  --insert-count 260000
"""

from __future__ import annotations

import argparse
import itertools
import json
import random
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

try:
    import pyarrow as pa
    import pyarrow.ipc as ipc
except ImportError as exc:
    raise SystemExit("pyarrow is required: pip install pyarrow") from exc


def post_json(url: str, payload: dict, timeout_sec: float, retries: int) -> Tuple[bool, str]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    last_err = ""
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                text = resp.read().decode("utf-8", errors="replace")
                try:
                    obj = json.loads(text)
                    ok = bool(obj.get("success", False))
                    if ok:
                        return True, ""
                    return False, obj.get("error", "unknown error")
                except json.JSONDecodeError:
                    return False, f"non-json response: {text[:200]}"
        except urllib.error.HTTPError as err:
            last_err = f"HTTP {err.code}: {err.reason}"
        except Exception as err:  # pylint: disable=broad-except
            last_err = str(err)

        if attempt < retries:
            time.sleep(0.05 * (attempt + 1))

    return False, last_err


def find_arrow_files(dataset_dir: Path, start_file: str) -> List[Path]:
    files = sorted(dataset_dir.glob("data-*.arrow"))
    if not files:
        raise RuntimeError(f"No arrow shard files found in {dataset_dir}")

    names = [p.name for p in files]
    if start_file not in names:
        raise RuntimeError(f"start file not found: {start_file}")

    start_idx = names.index(start_file)
    return files[start_idx:]


def _open_arrow_reader(path: Path):
    # HF shards are typically Arrow IPC file format.
    # Fallback to stream reader in case of stream-format files.
    try:
        return ipc.RecordBatchFileReader(pa.memory_map(str(path), "r"))
    except Exception:
        return ipc.RecordBatchStreamReader(pa.memory_map(str(path), "r"))


def iter_embeddings(
    dataset_dir: Path,
    start_file: str,
    limit: int,
    min_chunk_id: int | None,
) -> Iterable[List[float]]:
    emitted = 0

    for shard in find_arrow_files(dataset_dir, start_file):
        reader = _open_arrow_reader(shard)

        if hasattr(reader, "num_record_batches"):
            batches = [reader.get_batch(i) for i in range(reader.num_record_batches)]
        else:
            batches = list(reader)

        for batch in batches:
            if emitted >= limit:
                return

            if "embedding" not in batch.schema.names:
                raise RuntimeError(f"'embedding' column not found in {shard}")

            emb_col = batch.column(batch.schema.get_field_index("embedding"))

            chunk_col = None
            if min_chunk_id is not None:
                if "chunk_id" not in batch.schema.names:
                    raise RuntimeError("min_chunk_id mode requires 'chunk_id' column")
                chunk_col = batch.column(batch.schema.get_field_index("chunk_id"))

            n = batch.num_rows
            for i in range(n):
                if emitted >= limit:
                    return

                if chunk_col is not None:
                    cid = chunk_col[i].as_py()
                    if cid is None or int(cid) < min_chunk_id:
                        continue

                vec = emb_col[i].as_py()
                if vec is None:
                    continue

                emitted += 1
                yield [float(x) for x in vec]


def build_delete_ids(mode: str, delete_count: int, delete_max_id: int, seed: int, seq_start_id: int) -> List[int]:
    if mode == "random":
        if delete_count > delete_max_id:
            raise RuntimeError("delete_count cannot exceed delete_max_id in random mode")
        rng = random.Random(seed)
        # Unique IDs to avoid duplicate delete requests.
        return rng.sample(range(delete_max_id), delete_count)

    if seq_start_id < 0 or seq_start_id + delete_count > delete_max_id:
        raise RuntimeError("sequential delete range is out of [0, delete_max_id)")
    return list(range(seq_start_id, seq_start_id + delete_count))


def run_deletes(base_url: str, ids: Sequence[int], workers: int, timeout_sec: float, retries: int) -> Tuple[int, int]:
    url = f"{base_url.rstrip('/')}/api/delete"

    def one(gid: int) -> bool:
        ok, _ = post_json(url, {"id": int(gid)}, timeout_sec, retries)
        return ok

    ok_count = 0
    fail_count = 0
    t0 = time.time()

    with ThreadPoolExecutor(max_workers=workers) as ex:
        for idx, ok in enumerate(ex.map(one, ids), start=1):
            if ok:
                ok_count += 1
            else:
                fail_count += 1

            if idx % 1000 == 0:
                elapsed = time.time() - t0
                print(f"[delete] {idx}/{len(ids)} done, ok={ok_count}, fail={fail_count}, {elapsed:.1f}s")

    return ok_count, fail_count


def run_inserts(
    base_url: str,
    vectors: Iterable[List[float]],
    insert_count: int,
    workers: int,
    timeout_sec: float,
    retries: int,
    expected_dim: int,
) -> Tuple[int, int]:
    url = f"{base_url.rstrip('/')}/api/insert"

    def one(vec: List[float]) -> bool:
        if len(vec) != expected_dim:
            return False
        ok, _ = post_json(url, {"vector": vec}, timeout_sec, retries)
        return ok

    ok_count = 0
    fail_count = 0
    submitted = 0
    t0 = time.time()

    with ThreadPoolExecutor(max_workers=workers) as ex:
        pending = []

        for vec in vectors:
            pending.append(ex.submit(one, vec))
            submitted += 1

            if len(pending) >= workers * 8:
                for fut in pending:
                    if fut.result():
                        ok_count += 1
                    else:
                        fail_count += 1
                pending.clear()

                if submitted % 1000 == 0:
                    elapsed = time.time() - t0
                    print(f"[insert] {submitted}/{insert_count} submitted, ok={ok_count}, fail={fail_count}, {elapsed:.1f}s")

            if submitted >= insert_count:
                break

        for fut in pending:
            if fut.result():
                ok_count += 1
            else:
                fail_count += 1

    if submitted < insert_count:
        print(f"[insert] WARNING: only {submitted} vectors were read from Arrow files")

    return ok_count, fail_count


def main() -> int:
    parser = argparse.ArgumentParser(description="Bulk delete+insert for VectorDB")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--start-file", default="data-00188-of-00198.arrow")
    parser.add_argument("--delete-count", type=int, default=260000)
    parser.add_argument("--insert-count", type=int, default=260000)
    parser.add_argument("--insert-step", type=int, default=260000)
    parser.add_argument("--delete-max-id", type=int, default=26020203)
    parser.add_argument("--delete-mode", choices=["random", "sequential"], default="random")
    parser.add_argument("--seq-start-id", type=int, default=0)
    parser.add_argument("--min-chunk-id", type=int, default=None)
    parser.add_argument("--seed", type=int, default=20260401)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("--timeout-sec", type=float, default=5.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--expected-dim", type=int, default=768)
    parser.add_argument("--skip-delete", action="store_true")
    parser.add_argument("--skip-insert", action="store_true")
    args = parser.parse_args()

    dataset_dir = Path(args.dataset_dir)
    if not dataset_dir.exists():
        print(f"dataset dir not found: {dataset_dir}", file=sys.stderr)
        return 2

    print("=== Bulk Delete + Insert ===")
    print(f"base_url={args.base_url}")
    print(f"delete_mode={args.delete_mode}, delete_count={args.delete_count}, delete_max_id={args.delete_max_id}")
    print(
        f"insert_count={args.insert_count}, insert_step={args.insert_step}, "
        f"start_file={args.start_file}, min_chunk_id={args.min_chunk_id}"
    )
    print(f"workers={args.workers}, timeout={args.timeout_sec}s, retries={args.retries}")

    if args.insert_step <= 0:
        print("insert_step must be > 0", file=sys.stderr)
        return 2

    total_start = time.time()

    if not args.skip_delete:
        delete_ids = build_delete_ids(
            mode=args.delete_mode,
            delete_count=args.delete_count,
            delete_max_id=args.delete_max_id,
            seed=args.seed,
            seq_start_id=args.seq_start_id,
        )
        t0 = time.time()
        ok, fail = run_deletes(args.base_url, delete_ids, args.workers, args.timeout_sec, args.retries)
        print(f"[delete] done: ok={ok}, fail={fail}, elapsed={time.time() - t0:.1f}s")

    if not args.skip_insert:
        vec_iter = iter_embeddings(
            dataset_dir=dataset_dir,
            start_file=args.start_file,
            limit=args.insert_count,
            min_chunk_id=args.min_chunk_id,
        )
        t0 = time.time()
        total_ok = 0
        total_fail = 0
        total_submitted = 0
        checkpoint_idx = 0

        while total_submitted < args.insert_count:
            checkpoint_idx += 1
            checkpoint_target = min(args.insert_step, args.insert_count - total_submitted)

            ok, fail = run_inserts(
                base_url=args.base_url,
                vectors=itertools.islice(vec_iter, checkpoint_target),
                insert_count=checkpoint_target,
                workers=args.workers,
                timeout_sec=args.timeout_sec,
                retries=args.retries,
                expected_dim=args.expected_dim,
            )

            chunk_submitted = ok + fail
            total_ok += ok
            total_fail += fail
            total_submitted += chunk_submitted

            print(
                f"[insert-checkpoint {checkpoint_idx}] chunk={chunk_submitted}/{checkpoint_target}, "
                f"chunk_ok={ok}, chunk_fail={fail}, total={total_submitted}/{args.insert_count}"
            )

            if chunk_submitted < checkpoint_target:
                print("[insert] WARNING: no more vectors available in Arrow files")
                break

            if total_submitted >= args.insert_count:
                break

            user_input = input(
                "다음 insert를 진행하려면 'n' 입력 (중단하려면 다른 키 입력): "
            ).strip().lower()
            if user_input != "n":
                print("[insert] stopped by user")
                break

        print(f"[insert] done: ok={total_ok}, fail={total_fail}, elapsed={time.time() - t0:.1f}s")

    print(f"[total] elapsed={time.time() - total_start:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

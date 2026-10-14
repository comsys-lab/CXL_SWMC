import argparse
import time

import numpy as np
from datasets import Dataset, DatasetDict, load_from_disk


def reassign_chunkid_sequential(dataset: Dataset) -> Dataset:
    total = len(dataset)
    new_chunk_ids = np.arange(total, dtype=np.int64)

    if "chunk_id" in dataset.column_names:
        dataset = dataset.remove_columns("chunk_id")

    dataset = dataset.add_column("chunk_id", new_chunk_ids)
    return dataset


def reassign_chunkid_parallel(dataset: Dataset, num_proc: int, batch_size: int) -> Dataset:
    if num_proc < 1:
        raise ValueError("num_proc must be >= 1")

    def assign_chunk_id_batch(examples, indices):
        examples["chunk_id"] = indices
        return examples

    return dataset.map(
        assign_chunk_id_batch,
        batched=True,
        with_indices=True,
        batch_size=batch_size,
        num_proc=num_proc,
        desc=f"Reassigning chunk_id in parallel (num_proc={num_proc})",
    )


def change_chunkid(
    input_path: str,
    output_path: str,
    split: str | None = None,
    mode: str = "sequential",
    num_proc: int = 1,
    batch_size: int = 100_000,
) -> None:
    started = time.time()
    loaded = load_from_disk(input_path)

    if isinstance(loaded, DatasetDict):
        if split is None:
            raise ValueError("Input is a DatasetDict. Please provide --split.")
        if split not in loaded:
            raise ValueError(f"Split '{split}' not found. Available: {list(loaded.keys())}")
        dataset = loaded[split]
        print(f"Loaded DatasetDict split '{split}' with {len(dataset)} records")
        if mode == "parallel":
            modified_dataset = reassign_chunkid_parallel(dataset, num_proc=num_proc, batch_size=batch_size)
        else:
            modified_dataset = reassign_chunkid_sequential(dataset)
        loaded[split] = modified_dataset
        loaded.save_to_disk(output_path)
    elif isinstance(loaded, Dataset):
        dataset = loaded
        print(f"Loaded Dataset with {len(dataset)} records")
        if mode == "parallel":
            modified_dataset = reassign_chunkid_parallel(dataset, num_proc=num_proc, batch_size=batch_size)
        else:
            modified_dataset = reassign_chunkid_sequential(dataset)
        modified_dataset.save_to_disk(output_path)
    else:
        raise TypeError("Unsupported dataset type returned by load_from_disk")

    elapsed = time.time() - started
    print(f"chunk_id reassigned ({mode}) and saved to: {output_path}")
    print(f"Elapsed time: {elapsed:.2f}s")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Reassign chunk_id sequentially from 0 to N-1")
    parser.add_argument("--input-path", required=True, help="Input dataset path")
    parser.add_argument("--output-path", required=True, help="Output dataset path")
    parser.add_argument("--split", default=None, help="Split name when input is DatasetDict")
    parser.add_argument(
        "--mode",
        choices=["sequential", "parallel"],
        default="sequential",
        help="Execution mode. sequential is usually fastest; parallel uses multiprocessing.",
    )
    parser.add_argument("--num-proc", type=int, default=4, help="Number of worker processes for parallel mode")
    parser.add_argument("--batch-size", type=int, default=100_000, help="Batch size for parallel map")
    args = parser.parse_args()

    change_chunkid(
        args.input_path,
        args.output_path,
        args.split,
        mode=args.mode,
        num_proc=args.num_proc,
        batch_size=args.batch_size,
    )
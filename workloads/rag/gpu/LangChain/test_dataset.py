from langchain_community.storage import SQLStore
from datasets import load_dataset, load_from_disk
import argparse
from random import randint
import os
import time
import numpy as np

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build SQLite database from JSON file")

    parser.add_argument("--dataset-path", type=str, default=None, help="Path to the DataSets (arrow) file")
    parser.add_argument("--hf-dataset-name", type=str, default=None, help="Name of the Hugging Face dataset (if using a named dataset)")
    parser.add_argument("--num-records", type=int, default=None, help="Number of records to store (default: all)")
    parser.add_argument("--max-chunk-id", type=int, default=28_000_000, help="Maximum expected chunk_id")
    parser.add_argument("--batch-size", type=int, default=1_000_000, help="Batch size for chunk_id scan")

    args = parser.parse_args()

    # dataset_path or hf_dataset_name must be exculsivly provided
    if (args.dataset_path is None and args.hf_dataset_name is None) or (args.dataset_path and args.hf_dataset_name):
        raise ValueError("Either --dataset-path or --hf-dataset-name must be provided, but not both.")

    if args.dataset_path:
        print(f"Loading dataset from local path: {args.dataset_path}")
        dataset = load_from_disk(args.dataset_path)
    else:
        print(f"Loading dataset from Hugging Face: {args.hf_dataset_name}")
        dataset = load_dataset(args.hf_dataset_name, split="train")

    # chunk_id and document field must be present in the dataset
    if "chunk_id" not in dataset.column_names or "document" not in dataset.column_names:
        raise ValueError("The dataset must contain 'chunk_id' and 'document' fields.")

    if args.num_records:
        dataset = dataset.select(range(args.num_records))
    print(f"Dataset loaded with {len(dataset)} records.")

    doc_ids = ['8396147', '3819451', '10253948', '4447745', '9610893', '2127537', '4762322', '12303203', '6884484', '9966488']
    for doc_id in doc_ids:
        print(f"Document for chunk_id {doc_id}: {dataset[int(doc_id)]['document']}")
        print(f"embedding vector for chunk_id {doc_id}: {dataset[int(doc_id)]['embedding'][0:10]}...")
    # for i in range(0, len(dataset), len(dataset) // 10):
    #     print(f"Dataset {i}: {dataset[i]['chunk_id']}")


    # # 데이터셋을 배치 + 벡터화로 스캔하며 bitset에 체크
    # max_chunk_id = args.max_chunk_id
    # seen = bytearray(max_chunk_id + 1)
    # seen_np = np.frombuffer(seen, dtype=np.uint8)
    # invalid_chunk_id_count = 0
    # out_of_range_chunk_id_count = 0
    # count = 0
    # batch_size = args.batch_size

    # for batch in dataset.iter(batch_size=batch_size):
    #     raw_ids = np.asarray(batch["chunk_id"])
    #     count += raw_ids.size

    #     if np.issubdtype(raw_ids.dtype, np.integer):
    #         ids = raw_ids.astype(np.int64, copy=False)
    #         invalid_in_batch = 0
    #     else:
    #         # 문자열 chunk_id까지 한 번에 벡터 변환 시도
    #         try:
    #             ids = raw_ids.astype(np.int64)
    #             invalid_in_batch = 0
    #         except (TypeError, ValueError):
    #             # 일부 값이 깨진 경우에만 예외적으로 개별 파싱
    #             parsed = np.empty(raw_ids.size, dtype=np.int64)
    #             parsed.fill(-1)
    #             invalid_in_batch = 0
    #             for i, value in enumerate(raw_ids):
    #                 try:
    #                     parsed[i] = int(value)
    #                 except (TypeError, ValueError):
    #                     invalid_in_batch += 1
    #             ids = parsed

    #     invalid_chunk_id_count += invalid_in_batch

    #     valid_mask = (ids >= 0) & (ids <= max_chunk_id)
    #     valid_ids = ids[valid_mask]
    #     if valid_ids.size > 0:
    #         seen_np[valid_ids] = 1

    #     out_of_range_chunk_id_count += int(ids.size - valid_ids.size - invalid_in_batch)

    #     if count % max(batch_size, 100_000) == 0:
    #         print(f"Processed {count} records...")

    # missing_mask = seen_np == 0
    # missing_count = int(missing_mask.sum())

    # if missing_count > 0:
    #     print(f"Missing chunk id count: {missing_count}")
    #     missing_chunk_ids = np.flatnonzero(missing_mask).tolist()
    #     print(f"Missing chunk ids: {missing_chunk_ids}")
    # else:
    #     print(f"All chunk ids from 0 to {max_chunk_id} are present in the dataset.")

    # if invalid_chunk_id_count > 0:
    #     print(f"Invalid chunk_id rows: {invalid_chunk_id_count}")
    # if out_of_range_chunk_id_count > 0:
    #     print(f"Out-of-range chunk_id rows: {out_of_range_chunk_id_count}")
from langchain_community.storage import SQLStore
from datasets import load_dataset, load_from_disk
import argparse
from random import randint
import os
import time

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build SQLite database from JSON file")

    parser.add_argument("--dataset-path", type=str, default=None, help="Path to the DataSets (arrow) file")
    parser.add_argument("--hf-dataset-name", type=str, default=None, help="Name of the Hugging Face dataset (if using a named dataset)")
    parser.add_argument("--sqlite-db-path", type=str, required=True, help="Path to the SQLite database file")
    parser.add_argument("--num-records", type=int, default=None, help="Number of records to store (default: all)")

    args = parser.parse_args()

    # dataset_path or hf_dataset_name must be exculsivly provided
    if (args.dataset_path is None and args.hf_dataset_name is None) or (args.dataset_path and args.hf_dataset_name):
        raise ValueError("Either --dataset-path or --hf-dataset-name must be provided, but not both.")


    namespace = args.dataset_path.split("/")[-1]
    print(f"Using namespace: {namespace}")
    sql_store = SQLStore(namespace=namespace, db_url=f"sqlite:///{args.sqlite_db_path}")
    sql_store.create_schema()

    if args.dataset_path:
        print(f"Loading dataset from local path: {args.dataset_path}")
        dataset = load_from_disk(args.dataset_path)
    else:
        print(f"Loading dataset from Hugging Face: {args.hf_dataset_name}")
        dataset = load_dataset(args.hf_dataset_name, split="train")

    # chunk_id and document field must be present in the dataset
    if "chunk_id" not in dataset.column_names or "document" not in dataset.column_names:
        raise ValueError("The dataset must contain 'id' and 'content' fields.")

    if args.num_records:
        dataset = dataset.select(range(args.num_records))
    print(f"Dataset loaded with {len(dataset)} records.")
    
    # 전체 데이터를 미리 변환
    def encode_documents(example):
        return {
            "encoded_doc": example["document"].encode("utf-8"),
            "str_id": str(example["chunk_id"])
        }
    
    # map을 사용하여 전체 데이터를 병렬로 전처리
    processed_dataset = dataset.map(
        encode_documents, 
        num_proc=os.cpu_count() # CPU 코어 수에 맞게 조정
    )

    # 배치로 삽입
    batch_size = 100000
    for i in range(0, len(processed_dataset), batch_size):
        start_time = time.time()
        end_idx = min(i + batch_size, len(processed_dataset))

        # 직접 슬라이싱으로 데이터 추출 (훨씬 빠름)
        batch_str_ids = processed_dataset["str_id"][i:end_idx]
        batch_encoded_docs = processed_dataset["encoded_doc"][i:end_idx]
        records = list(zip(batch_str_ids, batch_encoded_docs))
   
        sql_store.mset(records)
        end_time = time.time()
        print(f"Batch {i // batch_size + 1}: Inserted {len(records)} records in {end_time - start_time:.2f} seconds.")
    
    print("All records inserted successfully.")

    ## 테스트: 데이터베이스에서 랜덤하게 일부 항목을 검색
    for _ in range(5):
        random_id = randint(0, args.num_records if args.num_records else len(dataset) - 1)
        retrieved_docs = sql_store.mget([str(random_id)])
        decoded_doc = retrieved_docs[0].decode("utf-8") if retrieved_docs[0] else "None"
        print(f"Retrieved document for chunk_id {random_id}: {decoded_doc[:100]}...")  # 앞 100자만 출력
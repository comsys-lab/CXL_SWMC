from langchain_community.storage import SQLStore
from datasets import load_dataset, load_from_disk
import argparse
from random import randint
import os
import time

if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument("--sqlite-db-path", type=str, required=True, help="Path to the SQLite database file")

    args = parser.parse_args()

    namespace = "PubMed_bge_28000000_sorted"
    print(f"Using namespace: {namespace}")
    sql_store = SQLStore(namespace=namespace, db_url=f"sqlite:///{args.sqlite_db_path}")

    ## 테스트: 데이터베이스에서 일부 항목을 검색
    for i in range(26000000, 50000000, 1000000):  # 예시로 10개의 문서를 검색
        doc_id = str(i)
        retrieved_docs = sql_store.mget([doc_id])
        decoded_doc = retrieved_docs[0].decode("utf-8") if retrieved_docs[0] else "None"
        print(f"Retrieved document for chunk_id {doc_id}: {decoded_doc}")  # 앞 100자만 출력
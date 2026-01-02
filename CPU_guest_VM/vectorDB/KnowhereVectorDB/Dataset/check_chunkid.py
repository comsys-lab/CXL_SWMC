from datasets import load_dataset, load_from_disk

def check_chunkid(input_path):
    # Load the dataset from the specified input path
    dataset = load_from_disk(input_path)
    
    # Check if 'chunk_id' column exists
    if 'chunk_id' not in dataset.column_names:
        raise ValueError("'chunk_id' column not found in the dataset.")
    
    # Print the first 10 chunk_id values to verify
    chunk_ids = [example['chunk_id'] for example in dataset.select(range(10))]
    print("First 10 chunk_id values:", chunk_ids)

    # print dataset info
    print(f"\nDataset info:")
    print(f"  Total examples: {len(dataset)}")
    if len(dataset) > 0:
        print(f"    Columns: {dataset.column_names}")
        print(f"    First example keys: {list(dataset[0].keys())}")

if __name__ == "__main__":
    # input_path = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000"  # Replace with your input dataset path
    input_path = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_modified"  # Replace with your input dataset path
    check_chunkid(input_path)
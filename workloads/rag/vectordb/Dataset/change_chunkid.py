from datasets import load_dataset, load_from_disk


def change_chunkid(input_path, output_path):
    # Load the dataset from the specified input path
    dataset = load_from_disk(input_path)
    
    # Check if 'chunk_id' column exists
    if 'chunk_id' not in dataset.column_names:
        raise ValueError("'chunk_id' column not found in the dataset.")
    
    # Function to modify chunk_id, chunk id is int64 type, we convert the value from [c+0, c+1, ...] to [0, 1, 2, 3, ...]
    constant = dataset[0]['chunk_id']  # Assuming chunk_id is consistent across the dataset
    def modify_chunk_id(example):
        example['chunk_id'] = example['chunk_id'] - constant
        return example

    # Apply the modification to all examples in the dataset
    modified_dataset = dataset.map(modify_chunk_id)
    
    # Save the modified dataset to the specified output path
    modified_dataset.save_to_disk(output_path)
    print(f"Modified dataset saved to {output_path}")

if __name__ == "__main__":
    input_path = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000"  # Replace with your input dataset path
    output_path = "/home/comsys/CXLSharedMemVM/KnowhereVectorDB/Dataset/PubMed_bge/PubMed_bge_28000000_modified"  # Replace with your desired output dataset path
    change_chunkid(input_path, output_path)
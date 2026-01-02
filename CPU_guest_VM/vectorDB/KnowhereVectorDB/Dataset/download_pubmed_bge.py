from datasets import load_dataset
import os

dataset_name = 'PubMed_bge'
dataset_dir = 'PubMed_bge/'

# 원하는 개수 설정 (None이면 전체 저장)
DESIRED_COUNT = 28_000_000  

# 디렉토리가 없으면 생성
os.makedirs(dataset_dir, exist_ok=True)

corpus_dataset = load_dataset("binbin10/PubMed_bge")

print("Dataset loaded successfully.")
print(f"Dataset splits: {list(corpus_dataset.keys())}")

# DatasetDict에서 'train' split에 접근하여 저장
if 'train' in corpus_dataset:
    train_dataset = corpus_dataset['train']
    print(f"Original train dataset size: {len(train_dataset)}")
    
    # 원하는 개수만큼 선택
    if DESIRED_COUNT and DESIRED_COUNT < len(train_dataset):
        train_dataset = train_dataset.select(range(DESIRED_COUNT))
        print(f"Selected {DESIRED_COUNT} examples from train dataset")
    
    print(f"Final dataset size to save: {len(train_dataset)}")
    
    # Arrow 파일로 저장
    output_path = os.path.join(dataset_dir, f"{dataset_name}_{len(train_dataset)}")
    train_dataset.save_to_disk(output_path)
    print(f"Dataset saved to {output_path}")
else:
    # 만약 train split이 없다면 첫 번째 available split 사용
    first_split = list(corpus_dataset.keys())[0]
    print(f"Using split: {first_split}")
    
    dataset_split = corpus_dataset[first_split]
    print(f"Original dataset size: {len(dataset_split)}")
    
    # 원하는 개수만큼 선택
    if DESIRED_COUNT and DESIRED_COUNT < len(dataset_split):
        dataset_split = dataset_split.select(range(DESIRED_COUNT))
        print(f"Selected {DESIRED_COUNT} examples from {first_split} dataset")
    
    print(f"Final dataset size to save: {len(dataset_split)}")
    
    # Arrow 파일로 저장
    output_path = os.path.join(dataset_dir, f"{dataset_name}_{len(dataset_split)}")
    dataset_split.save_to_disk(output_path)
    print(f"Dataset saved to {output_path}")

# 데이터셋 정보 출력
print(f"\nDataset info:")
for split_name, split_data in corpus_dataset.items():
    print(f"  {split_name}: {len(split_data)} examples")
    if len(split_data) > 0:
        print(f"    Columns: {split_data.column_names}")
        print(f"    First example keys: {list(split_data[0].keys())}")
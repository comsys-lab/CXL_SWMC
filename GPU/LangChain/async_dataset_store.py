from datasets import load_dataset, Dataset, load_from_disk
from typing import Any, List, Optional, Sequence, Tuple
import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
import os
from langchain_core.stores import BaseStore

class AsyncDatasetStore(BaseStore[str, Any]):
    """
    Hugging Face datasets를 사용하여 비동기적으로 작동하는 키-값 저장소.
    무지성으로 정수 키를 사용해서 ds[key]['document']로 직접 접근합니다.
    """
    def __init__(self, dataset_path: str = None, dataset_name: str = None):
        self.dataset_path = dataset_path
        self.dataset_name = dataset_name
        self.dataset = None
        self.temp_dict = {}  # amset으로 저장되는 임시 딕셔너리 (int -> str)
        self.executor = ThreadPoolExecutor(max_workers=os.cpu_count()*4)
        
    async def initialize(self):
        """데이터셋을 로드합니다."""
        try:
            if self.dataset_path:
                # 로컬 데이터셋 로드
                logging.info(f"로컬 데이터셋을 로드합니다: {self.dataset_path}")
                # self.dataset = load_dataset(self.dataset_path, split="train")
                self.dataset = load_from_disk(self.dataset_path)
            else:
                logging.info(f"로컬 데이터셋이 없습니다. 에러 발생.")
                raise ValueError("dataset_path가 지정되지 않았습니다.")
                # elif self.dataset_name:
                #     # Hugging Face Hub에서 데이터셋 로드
                #     logging.info(f"Hugging Face에서 데이터셋을 로드합니다: {self.dataset_name}")
                #     self.dataset = load_dataset(self.dataset_name, split="train")
                # else:
                #     # 빈 데이터셋 생성
                #     logging.info("빈 데이터셋을 생성합니다.")
                #     self.dataset = Dataset.from_dict({"document": []})
                    
            logging.info(f"데이터셋 초기화 완료. 총 {len(self.dataset)}개 항목 로드됨.")
            
        except Exception as e:
            logging.error(f"데이터셋 초기화 중 오류 발생: {e}")
            self.dataset = Dataset.from_dict({"document": []})

    def _get_documents_sync(self, keys: Sequence[str]) -> List[Optional[Any]]:
        """실제 데이터 접근을 수행하는 동기 헬퍼 함수"""
        results = []
        for key in keys:
            try:
                idx = int(key)
                if idx in self.temp_dict:
                    results.append(self.temp_dict[idx])
                elif self.dataset and 0 <= idx < len(self.dataset):
                    document = self.dataset[idx].get("document")
                    results.append(document)
                else:
                    results.append(None)
            except (ValueError, IndexError):
                results.append(None)
        return results

    async def amget(self, keys: Sequence[str]) -> List[Optional[Any]]:
        """키 리스트에 대응하는 값들을 비동기적으로 반환합니다."""
        loop = asyncio.get_running_loop()
        # 동기 함수인 _get_documents_sync를 별도의 스레드에서 실행하고 결과를 기다립니다.
        # 이렇게 하면 이벤트 루프는 다른 작업을 계속 처리할 수 있습니다.
        results = await loop.run_in_executor(
            self.executor, self._get_documents_sync, keys
        )
        return results

    async def amset(self, key_value_pairs: Sequence[Tuple[str, Any]]) -> None:
        """키-값 쌍들을 비동기적으로 저장합니다."""
        await asyncio.sleep(0)  # 비동기 컨텍스트 유지
        
        for key, value in key_value_pairs:
            try:
                chunk_id = int(key)  # chunk_id (int)
                document = str(value)  # document (string)
                self.temp_dict[chunk_id] = document
            except ValueError:
                logging.warning(f"잘못된 키 형식: {key} (정수가 아님)")
                
        logging.info(f"{len(key_value_pairs)}개 항목이 임시 딕셔너리에 저장되었습니다.")

    async def amdelete(self, keys: Sequence[str]) -> None:
        """키들에 해당하는 항목들을 비동기적으로 삭제합니다."""
        await asyncio.sleep(0)  # 비동기 컨텍스트 유지
        
        deleted_count = 0
        for key in keys:
            try:
                idx = int(key)
                if idx in self.temp_dict:
                    del self.temp_dict[idx]
                    deleted_count += 1
            except ValueError:
                pass
                
        logging.info(f"{deleted_count}개 항목이 임시 딕셔너리에서 삭제되었습니다.")
    
    def get_item_by_key(self, key: str) -> Optional[Any]:
        """키로 직접 항목을 가져옵니다 (무지성 인덱싱)."""
        try:
            idx = int(key)
            
            # 1. 먼저 임시 딕셔너리에서 찾기
            if idx in self.temp_dict:
                return self.temp_dict[idx]
            # 2. 없으면 데이터셋에서 찾기
            elif 0 <= idx < len(self.dataset):
                return self.dataset[idx].get("document")
            else:
                return None
        except (ValueError, IndexError):
            return None
    
    def get_all_keys(self) -> List[str]:
        """모든 키(인덱스)를 반환합니다."""
        dataset_keys = [str(i) for i in range(len(self.dataset))] if self.dataset else []
        temp_keys = [str(k) for k in self.temp_dict.keys()]
        # 중복 제거하고 정렬
        all_keys = list(set(dataset_keys + temp_keys))
        return sorted(all_keys, key=int)
    
    def size(self) -> int:
        """저장된 항목 수를 반환합니다."""
        dataset_size = len(self.dataset) if self.dataset else 0
        temp_size = len(self.temp_dict)
        # 중복을 고려하여 계산
        dataset_indices = set(range(dataset_size))
        temp_indices = set(self.temp_dict.keys())
        total_unique = len(dataset_indices.union(temp_indices))
        return total_unique
    
    # 동기 메서드는 구현하지 않음
    def mget(self, *args, **kwargs):
        raise NotImplementedError("비동기 메서드 'amget'을 사용하세요.")
    def mset(self, *args, **kwargs):
        raise NotImplementedError("비동기 메서드 'amset'을 사용하세요.")
    def mdelete(self, *args, **kwargs):
        raise NotImplementedError("비동기 메서드 'amdelete'을 사용하세요.")
    def yield_keys(self, *args, **kwargs):
        raise NotImplementedError("비동기 메서드 'ayield_keys'를 구현해야 합니다.")
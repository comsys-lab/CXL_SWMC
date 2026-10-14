from typing import Any, List, Optional, Sequence, Tuple
import asyncio
from langchain_core.stores import BaseStore
from langchain_community.storage import SQLStore
from sqlalchemy.ext.asyncio import create_async_engine

## SQLStore를 이용해서 비동기 datastore 구현

class AsyncSQLiteStore(BaseStore[str, Any]):
    """
    SQLite 데이터베이스를 사용하여 비동기적으로 작동하는 키-값 저장소.
    """
    def __init__(self, namespace: str, db_path: str):
        self.namespace = namespace
        self.db_path = db_path
        self.sql_store = SQLStore(namespace=self.namespace, db_url=f"sqlite+aiosqlite:///{self.db_path}", async_mode=True)
        # self.sql_store = None

    async def initialize(self):
        """SQLStore를 비동기 모드로 초기화합니다."""

    async def amget(self, keys: Sequence[str]) -> List[Optional[Any]]:
        """주어진 키 목록에 대해 비동기적으로 값을 가져옵니다."""
        try: 
            retrieved_docs = await self.sql_store.amget(keys)
            # 필요시 디코딩 처리
            decoded_docs = [doc.decode("utf-8") for doc in retrieved_docs]
            return decoded_docs
        except Exception as e:
            # 오류 처리 로깅
            return [None] * len(keys)

    async def amset(self, items: Sequence[Tuple[str, str]]) -> None:
        """주어진 키-값 쌍 목록에 대해 비동기적으로 값을 설정합니다."""
        ## str를 bytes로 인코딩
        encoded_items = [(key, value.encode("utf-8")) for key, value in items]
        await self.sql_store.amset(encoded_items)

    async def amdelete(self, keys: Sequence[str]) -> None:
        """주어진 키 목록에 대해 비동기적으로 값을 삭제합니다."""
        await self.sql_store.amdelete(keys)

    def mget(self, key: str) -> Optional[Any]:
        """동기적으로 값을 가져오는 메서드 (비동기 환경에서는 사용하지 않음)."""
        raise NotImplementedError("Use mget for asynchronous retrieval.")
    def mset(self, key: str, value: Any) -> None:
        """동기적으로 값을 설정하는 메서드 (비동기 환경에서는 사용하지 않음)."""
        raise NotImplementedError("Use mset for asynchronous setting.")
    def mdelete(self, key: str) -> None:
        """동기적으로 값을 삭제하는 메서드 (비동기 환경에서는 사용하지 않음)."""
        raise NotImplementedError("Use mdelete for asynchronous deletion.")
    def yield_keys(self, *args, **kwargs):
        raise NotImplementedError("비동기 메서드 'ayield_keys'를 구현해야 합니다.")
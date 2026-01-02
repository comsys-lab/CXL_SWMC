import aiohttp
import asyncio
import logging
from asyncio import Queue
from typing import Any, List

from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings
from langchain_core.vectorstores import VectorStore

class AsyncCppVectorDBStore(VectorStore):
    """
    비동기적으로 C++ 벡터 DB 서버와 통신하는 VectorStore 클래스.
    고성능을 위해 세션 풀을 사용합니다 (초당 1000+ 요청 대응).
    """
    def __init__(self, base_url: str, embedding_function, max_sessions: int = 15):
        self.base_url = base_url
        self._embedding_function = embedding_function
        self.session_pool = Queue(maxsize=max_sessions)
        self.max_sessions = max_sessions
        self._initialized = False

    def _create_new_session(self) -> aiohttp.ClientSession:
        """새로운 aiohttp 클라이언트 세션을 생성합니다."""
        connector = aiohttp.TCPConnector(
            limit_per_host=30,
            ttl_dns_cache=300,
            use_dns_cache=True,
            keepalive_timeout=60,
            enable_cleanup_closed=True
        )
        timeout = aiohttp.ClientTimeout(total=30, connect=5)
        return aiohttp.ClientSession(
            connector=connector,
            timeout=timeout,
            headers={"Content-Type": "application/json"}
        )

    async def initialize(self):
        """세션 풀 초기화"""
        if self._initialized:
            return
            
        for _ in range(self.max_sessions):
            session = self._create_new_session()
            await self.session_pool.put(session)
        
        self._initialized = True
        logging.info(f"Vector DB 세션 풀 초기화 완료: {self.max_sessions}개 세션")

    async def _get_session(self):
        """세션 풀에서 세션 가져오기"""
        if not self._initialized:
            await self.initialize()
        return await self.session_pool.get()

    async def _return_session(self, session):
        """세션을 풀에 반환"""
        if not session.closed:
            await self.session_pool.put(session)

    @property
    def embeddings(self) -> Embeddings:
        return self._embedding_function

    async def _asimilarity_search_by_vector(
        self, embedding: List[float], k: int = 4, **kwargs: Any
    ) -> List[Document]:
        """
        비동기적으로 벡터 검색을 수행하는 핵심 메서드.
        에러 발생 시 세션을 교체하여 안정성을 높입니다.
        """
        search_url = f"{self.base_url}/api/search"
        payload = {"vector": embedding, "k": k}
        
        session = await self._get_session()
        try:
            async with session.post(search_url, json=payload) as response:
                response.raise_for_status()
                response_data = await response.json()
            
            # 요청 성공 시, 세션을 풀에 반환
            await self._return_session(session)

            if not response_data.get("success"):
                logging.warning(f"Vector DB API 응답 실패: {response_data}")
                return []

            results = response_data.get("data", {}).get("results", [])
            
            documents = [
                Document(page_content="", metadata={"id": str(res.get("id"))})
                for res in results
            ]
            return documents
            
        except aiohttp.ClientError as e:
            logging.error(f"Vector DB API 호출 중 에러 발생: {e}. 세션을 교체합니다.")
            
            # 1. 기존 세션을 닫습니다. (재사용 방지)
            if not session.closed:
                await session.close()
            
            # 2. 새로운 세션을 만들어 풀에 추가합니다. (풀 크기 유지)
            new_session = self._create_new_session()
            await self.session_pool.put(new_session)
            
            return []
        # finally 블록은 이제 필요 없습니다. 성공/실패 경로에서 각각 처리하기 때문입니다.

    async def asimilarity_search(
        self, query: str, k: int = 4, **kwargs: Any
    ) -> List[Document]:
        """
        텍스트 쿼리를 받아 비동기적으로 벡터로 변환 후 검색합니다.
        """
        
        # print(f"쿼리: {query}")
        # 임베딩 함수의 비동기 메서드 'aembed_query'를 호출합니다.
        query_embedding = await self._embedding_function.aembed_query(query)

        # print(f"쿼리 임베딩: {query_embedding}")
        
        return await self._asimilarity_search_by_vector(query_embedding, k, **kwargs)

    # 동기 메서드들은 사용하지 않으므로 에러를 발생시킵니다.
    def similarity_search(self, *args, **kwargs):
        raise NotImplementedError("이 클래스는 비동기 실행만 지원합니다. 'asimilarity_search'를 사용하세요.")

    def add_texts(self, *args, **kwargs):
        raise NotImplementedError("데이터 추가는 별도의 로더를 통해 C++ DB에 직접 수행해야 합니다.")
    
    @classmethod
    def from_texts(
        cls,
        texts: List[str],
        embedding: Embeddings,
        metadatas: List[dict] = None,
        **kwargs: Any,
    ):
        """
        텍스트로부터 VectorStore를 생성하는 클래스 메서드.
        이 구현에서는 C++ DB가 별도로 관리되므로 실제로는 사용하지 않습니다.
        """
        raise NotImplementedError("이 클래스는 사전에 구축된 C++ DB를 사용합니다. from_texts는 지원하지 않습니다.")
    
    async def close_session(self):
        """모든 세션 풀의 세션들을 정리합니다."""
        sessions_to_close = []
        while not self.session_pool.empty():
            try:
                session = self.session_pool.get_nowait()
                sessions_to_close.append(session)
            except asyncio.QueueEmpty:
                break
        
        for session in sessions_to_close:
            if not session.closed:
                await session.close()
        
        logging.info(f"Vector DB 세션 풀 정리 완료: {len(sessions_to_close)}개 세션")
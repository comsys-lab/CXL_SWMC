from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
from langchain_openai import ChatOpenAI
import uvicorn
import os
import asyncio
from asyncio import Queue
from datasets import load_dataset
import numpy as np
# argparse는 더 이상 필요 없으므로 제거합니다.
# import argparse 
import logging

# Retrieval 관련 imports
from langchain.retrievers import MultiVectorRetriever
from langchain_core.embeddings import Embeddings
from async_custom_vectorstore import AsyncCppVectorDBStore
from async_sqlite_store import AsyncSQLiteStore
from sqlalchemy.ext.asyncio import create_async_engine
import aiohttp
import json

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# ===> 이 부분이 변경됩니다 <===
# 0. 환경 변수로부터 데이터셋 이름을 읽어와서 PDF 생성
# os.getenv("APP_DATASET", None)은 APP_DATASET이라는 환경 변수를 읽고, 없으면 None을 반환합니다.
dataset_name =  os.getenv("APP_DATASET", None)
BINS = 100 # 히스토그램 구간 수

CONCURRENCY_LIMIT = 400 
semaphore = asyncio.Semaphore(CONCURRENCY_LIMIT)

if dataset_name:
    try:
        logging.info(f"Hugging Face에서 데이터셋 '{dataset_name}'을 로드합니다.")
        dataset = load_dataset(dataset_name, split='train', streaming=True)
        answers = [item['text'] for item in dataset if 'text' in item and item['text']]
        if not answers:
            raise ValueError("데이터셋에서 유효한 답변을 찾을 수 없습니다.")
        logging.info(f"로드된 답변 수: {len(answers)}")
        
        token_lengths = [len(str(answer).split()) for answer in answers]
        pdf, _ = np.histogram(token_lengths, bins=BINS, density=True)
        pdf = pdf / pdf.sum()
        
        logging.info(f"Output token length PDF가 생성되었습니다 (첫 10개): {pdf[:10]}")
        
    except Exception as e:
        logging.error(f"데이터셋 처리 중 오류 발생: {e}. 기본 분포를 사용합니다.")
        pdf = np.ones(BINS) / BINS
else:
    logging.info("APP_DATASET 환경 변수가 지정되지 않았습니다. 기본 균등 분포를 사용합니다.")
    pdf = np.ones(BINS) / BINS

# 1. vLLM 서버 정보 설정 (이하 모든 코드는 기존과 동일)
VLLM_BASE_URL = "http://localhost:8000/v1"
os.environ["OPENAI_API_KEY"] = "EMPTY"

# 2. LangChain 모델 정의
llm = ChatOpenAI(
    base_url=VLLM_BASE_URL,
    model="meta-llama/Llama-3.1-8B-Instruct",
    temperature=0.7,
    max_tokens=2048,
    streaming=True
)

# # 2-1. 커스텀 TEI 임베딩 클래스
# class TEIEmbeddings(Embeddings):
#     """Text Embeddings Inference (TEI) 서버와 통신하는 임베딩 클래스"""
    
#     def __init__(self, endpoint_url: str):
#         self.endpoint_url = endpoint_url.rstrip('/')
#         self.session = None  # __init__에서는 None으로 설정

#     async def initialize(self):
#         """이벤트 루프가 시작된 후 세션을 생성합니다."""
#         if self.session is None:
#             connector = aiohttp.TCPConnector(limit=0)
#             self.session = aiohttp.ClientSession(connector=connector)

#     async def close_session(self):
#         """애플리케이션 종료 시 세션을 닫기 위한 메서드"""
#         if not self.session.closed:
#             await self.session.close()
        
#     def embed_documents(self, texts: list[str]) -> list[list[float]]:
#         """동기 버전 - 사용하지 않음"""
#         raise NotImplementedError("Use aembed_documents instead")
        
#     def embed_query(self, text: str) -> list[float]:
#         """동기 버전 - 사용하지 않음"""
#         raise NotImplementedError("Use aembed_query instead")
        
#     async def aembed_documents(self, texts: list[str]) -> list[list[float]]:
#         """비동기적으로 여러 텍스트를 임베딩"""
#         if not self.session:
#             raise RuntimeError("Session not initialized. Call initialize() first.")
#         # self.session을 재사용
#         async with self.session.post(
#             f"{self.endpoint_url}/embed",
#             json={"inputs": texts},
#             headers={"Content-Type": "application/json"}
#         ) as response:
#             if response.status == 200:
#                 return await response.json()
#             else:
#                 raise Exception(f"TEI 서버 오류: {response.status}")
                    
#     async def aembed_query(self, text: str) -> list[float]:
#         """비동기적으로 단일 텍스트를 임베딩"""
#         embeddings = await self.aembed_documents([text])
#         return embeddings[0]
class TEIEmbeddings(Embeddings):
    """고성능 TEI 임베딩 클래스 (초당 1000+ 요청 대응)"""
    
    def __init__(self, endpoint_url: str, max_sessions: int = 20):
        self.endpoint_url = endpoint_url.rstrip('/')
        self.session_pool = Queue(maxsize=max_sessions)
        self.max_sessions = max_sessions
        self._initialized = False

    async def initialize(self):
        """세션 풀 초기화"""
        if self._initialized:
            return
            
        for _ in range(self.max_sessions):
            connector = aiohttp.TCPConnector(
                limit_per_host=50,  # 호스트당 최대 연결 수
                ttl_dns_cache=300,  # DNS 캐시 TTL
                use_dns_cache=True,
                keepalive_timeout=60,  # Keep-alive 타임아웃
                enable_cleanup_closed=True
            )
            timeout = aiohttp.ClientTimeout(total=30, connect=5)
            session = aiohttp.ClientSession(
                connector=connector,
                timeout=timeout,
                headers={"Content-Type": "application/json"}
            )
            await self.session_pool.put(session)
        
        self._initialized = True
        logging.info(f"TEI 세션 풀 초기화 완료: {self.max_sessions}개 세션")

    async def _get_session(self):
        """세션 풀에서 세션 가져오기"""
        return await self.session_pool.get()

    async def _return_session(self, session):
        """세션을 풀에 반환"""
        if not session.closed:
            await self.session_pool.put(session)

    async def close_session(self):
        """모든 세션 정리"""
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
        
        logging.info(f"TEI 세션 풀 정리 완료: {len(sessions_to_close)}개 세션")

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        raise NotImplementedError("Use aembed_documents instead")
        
    def embed_query(self, text: str) -> list[float]:
        raise NotImplementedError("Use aembed_query instead")

    async def aembed_documents(self, texts: list[str]) -> list[list[float]]:
        """고성능 비동기 임베딩 (세션 풀 사용)"""
        if not self._initialized:
            await self.initialize()
            
        session = await self._get_session()
        try:
            async with session.post(
                f"{self.endpoint_url}/embed",
                json={"inputs": texts}
            ) as response:
                if response.status == 200:
                    result = await response.json()
                    return result
                else:
                    error_text = await response.text()
                    raise Exception(f"TEI 서버 오류 {response.status}: {error_text}")
        finally:
            await self._return_session(session)

    async def aembed_query(self, text: str) -> list[float]:
        """단일 텍스트 임베딩"""
        embeddings = await self.aembed_documents([text])
        return embeddings[0]

# 2-2. Retrieval 시스템 초기화
TEI_ENDPOINT_URL = "http://localhost:8081"
CPP_DB_URL_1 = "http://163.152.48.209:8080"
CPP_DB_URL_2 = "http://163.152.48.209:8081"
DATASET_PATH = os.getenv("DOC_DATASET_PATH", None)  # 환경 변수로 데이터셋 경로 지정
DATASET_NAME = os.getenv("DOC_DATASET_NAME", None)  # 또는 HF Hub 데이터셋 이름
SQLITE_DB_PATH = os.getenv("SQLITE_DB_PATH", "documents.db")  # SQLite DB 파일 경로
SQLITE_NAMESPACE = os.getenv("SQLITE_NAMESPACE", "default_namespace")  # 네임스페이스

# 임베딩 모델
tei_embeddings = TEIEmbeddings(endpoint_url=TEI_ENDPOINT_URL)

# 비동기 벡터 스토어
vector_store_1 = AsyncCppVectorDBStore(
    base_url=CPP_DB_URL_1,
    embedding_function=tei_embeddings
)

vector_store_2 = AsyncCppVectorDBStore(
    base_url=CPP_DB_URL_2,
    embedding_function=tei_embeddings
)


logging.info(f"Using namespace: {SQLITE_NAMESPACE}")
logging.info(f"SQLite DB Path: {SQLITE_DB_PATH}")
doc_store = AsyncSQLiteStore(namespace=SQLITE_NAMESPACE, db_path=SQLITE_DB_PATH)

# async def test_doc_store():
#     retrieved_docs = await doc_store.amget(["1", "2", "3"])
#     logging.info(f"amget: Fetched {len(retrieved_docs)} documents from doc_store.")
#     logging.info(f"amget: Type of first fetched doc: {type(retrieved_docs[0]) if retrieved_docs else 'N/A'}")
#     logging.info(f"amget: First fetched doc content (first 500 chars): {retrieved_docs[0][:500] if retrieved_docs and retrieved_docs[0] else 'N/A'}")

# # 아래처럼 호출해야 await가 정상 동작합니다.
# asyncio.run(test_doc_store())

# # namespace = SQLITE_DB_PATH.split("/")[-1]
# logging.info(f"Using namespace: {SQLITE_NAMESPACE}")
# logging.info(f"SQLite DB Path: {SQLITE_DB_PATH}")
# doc_store = SQLStore(namespace=SQLITE_NAMESPACE, db_url=f"sqlite:///{SQLITE_DB_PATH}")

# retrieved_docs = doc_store.mget([str(1), str(2), str(3)])
# logging.info(f"mget: Fetched {len(retrieved_docs)} documents from doc_store.")
# logging.info(f"mget: Type of first fetched doc: {type(retrieved_docs[0]) if retrieved_docs else 'N/A'}")
# decoded_docs = [doc.decode("utf-8") if isinstance(doc, bytes) else doc for doc in retrieved_docs]
# logging.info(f"mget: Type of first fetched doc after decode: {type(decoded_docs[0]) if decoded_docs else 'N/A'}")
# logging.info(f"mget: First fetched doc content (first 500 chars): {decoded_docs[0][:500] if decoded_docs else 'N/A'}")

# MultiVectorRetriever
retriever_1 = MultiVectorRetriever(
    vectorstore=vector_store_1,
    docstore=doc_store,
    id_key="id"
)

retriever_2 = MultiVectorRetriever(
    vectorstore=vector_store_2,
    docstore=doc_store,
    id_key="id"
)

# MultiVectorRetriever의 기본 검색 파라미터 설정
retriever_1.search_kwargs = {"k": 5}  # 5개 문서 검색
retriever_2.search_kwargs = {"k": 5}  # 5개 문서 검색

# 3. FastAPI 애플리케이션 생성
app = FastAPI()

# 애플리케이션 시작 이벤트
@app.on_event("startup")
async def startup_event():
    """애플리케이션 시작 시 데이터셋 저장소 초기화"""
    await tei_embeddings.initialize()
    await vector_store_1.initialize()
    await vector_store_2.initialize()


# 애플리케이션 종료 이벤트
@app.on_event("shutdown")
async def shutdown_event():
    """애플리케이션 종료 시 벡터 스토어 세션 정리"""
    await tei_embeddings.close_session() # 추가
    await vector_store_1.close_session()
    await vector_store_2.close_session()
    logging.info("벡터 스토어 세션이 정리되었습니다.")

# 4-1. RAG를 사용한 실제 vLLM 추론 스트림 생성기
async def real_stream_generator_with_rag(user_input: str, client_id: int = 0):
    latencies = {
        "embedding_latency": -1,
        "vectordb_latency": -1, 
        "document_latency": -1,
        "retrieval_latency": -1
    }
    
    try:
        # 1. Retrieval: 사용자 질문과 관련된 문서 검색
        # logging.info(f"문서 검색 중: {user_input}")
        start_time = asyncio.get_event_loop().time()
        retrieved_docs = await retriever_1.ainvoke(user_input)
        end_time = asyncio.get_event_loop().time()
        latencies["retrieval_latency"] = end_time - start_time
        # logging.info(f"문서 {len(retrieved_docs)}개 검색 완료 (소요 시간: {latencies['retrieval_latency']:.2f}s)")
        # logging.info(f"Retrieved {len(retrieved_docs)} documents.")
        # logging.info(retrieved_docs[:2])  # 첫 두 개 문서 내용 출력

        # 2. 검색된 문서들로 컨텍스트 구성
        context_parts = [f"Document {i+1}: {doc}" for i, doc in enumerate(retrieved_docs)]
        
        context = "\n\n".join(context_parts)
        
        # 3. RAG prompt construction (English)
        if context.strip():
            system_message = """You are a helpful AI assistant. Please answer the user's question based on the provided documents.
    If you cannot find the answer in the documents, respond using general knowledge."""
            user_message = f"""Refer to the following documents to answer the question:

    {context}

    Question: {user_input}"""
            # logging.info(f"Number of retrieved documents: {len(retrieved_docs)}")
        else:
            system_message = "You are a helpful assistant."
            user_message = user_input
            # logging.info("No documents retrieved, switching to general answer mode.")
        
        # 4. LLM 스트리밍 응답
        messages = [("system", system_message), ("user", user_message)]
        generated_tokens = 0
        # print("message의 token 수", len(system_message.split()) + len(user_message.split()))
        async for chunk in llm.astream(messages):
            if chunk.content:
                # 실제 토큰 개수를 단어 단위로 근사 계산
                generated_tokens += len(chunk.content.split())
                yield chunk.content
            
        # 응답 완료 후 latency 정보와 생성된 토큰 수를 함께 전송
        yield f"\n__LATENCIES__{latencies['embedding_latency']},{latencies['vectordb_latency']},{latencies['document_latency']},{latencies['retrieval_latency']},{generated_tokens}__END__"
            
    except Exception as e:
        logging.error(f"RAG 처리 중 오류 발생: {e}")
        # 오류 발생 시 기본 응답으로 fallback
        messages = [("system", "You are a helpful assistant."), ("user", user_input)]
        generated_tokens = 0
        async for chunk in llm.astream(messages):
            if chunk.content:
                generated_tokens += len(chunk.content.split())
                yield chunk.content
        # 오류 시에도 latency 정보 전송 (모두 -1)
        yield f"\n__LATENCIES__-1,-1,-1,-1,{generated_tokens}__END__"

# 4-2. 더미 응답 스트림 생성기 (Retrieval 포함)
async def dummy_stream_generator(user_input: str, client_id: int = 1):
    loop = asyncio.get_running_loop()
    full_request_start_time = loop.time()
    
    latencies = {
        "embedding_latency": -1,
        "vectordb_latency": -1, 
        "document_latency": -1,
        "retrieval_latency": -1
    }

    # === 1. 텍스트 임베딩 단계 및 시간 측정 ===
    try:
        # logging.info("[DUMMY] 1. 임베딩 시작...")
        embedding_start_time = loop.time()
        
        query_embedding = await tei_embeddings.aembed_query(user_input)
        
        embedding_end_time = loop.time()
        latencies["embedding_latency"] = embedding_end_time - embedding_start_time
        # logging.info(f"[DUMMY] 1. 임베딩 완료 (소요 시간: {latencies['embedding_latency']:.4f}s)")
        
        if not query_embedding:
            raise ValueError("임베딩 결과가 비어있습니다.")
            
    except Exception as e:
        logging.error(f"[DUMMY] 1. 임베딩 단계에서 오류 발생: {e}")
        # 임베딩 실패 시 더미 응답을 즉시 반환하고 종료
        yield "Embedding failed. "
        yield f"\n__LATENCIES__-1,-1,-1,-1,0__END__"
        return

    # === 2. 벡터 검색 단계 및 시간 측정 ===
    try:
        # logging.info("[DUMMY] 2. 벡터 검색 시작...")
        search_start_time = loop.time()
        
        # vector_store의 asimilarity_search_by_vector를 직접 호출
        if client_id % 2 == 0:
            id_docs = await vector_store_1._asimilarity_search_by_vector(query_embedding, k=5)
        else:
            id_docs = await vector_store_2._asimilarity_search_by_vector(query_embedding, k=5)
        
        search_end_time = loop.time()
        latencies["vectordb_latency"] = search_end_time - search_start_time
        # logging.info(f"[DUMMY] 2. 벡터 검색 완료 (소요 시간: {latencies['vectordb_latency']:.4f}s)")
        
        retrieved_ids = [doc.metadata["id"] for doc in id_docs]
        
    except Exception as e:
        logging.error(f"[DUMMY] 2. 벡터 검색 단계에서 오류 발생: {e}")
        yield "Vector search failed. "
        yield f"\n__LATENCIES__{latencies['embedding_latency']},-1,-1,-1,0__END__"
        return

    retrieved_docs = []
    # === 3. 문서 내용 검색 단계 및 시간 측정 ===
    try:
        # logging.info(f"[DUMMY] 3. 문서 내용 검색 시작 (ID 개수: {len(retrieved_ids)})...")
        doc_fetch_start_time = loop.time()
        
        retrieved_docs = await doc_store.amget(retrieved_ids)
        # logging.info(f"amget: Fetched {len(retrieved_docs)} documents from doc_store.")
        # logging.info(f"amget: Type of first fetched doc: {type(retrieved_docs[0]) if retrieved_docs else 'N/A'}")

        doc_fetch_end_time = loop.time()
        latencies["document_latency"] = doc_fetch_end_time - doc_fetch_start_time
        # logging.info(f"[DUMMY] 3. 문서 내용 검색 완료 (소요 시간: {latencies['document_latency']:.4f}s)")
        
        # None 값을 필터링
        retrieved_docs = [doc for doc in retrieved_docs if doc is not None]

        
    except Exception as e:
        logging.error(f"[DUMMY] 3. 문서 내용 검색 단계에서 오류 발생: {e}")
        yield "Document fetching failed. "
        yield f"\n__LATENCIES__{latencies['embedding_latency']},{latencies['vectordb_latency']},-1,-1,0__END__"
        return


    full_request_end_time = loop.time()
    latencies["retrieval_latency"] = full_request_end_time - full_request_start_time
    # logging.info(f"[DUMMY] 전체 RAG 파이프라인 완료 (총 소요 시간: {latencies['retrieval_latency']:.4f}s)")
    
    # (이하 더미 응답 생성 로직은 기존과 동일)
    context_parts = [f"Document {i+1}: {content}" for i, content in enumerate(retrieved_docs)]
    # context_parts = [f"Document {i+1}: {content.decode("utf-8")}" for i, content in enumerate(retrieved_docs)]
    context = "\n\n".join(context_parts)
    
    # 4. RAG prompt construction (English)
    if context.strip():
        system_message = """You are a helpful AI assistant. Please answer the user's question based on the provided documents.
If you cannot find the answer in the documents, respond using general knowledge."""
        user_message = f"""Refer to the following documents to answer the question:

{context}

Question: {user_input}"""
        # logging.info(f"Number of retrieved documents: {len(retrieved_docs)}")
    else:
        system_message = "You are a helpful assistant."
        user_message = user_input
        # logging.info("No documents retrieved, switching to general answer mode.")

    full_prompt = f"{system_message}\n\n{user_message}"
    input_token_count = len(full_prompt.split())
    # logging.info(f"[DUMMY] 전체 프롬프트 토큰 수: {input_token_count}")


    # 5. 더미 응답 생성 (실제 input 토큰 수 반영)
    # prefill_time_per_token
    #     = model weights per GPU / accelerator compute capabilty
    #     = (8B prams * 2) FLOP  / 82.58 TFLOP/s
    #     = 0.193 ms for llama-3.1-8b on GTX 4090
    # generation_time_per_token 
    #     = number of bytes moved (the model weights) per GPU ÷ accelerator memory bandwidth
    #     = (8B prams × 2) Bytes ÷ 1010 GB/s 
    #     = 15.8 ms for llama-3.1-8b on GTX 4090
    # https://blogs.vmware.com/cloud-foundation/2024/09/25/llm-inference-sizing-and-performance-guidance/

    prefill_time_per_token = 0.193e-3
    generation_time_per_token = 15.8e-3

    random_bin_index = np.random.choice(np.arange(BINS), p=pdf)
    dummy_generation_length = random_bin_index 
    
    # 실제 RAG prompt의 토큰 수로 TTFT 계산
    dummy_TTFT = input_token_count * prefill_time_per_token
    dummy_generation_latency = dummy_generation_length * generation_time_per_token
    start_time = loop.time()

    await asyncio.sleep(dummy_TTFT)

    end_time = loop.time()
    # logging.info(f"[DUMMY] 실제 TTFT: {end_time - start_time:.4f}s (예상: {dummy_TTFT:.4f}s)")

    start_time = loop.time()
    
    dummy_chunks = ["ComSys", "will", "be", "the", "best", "!"]
    
    yield dummy_chunks[0] + " "
    await asyncio.sleep(generation_time_per_token)
    # yield 나머지 더미 응답을 한 번에 반환
    full_dummy_response = " ".join([dummy_chunks[i % len(dummy_chunks)] for i in range(dummy_generation_length - 1)]) + " "
    await asyncio.sleep(dummy_generation_latency)
    yield full_dummy_response
    
    # 실제 생성된 토큰 수 계산 (dummy_generation_length 사용)
    actual_generated_tokens = dummy_generation_length
    
    # latency 정보와 생성된 토큰 수를 응답 마지막에 추가
    yield f"\n__LATENCIES__{latencies['embedding_latency']},{latencies['vectordb_latency']},{latencies['document_latency']},{latencies['retrieval_latency']},{actual_generated_tokens}__END__"
    
    end_time = loop.time()
    # logging.info(f"[DUMMY] 실제 생성 지연: {end_time - start_time:.4f}s (예상: {dummy_generation_latency:.4f}s)")

# 5. API 엔드포인트
@app.post("/chat")
async def chat_endpoint(request: Request):
    async with semaphore:
        body = await request.json()
        user_input = body.get("user_input", "")
        client_id = body.get("client_id", 0)

        if not user_input:
            return {"error": "user_input is required"}, 400

        if client_id == 0:
            # 실제 LLM 사용 (항상 RAG 포함)
            generator = real_stream_generator_with_rag(user_input, client_id)
        else:
            # 더미 응답 사용 (RAG 포함)
            generator = dummy_stream_generator(user_input, client_id)

        return StreamingResponse(generator, media_type="text/plain")

# 6. 서버 실행 (개발용)
if __name__ == "__main__":
    # `python main.py`로 실행할 때도 환경 변수를 인식할 수 있습니다.
    uvicorn.run(app, host="0.0.0.0", port=9000)
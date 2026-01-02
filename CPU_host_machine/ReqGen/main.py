import asyncio
import time
import argparse
import random
import numpy as np
import aiohttp
from datasets import load_dataset
import logging

# 로깅 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# 랜덤 시드
# random.seed(42)
# np.random.seed(42)

class ReqGen:
    def __init__(self, args):
        self.host = args.host
        self.port = args.port
        self.num_clients = args.num_clients
        self.duration = args.duration
        self.zipf_param = args.zipf
        self.dataset_name = args.dataset
        self.server_url = f"http://{self.host}:{self.port}/chat"
        self.read_write_ratio = args.read_write  # 읽기/쓰기 비율
        
        self.questions = self._load_questions()
        self.results = []
        self.requests_completed = 0
        self.requests_failed = 0
        self.start_time = None
        self.last_report_count = 0
        self.lock = asyncio.Lock()
        self.slo = args.slo 
        self.stop_test = False  # 조기 종료 플래그
        self.statistics_start_index = 0  # 통계 집계 시작 인덱스
        self.statistics_end_index = -1    # 통계 집계 종료 인덱스
        self.checked_slo_violation = False  # SLO 위반 여부 체크 플래그
        self.statistics_start_time = None  # 통계 집계 시작 시간
        self.statistics_end_time = None    # 통계 집계 종료 시간
        self.slo_violation = False  # SLO 위반으로 인한 조기 종료 여부

        # Latency 통계를 위한 리스트들
        self.embedding_latencies = []
        self.vectordb_latencies = []
        self.document_latencies = []
        self.retrieval_latencies = []

    def _load_questions(self):
        """질문 데이터셋을 로드하거나, 없을 경우 기본 질문을 생성합니다."""
        # self.dataset_name이 None이나 빈 문자열이 아니면 데이터셋 로드 시도
        if self.dataset_name:
            try:
                logging.info(f"Hugging Face에서 '{self.dataset_name}' 데이터셋을 로드합니다...")
                dataset = load_dataset(self.dataset_name, split='train', streaming=True)
                questions = [item['question'] for item in dataset.take(5000) if 'question' in item and item['question']]
                ## dataset을 random하게 shuffle 함.
                random.shuffle(questions)
                if not questions:
                    raise ValueError("데이터셋에서 유효한 질문을 찾을 수 없습니다.")
                logging.info(f"{len(questions)}개의 질문을 로드했습니다.")
                return questions
            except Exception as e:
                logging.error(f"데이터셋 로드 실패: {e}. 기본 질문 생성기(수도 묻기)로 대체합니다.")
                return self._generate_default_questions()
        else:
            logging.info("데이터셋이 지정되지 않았습니다. 기본 질문 생성기(수도 묻기)를 사용합니다.")
            return self._generate_default_questions()

    def _generate_default_questions(self):
        """각 나라의 수도를 묻는 무작위 질문을 생성합니다."""
        capitals = {
            "South Korea": "Seoul", "United States": "Washington, D.C.", "Japan": "Tokyo",
            "China": "Beijing", "United Kingdom": "London", "France": "Paris",
            "Germany": "Berlin", "Canada": "Ottawa", "Australia": "Canberra", "Russia": "Moscow"
        }
        return [f"What is the capital of {country}?" for country in capitals.keys()]

    def _calculate_pareto_percentage(self, a):
        """
        주어진 'a' 값과 전체 아이템 수에 대해,
        상위 20% 아이템이 차지하는 확률의 총합(비중)을 계산합니다.
        """
        total_items = len(self.questions)
        if a <= 1:
            # NumPy의 zipf 함수 제약 조건을 따름
            # 실제로는 이 경우도 의미가 있지만, 여기서는 NumPy 기준에 맞춤
            return 0

        # 1. 각 아이템(랭킹 k)의 가중치(weight)를 계산합니다. (1/k^a)
        # 랭킹은 1부터 시작하므로 range(1, total_items + 1) 사용
        ranks = np.arange(1, total_items + 1)
        weights = 1.0 / (ranks**a)
        
        # 2. 전체 가중치의 합으로 나누어 각 아이템이 뽑힐 확률을 구합니다.
        total_weight = np.sum(weights)
        probabilities = weights / total_weight
        
        # 3. 상위 20% 아이템의 개수를 계산합니다.
        num_top_items = int(total_items * 0.2)
        
        # 4. 상위 20% 아이템들의 확률을 모두 더합니다.
        # 배열 슬라이싱을 사용하여 상위 아이템들의 확률을 가져옴
        percentage = np.sum(probabilities[:num_top_items])
        
        return percentage * 100

    async def _run_client(self, session, client_id):
        """개별 클라이언트의 요청-응답-대기 사이클을 실행합니다."""
        # logging.info(f"클라이언트 {client_id} 시작")
        # 10초 동안 client_id에 비례한 초기 지연을 줍니다.
        initial_delay = client_id * 20 / self.num_clients
        await asyncio.sleep(initial_delay)
        
        while time.monotonic() - self.start_time < self.duration:
            # print(f"self.zipf_param: {self.zipf_param}, len(self.questions): {len(self.questions)}")
            # question_idx = np.random.zipf(self.zipf_param) % len(self.questions)
            
            # uniform distribution
            question_idx = random.randint(0, len(self.questions) - 1)

            # logging.info(f"클라이언트 {client_id} 요청: 질문 인덱스 {question_idx}")
            question = self.questions[question_idx]

            req_start_time = time.monotonic()
            first_token_time = None
            response_end_time = None
            # received_chunks = 0
            response_content = ""

            try:
                async with session.post(self.server_url, json={"client_id": client_id, "user_input": question}) as response:
                    response.raise_for_status()
                    async for chunk in response.content.iter_any():
                        if chunk:
                            if first_token_time is None:
                                first_token_time = time.monotonic()
                            # received_chunks += 1
                            response_content += chunk.decode('utf-8', errors='ignore')
                    response_end_time = time.monotonic()

            except asyncio.TimeoutError:
                # logging.warning(f"클라이언트 {client_id}: 요청 타임아웃")
                async with self.lock:
                    self.requests_failed += 1
                continue
            except aiohttp.ClientError as e:
                # logging.warning(f"요청 실패: {e}")
                async with self.lock:
                    self.requests_failed += 1
                # await asyncio.sleep(1)
                continue

            if first_token_time and response_end_time:
                # print(f"Response Content: {response_content}")
                ttft = first_token_time - req_start_time
                total_time = response_end_time - req_start_time
                # tpot = (response_end_time - first_token_time) / (received_chunks - 1) if received_chunks > 1 else 0
                
                # latency 정보 파싱
                embedding_latency = -1
                vectordb_latency = -1
                document_latency = -1
                retrieval_latency = -1
                generated_tokens = 0
                
                if "__LATENCIES__" in response_content and "__END__" in response_content:
                    try:
                        start_marker = response_content.find("__LATENCIES__") + len("__LATENCIES__")
                        end_marker = response_content.find("__END__")
                        latency_data = response_content[start_marker:end_marker]
                        latencies = latency_data.split(',')
                        if len(latencies) == 5:  # embedding, vectordb, document, retrieval, generated_tokens
                            embedding_latency = float(latencies[0])
                            vectordb_latency = float(latencies[1])
                            document_latency = float(latencies[2])
                            retrieval_latency = float(latencies[3])
                            generated_tokens = int(latencies[4])
                    except (ValueError, IndexError) as e:
                        logging.warning(f"Latency 정보 파싱 실패: {e}")

                # TPOT 계산 - 실제 생성된 토큰 수 사용
                if generated_tokens > 0 and response_end_time and first_token_time:
                    tpot = (response_end_time - first_token_time) / generated_tokens
                else:
                    tpot = 0

                # print(f"Tpot: {tpot * 1000:.4f} ms/token, Generated Tokens: {generated_tokens}, (response_end_time - first_token_time): {response_end_time - first_token_time:.8f}s")

                async with self.lock:
                    self.results.append({"ttft": ttft, "tpot": tpot})
                    # latency 정보 추가 (-1이 아닌 경우만 리스트에 추가)
                    if embedding_latency >= 0:
                        self.embedding_latencies.append(embedding_latency)
                    if vectordb_latency >= 0:
                        self.vectordb_latencies.append(vectordb_latency)
                    if document_latency >= 0:
                        self.document_latencies.append(document_latency)
                    if retrieval_latency >= 0:
                        self.retrieval_latencies.append(retrieval_latency)
                        
                    self.requests_completed += 1
                    
                    if self.requests_completed // 1000 > self.last_report_count // 1000:
                        self._print_realtime_report()
                        self.last_report_count = self.requests_completed


                wait_interval = generated_tokens * 0.200
                # wait_interval = generated_tokens * 0.002
                await asyncio.sleep(wait_interval)
                if self.stop_test:
                    # logging.info(f"조기 종료 플래그 감지, {client_id} 정지.")
                    break

    def _print_realtime_report(self):
        """100개의 요청마다 실시간 성능 지표를 출력합니다."""
        recent_ttfts = [r['ttft'] for r in self.results[-1000:]]
        if not recent_ttfts:
            return
            
        p99_ttft = np.percentile(recent_ttfts, 99)
        
        elapsed_time = time.monotonic() - self.start_time
        current_rps = self.requests_completed / elapsed_time if elapsed_time > 0 else 0
        
        logging.info(
            f"[실시간] 요청 {self.requests_completed}개 처리 | "
            f"현재까지의 RPS: {current_rps:.2f}"
            f"최근 1000개 request의 p99 TTFT: {p99_ttft:.4f} 초 | "
        )

        # ## 초반 10초의 통계는 버림
        if not self.statistics_start_time:
            if elapsed_time >= 10:
                self.statistics_start_index = self.requests_completed
                self.statistics_start_time = time.monotonic()
        
        ## duration 까지만 실험 결과 반영 (실제 실험 시간 = duration - 60초)
        if elapsed_time >= self.duration and not self.stop_test:
            self.stop_test = True
            self.statistics_end_time = time.monotonic()
            self.statistics_end_index = self.requests_completed  # 통계 집계 종료 인덱스 설정

        ## 최근 1000개의 ttft가 slo를 초과하면, 조기종료하고. self.slo_violation = True로 설정.
        if not self.stop_test and not self.slo_violation:
            if p99_ttft > self.slo * 4:
                logging.warning(f"최근 1000개의 p99 TTFT {p99_ttft:.4f} 초가 SLO 의 4배 ({self.slo * 4} 초)를 초과했습니다. 부하 테스트를 조기 종료합니다.")
                self.stop_test = True
                self.statistics_end_index = self.requests_completed  # 통계 집계 종료 인덱스 설정
                self.statistics_end_time = time.monotonic()
                self.slo_violation = True

        # # 60초가 지났을 때, 전체 p99 TTFT가 SLO를 초과하는지 확인하고, 그렇다면 조기 종료
        # if not self.checked_slo_violation and elapsed_time >= 60:
        #     self.checked_slo_violation = True  # 한 번만 체크
        #     total_p99_ttft = np.percentile([r['ttft'] for r in self.results], 99)
        #     if p99_ttft > self.slo:
        #         logging.warning(f"최근 1000개의 p99 TTFT {p99_ttft:.4f} 초가 SLO {self.slo} 초를 초과했습니다. 부하 테스트를 조기 종료합니다.")
        #         self.stop_test = True
        #         self.statistics_end_index = self.requests_completed  # 통계 집계 종료 인덱스 설정
        #     else:
        #         logging.info(f"최근 1000개의 p99 TTFT {total_p99_ttft:.4f} 초가 SLO {self.slo} 초 이내입니다. 테스트를 계속 진행합니다.")
        #         # 이후 값부터 통계에 반영됨.
        #         self.statistics_start_index = self.requests_completed
        #         self.statistics_start_time = time.monotonic()


    def _print_final_summary(self):
        """실험 종료 후 최종 성능 요약을 출력합니다."""
        if not self.results:
            logging.warning("처리된 요청이 없어 최종 결과를 출력할 수 없습니다.")
            return

        # 통계 집계 시작 인덱스와 종료 인덱스를 기준으로 결과 필터링
        start_index = self.statistics_start_index if self.statistics_start_index >= 0 else 0
        end_index = self.statistics_end_index if self.statistics_end_index >= 0 else len(self.results)

        print(f"통계에 반영된 요청 인덱스 범위: {start_index} ~ {end_index} (총 {end_index - start_index}개 요청)")

        self.results = self.results[start_index:end_index]
        self.requests_completed = len(self.results)
        self.requests_failed = self.requests_failed  # 실패한 요청 수는 변하지 않음
        retrieval_success_count = len(self.retrieval_latencies)
        self.embedding_latencies = self.embedding_latencies[start_index:end_index]
        self.vectordb_latencies = self.vectordb_latencies[start_index:end_index]
        self.document_latencies = self.document_latencies[start_index:end_index]
        self.retrieval_latencies = self.retrieval_latencies[start_index:end_index]

        ttfts = np.array([r['ttft'] for r in self.results])
        tpots = np.array([r['tpot'] for r in self.results if r['tpot'] > 0])

        if (self.statistics_start_time is None):
            print("statistics_start_time이 설정되지 않았습니다.")
        if (self.statistics_end_time is None):
            print("statistics_end_time이 설정되지 않았습니다.")
        
        final_duration = self.statistics_end_time - self.statistics_start_time if self.statistics_start_time and self.statistics_end_time else (time.monotonic() - self.start_time)
        statistics_requests_num = end_index - start_index
        print(f"통계 반영된 요청 수: {statistics_requests_num}, 통계 반영된 시간: {final_duration:.2f} 초")
        final_rps = statistics_requests_num / final_duration 
        
        print("\n" + "="*50)
        print(" 실험 최종 결과 요약")
        print("="*50)
        if self.slo_violation:
            print(" 부하 테스트가 조기 종료되었습니다! (SLO 위반)")
            print(f" Client 수를 낮추어 다시 시도하세요.")
        print(f" 설정 실험 시간: {self.duration} 초")
        print(f" Clients 수: {self.num_clients}")
        print(f" 통계 반영 시간: {final_duration:.2f} 초")
        print(f" 총 시도된 요청: {self.requests_completed + self.requests_failed} 개")
        print(f" 총 완료된 요청: {self.requests_completed} 개")
        print(f" 총 실패한 요청: {self.requests_failed} 개")
        print(f" 완료 요청 중 retrieval이 실패한 요청: {self.requests_completed - retrieval_success_count} 개")
        print(f" 요청 성공률: {(self.requests_completed / (self.requests_completed + self.requests_failed) * 100) if (self.requests_completed + self.requests_failed) > 0 else 0:.2f}%")
        print(f" 전체 Requests Per Second (RPS): {final_rps:.2f}")
        print("-"*50)
        print(" Time to First Token (TTFT) Latency:")
        print(f"  - 평균 (Mean): {np.mean(ttfts):.4f} 초")
        print(f"  - 중간값 (50%ile): {np.percentile(ttfts, 50):.4f} 초")
        print(f"  - 최소값 (Min): {np.min(ttfts):.4f} 초")
        print(f"  - 최대값 (Max): {np.max(ttfts):.4f} 초")
        print(f"  - 95%ile Tail: {np.percentile(ttfts, 95):.4f} 초")
        print(f"  - 99%ile Tail: {np.percentile(ttfts, 99):.4f} 초")
        print("-"*50)
        print(" Time Per Output Token (TPOT):")
        print(f"  - 평균 (Mean): {np.mean(tpots) * 1000:.2f} ms/token")
        
        # Latency 통계 출력
        embedding_latencies = np.array(self.embedding_latencies)
        print("-"*50)
        print(" Embedding Latency:")
        print(f"  - 총 샘플 수: {len(embedding_latencies)}")
        if len(embedding_latencies) == 0:
            print("  - (측정된 샘플이 없습니다.)")
        else:
            print(f"  - 평균 (Mean): {np.mean(embedding_latencies)*1000:.2f} ms")
            print(f"  - 중간값 (50%ile): {np.percentile(embedding_latencies, 50)*1000:.2f} ms")
            print(f"  - 95%ile Tail: {np.percentile(embedding_latencies, 95)*1000:.2f} ms")
            print(f"  - 99%ile Tail: {np.percentile(embedding_latencies, 99)*1000:.2f} ms")
            
        vectordb_latencies = np.array(self.vectordb_latencies)
        print("-"*50)
        print(" VectorDB Search Latency:")
        print(f"  - 총 샘플 수: {len(vectordb_latencies)}")
        if len(vectordb_latencies) == 0:
            print("  - (측정된 샘플이 없습니다.)")
        else:
            print(f"  - 평균 (Mean): {np.mean(vectordb_latencies)*1000:.2f} ms")
            print(f"  - 중간값 (50%ile): {np.percentile(vectordb_latencies, 50)*1000:.2f} ms")
            print(f"  - 95%ile Tail: {np.percentile(vectordb_latencies, 95)*1000:.2f} ms")
            print(f"  - 99%ile Tail: {np.percentile(vectordb_latencies, 99)*1000:.2f} ms")
        
        document_latencies = np.array(self.document_latencies)
        print("-"*50)
        print(" Document Search Latency:")
        print(f"  - 총 샘플 수: {len(document_latencies)}")
        if len(document_latencies) == 0:
            print("  - (측정된 샘플이 없습니다.)")
        else:
            print(f"  - 평균 (Mean): {np.mean(document_latencies)*1000:.2f} ms")
            print(f"  - 중간값 (50%ile): {np.percentile(document_latencies, 50)*1000:.2f} ms")
            print(f"  - 95%ile Tail: {np.percentile(document_latencies, 95)*1000:.2f} ms")
            print(f"  - 99%ile Tail: {np.percentile(document_latencies, 99)*1000:.2f} ms")
        
        retrieval_latencies = np.array(self.retrieval_latencies)
        print("-"*50)
        print(" Total Retrieval Latency:")
        print(f"  - 총 샘플 수: {len(retrieval_latencies)}")
        if len(retrieval_latencies) == 0:
            print("  - (측정된 샘플이 없습니다.)")
        else:
            print(f"  - 평균 (Mean): {np.mean(retrieval_latencies)*1000:.2f} ms")
            print(f"  - 중간값 (50%ile): {np.percentile(retrieval_latencies, 50)*1000:.2f} ms")
            print(f"  - 95%ile Tail: {np.percentile(retrieval_latencies, 95)*1000:.2f} ms")
            print(f"  - 99%ile Tail: {np.percentile(retrieval_latencies, 99)*1000:.2f} ms")
            
        print("="*50)

    async def run(self):
        """부하 테스트를 시작하고 실행합니다."""
        self.start_time = time.monotonic()
        logging.info(f"부하 테스트 시작, client 수 = {self.num_clients}")
        # logging.info(f"Zipf 값 {self.zipf_param}에서 상위 20%의 질문이 차지하는 비율: {self._calculate_pareto_percentage(self.zipf_param):.2f}%")

        connector = aiohttp.TCPConnector(limit=0)
        timeout = aiohttp.ClientTimeout(total=120, connect=30, sock_read=60)

        async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
            tasks = [self._run_client(session, client_id) for client_id in range(self.num_clients)]
            await asyncio.gather(*tasks)
            
        self._print_final_summary()

def main():
    parser = argparse.ArgumentParser(description="LangChain/vLLM 서버용 부하 생성기")
    parser.add_argument("--host", type=str, default="localhost", help="서버 호스트 주소")
    parser.add_argument("--port", type=int, default=9000, help="서버 포트 번호")
    parser.add_argument("--num-clients", type=int, default=1, help="동시 접속 클라이언트 수")
    parser.add_argument("--duration", type=int, default=60, help="총 실험 시간 (초)")
    parser.add_argument("--zipf", type=float, default=1, help="Zipf 분포의 skewness (1: 균등)")
    parser.add_argument("--slo", type=float, default=2.0, help="SLO (초 단위) - p99 TTFT 기준")
    # ===> 변경된 부분 <===
    parser.add_argument("--dataset", type=str, default=None, 
                        help="사용할 Hugging Face 데이터셋 디렉토리. 지정하지 않으면 기본 질문(수도 묻기)을 사용합니다.")
    parser.add_argument("--read-write", type=str, default="1_0", help="읽기/쓰기 비율 (예: 1_0 = 100% 읽기, 8_2 = 80% 읽기 20% 쓰기)")
    
    args = parser.parse_args()
    
    logging.info(f"ReqGen 시작: 서버={args.host}:{args.port}, 클라이언트={args.num_clients}, 시간={args.duration}초")

    reqgen = ReqGen(args)
    asyncio.run(reqgen.run())

if __name__ == "__main__":
    main()
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

class ReqGen:
    def __init__(self, args):
        self.host = args.host
        self.port = args.port
        self.num_clients = args.num_clients
        self.duration = args.duration
        self.zipf_param = args.zipf
        self.dataset_name = args.dataset
        self.slo_ttft = args.slo_ttft
        self.max_clients = args.max_clients
        self.client_step = args.client_step
        self.min_requests = args.min_requests
        self.server_url = f"http://{self.host}:{self.port}/chat"
        
        self.questions = self._load_questions()
        self.results = []
        self.requests_completed = 0
        self.start_time = None
        self.last_report_count = 0
        self.lock = asyncio.Lock()

    def _load_questions(self):
        """질문 데이터셋을 로드하거나, 없을 경우 기본 질문을 생성합니다."""
        # self.dataset_name이 None이나 빈 문자열이 아니면 데이터셋 로드 시도
        if self.dataset_name:
            try:
                logging.info(f"Hugging Face에서 '{self.dataset_name}' 데이터셋을 로드합니다...")
                dataset = load_dataset(self.dataset_name, split='train', streaming=True)
                questions = [item['question'] for item in dataset.take(5000) if 'question' in item and item['question']]
                if not questions:
                    raise ValueError("데이터셋에서 유효한 질문을 찾을 수 없습니다.")
                logging.info(f"{len(questions)}개의 질문을 로드했습니다.")
                return questions
            except Exception as e:
                logging.error(f"데이터셋 로드 실패: {e}. 기본 질문 생성기로 대체합니다.")
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
        while time.monotonic() - self.start_time < self.duration:
            question_idx = np.random.zipf(self.zipf_param) % len(self.questions)
            # logging.info(f"클라이언트 {client_id} 요청: 질문 인덱스 {question_idx}")
            question = self.questions[question_idx]

            req_start_time = time.monotonic()
            first_token_time = None
            response_end_time = None
            received_chunks = 0

            try:
                async with session.post(self.server_url, json={"client_id": client_id, "user_input": question}) as response:
                    response.raise_for_status()
                    async for chunk in response.content.iter_any():
                        if chunk:
                            if first_token_time is None:
                                first_token_time = time.monotonic()
                            received_chunks += 1
                    response_end_time = time.monotonic()

            except aiohttp.ClientError as e:
                logging.warning(f"요청 실패: {e}")
                await asyncio.sleep(1)
                continue

            if first_token_time and response_end_time:
                ttft = first_token_time - req_start_time
                total_time = response_end_time - req_start_time
                tpot = (response_end_time - first_token_time) / (received_chunks - 1) if received_chunks > 1 else 0

                async with self.lock:
                    self.results.append({"ttft": ttft, "tpot": tpot})
                    self.requests_completed += 1
                    
                    if self.requests_completed // 100 > self.last_report_count // 100:
                        self._print_realtime_report()
                        self.last_report_count = self.requests_completed

                wait_interval = received_chunks * 0.200
                await asyncio.sleep(wait_interval)

    def _print_realtime_report(self):
        """100개의 요청마다 실시간 성능 지표를 출력합니다."""
        recent_ttfts = [r['ttft'] for r in self.results[-100:]]
        if not recent_ttfts:
            return
            
        p99_ttft = np.percentile(recent_ttfts, 99)
        
        elapsed_time = time.monotonic() - self.start_time
        current_rps = self.requests_completed / elapsed_time if elapsed_time > 0 else 0
        
        logging.info(
            f"[실시간] 요청 {self.requests_completed}개 처리 | "
            f"TTFT (99%): {p99_ttft:.4f} 초 | "
            f"RPS: {current_rps:.2f}"
        )

    def _print_final_summary(self):
        """실험 종료 후 최종 성능 요약을 출력합니다."""
        if not self.results:
            logging.warning("처리된 요청이 없어 최종 결과를 출력할 수 없습니다.")
            return

        ttfts = np.array([r['ttft'] for r in self.results])
        tpots = np.array([r['tpot'] for r in self.results if r['tpot'] > 0])
        
        final_duration = time.monotonic() - self.start_time
        final_rps = self.requests_completed / final_duration if final_duration > 0 else 0
        p99_ttft = np.percentile(ttfts, 99)
        
        print("\n" + "="*50)
        print(" 실험 최종 결과 요약")
        print("="*50)
        print(f" 총 실험 시간: {final_duration:.2f} 초")
        print(f" 총 완료된 요청: {self.requests_completed} 개")
        print(f" 전체 Requests Per Second (RPS): {final_rps:.2f}")
        print("-"*50)
        print(" Time to First Token (TTFT) Latency:")
        print(f"  - 평균 (Mean): {np.mean(ttfts):.4f} 초")
        print(f"  - 중간값 (50%ile): {np.percentile(ttfts, 50):.4f} 초")
        print(f"  - 95%ile Tail: {np.percentile(ttfts, 95):.4f} 초")
        print(f"  - 99%ile Tail: {p99_ttft:.4f} 초")
        print("-"*50)
        print(" Time Per Output Token (TPOT):")
        print(f"  - 평균 (Mean): {np.mean(tpots) * 1000:.2f} ms/token")
        print("="*50)
        
        return final_rps, p99_ttft

    async def run(self):
        """부하 테스트를 시작하고 실행합니다."""
        if self.slo_ttft is not None:
            return await self._run_slo_search()
        else:
            return await self._run_single_test()

    async def _run_single_test(self):
        """단일 클라이언트 수로 테스트를 실행합니다."""
        self.start_time = time.monotonic()
        print(f"부하 테스트 시작, client 수 = {self.num_clients}")
        print(f"Zipf 값 {self.zipf_param}에서 상위 20%가 차지하는 비율: {self._calculate_pareto_percentage(self.zipf_param):.2f}%")

        connector = aiohttp.TCPConnector(limit=0)

        async with aiohttp.ClientSession(connector=connector) as session:
            tasks = [self._run_client(session, client_id) for client_id in range(self.num_clients)]
            await asyncio.gather(*tasks)
            
        return self._print_final_summary()

    async def _run_slo_search(self):
        """SLO를 만족하는 최대 RPS를 찾기 위해 클라이언트 수를 증가시키며 테스트합니다."""
        print(f"SLO 기반 최대 RPS 탐색 시작")
        print(f"목표 SLO: p99 TTFT <= {self.slo_ttft:.4f} 초")
        print(f"클라이언트 수 범위: {self.num_clients} ~ {self.max_clients} (step: {self.client_step})")
        print(f"각 테스트 지속 시간: {self.duration} 초")
        print(f"최소 요청 수: {self.min_requests}")
        print(f"Zipf 값 {self.zipf_param}에서 상위 20%가 차지하는 비율: {self._calculate_pareto_percentage(self.zipf_param):.2f}%")
        print("="*80)

        best_rps = 0
        best_clients = 0
        best_p99_ttft = float('inf')
        slo_results = []

        current_clients = self.num_clients
        
        while current_clients <= self.max_clients:
            print(f"\n[테스트 {len(slo_results) + 1}] 클라이언트 수: {current_clients}")
            print("-" * 60)
            
            # 각 테스트마다 상태 초기화
            self.results = []
            self.requests_completed = 0
            self.last_report_count = 0
            self.start_time = time.monotonic()

            connector = aiohttp.TCPConnector(limit=0)
            
            async with aiohttp.ClientSession(connector=connector) as session:
                tasks = [self._run_client(session, client_id) for client_id in range(current_clients)]
                await asyncio.gather(*tasks)

            # 충분한 요청이 처리되었는지 확인
            if self.requests_completed < self.min_requests:
                print(f"⚠️ 경고: 요청 수가 부족합니다 ({self.requests_completed} < {self.min_requests}). 다음 테스트로 건너뜀.")
                current_clients += self.client_step
                continue

            result = self._print_final_summary()
            if result is None:
                current_clients += self.client_step
                continue
                
            current_rps, current_p99_ttft = result
            
            slo_satisfied = current_p99_ttft <= self.slo_ttft
            slo_results.append({
                'clients': current_clients,
                'rps': current_rps,
                'p99_ttft': current_p99_ttft,
                'slo_satisfied': slo_satisfied
            })

            # 현재 step 결과 출력
            print(f"\n📊 [Step 결과] 클라이언트 {current_clients}개:")
            print(f"   • RPS: {current_rps:.2f}")
            print(f"   • p99 TTFT: {current_p99_ttft:.4f}초")
            print(f"   • SLO 목표: {self.slo_ttft:.4f}초")
            
            if slo_satisfied:
                if current_rps > best_rps:
                    best_rps = current_rps
                    best_clients = current_clients
                    best_p99_ttft = current_p99_ttft
                print(f"   • 상태: ✅ SLO 만족 (최대 RPS 업데이트)")
            else:
                print(f"   • 상태: ❌ SLO 위반 (p99 TTFT 초과)")
                print(f"   • SLO 위반으로 탐색을 중단합니다.")
                break

            current_clients += self.client_step

        # 최종 결과 출력
        self._print_slo_search_summary(slo_results, best_rps, best_clients, best_p99_ttft)
        return best_rps, best_clients, best_p99_ttft, slo_results

    def _print_slo_search_summary(self, slo_results, best_rps, best_clients, best_p99_ttft):
        """SLO 탐색 결과 요약을 출력합니다."""
        print("\n" + "="*80)
        print(" SLO 기반 최대 RPS 탐색 결과")
        print("="*80)
        
        if best_rps > 0:
            print(f" 🎯 SLO를 만족하는 최대 RPS: {best_rps:.2f}")
            print(f" 📊 최적 클라이언트 수: {best_clients}")
            print(f" ⏱️  해당 p99 TTFT: {best_p99_ttft:.4f} 초")
            print(f" 🎯 목표 SLO: {self.slo_ttft:.4f} 초")
        else:
            print(" ❌ SLO를 만족하는 설정을 찾지 못했습니다.")
            print(" 💡 권장사항: --max-clients 값을 줄이거나 --slo-ttft 값을 늘려보세요.")

        print("-"*80)
        print(" 📈 전체 테스트 결과 요약:")
        print(f" {'Step':<6} {'클라이언트':<10} {'RPS':<10} {'p99 TTFT':<12} {'SLO 상태':<12}")
        print("-"*80)
        
        for i, result in enumerate(slo_results, 1):
            status = "✅ 만족" if result['slo_satisfied'] else "❌ 위반"
            print(f" {i:<6} {result['clients']:<10} {result['rps']:<10.2f} {result['p99_ttft']:<12.4f} {status}")
        
        print("="*80)

def main():
    parser = argparse.ArgumentParser(description="LangChain/vLLM 서버용 부하 생성기")
    parser.add_argument("--host", type=str, default="localhost", help="서버 호스트 주소")
    parser.add_argument("--port", type=int, default=9000, help="서버 포트 번호")
    parser.add_argument("--num-clients", type=int, default=1, help="동시 접속 클라이언트 수 (SLO 모드에서는 시작 클라이언트 수)")
    parser.add_argument("--duration", type=int, default=60, help="총 실험 시간 (초)")
    parser.add_argument("--zipf", type=float, default=1, help="Zipf 분포의 skewness (1: 균등)")
    parser.add_argument("--dataset", type=str, default=None, 
                        help="사용할 Hugging Face 데이터셋 디렉토리. 지정하지 않으면 기본 질문(수도 묻기)을 사용합니다.")
    
    # SLO 관련 파라미터
    parser.add_argument("--slo-ttft", type=float, default=None, 
                        help="목표 SLO: p99 TTFT 임계값 (초). 지정하면 SLO를 만족하는 최대 RPS 탐색 모드로 실행")
    parser.add_argument("--max-clients", type=int, default=100, 
                        help="SLO 탐색 시 최대 클라이언트 수")
    parser.add_argument("--client-step", type=int, default=5, 
                        help="SLO 탐색 시 클라이언트 증가 단위")
    parser.add_argument("--min-requests", type=int, default=50, 
                        help="SLO 탐색 시 각 테스트에서 최소 요청 수 (신뢰할 수 있는 통계를 위함)")
    
    args = parser.parse_args()
    
    if args.slo_ttft is not None:
        logging.info(f"SLO 기반 최대 RPS 탐색 시작: 목표 p99 TTFT <= {args.slo_ttft:.4f}초")
        logging.info(f"서버={args.host}:{args.port}, 클라이언트 범위={args.num_clients}-{args.max_clients}")
    else:
        logging.info(f"ReqGen 시작: 서버={args.host}:{args.port}, 클라이언트={args.num_clients}, 시간={args.duration}초")

    reqgen = ReqGen(args)
    result = asyncio.run(reqgen.run())
    
    if args.slo_ttft is not None and result:
        best_rps, best_clients, best_p99_ttft, slo_results = result
        print(f"\n최종 권장 설정: 클라이언트 수 {best_clients}, 예상 RPS {best_rps:.2f}")

if __name__ == "__main__":
    main()
# Knowhere C++ mmap 예제

이 프로젝트는 Knowhere C++ API를 사용하여 HNSW 인덱스를 mmap으로 로드하는 예제입니다.

## 주요 특징

- **mmap 기반 인덱스 로딩**: 메모리 매핑을 사용한 효율적인 인덱스 로드
- **HNSW 인덱스**: 고성능 근사 최근접 이웃 검색
- **BinarySet 직렬화**: Knowhere의 표준 직렬화 형식 사용
- **성능 측정**: 빌드, 로드, 검색 시간 측정

## 파일 구조

```
knowhere_cpp/
├── CMakeLists.txt              # CMake 빌드 설정
├── mmap_hnsw_example.cpp       # 메인 예제 코드
├── generate_test_data.cpp      # 대용량 테스트 데이터 생성기
├── build.sh                    # 빌드 스크립트
└── README.md                   # 이 파일
```

## 빌드 요구사항

- **CMake** >= 3.16
- **C++17** 지원 컴파일러
- **Knowhere** 라이브러리 (시스템에 설치되어 있어야 함)

## 빌드 방법

```bash
cd /home/comsys/knowhere_cpp
./build.sh
```

## 실행 방법

### 1. 기본 예제 실행

```bash
cd build
./mmap_hnsw_example
```

이 예제는 다음을 수행합니다:
1. 10,000개의 128차원 벡터 생성
2. HNSW 인덱스 빌드 및 파일 저장
3. mmap을 사용하여 인덱스 로드
4. 100개 쿼리로 검색 성능 테스트

### 2. 대용량 데이터 생성

```bash
cd build
./generate_test_data
```

100,000개의 벡터로 구성된 대용량 데이터셋을 생성합니다.

## 코드 구조

### HNSWMmapExample 클래스

- `generateData()`: 테스트용 랜덤 벡터 데이터 생성
- `buildAndSaveIndex()`: HNSW 인덱스 빌드 및 BinarySet으로 저장
- `loadIndexWithMmap()`: mmap을 사용한 인덱스 로드
- `parseMmapData()`: mmap된 데이터에서 BinarySet 파싱
- `testSearch()`: 검색 성능 테스트

### mmap 활용 방식

1. **파일 매핑**: `mmap()`으로 인덱스 파일을 메모리에 매핑
2. **BinarySet 파싱**: 매핑된 메모리에서 직접 데이터 읽기
3. **메모리 복사**: 필요한 부분만 복사해서 BinarySet 구성
4. **인덱스 역직렬화**: Knowhere API로 인덱스 복원

## 성능 이점

- **빠른 로딩**: 파일 I/O 대신 메모리 매핑 사용
- **메모리 효율성**: 필요한 부분만 실제 메모리에 로드
- **공유 메모리**: 여러 프로세스가 같은 인덱스 공유 가능
- **OS 캐시 활용**: 커널의 페이지 캐시 최적화

## Python 예제와의 비교

| 기능 | Python API | C++ API |
|------|------------|---------|
| mmap 지원 | ❌ 직접 지원 없음 | ✅ 완전 지원 |
| BinarySet 조작 | ❌ 제한적 | ✅ 직접 조작 가능 |
| 메모리 제어 | ❌ 제한적 | ✅ 완전 제어 |
| 성능 | 🔸 Python 오버헤드 | ✅ 네이티브 성능 |

## 예상 출력

```
Knowhere HNSW mmap 예제 시작
설정: DIM=128, NB=10000, NQ=100, K=10

=== 테스트 데이터 생성 ===
데이터 생성 완료: DB=10000x128, Query=100x128

=== HNSW 인덱스 빌드 ===
인덱스 빌드 완료: 1234ms
인덱스 저장 완료: hnsw_index.bin

=== mmap으로 인덱스 로드 ===
파일 mmap 완료: 5242880 bytes
BinarySet 항목 수: 1
  - HNSW: 5242856 bytes
mmap 인덱스 로드 완료: 45ms

=== 검색 테스트 ===
검색 완료: 8765μs
결과 shape: 100 x 10

첫 번째 쿼리 결과:
  ID: 1234, Distance: 0.567
  ID: 5678, Distance: 0.789
  ...
평균 검색 지연시간: 87.65μs/query

=== 테스트 완료 ===
```

## 참고사항

- **메모리 정렬**: mmap된 데이터는 적절히 정렬되어야 함
- **파일 포맷**: BinarySet의 직렬화 형식을 정확히 파싱해야 함
- **에러 처리**: mmap 관련 시스템 콜 오류 처리 중요
- **리소스 관리**: munmap() 호출로 메모리 해제 필요

이 예제를 통해 C++에서 Knowhere의 mmap 기능을 완전히 활용할 수 있습니다.

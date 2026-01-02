#!/bin/bash

# VectorDB 빌드 스크립트

set -e

echo "=== VectorDB 빌드 시작 ==="

# 디렉토리 확인
if [ ! -f "CMakeLists.txt" ]; then
    echo "오류: CMakeLists.txt 파일을 찾을 수 없습니다."
    echo "이 스크립트는 vectorDB 디렉토리에서 실행해야 합니다."
    exit 1
fi

# HNSW 인덱스 파일 확인
# HNSW_INDEX="../knowhere_cpp/hnsw_index.bin"
# if [ ! -f "$HNSW_INDEX" ]; then
#     echo "경고: HNSW 인덱스 파일이 없습니다: $HNSW_INDEX"
#     echo "먼저 ../knowhere_cpp/advanced_mmap_example을 실행하여 인덱스를 생성하세요."
# fi

# 빌드 디렉토리 생성
if [ -d "build" ]; then
    echo "기존 빌드 디렉토리를 정리합니다..."
    rm -rf build
fi

mkdir build
cd build

# CMake 구성
echo "CMake 구성 중..."
cmake .. -DCMAKE_BUILD_TYPE=Release

# 빌드
echo "컴파일 중..."
make -j$(nproc)

# 빌드 결과 확인
if [ -f "vector_db" ]; then
    echo "✓ vector_db 빌드 성공"
else
    echo "✗ vector_db 빌드 실패"
    exit 1
fi

echo ""
echo "=== 빌드 완료 ==="
echo "실행 파일:"
echo "  ./build/vector_db - VectorDB 서버"
echo ""
echo "사용 예시:"
echo "  cd build"
echo "  ./vector_db"

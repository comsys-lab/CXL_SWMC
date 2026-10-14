#!/bin/bash

echo "=== Knowhere C++ mmap 예제 빌드 스크립트 ==="

# 빌드 디렉토리 생성
mkdir -p build
cd build

# CMake 설정
echo "CMake 설정 중..."
cmake .. -DCMAKE_BUILD_TYPE=Release

# 빌드
echo "컴파일 중..."
make -j$(nproc)

if [ $? -eq 0 ]; then
    echo "빌드 성공!"
    echo ""
    echo "실행 방법:"
    echo "  cd build"
    echo "  ./advanced_mmap_example    # 고급 HNSW mmap 예제 실행"
else
    echo "빌드 실패!"
    exit 1
fi

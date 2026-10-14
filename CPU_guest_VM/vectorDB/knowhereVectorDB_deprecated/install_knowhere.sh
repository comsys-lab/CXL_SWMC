#!/bin/bash

# Knowhere 설치 스크립트
# Ubuntu/Debian 환경에서 Knowhere를 빌드하고 Python wheel을 설치합니다.

set -e  # 오류 발생 시 스크립트 중단

echo "=== Knowhere 설치 스크립트 ==="

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 함수 정의
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# CMake 버전 확인 함수 추가 (print_error 함수 다음에)
check_cmake_version() {
    local required_version="3.26.4"
    local current_version
    
    if command -v cmake &> /dev/null; then
        current_version=$(cmake --version | head -n1 | cut -d' ' -f3)
        print_info "현재 CMake 버전: $current_version"
        
        # 버전 비교
        if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" = "$required_version" ]; then
            print_info "CMake 버전이 요구사항을 만족합니다."
            return 0
        else
            print_warning "CMake 버전이 부족합니다. 최소 $required_version 필요"
            return 1
        fi
    else
        print_warning "CMake가 설치되지 않았습니다."
        return 1
    fi
}

# 시스템 확인
print_info "시스템 정보 확인 중..."
echo "OS: $(lsb_release -d | cut -f2)"
echo "Architecture: $(uname -m)"
echo "Python: $(python3 --version)"

# CMake 버전 확인 및 업그레이드
print_info "CMake 버전 확인 중..."
if ! check_cmake_version; then
    echo "CMake를 최신 버전으로 업그레이드하시겠습니까? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        print_info "CMake 업그레이드 중..."
        
        # 기존 CMake 제거
        sudo apt remove cmake -y
        
        # Kitware 저장소 추가 및 CMake 설치
        wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | sudo tee /etc/apt/trusted.gpg.d/kitware.gpg >/dev/null
        sudo apt-add-repository "deb https://apt.kitware.com/ubuntu/ jammy main" -y
        sudo apt update
        sudo apt install cmake -y
        
        # 다시 확인
        if check_cmake_version; then
            print_info "CMake 업그레이드 완료"
        else
            print_error "CMake 업그레이드 실패"
            exit 1
        fi
    else
        print_error "CMake 업그레이드가 필요합니다. 수동으로 설치해주세요."
        echo "다음 명령어를 실행하세요:"
        echo "sudo apt remove cmake"
        echo "wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | sudo tee /etc/apt/trusted.gpg.d/kitware.gpg >/dev/null"
        echo "sudo apt-add-repository \"deb https://apt.kitware.com/ubuntu/ jammy main\""
        echo "sudo apt update && sudo apt install cmake"
        exit 1
    fi
fi

# 의존성 설치 확인
print_info "시스템 의존성 확인 중..."

# 필수 패키지 리스트
REQUIRED_PACKAGES=(
    "build-essential"
    "libopenblas-openmp-dev" 
    "libaio-dev"
    "python3-dev"
    "python3-pip"
    "swig"
    "git"
    "cmake"
)

MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package "; then
        MISSING_PACKAGES+=("$package")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    print_warning "다음 패키지들이 설치되지 않았습니다: ${MISSING_PACKAGES[*]}"
    echo "설치하시겠습니까? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        print_info "시스템 패키지 설치 중..."
        sudo apt update
        sudo apt install -y "${MISSING_PACKAGES[@]}"
        print_info "시스템 패키지 설치 완료"
    else
        print_error "필수 패키지가 설치되지 않았습니다. 수동으로 설치해주세요."
        exit 1
    fi
else
    print_info "모든 시스템 의존성이 설치되어 있습니다."
fi

# Python 패키지 설치
print_info "Python 의존성 설치 중..."

# pip 업그레이드
python3 -m pip install --upgrade pip --user

# 필수 Python 패키지 설치
python3 -m pip install conan==1.61.0 bfloat16 numpy --user

# PATH에 conan 추가
export PATH=$PATH:$HOME/.local/bin

# conan 버전 확인
if command -v conan &> /dev/null; then
    print_info "Conan 버전: $(conan --version)"
else
    print_error "Conan 설치 실패. PATH를 확인하세요: export PATH=\$PATH:\$HOME/.local/bin"
    exit 1
fi

# 작업 디렉토리 설정
WORK_DIR="${HOME}/CXLSharedMemVM/knowhereVectorDB"
KNOWHERE_DIR="${WORK_DIR}/knowhere"

print_info "작업 디렉토리: $WORK_DIR"

# 기존 디렉토리 확인
if [ -d "$KNOWHERE_DIR" ]; then
    print_warning "기존 Knowhere 디렉토리가 발견되었습니다: $KNOWHERE_DIR"
    echo "삭제하고 새로 클론하시겠습니까? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -rf "$KNOWHERE_DIR"
    else
        print_info "기존 디렉토리를 사용합니다."
    fi
fi

# Knowhere 소스 코드 클론
if [ ! -d "$KNOWHERE_DIR" ]; then
    print_info "Knowhere 소스 코드 클론 중..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    git clone https://github.com/zilliztech/knowhere.git
    print_info "소스 코드 클론 완료"
else
    print_info "기존 소스 코드 사용"
fi

cd "$KNOWHERE_DIR"

# 빌드 디렉토리 생성
BUILD_DIR="${KNOWHERE_DIR}/build"
if [ -d "$BUILD_DIR" ]; then
    print_warning "기존 빌드 디렉토리 삭제 중..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

print_info "빌드 설정 중..."

# Conan 리모트 추가
print_info "Conan 리모트 설정 중..."
conan remote add default-conan-local https://milvus01.jfrog.io/artifactory/api/conan/default-conan-local || true

# 빌드 타입 선택
echo "빌드 타입을 선택하세요:"
echo "1) Release (권장)"
echo "2) Debug"
read -p "선택 (1-2): " build_choice

case $build_choice in
    1)
        BUILD_TYPE="Release"
        ;;
    2)
        BUILD_TYPE="Debug"
        ;;
    *)
        print_warning "잘못된 선택. Release로 진행합니다."
        BUILD_TYPE="Release"
        ;;
esac

print_info "빌드 타입: $BUILD_TYPE"

# Conan 설정 및 의존성 설치
print_info "Conan 의존성 설치 중... (시간이 오래 걸릴 수 있습니다)"

conan install .. \
    --build=missing \
    -o with_ut=True \
    -s compiler.libcxx=libstdc++11 \
    -s build_type=$BUILD_TYPE

if [ $? -ne 0 ]; then
    print_error "Conan 의존성 설치 실패"
    exit 1
fi

print_info "Conan 의존성 설치 완료"

# 빌드 실행
print_info "Knowhere 빌드 중... (시간이 오래 걸릴 수 있습니다)"

conan build ..

if [ $? -ne 0 ]; then
    print_error "Knowhere 빌드 실패"
    exit 1
fi

print_info "Knowhere 빌드 완료"

# Python wheel 생성
print_info "Python wheel 생성 중..."

cd "${KNOWHERE_DIR}/python"

# 기존 빌드 아티팩트 정리
rm -rf build dist knowhere.egg-info
rm -f knowhere/knowhere_wrap.cpp knowhere/swigknowhere.py

# Python wheel 빌드
python3 setup.py bdist_wheel

if [ $? -ne 0 ]; then
    print_error "Python wheel 생성 실패"
    exit 1
fi

print_info "Python wheel 생성 완료"

# Wheel 설치
WHEEL_FILE=$(find dist -name "pyknowhere-*.whl" | head -1)

if [ -z "$WHEEL_FILE" ]; then
    print_error "생성된 wheel 파일을 찾을 수 없습니다."
    exit 1
fi

print_info "Python wheel 설치 중: $WHEEL_FILE"

python3 -m pip install "$WHEEL_FILE" --user --force-reinstall

if [ $? -ne 0 ]; then
    print_error "Python wheel 설치 실패"
    exit 1
fi

print_info "Python wheel 설치 완료"

# 설치 확인
print_info "설치 확인 중..."

python3 -c "import knowhere; print(f'Knowhere 버전: {knowhere.GetCurrentVersion()}'); print('설치 성공!')" 2>/dev/null

if [ $? -eq 0 ]; then
    print_info "✅ Knowhere 설치가 완료되었습니다!"
    echo ""
    echo "사용 방법:"
    echo "  cd /home/comsys/CXLSharedMemVM/vectorDB"
    echo "  python3 knowhere_example.py --help"
    echo ""
    echo "빌드 디렉토리: $BUILD_DIR"
    echo "Wheel 파일: $WHEEL_FILE"
else
    print_error "❌ 설치 확인 실패. import 오류가 발생했습니다."
    exit 1
fi

# 정리 옵션
echo ""
echo "빌드 디렉토리를 정리하시겠습니까? (용량 절약, y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    print_info "빌드 디렉토리 정리 중..."
    cd "$WORK_DIR"
    rm -rf "$BUILD_DIR"
    print_info "정리 완료"
fi

print_info "스크립트 완료!"

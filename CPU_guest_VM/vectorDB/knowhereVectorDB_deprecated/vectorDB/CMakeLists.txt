## GPT 기반임. 대화내용: https://chatgpt.com/share/68be5ce7-b898-8011-a0bb-f574e796b52a
cmake_minimum_required(VERSION 3.20)  # CMake 최소 버전
project(vectorDB CXX)                 # 프로젝트 이름, 언어 = C++

set(CMAKE_CXX_STANDARD 20)            # C++20 사용
set(CMAKE_CXX_STANDARD_REQUIRED ON)   # C++20 강제

# Conan toolchain 불러옴 (cmake 실행할 때 -DCMAKE_TOOLCHAIN_FILE 지정)
# => Conan이 설치한 패키지 경로/플래그를 자동 인식

add_subdirectory(external/knowhere)   # knowhere 소스를 내 프로젝트에 포함
# => knowhere 타겟이 생김 (libknowhere.so)

add_executable(vector_db main.cpp vector_db.cpp vector_db_server.cpp)
# => 내 코드 빌드 규칙 생성, 실행파일 vector_db 만들기

target_link_libraries(vector_db
  PRIVATE
    knowhere                        # knowhere 타겟 링크 (헤더/플래그 자동 전이)
)

find_package(glog REQUIRED)          # Conan이 제공하는 glog 패키지 불러오기
target_link_libraries(vector_db PRIVATE glog::glog)

# RPATH 설정: 실행파일이 실행될 때 libknowhere.so를 찾을 수 있도록
set_target_properties(vector_db PROPERTIES
  BUILD_RPATH "$ORIGIN;$ORIGIN/..;$ORIGIN/../lib"
  INSTALL_RPATH "$ORIGIN"
)

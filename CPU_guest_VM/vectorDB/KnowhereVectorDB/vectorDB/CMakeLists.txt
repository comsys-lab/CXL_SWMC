cmake_minimum_required(VERSION 3.16)
project(vectorDB)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set Knowhere paths
set(KNOWHERE_ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/external/knowhere")
set(KNOWHERE_BUILD_DIR "${KNOWHERE_ROOT_DIR}/build/Release")
set(KNOWHERE_INCLUDE_DIR "${KNOWHERE_ROOT_DIR}/include")
set(KNOWHERE_LIB "${KNOWHERE_BUILD_DIR}/libknowhere.so")

# Add Conan generators path
list(APPEND CMAKE_MODULE_PATH ${KNOWHERE_BUILD_DIR}/generators)
list(APPEND CMAKE_PREFIX_PATH ${KNOWHERE_BUILD_DIR}/generators)

# Check if Knowhere files exist
if(NOT EXISTS ${KNOWHERE_LIB})
    message(FATAL_ERROR "Knowhere library not found at: ${KNOWHERE_LIB}")
endif()

if(NOT EXISTS ${KNOWHERE_INCLUDE_DIR})
    message(FATAL_ERROR "Knowhere include directory not found at: ${KNOWHERE_INCLUDE_DIR}")
endif()

# Find required dependencies
find_package(nlohmann_json REQUIRED)

# 시스템에 설치된 Boost 라이브러리 직접 사용
find_library(BOOST_SYSTEM_LIB boost_system)
find_library(BOOST_THREAD_LIB boost_thread)

find_package(glog REQUIRED)
find_package(OpenMP REQUIRED)

# Find Arrow
find_package(PkgConfig REQUIRED)
pkg_check_modules(ARROW REQUIRED arrow)
pkg_check_modules(PARQUET REQUIRED parquet)

# Include directories
include_directories(${KNOWHERE_INCLUDE_DIR})
include_directories(${KNOWHERE_ROOT_DIR}/thirdparty/faiss)
include_directories(/usr/local/include)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/external/moodycamel)
include_directories(${ARROW_INCLUDE_DIRS})
include_directories(${PARQUET_INCLUDE_DIRS})

# Add executables
add_executable(vector_db 
    src/main.cpp 
    src/vector_db.cpp 
    src/vector_db_server.cpp
    src/flat_index.cpp
    src/hnsw_index.cpp
)

add_executable(build_vectorDB
    src/build_vectorDB.cpp
)

# Link libraries for vector_db
target_link_libraries(vector_db 
    ${KNOWHERE_LIB}
    nlohmann_json::nlohmann_json
    ${BOOST_SYSTEM_LIB}
    ${BOOST_THREAD_LIB}
    glog::glog
    OpenMP::OpenMP_CXX
    pthread
)

# Link libraries for build_vectorDB
target_link_libraries(build_vectorDB 
    ${KNOWHERE_LIB}
    nlohmann_json::nlohmann_json
    ${BOOST_SYSTEM_LIB}
    ${BOOST_THREAD_LIB}
    glog::glog
    OpenMP::OpenMP_CXX
    ${ARROW_LIBRARIES}
    ${PARQUET_LIBRARIES}
    pthread
)

# Link libraries for vector_db
target_link_libraries(vector_db 
    ${KNOWHERE_LIB}
    nlohmann_json::nlohmann_json
    ${BOOST_SYSTEM_LIB}
    ${BOOST_THREAD_LIB}
    glog::glog
    OpenMP::OpenMP_CXX
    ${ARROW_LIBRARIES}
    ${PARQUET_LIBRARIES}
    pthread
)

# Compiler flags
target_compile_options(vector_db PRIVATE 
    -O2 
    -Wall 
    -Wextra
)

target_compile_options(build_vectorDB PRIVATE 
    -O2 
    -Wall 
    -Wextra
)

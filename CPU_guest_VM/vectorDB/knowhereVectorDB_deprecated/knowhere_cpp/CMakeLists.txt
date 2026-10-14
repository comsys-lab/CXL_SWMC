cmake_minimum_required(VERSION 3.16)
project(knowhere_mmap_example)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set Knowhere paths
set(KNOWHERE_ROOT_DIR "/home/comsys/CXLSharedMemVM/knowhereVectorDB/knowhere")
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
find_package(Boost REQUIRED)
find_package(glog REQUIRED)

# Include directories
include_directories(${KNOWHERE_INCLUDE_DIR})
include_directories(${KNOWHERE_ROOT_DIR}/thirdparty/faiss)
include_directories(/usr/local/include)

# Add executable
add_executable(advanced_mmap_example advanced_mmap_example.cpp)

# Link libraries
target_link_libraries(advanced_mmap_example 
    ${KNOWHERE_LIB}
    nlohmann_json::nlohmann_json
    Boost::boost
    glog::glog
    pthread
)

# Compiler flags
target_compile_options(advanced_mmap_example PRIVATE 
    -O2 
    -Wall 
    -Wextra
)

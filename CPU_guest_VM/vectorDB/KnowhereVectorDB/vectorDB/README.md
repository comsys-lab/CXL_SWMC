# VectorDB

Advanced vector database implementation using Knowhere HNSW index with append-only flat index, supporting concurrent search and insert operations via REST API.

## Project Structure

```
vectorDB/
├── src/                   # Source code
│   ├── main.cpp          # Application entry point
│   ├── vector_db.h       # Core vector database interface
│   ├── vector_db.cpp     # Vector database implementation
│   ├── vector_db_server.h # HTTP server interface
│   ├── vector_db_server.cpp # HTTP server implementation
│   └── httplib.h         # HTTP library header
├── external/             # External libraries
│   └── knowhere/        # Knowhere vector search library
├── build/               # Build output (generated)
│   └── vector_db        # Main executable
├── CMakeLists.txt       # CMake build configuration
├── build.sh            # Build script
├── test_server.sh      # Server testing script
└── README.md           # This file
```

## Features

- **HNSW Index**: File-backed mmap loading of pre-built HNSW index using Knowhere
- **Append-Only Flat Index**: Memory-mapped flat index for new vector insertions
- **Concurrent Operations**: Thread-safe search and insert operations
- **REST API**: HTTP-based API for vector operations
- **Memory Efficient**: Uses mmap for zero-copy index loading

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌────────────────────┐
│   REST API      │    │   VectorDB       │    │  Storage           │
│                 │    │                  │    │                    │
│ POST /vectors   │────│ Insert Vector    │────│ Append-Only Flat   │
│ POST /search    │────│ Search Vector    │────│ + HNSW Index       │
│ GET  /status    │    │                  │    │ (mmap files)       │
└─────────────────┘    └──────────────────┘    └────────────────────┘
```

### Search Process
1. Search in HNSW index for top-k candidates
2. Brute-force search in append-only flat index
3. Merge and rank all results to return final top-k

### Insert Process
1. Assign unique ID to new vector
2. Append to memory-mapped flat index file
3. Return assigned ID

## Prerequisites

- C++20 compatible compiler (GCC 11.4+ or Clang equivalent)
- CMake 3.16+
- Pre-built Knowhere library (with Conan dependencies)
- System packages:
  - `libxxhash-dev` (for Knowhere compatibility)
  - `libopenblas-dev` (for BLAS operations)
  - `nlohmann-json3-dev` (JSON parsing)
  - `libboost-all-dev` (Boost libraries)
  - `libgoogle-glog-dev` (Logging)

## Dependencies

This project uses:
- **Knowhere**: Vector similarity search library (linked as external dependency)
- **cpp-httplib**: Embedded HTTP server library (header-only, included in `src/`)
- **nlohmann/json**: JSON parsing (via Conan package manager)
- **Boost**: System utilities (via Conan package manager)  
- **glog**: Logging library (via Conan package manager)

All Conan dependencies are automatically resolved through the Knowhere build system.

## Building

arrow, boost 관련 라이브러리
```bash
# 필수 도구
sudo apt update
sudo apt install -y -V pkg-config ca-certificates lsb-release wget

# Apache Arrow APT 저장소 추가
wget https://packages.apache.org/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb
sudo apt install -y -V ./apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb

# 설치
sudo apt update
sudo apt install -y -V libarrow-dev libparquet-dev
sudo apt install -y libboost-all-dev
```

### Build Knowhere
First, we use git checkout 10473ff04f33633dffff323840e56b0911eb2d23 version
do `git checkout 10473ff04f33633dffff323840e56b0911eb2d23` first.

follow knowhere README.md.
but, before conan install, we need to set environment variable.

Ex)
```bash
export CMAKE_POLICY_VERSION_MINIMUM=3.5
conan install .. --build=missing -o with_ut=True -s compiler.libcxx=libstdc++11 -s build_type=Release
```

+ requirements
newest cmake (for Ubuntu 22.04)
```bash
sudo apt update
sudo apt install -y ca-certificates gnupg wget software-properties-common

wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc \
  | gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu jammy main' \
  | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null

sudo apt update
sudo apt install -y cmake
```

ccache
```bash
sudo apt-get update
sudo apt-get install -y ccache
```

### Option 1: Using the Build Script (Recommended)

```bash
# Build everything with the provided script
./build.sh
```

This script will:
1. Clean any existing build directory
2. Run CMake configuration 
3. Compile the project with optimal settings
4. Generate the `vector_db` executable in `build/`

### Option 2: Manual Build

```bash
# Create and enter build directory
mkdir build && cd build

# Configure with CMake
cmake .. -DCMAKE_BUILD_TYPE=Release

# Build with make
make -j$(nproc)
```

### Build Requirements

The build system expects:
- Knowhere library pre-built at `external/knowhere/build/Release/`
- All Conan dependencies resolved in the Knowhere build
- System packages installed (see Prerequisites)

**Note**: If you need to build Knowhere from scratch, refer to the Knowhere documentation for Conan setup and build instructions.

## Usage

### Starting the Server

```bash
# Navigate to build directory
cd build

# Run with default parameters
./vector_db

# The server will start on http://localhost:8080
# Look for "Server running on http://localhost:8080" message
```

### Server Configuration

The server uses built-in configuration:
- **Port**: 8080 (hardcoded)
- **Host**: localhost/0.0.0.0
- **Index File**: `flat_index.bin` (created automatically if not exists)
- **Vector Dimensions**: 384 (configurable in source)
- **Max Vectors**: 100,000 (configurable in source)

### API Endpoints

#### 1. Insert Vector
```http
POST /api/vectors
Content-Type: application/json

{
    "vector": [0.1, 0.2, 0.3, ...]  // 384-dimensional float vector
}
```

Response:
```json
{
    "success": true,
    "data": {
        "id": 12345,
        "message": "Vector inserted successfully"
    },
    "timestamp": 1692123456
}
```

#### 2. Search Vectors
```http
POST /api/search
Content-Type: application/json

{
    "vector": [0.1, 0.2, 0.3, ...],  // 384-dimensional query vector
    "k": 10                          // number of results (optional, default: 10)
}
```

Response:
```json
{
    "success": true,
    "data": {
        "results": [
            {"id": 12345, "distance": 0.123},
            {"id": 12346, "distance": 0.156},
            ...
        ],
        "search_time_us": 1234,
        "total_results": 10
    },
    "timestamp": 1692123456
}
```

#### 3. Status Check
```http
GET /api/status
```

Response:
```json
{
    "success": true,
    "data": {
        "flat_index_count": 1000,
        "flat_index_full": false,
        "server_running": true,
        "port": 8080
    },
    "timestamp": 1692123456
}
```

#### 4. Health Check
```http
GET /health
```

Response:
```json
{
    "status": "healthy",
    "timestamp": 1692123456
}
```

## Testing

### Automated Testing

Use the provided test script to verify the server:

```bash
# Test with default server (localhost:8080)
./test_server.sh

# Make sure the server is running first:
cd build && ./vector_db &
cd .. && ./test_server.sh
```

### Manual Testing

```bash
# 1. Start the server
cd build && ./vector_db

# 2. In another terminal, test endpoints:

# Health check
curl http://localhost:8080/health

# Status check  
curl http://localhost:8080/api/status

# Insert a vector
curl -X POST http://localhost:8080/api/vectors \
  -H "Content-Type: application/json" \
  -d '{"vector": [0.1, 0.2, 0.3, ...]}'  # 384 dimensions

# Search for similar vectors
curl -X POST http://localhost:8080/api/search \
  -H "Content-Type: application/json" \
  -d '{"vector": [0.1, 0.2, 0.3, ...], "k": 5}'
```

## Development

### Code Organization

- **`src/main.cpp`**: Application entry point and server startup
- **`src/vector_db.h/cpp`**: Core vector database logic and index management
- **`src/vector_db_server.h/cpp`**: HTTP REST API implementation  
- **`src/httplib.h`**: Single-header HTTP library (external dependency)

### Building for Development

```bash
# For development with debug symbols
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Debug
make -j$(nproc)

# For release/performance testing  
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### Adding New Features

1. **Vector Operations**: Modify `VectorDB` class in `src/vector_db.cpp`
2. **API Endpoints**: Add handlers in `VectorDBServer` class in `src/vector_db_server.cpp`  
3. **Configuration**: Update constants in header files
4. **Dependencies**: Modify `CMakeLists.txt` if needed

## Troubleshooting

### Build Issues

```bash
# If Knowhere library not found:
# 1. Check that external/knowhere/build/Release/libknowhere.so exists
# 2. Ensure Conan dependencies are built in Knowhere

# If missing system packages:
sudo apt update
sudo apt install libxxhash-dev libopenblas-dev nlohmann-json3-dev \
                 libboost-all-dev libgoogle-glog-dev

# Clean build
rm -rf build && ./build.sh
```

### Runtime Issues

```bash
# If server fails to start:
# 1. Check port 8080 is not in use: netstat -tlnp | grep 8080
# 2. Check flat_index.bin permissions in build directory
# 3. Verify vector dimensions match expectations (384)

# If search returns no results:
# 1. Insert some vectors first
# 2. Ensure query vector has exactly 384 dimensions  
# 3. Check server logs for error messages
```

## Performance Characteristics

- **Search Latency**: Sub-millisecond for typical queries
- **Insert Latency**: Microseconds (append-only operation)
- **Memory Usage**: Minimal due to mmap (only working set in RAM)
- **Throughput**: High concurrent read/write operations

## File Format

### HNSW Index File
- Binary format compatible with Knowhere HNSW serialization
- Memory-mapped for zero-copy loading

### Flat Index File
- Format: `[vector_data][id_data]`
- `vector_data`: `MAX_VECTORS * 384 * sizeof(float)` bytes
- `id_data`: `MAX_VECTORS * sizeof(uint64_t)` bytes
- Total size: ~150MB for 100K vectors

## Error Handling

- **Insert Failures**: When flat index is full
- **Search Failures**: Invalid vector dimensions or server errors
- **Connection Failures**: Network or server unavailability

## Limitations

- Fixed vector dimensions (384)
- Fixed flat index capacity (100K vectors)
- No vector deletion (append-only)
- L2 distance metric only
- Single HNSW index (no dynamic updates)

## Future Enhancements

- [ ] Dynamic vector dimensions support
- [ ] HNSW index rebuilding with flat index data  
- [ ] Vector deletion and updates
- [ ] Multiple distance metrics (cosine, inner product)
- [ ] Distributed deployment support
- [ ] Persistent storage guarantees
- [ ] Authentication and authorization
- [ ] Configurable server parameters (port, host, limits)
- [ ] Metrics and monitoring endpoints
- [ ] Batch operations API
- [ ] Index compression and optimization

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes in the `src/` directory
4. Test your changes with `./build.sh && ./test_server.sh`
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## License

This project is part of the CXLSHMSWcoherence research project. See the repository root for license information.

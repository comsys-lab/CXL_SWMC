# VectorDB

Advanced vector database implementation using Knowhere HNSW index with append-only flat index, supporting concurrent search and insert operations via REST API.

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

- C++17 compatible compiler
- CMake 3.16+
- Knowhere library (built and installed)
- OpenSSL (for HTTPS support)

## Dependencies

The following dependencies are automatically downloaded:
- [cpp-httplib](https://github.com/yhirose/cpp-httplib) - HTTP server library
- [nlohmann/json](https://github.com/nlohmann/json) - JSON parsing library

## Building

1. **Prepare HNSW Index**:
   First, build an HNSW index using the example in `../knowhere_cpp/`:
   ```bash
   cd ../knowhere_cpp/
   # Build and run advanced_mmap_example to create hnsw_index.bin
   ```

2. **Build VectorDB**:
   ```bash
   mkdir build && cd build
   cmake ..
   make -j$(nproc)
   ```

## Usage

### Starting the Server

```bash
# Using default parameters
./vector_db_server

# With custom parameters
./vector_db_server <hnsw_index_path> <flat_index_path> <port>

# Example
./vector_db_server ../knowhere_cpp/hnsw_index.bin flat_index.bin 8080
```

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

Use the provided test script to verify the server:

```bash
# Test with default server (localhost:8080)
./test_server.sh

# Test with custom server
./test_server.sh <host> <port>
```

The test script will:
1. Check server health
2. Query server status
3. Insert 5 random vectors
4. Perform 3 search queries
5. Display final status

## Configuration

### Vector Dimensions
- Default: 384 dimensions
- To change: modify `VECTOR_DIM` constant in headers and rebuild

### Flat Index Capacity
- Default: 100,000 vectors
- To change: modify `MAX_VECTORS` in `AppendOnlyFlatIndex` class

### HNSW Parameters
- ef: 200 (search quality)
- Metric: L2 distance

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

- [ ] Dynamic vector dimensions
- [ ] Index rebuilding with flat index data
- [ ] Vector deletion support
- [ ] Multiple distance metrics
- [ ] Distributed deployment
- [ ] Persistence guarantees
- [ ] Authentication and authorization

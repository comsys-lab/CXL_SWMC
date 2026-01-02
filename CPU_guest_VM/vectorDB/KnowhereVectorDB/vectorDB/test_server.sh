#!/bin/bash

# VectorDB Server Test Script using curl
# Usage: ./test_server.sh [host] [port]

# Default values
HOST=${1:-localhost}
PORT=${2:-8080}
BASE_URL="http://${HOST}:${PORT}"

echo "===================="
echo "VectorDB Server Test"
echo "===================="
echo "Server: $BASE_URL"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to generate random vector (768 dimensions)
generate_random_vector() {
    python3 -c "
import random
import json
vector = [round(random.uniform(-1, 1), 6) for _ in range(768)]
print(json.dumps(vector))
"
}

# Function to test API endpoint
test_endpoint() {
    local method=$1
    local endpoint=$2
    local data=$3
    local description=$4
    
    echo -e "${YELLOW}Testing: $description${NC}"
    
    if [ -n "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X $method \
                   -H "Content-Type: application/json" \
                   -d "$data" \
                   "$BASE_URL$endpoint")
    else
        response=$(curl -s -w "\n%{http_code}" -X $method "$BASE_URL$endpoint")
    fi
    
    # Split response and status code
    body=$(echo "$response" | head -n -1)
    status_code=$(echo "$response" | tail -n 1)
    
    if [ "$status_code" -eq 200 ]; then
        echo -e "${GREEN}✓ Success (HTTP $status_code)${NC}"
        echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
    else
        echo -e "${RED}✗ Failed (HTTP $status_code)${NC}"
        echo "$body"
    fi
    echo ""
}

# 1. Health Check
echo "1. Health Check"
test_endpoint "GET" "/health" "" "Server health status"

# 2. Status Check
echo "2. Status Check"
test_endpoint "GET" "/api/status" "" "Server status information"

# # 3. Insert Vectors
# echo "3. Insert Test Vectors"
# vector_ids=()

# for i in {1..3}; do
#     echo "Inserting vector $i/3..."
#     vector=$(generate_random_vector)
#     data="{\"vector\": $vector}"
    
#     response=$(curl -s -w "\n%{http_code}" -X POST \
#                -H "Content-Type: application/json" \
#                -d "$data" \
#                "$BASE_URL/api/vectors")
    
#     body=$(echo "$response" | head -n -1)
#     status_code=$(echo "$response" | tail -n 1)
    
#     if [ "$status_code" -eq 200 ]; then
#         # Extract ID from response
#         id=$(echo "$body" | python3 -c "
# import json, sys
# try:
#     data = json.load(sys.stdin)
#     print(data['data']['id'])
# except:
#     print('0')
# ")
#         vector_ids+=($id)
#         echo -e "${GREEN}✓ Vector $i inserted with ID: $id${NC}"
#     else
#         echo -e "${RED}✗ Failed to insert vector $i (HTTP $status_code)${NC}"
#         echo "$body"
#     fi
# done
# echo ""

# 4. Search Tests
echo "4. Search Test Queries"

for i in {1..3}; do
    echo "Search query $i/3..."
    query_vector=$(generate_random_vector)
    search_data="{\"vector\": $query_vector, \"k\": 10}"
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
               -H "Content-Type: application/json" \
               -d "$search_data" \
               "$BASE_URL/api/search")
    
    body=$(echo "$response" | head -n -1)
    status_code=$(echo "$response" | tail -n 1)
    
    if [ "$status_code" -eq 200 ]; then
        echo -e "${GREEN}✓ Search query $i completed${NC}"
        echo "$body" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    results = data['data']['results']
    search_time = data['data']['search_time_us']
    print(f'  Found {len(results)} results in {search_time} microseconds')
    for j, result in enumerate(results[:5]):  # Show top 5
        print(f'    {j+1}. ID: {result[\"id\"]}, Distance: {result[\"distance\"]:.6f}')
    if len(results) > 5:
        print(f'    ... and {len(results)-5} more results')
except Exception as e:
    print(f'  Error parsing response: {e}')
"
    else
        echo -e "${RED}✗ Search query $i failed (HTTP $status_code)${NC}"
        echo "$body"
    fi
    echo ""
done

# 5. Final Status Check
echo "5. Final Status Check"
test_endpoint "GET" "/api/status" "" "Final server status"

# 6. Performance Summary
echo "===================="
echo "Test Summary"
echo "===================="
echo "• Inserted ${#vector_ids[@]} vectors"
echo "• Vector IDs: ${vector_ids[*]}"
echo "• Performed 3 search queries"
echo "• Server URL: $BASE_URL"
echo ""

# Check if Python3 is available (needed for JSON parsing)
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Note: python3 not found. JSON responses may not be formatted.${NC}"
fi

echo "Test completed!"

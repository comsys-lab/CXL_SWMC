#!/bin/bash

# Create necessary directories
mkdir -p data/response_cache log

# Build Docker image
docker build -t dummy-llm-server .

# Run the container with host networking
docker run --gpus all \
    --network=host \
    -v /home/cloud_cxl/huggingface_cache:/app/huggingface_cache \
    -v ${PWD}/data:/app/data \
    -v ${PWD}/log:/app/log \
    --shm-size=1g \
    --ulimit memlock=-1 \
    --rm \
    dummy-llm-server

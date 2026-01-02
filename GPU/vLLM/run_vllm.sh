#!/bin/bash

# Set variables
VLLM_IMAGE="vllm/vllm-openai:v0.6.5"
MODEL_NAME="meta-llama/Llama-3.1-8B-Instruct"
CONTAINER_NAME="my_vllm_container"
PORT=8000
MODEL_LEN=40960
HUGGINGFACE_CACHE="$HOME/.cache/huggingface"
TOKEN="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"

# Run vLLM container with --rm
docker run --runtime=nvidia --gpus '"device=1"' \
  -it \
  --name ${CONTAINER_NAME} \
  --rm \
  -p ${PORT}:${PORT} \
  -v ${HUGGINGFACE_CACHE}:/root/.cache/huggingface \
  --env "HUGGING_FACE_HUB_TOKEN=${TOKEN}" \
  --ipc=host \
  ${VLLM_IMAGE} \
  --model ${MODEL_NAME} \
  --port ${PORT} \
  --max_model_len ${MODEL_LEN}

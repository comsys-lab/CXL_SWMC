IMAGE_NAME="ghcr.io/huggingface/text-embeddings-inference:1.8"
CONTAINER_NAME="my_TEI_container"
PORT=8081



docker run --gpus '"device=0"' \
  -it \
  --name ${CONTAINER_NAME} \
  --rm \
  -p ${PORT}:80 \
  -v $PWD/data:/data \
  --pull always \
  ${IMAGE_NAME} \
  --model-id BAAI/bge-base-en-v1.5 \
  --max-client-batch-size 128
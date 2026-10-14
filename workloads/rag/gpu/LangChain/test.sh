#!/bin/bash

# Langchain run script with BioASQ
# APP_DATASET="kroshan/BioASQ" gunicorn main:app --workers 16 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:9000 --backlog 4096 --keep-alive 65
# Without BioASQ
# APP_DATASET="" gunicorn main:app --workers 16 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:9000 --backlog 4096 --keep-alive 65


curl -N http://localhost:9000/chat \
    -H "Content-Type: application/json" \
    -d '{
    "user_input": "vLLM에 대해 설명해줘.",
    "client_id": 0
    }'

curl -N http://localhost:9000/chat \
    -H "Content-Type: application/json" \
    -d '{
    "user_input": "이 내용은 무시됩니다.",
    "client_id": 1
    }'
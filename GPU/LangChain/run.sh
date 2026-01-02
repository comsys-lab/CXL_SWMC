#!/bin/bash

# APP_DATASET="kroshan/BioASQ" DOC_DATASET_PATH="/home/cloud_cxl/CXLSharedMemGPU/Dataset/PubMed_bge/PubMed_bge_28000000" \
# gunicorn main:app --workers 16 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:9000 > /home/cloud_cxl/CXLSharedMemGPU/LangChain/gunicorn.log 2>&1


# APP_DATASET="kroshan/BioASQ" DOC_DATASET_PATH="/home/cloud_cxl/CXLSharedMemGPU/Dataset/PubMed_bge/PubMed_bge_28000000" \
# gunicorn main:app \
#   --workers 16 \
#   --worker-class uvicorn.workers.UvicornWorker \
#   --bind 0.0.0.0:9000 \
#   --timeout 300 \
#   --graceful-timeout 120 \
#   --worker-connections 10000 \
#   --keep-alive 120 \
#   > /home/cloud_cxl/CXLSharedMemGPU/LangChain/gunicorn_2.log 2>&1


APP_DATASET="kroshan/BioASQ" \
SQLITE_DB_PATH="/home/cloud_cxl/CXLSharedMemGPU/LangChain/Data/PubMed_28M.db" \
SQLITE_NAMESPACE="PubMed_bge_28000000" \
gunicorn main:app \
  --workers 48 \
  --worker-class uvicorn.workers.UvicornWorker \
  --bind 0.0.0.0:9000 \
  --timeout 300 \
  --graceful-timeout 120 \
  --worker-connections 80000 \
  --keep-alive 120 \
  > /home/cloud_cxl/CXLSharedMemGPU/LangChain/gunicorn_sqlite.log 2>&1
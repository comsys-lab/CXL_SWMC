# Use NVIDIA CUDA base image
FROM nvidia/cuda:12.1.0-devel-ubuntu22.04

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY requirements.txt .

# Install Python dependencies
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy server code
COPY . .

# Create directories for data and logs
RUN mkdir -p data/response_cache log

# Expose port
EXPOSE 5000

# Run the server
CMD ["python3", "dummy_llm_server.py"]

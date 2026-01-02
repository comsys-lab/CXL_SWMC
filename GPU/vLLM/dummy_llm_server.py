from flask import Flask, request, jsonify
import requests
import time
import logging
import json
from queue import Queue
from threading import Thread
import os
from typing import Dict, List, Optional
from urllib.parse import urljoin
import socket
import random

# Flask app setup
app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")
logger = logging.getLogger(__name__)

# vLLM OpenAI API settings
VLLM_HOST = os.getenv("VLLM_HOST", "localhost")
VLLM_PORT = int(os.getenv("VLLM_PORT", "8000"))
VLLM_API_URL = f"http://{VLLM_HOST}:{VLLM_PORT}/v1/chat/completions"

def is_vllm_server_running() -> bool:
    """Check if vLLM server is running and accessible"""
    try:
        with socket.create_connection((VLLM_HOST, VLLM_PORT), timeout=2.0) as sock:
            return True
    except (socket.timeout, socket.error):
        return False

# Global variables
MODEL_ID = "meta-llama/Llama-3.1-8B-Instruct"
CACHE_DIR = "data/response_cache"
MAX_NEW_TOKENS = 128

# Cache for storing responses
response_cache: Dict[str, Dict] = {}

# Request headers
HEADERS = {
    "Content-Type": "application/json"
}

# Ensure cache directory exists
os.makedirs(CACHE_DIR, exist_ok=True)

# Check vLLM server status
vllm_available = is_vllm_server_running()
if vllm_available:
    logger.info("vLLM server is running and accessible")
else:
    logger.warning("vLLM server is not accessible. Will use cached responses only.")

def get_fallback_response(query_id: str, messages: List[Dict], start_time: float) -> Dict:
    """Generate a fallback response when vLLM server is not available."""
    fallback_text = "I apologize, but I am currently in fallback mode and cannot provide a detailed response. The LLM server is not accessible."
    latency = 0.5  # Fixed latency for fallback responses
    
    result = {
        "query_id": query_id,
        "response": fallback_text,
        "latency": latency,
        "is_fallback": True,
        "timestamp": time.time()
    }
    
    return result

def calculate_token_based_latency(input_text: str, output_text: str) -> float:
    """Calculate simulated latency based on input and output token lengths.
    
    For Llama models:
    - Prefill (KV cache creation): ~0.15s per input token
    - Decode (token generation): ~0.075s per output token
    """
    input_tokens = len(input_text.split())  # Simple tokenization for estimation
    output_tokens = len(output_text.split())
    
    # Base latency for model initialization and API overhead
    base_latency = 0.2  
    
    # Prefill phase (slower for first pass through the input)
    prefill_latency = input_tokens * 0.15  # 150ms per input token
    
    # Decoding phase (generation of new tokens)
    decode_latency = output_tokens * 0.075  # 75ms per output token
    
    total_latency = base_latency + prefill_latency + decode_latency
    
    # Add some random variation (±10%)
    variation = total_latency * 0.1 * (2 * random.random() - 1)
    
    return max(0.1, total_latency + variation)  # Ensure minimum latency of 100ms

def save_response_to_cache(query_id: str, data: Dict) -> None:
    """Save response data to cache file."""
    cache_file = os.path.join(CACHE_DIR, f"{query_id}.json")
    with open(cache_file, "w") as f:
        json.dump(data, f)

def load_response_from_cache(query_id: str) -> Optional[Dict]:
    """Load response data from cache file."""
    cache_file = os.path.join(CACHE_DIR, f"{query_id}.json")
    if os.path.exists(cache_file):
        with open(cache_file, "r") as f:
            return json.load(f)
    return None

def process_real_inference(query_id: str, messages: List[Dict], start_time: float) -> Dict:
    """Process a real LLM inference request using vLLM OpenAI API."""
    if not vllm_available:
        logger.warning("vLLM server is not accessible, using fallback response")
        return get_fallback_response(query_id, messages, start_time)
        
    try:
        payload = {
            "model": MODEL_ID,
            "messages": messages
        }
        
        response = requests.post(VLLM_API_URL, headers=HEADERS, json=payload, timeout=10.0)
        response.raise_for_status()
        
        vllm_response = response.json()
        end_time = time.time()
        latency = end_time - start_time
        
        result = {
            "query_id": query_id,
            "response": vllm_response["choices"][0]["message"]["content"],
            "latency": latency,
            "is_real": True,
            "timestamp": time.time(),
            "raw_response": vllm_response
        }
        
        # Save to cache for future replay
        save_response_to_cache(query_id, result)
        return result
        
    except requests.exceptions.RequestException as e:
        logger.error(f"Error in real inference for query {query_id}: {str(e)}")
        return get_fallback_response(query_id, messages, start_time)

def process_cached_inference(query_id: str, messages: List[Dict], start_time: float) -> Dict:
    """Process a cached inference request."""
    cached_data = load_response_from_cache(query_id)
    if not cached_data:
        # Fallback to real inference if cache miss
        return process_real_inference(query_id, messages, start_time)
    
    # Calculate simulated latency based on input and output lengths
    input_text = " ".join([msg["content"] for msg in messages])
    simulated_latency = calculate_token_based_latency(input_text, cached_data["response"])
    time.sleep(simulated_latency)  # Simulate processing time
    
    result = {
        "query_id": query_id,
        "response": cached_data["response"],
        "latency": simulated_latency,
        "is_cached": True,
        "original_latency": cached_data["latency"],
        "timestamp": time.time(),
        "raw_response": cached_data.get("raw_response")
    }
    
    return result

@app.route("/v1/chat/completions", methods=["POST"])
def chat_completions():
    """OpenAI-compatible chat completions endpoint"""
    data = request.json
    messages = data.get("messages", [])
    query_id = data.get("query_id", str(time.time()))
    start_time = time.time()
    
    logger.info(f"Received chat request - Query ID: {query_id}")
    
    try:
        # Check if we should use real inference or cached response
        if not os.listdir(CACHE_DIR) and vllm_available:  # Try real inference if cache empty and server available
            result = process_real_inference(query_id, messages, start_time)
        else:
            result = process_cached_inference(query_id, messages, start_time)
        
        # Format response in OpenAI API format
        response = {
            "id": f"chatcmpl-{query_id}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": MODEL_ID,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": result["response"]
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": result.get("raw_response", {}).get("usage", {}),
            "_internal": {
                "latency": result["latency"],
                "is_cached": result.get("is_cached", False),
                "is_fallback": result.get("is_fallback", False)
            }
        }
        
        logger.info(f"Completed request - Query ID: {query_id}, Latency: {result['latency']:.4f}s")
        return jsonify(response)
        
    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
        return jsonify({
            "error": {
                "message": str(e),
                "type": "internal_error",
                "query_id": query_id
            }
        }), 500

@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint"""
    status = {
        "status": "ok",
        "message": "DummyLLM server is running",
        "vllm_server": "available" if vllm_available else "unavailable",
        "cache_size": len(os.listdir(CACHE_DIR))
    }
    return jsonify(status)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

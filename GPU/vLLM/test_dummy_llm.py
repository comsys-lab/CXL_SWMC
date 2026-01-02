#!/usr/bin/env python3
import requests
import time
import json
import argparse
from typing import Dict, List
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('log/test.log')
    ]
)
logger = logging.getLogger(__name__)

def send_request(url: str, query_id: str, prompt: str) -> Dict:
    """Send a request to the LLM server and return the response."""
    data = {
        "query_id": query_id,
        "prompt": prompt
    }
    
    try:
        response = requests.post(f"{url}/generate", json=data)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Request failed for query {query_id}: {e}")
        return None

def run_test(url: str, num_requests: int = 5):
    """Run test scenarios for the DummyLLM server."""
    test_prompts = [
        "What is machine learning?",
        "Explain quantum computing",
        "How does natural language processing work?",
        "What are neural networks?",
        "Describe deep learning"
    ]
    
    results = []
    
    # First request - should trigger real inference
    logger.info("Testing real inference...")
    start_time = time.time()
    response = send_request(url, "test_real_1", test_prompts[0])
    if response:
        logger.info(f"Real inference latency: {response['latency']:.4f}s")
        results.append(response)
    
    # Subsequent requests - should use cache
    logger.info("\nTesting cached responses...")
    for i in range(1, num_requests):
        prompt_idx = i % len(test_prompts)
        response = send_request(url, f"test_cached_{i}", test_prompts[prompt_idx])
        if response:
            logger.info(f"Request {i} latency: {response['latency']:.4f}s")
            results.append(response)
        time.sleep(1)  # Add small delay between requests
    
    # Calculate and log statistics
    latencies = [r['latency'] for r in results if r]
    if latencies:
        avg_latency = sum(latencies) / len(latencies)
        max_latency = max(latencies)
        min_latency = min(latencies)
        
        logger.info("\nTest Results:")
        logger.info(f"Total requests: {len(results)}")
        logger.info(f"Average latency: {avg_latency:.4f}s")
        logger.info(f"Max latency: {max_latency:.4f}s")
        logger.info(f"Min latency: {min_latency:.4f}s")
        
        # Save results to file
        with open('log/test_results.json', 'w') as f:
            json.dump(results, f, indent=2)

def main():
    parser = argparse.ArgumentParser(description='Test DummyLLM server')
    parser.add_argument('--url', default='http://localhost:5000',
                      help='Server URL (default: http://localhost:5000)')
    parser.add_argument('--requests', type=int, default=5,
                      help='Number of test requests (default: 5)')
    
    args = parser.parse_args()
    
    # Check server health
    try:
        health_response = requests.get(f"{args.url}/health")
        health_response.raise_for_status()
        logger.info("Server is healthy, starting tests...")
    except requests.exceptions.RequestException as e:
        logger.error(f"Server health check failed: {e}")
        return
    
    run_test(args.url, args.requests)

if __name__ == "__main__":
    main()

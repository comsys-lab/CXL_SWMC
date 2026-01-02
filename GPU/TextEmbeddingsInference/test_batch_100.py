import json
import subprocess
import time

# 100개의 문장 생성
data = {
    "inputs": ["This is a test sentence for MPNet."] * 100
}

# JSON 파일 저장
with open("batch_100.json", "w") as f:
    json.dump(data, f)

# curl로 전송 + 응답 시간 측정
print("Sending batch of 100 inputs...")

start = time.time()
subprocess.run([
    "curl", "-s", "-X", "POST", "http://localhost:8080/embed",
    "-H", "Content-Type: application/json",
    "-d", "@batch_100.json"
], stdout=subprocess.DEVNULL)
end = time.time()

print(f"Total elapsed time: {end - start:.3f} seconds")

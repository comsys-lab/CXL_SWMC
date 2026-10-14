BioASQ Yes/No Benchmark Plan and Usage

Goal
- Measure accuracy only on BioASQ yes/no questions.
- Send every request to /chat with client_id=0.
- Force the model to answer with yes or no only.
- Save request and response logs in JSON so accuracy can be recomputed later.

Plan
1. Read BioASQ JSONL and filter question_type == yesno.
2. Build a forced prompt that demands exactly yes or no.
3. Call /chat with payload:
   - user_input: forced prompt
   - client_id: 0
4. Parse streamed response and remove latency tail marker.
5. Extract predicted label from response using yes/no normalization.
6. Compare prediction with gold label and compute accuracy.
7. Save all records and summary to runs/*.json.
8. Recompute accuracy later from saved JSON without calling /chat again.

Files
- run_bioasq_yesno_benchmark.py: runs benchmark and stores logs.
- recompute_yesno_accuracy.py: recalculates accuracy from saved run JSON.
- runs/: output directory for run logs.

How to run
1. Move to benchmark directory:
   cd /home/comsys/CXL_SWMC/GPU/benchmark

2. Run benchmark:
   python3 run_bioasq_yesno_benchmark.py \
     --dataset ../Dataset/bioasq/bioasq_questions.json \
     --chat-url http://127.0.0.1:9000/chat

3. Optional: limit number of questions for quick test:
   python3 run_bioasq_yesno_benchmark.py \
     --dataset ../Dataset/bioasq/bioasq_questions.json \
     --chat-url http://127.0.0.1:9000/chat \
     --max-questions 20

4. Recompute accuracy from a saved file:
   python3 recompute_yesno_accuracy.py --run-json runs/bioasq_yesno_run_YYYYMMDD_HHMMSS.json

Accuracy definition
- Let V be number of valid predictions where model output is normalized to yes or no.
- Let C be number of correct predictions among valid predictions.
- Accuracy = C / V.

Notes
- If output does not contain yes or no, it is counted as invalid prediction.
- Invalid predictions are tracked separately and excluded from accuracy denominator.
- Each record stores:
  - question id
  - original question
  - forced prompt
  - gold answer
  - raw response
  - normalized prediction
  - correctness
  - http status and error info

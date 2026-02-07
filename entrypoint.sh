#!/bin/bash
set -e

# ============================================================
# Startup sequence:
#   1. Substitute env vars (VLLM_MODEL) in agent config
#   2. Test vLLM inference
#   3. Start Controller (port 5000)
#   4. Start DBBench workers → ALFWorld workers
#   5. Run Assigner
# ============================================================

# 1. Substitute environment variables in agent config
echo "[1/5] Substituting VLLM_MODEL=${VLLM_MODEL} in agent config..."
envsubst < configs/agents/api_agents.yaml > /tmp/api_agents.yaml
cp /tmp/api_agents.yaml configs/agents/api_agents.yaml
cat configs/agents/api_agents.yaml

# 2. Test vLLM inference
echo "[2/5] Testing vLLM inference..."
MAX_RETRIES=30
for i in $(seq 1 $MAX_RETRIES); do
  HTTP_CODE=$(curl -s -o /tmp/vllm_test.json -w "%{http_code}" \
    -X POST http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${VLLM_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}], \"max_tokens\": 16}" \
    2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "vLLM inference test PASSED"
    cat /tmp/vllm_test.json | python -m json.tool 2>/dev/null || cat /tmp/vllm_test.json
    break
  fi
  if [ "$i" = "$MAX_RETRIES" ]; then
    echo "ERROR: vLLM inference test FAILED after ${MAX_RETRIES} retries (HTTP ${HTTP_CODE})"
    cat /tmp/vllm_test.json 2>/dev/null
    exit 1
  fi
  echo "  Waiting for vLLM... (${i}/${MAX_RETRIES}, HTTP ${HTTP_CODE})"
  sleep 10
done

# 3-4. Start Controller → DBBench workers → ALFWorld workers
#   start_task.py -a starts:
#     - Controller on port 5000
#     - Workers in config order (dbbench-std first, then alfworld-std)
echo "[3/5] Starting Controller (port 5000)..."
echo "[4/5] Starting Task Workers (DBBench → ALFWorld)..."
python -m src.start_task -a &
TASK_PID=$!

# Wait for controller + workers to be fully registered
echo "  Waiting for Controller and Workers to register..."
for i in $(seq 1 30); do
  WORKERS=$(curl -sf http://localhost:5000/api/list_workers 2>/dev/null || echo "")
  if echo "$WORKERS" | python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tasks = set()
    for w in data:
        tasks.add(w.get('task_name', ''))
    if 'dbbench-std' in tasks and 'alfworld-std' in tasks:
        print('All workers registered')
        sys.exit(0)
except:
    pass
sys.exit(1)
" 2>/dev/null; then
    break
  fi
  if [ "$i" = "30" ]; then
    echo "WARNING: Not all workers registered after 30s, proceeding anyway..."
  fi
  sleep 1
done

# 5. Run Assigner
echo "[5/5] Starting Assigner..."
python -m src.assigner configs/assignments/default.yaml
ASSIGNER_EXIT=$?

echo "Assigner finished with exit code ${ASSIGNER_EXIT}"

# Keep workers alive for result inspection (optional: remove if not needed)
if [ -n "$TASK_PID" ]; then
  kill $TASK_PID 2>/dev/null || true
  wait $TASK_PID 2>/dev/null || true
fi

exit $ASSIGNER_EXIT

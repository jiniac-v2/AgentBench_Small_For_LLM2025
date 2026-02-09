#!/bin/bash
set -e

# ============================================================
# AgentBench Local Execution Script
#
# Usage:
#   export VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
#   bash scripts/run.sh
#
# Prerequisites:
#   - Python 3.9+ with requirements.txt installed
#   - Docker with NVIDIA GPU support (for vLLM + MySQL)
#   - vLLM running on localhost:8000
#     e.g. docker compose up -d
#     or:  docker run --rm --gpus all --ipc=host -p 8000:8000 \
#            vllm/vllm-openai:v0.13.0 \
#            --model "$VLLM_MODEL" --max-model-len 8192 \
#            --gpu-memory-utilization 0.95
# ============================================================

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
PIDS=()

cleanup() {
  echo "Cleaning up..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "=== AgentBench Local Runner ==="
echo "Model: ${VLLM_MODEL}"

# 1. Substitute model name in agent config
echo "[1/5] Configuring agent for model: ${VLLM_MODEL}"
sed "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" configs/agents/api_agents.yaml > /tmp/api_agents.yaml
cp /tmp/api_agents.yaml configs/agents/api_agents.yaml
cat configs/agents/api_agents.yaml

# 2. Test vLLM inference
echo "[2/5] Testing vLLM inference..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -s -o /tmp/vllm_test.json -w "%{http_code}" \
    -X POST http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${VLLM_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}], \"max_tokens\": 16}" \
    2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  vLLM inference test PASSED"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "  ERROR: vLLM not responding. Is it running on localhost:8000?"
    exit 1
  fi
  echo "  Waiting for vLLM... (${i}/30)"
  sleep 10
done

# 3. Start Controller (port 5020)
echo "[3/5] Starting Controller (port 5020)..."
python3 -m src.server.task_controller -p 5020 &
PIDS+=($!)

# Wait for controller to be ready
for i in $(seq 1 30); do
  if curl -sf http://localhost:5020/api/list_workers > /dev/null 2>&1; then
    echo "  Controller is ready"
    break
  fi
  sleep 1
done

# 4. Start Workers: DBBench (port 5023) → ALFWorld (port 5021)
echo "[4/5] Starting DBBench Worker (port 5023)..."
python3 -m src.server.task_worker dbbench-std \
  -c configs/tasks/dbbench.yaml \
  -C http://localhost:5020/api \
  -s http://localhost:5023/api \
  -p 5023 &
PIDS+=($!)

echo "       Starting ALFWorld Worker (port 5021)..."
python3 -m src.server.task_worker alfworld-std \
  -c configs/tasks/alfworld.yaml \
  -C http://localhost:5020/api \
  -s http://localhost:5021/api \
  -p 5021 &
PIDS+=($!)

# Wait for workers to register
for i in $(seq 1 60); do
  WORKERS=$(curl -sf http://localhost:5020/api/list_workers 2>/dev/null || echo "")
  if echo "$WORKERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = {w.get('task_name','') for w in data}
assert 'dbbench-std' in tasks and 'alfworld-std' in tasks
" 2>/dev/null; then
    echo "  All workers registered"
    break
  fi
  sleep 2
done

# 5. Run Assigner
echo "[5/5] Starting Assigner..."
python3 -m src.assigner configs/assignments/default.yaml
EXIT_CODE=$?

echo "=== Done (exit code: ${EXIT_CODE}) ==="
exit $EXIT_CODE

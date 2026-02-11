#!/bin/bash
set -e

# ============================================================
# AgentBench Local Service Launcher
#
# Usage:
#   export VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
#   bash scripts/eval/run.sh
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
#
# このスクリプトは Controller + Worker を起動し、評価を実行して終了します。
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
echo "[1/4] Configuring agent for model: ${VLLM_MODEL}"
sed "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" configs/agents/api_agents.yaml > /tmp/api_agents.yaml
cp /tmp/api_agents.yaml configs/agents/api_agents.yaml
cat configs/agents/api_agents.yaml

# 2. Test vLLM inference
echo "[2/4] Testing vLLM inference..."
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
echo "[3/4] Starting Controller (port 5020)..."
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

# 4. Start Workers: DBBench (port 5023) + ALFWorld (port 5021)
echo "[4/4] Starting DBBench Worker (port 5023)..."
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

# Wait for workers to register (at least dbbench-std; alfworld-std is optional)
REGISTERED=""
for i in $(seq 1 60); do
  WORKERS=$(curl -sf http://localhost:5020/api/list_workers 2>/dev/null || echo "")
  REGISTERED=$(echo "$WORKERS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tasks = {w.get('task_name','') for w in data}
    print(' '.join(sorted(tasks - {''})))
except: pass
" 2>/dev/null)
  if echo "$REGISTERED" | grep -q "dbbench-std"; then
    break
  fi
  sleep 2
done
if echo "$REGISTERED" | grep -q "dbbench-std"; then
  echo "  Registered workers: ${REGISTERED}"
  if ! echo "$REGISTERED" | grep -q "alfworld-std"; then
    echo "  WARNING: alfworld-std failed to register (gym not installed?). Skipping ALFWorld."
  fi
else
  echo "  ERROR: dbbench-std did not register within 120s"
  exit 1
fi

echo ""
echo "=== Services ready. Running evaluation... ==="
echo ""

mkdir -p outputs
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "=== Evaluation finished (exit code: ${EXIT_CODE}) ==="
echo "Log: outputs/execution.log"
exit ${EXIT_CODE}

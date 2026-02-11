#!/bin/bash
set -e

# ============================================================
# AgentBench 評価実行スクリプト
#
# Usage:
#   bash scripts/eval/run.sh
#
# Prerequisites:
#   - vLLM が localhost:8000 で稼働中 (systemd or docker compose)
#   - Python 依存パッケージインストール済み (setup-vm.sh)
#
# 処理内容:
#   1. agent config のモデル名を設定
#   2. vLLM の疎通確認
#   3. Controller + Workers を起動 (start_task -a)
#   4. Assigner で評価実行
#   5. 完了後に全プロセスをクリーンアップ
# ============================================================

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
PIDS=()

cleanup() {
  echo ""
  echo "Cleaning up..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

echo "=== AgentBench Evaluation ==="
echo "Model: ${VLLM_MODEL}"

# 1. agent config のモデル名を設定
echo "[1/4] Configuring agent for model: ${VLLM_MODEL}"
sed -i "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" configs/agents/api_agents.yaml
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" configs/agents/api_agents.yaml
cat configs/agents/api_agents.yaml

# 2. vLLM の疎通確認
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

# 3. Controller + Workers を起動
echo "[3/4] Starting Controller + Workers..."
python3 -m src.start_task -a &
PIDS+=($!)

# Workers の登録待ち
echo "  Waiting for all workers to register..."
for i in $(seq 1 60); do
  WORKERS=$(curl -sf http://localhost:5020/api/list_workers 2>/dev/null || echo "")
  if echo "$WORKERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = {w.get('task_name','') for w in data}
assert 'dbbench-std' in tasks and 'alfworld-std' in tasks
" 2>/dev/null; then
    echo "  All workers registered: dbbench-std, alfworld-std"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "  ERROR: Workers did not register within 120s"
    echo "  Check: python3 -c 'import gym; import alfworld'"
    exit 1
  fi
  sleep 2
done

# 4. 評価実行
echo "[4/4] Running evaluation..."
echo ""

mkdir -p outputs
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "=== Evaluation finished (exit code: ${EXIT_CODE}) ==="
echo "Log: outputs/execution.log"
exit ${EXIT_CODE}

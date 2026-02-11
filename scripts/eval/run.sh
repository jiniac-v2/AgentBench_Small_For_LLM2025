#!/bin/bash
set -e

# ============================================================
# AgentBench プリフライトチェック
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
#   3. Controller + Workers を一時起動し、全 worker の登録を確認
#   チェック完了後、起動したプロセスを停止して終了する。
#
# 評価の実行:
#   python3 -m src.start_task -a   # ターミナルでサーバー起動
#   # 別ターミナルで:
#   python3 -m src.assigner -c configs/assignments/default.yaml
# ============================================================

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
BG_PID=""

cleanup() {
  if [ -n "$BG_PID" ]; then
    kill "$BG_PID" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== AgentBench Preflight Check ==="
echo "Model: ${VLLM_MODEL}"

# 1. agent config のモデル名を設定
echo "[1/3] Configuring agent for model: ${VLLM_MODEL}"
sed -i "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" configs/agents/api_agents.yaml
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" configs/agents/api_agents.yaml
cat configs/agents/api_agents.yaml

# 2. vLLM の疎通確認
echo "[2/3] Checking vLLM..."

# systemd サービスが存在すればプロセス状態を確認
if systemctl is-active agentbench-vllm &>/dev/null; then
  echo "  systemd: agentbench-vllm is active"
elif systemctl list-unit-files agentbench-vllm.service &>/dev/null 2>&1; then
  echo "  ERROR: agentbench-vllm service exists but is not running"
  echo "  Run: sudo journalctl -u agentbench-vllm -n 20"
  exit 1
fi

# /v1/models で API の応答を待つ (軽量エンドポイント)
for i in $(seq 1 60); do
  if curl -sf http://localhost:8000/v1/models -o /dev/null 2>/dev/null; then
    echo "  vLLM API ready (localhost:8000)"
    # モデル名の確認
    MODELS=$(curl -sf http://localhost:8000/v1/models 2>/dev/null || echo "")
    echo "  Loaded models: $(echo "$MODELS" | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin).get("data",[])]' 2>/dev/null || echo '(unknown)')"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "  ERROR: vLLM not responding on localhost:8000 after 60s"
    echo "  Check: curl http://localhost:8000/v1/models"
    exit 1
  fi
  sleep 1
done

# 3. Controller + Workers を一時起動して登録確認
echo "[3/3] Starting Controller + Workers (temporary)..."
# start_task.py は while True: input() で待機する設計なので
# バックグラウンド実行時は stdin を開いたままにする
tail -f /dev/null | python3 -m src.start_task -a &
BG_PID=$!

# Workers の登録待ち
echo "  Waiting for all workers to register..."
CHECK_OK=false
for i in $(seq 1 60); do
  WORKERS=$(curl -sf http://localhost:5000/api/list_workers 2>/dev/null || echo "")
  if echo "$WORKERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tasks = {w.get('task_name','') for w in data}
assert 'dbbench-std' in tasks and 'alfworld-std' in tasks
" 2>/dev/null; then
    echo "  All workers registered: dbbench-std, alfworld-std"
    CHECK_OK=true
    break
  fi
  if [ "$i" = "60" ]; then
    echo "  ERROR: Workers did not register within 120s"
    echo "  Check: python3 -c 'import gym; import alfworld'"
  fi
  sleep 2
done

# 一時プロセスを停止 (trap cleanup でも止まるが明示的に)
echo "  Stopping temporary server..."
cleanup
BG_PID=""

echo ""
if $CHECK_OK; then
  echo "=== All checks passed ==="
  echo ""
  echo "To run evaluation:"
  echo "  1. python3 -m src.start_task -a"
  echo "  2. (別ターミナル) python3 -m src.assigner -c configs/assignments/default.yaml"
  exit 0
else
  echo "=== Checks FAILED ==="
  exit 1
fi

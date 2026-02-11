#!/bin/bash
set -e

# ============================================================
# AgentBench タスクサーバー起動スクリプト
#
# Usage:
#   bash scripts/eval/run.sh        # サーバー起動 + worker 登録確認
#   bash scripts/eval/run.sh stop   # サーバー停止
#
# Prerequisites:
#   - vLLM が localhost:8000 で稼働中 (systemd or docker compose)
#   - Python 依存パッケージインストール済み (setup-vm.sh)
#
# 処理内容:
#   1. agent config のモデル名を設定
#   2. vLLM の疎通確認
#   3. Controller + Workers をバックグラウンド起動し、worker 登録を確認
#   成功したらサーバーは動いたままスクリプト終了。
#   失敗したらサーバーを停止して exit 1。
#
# 評価の実行:
#   python3 -m src.assigner -c configs/assignments/default.yaml
#
# サーバーの停止:
#   bash scripts/eval/run.sh stop
# ============================================================

PIDFILE="/tmp/agentbench-server.pid"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"

# --- stop サブコマンド ---
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    echo "Stopping AgentBench server (PID: $PID)..."
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "Stopped."
  else
    echo "No PID file found ($PIDFILE). Server may not be running."
  fi
  exit 0
fi

echo "=== AgentBench Task Server ==="
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

# 3. Controller + Workers をバックグラウンド起動
echo "[3/3] Starting Controller + Workers..."
# start_task.py は while True: input() で待機する設計なので
# バックグラウンド実行時は stdin を開いたままにする
tail -f /dev/null | python3 -m src.start_task -a &
BG_PID=$!
echo "$BG_PID" > "$PIDFILE"

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

echo ""
if $CHECK_OK; then
  echo "=== Task server ready (PID: $BG_PID) ==="
  echo ""
  echo "Run evaluation:"
  echo "  python3 -m src.assigner -c configs/assignments/default.yaml"
  echo ""
  echo "Stop server:"
  echo "  bash scripts/eval/run.sh stop"
  exit 0
else
  echo "=== Startup FAILED — stopping server ==="
  kill "$BG_PID" 2>/dev/null || true
  wait "$BG_PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 1
fi

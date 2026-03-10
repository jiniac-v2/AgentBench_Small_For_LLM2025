#!/bin/bash
set -e

# ============================================================
# Step 2: 評価実行 (タスクサーバー + assigner.py)
#
# Usage:
#   bash eval/step2_evaluate.sh
#
# 処理:
#   1. 既存の run-task-server.sh でタスクサーバーをバックグラウンド起動
#   2. assigner.py で評価実行
#   3. タスクサーバーを停止
#
# Exit code:
#   0 = 評価成功, 1 = 評価失敗
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Activate venv
# shellcheck disable=SC1091
[ -f "${APP_DIR}/.venv/bin/activate" ] && source "${APP_DIR}/.venv/bin/activate"

echo "============================================"
echo " [Step2] 評価実行"
echo "============================================"

# ── 0. .env 読み込み (Step1 で更新された VLLM_MODEL 等を取得) ──

if [ -f "${APP_DIR}/.env" ]; then
    echo "[Step2] .env を読み込み..."
    set -a
    # shellcheck disable=SC1091
    source "${APP_DIR}/.env"
    set +a
    echo "[Step2] VLLM_MODEL=${VLLM_MODEL}"
fi

# ── 1. タスクサーバー起動 ──

echo "[Step2] タスクサーバー起動..."
bash "${APP_DIR}/eval/run-task-server.sh" &
TASK_PID=$!

# タスクサーバーの起動を待つ
echo "[Step2] タスクサーバーの起動待ち..."
task_ready=false
for i in $(seq 1 30); do
    if curl -s --max-time 2 http://localhost:5000/api >/dev/null 2>&1; then
        task_ready=true
        break
    fi
    sleep 2
done

if [ "$task_ready" = false ]; then
    echo "[Step2] WARNING: タスクサーバーの応答を確認できませんが続行します"
fi

# ── 2. assigner.py 実行 ──

echo "[Step2] assigner.py 実行開始..."
cd "${APP_DIR}"
assigner_exit=0
python3 -m src.assigner -c configs/assignments/default.yaml -r || assigner_exit=$?

# ── 3. タスクサーバー停止 ──

echo "[Step2] タスクサーバー停止..."
kill $TASK_PID 2>/dev/null || true
wait $TASK_PID 2>/dev/null || true

# 残存プロセスの掃除 (run-task-server.sh が exec するので念のため)
PIDS=$(lsof -ti :5000-5010 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    echo "[Step2] 残存プロセスを停止: $PIDS"
    echo "$PIDS" | xargs kill 2>/dev/null || true
    sleep 1
    PIDS=$(lsof -ti :5000-5010 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
    fi
fi

if [ $assigner_exit -ne 0 ]; then
    echo "[Step2] ERROR: assigner.py が異常終了 (exit=$assigner_exit)"
    exit 1
fi

echo "[Step2] 評価完了"
exit 0

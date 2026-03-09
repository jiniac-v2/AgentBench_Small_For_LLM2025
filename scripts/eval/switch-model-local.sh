#!/bin/bash
set -e

# ============================================================
# Model Switch Script (ローカル / WSL 版)
#
# systemd ではなく docker compose で vLLM を再起動します。
#
# Usage:
#   1. このファイルの VLLM_MODEL, HF_TOKEN を編集
#   2. bash ~/AgentBench_Small_For_LLM2025/scripts/eval/switch-model-local.sh
#
# 処理内容:
#   1. .env にモデル名・HFトークンを書き込み
#   2. api_agents.yaml のモデル名を更新
#   3. docker compose で vLLM を再起動
# ============================================================

# ---- ここを編集 ----
VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
HF_TOKEN=""
# ---------------------

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== Switching to model: ${VLLM_MODEL} ==="
echo "APP_DIR: ${APP_DIR}"

# 1. Update .env
echo "[1/3] Updating .env..."
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-8192}
VLLM_GPU_MEMORY_UTILIZATION=${VLLM_GPU_MEMORY_UTILIZATION:-0.95}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# 2. Update agent config (インデントされた model: 行のみ)
echo "[2/3] Updating agent config..."
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" "${APP_DIR}/configs/agents/api_agents.yaml"
echo "  Agent config:"
cat "${APP_DIR}/configs/agents/api_agents.yaml"

# 3. Restart vLLM via docker compose
echo "[3/3] Restarting vLLM (docker compose)..."
cd "${APP_DIR}"
docker compose down
docker compose up -d

echo ""
echo "=== Model switched to: ${VLLM_MODEL} ==="
echo ""
echo "vLLM の起動を待ってください (1〜3 分):"
echo "  docker compose logs -f vllm"
echo ""
echo "評価実行:"
echo "  cd ${APP_DIR}"
echo "  bash scripts/eval/run-task-server.sh   # 別ターミナル"
echo "  python3 -m src.assigner -c configs/assignments/default.yaml"
echo ""

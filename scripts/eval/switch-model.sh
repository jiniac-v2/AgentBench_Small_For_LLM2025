#!/bin/bash
set -e

# ============================================================
# Model Switch Script
#
# Usage:
#   sudo bash scripts/eval/switch-model.sh <model-name> [hf-token]
#
# Examples:
#   sudo bash scripts/eval/switch-model.sh Qwen/Qwen2.5-7B-Instruct
#   sudo bash scripts/eval/switch-model.sh nakashi104/Qwen2.5-7B-Instruct hf_xxxx
#
# 処理内容:
#   1. .env にモデル名・HFトークンを書き込み
#   2. vLLM を再起動
#
# api_agents.yaml は ${VLLM_MODEL} プレースホルダを使うため
# 書き換え不要。ConfigLoader が .env から自動展開する。
# ============================================================

if [ -z "$1" ]; then
  echo "Usage: sudo bash $0 <model-name> [hf-token]"
  echo ""
  echo "Examples:"
  echo "  sudo bash $0 Qwen/Qwen2.5-7B-Instruct"
  echo "  sudo bash $0 nakashi104/Qwen2.5-7B-Instruct hf_xxxx"
  exit 1
fi

VLLM_MODEL="$1"
HF_TOKEN="${2:-}"

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== Switching to model: ${VLLM_MODEL} ==="
echo "APP_DIR: ${APP_DIR}"

# 1. Update .env (single source of truth)
echo "[1/2] Updating .env..."
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF
echo "  .env:"
cat "${APP_DIR}/.env"

# 2. Restart vLLM
echo "[2/2] Restarting vLLM..."
systemctl daemon-reload
systemctl restart agentbench-vllm

echo ""
echo "=== Model switched to: ${VLLM_MODEL} ==="
echo ""
echo "確認:"
echo "  sudo journalctl -u agentbench-vllm -f"
echo ""
echo "評価実行:"
echo "  cd ${APP_DIR}"
echo "  bash scripts/eval/run-task-server.sh   # ターミナル1"
echo "  python3 -m src.assigner -c configs/assignments/default.yaml  # ターミナル2"
echo ""

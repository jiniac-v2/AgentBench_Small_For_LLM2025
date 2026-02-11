#!/bin/bash
set -e

# ============================================================
# Model Switch & Evaluation Script
#
# Usage:
#   1. このファイルの VLLM_MODEL, HF_TOKEN を編集
#   2. sudo bash ~/AgentBench_Small_For_LLM2025/scripts/switch-model.sh
#
# 処理内容:
#   1. .env にモデル名・HFトークンを書き込み
#   2. api_agents.yaml のモデル名を更新
#   3. vLLM + 全サービスを再起動
#   4. 前回の出力をクリア
#   5. Assigner (評価) を実行
# ============================================================

# ---- ここを編集 ----
VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
HF_TOKEN=""
# ---------------------

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Switching to model: ${VLLM_MODEL} ==="
echo "APP_DIR: ${APP_DIR}"

# 1. Update .env
echo "[1/5] Updating .env..."
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# 2. Update agent config
echo "[2/5] Updating agent config..."
sed -i "s|model:.*|model: \"${VLLM_MODEL}\"|" "${APP_DIR}/configs/agents/api_agents.yaml"
echo "  Agent config:"
cat "${APP_DIR}/configs/agents/api_agents.yaml"

# 3. Restart all services
echo "[3/5] Restarting services..."
systemctl restart agentbench-vllm
systemctl restart agentbench-controller
systemctl restart agentbench-worker-dbbench
systemctl restart agentbench-worker-alfworld

# 4. Clear previous outputs
echo "[4/5] Clearing previous outputs..."
rm -rf "${APP_DIR}/outputs/"*

# 5. Run Assigner (evaluation)
echo "[5/5] Starting evaluation..."
systemctl restart agentbench-assigner

echo ""
echo "=== Evaluation started ==="
echo "Monitor progress:"
echo "  sudo journalctl -u agentbench-assigner -f"
echo ""
echo "Results will be in: ${APP_DIR}/outputs/"

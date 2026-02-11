#!/bin/bash
set -e

# ============================================================
# Model Switch & Evaluation Script
#
# Usage:
#   sudo bash scripts/switch-model.sh <model-name> [hf-token]
#
# Examples:
#   sudo bash scripts/switch-model.sh Qwen/Qwen2.5-7B-Instruct
#   sudo bash scripts/switch-model.sh your-org/your-model hf_xxxxxxxxxxxxx
#
# This script:
#   1. Updates .env with the new model name (and optional HF token)
#   2. Updates agent config (api_agents.yaml)
#   3. Restarts vLLM + all AgentBench services
#   4. Clears previous outputs
#   5. Runs the Assigner (evaluation)
# ============================================================

APP_DIR="/opt/agentbench"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <model-name> [hf-token]"
  echo ""
  echo "Examples:"
  echo "  $0 Qwen/Qwen2.5-7B-Instruct"
  echo "  $0 your-org/your-model hf_xxxxxxxxxxxxx"
  exit 1
fi

NEW_MODEL="$1"
HF_TOKEN="${2:-}"

echo "=== Switching to model: ${NEW_MODEL} ==="

# 1. Update .env
echo "[1/5] Updating .env..."
# Read existing HF token if not provided
if [ -z "$HF_TOKEN" ] && [ -f "${APP_DIR}/.env" ]; then
  HF_TOKEN=$(grep -oP 'HUGGING_FACE_HUB_TOKEN=\K.*' "${APP_DIR}/.env" 2>/dev/null || echo "")
fi

cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${NEW_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# 2. Update agent config
echo "[2/5] Updating agent config..."
sed -i "s|model:.*|model: \"${NEW_MODEL}\"|" "${APP_DIR}/configs/agents/api_agents.yaml"
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

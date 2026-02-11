#!/bin/bash
set -e

# ============================================================
# AgentBench VM 環境構築スクリプト
#
# Usage:
#   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup-vm.sh
#
# Prerequisites:
#   - VM が起動済み (terraform apply 完了)
#   - SSH 接続済み
#
# 処理内容:
#   1. Docker / NVIDIA Container Toolkit の確認
#   2. ユーザーを docker グループに追加
#   3. Python 依存パッケージのインストール
#   4. .env / agent config の生成
#   5. Docker イメージの pull
#   6. systemd サービスのインストール・起動
# ============================================================

# ---- 設定 ----
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
HF_TOKEN="${HF_TOKEN:-}"
# ---------------

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Detect the user who invoked sudo (or current user)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"

echo "=== AgentBench VM Setup ==="
echo "APP_DIR:    ${APP_DIR}"
echo "User:       ${ACTUAL_USER}"
echo "VLLM_MODEL: ${VLLM_MODEL}"
echo ""

# ============================================================
# 1. Docker の確認
# ============================================================
echo "[1/6] Checking Docker..."
if ! command -v docker &> /dev/null; then
  echo "  ERROR: Docker is not installed."
  echo "  startup script がまだ完了していない可能性があります。"
  echo "  確認: sudo journalctl -u google-startup-scripts --no-pager"
  exit 1
fi
echo "  Docker OK: $(docker --version)"

# ============================================================
# 2. ユーザーを docker グループに追加
# ============================================================
echo "[2/6] Configuring docker group..."
if ! groups "$ACTUAL_USER" | grep -q docker; then
  usermod -aG docker "$ACTUAL_USER"
  echo "  Added ${ACTUAL_USER} to docker group."
  echo "  (次回ログイン時から sudo なしで docker が使えます)"
else
  echo "  ${ACTUAL_USER} is already in docker group."
fi

# ============================================================
# 3. Python 依存パッケージ
# ============================================================
echo "[3/6] Installing Python dependencies..."
pip3 install -r "${APP_DIR}/requirements.txt"

# ============================================================
# 4. .env / agent config の生成
# ============================================================
echo "[4/6] Generating configuration..."

cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# agent config のモデル名を置換
sed -i "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" "${APP_DIR}/configs/agents/api_agents.yaml"
# 既にモデル名が入っている場合も対応 (switch-model.sh と同じ)
sed -i "s|model:.*|model: \"${VLLM_MODEL}\"|" "${APP_DIR}/configs/agents/api_agents.yaml"

echo "  .env:"
cat "${APP_DIR}/.env"
echo "  Agent config:"
cat "${APP_DIR}/configs/agents/api_agents.yaml"

# ============================================================
# 5. Docker イメージの pull
# ============================================================
echo "[5/6] Pulling Docker images..."
docker pull mysql:9.5.0 &
docker pull vllm/vllm-openai:v0.13.0 &
wait
echo "  Docker images pulled."

# ============================================================
# 6. systemd サービスのインストール・起動
# ============================================================
echo "[6/6] Installing systemd services..."

# /opt/agentbench プレースホルダーを実際の APP_DIR に置換してコピー
for f in "${APP_DIR}/systemd/"*.service; do
  sed "s|/opt/agentbench|${APP_DIR}|g" "$f" > "/etc/systemd/system/$(basename "$f")"
done
systemctl daemon-reload

echo "  Starting agentbench-vllm..."
systemctl enable --now agentbench-vllm

echo "  Starting agentbench-controller..."
systemctl enable --now agentbench-controller

echo "  Starting agentbench-worker-dbbench..."
systemctl enable --now agentbench-worker-dbbench

echo "  Starting agentbench-worker-alfworld..."
systemctl enable --now agentbench-worker-alfworld

echo "  Assigner service installed (not auto-started)."

# ============================================================
# 完了
# ============================================================
echo ""
echo "=========================================="
echo " セットアップ完了!"
echo "=========================================="
echo ""
echo "モデル切替 (必要な場合):"
echo "  vi ${APP_DIR}/scripts/switch-model.sh   # VLLM_MODEL を編集"
echo "  sudo bash ${APP_DIR}/scripts/switch-model.sh"
echo ""
echo "評価実行:"
echo "  cd ${APP_DIR}"
echo "  python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log"
echo ""
echo "サービス確認:"
echo "  systemctl status agentbench-vllm"
echo "  sudo journalctl -u agentbench-vllm -f"
echo ""

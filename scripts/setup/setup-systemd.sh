#!/bin/bash
set -e

# ============================================================
# AgentBench systemd サービスのインストール・起動
#
# Usage:
#   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup/setup-systemd.sh
#
# Prerequisites:
#   - setup-vm.sh が完了済み
#
# 処理内容:
#   1. systemd サービスファイルのインストール
#   2. サービスの有効化・起動
#      vLLM → Controller (health check 待ち) → Workers
# ============================================================

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== AgentBench systemd Setup ==="
echo "APP_DIR: ${APP_DIR}"
echo ""

# ============================================================
# 1. サービスファイルのインストール
# ============================================================
echo "[1/2] Installing systemd service files..."

# /opt/agentbench プレースホルダーを実際の APP_DIR に置換してコピー
for f in "${APP_DIR}/systemd/"*.service; do
  BASENAME="$(basename "$f")"
  sed "s|/opt/agentbench|${APP_DIR}|g" "$f" > "/etc/systemd/system/${BASENAME}"
  echo "  Installed: ${BASENAME}"
done
systemctl daemon-reload

# ============================================================
# 2. サービスの有効化・起動
# ============================================================
echo "[2/2] Enabling and starting services..."

# 依存関係: vLLM → Controller (health check 待ち) → Workers
# Restart=always なので controller は vLLM 準備完了まで自動リトライする
systemctl enable --now agentbench-vllm
systemctl enable --now --no-block agentbench-controller
systemctl enable --now --no-block agentbench-worker-dbbench
systemctl enable --now --no-block agentbench-worker-alfworld

echo ""
echo "=========================================="
echo " systemd セットアップ完了!"
echo "=========================================="
echo ""
echo "vLLM のモデルロード完了後、Controller → Workers が順次起動します。"
echo ""
echo "サービス確認:"
echo "  systemctl status agentbench-vllm"
echo "  systemctl status agentbench-controller"
echo "  systemctl status agentbench-worker-dbbench"
echo "  systemctl status agentbench-worker-alfworld"
echo "  sudo journalctl -u agentbench-vllm -f"
echo ""
echo "評価実行:"
echo "  sudo systemctl start agentbench-assigner"
echo "  sudo journalctl -u agentbench-assigner -f"
echo ""
echo "モデル切替:"
echo "  vi ${APP_DIR}/scripts/eval/switch-model.sh   # VLLM_MODEL を編集"
echo "  sudo bash ${APP_DIR}/scripts/eval/switch-model.sh"
echo ""

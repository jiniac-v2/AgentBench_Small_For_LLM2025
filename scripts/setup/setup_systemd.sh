#!/bin/bash
set -e

# ============================================================
# AgentBench VM セットアップ (3/3)
#
# vLLM systemd サービスの登録・自動起動
#
# Usage:
#   sudo bash scripts/setup/setup_systemd.sh
# ============================================================

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== vLLM systemd Setup ==="
echo "APP_DIR: ${APP_DIR}"
echo ""

# サービスファイルのインストール (/opt/agentbench を実際のパスに置換)
sed "s|/opt/agentbench|${APP_DIR}|g" "${APP_DIR}/systemd/agentbench-vllm.service" \
  > /etc/systemd/system/agentbench-vllm.service
echo "Installed: agentbench-vllm.service"

systemctl daemon-reload
systemctl enable --now agentbench-vllm

echo ""
echo "=========================================="
echo " vLLM systemd セットアップ完了!"
echo "=========================================="
echo ""
echo "サービス確認:"
echo "  systemctl status agentbench-vllm"
echo "  sudo journalctl -u agentbench-vllm -f"
echo ""
echo "評価実行:"
echo "  cd ${APP_DIR}"
echo "  bash scripts/eval/run.sh"
echo ""

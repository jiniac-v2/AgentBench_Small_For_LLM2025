#!/bin/bash
set -e

# ============================================================
# vLLM systemd サービスのインストール
#
# Usage:
#   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup/setup-systemd.sh
#
# Prerequisites:
#   - setup-vm1.sh / setup-vm2.sh が完了済み
#
# 処理内容:
#   vLLM サービスを systemd に登録し、VM 起動時に自動起動するようにする。
#   Controller/Workers は run.sh で都度起動する。
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

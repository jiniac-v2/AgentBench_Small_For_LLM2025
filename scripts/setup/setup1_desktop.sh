#!/bin/bash
set -e

# ============================================================
# AgentBench ローカルセットアップ — Docker Desktop 版
#
# Docker Desktop (WSL 2 backend) を使う場合のセットアップ。
# Docker Engine / nvidia-container-toolkit のインストールは不要。
# Python 依存パッケージのみセットアップします。
#
# Usage:
#   sudo bash scripts/setup/setup1_desktop.sh
#
# 前提:
#   - Docker Desktop for Windows がインストール済み
#   - WSL integration が有効 (Settings > Resources > WSL integration)
#   - Windows 側に最新の NVIDIA ドライバがインストール済み
#
# Docker Engine 版: setup1.sh を使ってください
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ACTUAL_USER="${SUDO_USER:-$(whoami)}"

echo "=== setup1_desktop: Python dependencies (Docker Desktop) ==="
echo "APP_DIR: ${APP_DIR}"
echo "User:    ${ACTUAL_USER}"
echo ""

# ============================================================
# 1. Docker Desktop の動作確認
# ============================================================
echo "[1/3] Checking Docker Desktop..."
if ! command -v docker &> /dev/null; then
    echo "ERROR: docker コマンドが見つかりません。"
    echo "  Docker Desktop が起動しているか確認してください。"
    echo "  Settings > Resources > WSL integration で Ubuntu が有効か確認してください。"
    exit 1
fi

echo "  Docker: $(docker --version)"
echo "  Compose: $(docker compose version 2>/dev/null || echo 'not found')"

# GPU パススルーの確認
echo "  GPU check..."
if docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi > /dev/null 2>&1; then
    echo "  GPU: OK"
else
    echo "WARNING: docker --gpus all が動作しません。"
    echo "  Docker Desktop が起動しているか、NVIDIA ドライバが最新か確認してください。"
    echo "  (セットアップは続行します)"
fi

# ============================================================
# 2. Python 依存パッケージ
# ============================================================
echo "[2/3] Installing Python dependencies..."
apt-get update
apt-get install -y python3-pip cmake build-essential
if ! command -v python &> /dev/null; then
    ln -s "$(which python3)" /usr/local/bin/python
fi
pip3 install -r "${APP_DIR}/requirements.txt"

# 必須モジュールの検証
echo "  Verifying critical dependencies..."
python3 -c "import gym" || { echo "ERROR: gym not installed. Try: pip3 install gym"; exit 1; }
python3 -c "import alfworld" || { echo "ERROR: alfworld not installed. Try: pip3 install alfworld"; exit 1; }
python3 -c "import docker" || { echo "ERROR: docker (python) not installed."; exit 1; }
python3 -c "import torch" || { echo "ERROR: torch not installed. Required by alfworld."; exit 1; }
echo "  All dependencies verified."

# ============================================================
# 3. root で作られたファイルの所有権を戻す
# ============================================================
echo "[3/3] Fixing file ownership for ${ACTUAL_USER}..."
chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${APP_DIR}"
[ -d /tmp/alfworld ] && rm -rf /tmp/alfworld

# ============================================================
# 完了
# ============================================================
echo ""
echo "=========================================="
echo " setup1_desktop 完了!"
echo "=========================================="
echo ""
echo "次: bash ${APP_DIR}/scripts/setup/setup2.sh"
echo ""

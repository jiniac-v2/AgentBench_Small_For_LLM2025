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
#   bash infra/wsl/setup1_desktop.sh
#
# 前提:
#   - Docker Desktop for Windows がインストール済み
#   - WSL integration が有効 (Settings > Resources > WSL integration)
#   - Windows 側に最新の NVIDIA ドライバがインストール済み
#
# Docker Engine 版: setup1.sh を使ってください
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== setup1_desktop: Python dependencies (Docker Desktop) ==="
echo "APP_DIR: ${APP_DIR}"
echo "User:    $(whoami)"
echo ""

# ============================================================
# 1. Docker Desktop の動作確認
# ============================================================
echo "[1/2] Checking Docker Desktop..."
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
# 2. Python 3.11 + 仮想環境 + 依存パッケージ
#    alfworld/spacy/thinc が Python 3.12 非対応のため 3.11 を使用
# ============================================================
echo "[2/2] Installing Python 3.11 and dependencies..."
sudo apt-get update
if ! command -v python3.11 &> /dev/null; then
    echo "  Installing Python 3.11 from deadsnakes PPA..."
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
fi
sudo apt-get install -y python3.11 python3.11-venv python3.11-dev cmake build-essential

# venv の作成 (Python 3.11)
VENV_DIR="${APP_DIR}/.venv"
if [ ! -d "${VENV_DIR}" ]; then
    echo "  Creating virtual environment (Python 3.11): ${VENV_DIR}"
    python3.11 -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip setuptools wheel
pip install -r "${APP_DIR}/requirements.txt"

# 必須モジュールの検証
echo "  Verifying critical dependencies..."
python3 -c "import gym" || { echo "ERROR: gym not installed."; exit 1; }
python3 -c "import alfworld" || { echo "ERROR: alfworld not installed."; exit 1; }
python3 -c "import docker" || { echo "ERROR: docker (python) not installed."; exit 1; }
python3 -c "import torch" || { echo "ERROR: torch not installed. Required by alfworld."; exit 1; }
echo "  All dependencies verified."

# ============================================================
# 完了
# ============================================================
echo ""
echo "=========================================="
echo " setup1_desktop 完了!"
echo "=========================================="
echo ""
echo "次: bash ${APP_DIR}/infra/wsl/setup2.sh"
echo ""

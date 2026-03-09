#!/bin/bash
set -e

# ============================================================
# AgentBench セットアップ (1/2) — Docker Engine 版
#
# Docker Engine, NVIDIA Container Toolkit, Python 依存パッケージ
#
# Usage:
#   bash infra/gcp/setup1.sh          # GCP
#   bash infra/wsl/setup1.sh          # WSL (symlink)
#
# Docker Desktop を使う場合: infra/wsl/setup1_desktop.sh を使ってください
# ============================================================

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== setup1: Docker / NVIDIA / Python ==="
echo "APP_DIR: ${APP_DIR}"
echo "User:    $(whoami)"
echo ""

# ============================================================
# 1. Docker Engine
# ============================================================
echo "[1/4] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  echo "  Docker installed."
else
  echo "  Docker already installed: $(docker --version)"
fi

# ============================================================
# 2. NVIDIA Container Toolkit
# ============================================================
echo "[2/4] Installing NVIDIA Container Toolkit..."
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  echo "  NVIDIA Container Toolkit installed."
else
  echo "  NVIDIA Container Toolkit already installed."
fi

# ============================================================
# 3. ユーザーを docker グループに追加
# ============================================================
echo "[3/4] Configuring docker group..."
if ! groups "$(whoami)" | grep -q docker; then
  sudo usermod -aG docker "$(whoami)"
  echo "  Added $(whoami) to docker group."
else
  echo "  $(whoami) is already in docker group."
fi

# ============================================================
# 4. Python 仮想環境 + 依存パッケージ
# ============================================================
echo "[4/4] Installing Python dependencies..."
sudo apt-get install -y python3-pip python3-venv cmake build-essential

# venv の作成
VENV_DIR="${APP_DIR}/.venv"
if [ ! -d "${VENV_DIR}" ]; then
  echo "  Creating virtual environment: ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

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
echo " setup1 完了!"
echo "=========================================="
echo ""
echo "docker グループ反映のため再ログインしてください。"
echo "  newgrp docker  または  exit → 再接続"
echo ""
echo "次: bash ${APP_DIR}/infra/gcp/setup2.sh"
echo ""

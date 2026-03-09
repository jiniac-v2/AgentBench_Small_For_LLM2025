#!/bin/bash
set -e

# ============================================================
# AgentBench VM セットアップ (1/3) — Docker Engine 版
#
# Docker Engine, NVIDIA Container Toolkit, Python 依存パッケージ
#
# Usage:
#   sudo bash scripts/setup/setup1.sh
#
# Docker Desktop を使う場合: setup1_desktop.sh を使ってください
# ============================================================

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# Detect the user who invoked sudo (or current user)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"

echo "=== setup1: Docker / NVIDIA / Python ==="
echo "APP_DIR: ${APP_DIR}"
echo "User:    ${ACTUAL_USER}"
echo ""

# ============================================================
# 1. Docker Engine
# ============================================================
echo "[1/4] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
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
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  echo "  NVIDIA Container Toolkit installed."
else
  echo "  NVIDIA Container Toolkit already installed."
fi

# ============================================================
# 3. ユーザーを docker グループに追加
# ============================================================
echo "[3/4] Configuring docker group..."
if ! groups "$ACTUAL_USER" | grep -q docker; then
  usermod -aG docker "$ACTUAL_USER"
  echo "  Added ${ACTUAL_USER} to docker group."
else
  echo "  ${ACTUAL_USER} is already in docker group."
fi

# ============================================================
# 4. Python 依存パッケージ
# ============================================================
echo "[4/4] Installing Python dependencies..."
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
# 5. root で作られたファイルの所有権を戻す
# ============================================================
echo "Fixing file ownership for ${ACTUAL_USER}..."
chown -R "${ACTUAL_USER}:${ACTUAL_USER}" "${APP_DIR}"
# alfworld-download が root で /tmp/alfworld に書くことがある
[ -d /tmp/alfworld ] && rm -rf /tmp/alfworld

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
echo "次: bash ${APP_DIR}/scripts/setup/setup2.sh"
echo ""

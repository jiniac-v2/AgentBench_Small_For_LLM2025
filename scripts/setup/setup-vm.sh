#!/bin/bash
set -e

# ============================================================
# AgentBench VM 環境構築スクリプト
#
# Usage:
#   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup/setup-vm.sh
#
# Prerequisites:
#   - VM が起動済み (terraform apply 完了)
#   - SSH 接続済み
#
# 処理内容:
#   1. Docker Engine のインストール
#   2. NVIDIA Container Toolkit のインストール
#   3. ユーザーを docker グループに追加
#   4. Python 依存パッケージのインストール
#      + ALFWorld ランタイムデータのリンク (logic/, json_2.1.1/, detectors/)
#   5. .env / agent config の生成
#   6. Docker イメージの pull
#
# systemd サービスの設定は別途:
#   sudo bash scripts/setup/setup-systemd.sh
# ============================================================

# ---- 設定 ----
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
HF_TOKEN="${HF_TOKEN:-}"
# ---------------

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# Detect the user who invoked sudo (or current user)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"

echo "=== AgentBench VM Setup ==="
echo "APP_DIR:    ${APP_DIR}"
echo "User:       ${ACTUAL_USER}"
echo "VLLM_MODEL: ${VLLM_MODEL}"
echo ""

# ============================================================
# 1. Docker Engine
# ============================================================
echo "[1/6] Installing Docker Engine..."
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
echo "[2/6] Installing NVIDIA Container Toolkit..."
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
echo "[3/6] Configuring docker group..."
if ! groups "$ACTUAL_USER" | grep -q docker; then
  usermod -aG docker "$ACTUAL_USER"
  echo "  Added ${ACTUAL_USER} to docker group."
  echo "  (次回ログイン時から sudo なしで docker が使えます)"
else
  echo "  ${ACTUAL_USER} is already in docker group."
fi

# ============================================================
# 4. Python 依存パッケージ
# ============================================================
echo "[4/6] Installing Python dependencies..."
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

# alfworld ランタイムデータのダウンロード + リンク
ALFWORLD_PKG_DATA=$(python3 -c "import os, alfworld; print(os.path.join(os.path.dirname(alfworld.__file__), 'data'))")
ACTUAL_USER_HOME=$(eval echo "~${ACTUAL_USER}")
ALFWORLD_CACHE_DATA="${ACTUAL_USER_HOME}/.cache/alfworld"
if [ ! -d "${ALFWORLD_PKG_DATA}/logic" ] && [ ! -d "${ALFWORLD_CACHE_DATA}/logic" ]; then
  echo "  Downloading alfworld runtime data (as ${ACTUAL_USER})..."
  su - "${ACTUAL_USER}" -c "alfworld-download" 2>&1 || {
    echo "  WARNING: alfworld-download failed. You may need to run it manually."
  }
fi
# データソースを判定 (パッケージ内 or ~/.cache/alfworld)
if [ -d "${ALFWORLD_PKG_DATA}/logic" ]; then
  ALFWORLD_DATA_SRC="$ALFWORLD_PKG_DATA"
elif [ -d "${ALFWORLD_CACHE_DATA}/logic" ]; then
  ALFWORLD_DATA_SRC="$ALFWORLD_CACHE_DATA"
else
  echo "  WARNING: alfworld data not found in package or cache."
  ALFWORLD_DATA_SRC=""
fi
if [ -n "$ALFWORLD_DATA_SRC" ]; then
  echo "  Linking alfworld runtime data from ${ALFWORLD_DATA_SRC}..."
  for subdir in logic json_2.1.1 detectors; do
    if [ -d "${ALFWORLD_DATA_SRC}/${subdir}" ]; then
      if [ -L "${APP_DIR}/data/alfworld/${subdir}" ] || [ ! -e "${APP_DIR}/data/alfworld/${subdir}" ]; then
        ln -sfn "${ALFWORLD_DATA_SRC}/${subdir}" "${APP_DIR}/data/alfworld/${subdir}"
        echo "    Linked: ${subdir}"
      fi
    fi
  done
fi

# ============================================================
# 5. .env / agent config の生成
# ============================================================
echo "[5/6] Generating configuration..."

cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# agent config のモデル名を置換 (インデントされた model: 行のみ)
sed -i "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" "${APP_DIR}/configs/agents/api_agents.yaml"
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" "${APP_DIR}/configs/agents/api_agents.yaml"

echo "  .env:"
cat "${APP_DIR}/.env"
echo "  Agent config:"
cat "${APP_DIR}/configs/agents/api_agents.yaml"

# ============================================================
# 6. Docker イメージの pull
# ============================================================
echo "[6/6] Pulling Docker images..."
docker pull mysql:9.5.0 &
docker pull vllm/vllm-openai:v0.13.0 &
wait
echo "  Docker images pulled."

# ============================================================
# 完了
# ============================================================
echo ""
echo "=========================================="
echo " VM セットアップ完了!"
echo "=========================================="
echo ""
echo "重要: docker グループの反映には再ログインが必要です。"
echo "  exit して SSH で再接続するか、以下を実行:"
echo "  newgrp docker"
echo ""
echo "次のステップ: systemd サービスのインストール"
echo "  sudo bash ${APP_DIR}/scripts/setup/setup-systemd.sh"
echo ""

#!/bin/bash
set -e

# ============================================================
# AgentBench VM セットアップ (2/3)
#
# ALFWorld データ, .env / agent config, Docker イメージ pull
#
# Usage:
#   bash infra/gcp/setup2.sh
# ============================================================

# ---- 設定 ----
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-7B-Instruct}"
HF_TOKEN="${HF_TOKEN:-}"
# ---------------

# Auto-detect APP_DIR from script location
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# sudo 経由で実行された場合でも実ユーザーのホームを使う
if [ -n "${SUDO_USER:-}" ]; then
  ACTUAL_USER="${SUDO_USER}"
else
  ACTUAL_USER="$(whoami)"
fi
ACTUAL_USER_HOME=$(eval echo "~${ACTUAL_USER}")

# Activate venv
# shellcheck disable=SC1091
if [ -f "${APP_DIR}/.venv/bin/activate" ]; then
  source "${APP_DIR}/.venv/bin/activate"
fi

echo "=== setup2: ALFWorld / config / Docker images ==="
echo "APP_DIR:    ${APP_DIR}"
echo "User:       $(whoami) (actual: ${ACTUAL_USER})"
echo "VLLM_MODEL: ${VLLM_MODEL}"
echo ""

# ============================================================
# 1. ALFWorld ランタイムデータ
# ============================================================
echo "[1/3] Setting up ALFWorld runtime data..."

ALFWORLD_PKG_DATA=$(python3 -c "import os, alfworld; print(os.path.join(os.path.dirname(alfworld.__file__), 'data'))")
ALFWORLD_CACHE_DATA="${ACTUAL_USER_HOME}/.cache/alfworld"

if [ ! -d "${ALFWORLD_PKG_DATA}/logic" ] && [ ! -d "${ALFWORLD_CACHE_DATA}/logic" ]; then
  echo "  Downloading alfworld runtime data..."
  if [ "${ACTUAL_USER}" != "$(whoami)" ]; then
    su - "${ACTUAL_USER}" -c "source ${APP_DIR}/.venv/bin/activate && alfworld-download" 2>&1 || {
      echo "  WARNING: alfworld-download failed. You may need to run it manually."
    }
  else
    alfworld-download 2>&1 || {
      echo "  WARNING: alfworld-download failed. You may need to run it manually."
    }
  fi
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
# 2. .env / agent config の生成
# ============================================================
echo "[2/3] Generating configuration..."

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
# 3. Docker イメージの pull
# ============================================================
echo "[3/3] Pulling Docker images..."
docker pull mysql:9.5.0 &
docker pull vllm/vllm-openai:v0.13.0 &
wait
echo "  Docker images pulled."

# ============================================================
# 完了
# ============================================================
echo ""
echo "=========================================="
echo " setup2 完了!"
echo "=========================================="
echo ""
echo "次: cd ${APP_DIR} && docker compose up -d"
echo ""

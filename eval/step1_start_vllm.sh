#!/bin/bash
set -e

# ============================================================
# Step 1: vLLM 立ち上げ (docker compose)
#
# Usage:
#   bash eval/step1_start_vllm.sh <model_path> <hf_token> [max_wait_sec]
#
# 処理:
#   1. .env / api_agents.yaml を更新
#   2. docker compose up -d で vLLM を起動し、起動完了を待機
#
# 事前に step0_cleanup.sh でコンテナ停止・キャッシュ削除を行うこと。
#
# Exit code:
#   0 = 起動成功, 1 = 起動失敗
# ============================================================

VLLM_MODEL="$1"
HF_TOKEN="$2"
MAX_WAIT="${3:-3600}"  # デフォルト1時間

if [ -z "$VLLM_MODEL" ]; then
    echo "ERROR: Usage: $0 <model_path> <hf_token> [max_wait_sec]"
    exit 1
fi

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Activate venv
# shellcheck disable=SC1091
[ -f "${APP_DIR}/.venv/bin/activate" ] && source "${APP_DIR}/.venv/bin/activate"

echo "============================================"
echo " [Step1] vLLM 立ち上げ (docker compose)"
echo " Model: ${VLLM_MODEL}"
echo "============================================"

# ── 1. .env / agent config 更新 ──

echo "[Step1] .env を更新..."
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-8192}
VLLM_GPU_MEMORY_UTILIZATION=${VLLM_GPU_MEMORY_UTILIZATION:-0.90}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

echo "[Step1] api_agents.yaml を更新..."
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" \
    "${APP_DIR}/configs/agents/api_agents.yaml"

# ── ログからエラー原因を診断して終了 ──

diagnose_and_exit() {
    local trigger="$1"  # "crashed" or "timeout"
    local logs
    logs=$(docker compose logs --tail=100 vllm 2>/dev/null || echo "")

    echo "[Step1] 直近のログ:"
    docker compose logs --tail=30 vllm 2>/dev/null || true

    local diagnosis="UNKNOWN"
    if echo "$logs" | grep -qiE "repository not found|model .* does not exist|404.*not found|does not appear to have.*config"; then
        diagnosis="MODEL_NOT_FOUND"
    elif echo "$logs" | grep -qiE "401|403|unauthorized|access denied|gated repo|token.*invalid|Invalid username or password"; then
        diagnosis="AUTH_ERROR"
    elif echo "$logs" | grep -qiE "CUDA out of memory|torch.cuda.OutOfMemoryError|OOM|Cannot allocate memory|not enough memory"; then
        diagnosis="OOM"
    elif echo "$logs" | grep -qiE "max_model_len.*is too high|model.*max.*is larger|exceeds.*max_position_embeddings|context length"; then
        diagnosis="CONTEXT_TOO_LONG"
    elif echo "$logs" | grep -qiE "CUDA error|NCCL error|cuda.*not available|no CUDA GPUs|nvidia.*error|GPU.*not found"; then
        diagnosis="CUDA_ERROR"
    elif echo "$logs" | grep -qiE "ConnectionError|ConnectionResetError|DownloadError|Name or service not known|Temporary failure in name resolution|Could not resolve host"; then
        diagnosis="DOWNLOAD_ERROR"
    elif [ "$trigger" = "timeout" ]; then
        diagnosis="TIMEOUT"
    else
        diagnosis="CONTAINER_CRASH"
    fi

    echo ""
    echo "[Step1] ===== 診断結果: ${diagnosis} ====="
    echo "[Step1] DIAGNOSIS=${diagnosis}"
    exit 1
}

# ── 2. vLLM 起動 + 起動待ち ──

echo "[Step1] vLLM を起動 (docker compose up -d)..."
cd "${APP_DIR}"
docker compose up -d

echo "[Step1] vLLM の起動を待機中 (最大 ${MAX_WAIT}s)..."
elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    # /v1/models が応答すれば起動完了
    if curl -s --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
        echo "[Step1] vLLM 起動完了 (${elapsed}s)"
        loaded_model=$(curl -s http://localhost:8000/v1/models 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || true)
        echo "[Step1] ロード済みモデル: ${loaded_model}"
        exit 0
    fi

    # コンテナが異常終了していないかチェック
    container_status=$(docker compose ps --format json 2>/dev/null \
        | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    if 'vllm' in d.get('Service',''):
        print(d.get('State','unknown'))
        sys.exit(0)
print('not found')
" 2>/dev/null || echo "unknown")

    if [ "$container_status" = "exited" ] || [ "$container_status" = "dead" ]; then
        echo "[Step1] ERROR: vLLM コンテナが異常終了しました。"
        diagnose_and_exit "crashed"
    fi

    sleep 10
    elapsed=$((elapsed + 10))
    echo "[Step1] ... ${elapsed}s 経過"
done

echo "[Step1] ERROR: vLLM が ${MAX_WAIT}s 以内に起動しませんでした"
diagnose_and_exit "timeout"

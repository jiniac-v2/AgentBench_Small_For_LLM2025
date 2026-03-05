#!/bin/bash
set -e

# ============================================================
# Step 1: vLLM 立ち上げ
#
# Usage:
#   sudo bash scripts/massive_eval/step1_start_vllm.sh <model_path> <hf_token>
#
# 処理:
#   1. 既存 vLLM コンテナを確実に停止・削除
#   2. GPU メモリを解放
#   3. 前モデルの推論キャッシュをクリア (HFモデルキャッシュは保持)
#   4. .env / api_agents.yaml を更新
#   5. vLLM を再起動し、起動完了を待機
#
# Exit code:
#   0 = 起動成功, 1 = 起動失敗
# ============================================================

VLLM_MODEL="$1"
HF_TOKEN="$2"
MAX_WAIT="${3:-600}"  # デフォルト10分 (大きいモデルのダウンロード考慮)

if [ -z "$VLLM_MODEL" ]; then
    echo "ERROR: Usage: $0 <model_path> <hf_token> [max_wait_sec]"
    exit 1
fi

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "============================================"
echo " [Step1] vLLM 立ち上げ"
echo " Model: ${VLLM_MODEL}"
echo "============================================"

# ── 1. 既存 vLLM コンテナを確実に停止 ──

echo "[Step1] 既存 vLLM コンテナを停止..."
systemctl stop agentbench-vllm 2>/dev/null || true
# systemd の stop が効かない場合も docker で直接停止
docker stop vllm-server 2>/dev/null || true
docker rm -f vllm-server 2>/dev/null || true
sleep 2

# ── 2. GPU メモリ解放 ──

echo "[Step1] GPU メモリを解放..."
# vLLM 以外に GPU を掴んでいるプロセスがあれば警告
if command -v nvidia-smi &>/dev/null; then
    gpu_procs=$(nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>/dev/null || true)
    if [ -n "$gpu_procs" ]; then
        echo "[Step1] WARNING: GPU を使用中のプロセスがあります:"
        echo "$gpu_procs"
    else
        echo "[Step1] GPU メモリ: クリア"
    fi
fi

# ── 3. 推論キャッシュのクリア (HFモデルウェイトは保持) ──

echo "[Step1] 推論キャッシュをクリア..."
# vLLM が /root/.cache 配下に作る一時ファイルを掃除 (モデルウェイト以外)
rm -rf /tmp/vllm_cache 2>/dev/null || true
rm -rf /tmp/ray 2>/dev/null || true
# Python の __pycache__ は触らない、HF の models キャッシュも保持

# ── 4. .env / agent config 更新 ──

echo "[Step1] .env を更新..."
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

echo "[Step1] api_agents.yaml を更新..."
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${VLLM_MODEL}\"|" \
    "${APP_DIR}/configs/agents/api_agents.yaml"

# ── 5. vLLM 起動 + 起動待ち ──

echo "[Step1] vLLM を起動..."
systemctl daemon-reload
systemctl restart agentbench-vllm

echo "[Step1] vLLM の起動を待機中 (最大 ${MAX_WAIT}s)..."
elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    # /v1/models が応答すれば起動完了
    if curl -s --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
        echo "[Step1] vLLM 起動完了 (${elapsed}s)"
        # モデル名が正しくロードされているか確認
        loaded_model=$(curl -s http://localhost:8000/v1/models 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || true)
        echo "[Step1] ロード済みモデル: ${loaded_model}"
        exit 0
    fi

    # コンテナが異常終了していないかチェック
    if ! docker ps --format '{{.Names}}' | grep -q vllm-server; then
        # systemd が Restart=always なので少し待つ
        container_status=$(docker inspect -f '{{.State.Status}}' vllm-server 2>/dev/null || echo "not found")
        if [ "$container_status" = "not found" ] && [ $elapsed -gt 30 ]; then
            echo "[Step1] ERROR: vLLM コンテナが存在しません。ログを確認:"
            journalctl -u agentbench-vllm --no-pager -n 20
            exit 1
        fi
    fi

    sleep 10
    elapsed=$((elapsed + 10))
    echo "[Step1] ... ${elapsed}s 経過"
done

echo "[Step1] ERROR: vLLM が ${MAX_WAIT}s 以内に起動しませんでした"
echo "[Step1] 直近のログ:"
journalctl -u agentbench-vllm --no-pager -n 30
exit 1

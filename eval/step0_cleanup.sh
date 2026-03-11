#!/bin/bash
set -e

# ============================================================
# Step 0: 事前クリーンアップ (タイムアウト対象外)
#
# Usage:
#   bash eval/step0_cleanup.sh
#
# 処理:
#   1. 既存 vLLM コンテナを停止・削除
#   2. Docker 不要リソースを削除
#   3. GPU メモリを解放
#   4. 推論キャッシュ + HF モデルキャッシュを削除
#
# Exit code:
#   0 = 正常完了 (常に成功)
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================"
echo " [Step0] 事前クリーンアップ"
echo "============================================"

# ── 1. 既存 vLLM コンテナを停止 ──

echo "[Step0] 既存 vLLM コンテナを停止..."
cd "${APP_DIR}"
docker compose down 2>/dev/null || true

# ── 2. Docker 不要リソース削除 ──

echo "[Step0] Docker 不要リソースを削除..."
docker system prune -f 2>/dev/null || true
sleep 2

# ── 3. GPU メモリ解放 ──

echo "[Step0] GPU メモリを解放..."
if command -v nvidia-smi &>/dev/null; then
    gpu_procs=$(nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>/dev/null || true)
    if [ -n "$gpu_procs" ]; then
        echo "[Step0] WARNING: GPU を使用中のプロセスがあります:"
        echo "$gpu_procs"
    else
        echo "[Step0] GPU メモリ: クリア"
    fi
fi

# ── 4. キャッシュクリア (推論キャッシュ + HF モデルキャッシュ) ──

echo "[Step0] 推論キャッシュをクリア..."
rm -rf /tmp/vllm_cache 2>/dev/null || true
rm -rf /tmp/ray 2>/dev/null || true

# HF モデルキャッシュを削除してディスク枯渇を防止
# Note: vLLM コンテナが root でキャッシュを書くため sudo が必要な場合がある
HF_CACHE="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
if [ -d "${HF_CACHE}/hub" ]; then
    cache_size=$(du -sh "${HF_CACHE}/hub" 2>/dev/null | cut -f1)
    echo "[Step0] HF モデルキャッシュを削除 (${cache_size})..."
    if rm -rf "${HF_CACHE}/hub" 2>/dev/null; then
        echo "[Step0] HF モデルキャッシュ削除完了"
    else
        echo "[Step0] 権限不足のため sudo で削除..."
        sudo rm -rf "${HF_CACHE}/hub"
        echo "[Step0] HF モデルキャッシュ削除完了 (sudo)"
    fi
fi

echo "[Step0] クリーンアップ完了"
exit 0

#!/bin/bash
# ============================================================
# vLLM エラー診断スクリプト
#
# CSV から vLLM-Error のモデルを抽出し、各モデルを docker compose で
# 起動して失敗ログからエラー原因を分類する。
#
# Usage:
#   bash eval/diagnose_vllm.sh [models.csv] [max_wait_sec]
#
# 出力:
#   - 標準出力にサマリーテーブル
#   - eval/vllm_diagnosis.csv に結果を保存
#
# エラー分類:
#   MODEL_NOT_FOUND  - モデルが HuggingFace に存在しない / アクセス不可
#   AUTH_ERROR       - HuggingFace トークンが無効 / gated model のアクセス権なし
#   OOM              - GPU メモリ不足 (CUDA OOM)
#   CONTEXT_TOO_LONG - max-model-len がモデルの上限を超えている
#   CUDA_ERROR       - CUDA/GPU ドライバ関連のエラー
#   DOWNLOAD_ERROR   - ネットワーク/ダウンロード関連のエラー
#   TIMEOUT          - 制限時間内に起動しなかった (原因不明)
#   CONTAINER_CRASH  - コンテナが異常終了 (原因特定不可)
#   UNKNOWN          - 上記に該当しない
# ============================================================

set -euo pipefail

CSV_PATH="${1:-eval/models.csv}"
MAX_WAIT="${2:-300}"  # 診断用は短めのデフォルト 5分

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIAG_CSV="${APP_DIR}/eval/vllm_diagnosis.csv"

if [ ! -f "$CSV_PATH" ]; then
    echo "ERROR: CSV not found: $CSV_PATH"
    exit 1
fi

# ── ログからエラー原因を判定する関数 ──

diagnose_logs() {
    local logs="$1"
    local container_state="$2"

    # 優先度順にマッチング
    if echo "$logs" | grep -qiE "repository not found|model .* does not exist|404.*not found|does not appear to have.*config"; then
        echo "MODEL_NOT_FOUND"
    elif echo "$logs" | grep -qiE "401|403|unauthorized|access denied|gated repo|token.*invalid|authentication"; then
        echo "AUTH_ERROR"
    elif echo "$logs" | grep -qiE "CUDA out of memory|torch.cuda.OutOfMemoryError|OOM|Cannot allocate memory|not enough memory"; then
        echo "OOM"
    elif echo "$logs" | grep -qiE "max_model_len.*is too high|model's max.*is larger|exceeds.*max_position_embeddings|context length"; then
        echo "CONTEXT_TOO_LONG"
    elif echo "$logs" | grep -qiE "CUDA error|NCCL error|cuda.*not available|no CUDA GPUs|nvidia.*error|GPU.*not found"; then
        echo "CUDA_ERROR"
    elif echo "$logs" | grep -qiE "ConnectionError|ConnectionResetError|OSError.*Errno|DownloadError|HTTPError|Name or service not known|Temporary failure in name resolution|Could not resolve host"; then
        echo "DOWNLOAD_ERROR"
    elif [ "$container_state" = "exited" ] || [ "$container_state" = "dead" ]; then
        echo "CONTAINER_CRASH"
    elif [ "$container_state" = "timeout" ]; then
        echo "TIMEOUT"
    else
        echo "UNKNOWN"
    fi
}

# ── vLLM-Error のモデルを CSV から抽出 ──

echo "========================================"
echo " vLLM エラー診断"
echo " CSV: $CSV_PATH"
echo " 待機上限: ${MAX_WAIT}s/モデル"
echo "========================================"
echo ""

# ヘッダーから列インデックスを取得
header=$(head -1 "$CSV_PATH")
IFS=',' read -ra cols <<< "$header"

col_idx() {
    local name="$1"
    for i in "${!cols[@]}"; do
        if [ "${cols[$i]}" = "$name" ]; then
            echo "$i"
            return
        fi
    done
    echo "-1"
}

IDX_MODEL=$(col_idx "model_path")
IDX_TOKEN=$(col_idx "hf_token")
IDX_STATUS=$(col_idx "Valid_Status")
IDX_OMNI_ID=$(col_idx "OmniID")
IDX_OMNI_ACCOUNT=$(col_idx "OmniAccount")

if [ "$IDX_MODEL" = "-1" ] || [ "$IDX_STATUS" = "-1" ]; then
    echo "ERROR: CSV に model_path / Valid_Status 列が見つかりません"
    exit 1
fi

# 診断 CSV ヘッダー
echo "OmniID,OmniAccount,model_path,diagnosis,detail" > "$DIAG_CSV"

# vLLM-Error の行を集める
error_models=()
while IFS=',' read -ra fields; do
    status="${fields[$IDX_STATUS]:-}"
    if [ "$status" = "vLLM-Error" ]; then
        model="${fields[$IDX_MODEL]:-}"
        token="${fields[$IDX_TOKEN]:-}"
        omni_id="${fields[$IDX_OMNI_ID]:-}"
        omni_account="${fields[$IDX_OMNI_ACCOUNT]:-}"
        error_models+=("${omni_id}|${omni_account}|${model}|${token}")
    fi
done < <(tail -n +2 "$CSV_PATH")

if [ ${#error_models[@]} -eq 0 ]; then
    echo "vLLM-Error のモデルはありません。"
    exit 0
fi

echo "対象: ${#error_models[@]} モデル"
echo ""

# ── 各モデルを診断 ──

count=0
for entry in "${error_models[@]}"; do
    IFS='|' read -r omni_id omni_account model token <<< "$entry"
    count=$((count + 1))

    echo "----------------------------------------"
    echo "[$count/${#error_models[@]}] $model"
    echo "----------------------------------------"

    # .env を更新
    cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${model}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-8192}
VLLM_GPU_MEMORY_UTILIZATION=${VLLM_GPU_MEMORY_UTILIZATION:-0.90}
HUGGING_FACE_HUB_TOKEN=${token}
EOF

    # 既存コンテナ停止
    cd "${APP_DIR}"
    docker compose down --timeout 10 2>/dev/null || true

    # 起動
    docker compose up -d 2>/dev/null

    # 起動待ち
    elapsed=0
    container_state="running"
    while [ $elapsed -lt "$MAX_WAIT" ]; do
        if curl -s --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
            container_state="ok"
            break
        fi

        # コンテナ状態チェック
        state=$(docker compose ps --format json 2>/dev/null \
            | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    if 'vllm' in d.get('Service',''):
        print(d.get('State','unknown'))
        sys.exit(0)
print('not found')
" 2>/dev/null || echo "unknown")

        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            container_state="$state"
            break
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [ "$container_state" = "running" ] && [ $elapsed -ge "$MAX_WAIT" ]; then
        container_state="timeout"
    fi

    # ログ取得
    logs=$(docker compose logs --tail=100 vllm 2>/dev/null || echo "")

    # 診断
    if [ "$container_state" = "ok" ]; then
        diagnosis="OK"
        detail="起動成功 (${elapsed}s)"
        echo "  => OK (起動成功 ${elapsed}s)"
    else
        diagnosis=$(diagnose_logs "$logs" "$container_state")

        # 詳細メッセージ抽出 (エラー行の最初の1行)
        detail=$(echo "$logs" | grep -iE "error|exception|failed|denied|unauthorized|OOM|not found|cannot" | tail -1 | sed 's/,/ /g' | cut -c1-200)
        if [ -z "$detail" ]; then
            detail="container_state=${container_state}"
        fi

        echo "  => $diagnosis: $detail"
    fi

    # CSV に追記
    echo "${omni_id},${omni_account},${model},${diagnosis},\"${detail}\"" >> "$DIAG_CSV"

    # 停止
    docker compose down --timeout 10 2>/dev/null || true
done

echo ""
echo "========================================"
echo " 診断完了"
echo " 結果: $DIAG_CSV"
echo "========================================"
echo ""

# サマリー表示
echo "--- サマリー ---"
echo ""
tail -n +2 "$DIAG_CSV" | cut -d',' -f4 | sort | uniq -c | sort -rn | while read -r cnt diag; do
    printf "  %-20s %d\n" "$diag" "$cnt"
done
echo ""
echo "--- 詳細 ---"
echo ""
column -t -s',' "$DIAG_CSV" 2>/dev/null || cat "$DIAG_CSV"

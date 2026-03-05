#!/bin/bash
set -e

# ============================================================
# Step 4: 評価コンテンツの整理
#
# Usage:
#   bash scripts/massive_eval/step4_organize.sh <omni_account> <output_dir> [results_base]
#
# 処理:
#   1. outputs ディレクトリ (analysis 結果含む) を
#      {results_base}/{omni_account}/ にコピー
#
# Exit code:
#   0 = 整理成功, 1 = 失敗
# ============================================================

OMNI_ACCOUNT="$1"
OUTPUT_DIR="$2"
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_BASE="${3:-${APP_DIR}/massive_eval_results}"

if [ -z "$OMNI_ACCOUNT" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: Usage: $0 <omni_account> <output_dir> [results_base]"
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: output_dir が存在しません: ${OUTPUT_DIR}"
    exit 1
fi

DEST="${RESULTS_BASE}/${OMNI_ACCOUNT}"

echo "============================================"
echo " [Step4] 評価コンテンツの整理"
echo " From: ${OUTPUT_DIR}"
echo " To:   ${DEST}"
echo "============================================"

mkdir -p "$RESULTS_BASE"

# 既存があれば削除して上書き
if [ -d "$DEST" ]; then
    echo "[Step4] 既存ディレクトリを削除: ${DEST}"
    rm -rf "$DEST"
fi

cp -r "$OUTPUT_DIR" "$DEST"

echo "[Step4] 保存完了: ${DEST}"
ls -la "$DEST"
exit 0

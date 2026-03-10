#!/bin/bash
set -e

# ============================================================
# Step 4: 評価コンテンツの整理
#
# Usage:
#   bash eval/step4_organize.sh <prefix> <output_dir>
#
# 処理:
#   outputs/{TIMESTAMP}/ ディレクトリ名に {prefix} を付与する
#   例: outputs/2025-03-10-12-34-56/
#     → outputs/{OmniID}_{OmniAccount}_2025-03-10-12-34-56/
#
# Exit code:
#   0 = 整理成功, 1 = 失敗
# ============================================================

PREFIX="$1"
OUTPUT_DIR="$2"

if [ -z "$PREFIX" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: Usage: $0 <prefix> <output_dir>"
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: output_dir が存在しません: ${OUTPUT_DIR}"
    exit 1
fi

# ディレクトリ名にプレフィックスを付与してリネーム
PARENT_DIR="$(dirname "$OUTPUT_DIR")"
BASE_NAME="$(basename "$OUTPUT_DIR")"
DEST="${PARENT_DIR}/${PREFIX}${BASE_NAME}"

echo "============================================"
echo " [Step4] 評価コンテンツの整理"
echo " From: ${OUTPUT_DIR}"
echo " To:   ${DEST}"
echo "============================================"

# 既にプレフィックス付きなら何もしない
if [ "$OUTPUT_DIR" = "$DEST" ]; then
    echo "[Step4] 既にプレフィックス付きです。スキップ。"
    exit 0
fi

# 既存があれば削除して上書き
if [ -d "$DEST" ]; then
    echo "[Step4] 既存ディレクトリを削除: ${DEST}"
    rm -rf "$DEST"
fi

mv "$OUTPUT_DIR" "$DEST"

echo "[Step4] リネーム完了: ${DEST}"
ls -la "$DEST"
exit 0

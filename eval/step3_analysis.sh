#!/bin/bash
set -e

# ============================================================
# Step 3: analysis.py 実行
#
# Usage:
#   bash eval/step3_analysis.sh <output_dir>
#
# 処理:
#   1. 指定された output ディレクトリに対して analysis.py を実行
#   2. 結果は <output_dir>/analysis/ に保存される
#
# Exit code:
#   0 = 分析成功, 1 = 分析失敗
# ============================================================

OUTPUT_DIR="$1"

if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: Usage: $0 <output_dir>"
    echo "  output_dir が存在しません: ${OUTPUT_DIR}"
    exit 1
fi

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Activate venv
# shellcheck disable=SC1091
[ -f "${APP_DIR}/.venv/bin/activate" ] && source "${APP_DIR}/.venv/bin/activate"

ANALYSIS_SAVE="${OUTPUT_DIR}/analysis"

echo "============================================"
echo " [Step3] analysis.py 実行"
echo " Output: ${OUTPUT_DIR}"
echo " Save:   ${ANALYSIS_SAVE}"
echo "============================================"

cd "${APP_DIR}"
python3 -m src.analysis \
    -c configs/assignments/definition.yaml \
    -o "$OUTPUT_DIR" \
    -s "$ANALYSIS_SAVE" \
    -t 0

echo "[Step3] 分析完了: ${ANALYSIS_SAVE}"
exit 0

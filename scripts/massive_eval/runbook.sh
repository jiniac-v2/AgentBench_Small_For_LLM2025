#!/bin/bash
set -e

# ============================================================
# Massive Evaluation Runbook
#
# CSV に列挙された複数モデルを連続的に評価するオーケストレータ。
# 各ステップは独立したスクリプトとして実装されている。
#
# Usage:
#   sudo bash scripts/massive_eval/runbook.sh [models.csv]
#
# CSV format (ヘッダー行必須):
#   OmniAccount,OmniID,Pre-check,Model_Path,READ_KEY,
#   Current_Score,Valid_Status,Valid_Time,Score,DB_Bench,ALFWorld
#
# パイプライン:
#   Step 1: step1_start_vllm.sh  - vLLM 立ち上げ (キャッシュクリア含む)
#   Step 2: step2_evaluate.sh    - 評価実行 (タスクサーバー + assigner.py)
#   Step 3: step3_analysis.sh    - analysis.py 実行
#   Step 4: step4_organize.sh    - 結果整理 (OmniAccount プレフィックス)
#
# Valid_Status:
#   vLLM-Error    : vLLM の立ち上げ失敗
#   Valid-Error    : 評価中に失敗
#   Analysis-Error : analysis.py の実行に失敗
#   Finish         : 正常完了
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CSV_FILE="${1:-${SCRIPT_DIR}/models.csv}"
RESULTS_BASE="${APP_DIR}/massive_eval_results"

if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    exit 1
fi

mkdir -p "$RESULTS_BASE"

# ── ユーティリティ関数 ───────────────────────────

update_csv() {
    local line_num="$1"
    local new_line="$2"
    sed -i "${line_num}s|.*|${new_line}|" "$CSV_FILE"
}

get_latest_output() {
    ls -1dt "${APP_DIR}/outputs/"*/ 2>/dev/null | head -1
}

extract_scores() {
    local output_dir="$1"
    local score_file="${output_dir}/analysis/result.json"
    if [ -f "$score_file" ]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
scores = data.get('overall_scores', {})
for agent, s in scores.items():
    overall = s.get('overall_score', '')
    db = s.get('db_bench_score', '')
    alf = s.get('alf_score', '')
    print(f'{overall},{db},{alf}')
    sys.exit(0)
print(',,')
" "$score_file"
    else
        echo ",,"
    fi
}

format_duration() {
    local seconds="$1"
    printf '%02d:%02d:%02d' $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}

# ── メインループ ──────────────────────────────────

echo ""
echo "============================================"
echo " Massive Evaluation Runbook"
echo " CSV:     ${CSV_FILE}"
echo " Results: ${RESULTS_BASE}"
echo "============================================"
echo ""

total_count=0
finish_count=0
error_count=0
skip_count=0

csv_line_num=0
while IFS=',' read -r omni_account omni_id pre_check model_path read_key \
                       current_score valid_status valid_time score db_bench alfworld; do
    csv_line_num=$((csv_line_num + 1))

    # ヘッダー行スキップ
    if [ $csv_line_num -eq 1 ]; then
        continue
    fi

    # 空行スキップ
    if [ -z "$omni_account" ] || [ -z "$model_path" ]; then
        continue
    fi

    total_count=$((total_count + 1))

    # Pre-check が OK でなければスキップ
    if [ "$pre_check" != "OK" ]; then
        echo "[skip] ${omni_account} (OmniID=${omni_id}) -- Pre-check=${pre_check}"
        skip_count=$((skip_count + 1))
        continue
    fi

    # 既に Finish ならスキップ
    if [ "$valid_status" = "Finish" ]; then
        echo "[skip] ${omni_account} (OmniID=${omni_id}) -- already Finish"
        skip_count=$((skip_count + 1))
        continue
    fi

    echo ""
    echo "============================================"
    echo " [${total_count}] ${omni_account} (OmniID=${omni_id})"
    echo " Model: ${model_path}"
    echo "============================================"

    pipeline_start=$(date +%s)

    # ────────────────────────────────────────────
    # Step 1: vLLM 立ち上げ
    # ────────────────────────────────────────────
    if ! bash "${SCRIPT_DIR}/step1_start_vllm.sh" "$model_path" "$read_key"; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},vLLM-Error,${duration},,,"
        echo "[FAIL] ${omni_account}: vLLM-Error (${duration})"
        error_count=$((error_count + 1))
        continue
    fi

    # ────────────────────────────────────────────
    # Step 2: 評価実行
    # ────────────────────────────────────────────
    if ! bash "${SCRIPT_DIR}/step2_evaluate.sh"; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Valid-Error,${duration},,,"
        echo "[FAIL] ${omni_account}: Valid-Error (${duration})"
        error_count=$((error_count + 1))
        continue
    fi

    # ────────────────────────────────────────────
    # Step 3: analysis.py 実行
    # ────────────────────────────────────────────
    latest_output="$(get_latest_output)"
    if [ -z "$latest_output" ]; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Analysis-Error,${duration},,,"
        echo "[FAIL] ${omni_account}: Analysis-Error -- no output directory (${duration})"
        error_count=$((error_count + 1))
        continue
    fi

    if ! bash "${SCRIPT_DIR}/step3_analysis.sh" "$latest_output"; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Analysis-Error,${duration},,,"
        echo "[FAIL] ${omni_account}: Analysis-Error (${duration})"
        error_count=$((error_count + 1))
        continue
    fi

    # ────────────────────────────────────────────
    # Step 4: 評価コンテンツの整理
    # ────────────────────────────────────────────
    bash "${SCRIPT_DIR}/step4_organize.sh" "$omni_account" "$latest_output" "$RESULTS_BASE"

    # ────────────────────────────────────────────
    # スコア抽出 & CSV 書き戻し
    # ────────────────────────────────────────────
    scores_csv="$(extract_scores "$latest_output")"
    IFS=',' read -r score_val db_val alf_val <<< "$scores_csv"

    pipeline_end=$(date +%s)
    duration=$(format_duration $((pipeline_end - pipeline_start)))

    update_csv "$csv_line_num" \
        "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Finish,${duration},${score_val},${db_val},${alf_val}"

    echo ""
    echo "[OK] ${omni_account}: Score=${score_val} DB=${db_val} ALF=${alf_val} Time=${duration}"
    finish_count=$((finish_count + 1))

done < "$CSV_FILE"

echo ""
echo "============================================"
echo " Massive Evaluation 完了"
echo "============================================"
echo " 合計:   ${total_count}"
echo " 成功:   ${finish_count}"
echo " 失敗:   ${error_count}"
echo " スキップ: ${skip_count}"
echo ""
echo " 結果: ${RESULTS_BASE}/"
echo " CSV:  ${CSV_FILE}"
echo "============================================"

#!/bin/bash
set -e

# ============================================================
# Massive Evaluation Runner
#
# CSV に列挙された複数モデルを連続的に評価する。
#
# Usage:
#   sudo bash scripts/massive_eval/run_massive.sh [models.csv]
#
# CSV format (ヘッダー行必須):
#   OmniAccount,OmniID,Pre-check,Model_Path,READ_KEY,
#   Current_Score,Valid_Status,Valid_Time,Score,DB_Bench,ALFWorld
#
# Pre-check が "OK" の行のみ実行する。
#
# パイプライン (1モデルあたり):
#   1. vLLM 立ち上げ (.env / yaml 更新 + vLLM 再起動 + 起動待ち)
#   2. assigner.py の実行 (タスクサーバー起動 → 評価)
#   3. analysis.py の実行
#   4. 評価コンテンツの整理 (OmniAccount プレフィックス付きディレクトリに保存)
#
# Valid_Status:
#   vLLM-Error  : vLLM の立ち上げ失敗
#   Valid-Error   : 評価中に失敗
#   Analysis-Error: analysis.py の実行に失敗
#   Finish       : 正常完了
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CSV_FILE="${1:-${APP_DIR}/scripts/massive_eval/models.csv}"
RESULTS_BASE="${APP_DIR}/massive_eval_results"

if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    exit 1
fi

mkdir -p "$RESULTS_BASE"

# ── CSV 書き戻し関数 ──────────────────────────────

# CSV の特定行を更新する (行番号ベースで安全に書き戻す)
# Usage: update_csv <line_num> <new_line>
update_csv() {
    local line_num="$1"
    local new_line="$2"
    sed -i "${line_num}s|.*|${new_line}|" "$CSV_FILE"
}

# ── パイプライン Step 1: vLLM 立ち上げ ───────────

start_vllm() {
    local model="$1" token="$2"

    echo "[Step1] vLLM 立ち上げ: model=${model}"

    # .env 更新
    cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${model}
HUGGING_FACE_HUB_TOKEN=${token}
EOF

    # agent config 更新
    sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${model}\"|" \
        "${APP_DIR}/configs/agents/api_agents.yaml"

    # vLLM 再起動
    systemctl daemon-reload
    systemctl restart agentbench-vllm

    # 起動待ち
    local max_wait=300
    local elapsed=0
    echo "[Step1] vLLM の起動を待機中..."
    while [ $elapsed -lt $max_wait ]; do
        if curl -s --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
            echo "[Step1] vLLM 起動完了 (${elapsed}s)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo "[Step1] ... ${elapsed}s 経過"
    done
    echo "[Step1] ERROR: vLLM が ${max_wait}s 以内に起動しませんでした"
    return 1
}

# ── パイプライン Step 2: assigner.py の実行 ──────

run_assigner() {
    echo "[Step2] タスクサーバー起動..."
    bash "${APP_DIR}/scripts/eval/run-task-server.sh" &
    local task_pid=$!
    sleep 5

    echo "[Step2] assigner.py 実行開始..."
    cd "${APP_DIR}"
    python3 -m src.assigner -c configs/assignments/default.yaml -r
    local assigner_exit=$?

    # タスクサーバー停止
    kill $task_pid 2>/dev/null || true
    wait $task_pid 2>/dev/null || true

    return $assigner_exit
}

# ── パイプライン Step 3: analysis.py の実行 ──────

run_analysis() {
    local output_dir="$1"
    local analysis_save="${output_dir}/analysis"

    echo "[Step3] analysis.py 実行..."
    cd "${APP_DIR}"
    python3 -m src.analysis \
        -c configs/assignments/definition.yaml \
        -o "$output_dir" \
        -s "$analysis_save" \
        -t 0

    return $?
}

# ── パイプライン Step 4: 評価コンテンツの整理 ────

organize_results() {
    local omni_account="$1"
    local output_dir="$2"
    local dest="${RESULTS_BASE}/${omni_account}"

    echo "[Step4] 結果を整理: ${dest}/"

    # 既存があれば削除
    if [ -d "$dest" ]; then
        rm -rf "$dest"
    fi

    # outputs ディレクトリ丸ごとコピー (analysis 結果含む)
    cp -r "$output_dir" "$dest"

    echo "[Step4] 保存完了: ${dest}"
}

# ── スコア抽出関数 ───────────────────────────────

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

get_latest_output() {
    ls -1dt "${APP_DIR}/outputs/"*/ 2>/dev/null | head -1
}

format_duration() {
    local seconds="$1"
    printf '%02d:%02d:%02d' $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}

# ── メインループ ──────────────────────────────────

echo "============================================"
echo " Massive Evaluation Runner"
echo " CSV: ${CSV_FILE}"
echo "============================================"
echo ""

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

    # Pre-check が OK でなければスキップ
    if [ "$pre_check" != "OK" ]; then
        echo "[skip] ${omni_account} (OmniID=${omni_id}) -- Pre-check=${pre_check}"
        continue
    fi

    # 既に Finish ならスキップ
    if [ "$valid_status" = "Finish" ]; then
        echo "[skip] ${omni_account} (OmniID=${omni_id}) -- already Finish"
        continue
    fi

    echo ""
    echo "============================================"
    echo " ${omni_account} (OmniID=${omni_id})"
    echo " Model: ${model_path}"
    echo "============================================"

    pipeline_start=$(date +%s)

    # ── Step 1: vLLM 立ち上げ ──
    if ! start_vllm "$model_path" "$read_key"; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},vLLM-Error,${duration},,,"
        echo "[error] ${omni_account}: vLLM-Error"
        continue
    fi

    # ── Step 2: assigner.py の実行 ──
    if ! run_assigner; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Valid-Error,${duration},,,"
        echo "[error] ${omni_account}: Valid-Error (assigner failed)"
        continue
    fi

    # ── Step 3: analysis.py の実行 ──
    latest_output="$(get_latest_output)"
    if [ -z "$latest_output" ]; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Analysis-Error,${duration},,,"
        echo "[error] ${omni_account}: Analysis-Error (no output directory)"
        continue
    fi

    if ! run_analysis "$latest_output"; then
        pipeline_end=$(date +%s)
        duration=$(format_duration $((pipeline_end - pipeline_start)))
        update_csv "$csv_line_num" \
            "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Analysis-Error,${duration},,,"
        echo "[error] ${omni_account}: Analysis-Error (analysis failed)"
        continue
    fi

    # ── Step 4: 評価コンテンツの整理 ──
    organize_results "$omni_account" "$latest_output"

    # ── スコア抽出 & CSV 書き戻し ──
    scores_csv="$(extract_scores "$latest_output")"
    IFS=',' read -r score_val db_val alf_val <<< "$scores_csv"

    pipeline_end=$(date +%s)
    duration=$(format_duration $((pipeline_end - pipeline_start)))

    update_csv "$csv_line_num" \
        "${omni_account},${omni_id},${pre_check},${model_path},${read_key},${current_score},Finish,${duration},${score_val},${db_val},${alf_val}"

    echo "[done] ${omni_account}: Score=${score_val} DB=${db_val} ALF=${alf_val} Time=${duration}"

done < "$CSV_FILE"

echo ""
echo "============================================"
echo " 全モデルの評価が完了しました"
echo " 結果: ${RESULTS_BASE}/"
echo " CSV:  ${CSV_FILE}"
echo "============================================"

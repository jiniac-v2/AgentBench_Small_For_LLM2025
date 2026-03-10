#!/bin/bash
set -e

# ============================================================
# Evaluation Runbook
#
# CSV に列挙されたモデルを連続的に評価する。
# 単一モデルでも CSV に1行書けば同じ手順で動く。
#
# 前提:
#   - タスクサーバーが別ターミナルで起動済み
#     (bash eval/run-task-server.sh)
#
# Usage:
#   bash eval/runbook.sh [models.csv]
#
# CSV format (ヘッダー行必須):
#   No,machine,OmniID,OmniAccount,model_path,hf_token,
#   extract_status,Last_Update,Model_Status,PreCheck,
#   Current_Score,Valid_Status,Valid_Time,Score,DB_Bench,ALFWorld
#
# 各レコードで実行される処理:
#   1. vLLM モデル切替 (docker compose 再起動 + キャッシュ削除)
#   2. 評価実行 (python3 eval/run_evaluate.py → src.assigner)
#   3. 結果集計 (python3 -m src.analysis)
#   4. 結果整理 ({OmniID}_{OmniAccount}_ プレフィックス)
#   5. CSV にスコア・ステータス書き込み
#
# Valid_Status:
#   vLLM-Error     : vLLM の立ち上げ失敗
#   Valid-Error     : 評価中に失敗
#   Analysis-Error  : analysis.py の実行に失敗
#   Valid_TimeOut   : 制限時間超過 (2h)
#   Finish          : 正常完了
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Activate venv
# shellcheck disable=SC1091
[ -f "${APP_DIR}/.venv/bin/activate" ] && source "${APP_DIR}/.venv/bin/activate"

CSV_FILE="${1:-${SCRIPT_DIR}/models.csv}"

# 1モデルあたりの制限時間 (2時間 = 7200秒)
PIPELINE_TIMEOUT_SEC=7200

STEP1_SCRIPT="${SCRIPT_DIR}/step1_start_vllm.sh"

if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    exit 1
fi

# ── 前提条件チェック ─────────────────────────────

echo "[runbook] タスクサーバーの起動を確認中..."
if ! curl -s --max-time 3 http://localhost:5000/api >/dev/null 2>&1; then
    echo ""
    echo "ERROR: タスクサーバー (port 5000) が起動していません"
    echo "  別ターミナルで以下を実行してください:"
    echo "    bash eval/run-task-server.sh"
    echo ""
    exit 1
fi
echo "[runbook] タスクサーバー: OK"

# ── ユーティリティ関数 ───────────────────────────

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

# CSV の指定行の特定カラムだけを更新する関数
# Usage: update_csv_fields <line_num> <valid_status> <valid_time> [score] [db_bench] [alfworld]
update_csv_fields() {
    local line_num="$1"
    local valid_status="$2"
    local valid_time="$3"
    local score="${4:-}"
    local db_bench="${5:-}"
    local alfworld="${6:-}"

    # 現在の行を読み取り
    local current_line
    current_line="$(sed -n "${line_num}p" "$CSV_FILE")"

    # カラム分割 (16カラム: No,machine,OmniID,...,ALFWorld)
    IFS=',' read -r c_no c_machine c_omni_id c_omni_account c_model_path c_hf_token \
                    c_extract_status c_last_update c_model_status c_precheck \
                    c_current_score c_valid_status c_valid_time c_score c_db_bench c_alfworld \
                    <<< "$current_line"

    local new_line="${c_no},${c_machine},${c_omni_id},${c_omni_account},${c_model_path},${c_hf_token},${c_extract_status},${c_last_update},${c_model_status},${c_precheck},${c_current_score},${valid_status},${valid_time},${score},${db_bench},${alfworld}"
    sed -i "${line_num}s|.*|${new_line}|" "$CSV_FILE"
}

# ── メインループ ──────────────────────────────────

echo ""
echo "============================================"
echo " Evaluation Runbook"
echo " CSV:     ${CSV_FILE}"
echo " Output:  ${APP_DIR}/outputs/"
echo " Timeout: ${PIPELINE_TIMEOUT_SEC}s (per model)"
echo "============================================"
echo ""

total_count=0
finish_count=0
error_count=0
skip_count=0

csv_line_num=0
while IFS=',' read -r no machine omni_id omni_account model_path hf_token \
                       extract_status last_update model_status pre_check \
                       current_score valid_status valid_time score db_bench alfworld; do
    csv_line_num=$((csv_line_num + 1))

    # ヘッダー行スキップ
    if [ $csv_line_num -eq 1 ]; then
        continue
    fi

    # 空行スキップ
    if [ -z "$omni_id" ] || [ -z "$model_path" ]; then
        continue
    fi

    total_count=$((total_count + 1))
    prefix="${omni_id}_${omni_account}_"
    label="${omni_id}/${omni_account}"

    # PreCheck が OK でなければスキップ
    if [ "$pre_check" != "OK" ]; then
        echo "[skip] ${label} -- PreCheck=${pre_check}"
        skip_count=$((skip_count + 1))
        continue
    fi

    # 既に Finish ならスキップ
    if [ "$valid_status" = "Finish" ]; then
        echo "[skip] ${label} -- already Finish"
        skip_count=$((skip_count + 1))
        continue
    fi

    echo ""
    echo "============================================"
    echo " [${total_count}] ${label}"
    echo " Model: ${model_path}"
    echo "============================================"

    pipeline_start=$(date +%s)

    # ────────────────────────────────────────────
    # パイプラインをサブシェルで実行し timeout で制限
    # タスクサーバーは外部で起動済みの前提
    # ────────────────────────────────────────────
    set +e
    timeout --kill-after=60 "${PIPELINE_TIMEOUT_SEC}" bash -c '
        set -e
        SCRIPT_DIR="$1"; APP_DIR="$2"; model_path="$3"; hf_token="$4"
        latest_output_file="$5"; step1_script="$6"

        # 1. vLLM モデル切替 (停止 → キャッシュ削除 → .env更新 → 起動)
        bash "$step1_script" "$model_path" "$hf_token"

        # 2. 評価実行 (run_evaluate.py → src.assigner)
        cd "$APP_DIR"
        python3 "${SCRIPT_DIR}/run_evaluate.py" -c configs/assignments/default.yaml -r

        # 3. 結果集計 (analysis.py)
        latest_output="$(ls -1dt "${APP_DIR}/outputs/"*/ 2>/dev/null | head -1)"
        if [ -z "$latest_output" ]; then
            echo "ERROR: no output directory found" >&2
            exit 1
        fi
        bash "${SCRIPT_DIR}/step3_analysis.sh" "$latest_output"

        # latest_output パスを親に伝える
        echo "$latest_output" > "$latest_output_file"
    ' _ "$SCRIPT_DIR" "$APP_DIR" "$model_path" "$hf_token" "/tmp/latest_output_$$" "$STEP1_SCRIPT"

    pipeline_exit=$?
    set -e
    pipeline_end=$(date +%s)
    duration=$(format_duration $((pipeline_end - pipeline_start)))

    # ── タイムアウト判定 ──
    if [ $pipeline_exit -eq 124 ] || [ $pipeline_exit -eq 137 ]; then
        update_csv_fields "$csv_line_num" "Valid_TimeOut" "$duration"
        echo "[TIMEOUT] ${label}: Valid_TimeOut (${duration})"
        error_count=$((error_count + 1))
        cd "${APP_DIR}" && docker compose down 2>/dev/null || true
        rm -f "/tmp/latest_output_$$"
        continue
    fi

    # ── エラー判定 ──
    if [ $pipeline_exit -ne 0 ]; then
        update_csv_fields "$csv_line_num" "Valid-Error" "$duration"
        echo "[FAIL] ${label}: Valid-Error (${duration})"
        error_count=$((error_count + 1))
        rm -f "/tmp/latest_output_$$"
        continue
    fi

    # ── 正常完了 ──
    latest_output=""
    if [ -f "/tmp/latest_output_$$" ]; then
        latest_output="$(cat /tmp/latest_output_$$)"
        rm -f "/tmp/latest_output_$$"
    fi

    # スコア抽出 (リネーム前にやる)
    scores_csv="$(extract_scores "$latest_output")"
    IFS=',' read -r score_val db_val alf_val <<< "$scores_csv"

    update_csv_fields "$csv_line_num" "Finish" "$duration" "$score_val" "$db_val" "$alf_val"

    # 4. 結果整理: outputs/{TIMESTAMP}/ → outputs/{ID}_{Account}_{TIMESTAMP}/
    bash "${SCRIPT_DIR}/step4_organize.sh" "$prefix" "$latest_output"

    echo ""
    echo "[OK] ${label}: Score=${score_val} DB=${db_val} ALF=${alf_val} Time=${duration}"
    finish_count=$((finish_count + 1))

done < "$CSV_FILE"

echo ""
echo "============================================"
echo " Evaluation 完了"
echo "============================================"
echo " 合計:     ${total_count}"
echo " 成功:     ${finish_count}"
echo " 失敗:     ${error_count}"
echo " スキップ: ${skip_count}"
echo ""
echo " 結果: ${APP_DIR}/outputs/"
echo " CSV:  ${CSV_FILE}"
echo "============================================"

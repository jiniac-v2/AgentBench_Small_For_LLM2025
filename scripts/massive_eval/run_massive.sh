#!/bin/bash
set -e

# ============================================================
# Massive Evaluation Runner
#
# CSV ファイルに列挙された複数モデルを連続的に評価する。
#
# Usage:
#   sudo bash scripts/massive_eval/run_massive.sh [models.csv]
#
# CSV format (ヘッダー行必須):
#   id,username,hf_model_path,hf_token,overall_score
#
# 評価ワークフロー (1モデルあたり):
#   1. モデル切り替え (.env / yaml 更新 + vLLM 再起動)
#   2. vLLM 起動待ち
#   3. タスクサーバー起動 → 評価実行
#   4. analysis 実行
#   5. 結果を {username}_{model_basename} ディレクトリにコピー
#   6. overall_score を CSV に書き戻し
# ============================================================

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CSV_FILE="${1:-${APP_DIR}/scripts/massive_eval/models.csv}"
RESULTS_BASE="${APP_DIR}/massive_eval_results"

if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    exit 1
fi

mkdir -p "$RESULTS_BASE"

# ── ヘルパー関数 ──────────────────────────────────

switch_model() {
    local model="$1" token="$2"

    echo "[switch] model=${model}"

    # 1. .env 更新
    cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${model}
HUGGING_FACE_HUB_TOKEN=${token}
EOF

    # 2. agent config 更新
    sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"${model}\"|" \
        "${APP_DIR}/configs/agents/api_agents.yaml"

    # 3. vLLM 再起動
    systemctl daemon-reload
    systemctl restart agentbench-vllm
}

wait_for_vllm() {
    local max_wait=300  # 最大5分
    local elapsed=0
    echo "[wait] vLLM の起動を待機中..."
    while [ $elapsed -lt $max_wait ]; do
        if curl -s --max-time 5 http://localhost:8000/v1/models >/dev/null 2>&1; then
            echo "[wait] vLLM 起動完了 (${elapsed}s)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo "[wait] ... ${elapsed}s 経過"
    done
    echo "ERROR: vLLM が ${max_wait}s 以内に起動しませんでした"
    return 1
}

run_evaluation() {
    echo "[eval] タスクサーバー起動..."
    # タスクサーバーをバックグラウンドで起動
    bash "${APP_DIR}/scripts/eval/run-task-server.sh" &
    local task_pid=$!
    sleep 5  # タスクサーバーの起動待ち

    echo "[eval] 評価開始..."
    cd "${APP_DIR}"
    python3 -m src.assigner -c configs/assignments/default.yaml -r || true

    # タスクサーバー停止
    kill $task_pid 2>/dev/null || true
    wait $task_pid 2>/dev/null || true
}

run_analysis() {
    local output_dir="$1"
    echo "[analysis] 分析実行..."
    cd "${APP_DIR}"
    python3 -m src.analysis \
        -c configs/assignments/definition.yaml \
        -o "$output_dir" \
        -s "${output_dir}/analysis" \
        -t 0
}

get_latest_output() {
    # outputs/ 配下で最も新しいディレクトリを返す
    ls -1dt "${APP_DIR}/outputs/"*/ 2>/dev/null | head -1
}

extract_overall_score() {
    local analysis_dir="$1"
    local score_file="${analysis_dir}/analysis/result.json"
    if [ -f "$score_file" ]; then
        python3 -c "
import json, sys
with open('${score_file}') as f:
    data = json.load(f)
scores = data.get('overall_scores', {})
for agent, s in scores.items():
    print(s.get('overall_score', 'N/A'))
    sys.exit(0)
print('N/A')
"
    else
        echo "N/A"
    fi
}

# ── メインループ ──────────────────────────────────

echo "============================================"
echo " Massive Evaluation Runner"
echo " CSV: ${CSV_FILE}"
echo "============================================"
echo ""

# CSV をヘッダー付きで読み込む (1行目スキップ)
line_num=0
while IFS=',' read -r id username hf_model_path hf_token _rest; do
    line_num=$((line_num + 1))

    # ヘッダー行スキップ
    if [ $line_num -eq 1 ]; then
        continue
    fi

    # 空行スキップ
    if [ -z "$id" ] || [ -z "$hf_model_path" ]; then
        continue
    fi

    # 既にスコアが記入済みならスキップ
    if [ -n "$_rest" ] && [ "$_rest" != "" ] && [ "$_rest" != " " ]; then
        echo "[skip] ID=${id} ${username} -- already scored: ${_rest}"
        continue
    fi

    model_basename="$(basename "$hf_model_path")"
    result_dir_name="${username}_${model_basename}"

    echo ""
    echo "============================================"
    echo " [${id}] ${username} / ${hf_model_path}"
    echo "============================================"

    # Step 1: モデル切り替え
    switch_model "$hf_model_path" "$hf_token"

    # Step 2: vLLM 起動待ち
    if ! wait_for_vllm; then
        echo "[error] ID=${id} skipped (vLLM failed to start)"
        # CSV にエラーを記録
        sed -i "s|^${id},${username},${hf_model_path},${hf_token},.*|${id},${username},${hf_model_path},${hf_token},ERROR|" "$CSV_FILE"
        continue
    fi

    # Step 3: 評価実行
    run_evaluation

    # Step 4: 最新の出力ディレクトリを取得 → analysis 実行
    latest_output="$(get_latest_output)"
    if [ -z "$latest_output" ]; then
        echo "[error] ID=${id} no output directory found"
        sed -i "s|^${id},${username},${hf_model_path},${hf_token},.*|${id},${username},${hf_model_path},${hf_token},ERROR|" "$CSV_FILE"
        continue
    fi

    run_analysis "$latest_output"

    # Step 5: 結果ディレクトリをコピー
    dest="${RESULTS_BASE}/${result_dir_name}"
    if [ -d "$dest" ]; then
        rm -rf "$dest"
    fi
    cp -r "$latest_output" "$dest"
    echo "[save] 結果を保存: ${dest}"

    # Step 6: overall_score を CSV に書き戻し
    score="$(extract_overall_score "$latest_output")"
    echo "[score] ID=${id} ${username}: ${score}"
    sed -i "s|^${id},${username},${hf_model_path},${hf_token},.*|${id},${username},${hf_model_path},${hf_token},${score}|" "$CSV_FILE"

    echo "[done] ID=${id} ${username} 完了"

done < "$CSV_FILE"

echo ""
echo "============================================"
echo " 全モデルの評価が完了しました"
echo " 結果: ${RESULTS_BASE}/"
echo " CSV:  ${CSV_FILE}"
echo "============================================"

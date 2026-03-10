# クラウド評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [クラウド環境構築](setup.md)

> **Note**: `python3` を直接実行する場合は、事前に仮想環境を有効化してください:
> ```bash
> cd ~/AgentBench_Small_For_LLM2025 && source .venv/bin/activate
> ```
> `bash eval/...` で実行するスクリプトは内部で自動的に有効化します。

---

## Step 1: CSV の準備

`eval/models.csv` を作成します。**単一モデルでも CSV に1行書くだけ**で同じ手順で動きます。

```bash
cp eval/models.csv.example eval/models.csv
vi eval/models.csv
```

### CSV スキーマ

```csv
No,machine,OmniID,OmniAccount,model_path,hf_token,extract_status,Last_Update,Model_Status,PreCheck,Current_Score,Valid_Status,Valid_Time,Score,DB_Bench,ALFWorld
1,,1111,alice,Qwen/Qwen2.5-7B-Instruct,hf_xxx,,,,OK,,,,,,
2,,2222,bob,meta-llama/Llama-3.1-8B-Instruct,hf_yyy,,,,OK,,,,,,
```

| カラム | 説明 | 入力 |
|---|---|---|
| `No` | 通し番号 | 手動 |
| `machine` | マシン名 (空でもOK) | 手動 |
| `OmniID` | 識別用 ID | 手動 |
| `OmniAccount` | 識別用アカウント名 | 手動 |
| `model_path` | HuggingFace モデルパス | 手動 |
| `hf_token` | HuggingFace トークン (READ権限) | 手動 |
| `extract_status` | 抽出ステータス | 手動 |
| `Last_Update` | 最終更新日時 | 手動 |
| `Model_Status` | モデルステータス | 手動 |
| `PreCheck` | **`OK` のもののみ評価される** | 手動 |
| `Current_Score` | 現在のスコア | 手動 |
| `Valid_Status` | 実行結果ステータス | **自動** |
| `Valid_Time` | 所要時間 | **自動** |
| `Score` | 総合スコア | **自動** |
| `DB_Bench` | DBBench スコア | **自動** |
| `ALFWorld` | ALFWorld スコア | **自動** |

結果ディレクトリは `eval_results/{OmniID}_{OmniAccount}_/` に保存されます。

---

## Step 2: vLLM の起動確認

初回または VM を再起動した場合は、vLLM が起動していることを確認します。

```bash
cd ~/AgentBench_Small_For_LLM2025

# コンテナの状態確認
docker compose ps

# 起動していなければ起動
docker compose up -d

# 起動完了の確認 (1〜3分かかる)
docker compose logs -f vllm
```

`Uvicorn running on http://0.0.0.0:8000` が表示されれば準備完了。

```bash
# API で直接確認
curl -s http://localhost:8000/health
```

> Step 4 の runbook.sh が CSV の各レコードごとにモデルを自動切替するため、
> ここでは何のモデルが載っていても構いません。

---

## Step 3: タスクサーバー起動

**別ターミナル**でタスクサーバーを起動します。フォアグラウンドで動き続けます。

```bash
cd ~/AgentBench_Small_For_LLM2025
bash eval/run-task-server.sh
```

> **VSCode の場合:** ターミナル右上の分割ボタン、または `Ctrl+Shift+5` でターミナルを複製できます。
>
> ![ターミナル複製](../../assets/ターミナル複製.gif)

起動したらこのターミナルはそのまま放置して、**元のターミナル**で Step 4 に進みます。

---

## Step 4: 評価実行

```bash
cd ~/AgentBench_Small_For_LLM2025
bash eval/runbook.sh eval/models.csv
```

これで CSV の各レコードに対して以下が自動的に繰り返されます:

1. **vLLM モデル切替** - docker compose 再起動、推論キャッシュ削除、`.env` / `api_agents.yaml` 更新
2. **評価実行** - `python3 eval/run_evaluate.py` → `src.assigner` (全タスク実行)
3. **結果集計** - `python3 -m src.analysis` でスコア算出
4. **結果整理** - `eval_results/{OmniID}_{OmniAccount}_/` にコピー
5. **CSV 更新** - `Valid_Status`, `Valid_Time`, `Score`, `DB_Bench`, `ALFWorld` を自動記入

制限時間は **1モデルあたり2時間** です。超過すると `Valid_TimeOut` が記録されます。

### Valid_Status 一覧

| ステータス | 意味 |
|---|---|
| `Finish` | 正常完了 |
| `vLLM-Error` | vLLM の起動に失敗 |
| `Valid-Error` | 評価中にエラー発生 |
| `Analysis-Error` | analysis.py の実行に失敗 |
| `Valid_TimeOut` | 制限時間超過 (2h) |

### オプション: Prefect でトレース

Prefect を使うと、Web UI で各ステップの進捗やエラーログをリアルタイムに確認できます。
Slack 通知にも対応しています。

```bash
# ターミナル A: Prefect サーバー起動
prefect server start

# ターミナル B: Prefect 版で評価実行
cd ~/AgentBench_Small_For_LLM2025
python3 eval/runbook.py eval/models.csv
```

Prefect UI は `http://localhost:4200` で確認できます。

GCP VM 上で動かしている場合は SSH トンネルでアクセス:

```bash
# ローカル PC から
gcloud compute ssh agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID \
  --ssh-flag="-L 4200:localhost:4200"
```

> VSCode Remote SSH の場合はポートが自動転送されるため SSH トンネル不要です。

#### Slack 通知の設定 (任意)

1. [Slack App](https://api.slack.com/apps) を作成
2. **Incoming Webhooks** を有効化し、チャンネルに Webhook URL を発行
3. `.env` に追記:

```bash
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T.../B.../xxxx
```

> 通知内容はモデル名・ステータス・スコア・所要時間のみ。トークン等の機密情報は送信しません。

---

## デバッグ: 単一タスクだけ実行する

ALFWorld / DBBench を個別に動かしたい場合。
Step 2 まで済んでいる前提で、タスクサーバーと assigner を手動で動かします。

### ALFWorld だけ

```bash
# タスクサーバー (別ターミナル)
bash eval/run-task-server.sh alf

# アサイナー
source .venv/bin/activate
python3 -m src.assigner -c configs/assignments/debug_alf.yaml 2>&1 | tee outputs/execution.log
```

### DBBench だけ

```bash
# タスクサーバー (別ターミナル)
bash eval/run-task-server.sh db

# アサイナー
source .venv/bin/activate
python3 -m src.assigner -c configs/assignments/debug_db.yaml 2>&1 | tee outputs/execution.log
```

### 前回の結果をクリアして再実行する場合

```bash
rm -rf outputs/*
```

---

## Step 5: 結果確認

```bash
ls ~/AgentBench_Small_For_LLM2025/eval_results/
cat eval/models.csv
```

ローカルにコピー:

```bash
gcloud compute scp --recurse \
  agentbench-eval:~/AgentBench_Small_For_LLM2025/eval_results/ ./eval_results/ \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

> VSCode の方は eval_results 配下のデータを DL でいいです

---

## vLLM の状態確認・監視

```bash
# コンテナの状態確認
docker compose ps

# ログの確認
docker compose logs --tail=50 vllm

# ログをリアルタイムで追跡
docker compose logs -f vllm
```

### vLLM の再起動

```bash
cd ~/AgentBench_Small_For_LLM2025
docker compose down && docker compose up -d
```

---

## トラブルシューティング

### "0 samples remaining"

前回の結果がキャッシュされています:

```bash
rm -rf outputs/*
```

### ALFWorld: `FileNotFoundError` / `PermissionError`: `data/alfworld/logic/alfred.pddl`

alfworld ランタイムデータのシンボリックリンクが未作成、またはリンク先にアクセスできません。
`setup2.sh` を再実行してください (sudo 不要):

```bash
bash ~/AgentBench_Small_For_LLM2025/infra/gcp/setup2.sh
```

**PermissionError の場合**: シンボリックリンクが `/root/.cache/alfworld/` を指している可能性があります
（`setup2.sh` を `sudo` で実行した場合に発生）。確認方法:

```bash
ls -la data/alfworld/logic
# /root/ 配下を指している → setup2.sh を sudo なしで再実行
```

### vLLM 接続エラー

```bash
docker compose ps
docker compose logs --tail=50 vllm
```

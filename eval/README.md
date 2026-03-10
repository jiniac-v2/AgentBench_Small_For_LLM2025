# 評価リファレンス

WSL / GCP 共通の評価関連リファレンスです。

## CSV スキーマ

`eval/models.csv` に評価対象モデルを記載します。**単一モデルでも CSV に1行書くだけ**で同じ手順で動きます。

```bash
cp eval/models.csv.example eval/models.csv
vi eval/models.csv
```

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

評価結果は `outputs/{OmniID}_{OmniAccount}_{TIMESTAMP}/` に保存されます。

---

## 評価パイプライン

`runbook.sh` は CSV の各レコード (PreCheck=OK) に対して以下を自動的に繰り返します:

1. **vLLM モデル切替** - docker compose 再起動、推論キャッシュ削除、`.env` / `api_agents.yaml` 更新
2. **評価実行** - `python3 eval/run_evaluate.py` → `src.assigner` (全タスク実行)
3. **結果集計** - `python3 -m src.analysis` でスコア算出
4. **結果整理** - `outputs/{TIMESTAMP}/` を `outputs/{OmniID}_{OmniAccount}_{TIMESTAMP}/` にリネーム
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

---

## オプション: Prefect でトレース

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

### Slack 通知の設定 (任意)

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
vLLM が起動済みの前提で、タスクサーバーと assigner を手動で動かします。

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
# WSL の場合
bash ~/AgentBench_Small_For_LLM2025/infra/wsl/setup2.sh

# GCP の場合
bash ~/AgentBench_Small_For_LLM2025/infra/gcp/setup2.sh
```

**PermissionError の場合**: シンボリックリンクが `/root/.cache/alfworld/` を指している可能性があります
（`setup2.sh` を `sudo` で実行した場合に発生）。確認方法:

```bash
ls -la data/alfworld/logic
# /root/ 配下を指している → setup2.sh を sudo なしで再実行
```

### docker: Permission denied

```
docker.errors.DockerException: Error while fetching server API version:
  ('Connection aborted.', PermissionError(13, 'Permission denied'))
```

現在のシェルに docker グループが反映されていません。各ターミナルで `newgrp docker` を実行してください:

```bash
newgrp docker
```

> `newgrp docker` はターミナルごとに必要です。新しいターミナルを開くたびに実行してください。
> 一度ログアウト → 再ログインすればすべてのシェルに反映されます。

### docker compose up: NVIDIA ドライバエラー

```
nvidia-container-cli: initialization error: load library failed:
  libnvidia-ml.so.1: cannot open shared object file: no such file or directory
```

NVIDIA GPU ドライバがインストールされていないか、認識されていません。

```bash
# ドライバの状態確認
nvidia-smi

# GCP Deep Learning VM の場合
sudo /opt/deeplearning/install-driver.sh

# インストール後に確認
nvidia-smi
```

> `setup1.sh` を実行済みであれば通常このエラーは発生しません。
> VM を再作成した場合やイメージが異なる場合は手動インストールが必要です。

### vLLM 接続エラー

```bash
docker compose ps
docker compose logs --tail 50 vllm
curl -s http://localhost:8000/health
```

### vLLM が OOM で落ちる

VRAM が不足しています。`.env` で以下を調整:

```bash
# モデルサイズを小さくする
VLLM_MODEL=Qwen/Qwen2.5-3B-Instruct

# または VRAM 使用率・コンテキスト長を下げる
VLLM_GPU_MEMORY_UTILIZATION=0.85
VLLM_MAX_MODEL_LEN=4096
```

変更後: `docker compose down && docker compose up -d`

### WSL のメモリ不足

WSL2 のデフォルトメモリ上限に引っかかっている可能性があります。
`%UserProfile%\.wslconfig` でメモリを増やしてください（[詳細](../infra/wsl/setup.md#メモリ制限)）。

# クラウド評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [クラウド環境構築](setup.md)

> **Note**: `python3` を直接実行する場合は、事前に `source .venv/bin/activate` してください。
> `bash eval/...` で実行するスクリプトは内部で自動的に有効化します。

---

## Step 1: VM に SSH ログイン

```bash
gcloud compute ssh VM_NAME --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

Prefect UI にアクセスする場合はポートフォワーディング付きで接続します:

```bash
gcloud compute ssh VM_NAME --zone YOUR_ZONE --project YOUR_PROJECT_ID \
  -- -L 4200:localhost:4200
```

> ログイン後、ブラウザで `http://localhost:4200` から Prefect UI を確認できます。

---

## Step 2: CSV の準備

評価するモデルを CSV に記載します。→ [CSV スキーマの詳細](../../eval/README.md#csv-スキーマ)

### 方法 A: VM 上で直接編集

```bash
cp eval/models.csv.example eval/models.csv
vi eval/models.csv
```

### 方法 B: ローカルから転送

ローカルで CSV を用意して VM に転送します。

```bash
# ローカルで実行
gcloud compute scp eval/models.csv VM_NAME:~/AgentBench_Small_For_LLM2025/eval/models.csv \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

---

## Step 3: vLLM の起動確認

初回または VM を再起動した場合は、vLLM が起動していることを確認します。

```bash
cd ~/AgentBench_Small_For_LLM2025
newgrp docker          # 新しいシェルでは docker グループが未反映のため必須

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

> runbook.py が CSV の各レコードごとにモデルを自動切替するため、
> ここでは何のモデルが載っていても構いません。

---

## Step 4: .env の準備 (ターミナル 1)

`.env.example` に Slack Webhook URL を記入してからコピーします:

```bash
vi .env.example   # SLACK_WEBHOOK_URL= に URL を貼る
cp .env.example .env
```

---

## Step 5: Prefect サーバー起動 (ターミナル 1)

```bash
source .venv/bin/activate
prefect server start
```

`Started server at http://0.0.0.0:4200` が表示されたら OK。

---

## Step 6: タスクサーバー起動 (ターミナル 2)

`Ctrl+Shift+`` で新しいターミナルを開きます:

```bash
cd ~/AgentBench_Small_For_LLM2025
newgrp docker          # タスクワーカー (dbbench) が docker を使うため必須
bash eval/run-task-server.sh
```

---

## Step 7: 評価実行 (ターミナル 3)

`Ctrl+Shift+`` でもう 1 つターミナルを開きます:

```bash
cd ~/AgentBench_Small_For_LLM2025
newgrp docker          # 評価スクリプトが docker コマンドを使うため必須
source .venv/bin/activate
python3 eval/runbook.py eval/models.csv
```

評価パイプラインの詳細・Valid_Status の一覧は [評価リファレンス](../../eval/README.md#評価パイプライン) を参照してください。

---

## Step 8: 結果確認

```bash
# プレフィックス付きディレクトリが outputs/ 配下にある
ls ~/AgentBench_Small_For_LLM2025/outputs/

# CSV にスコアが自動記入されている
cat eval/models.csv
```

ローカルにコピー:

```bash
# ローカルで実行
gcloud compute scp --recurse \
  VM_NAME:~/AgentBench_Small_For_LLM2025/outputs/ ./outputs/ \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

---

## デバッグ・トラブルシューティング

→ [デバッグ: 単一タスクだけ実行する](../../eval/README.md#デバッグ-単一タスクだけ実行する)

→ [トラブルシューティング](../../eval/README.md#トラブルシューティング)

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
docker compose down && docker compose up -d
```

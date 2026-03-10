# WSL 評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [WSL 環境構築](setup.md)

> **Note**: `python3` を直接実行する場合は、事前に仮想環境を有効化してください:
> ```bash
> cd ~/AgentBench_Small_For_LLM2025 && source .venv/bin/activate
> ```
> `bash eval/...` で実行するスクリプトは内部で自動的に有効化します。

---

## Step 1: CSV の準備

評価するモデルを CSV に記載します。→ [CSV スキーマの詳細](../../eval/README.md#csv-スキーマ)

```bash
cp eval/models.csv.example eval/models.csv
vi eval/models.csv
```

---

## Step 2: vLLM の起動確認

初回または PC を再起動した場合は、vLLM が起動していることを確認します。

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

## Step 3: .env の準備

`.env.example` に Slack Webhook URL を記入してからコピーします (Slack 通知が不要なら空欄のままでOK):

```bash
vi .env.example   # SLACK_WEBHOOK_URL= に URL を貼る
cp .env.example .env
```

---

## Step 4: Prefect サーバー起動 (ターミナル 1)

```bash
cd ~/AgentBench_Small_For_LLM2025
source .venv/bin/activate
prefect server start
```

`Started server at http://0.0.0.0:4200` が表示されたら OK。
ブラウザで `http://localhost:4200` から Prefect UI を確認できます。

---

## Step 5: タスクサーバー起動 (ターミナル 2)

新しいターミナルを開きます。

> **Windows Terminal の場合:** `Ctrl+Shift+D` でペインを分割できます。
>
> **VSCode の場合:** ターミナル右上の分割ボタン、または `Ctrl+Shift+5` でターミナルを複製できます。

```bash
cd ~/AgentBench_Small_For_LLM2025
newgrp docker          # タスクワーカー (dbbench) が docker を使うため必須
bash eval/run-task-server.sh
```

起動したらこのターミナルはそのまま放置して、新しいターミナルで Step 6 に進みます。

---

## Step 6: 評価実行 (ターミナル 3)

もう 1 つ新しいターミナルを開きます:

```bash
cd ~/AgentBench_Small_For_LLM2025
newgrp docker          # 評価スクリプトが docker コマンドを使うため必須
source .venv/bin/activate
python3 eval/runbook.py eval/models.csv
```

評価パイプラインの詳細・Valid_Status の一覧は [評価リファレンス](../../eval/README.md#評価パイプライン) を参照してください。

---

## Step 7: 結果確認

```bash
# プレフィックス付きディレクトリが outputs/ 配下にある
ls ~/AgentBench_Small_For_LLM2025/outputs/

# CSV にスコアが自動記入されている
cat eval/models.csv
```

---

## デバッグ・トラブルシューティング

→ [デバッグ: 単一タスクだけ実行する](../../eval/README.md#デバッグ-単一タスクだけ実行する)

→ [トラブルシューティング](../../eval/README.md#トラブルシューティング)

---

## vLLM の状態確認・監視

```bash
# コンテナの確認
docker compose ps

# ログの確認
docker compose logs --tail=50 vllm

# ログをリアルタイムで追跡
docker compose logs -f vllm
```

### vLLM の手動再起動

```bash
cd ~/AgentBench_Small_For_LLM2025
docker compose down
docker compose up -d
```

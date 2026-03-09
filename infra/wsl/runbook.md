# ローカル評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [ローカル環境構築](setup.md)

> **Note**: `python3` を直接実行する場合は、事前に仮想環境を有効化してください:
> ```bash
> cd ~/AgentBench_Small_For_LLM2025 && source .venv/bin/activate
> ```
> `bash eval/...` で実行するスクリプトは内部で自動的に有効化します。

---

## Step 1: モデル切替

`.env` を編集してモデル名・HF トークンを設定し、docker compose で vLLM を再起動します。

```bash
cd ~/AgentBench_Small_For_LLM2025

# .env を編集
vi .env
```

```bash
VLLM_MODEL=your-org/your-model
HUGGING_FACE_HUB_TOKEN=hf_xxxxxxxxxxxxx
```

```bash
# vLLM 再起動
docker compose down && docker compose up -d

# agent config のモデル名も更新
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"your-org/your-model\"|" configs/agents/api_agents.yaml
```

---

## Step 2: vLLM の起動確認

モデル切替後、vLLM が完全に起動するまで待ちます (1〜3 分)。

```bash
# ヘルスチェック
docker compose ps

# ログ確認 (起動完了まで待つ)
docker compose logs -f vllm
```

`INFO:     Started server process` や `Uvicorn running on http://0.0.0.0:8000` が表示されれば準備完了。

API で直接確認:

```bash
curl -s http://localhost:8000/health
# "OK" が返れば準備完了
```

---

## Step 3: タスクサーバー起動

> ここは vLLM を再起動していない場合は毎回やらなくてもいい。連続でモデル評価したい場合はスキップしてください

```bash
cd ~/AgentBench_Small_For_LLM2025
bash eval/run-task-server.sh
```

5000 番台のポートに残っているプロセスを自動で停止してからサーバーを起動します。
フォアグラウンドで動き続けるため、**別のターミナル**で Step 4 以降を実行してください。

> **Windows Terminal の場合:** `Ctrl+Shift+D` でペインを分割できます。
>
> **VSCode の場合:** ターミナル右上の分割ボタン、または `Ctrl+Shift+5` でターミナルを複製できます。

---

## Step 4: 評価実行

```bash
cd ~/AgentBench_Small_For_LLM2025
source .venv/bin/activate
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

- 実行ログ: `outputs/execution.log`
- 結果: `outputs/` 以下

### 前回の結果をクリアして再実行する場合

```bash
rm -rf outputs/*
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

---

## デバッグ: 単一タスクだけ実行する

ALFWorld / DBBench を個別に動かしたい場合は、`--config` でデバッグ用設定を指定します。
同時実行数は通常実行と同じです（ALF: 5並列, DB: 1並列, エージェント: 5並列）。

### ALFWorld だけ

```bash
# タスクサーバー (別ターミナル)
bash eval/run-task-server.sh alf

# アサイナー
python3 -m src.assigner -c configs/assignments/debug_alf.yaml 2>&1 | tee outputs/execution.log
```

### DBBench だけ

```bash
# タスクサーバー (別ターミナル)
bash eval/run-task-server.sh db

# アサイナー
python3 -m src.assigner -c configs/assignments/debug_db.yaml 2>&1 | tee outputs/execution.log
```

---

## Step 5: 結果集計

評価が完了したら、結果を集計してスコアを算出します。

```bash
cd ~/AgentBench_Small_For_LLM2025
python3 -m src.analysis -o outputs -s analysis
```

`analysis/` ディレクトリに以下が出力されます:

| ファイル | 内容 |
|---|---|
| `result.json` / `result.yaml` | 全詳細 |
| `summary.csv` | エージェント × タスクの主要メトリクス |
| `overall_score.csv` | 総合スコア (oa) |
| `agent_validation.csv` | エージェント別バリデーション |
| `task_validation.csv` | タスク別バリデーション |

何もオプションをつけなければ一番新しい日付のログを対象にします。
`-t` オプションで集計対象の時間範囲を指定できます:

```bash
# 直近1日分だけ集計
python3 -m src.analysis -o outputs -s analysis -t 1d
```

---

## Step 6: 結果確認

```bash
cat ~/AgentBench_Small_For_LLM2025/analysis/overall_score.csv
```

---

## vLLM の状態確認・監視

```bash
# コンテナの確認
docker compose ps

# ログの確認
docker compose logs --tail 50 vllm

# ログをリアルタイムで追跡
docker compose logs -f vllm
```

### vLLM の手動再起動

```bash
cd ~/AgentBench_Small_For_LLM2025
docker compose down
docker compose up -d
```

---

## トラブルシューティング

### "0 samples remaining"

前回の結果がキャッシュされています:

```bash
rm -rf outputs/*
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

### ALFWorld: `FileNotFoundError` / `PermissionError`: `data/alfworld/logic/alfred.pddl`

alfworld ランタイムデータのシンボリックリンクが未作成、またはリンク先にアクセスできません。
`setup2.sh` を再実行してください (sudo 不要):

```bash
bash ~/AgentBench_Small_For_LLM2025/infra/wsl/setup2.sh
```

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
`%UserProfile%\.wslconfig` でメモリを増やしてください（[詳細](setup.md#メモリ制限)）。

---

## 複数モデル一括実行

ローカル環境でも評価パイプラインを利用できます。
クラウド版と同じ仕組みです。docker compose で vLLM を管理します。

### セットアップ

```bash
pip install "prefect>=3.0,<4.0"
```

### CSV の準備

[クラウド版と同じフォーマット](../gcp/runbook.md#csv-の準備) で `eval/models.csv` を作成してください。

### 実行

```bash
# ターミナル 1: Prefect サーバー起動
prefect server start

# ターミナル 2: 評価実行
cd ~/AgentBench_Small_For_LLM2025
python3 eval/runbook.py [models.csv]
```

### Prefect UI で進捗確認

ブラウザで `http://localhost:4200` を開いてください（ローカルなので SSH トンネル不要）。

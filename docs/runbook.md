# 評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [ローカル](setup-local.md) / [GCP](setup-gcp.md) + [セットアップスクリプト](setup.md)

---

## Step 1: モデル切替

### GCP 環境

```bash
# switch-model.sh を編集してモデル名・HFトークンを設定
vi ~/AgentBench_Small_For_LLM2025/scripts/eval/switch-model.sh
```

```bash
# ---- ここを編集 ----
VLLM_MODEL="your-org/your-model"
HF_TOKEN="hf_xxxxxxxxxxxxx"    # private モデルの場合
# ---------------------
```

```bash
# モデル切替 (.env + config 更新 → サービス再起動)
sudo bash ~/AgentBench_Small_For_LLM2025/scripts/eval/switch-model.sh
```

### ローカル環境

```bash
# .env のモデル名を変更
vi .env
```

```bash
# vLLM を再起動
docker compose down && docker compose up -d
```

vLLM が起動するまで待つ:

```bash
curl http://localhost:8000/v1/models
```

レスポンスが返れば OK。

---

## Step 2: タスクサーバー起動 (ターミナル 1)

```bash
cd ~/AgentBench_Small_For_LLM2025
python3 -m src.start_task -a
```

Controller と Workers がすべて起動するまで待つ（`Worker registered` のログが出れば OK）。

**このターミナルは閉じずにそのまま維持する。**

---

## Step 3: 評価実行 (ターミナル 2 — 別ターミナルを開く)

新しいターミナルを開いて以下を実行:

```bash
cd ~/AgentBench_Small_For_LLM2025
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

## Step 4: 結果確認

```bash
ls ~/AgentBench_Small_For_LLM2025/outputs/
```

GCP からローカルにコピー:

```bash
gcloud compute scp --recurse \
  agentbench-eval:~/AgentBench_Small_For_LLM2025/outputs/ ./outputs/ \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

---

## Step 5: タスクサーバー停止

ターミナル 1 で `Ctrl+C` を押す。

リモート接続で `Ctrl+C` が効かない場合は、別ターミナルから:

```bash
pkill -f "src.start_task"
```

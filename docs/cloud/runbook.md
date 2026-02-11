# クラウド評価の実行

実験のたびに実行する手順です。環境構築は済んでいる前提: [クラウド環境構築](setup.md)

---

## Step 1: モデル切替

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

---

## Step 2: タスクサーバー起動 (ターミナル 1)

```bash
cd ~/AgentBench_Small_For_LLM2025
sudo -E python3 -m src.start_task -a 
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

## デバッグ: 単一タスクだけ実行する

ALFWorld / DBBench を個別に動かしたい場合は、専用のデバッグ用設定を使います。
同時実行数は通常実行と同じです（ALF: 5並列, DB: 1並列, エージェント: 5並列）。

### ALFWorld だけ

```bash
# ターミナル 1: タスクサーバー
sudo -E python3 -m src.start_task -a --config configs/start_task_alf.yaml

# ターミナル 2: アサイナー
python3 -m src.assigner -c configs/assignments/debug_alf.yaml 2>&1 | tee outputs/execution.log
```

### DBBench だけ

```bash
# ターミナル 1: タスクサーバー
sudo -E python3 -m src.start_task -a --config configs/start_task_db.yaml

# ターミナル 2: アサイナー
python3 -m src.assigner -c configs/assignments/debug_db.yaml 2>&1 | tee outputs/execution.log
```

---

## Step 4: 結果確認

```bash
ls ~/AgentBench_Small_For_LLM2025/outputs/
```

ローカルにコピー:

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

---

## サービスの状態確認・監視

```bash
# 各サービスの状態
sudo systemctl status agentbench-vllm
sudo systemctl status agentbench-controller
sudo systemctl status agentbench-worker-dbbench
sudo systemctl status agentbench-worker-alfworld

# vLLM コンテナの確認
sudo docker ps | grep vllm

# ログの確認
sudo journalctl -u agentbench-vllm -n 50
sudo journalctl -u agentbench-controller -n 50

# vLLM のログをリアルタイムで追跡
sudo journalctl -u agentbench-vllm -f
```

### サービスの手動再起動

```bash
sudo systemctl restart agentbench-vllm
sudo systemctl restart agentbench-controller
sudo systemctl restart agentbench-worker-dbbench
sudo systemctl restart agentbench-worker-alfworld
```

---

## トラブルシューティング

### サービスが起動しない

```bash
sudo journalctl -u agentbench-<service-name> -n 100
sudo systemctl restart agentbench-<service-name>
```

### "0 samples remaining"

前回の結果がキャッシュされています:

```bash
rm -rf outputs/*
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

### vLLM 接続エラー

```bash
sudo systemctl status agentbench-vllm
sudo journalctl -u agentbench-vllm -n 50
docker ps | grep vllm
```

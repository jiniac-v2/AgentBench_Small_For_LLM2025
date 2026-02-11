# 評価実行

環境構築が完了していること: [ローカル環境構築](setup-local.md) / [GCP環境構築](setup-gcp.md)

## モデル切替

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
export VLLM_MODEL="your-org/your-model"
bash scripts/eval/run.sh
```

---

## 評価実行

ローカル・GCP 共通です。

```bash
cd ~/AgentBench_Small_For_LLM2025
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

結果は `outputs/` に出力されます。

### 前回の結果をクリアして再実行

```bash
rm -rf outputs/*
python3 -m src.assigner -c configs/assignments/default.yaml 2>&1 | tee outputs/execution.log
```

---

## サービスの状態確認・監視 (GCP)

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

## 結果取得

```bash
# VM 上で確認
ls ~/AgentBench_Small_For_LLM2025/outputs/

# ローカルにコピー
gcloud compute scp --recurse \
  agentbench-eval:~/AgentBench_Small_For_LLM2025/outputs/ ./outputs/ \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
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

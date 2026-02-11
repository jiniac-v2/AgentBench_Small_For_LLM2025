# 評価実行

## ローカル環境

[ローカル環境構築](setup-local.md) が完了していること。

```bash
export VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
bash scripts/run.sh
```

`scripts/run.sh` は以下を順番に実行します:
1. エージェント設定にモデル名を展開
2. vLLM 推論テスト
3. Controller 起動 (port 5020)
4. DBBench Worker (port 5023) → ALFWorld Worker (port 5021) 起動
5. Assigner による評価実行

結果は `outputs/` に出力されます。

---

## GCP 環境

[GCP 環境構築](setup-gcp.md) が完了していること。SSH で VM に接続した状態で操作します。

VM は一度構築すれば、複数モデルの評価に繰り返し使えます。

### モデル設定・評価実行

```bash
# 1. switch-model.sh を編集してモデル名・HFトークンを設定
vi ~/AgentBench_Small_For_LLM2025/scripts/switch-model.sh
```

```bash
# ---- ここを編集 ----
VLLM_MODEL="your-org/your-model"
HF_TOKEN="hf_xxxxxxxxxxxxx"    # private モデルの場合
# ---------------------
```

```bash
# 2. 実行
sudo bash ~/AgentBench_Small_For_LLM2025/scripts/switch-model.sh

```

`switch-model.sh` は以下を自動実行します:
1. `.env` + `api_agents.yaml` のモデル名を更新
2. vLLM + 全サービスを再起動
3. 前回の出力をクリア
4. Assigner (評価) を実行

### 監視

```bash
# 評価の進行状況
sudo journalctl -u agentbench-assigner -f

# 各サービスの状態
sudo systemctl status agentbench-vllm
sudo systemctl status agentbench-controller
sudo systemctl status agentbench-worker-dbbench
sudo systemctl status agentbench-worker-alfworld
```

### 結果取得

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
rm -rf outputs/<task-name>*
python3 -m src.assigner configs/assignments/default.yaml
```

### vLLM 接続エラー

```bash
sudo systemctl status agentbench-vllm
sudo journalctl -u agentbench-vllm -n 50
docker ps | grep vllm
```

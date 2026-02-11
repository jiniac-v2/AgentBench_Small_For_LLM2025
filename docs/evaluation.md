# 評価リファレンス

実験の手順は [評価の実行](runbook.md) を参照してください。

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

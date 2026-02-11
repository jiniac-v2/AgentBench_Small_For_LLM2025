# VM の確認・起動・停止

## VM の状態確認

### CLI

```bash
# VM の状態を確認
gcloud compute instances describe agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID \
  --format="table(name,status,networkInterfaces[0].accessConfigs[0].natIP)"
```

出力例:
```
NAME             STATUS   NAT_IP
agentbench-eval  RUNNING  34.xxx.xxx.xxx
```

| STATUS | 意味 |
|---|---|
| `RUNNING` | 起動中 (課金中) |
| `TERMINATED` | 停止中 (ディスク課金のみ) |
| `STAGING` | 起動準備中 |
| `SUSPENDED` | サスペンド中 |

```bash
# プロジェクト内の全 VM を一覧
gcloud compute instances list --project YOUR_PROJECT_ID
```

### コンソール

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` の行に状態 (緑チェック = 起動中) と外部 IP が表示される

---

## VM の停止

GPU VM は起動中は課金されます。使わない間は停止してください。

### CLI

```bash
gcloud compute instances stop agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

### コンソール

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「停止」** ボタンをクリック

> 停止中はディスク (200GB pd-balanced) の料金のみ発生します。GPU・CPU 料金は発生しません。

---

## VM の起動

### CLI

```bash
gcloud compute instances start agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

### コンソール

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「起動」** ボタンをクリック

> 起動後、startup.sh が自動でインフラサービス (vLLM, Controller, Worker) を開始します (2回目以降はプロビジョニングをスキップ)。

---

## VM の削除

VM とディスクを完全に削除します（課金が完全に停止します）。

### CLI (Terraform)

```bash
cd terraform && terraform destroy
```

### コンソール

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「削除」** ボタンをクリック

> **注意**: Terraform で作成した場合は `terraform destroy` を推奨します (Service Account, Firewall ルールも合わせて削除されます)。

---

## サービスの状態確認 (SSH 接続後)

VM に SSH 接続した状態で、AgentBench の各サービスを確認できます。

```bash
# 全サービスの状態を一覧
sudo systemctl status agentbench-vllm
sudo systemctl status agentbench-controller
sudo systemctl status agentbench-worker-dbbench
sudo systemctl status agentbench-worker-alfworld

# vLLM コンテナの確認
sudo docker ps | grep vllm

# 各サービスのログ
sudo journalctl -u agentbench-vllm -n 50
sudo journalctl -u agentbench-controller -n 50
```

### サービスの手動再起動

```bash
sudo systemctl restart agentbench-vllm
sudo systemctl restart agentbench-controller
sudo systemctl restart agentbench-worker-dbbench
sudo systemctl restart agentbench-worker-alfworld
```

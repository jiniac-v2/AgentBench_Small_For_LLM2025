# AgentBench v0.3 Small

[AgentBench](https://github.com/THUDM/AgentBench) の小規模版です。以下の2タスクのみを含みます:

- **DBBench** - データベースクエリタスク (80 tasks)
- **ALFWorld** - 家庭内の対話的タスク (134 tasks)

推論は vLLM (OpenAI互換API) 経由で実行します。

---

## アーキテクチャ

```
┌──────────────────────────────────────────────────┐
│                   GCE / Local                    │
├──────────────────────────────────────────────────┤
│  vLLM (Docker)                    Port: 8000     │
│    └── vllm/vllm-openai:v0.13.0                 │
├──────────────────────────────────────────────────┤
│  AgentBench (Native Python)                      │
│    ├── Controller                 Port: 5020     │
│    ├── ALFWorld Worker            Port: 5021     │
│    ├── DBBench Worker             Port: 5023     │
│    └── Assigner (Evaluation)                     │
├──────────────────────────────────────────────────┤
│  MySQL (Docker, DBBench用)        Port: 動的     │
│    └── mysql:9.5.0                               │
└──────────────────────────────────────────────────┘
```

---

## ローカル実行

### 1. 環境構築

```bash
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025

python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Docker が動作していることを確認:

```bash
docker ps
docker pull mysql:9.5.0
```

### 2. vLLM 起動

```bash
# docker compose を使う場合
cp .env.example .env
vi .env  # VLLM_MODEL を設定
docker compose up -d

# または直接実行
docker run --rm --gpus all --ipc=host -p 8000:8000 \
  vllm/vllm-openai:v0.13.0 \
  --model "Qwen/Qwen2.5-7B-Instruct" \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.95
```

### 3. 評価実行

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

## GCP デプロイ (Terraform)

### 前提条件

- `gcloud` CLI インストール・認証済み
- `terraform` >= 1.0 インストール済み
- 対象GCPプロジェクトへのアクセス権限

### 1. GCP 認証

```bash
gcloud auth login
gcloud auth application-default login
```

### 2. Terraform 設定

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
```

`terraform.tfvars`:
```hcl
project_id   = "your-project-id"    # 必須: GCPプロジェクトID
region       = "me-central2"
zone         = "me-central2-c"
machine_type = "g2-standard-8"      # 8 vCPU, 32GB RAM, NVIDIA L4
disk_size_gb = 200
vllm_model   = "Qwen/Qwen2.5-7B-Instruct"
hf_token     = ""                   # gated model の場合のみ
```

### 3. VM 作成

```bash
terraform init
terraform plan     # 変更内容を確認
terraform apply    # VM作成 (自動構築開始)
```

出力例:
```
instance_ip = "34.xxx.xxx.xxx"
ssh_command = "gcloud compute ssh agentbench-eval --zone me-central2-c --project your-project-id"
```

### 4. SSH 接続・状態確認

```bash
gcloud compute ssh agentbench-eval \
  --zone me-central2-c \
  --project your-project-id
```

VM 起動後、`startup.sh` が自動で以下を実行します:

```
startup.sh (自動)
  ├── Docker Compose plugin + NVIDIA Container Toolkit
  ├── git clone (Self-Clone)
  ├── pip install -r requirements.txt
  ├── .env 生成 (メタデータから VLLM_MODEL 取得)
  ├── docker pull mysql:9.5.0 / vllm-openai:v0.13.0
  └── systemd サービス起動
       ├── agentbench-vllm          (Docker, port 8000)
       ├── agentbench-controller    (port 5020, 推論テスト込み)
       ├── agentbench-worker-dbbench   (port 5023)
       ├── agentbench-worker-alfworld  (port 5021)
       └── agentbench-assigner      (評価実行)
```

### 5. サービス監視

```bash
# startup スクリプトのログ
sudo journalctl -u google-startup-scripts -f

# 各サービスの状態
sudo systemctl status agentbench-vllm
sudo systemctl status agentbench-controller
sudo systemctl status agentbench-worker-dbbench
sudo systemctl status agentbench-worker-alfworld

# Assigner の進行状況
sudo journalctl -u agentbench-assigner -f

# vLLM 推論確認
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 10
  }'
```

### 6. 結果取得

```bash
# VM 上で確認
ls /opt/agentbench/outputs/

# ローカルにコピー
gcloud compute scp --recurse \
  agentbench-eval:/opt/agentbench/outputs/ ./outputs/ \
  --zone me-central2-c --project your-project-id
```

### 7. モデル変更・再実行

```bash
# SSH 接続した状態で
sudo vi /opt/agentbench/.env           # VLLM_MODEL を変更
sudo sed -i 's|model:.*|model: "新モデル名"|' /opt/agentbench/configs/agents/api_agents.yaml

# サービス再起動
sudo systemctl restart agentbench-vllm
sudo systemctl restart agentbench-controller
sudo systemctl restart agentbench-worker-dbbench
sudo systemctl restart agentbench-worker-alfworld

# 前回の出力を削除して再実行
sudo rm -rf /opt/agentbench/outputs/*
sudo systemctl restart agentbench-assigner
```

### 8. VM 削除

```bash
cd terraform/
terraform destroy
```

### Secret Manager (privateリポジトリの場合)

リポジトリが非公開の場合、GitHub PAT を Secret Manager に登録:

```bash
echo -n "ghp_xxxxxxxxxxxx" | \
  gcloud secrets create github-pat --data-file=- --project=your-project-id
```

VM の Service Account に自動で Secret Manager アクセス権限が付与されます。

---

## トラブルシューティング

### サービスが起動しない

```bash
# ログ確認
sudo journalctl -u agentbench-<service-name> -n 100

# サービス再起動
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

---

## GCP スペック

| 項目 | 値 |
|---|---|
| マシンタイプ | g2-standard-8 (8 vCPU, 32GB RAM) |
| GPU | NVIDIA L4 |
| ディスク | 200GB pd-balanced |
| OS | Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570 |
| vLLM | v0.13.0 |
| MySQL | 9.5.0 |

---

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```

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

## GCP デプロイ

### 0. 事前準備

`gcloud` CLI と `terraform` がインストール・認証済みであること。

#### 請求先アカウント

GPU 付き VM を使うには請求先アカウントが紐づいている必要があります（無料トライアルでは GPU クォータは付与されません）。
[Cloud コンソール → お支払い](https://console.cloud.google.com/billing) で確認してください。

#### GCP プロジェクトの準備

```bash
# 1. 認証
gcloud auth login
gcloud auth application-default login    # Terraform 用

# 2. プロジェクト設定
gcloud projects list
gcloud config set project YOUR_PROJECT_ID

# 3. 必要な API を有効化
gcloud services enable compute.googleapis.com           # Compute Engine
gcloud services enable iam.googleapis.com               # IAM
gcloud services enable secretmanager.googleapis.com     # Secret Manager (private repo 用)
```

#### GPU クォータの確認・引き上げ

GPU クォータは新規プロジェクトではデフォルト **0** です。引き上げが必要です。

**CLI で確認 (推奨):**

```bash
gcloud compute regions describe me-central2 \
  --project YOUR_PROJECT_ID \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" \
  | grep -i nvidia
```

`NVIDIA_L4_GPUS` の `limit` が `0` なら引き上げが必要です。

**コンソールで確認・引き上げ:**

1. [Google Cloud コンソール → IAM と管理 → 割り当て](https://console.cloud.google.com/iam-admin/quotas) を開く
2. ページ左上の **「割り当てタイプ」ドロップダウンを「すべての割り当て」に変更** する
   (デフォルトの「使用中の割り当て」だと使用量 0 のクォータが非表示になる)
3. フィルタ欄で絞り込む:
   - **サービス**: `Compute Engine API` を選択
   - **制限名** (Limit Name): `NVIDIA_L4` と入力
4. 一覧に `NVIDIA_L4_GPUS` が表示される。`me-central2` リージョンの「上限」が **0** なら引き上げが必要

> ヒットしない場合: フィルタの「リージョン」は指定しないでください。使用量 0 のクォータはリージョン指定すると表示されません。

**引き上げリクエスト:**

5. 対象のクォータ行のチェックボックスをオンにする
6. ページ上部の **「割り当てを編集」** をクリック
7. 右側パネルで **「新しい上限」に `1`** を入力
8. **リクエストの説明** に理由を記入（例: `Need 1 NVIDIA L4 GPU for LLM evaluation on G2 VM`）
9. **「完了」** → **「次へ」** → 連絡先を確認して **「リクエストを送信」**

> 引き上げには数分〜数日かかる場合があります。承認・却下はメールで通知されます。
> 無料トライアルアカウントでは GPU クォータは付与されません。

### 1. VM 構築 (ローカルから一発)

```bash
# Terraform 設定
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars    # project_id を設定（必須）

# VM 作成 〜 プロビジョニング完了まで一発実行
bash scripts/setup-gcp.sh
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

`setup-gcp.sh` は以下を順番に実行します:
1. `terraform apply` (VM 作成)
2. SSH 接続待ち
3. プロビジョニング完了待ち (Docker pull 等で初回10〜15分)

完了すると SSH 接続コマンドが表示されます。

### 2. SSH 接続

```bash
# gcloud SSH
gcloud compute ssh agentbench-eval --zone me-central2-c --project your-project-id

# または VSCode Remote SSH (IP は setup-gcp.sh の出力に表示)
```

### 3. 評価実行 (SSH 接続後)

VM は一度構築すれば、複数モデルの評価に繰り返し使えます。

```bash
# 1. switch-model.sh を編集してモデル名・HFトークンを設定
sudo vi /opt/agentbench/scripts/switch-model.sh

# ---- ここを編集 ----
# VLLM_MODEL="your-org/your-model"
# HF_TOKEN="hf_xxxxxxxxxxxxx"    # private モデルの場合
# ---------------------

# 2. 実行
sudo bash /opt/agentbench/scripts/switch-model.sh
```

`switch-model.sh` は以下を自動実行します:
1. `.env` + `api_agents.yaml` のモデル名を更新
2. vLLM + 全サービスを再起動
3. 前回の出力をクリア
4. Assigner (評価) を実行

### 4. 監視・結果取得

```bash
# 評価の進行状況
sudo journalctl -u agentbench-assigner -f

# 各サービスの状態
sudo systemctl status agentbench-vllm
sudo systemctl status agentbench-controller
sudo systemctl status agentbench-worker-dbbench
sudo systemctl status agentbench-worker-alfworld
```

```bash
# 結果確認 (VM 上)
ls /opt/agentbench/outputs/

# ローカルにコピー
gcloud compute scp --recurse \
  agentbench-eval:/opt/agentbench/outputs/ ./outputs/ \
  --zone me-central2-c --project your-project-id
```

### 5. VM 削除

```bash
cd terraform && terraform destroy
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

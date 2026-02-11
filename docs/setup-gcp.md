# 環境構築: GCP

## 前提条件

- `gcloud` CLI インストール済み — [インストール方法](https://docs.cloud.google.com/sdk/docs/install-sdk?hl=ja)
- `terraform` >= 1.0 インストール済み — [インストール方法](https://developer.hashicorp.com/terraform/install)

## Step 1: 認証・プロジェクト設定

```bash
gcloud auth login
gcloud auth application-default login    # Terraform 用
```

```bash
gcloud projects list
gcloud config set project YOUR_PROJECT_ID
```

## Step 2: 請求先アカウントの確認

GPU 付き VM を使うには請求先アカウントが紐づいている必要があります（無料トライアルでは GPU クォータは付与されません）。
[Cloud コンソール → お支払い](https://console.cloud.google.com/billing) で確認してください。

## Step 3: API の有効化

```bash
gcloud services enable compute.googleapis.com           # Compute Engine
gcloud services enable iam.googleapis.com               # IAM
gcloud services enable secretmanager.googleapis.com     # Secret Manager (private repo 用)
```

> Compute Engine API が有効でないと、VM 作成もクォータ確認もできません。必ず先に実行してください。

## Step 4: GPU クォータの確認・引き上げ

GPU クォータは新規プロジェクトではデフォルト **0** です。以下の **2つ** のクォータ引き上げが必要です。

| クォータ名 | 説明 | 確認レベル |
|---|---|---|
| `GPUS_ALL_REGIONS` | 全リージョン合計の GPU 数上限 | プロジェクト全体 |
| `NVIDIA_L4_GPUS` | リージョン別の L4 GPU 数上限 | 使用するリージョン |

**CLI で確認:**

```bash
# (A) グローバル GPU クォータ
gcloud compute project-info describe --project YOUR_PROJECT_ID --format=json \
  | python3 -c "
import json, sys
for q in json.load(sys.stdin).get('quotas', []):
    if 'GPU' in q.get('metric', ''):
        print(f\"{q['metric']}: limit={q['limit']}, usage={q['usage']}\")"

# (B) リージョン別 L4 クォータ (YOUR_REGION を使用リージョンに置き換え)
gcloud compute regions describe YOUR_REGION --project YOUR_PROJECT_ID --format=json \
  | python3 -c "
import json, sys
for q in json.load(sys.stdin).get('quotas', []):
    if 'NVIDIA_L4' in q.get('metric', ''):
        print(f\"{q['metric']}: limit={q['limit']}, usage={q['usage']}\")"
```

両方とも `limit=1.0` 以上なら OK です。

**コンソールで引き上げ:**

1. [Google Cloud コンソール → IAM と管理 → 割り当て](https://console.cloud.google.com/iam-admin/quotas) を開く
2. **「割り当てタイプ」→「すべての割り当て」に変更** (使用量 0 のクォータはデフォルト非表示)
3. 以下の **2つ** を順番に引き上げる:

**(A) `GPUS_ALL_REGIONS` (グローバル):**
- フィルタ: **サービス** `Compute Engine API`、**制限名** `GPUS_ALL_REGIONS`
- チェックボックスオン → **「割り当てを編集」** → 新しい上限 `1`

**(B) `NVIDIA_L4_GPUS` (リージョン別):**
- フィルタ: **サービス** `Compute Engine API`、**制限名** `NVIDIA_L4`
- 使用するリージョンの行のチェックボックスオン → **「割り当てを編集」** → 新しい上限 `1`

4. **リクエストの説明** に理由を記入（例: `Need 1 NVIDIA L4 GPU for LLM evaluation on G2 VM`）
5. **「完了」** → **「次へ」** → 連絡先を確認して **「リクエストを送信」**

> 引き上げには数分〜数日かかる場合があります。承認・却下はメールで通知されます。

## Step 5: 利用可能なゾーンの確認

```bash
gcloud compute accelerator-types list --filter="name=nvidia-l4" --project YOUR_PROJECT_ID
```

`terraform.tfvars` の `region` / `zone` は上記で表示されるゾーンから選択してください。

## Step 6: VM 構築

```bash
# Terraform 設定
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars    # project_id, region, zone を設定
```

`terraform.tfvars`:
```hcl
project_id   = "your-project-id"    # 必須
region       = "asia-northeast1"    # Step 5 で確認したリージョン
zone         = "asia-northeast1-a"  # Step 5 で確認したゾーン
machine_type = "g2-standard-8"      # 8 vCPU, 32GB RAM, NVIDIA L4
disk_size_gb = 200
vllm_model   = "Qwen/Qwen2.5-7B-Instruct"
hf_token     = ""                   # gated model の場合のみ
```

```bash
# VM 作成 〜 プロビジョニング完了まで一発実行
bash scripts/setup-gcp.sh
```

`setup-gcp.sh` は以下を順番に実行します:
1. `terraform apply` (VM 作成)
2. SSH 接続待ち
3. プロビジョニング完了待ち (Docker pull 等で初回10〜15分)

完了すると SSH 接続コマンドが表示されます。

環境構築は以上です。次のステップ:
- [VM 接続方法](vm-connection.md) — SSH / VSCode での接続
- [VM の確認・起動・停止](vm-management.md) — VM の状態管理
- [評価実行](evaluation.md) — モデル評価の実行

---

## 補足

### Secret Manager (private リポジトリの場合)

リポジトリが非公開の場合、GitHub PAT を Secret Manager に登録:

```bash
echo -n "ghp_xxxxxxxxxxxx" | \
  gcloud secrets create github-pat --data-file=- --project=your-project-id
```

VM の Service Account に自動で Secret Manager アクセス権限が付与されます。

### VM の管理

VM の起動・停止・削除については [VM の確認・起動・停止](vm-management.md) を参照してください。

### GCP スペック

| 項目 | 値 |
|---|---|
| マシンタイプ | g2-standard-8 (8 vCPU, 32GB RAM) |
| GPU | NVIDIA L4 |
| ディスク | 200GB pd-balanced |
| OS | Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570 |
| vLLM | v0.13.0 |
| MySQL | 9.5.0 |

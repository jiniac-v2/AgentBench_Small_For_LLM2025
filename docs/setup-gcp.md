# 環境構築: GCP

## 前提条件

- `gcloud` CLI インストール済み
- `terraform` >= 1.0 インストール済み

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

## Step 7: VM に接続

### 方法 A: コマンドライン (gcloud SSH)

```bash
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

### 方法 B: VSCode Remote SSH

#### 1. 拡張機能のインストール

VSCode で以下の拡張機能をインストール:
- **Remote - SSH** (`ms-vscode-remote.remote-ssh`)

#### 2. SSH 鍵の生成・SSH config の自動設定

```bash
# gcloud が SSH 鍵を生成し、~/.ssh/config に接続情報を自動追加
gcloud compute config-ssh --project YOUR_PROJECT_ID
```

実行すると `~/.ssh/config` に以下のようなエントリが追加されます:
```
Host agentbench-eval.YOUR_ZONE.YOUR_PROJECT_ID
    HostName <外部IP>
    IdentityFile ~/.ssh/google_compute_engine
    UserKnownHostsFile ~/.ssh/google_compute_known_hosts
    ...
```

> 初回のみ `~/.ssh/google_compute_engine` (秘密鍵) と `~/.ssh/google_compute_engine.pub` (公開鍵) が自動生成されます。

#### 3. VSCode から接続

1. `Cmd + Shift + P` → **Remote-SSH: Connect to Host** を選択
2. 一覧から `agentbench-eval.YOUR_ZONE.YOUR_PROJECT_ID` を選択
3. 接続後、左下に `SSH: agentbench-eval...` と表示されれば成功

#### 4. ワークスペースを開く

接続後、**ファイル → フォルダを開く** で `/opt/agentbench` を開くと、VM 上のコードを直接編集できます。

> **VM の IP が変わった場合** (VM 再起動時など): `gcloud compute config-ssh` を再実行して `~/.ssh/config` を更新してください。

環境構築は以上です。評価の実行は [評価実行ガイド](evaluation.md) を参照してください。

---

## 補足

### Secret Manager (private リポジトリの場合)

リポジトリが非公開の場合、GitHub PAT を Secret Manager に登録:

```bash
echo -n "ghp_xxxxxxxxxxxx" | \
  gcloud secrets create github-pat --data-file=- --project=your-project-id
```

VM の Service Account に自動で Secret Manager アクセス権限が付与されます。

### VM 削除

```bash
cd terraform && terraform destroy
```

### GCP スペック

| 項目 | 値 |
|---|---|
| マシンタイプ | g2-standard-8 (8 vCPU, 32GB RAM) |
| GPU | NVIDIA L4 |
| ディスク | 200GB pd-balanced |
| OS | Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570 |
| vLLM | v0.13.0 |
| MySQL | 9.5.0 |

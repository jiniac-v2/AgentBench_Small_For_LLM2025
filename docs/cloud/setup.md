# クラウド環境構築 (GCP)

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

> 引き上げは1分くらいで許可降ります

## Step 5: 利用可能なゾーンの確認

```bash
gcloud compute accelerator-types list --filter="name=nvidia-l4" --project YOUR_PROJECT_ID
```

`terraform.tfvars` の `region` / `zone` は上記で表示されるゾーンから選択してください。

## Step 6: VM 作成

```bash
# Terraform 設定
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars    # project_id, region, zone を設定
```

`terraform.tfvars`:
```hcl
project_id   = "your-project-id"    # 必須
region       = "asia-northeast1"    # Step 5 で確認したリージョン. 過疎ってそうなリージョンを選択することを推奨
zone         = "asia-northeast1-a"  # Step 5 で確認したゾーン．過疎ってそうなゾーンを選択することを推奨．
machine_type = "g2-standard-8"      # 8 vCPU, 32GB RAM, NVIDIA L4
disk_size_gb = 200
git_branch   = ""              # VM にクローンするブランチ(現在:kit_v0.2)
```

> 基本的に本キットでは，初期構築を１度やればあとはVMを停止→再起動させても同じ作業をしなくて済むようになってます．  
> が，GCPの仕様上，GPUが枯渇しているリージョン・ゾーンで停止してしまうと，再起動時にGPUが掴めなくてマシン作り直しになることがあります．  
> ある意味，その為にこのようなキットがあるとも

```bash
# VM 作成 + 構築完了待ち + リポジトリ clone
bash scripts/infra/setup-gcp.sh
```

`setup-gcp.sh` は以下を実行します:
1. `terraform apply` (VM 作成)
2. startup script が自動で clone (private リポの場合は Secret Manager の PAT を使用)

> 基本的にここで失敗しそうな原因はリージョンガチャした結果，そのリージョン/ゾーンは使えないよ，と言われたパターンが大抵です．
> また別のリージョン/ゾーンに変えてみてください．

## Step 7: VM に接続

SSH で VM に接続します。接続方法は2つあります:

- **方法 A**: `gcloud compute ssh` コマンド（すぐ使える）
- **方法 B**: VSCode Remote - SSH（IDE 機能をフル活用したい場合）

詳細は [VM 接続方法](#vm-接続方法) を参照してください．方法Bを推奨します．

## Step 8: セットアップスクリプト

VM 上で以下を実行します。

```bash
cd ~/AgentBench_Small_For_LLM2025

# (1) Docker / NVIDIA / Python 依存 (要 sudo)
sudo bash scripts/setup/setup1.sh

# docker グループ反映のため再ログイン
exit
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
# または以下コマンド
newgrp docker

# (2) ALFWorld データ / .env / Docker イメージ pull
cd ~/AgentBench_Small_For_LLM2025
bash scripts/setup/setup2.sh
```

## Step 9: systemd セットアップ

VM 再起動時に vLLM を自動起動させます。

```bash
sudo bash scripts/setup/setup_systemd.sh
```

確認:

```bash
systemctl status agentbench-vllm
```

> vLLMは立ち上げに時間がかかるので，マシン再起動後しばらく時間を置いてから評価を走らせましょう．

## 次のステップ

[クラウド評価の実行](runbook.md) に進んでください。

---

## VM 接続方法

### 方法 A: コマンドライン (gcloud SSH)

```bash
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

### 方法 B: VSCode Remote - SSH (推奨)

後ほどターミナルを複数使うので，こちらを推奨

#### 前提

- gcloud CLI がインストール済み・認証済み (`gcloud auth login`)
- VSCode 拡張機能:
  - **Remote - SSH** (`ms-vscode-remote.remote-ssh`) — VM への接続・リモート開発
  - **Cloud Code** (`GoogleCloudTools.cloudcode`) — VM の状態確認 (任意)

#### SSH config の自動生成

`gcloud compute config-ssh` を実行すると、プロジェクト内の全 VM に対する SSH 設定が `~/.ssh/config` に自動追記されます。

```bash
gcloud compute config-ssh
```

`gcloud auth login` で認証済みであれば、プロジェクトの VM を自動検出し、SSH config (`~/.ssh/config`) と鍵ペア (`~/.ssh/google_compute_engine`) を生成します。

成功すると以下のように表示されます:

```
You should now be able to use ssh/scp with your instances.
For example, try running:

  $ ssh agentbench-eval.asia-northeast1-a.YOUR_PROJECT_ID
```

> VM の外部 IP が変わった場合 (停止→起動後など) は、再度 `gcloud compute config-ssh` を実行してください。

#### VSCode から接続

**コマンドパレットから:**

1. `Cmd+Shift+P` (Mac) / `Ctrl+Shift+P` (Windows/Linux)
2. **Remote-SSH: Connect to Host...** を選択
3. `agentbench-eval.ZONE.PROJECT_ID` を選択

**左下のリモートアイコンから:**

1. VSCode 左下の **緑色の `><` アイコン** をクリック
2. **ホストに接続する (Connect to Host...)** を選択
3. `agentbench-eval.ZONE.PROJECT_ID` を選択

**リモートエクスプローラーから:**

1. 左サイドバーの **リモートエクスプローラー** アイコン (モニターのアイコン) をクリック
2. ドロップダウンで **SSH ターゲット (Remotes (SSH))** を選択
3. `agentbench-eval.ZONE.PROJECT_ID` が一覧に表示される
4. ホスト名の右にある **→ アイコン** (Connect in Current Window) をクリック

いずれの方法でも、新しい VSCode ウィンドウが開き VM に接続されます。

#### SSH config の削除
不要になったら自動生成された設定を削除できます:

```bash
gcloud compute config-ssh --remove
```

### 補足: Cloud Code で VM の状態を確認する

Cloud Code 拡張機能をインストールすると、VSCode のサイドバーから VM の状態 (実行中・停止中など) を GUI で確認できます。

1. 左サイドバーの **Cloud Code アイコン** をクリック
2. **Compute Engine** セクションを展開
3. プロジェクトを選択すると、VM の一覧と状態が表示される

> Cloud Code は VM の状態確認用です。VM への接続・リモート開発には上記の **Remote - SSH** を使用してください。

---

## VM の管理

### VM の状態確認

**CLI:**

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

**コンソール:**

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` の行に状態 (緑チェック = 起動中) と外部 IP が表示される

### VM の停止

GPU VM は起動中は課金されます。使わない間は停止してください。

**CLI:**

```bash
gcloud compute instances stop agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

**コンソール:**

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「停止」** ボタンをクリック

> 停止中はディスク (200GB pd-balanced) の料金のみ発生します。GPU・CPU 料金は発生しません。

### VM の起動

**CLI:**

```bash
gcloud compute instances start agentbench-eval \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

**コンソール:**

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「起動」** ボタンをクリック

> 起動後、systemd が自動でインフラサービス (vLLM, Controller, Worker) を開始します。startup.sh はプロビジョニング済みの場合何もしません。
> **注意**: 停止→起動で外部 IP が変わるため、VSCode Remote SSH を使う場合は `gcloud compute config-ssh` を再実行してください。

### VM の削除

VM とディスクを完全に削除します（課金が完全に停止します）。

**CLI (Terraform):**

```bash
cd terraform && terraform destroy
```

**コンソール:**

1. [Compute Engine → VM インスタンス](https://console.cloud.google.com/compute/instances) を開く
2. `agentbench-eval` のチェックボックスをオン
3. ページ上部の **「削除」** ボタンをクリック

> **注意**: Terraform で作成した場合は `terraform destroy` を推奨します (Service Account, Firewall ルールも合わせて削除されます)。

---

## 補足

### Secret Manager (private リポジトリの場合)

リポジトリが非公開の場合、GitHub PAT を Secret Manager に登録:

```bash
echo -n "ghp_xxxxxxxxxxxx" | \
  gcloud secrets create github-pat --data-file=- --project=your-project-id
```

VM の Service Account に自動で Secret Manager アクセス権限が付与されます。

### GCP スペック

| 項目 | 値 |
|---|---|
| マシンタイプ | g2-standard-8 (8 vCPU, 32GB RAM) |
| GPU | NVIDIA L4 |
| ディスク | 200GB pd-balanced |
| OS | Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570 |
| vLLM | v0.13.0 |
| MySQL | 9.5.0 |

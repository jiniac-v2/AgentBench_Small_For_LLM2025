# VM 接続方法

VM 構築 ([環境構築: GCP](setup-gcp.md)) が完了していること。

## 方法 A: コマンドライン (gcloud SSH)

```bash
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

## 方法 B: VSCode + Cloud Code 拡張機能 (推奨)

SSH config の手動設定不要で、GUI から VM に接続できます。

### 1. 拡張機能のインストール

VSCode で以下の拡張機能をインストール:
- **Cloud Code** (`GoogleCloudTools.cloudcode`)

### 2. GCP プロジェクトの選択

1. VSCode 左サイドバーの **Cloud Code アイコン** をクリック
2. **Compute Engine** セクションを展開
3. プロジェクトが未選択なら、プロジェクトを選択

### 3. SSH 接続

1. Compute Engine セクションに `agentbench-eval` が表示される
2. `agentbench-eval` を**右クリック** → **「Open SSH」** を選択
3. VSCode のターミナルで SSH セッションが開く

### 4. ファイルのアップロード・ログ確認

- VM を右クリック → **「Upload files」** でローカルファイルを VM に転送可能
- VM を右クリック → **「View logs」** で VM ログを IDE 内で確認可能

### 5. リモートファイル編集

SSH 接続後、**ファイル → フォルダを開く** で `/opt/agentbench` を開くと、VM 上のコードを直接編集できます。

> Cloud Code は外部 IP のない VM にも IAP 経由で接続できます。

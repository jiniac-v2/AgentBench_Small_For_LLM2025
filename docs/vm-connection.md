# VM 接続方法

VM 構築 ([環境構築: GCP](setup-gcp.md)) が完了していること。

## 方法 A: コマンドライン (gcloud SSH)

```bash
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

## 方法 B: VSCode Remote - SSH (推奨)

VSCode の **Remote - SSH** 拡張機能で VM に接続し、エクスプローラー・ターミナル・拡張機能などフル IDE 機能をリモートで利用できます。

### 1. 前提

- gcloud CLI がインストール済み・認証済み (`gcloud auth login`)
- VSCode 拡張機能:
  - **Remote - SSH** (`ms-vscode-remote.remote-ssh`) — VM への接続・リモート開発
  - **Cloud Code** (`GoogleCloudTools.cloudcode`) — VM の状態確認 (任意)

### 2. SSH config の自動生成

`gcloud compute config-ssh` を実行すると、プロジェクト内の全 VM に対する SSH 設定が `~/.ssh/config` に自動追記されます。

```bash
gcloud compute config-ssh --project YOUR_PROJECT_ID
```

成功すると以下のように表示されます:

```
You should now be able to use ssh/scp with your instances.
For example, try running:

  $ ssh agentbench-eval.asia-northeast1-a.YOUR_PROJECT_ID
```

> SSH 鍵ペア (`~/.ssh/google_compute_engine`) も自動生成されます。
> VM の外部 IP が変わった場合 (停止→起動後など) は、再度 `gcloud compute config-ssh` を実行してください。

### 3. VSCode から接続

1. `Cmd+Shift+P` (Mac) / `Ctrl+Shift+P` (Windows/Linux)
2. **Remote-SSH: Connect to Host...** を選択
3. `agentbench-eval.ZONE.PROJECT_ID` を選択
4. 新しい VSCode ウィンドウが開き、VM に接続される

### 4. リモート開発

接続が完了すると、VSCode がリモート VM 上で動作するモードになります。
ローカル開発と同じ操作感で VM 上のファイルを扱えます。

- **フォルダを開く**: **ファイル → フォルダを開く** → `~/AgentBench_Small_For_LLM2025` を指定
- **エクスプローラー**: 左サイドバーでファイルツリーを閲覧・操作
- **ファイル編集**: 通常どおりコードを編集・保存 (変更は即座に VM に反映)
- **ターミナル**: `` Ctrl+` `` で VM 上のシェルを直接操作
- **拡張機能**: Python 等の拡張機能はリモート側にインストールされ、VM 上で実行される
- **Git**: ソース管理タブで VM 上のリポジトリを操作可能

### SSH config の削除

不要になったら自動生成された設定を削除できます:

```bash
gcloud compute config-ssh --remove --project YOUR_PROJECT_ID
```

## 補足: Cloud Code で VM の状態を確認する

Cloud Code 拡張機能をインストールすると、VSCode のサイドバーから VM の状態 (実行中・停止中など) を GUI で確認できます。

1. 左サイドバーの **Cloud Code アイコン** をクリック
2. **Compute Engine** セクションを展開
3. プロジェクトを選択すると、VM の一覧と状態が表示される

> Cloud Code は VM の状態確認用です。VM への接続・リモート開発には上記の **Remote - SSH** を使用してください。

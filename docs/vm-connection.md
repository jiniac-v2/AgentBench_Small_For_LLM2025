# VM 接続方法

VM 構築 ([環境構築: GCP](setup-gcp.md)) が完了していること。

## 方法 A: コマンドライン (gcloud SSH)

```bash
gcloud compute ssh agentbench-eval --zone YOUR_ZONE --project YOUR_PROJECT_ID
```

## 方法 B: VSCode Remote - SSH + IAP tunnel (推奨)

VSCode の **Remote - SSH** 拡張機能と GCP の **IAP (Identity-Aware Proxy) tunnel** を組み合わせる方法。
外部 IP 不要・IAM 認証・ポート 22 開放不要で、VSCode の全機能 (ターミナル、デバッグ、拡張機能) が使えます。

### 1. 前提

- gcloud CLI がインストール済み・認証済み (`gcloud auth login`)
- VSCode 拡張機能 **Remote - SSH** (`ms-vscode-remote.remote-ssh`) をインストール

### 2. 初回 SSH 接続 (鍵の生成)

一度 gcloud 経由で SSH しておくと、鍵ペア (`~/.ssh/google_compute_engine`) が自動生成されます。

```bash
gcloud compute ssh agentbench-eval \
  --tunnel-through-iap \
  --zone=YOUR_ZONE \
  --project=YOUR_PROJECT_ID
```

接続を確認したら `exit` で抜けます。

### 3. SSH config の取得

`--dry-run` で gcloud が生成する SSH コマンドを確認します。

```bash
gcloud compute ssh agentbench-eval \
  --tunnel-through-iap \
  --zone=YOUR_ZONE \
  --project=YOUR_PROJECT_ID \
  --dry-run
```

出力から `ProxyCommand`、`HostKeyAlias`、`User` などの値を確認します。

### 4. `~/.ssh/config` の設定

以下を `~/.ssh/config` に追記します。`YOUR_*` 部分を実際の値に置き換えてください。

```
Host agentbench-eval
    HostName compute.XXXXXXXXXX
    IdentityFile ~/.ssh/google_compute_engine
    CheckHostIP no
    HostKeyAlias compute.XXXXXXXXXX
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile ~/.ssh/google_compute_known_hosts
    ProxyCommand gcloud compute start-iap-tunnel agentbench-eval %p --listen-on-stdin --project=YOUR_PROJECT_ID --zone=YOUR_ZONE --verbosity=warning
    ProxyUseFdpass no
    User YOUR_USERNAME
```

> `HostName` と `HostKeyAlias` は Step 3 の `--dry-run` 出力からコピーしてください。

### 5. VSCode から接続

1. `Cmd+Shift+P` (Mac) / `Ctrl+Shift+P` (Windows/Linux)
2. **Remote-SSH: Connect to Host...** を選択
3. **agentbench-eval** を選択
4. 新しい VSCode ウィンドウが開き、VM に接続される

### 6. リモートフォルダを開く

接続後、**ファイル → フォルダを開く** で `/opt/agentbench` を指定すると、VM 上のコードを直接編集できます。

### 推奨 VSCode 設定

接続が安定しない場合、`settings.json` に以下を追加:

```json
{
    "remote.SSH.remotePlatform": {
        "agentbench-eval": "linux"
    },
    "remote.SSH.connectTimeout": 60,
    "remote.SSH.showLoginTerminal": true,
    "remote.SSH.useLocalServer": false
}
```

- `remotePlatform` を指定するとプラットフォーム検出ステップをスキップでき、IAP tunnel 経由でも安定します
- `showLoginTerminal: true` で接続失敗時のデバッグが容易になります

# WSL2 + GPU 環境構築ガイド (Docker Desktop)

Windows + WSL2 + NVIDIA GPU + **Docker Desktop** で AgentBench を動かすための詳細セットアップ手順です。

> **参考記事**: [WSL2でGPUを使う (usagi1975)](https://zenn.dev/usagi1975/articles/2025-03-31-000_wsl2-gpu)

---

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────┐
│  Windows 11                                         │
│  ┌────────────────────┐  ┌───────────────────────┐  │
│  │ NVIDIA GPU ドライバ │  │ Docker Desktop        │  │
│  │ (Game Ready/Studio)│  │  WSL 2 backend: ON    │  │
│  └────────┬───────────┘  └───────────┬───────────┘  │
│           │ /usr/lib/wsl/lib/        │ docker CLI    │
│  ┌────────▼──────────────────────────▼───────────┐  │
│  │  WSL2 (Ubuntu 22.04 / 24.04)                  │  │
│  │  ┌──────────┐  ┌──────────┐  ┌─────────────┐  │  │
│  │  │  vLLM    │  │  MySQL   │  │ AgentBench  │  │  │
│  │  │ :8000    │  │ :3306    │  │ (Python)    │  │  │
│  │  └──────────┘  └──────────┘  └─────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Docker Desktop を使う場合、WSL 内に Docker Engine や nvidia-container-toolkit を個別にインストールする必要はありません。** Docker Desktop が WSL 2 バックエンド経由ですべて管理します。

---

## 前提条件

| 項目 | 要件 |
|---|---|
| OS | Windows 10 (21H2+) / Windows 11 |
| GPU | NVIDIA (CUDA 対応、VRAM 12GB+ 推奨) |
| RAM | 32GB 以上推奨 |
| ディスク | SSD 200GB+ の空き |
| WSL | バージョン 2 |

---

## Step 1: Windows 側 — NVIDIA GPU ドライバのインストール

WSL2 で GPU を使うには **Windows 側にのみ** NVIDIA ドライバをインストールします。

1. [NVIDIA ドライバダウンロード](https://www.nvidia.com/Download/index.aspx) から **最新の Game Ready / Studio ドライバ** をダウンロード・インストール
2. インストール後、Windows を再起動

> **重要**: WSL 内に `nvidia-driver-*` パッケージは **絶対にインストールしないでください**。
> Windows 側のドライバが `/usr/lib/wsl/lib/` 経由で WSL 内に自動共有されます。
> WSL 内にドライバを入れると競合してクラッシュします。

### ドライバのバージョン確認 (Windows 側)

```powershell
nvidia-smi
```

`Driver Version: 570.xx.xx` 以上であることを確認してください。

---

## Step 2: WSL2 のセットアップ

### 2-1. WSL2 がまだの場合

PowerShell (管理者) で:

```powershell
wsl --install -d Ubuntu-22.04
```

インストール後、再起動してユーザー名・パスワードを設定してください。

> **カスタムディストリビューション名をつけたい場合** (参考記事の方法):
>
> ```powershell
> # 一旦デフォルト名でインストール
> wsl --install -d Ubuntu-22.04
>
> # エクスポート → 好きな名前でインポート
> wsl --export Ubuntu-22.04 D:\wsl\ubuntu-22.04.tar
> wsl --import MyAgentBench D:\wsl\MyAgentBench D:\wsl\ubuntu-22.04.tar
>
> # 不要になったデフォルトを削除
> wsl --unregister Ubuntu-22.04
> ```

### 2-2. WSL2 が既にある場合

バージョンが 2 であることを確認:

```powershell
wsl -l -v
```

```
  NAME            STATE           VERSION
* Ubuntu-22.04    Running         2
```

VERSION が `1` の場合は変換:

```powershell
wsl --set-version Ubuntu-22.04 2
```

### 2-3. WSL カーネルを最新に更新

```powershell
wsl --update
```

---

## Step 3: WSL 内で GPU の動作確認

WSL ターミナルで:

```bash
nvidia-smi
```

GPU の情報が表示されれば OK:

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx    Driver Version: 570.xx.xx    CUDA Version: 12.x                 |
|   ...
| GPU  Name        ...
|   0  NVIDIA GeForce RTX 4090  ...
+-----------------------------------------------------------------------------------------+
```

**表示されない場合のトラブルシューティング**:

1. Windows 側の NVIDIA ドライバが最新か確認
2. WSL を再起動: PowerShell で `wsl --shutdown` → WSL を再度開く
3. WSL カーネルを更新: `wsl --update`
4. `/usr/lib/wsl/lib/nvidia-smi` が存在するか確認:
   ```bash
   ls -la /usr/lib/wsl/lib/nvidia-smi
   ```
   存在しない場合、Windows 側のドライバの再インストールが必要です

---

## Step 4: Docker Desktop のインストールと設定

### 4-1. Docker Desktop のインストール

[Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) からダウンロードしてインストールします。

### 4-2. WSL 2 バックエンドの有効化

Docker Desktop の設定画面 (`Settings`) で:

1. **General** → `Use the WSL 2 based engine` をチェック (デフォルトで ON)
2. **Resources** → **WSL integration** → 使用する Ubuntu ディストリビューションを ON にする

```
Settings > Resources > WSL integration
  ☑ Enable integration with my default WSL distro
  ☑ Ubuntu-22.04     ← ON にする
```

3. `Apply & restart` をクリック

### 4-3. Docker Desktop の GPU サポート確認

Docker Desktop は WSL 2 バックエンド利用時に **自動的に GPU をサポート** します。
追加の nvidia-container-toolkit のインストールは不要です。

WSL ターミナルで動作確認:

```bash
# docker コマンドが使えることを確認
docker --version
docker compose version

# GPU が Docker から見えることを確認
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi
```

GPU 情報が表示されれば Docker 経由の GPU アクセスは正常です。

**動作しない場合**:

1. Docker Desktop が起動しているか確認 (タスクトレイのクジラアイコン)
2. WSL integration が有効か再確認 (`Settings > Resources > WSL integration`)
3. Docker Desktop を再起動
4. それでもダメな場合: `wsl --shutdown` → Docker Desktop を再起動 → WSL を起動

---

## Step 5: .wslconfig でリソース制限を調整

WSL2 はデフォルトで Windows の物理メモリの 50% しか使えません。
vLLM は大量のメモリを使うため、制限を緩和します。

**Windows 側** で `%UserProfile%\.wslconfig` を作成・編集:

```ini
[wsl2]
memory=24GB
swap=8GB
```

> **目安**: 搭載 RAM が 32GB なら `memory=24GB`、64GB なら `memory=48GB` 程度

変更後:

```powershell
wsl --shutdown
```

WSL を再度開いてメモリ制限を確認:

```bash
free -h
```

---

## Step 6: リポジトリのクローンと Python 環境構築

### 6-1. クローン

```bash
cd ~
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025
```

> **private リポの場合**: GitHub PAT を使って clone してください。

### 6-2. Python 依存パッケージのインストール

Docker Desktop を使う場合、`setup1.sh` の Docker / nvidia-container-toolkit のインストールは不要です。
Python 環境のみ手動でセットアップします:

```bash
sudo apt-get update
sudo apt-get install -y python3-pip cmake build-essential
pip3 install -r requirements.txt
```

依存パッケージの検証:

```bash
python3 -c "import gym; import alfworld; import docker; import torch; print('OK')"
```

### 6-3. ALFWorld データと設定ファイル

```bash
bash scripts/setup/setup2.sh
```

> `setup2.sh` は ALFWorld ランタイムデータのダウンロード、`.env` 生成、Docker イメージの pull を行います。

---

## Step 7: vLLM の起動

### 7-1. .env の設定

```bash
cd ~/AgentBench_Small_For_LLM2025
cp .env.example .env
vi .env
```

`.env`:

```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct
VLLM_MAX_MODEL_LEN=8192
VLLM_GPU_MEMORY_UTILIZATION=0.95
HUGGING_FACE_HUB_TOKEN=hf_xxxxxxxxxxxxx    # gated model の場合
```

### 7-2. docker compose で起動

```bash
docker compose up -d
```

### 7-3. 起動確認

```bash
# コンテナのステータス確認
docker compose ps

# ログをリアルタイムで確認 (起動完了まで 1〜5 分)
docker compose logs -f vllm

# API が応答するか確認
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

### 7-4. モデルの切り替え

別のモデルに切り替えるには:

```bash
bash scripts/eval/switch-model-local.sh
```

または `.env` を編集して:

```bash
docker compose down
docker compose up -d
```

---

## GPU VRAM とモデルサイズの目安

| GPU | VRAM | 推奨モデルサイズ |
|---|---|---|
| RTX 3060 | 12GB | ~7B (4bit 量子化) |
| RTX 3090 / 4090 | 24GB | ~14B |
| A100 / H100 | 40-80GB | ~70B |

> `VLLM_GPU_MEMORY_UTILIZATION=0.95` はデフォルトで VRAM の 95% を使います。
> OOM が出る場合は `0.85` に下げるか、`VLLM_MAX_MODEL_LEN` を小さくしてください。

---

## ディスク I/O に関する注意

WSL 内のファイルシステム (`/home/...`) は Windows のファイルシステム (`/mnt/c/...`) より **大幅に高速** です。
リポジトリや HuggingFace キャッシュは必ず WSL 内に置いてください。

```bash
# 良い: WSL ネイティブ (ext4)
~/AgentBench_Small_For_LLM2025/
~/.cache/huggingface/

# 悪い: Windows マウント (9P プロトコル経由、遅い)
/mnt/c/Users/.../AgentBench_Small_For_LLM2025/
```

---

## トラブルシューティング

### `nvidia-smi` が WSL 内で動かない

```bash
# パスを確認
which nvidia-smi || echo "not in PATH"
ls /usr/lib/wsl/lib/nvidia-smi

# PATH に追加 (必要な場合)
export PATH="/usr/lib/wsl/lib:$PATH"

# .bashrc に永続化
echo 'export PATH="/usr/lib/wsl/lib:$PATH"' >> ~/.bashrc
```

### `docker run --gpus all` でエラーが出る

```
docker: Error response from daemon: could not select device driver "" with capabilities: [[gpu]].
```

Docker Desktop が起動しているか確認してください。
Docker Desktop を使っている場合、WSL 内の Docker Engine / nvidia-container-toolkit は不要です。
もし WSL 内に Docker Engine がインストールされている場合、競合するので削除してください:

```bash
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io
```

### vLLM が起動しない / OOM

```bash
# ログ確認
docker compose logs vllm

# GPU メモリの使用状況
nvidia-smi

# メモリ使用率を下げて再起動
# .env を編集:
#   VLLM_GPU_MEMORY_UTILIZATION=0.85
#   VLLM_MAX_MODEL_LEN=4096
docker compose down
docker compose up -d
```

### WSL のメモリが足りない

```bash
free -h
```

`%UserProfile%\.wslconfig` の `memory` を増やしてください (→ [Step 5](#step-5-wslconfig-でリソース制限を調整))。

### Docker Desktop が WSL ディストロを認識しない

```powershell
# ディストロ一覧を確認
wsl -l -v

# Docker Desktop の Settings > Resources > WSL integration で
# 対象ディストリビューションが ON になっているか確認
```

---

## 推奨スペック (まとめ)

| 項目 | 推奨値 |
|---|---|
| OS | Windows 10/11 + WSL2 (Ubuntu 22.04) |
| GPU | NVIDIA RTX 3090 以上 (VRAM 24GB+) |
| RAM | 32GB 以上 |
| ディスク | SSD 200GB 以上の空き |
| NVIDIA ドライバ | 最新版 (Windows 側のみ) |
| Docker | **Docker Desktop** (WSL 2 backend) |
| vLLM | v0.13.0 |

---

## 次のステップ

- [ローカル評価の実行](runbook.md)

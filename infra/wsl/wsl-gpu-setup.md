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

---

## 前提条件 (3 ステップ)

やることは 3 つだけです:

1. **Windows の NVIDIA ドライバを最新にする**
2. **公式の CUDA Toolkit インストール手順を WSL の Ubuntu でやる**
3. **Docker Desktop をインストールする**

以下、それぞれの詳細です。

---

## Step 1: Windows 側 — NVIDIA GPU ドライバを最新にする

普通に Windows 側の NVIDIA ドライバを最新にしておくだけで OK です。

- [NVIDIA ドライバダウンロード](https://www.nvidia.com/Download/index.aspx) から最新ドライバをダウンロード・インストール
- GeForce Experience / NVIDIA App からの更新でも可
- インストール後、Windows を再起動

> **重要**: WSL 内に `nvidia-driver-*` パッケージは **絶対にインストールしないでください**。
> Windows 側のドライバが `/usr/lib/wsl/lib/` 経由で WSL 内に自動共有されます。

### 確認

```powershell
nvidia-smi
```

### WSL2 の準備

WSL2 がまだの場合は PowerShell (管理者) で:

```powershell
wsl --install -d Ubuntu-22.04
```

既にある場合はバージョン 2 であることを確認:

```powershell
wsl -l -v
```

WSL カーネルも最新にしておく:

```powershell
wsl --update
```

WSL 内で `nvidia-smi` が動くことを確認:

```bash
nvidia-smi
```

---

## Step 2: WSL の Ubuntu に CUDA Toolkit をインストールする

[NVIDIA CUDA Toolkit ダウンロードページ](https://developer.nvidia.com/cuda-downloads) で以下を選択:

- **Operating System**: Linux
- **Architecture**: x86_64
- **Distribution**: WSL-Ubuntu
- **Version**: 2.0
- **Installer Type**: deb (network)

表示されたコマンドをそのまま WSL 内で実行します:

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get -y install cuda-toolkit-12-6
```

> **バージョンについて**: `cuda-toolkit-12-6` の部分はページに表示されたバージョンに合わせてください。
> 最新版をインストールしたい場合は、ダウンロードページの指示に従ってください。

### PATH を通す

```bash
echo 'export PATH="/usr/local/cuda/bin:$PATH"' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"' >> ~/.bashrc
source ~/.bashrc
```

### 確認

```bash
nvcc --version
```

> **注意**: `cuda` や `cuda-drivers` メタパッケージは **インストールしないでください**。
> これらは Linux 用 GPU ドライバを含むため、Windows 側のドライバと競合します。
> 必ず `cuda-toolkit-XX-X` を指定してください。

---

## Step 3: Docker Desktop をインストールする

### 3-1. インストール

[Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) からダウンロードしてインストールします。

### 3-2. WSL 2 バックエンドの有効化

Docker Desktop の設定画面 (`Settings`) で:

1. **General** → `Use the WSL 2 based engine` をチェック (デフォルトで ON)
2. **Resources** → **WSL integration** → 使用する Ubuntu ディストリビューションを ON にする

```
Settings > Resources > WSL integration
  ☑ Enable integration with my default WSL distro
  ☑ Ubuntu-22.04     ← ON にする
```

3. `Apply & restart` をクリック

### 3-3. GPU パススルーの確認

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

GPU 情報が表示されれば前提条件は **すべてクリア** です。

**動作しない場合**:

1. Docker Desktop が起動しているか確認 (タスクトレイのクジラアイコン)
2. WSL integration が有効か再確認 (`Settings > Resources > WSL integration`)
3. Docker Desktop を再起動
4. それでもダメな場合: `wsl --shutdown` → Docker Desktop を再起動 → WSL を起動

---

## AgentBench のセットアップ

前提条件が整ったら、AgentBench 本体のセットアップに進みます。

### リポジトリのクローン

```bash
cd ~
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025
```

> **private リポの場合**: GitHub PAT を使って clone してください。

### セットアップスクリプト (Docker Desktop 版)

Docker Desktop 用の専用セットアップスクリプトを使います。
Docker Engine / nvidia-container-toolkit のインストールはスキップし、Python 依存のみセットアップします:

```bash
# (1) Python 依存パッケージ (要 sudo)
sudo bash infra/wsl/setup1_desktop.sh
```

> **Docker Engine 版** (`setup1.sh`) との違い:
> - Docker Engine のインストールをスキップ (Docker Desktop が提供)
> - nvidia-container-toolkit のインストールをスキップ (Docker Desktop が管理)
> - docker グループへの追加をスキップ (Docker Desktop が管理)
> - GPU パススルーの動作確認を自動実行

### ALFWorld データと設定ファイル

```bash
bash infra/wsl/setup2.sh
```

> `setup2.sh` は ALFWorld ランタイムデータのダウンロード、`.env` 生成、Docker イメージの pull を行います。

### .wslconfig でリソース制限を調整

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

---

## vLLM の起動

### .env の設定

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

### docker compose で起動

```bash
docker compose up -d
```

### 起動確認

```bash
# コンテナのステータス確認
docker compose ps

# ログをリアルタイムで確認 (起動完了まで 1〜5 分)
docker compose logs -f vllm

# API が応答するか確認
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

### モデルの切り替え

`.env` の `VLLM_MODEL` を編集して vLLM を再起動:

```bash
vi .env
docker compose down && docker compose up -d

# agent config のモデル名も更新
sed -i "s|^\([[:space:]]*\)model:.*|\1model: \"your-org/your-model\"|" configs/agents/api_agents.yaml
```

---

## GPU VRAM とモデルサイズの目安

| GPU | VRAM | 推奨モデルサイズ |
|---|---|---|
| RTX 3060 | 12GB | ~7B (4bit 量子化) |
| RTX 3090 / 4090 | 24GB | ~14B |
| RTX 5090 | 32GB | ~14B (余裕あり) |
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

`%UserProfile%\.wslconfig` の `memory` を増やしてください。

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
